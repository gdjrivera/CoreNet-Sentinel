#!/usr/bin/env python3
"""
FortiGate Configuration Validator

Validates the integrity, structure, and security posture
of extracted FortiGate configurations.

Usage:
    python3 validate_config.py \\
        --config-dir /path/to/configs \\
        --hostname FGT-NAME \\
        --model FortiGate-600F \\
        --firmware v7.4.3 \\
        --min-size 1024 \\
        --max-size 10485760 \\
        --output /path/to/report.json
"""

import argparse
import hashlib
import json
import os
import re
import sys
from datetime import datetime
from pathlib import Path


class FortiGateConfigValidator:
    REQUIRED_SECTIONS = [
        "config system global",
        "config system interface",
        "config firewall policy",
        "config router static",
    ]

    FORBIDDEN_PATTERNS = [
        (r"set\s+password\s+\S+", "Plain text password detected"),
        (r"set\s+private-key\s+\S+", "Private key in configuration"),
        (r"set\s+secret\s+\S+", "Secret exposed in configuration"),
        (r"set\s+key\s+\S+", "Encryption key exposed"),
        (r"set\s+psksecret\s+\S+", "Pre-shared key exposed"),
        (r"set\s+passwd\s+\S+", "Password in configuration"),
    ]

    SECURITY_CHECKS = [
        ("admin_https_redirect", r"set\s+admin-https-redirect\s+enable", "HTTPS redirect not enabled"),
        ("admin_ssl_version", r"set\s+admin-ssl-version\s+tls-1\.[23]", "TLS version too old"),
        ("admin_ssl_ciphersuites", r"set\s+admin-ssl-ciphersuites", "SSL cipher suites not restricted"),
        ("https_required", r"set\s+https\s+enable", "HTTPS not enabled"),
        ("failed_logins", r"set\s+admin-login-threshold", "Failed login threshold not configured"),
        ("lockout_period", r"set\s+admin-lockout-duration", "Account lockout not configured"),
        ("password_policy", r"config\s+system\s+password-policy", "Password policy not configured"),
        ("session_timeout", r"set\s+admin-idle-timeout", "Admin session timeout not configured"),
        ("antivirus", r"config\s+antivirus\s+profile", "No antivirus profiles found"),
        ("ips", r"config\s+ips\s+sensor", "No IPS sensors found"),
        ("web_filter", r"config\s+webfilter\s+profile", "No web filter profiles found"),
        ("dns_filter", r"config\s+dnsfilter\s+profile", "No DNS filter profiles found"),
        ("log_disk", r"set\s+log-disk\s+enable", "Local logging to disk not enabled"),
        ("log_remote", r"set\s+syslog\s+status\s+enable", "Remote syslog not configured"),
    ]

    def __init__(self, config_dir: str, hostname: str, model: str, firmware: str,
                 min_size: int, max_size: int):
        self.config_dir = Path(config_dir)
        self.hostname = hostname
        self.model = model
        self.firmware = firmware
        self.min_size = min_size
        self.max_size = max_size
        self.errors = []
        self.warnings = []
        self.info = []
        self.config_content = None

    def validate(self) -> dict:
        """Run all validation checks and return results."""
        result = {
            "hostname": self.hostname,
            "model": self.model,
            "firmware": self.firmware,
            "timestamp": datetime.utcnow().isoformat(),
            "valid": True,
            "errors": [],
            "warnings": [],
            "info": [],
            "checks": {},
        }

        config_files = self._find_config_files()

        if not config_files:
            self.errors.append("No configuration files found")
            result["valid"] = False
            result["errors"] = self.errors
            return result

        for config_file in config_files:
            self.config_content = self._read_config(config_file)
            if not self.config_content:
                continue

            result["checks"]["file_integrity"] = self._check_file_integrity(config_file)
            result["checks"]["size_validation"] = self._check_size(config_file)
            result["checks"]["required_sections"] = self._check_required_sections()
            result["checks"]["forbidden_patterns"] = self._check_forbidden_patterns()
            result["checks"]["security_posture"] = self._check_security_posture()
            result["checks"]["syntax_validation"] = self._check_syntax()

        result["errors"] = self.errors
        result["warnings"] = self.warnings
        result["info"] = self.info
        result["valid"] = len(self.errors) == 0

        return result

    def _find_config_files(self) -> list:
        """Find configuration files in the backup directory."""
        patterns = ["*.conf", "*.json", "*.txt"]
        files = []
        for pattern in patterns:
            files.extend(self.config_dir.glob(pattern))
        return sorted(files)

    def _read_config(self, filepath: Path) -> str | None:
        """Read configuration file content."""
        try:
            content = filepath.read_text(encoding="utf-8", errors="replace")
            self.info.append(f"Read configuration from {filepath.name} ({len(content)} bytes)")
            return content
        except Exception as e:
            self.errors.append(f"Cannot read {filepath.name}: {e}")
            return None

    def _check_file_integrity(self, filepath: Path) -> dict:
        """Verify file integrity using SHA-256 hash."""
        result = {"status": "pass", "details": {}}
        try:
            sha256 = hashlib.sha256()
            sha256.update(self.config_content.encode("utf-8"))
            result["details"]["sha256"] = sha256.hexdigest()
            self.info.append(f"SHA-256: {result['details']['sha256']}")

            first_line = self.config_content.split("\n")[0]
            if "FortiGate" not in first_line and "config" not in first_line.lower():
                result["status"] = "warn"
                self.warnings.append(f"File {filepath.name} may not be a valid FortiGate config")
        except Exception as e:
            result["status"] = "fail"
            self.errors.append(f"Integrity check failed for {filepath.name}: {e}")

        return result

    def _check_size(self, filepath: Path) -> dict:
        """Validate configuration file size."""
        result = {"status": "pass", "details": {}}
        size = len(self.config_content)

        result["details"]["size_bytes"] = size

        if size < self.min_size:
            result["status"] = "fail"
            self.errors.append(
                f"Configuration too small: {size} bytes (min: {self.min_size})"
            )
        elif size > self.max_size:
            result["status"] = "fail"
            self.errors.append(
                f"Configuration too large: {size} bytes (max: {self.max_size})"
            )
        elif size < self.min_size * 5:
            result["status"] = "warn"
            self.warnings.append(
                f"Configuration is minimal: {size} bytes"
            )

        return result

    def _check_required_sections(self) -> dict:
        """Verify presence of required configuration blocks."""
        result = {"status": "pass", "details": {"present": [], "missing": []}}

        for section in self.REQUIRED_SECTIONS:
            pattern = re.escape(section)
            if re.search(pattern, self.config_content, re.IGNORECASE):
                result["details"]["present"].append(section)
            else:
                result["details"]["missing"].append(section)
                result["status"] = "fail"
                self.errors.append(f"Required section missing: {section}")

        return result

    def _check_forbidden_patterns(self) -> dict:
        """Scan for sensitive data that should not be in config files."""
        result = {"status": "pass", "details": {"findings": []}}

        for pattern, description in self.FORBIDDEN_PATTERNS:
            matches = re.findall(pattern, self.config_content, re.IGNORECASE)
            if matches:
                result["details"]["findings"].append({
                    "pattern": pattern,
                    "description": description,
                    "count": len(matches),
                })
                result["status"] = "warn"
                self.warnings.append(f"{description} ({len(matches)} occurrence(s))")

        return result

    def _check_security_posture(self) -> dict:
        """Evaluate security posture based on configuration settings."""
        result = {"status": "pass", "details": {"passed": [], "failed": []}}

        for check_name, pattern, fail_message in self.SECURITY_CHECKS:
            if re.search(pattern, self.config_content, re.IGNORECASE):
                result["details"]["passed"].append(check_name)
            else:
                result["details"]["failed"].append(check_name)
                result["status"] = "warn"
                self.warnings.append(f"Security check failed: {fail_message}")

        return result

    def _check_syntax(self) -> dict:
        """Basic syntax validation of configuration structure."""
        result = {"status": "pass", "details": {}}

        open_braces = self.config_content.count("{")
        close_braces = self.config_content.count("}")
        result["details"]["brace_balance"] = open_braces - close_braces

        if open_braces != close_braces:
            result["status"] = "fail"
            self.errors.append(
                f"Unbalanced braces: {open_braces} open vs {close_braces} close "
                f"(delta: {result['details']['brace_balance']})"
            )

        lines = self.config_content.split("\n")
        result["details"]["total_lines"] = len(lines)
        result["details"]["config_lines"] = sum(
            1 for line in lines if line.strip() and not line.startswith("#")
        )
        result["details"]["comment_lines"] = sum(
            1 for line in lines if line.strip().startswith("#")
        )

        return result


def main():
    parser = argparse.ArgumentParser(
        description="FortiGate Configuration Validator",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--config-dir", required=True, help="Directory containing config files")
    parser.add_argument("--hostname", required=True, help="Device hostname")
    parser.add_argument("--model", default="unknown", help="Device model")
    parser.add_argument("--firmware", default="unknown", help="Firmware version")
    parser.add_argument("--min-size", type=int, default=1024, help="Minimum config size in bytes")
    parser.add_argument("--max-size", type=int, default=10485760, help="Maximum config size in bytes")
    parser.add_argument("--output", default=None, help="Output JSON report path")

    args = parser.parse_args()

    validator = FortiGateConfigValidator(
        config_dir=args.config_dir,
        hostname=args.hostname,
        model=args.model,
        firmware=args.firmware,
        min_size=args.min_size,
        max_size=args.max_size,
    )

    results = validator.validate()

    output_path = args.output or os.path.join(args.config_dir, "validation_report.json")
    os.makedirs(os.path.dirname(output_path) or ".", exist_ok=True)

    with open(output_path, "w", encoding="utf-8") as f:
        json.dump(results, f, indent=2, ensure_ascii=False)

    if results["errors"]:
        print(f"[FAIL] Validation failed for {args.hostname}")
        print(f"       {len(results['errors'])} error(s), {len(results['warnings'])} warning(s)")
        for error in results["errors"]:
            print(f"       ERROR: {error}")
    else:
        print(f"[PASS] Validation passed for {args.hostname}")

    for warning in results["warnings"]:
        print(f"       WARN: {warning}")

    sys.exit(1 if results["errors"] else 0)


if __name__ == "__main__":
    main()
