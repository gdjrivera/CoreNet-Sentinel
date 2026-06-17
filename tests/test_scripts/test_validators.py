#!/usr/bin/env python3
"""
Tests for FortiGate Backup Validators
"""

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent.parent / "scripts" / "python"))

from config_validator import FortiGateConfigValidator
from hash_verifier import HashVerifier


class TestConfigValidator(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.mkdtemp()
        self.validator = FortiGateConfigValidator(
            config_dir=self.temp_dir,
            hostname="FGT-TEST-01",
            model="FortiGate-100F",
            firmware="v7.4.3",
            min_size=100,
            max_size=10485760,
        )

    def _write_config(self, content: str, filename: str = "config.conf"):
        path = Path(self.temp_dir) / filename
        path.write_text(content)
        return path

    def test_valid_full_config(self):
        config = """# FortiGate Configuration
config system global
    set hostname "FGT-TEST-01"
end
config system interface
    set port1-ip "10.0.0.1/24"
end
config firewall policy
    edit 1
        set srcintf "port1"
        set dstintf "port2"
        set srcaddr "all"
        set dstaddr "all"
        set action accept
    next
end
config router static
    edit 1
        set dst 0.0.0.0 0.0.0.0
        set gateway 10.0.0.254
        set device "port1"
    next
end
"""
        self._write_config(config)
        results = self.validator.validate()
        self.assertTrue(results["valid"])
        self.assertEqual(len(results["errors"]), 0)

    def test_missing_required_sections(self):
        config = """config system global
    set hostname "FGT-TEST-01"
end
"""
        self._write_config(config)
        results = self.validator.validate()
        self.assertFalse(results["valid"])
        self.assertTrue(any("missing" in e.lower() for e in results["errors"]))

    def test_forbidden_patterns_detected(self):
        config = """config system global
    set hostname "FGT-TEST-01"
    set password "super-secret-123"
end
config system interface
    set port1-ip "10.0.0.1/24"
end
config firewall policy
    edit 1
        set srcintf "port1"
        set dstintf "port2"
        set action accept
    next
end
config router static
    edit 1
        set dst 0.0.0.0 0.0.0.0
        set gateway 10.0.0.254
    next
end
"""
        self._write_config(config)
        results = self.validator.validate()
        self.assertTrue(results["valid"])
        self.assertGreater(len(results["warnings"]), 0)

    def test_unbalanced_braces(self):
        config = """config system global
    set hostname "FGT-TEST-01"
config system interface
    set port1-ip "10.0.0.1/24"
end
"""
        self._write_config(config)
        results = self.validator.validate()
        self.assertFalse(results["valid"])
        self.assertTrue(any("braces" in e.lower() for e in results["errors"]))

    def test_config_too_small(self):
        config = "small"
        self._write_config(config)
        results = self.validator.validate()
        self.assertFalse(results["valid"])
        self.assertTrue(any("small" in e.lower() for e in results["errors"]))

    def test_security_checks(self):
        config = """config system global
    set hostname "FGT-TEST-01"
    set admin-https-redirect enable
    set admin-ssl-version tls-1.2
end
config system interface
    set port1-ip "10.0.0.1/24"
end
config firewall policy
    edit 1
        set srcintf "port1"
        set dstintf "port2"
        set action accept
    next
end
config router static
    edit 1
        set dst 0.0.0.0 0.0.0.0
        set gateway 10.0.0.254
    next
end
"""
        self._write_config(config)
        results = self.validator.validate()
        security_check = results["checks"]["security_posture"]
        self.assertIn("admin_https_redirect", security_check["details"]["passed"])

    def test_validation_report_output(self):
        config = """config system global
    set hostname "FGT-TEST-01"
end
config system interface
    set port1-ip "10.0.0.1/24"
end
config firewall policy
    edit 1
        set srcintf "port1"
        set dstintf "port2"
        set action accept
    next
end
config router static
    edit 1
        set dst 0.0.0.0 0.0.0.0
        set gateway 10.0.0.254
    next
end
"""
        self._write_config(config)
        results = self.validator.validate()
        report_path = Path(self.temp_dir) / "validation_report.json"
        with open(report_path, "w") as f:
            json.dump(results, f, indent=2)
        self.assertTrue(report_path.exists())
        with open(report_path) as f:
            loaded = json.load(f)
        self.assertEqual(loaded["hostname"], "FGT-TEST-01")


class TestHashVerifier(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.mkdtemp()
        self.verifier = HashVerifier(self.temp_dir)

    def test_calculate_hash(self):
        filepath = Path(self.temp_dir) / "test.txt"
        filepath.write_text("test content")
        hash_result = self.verifier.calculate_hash(filepath, "sha256")
        self.assertEqual(len(hash_result), 64)
        self.assertTrue(all(c in "0123456789abcdef" for c in hash_result))

    def test_verify_file_correct(self):
        filepath = Path(self.temp_dir) / "test.conf"
        filepath.write_text("config data")
        expected = self.verifier.calculate_hash(filepath)
        result = self.verifier.verify_file(filepath, expected)
        self.assertTrue(result["verified"])

    def test_verify_file_incorrect(self):
        filepath = Path(self.temp_dir) / "test.conf"
        filepath.write_text("config data")
        result = self.verifier.verify_file(filepath, "0000000000000000000000000000000000000000000000000000000000000000")
        self.assertFalse(result["verified"])

    def test_verify_file_not_found(self):
        result = self.verifier.verify_file(Path("/nonexistent/file.conf"), "hash")
        self.assertFalse(result["verified"])
        self.assertIn("error", result)

    def test_build_hash_chain(self):
        config_dir = Path(self.temp_dir) / "fgt-test" / "20250101"
        config_dir.mkdir(parents=True)
        (config_dir / "fgt-test_20250101_full_config.conf").write_text("config data")
        chain = self.verifier.build_hash_chain(Path(self.temp_dir))
        self.assertIn("entries", chain)
        self.assertGreater(chain["total_entries"], 0)
        self.assertIn("head_hash", chain)

    def test_verify_chain(self):
        config_dir = Path(self.temp_dir) / "fgt-test" / "20250101"
        config_dir.mkdir(parents=True)
        (config_dir / "fgt-test_20250101_full_config.conf").write_text("config data")
        self.verifier.build_hash_chain(Path(self.temp_dir))
        result = self.verifier.verify_chain(Path(self.temp_dir))
        self.assertTrue(result.get("valid", False))

    def test_chain_tamper_detection(self):
        config_dir = Path(self.temp_dir) / "fgt-test" / "20250101"
        config_dir.mkdir(parents=True)
        filepath = config_dir / "fgt-test_20250101_full_config.conf"
        filepath.write_text("original config data")
        self.verifier.build_hash_chain(Path(self.temp_dir))

        filepath.write_text("MODIFIED config data!!!")
        result = self.verifier.verify_chain(Path(self.temp_dir))
        self.assertFalse(result.get("valid", True))


if __name__ == "__main__":
    unittest.main()
