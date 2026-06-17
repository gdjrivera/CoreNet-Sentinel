#!/usr/bin/env python3
"""
Compliance Checker for FortiGate Backup System

Automated compliance verification against configured audit rules.

Usage:
    python3 compliance_check.py --profile standard
    python3 compliance_check.py --profile enhanced
    python3 compliance_check.py --all
    python3 compliance_check.py --rule AUDIT-BK-001
    python3 compliance_check.py --report output.json
"""

import argparse
import json
import os
import subprocess
import sys
from datetime import datetime
from pathlib import Path

try:
    import yaml
except ImportError:
    yaml = None


class ComplianceChecker:
    def __init__(self, rules_file: str, backup_dir: str):
        self.rules_file = Path(rules_file)
        self.backup_dir = Path(backup_dir)
        self.rules = self._load_rules()
        self.results = []

    def _load_rules(self) -> dict:
        """Load audit rules from YAML configuration."""
        if not self.rules_file.exists():
            print(f"Rules file not found: {self.rules_file}", file=sys.stderr)
            return {"audit_rules": [], "compliance_profiles": {}}

        with open(self.rules_file) as f:
            if yaml:
                return yaml.safe_load(f) or {}
            import json as jsonlib
            return jsonlib.load(f)

    def _get_rules_for_profile(self, profile: str) -> list:
        """Get list of rule IDs for a compliance profile."""
        profiles = self.rules.get("compliance_profiles", {})
        profile_config = profiles.get(profile, {})
        rule_ids = profile_config.get("rules", [])

        rules = []
        all_rules = self.rules.get("audit_rules", [])
        for rule in all_rules:
            if rule.get("id") in rule_ids:
                rules.append(rule)

        return rules

    def check_backup_frequency(self, device: str) -> dict:
        """Check if device was backed up in last 24h."""
        result = {"check": "backup_frequency_last_24h", "passed": False, "details": {}}

        today = datetime.utcnow().strftime("%Y-%m-%d")
        device_dir = self.backup_dir / device / today

        if device_dir.exists():
            configs = list(device_dir.glob("*full_config*"))
            result["passed"] = len(configs) > 0
            result["details"]["files_found"] = len(configs)
            result["details"]["backup_date"] = today
        else:
            result["details"]["error"] = f"No backup directory for {device} on {today}"

        return result

    def check_repo_permissions(self) -> dict:
        """Check file permissions on backup repository."""
        result = {"check": "repository_permissions", "passed": True, "details": {}}
        issues = []

        # Check directory permissions (should be 0750)
        for item in self.backup_dir.iterdir():
            if item.is_dir() and not item.name.startswith("."):
                mode = oct(item.stat().st_mode)[-3:]
                if mode not in ["750", "755", "775", "770"]:
                    issues.append(f"Directory {item.name} has mode {mode}")

        # Check file permissions (should be 0640)
        for item in self.backup_dir.rglob("*full_config*"):
            if item.is_file():
                mode = oct(item.stat().st_mode)[-3:]
                if mode not in ["640", "644", "600"]:
                    issues.append(f"File {item.name} has mode {mode}")

        result["passed"] = len(issues) == 0
        result["details"]["issues"] = issues[:10]
        return result

    def check_disk_usage(self) -> dict:
        """Check available disk space."""
        result = {"check": "disk_usage", "passed": False, "details": {}}
        try:
            stat = os.statvfs(str(self.backup_dir))
            free_percent = (stat.f_frsize * stat.f_bfree) / (stat.f_frsize * stat.f_blocks) * 100
            result["passed"] = free_percent >= 20
            result["details"]["free_percent"] = round(free_percent, 1)
            result["details"]["free_bytes"] = stat.f_frsize * stat.f_bfree
            result["details"]["total_bytes"] = stat.f_frsize * stat.f_blocks
        except Exception as e:
            result["details"]["error"] = str(e)
        return result

    def check_git_health(self) -> dict:
        """Check git repository integrity."""
        result = {"check": "git_fsck", "passed": True, "details": {}}
        git_dir = self.backup_dir / ".git"

        if not git_dir.exists():
            result["passed"] = False
            result["details"]["error"] = "Not a git repository"
            return result

        try:
            fsck = subprocess.run(
                ["git", "fsck", "--no-dangling"],
                cwd=str(self.backup_dir),
                capture_output=True, text=True, timeout=30,
            )
            if fsck.returncode != 0:
                result["passed"] = False
                result["details"]["fsck_output"] = fsck.stdout + fsck.stderr
            else:
                result["details"]["fsck_output"] = "No errors found"
        except Exception as e:
            result["passed"] = False
            result["details"]["error"] = str(e)

        return result

    def check_ssh_key_age(self, key_path: str = None) -> dict:
        """Check age of SSH key used for backups."""
        result = {"check": "ssh_key_age", "passed": True, "details": {}}

        if key_path is None:
            key_path = os.path.expanduser("~/.ssh/fortigate-backup-key")

        if not os.path.exists(key_path):
            result["passed"] = False
            result["details"]["error"] = "SSH key not found"
            return result

        mtime = os.path.getmtime(key_path)
        age_days = (datetime.now() - datetime.fromtimestamp(mtime)).days
        result["details"]["key_age_days"] = age_days
        result["passed"] = age_days <= 90
        result["details"]["key_path"] = key_path

        return result

    def run_compliance_profile(self, profile: str) -> list[dict]:
        """Run all checks for a compliance profile."""
        rules = self._get_rules_for_profile(profile)
        results = []

        checks_map = {
            "backup_frequency_last_24h": lambda: self.check_backup_frequency("*"),
            "repository_permissions": self.check_repo_permissions,
            "disk_usage": self.check_disk_usage,
            "git_fsck": self.check_git_health,
            "ssh_key_age": self.check_ssh_key_age,
        }

        for rule in rules:
            check_name = rule.get("check")
            check_func = checks_map.get(check_name)

            if check_func:
                try:
                    check_result = check_func()
                except Exception as e:
                    check_result = {"check": check_name, "passed": False, "details": {"error": str(e)}}
            else:
                check_result = {"check": check_name, "passed": False, "details": {"error": "No check implementation"}}

            check_result["rule_id"] = rule.get("id")
            check_result["rule_name"] = rule.get("name")
            check_result["severity"] = rule.get("severity", "medium")
            results.append(check_result)

        return results

    def generate_report(self, results: list[dict]) -> str:
        """Generate compliance report."""
        total = len(results)
        passed = sum(1 for r in results if r.get("passed"))
        failed = total - passed

        report = []
        report.append("=" * 72)
        report.append("COMPLIANCE CHECK REPORT")
        report.append(f"Generated: {datetime.utcnow().isoformat()}")
        report.append(f"Backup Dir: {self.backup_dir}")
        report.append(f"Total Checks: {total}")
        report.append(f"Passed: {passed}")
        report.append(f"Failed: {failed}")
        report.append("=" * 72)

        for result in results:
            status = "PASS" if result.get("passed") else "FAIL"
            severity = result.get("severity", "N/A").upper()
            report.append(f"\n[{status}] [{severity}] {result.get('rule_id', 'N/A')}")
            report.append(f"  Rule: {result.get('rule_name', 'N/A')}")
            report.append(f"  Check: {result.get('check', 'N/A')}")

            details = result.get("details", {})
            for key, value in details.items():
                if isinstance(value, list) and len(value) > 3:
                    report.append(f"  {key}: {', '.join(str(v) for v in value[:3])}...")
                elif isinstance(value, str) and len(value) > 200:
                    report.append(f"  {key}: {value[:200]}...")
                else:
                    report.append(f"  {key}: {value}")

        return "\n".join(report)


def main():
    parser = argparse.ArgumentParser(
        description="FortiGate Backup Compliance Checker",
    )
    parser.add_argument("--rules", default="security/audit/audit_rules.yml", help="Audit rules file")
    parser.add_argument("--backup-dir", default="/opt/backups/fortigates", help="Backup directory")
    parser.add_argument("--profile", help="Compliance profile (standard/enhanced)")
    parser.add_argument("--all", action="store_true", help="Run all checks")
    parser.add_argument("--rule", help="Run specific rule by ID")
    parser.add_argument("--report", help="Output report to file")
    parser.add_argument("--json", help="Output JSON results to file")

    args = parser.parse_args()

    checker = ComplianceChecker(args.rules, args.backup_dir)

    if args.profile:
        results = checker.run_compliance_profile(args.profile)
    elif args.all:
        results = checker.run_compliance_profile("enhanced")
    elif args.rule:
        results = [{"rule_id": args.rule, "note": "Single rule execution not yet implemented"}]
    else:
        parser.print_help()
        sys.exit(1)

    if args.json:
        with open(args.json, "w") as f:
            json.dump(results, f, indent=2)
        print(f"JSON results written to {args.json}")

    report = checker.generate_report(results)
    if args.report:
        with open(args.report, "w") as f:
            f.write(report)
        print(f"Report written to {args.report}")
    else:
        print(report)

    failed = sum(1 for r in results if not r.get("passed"))
    sys.exit(1 if failed > 0 else 0)


if __name__ == "__main__":
    main()
