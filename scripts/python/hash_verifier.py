#!/usr/bin/env python3
"""
Hash Verifier for FortiGate Backup Integrity

Verifies the integrity of backed up configurations using
SHA-256 hashes and maintains a hash chain for tamper detection.

Usage:
    python3 hash_verifier.py --verify /path/to/config.conf --hash abc123...
    python3 hash_verifier.py --verify-dir /opt/backups/fortigates
    python3 hash_verifier.py --chain /opt/backups/fortigates --recent 30
    python3 hash_verifier.py --rebuild-chain /opt/backups/fortigates
"""

import argparse
import hashlib
import json
import os
import sys
from datetime import datetime
from pathlib import Path


class HashVerifier:
    CHUNK_SIZE = 65536
    CHAIN_FILE = ".hash_chain.json"

    def __init__(self, backup_dir: str):
        self.backup_dir = Path(backup_dir)

    def calculate_hash(self, filepath: Path, algorithm: str = "sha256") -> str:
        """Calculate file hash using specified algorithm."""
        hasher = hashlib.new(algorithm)
        with open(filepath, "rb") as f:
            while chunk := f.read(self.CHUNK_SIZE):
                hasher.update(chunk)
        return hasher.hexdigest()

    def verify_file(self, filepath: Path, expected_hash: str, algorithm: str = "sha256") -> dict:
        """Verify a single file's integrity."""
        result = {
            "file": str(filepath),
            "expected_hash": expected_hash,
            "algorithm": algorithm,
            "verified": False,
            "computed_hash": None,
            "timestamp": datetime.utcnow().isoformat(),
        }

        if not filepath.exists():
            result["error"] = "File not found"
            return result

        computed = self.calculate_hash(filepath, algorithm)
        result["computed_hash"] = computed
        result["verified"] = computed == expected_hash

        return result

    def verify_directory(self, directory: Path = None, recursive: bool = True) -> list[dict]:
        """Verify all configuration files in a directory."""
        if directory is None:
            directory = self.backup_dir

        results = []
        pattern = "**/*" if recursive else "*"

        for filepath in directory.glob(pattern):
            if not filepath.is_file() or filepath.suffix in {".json", ".md", ".log"}:
                continue
            if filepath.name == self.CHAIN_FILE:
                continue

            hash_file = filepath.parent / f"{filepath.name}.sha256"
            if hash_file.exists():
                expected = hash_file.read_text().strip().split()[0]
                result = self.verify_file(filepath, expected)
                results.append(result)
            else:
                results.append({
                    "file": str(filepath),
                    "error": "No hash file found",
                    "verified": False,
                })

        return results

    def build_hash_chain(self, base_dir: Path = None) -> dict:
        """Build or rebuild the hash chain for tamper detection."""
        if base_dir is None:
            base_dir = self.backup_dir

        chain = {
            "chain_metadata": {
                "built_at": datetime.utcnow().isoformat(),
                "base_directory": str(base_dir),
                "chain_type": "merkle_dag",
                "version": "2.0",
            },
            "entries": [],
            "previous_head_hash": None,
        }

        chain_file = base_dir / self.CHAIN_FILE
        if chain_file.exists():
            try:
                previous = json.loads(chain_file.read_text())
                chain["previous_head_hash"] = previous.get("head_hash")
            except (json.JSONDecodeError, Exception):
                pass

        config_files = sorted(base_dir.rglob("*full_config*"))
        previous_hash = chain["previous_head_hash"]

        for config_file in config_files:
            if not config_file.is_file():
                continue

            file_hash = self.calculate_hash(config_file)
            entry = {
                "file": str(config_file.relative_to(base_dir)),
                "hash": file_hash,
                "size_bytes": config_file.stat().st_size,
                "modified_at": datetime.fromtimestamp(config_file.stat().st_mtime).isoformat(),
                "previous_hash": previous_hash,
            }

            entry_hash = hashlib.sha256(
                json.dumps(entry, sort_keys=True).encode()
            ).hexdigest()
            entry["entry_hash"] = entry_hash

            chain["entries"].append(entry)
            previous_hash = entry_hash

        chain["head_hash"] = previous_hash
        chain["total_entries"] = len(config_files)

        chain_file.write_text(json.dumps(chain, indent=2, default=str))
        return chain

    def verify_chain(self, base_dir: Path = None) -> dict:
        """Verify the integrity of the entire hash chain."""
        if base_dir is None:
            base_dir = self.backup_dir

        chain_file = base_dir / self.CHAIN_FILE
        if not chain_file.exists():
            return {"valid": False, "error": "No hash chain found"}

        chain = json.loads(chain_file.read_text())
        results = {
            "valid": True,
            "chain_length": chain.get("total_entries", 0),
            "verified_entries": 0,
            "failed_entries": 0,
            "errors": [],
        }

        previous_hash = chain.get("previous_head_hash")

        for entry in chain.get("entries", []):
            config_path = base_dir / entry["file"]

            if not config_path.exists():
                results["valid"] = False
                results["errors"].append(f"Missing file: {entry['file']}")
                results["failed_entries"] += 1
                continue

            computed_hash = self.calculate_hash(config_path)
            if computed_hash != entry["hash"]:
                results["valid"] = False
                results["errors"].append(
                    f"Hash mismatch for {entry['file']}: expected {entry['hash']}, computed {computed_hash}"
                )
                results["failed_entries"] += 1
                continue

            if previous_hash and entry.get("previous_hash"):
                if entry["previous_hash"] != previous_hash:
                    results["valid"] = False
                    results["errors"].append(
                        f"Chain break at {entry['file']}: expected prev {previous_hash[:16]}..., got {entry['previous_hash'][:16]}..."
                    )

            # Verify the entry hash itself
            entry_copy = {k: v for k, v in entry.items() if k != "entry_hash"}
            expected_entry_hash = hashlib.sha256(
                json.dumps(entry_copy, sort_keys=True).encode()
            ).hexdigest()

            if expected_entry_hash != entry.get("entry_hash"):
                results["valid"] = False
                results["errors"].append(f"Entry hash tampered for {entry['file']}")
                results["failed_entries"] += 1
                continue

            previous_hash = entry["entry_hash"]
            results["verified_entries"] += 1

        return results

    def get_integrity_report(self, base_dir: Path = None) -> str:
        """Generate an integrity report for auditing."""
        if base_dir is None:
            base_dir = self.backup_dir

        chain_results = self.verify_chain(base_dir)
        file_results = self.verify_directory(base_dir)

        report = []
        report.append("=" * 72)
        report.append("FORTIGATE BACKUP INTEGRITY REPORT")
        report.append(f"Generated: {datetime.utcnow().isoformat()}")
        report.append(f"Base Directory: {base_dir}")
        report.append("=" * 72)

        report.append(f"\nHash Chain Status:")
        report.append(f"  Chain Valid: {chain_results.get('valid', False)}")
        report.append(f"  Entries Verified: {chain_results.get('verified_entries', 0)}")
        report.append(f"  Failed Entries: {chain_results.get('failed_entries', 0)}")

        if chain_results.get("errors"):
            report.append(f"\n  Chain Errors:")
            for error in chain_results["errors"][:10]:
                report.append(f"    - {error}")
            if len(chain_results["errors"]) > 10:
                report.append(f"    ... and {len(chain_results['errors']) - 10} more")

        report.append(f"\nFile Verification:")
        verified = sum(1 for r in file_results if r.get("verified"))
        failed = sum(1 for r in file_results if not r.get("verified"))
        report.append(f"  Files Verified: {verified}")
        report.append(f"  Files Failed: {failed}")

        for result in file_results:
            if not result.get("verified"):
                report.append(f"    FAIL: {result['file']} - {result.get('error', 'Hash mismatch')}")

        report.append("\n" + "=" * 72)
        return "\n".join(report)


def main():
    parser = argparse.ArgumentParser(
        description="FortiGate Backup Hash Verifier",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--backup-dir", required=True, help="Backup directory path")
    parser.add_argument("--verify", help="Verify a single file")
    parser.add_argument("--hash", help="Expected hash for single file verification")
    parser.add_argument("--verify-dir", help="Verify all files in directory")
    parser.add_argument("--chain", action="store_true", help="Build or rebuild hash chain")
    parser.add_argument("--verify-chain", action="store_true", help="Verify hash chain integrity")
    parser.add_argument("--report", action="store_true", help="Generate integrity report")
    parser.add_argument("--algorithm", default="sha256", help="Hash algorithm")

    args = parser.parse_args()

    verifier = HashVerifier(args.backup_dir)

    if args.verify and args.hash:
        result = verifier.verify_file(Path(args.verify), args.hash, args.algorithm)
        print(f"Verification: {'PASSED' if result['verified'] else 'FAILED'}")
        print(f"  File: {result['file']}")
        print(f"  Expected: {result['expected_hash']}")
        print(f"  Computed: {result['computed_hash']}")
        sys.exit(0 if result['verified'] else 1)

    elif args.verify_dir:
        results = verifier.verify_directory(Path(args.verify_dir))
        passed = sum(1 for r in results if r.get("verified"))
        failed = len(results) - passed
        print(f"Verification: {passed} passed, {failed} failed")
        for result in results:
            if not result.get("verified"):
                print(f"  FAIL: {result['file']} - {result.get('error', 'unknown')}")
        sys.exit(1 if failed > 0 else 0)

    elif args.chain:
        chain = verifier.build_hash_chain()
        print(f"Hash chain built: {chain['total_entries']} entries")
        print(f"Head hash: {chain['head_hash'][:32]}...")
        sys.exit(0)

    elif args.verify_chain:
        results = verifier.verify_chain()
        print(f"Chain verification: {'PASSED' if results['valid'] else 'FAILED'}")
        print(f"  Entries: {results['verified_entries']} verified, {results['failed_entries']} failed")
        for error in results.get("errors", [])[:5]:
            print(f"  Error: {error}")
        sys.exit(0 if results['valid'] else 1)

    elif args.report:
        report = verifier.get_integrity_report()
        print(report)
        sys.exit(0)

    else:
        parser.print_help()


if __name__ == "__main__":
    main()
