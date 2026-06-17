#!/usr/bin/env python3
"""
Secrets Scanner for FortiGate Configurations

Scans configuration files for exposed secrets, keys, passwords,
and sensitive data patterns. Integrates with git pre-commit hooks
and CI/CD pipelines to prevent credential leakage.

Usage:
    # Scan a single file
    python3 secrets_scanner.py --file /path/to/config.conf

    # Scan directory recursively
    python3 secrets_scanner.py --dir /opt/backups/fortigates

    # Scan with git diff (only changed lines)
    python3 secrets_scanner.py --git-diff HEAD~1

    # CI/CD mode (exit with error if secrets found)
    python3 secrets_scanner.py --dir /backups --ci-mode

    # Generate SARIF report for GitHub Advanced Security
    python3 secrets_scanner.py --dir /backups --sarif-output results.sarif
"""

import argparse
import hashlib
import json
import os
import re
import sys
from datetime import datetime
from pathlib import Path


class SecretsScanner:
    SECRET_PATTERNS = [
        # FortiGate specific
        (r"set\s+(password|passwd|psksecret|pre-shared-key)\s+[\"']?([^\"'\s]{4,})[\"']?", "FortiGate Password/PSK"),
        (r"set\s+(private-key|key|secret|api-key|api-token)\s+[\"']?([^\"'\s]{8,})[\"']?", "FortiGate Private Key/Secret"),
        (r"(community|auth-password|priv-password)\s+[\"']?([^\"'\s]{4,})[\"']?", "SNMP Community/String"),
        (r"set\s+(hapassword|ha-password)\s+[\"']?([^\"'\s]{4,})[\"']?", "HA Password"),
        (r"set\s+(ldap-password|radius-secret|tacacs-key)\s+[\"']?([^\"'\s]{4,})[\"']?", "AAA Secret"),

        # Generic secrets
        (r"(?:api[_\-]?key|apikey|api_secret|apiSecret)\s*[:=]\s*[\"']?([A-Za-z0-9_\-=]{16,})[\"']?", "API Key"),
        (r"(?:secret|token|bearer|auth_token)\s*[:=]\s*[\"']?([A-Za-z0-9_\-\.=]{16,})[\"']?", "Generic Secret/Token"),
        (r"(?:password|passwd|pwd)\s*[:=]\s*[\"']?([^\"'\s]{6,})[\"']?", "Generic Password"),
        (r"(?:ssh-rsa|ssh-ed25519|-----BEGIN\s+(?:RSA|EC|OPENSSH)\s+PRIVATE\s+KEY-----)", "SSH Private Key"),
        (r"(?:-----BEGIN\s+CERTIFICATE-----)", "Certificate"),
        (r"(?:-----BEGIN\s+PGP\s+PRIVATE\s+KEY\s+BLOCK-----)", "PGP Private Key"),

        # AWS/Azure/GCP
        (r"(?:AKIA[0-9A-Z]{16})", "AWS Access Key"),
        (r"(?:eyJ[a-zA-Z0-9_\-]{10,}\.[a-zA-Z0-9_\-]{10,}\.[a-zA-Z0-9_\-]{10,})", "JWT Token"),
        (r"(?:ghp_[a-zA-Z0-9]{36})", "GitHub Personal Access Token"),
        (r"(?:gho_[a-zA-Z0-9]{36})", "GitHub OAuth Token"),
        (r"(?:xox[baprs]-[a-zA-Z0-9]{10,})", "Slack Token"),
        (r"(?:sk-[a-zA-Z0-9]{32,})", "OpenAI API Key"),
    ]

    ENTROPY_THRESHOLD = 4.5

    def __init__(self, ci_mode: bool = False):
        self.ci_mode = ci_mode
        self.findings = []
        self.excluded_paths = {".git", "__pycache__", "node_modules", ".git-crypt"}

    def scan_file(self, filepath: Path) -> list[dict]:
        """Scan a single file for secrets."""
        if any(excluded in filepath.parts for excluded in self.excluded_paths):
            return []

        if filepath.suffix in {".pyc", ".pyo", ".o", ".so", ".dll", ".exe"}:
            return []

        findings = []

        try:
            content = filepath.read_text(encoding="utf-8", errors="replace")
        except Exception:
            return []

        lines = content.split("\n")
        for line_num, line in enumerate(lines, 1):
            stripped = line.strip()
            if not stripped or stripped.startswith("#") or stripped.startswith("//"):
                continue

            for pattern, description in self.SECRET_PATTERNS:
                matches = re.finditer(pattern, stripped, re.IGNORECASE)
                for match in matches:
                    context = self._get_context(lines, line_num)
                    entropy = self._calculate_entropy(match.group())

                    finding = {
                        "file": str(filepath),
                        "line": line_num,
                        "pattern": description,
                        "match_preview": self._mask_secret(match.group()),
                        "entropy": round(entropy, 2),
                        "context": context,
                        "severity": "critical" if entropy > 5.0 else "high" if entropy > self.ENTROPY_THRESHOLD else "medium",
                        "timestamp": datetime.utcnow().isoformat(),
                    }
                    findings.append(finding)

        return findings

    def scan_directory(self, directory: Path) -> list[dict]:
        """Recursively scan a directory for secrets."""
        all_findings = []
        files_scanned = 0

        for root, _, files in os.walk(directory):
            root_path = Path(root)
            if any(excluded in root_path.parts for excluded in self.excluded_paths):
                continue

            for filename in files:
                filepath = root_path / filename
                if filepath.stat().st_size > 10_485_760:  # Skip files >10MB
                    continue

                findings = self.scan_file(filepath)
                if findings:
                    all_findings.extend(findings)
                files_scanned += 1

        return all_findings

    def scan_git_diff(self, git_ref: str, repo_path: str = ".") -> list[dict]:
        """Scan lines changed in a git diff for secrets."""
        import subprocess

        result = subprocess.run(
            ["git", "diff", "--unified=0", git_ref],
            capture_output=True, text=True, cwd=repo_path,
        )

        if result.returncode != 0:
            print(f"Error running git diff: {result.stderr}", file=sys.stderr)
            return []

        findings = []
        current_file = None
        diff_lines = result.stdout.split("\n")

        for line in diff_lines:
            if line.startswith("+++ b/"):
                current_file = line[6:]
            elif line.startswith("+") and not line.startswith("+++"):
                stripped = line[1:].strip()
                for pattern, description in self.SECRET_PATTERNS:
                    if re.search(pattern, stripped, re.IGNORECASE):
                        findings.append({
                            "file": current_file,
                            "pattern": description,
                            "match_preview": self._mask_secret(stripped),
                            "source": "git_diff",
                            "git_ref": git_ref,
                        })

        return findings

    def _get_context(self, lines: list[str], line_num: int, context_lines: int = 2) -> list[str]:
        """Get surrounding context lines for a finding."""
        start = max(0, line_num - 1 - context_lines)
        end = min(len(lines), line_num + context_lines)
        return [f"{i+1}:{lines[i]}" for i in range(start, end)]

    def _calculate_entropy(self, data: str) -> float:
        """Calculate Shannon entropy of a string."""
        if not data:
            return 0.0

        entropy = 0.0
        size = len(data)
        for char in set(data):
            probability = data.count(char) / size
            if probability > 0:
                entropy -= probability * (probability and (probability ** 0.5).real)

        if not entropy:
            import math
            for char in set(data):
                probability = data.count(char) / size
                if probability > 0:
                    entropy -= probability * math.log2(probability)

        return entropy

    def _mask_secret(self, secret: str, visible_chars: int = 4) -> str:
        """Mask sensitive portions of a secret for safe display."""
        if len(secret) <= visible_chars * 2:
            return secret[:visible_chars] + "****" if len(secret) > visible_chars else secret

        return secret[:visible_chars] + "*" * (len(secret) - visible_chars * 2) + secret[-visible_chars:]

    def generate_report(self, findings: list[dict], output_format: str = "text") -> str:
        """Generate a formatted report of findings."""
        if not findings:
            return "No secrets found.\n"

        if output_format == "json":
            report = {
                "scan_timestamp": datetime.utcnow().isoformat(),
                "total_findings": len(findings),
                "severity_summary": {
                    "critical": sum(1 for f in findings if f.get("severity") == "critical"),
                    "high": sum(1 for f in findings if f.get("severity") == "high"),
                    "medium": sum(1 for f in findings if f.get("severity") == "medium"),
                },
                "findings": findings,
            }
            return json.dumps(report, indent=2)

        lines = []
        lines.append("=" * 72)
        lines.append("SECRETS SCAN REPORT")
        lines.append(f"Timestamp: {datetime.utcnow().isoformat()}")
        lines.append(f"Total Findings: {len(findings)}")
        lines.append(f"Severity: Critical={sum(1 for f in findings if f.get('severity')=='critical')} "
                      f"High={sum(1 for f in findings if f.get('severity')=='high')} "
                      f"Medium={sum(1 for f in findings if f.get('severity')=='medium')}")
        lines.append("=" * 72)

        for idx, finding in enumerate(findings, 1):
            lines.append(f"\n[{idx}] {finding['pattern']} ({finding.get('severity', 'N/A').upper()})")
            lines.append(f"     File: {finding['file']}:{finding.get('line', '?')}")
            lines.append(f"     Match: {finding['match_preview']}")
            lines.append(f"     Entropy: {finding.get('entropy', 'N/A')}")

        return "\n".join(lines)

    def generate_sarif(self, findings: list[dict]) -> str:
        """Generate SARIF format for GitHub Advanced Security."""
        sarif_runs = []
        for finding in findings:
            sarif_runs.append({
                "tool": {
                    "driver": {
                        "name": "fortigate-secrets-scanner",
                        "informationUri": "https://internal.local/fortigate-backup",
                    }
                },
                "results": [{
                    "ruleId": finding["pattern"],
                    "level": finding.get("severity", "error"),
                    "message": {"text": f"Secret detected: {finding['pattern']}"},
                    "locations": [{
                        "physicalLocation": {
                            "artifactLocation": {"uri": finding["file"]},
                            "region": {
                                "startLine": finding.get("line", 0),
                            }
                        }
                    }],
                }],
            })

        return json.dumps({"$schema": "https://raw.githubusercontent.com/oasis-tcs/sarif-spec/master/Schemata/sarif-schema-2.1.0.json", "runs": sarif_runs}, indent=2)


def main():
    parser = argparse.ArgumentParser(
        description="FortiGate Configuration Secrets Scanner",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--file", help="Scan a single file")
    parser.add_argument("--dir", help="Scan a directory recursively")
    parser.add_argument("--git-diff", help="Scan git diff (e.g., HEAD~1)")
    parser.add_argument("--ci-mode", action="store_true", help="Exit with error code if secrets found")
    parser.add_argument("--sarif-output", help="Output SARIF report to file")
    parser.add_argument("--output", "-o", help="Output report to file")
    parser.add_argument("--format", choices=["text", "json"], default="text", help="Output format")

    args = parser.parse_args()

    scanner = SecretsScanner(ci_mode=args.ci_mode)
    findings = []

    if args.file:
        findings = scanner.scan_file(Path(args.file))
    elif args.dir:
        findings = scanner.scan_directory(Path(args.dir))
    elif args.git_diff:
        findings = scanner.scan_git_diff(args.git_diff)
    else:
        parser.print_help()
        sys.exit(1)

    if args.sarif_output:
        sarif = scanner.generate_sarif(findings)
        Path(args.sarif_output).write_text(sarif)

    report = scanner.generate_report(findings, output_format=args.format)

    if args.output:
        Path(args.output).write_text(report)
        print(f"Report written to {args.output}")
    else:
        print(report)

    if args.ci_mode and findings:
        print(f"\n[CI MODE] Found {len(findings)} secrets - blocking pipeline")
        sys.exit(1)


if __name__ == "__main__":
    main()
