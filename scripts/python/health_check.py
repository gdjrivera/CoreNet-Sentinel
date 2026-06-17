#!/usr/bin/env python3
"""
FortiGate Health Checker

Performs comprehensive health checks on FortiGate devices
and the backup infrastructure.

Usage:
    python3 health_check.py --host 10.150.1.1 --port 443 --protocol https
    python3 health_check.py --host 10.150.1.1 --port 22 --protocol ssh
    python3 health_check.py --config /path/to/inventory.yml --all
    python3 health_check.py --prometheus-output /var/lib/node_exporter/fortigate.prom
"""

import argparse
import json
import os
import socket
import ssl
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path


class FortiGateHealthCheck:
    def __init__(self, host: str, port: int, protocol: str = "https", timeout: int = 30):
        self.host = host
        self.port = port
        self.protocol = protocol
        self.timeout = timeout
        self.results = {
            "host": host,
            "port": port,
            "protocol": protocol,
            "timestamp": datetime.utcnow().isoformat(),
            "checks": {},
            "overall_status": "unknown",
        }

    def run_all_checks(self) -> dict:
        """Run all health checks."""
        self.results["checks"]["connectivity"] = self._check_connectivity()
        self.results["checks"]["dns_resolution"] = self._check_dns()
        self.results["checks"]["tls_certificate"] = self._check_tls() if self.protocol == "https" else {"status": "skipped"}
        self.results["checks"]["port_open"] = self._check_port()
        self.results["checks"]["response_time"] = self._check_response_time()

        all_passed = all(
            c.get("status") == "pass" or c.get("status") == "skipped"
            for c in self.results["checks"].values()
        )
        self.results["overall_status"] = "pass" if all_passed else "fail"
        return self.results

    def _check_connectivity(self) -> dict:
        """Check basic TCP connectivity to the device."""
        result = {"status": "pass", "details": {}}
        try:
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.settimeout(self.timeout)
            start = time.time()
            sock.connect((self.host, self.port))
            latency = time.time() - start
            sock.close()
            result["details"]["latency_ms"] = round(latency * 1000, 2)
            result["details"]["message"] = f"Connected to {self.host}:{self.port} in {latency*1000:.1f}ms"
        except socket.timeout:
            result["status"] = "fail"
            result["details"]["error"] = f"Connection timed out after {self.timeout}s"
        except socket.error as e:
            result["status"] = "fail"
            result["details"]["error"] = str(e)
        return result

    def _check_dns(self) -> dict:
        """Verify DNS resolution for the host."""
        result = {"status": "pass", "details": {}}
        try:
            resolved = socket.gethostbyname(self.host)
            result["details"]["resolved_ip"] = resolved
            result["details"]["message"] = f"DNS resolved {self.host} -> {resolved}"

            hostname, _, _ = socket.gethostbyaddr(resolved)
            result["details"]["ptr_record"] = hostname
        except socket.gaierror:
            result["status"] = "warn"
            result["details"]["error"] = f"Cannot resolve {self.host} - using IP directly"
        except socket.herror:
            result["details"]["ptr_record"] = "No PTR record"
        return result

    def _check_tls(self) -> dict:
        """Check TLS certificate validity and strength."""
        result = {"status": "pass", "details": {}}
        try:
            context = ssl.create_default_context()
            context.check_hostname = True
            context.verify_mode = ssl.CERT_REQUIRED

            with socket.create_connection((self.host, self.port), timeout=self.timeout) as sock:
                with context.wrap_socket(sock, server_hostname=self.host) as tls:
                    cert = tls.getpeercert()
                    result["details"]["tls_version"] = tls.version()
                    result["details"]["cipher"] = tls.cipher()

                    if cert:
                        not_after = cert.get("notAfter", "unknown")
                        not_before = cert.get("notBefore", "unknown")
                        result["details"]["cert_subject"] = dict(cert.get("subject", []))
                        result["details"]["cert_issuer"] = dict(cert.get("issuer", []))
                        result["details"]["cert_expiry"] = not_after

            if tls.version() in ["TLSv1", "TLSv1.1"]:
                result["status"] = "warn"
                result["details"]["warning"] = f"Outdated TLS version: {tls.version()}"

        except ssl.SSLError as e:
            result["status"] = "fail"
            result["details"]["error"] = f"SSL Error: {e}"
        except Exception as e:
            result["status"] = "fail"
            result["details"]["error"] = str(e)

        return result

    def _check_port(self) -> dict:
        """Verify the specific port is open and responding."""
        result = {"status": "pass", "details": {}}
        try:
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.settimeout(5)
            result_code = sock.connect_ex((self.host, self.port))
            sock.close()

            if result_code == 0:
                result["details"]["port_status"] = "open"
            else:
                result["status"] = "fail"
                result["details"]["port_status"] = f"closed (error: {result_code})"
        except Exception as e:
            result["status"] = "fail"
            result["details"]["error"] = str(e)
        return result

    def _check_response_time(self) -> dict:
        """Measure response time over multiple attempts."""
        result = {"status": "pass", "details": {}}
        times = []

        for i in range(3):
            try:
                sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                sock.settimeout(self.timeout)
                start = time.perf_counter()
                sock.connect((self.host, self.port))
                elapsed = time.perf_counter() - start
                sock.close()
                times.append(elapsed * 1000)
            except Exception:
                pass

        if times:
            result["details"]["avg_response_ms"] = round(sum(times) / len(times), 2)
            result["details"]["min_response_ms"] = round(min(times), 2)
            result["details"]["max_response_ms"] = round(max(times), 2)
            result["details"]["samples"] = len(times)

            if result["details"]["avg_response_ms"] > 500:
                result["status"] = "warn"
                result["details"]["warning"] = f"High latency: {result['details']['avg_response_ms']}ms average"
        else:
            result["status"] = "fail"
            result["details"]["error"] = "No successful connections for timing"

        return result

    def to_prometheus(self) -> str:
        """Output health check results in Prometheus format."""
        lines = [
            "# HELP fortigate_health_check FortiGate health check status",
            "# TYPE fortigate_health_check gauge",
        ]

        for check_name, check_result in self.results["checks"].items():
            status_value = 1 if check_result.get("status") == "pass" else 0
            latency = check_result.get("details", {}).get("latency_ms", 0)
            lines.append(
                f'fortigate_health_check{{host="{self.host}",check="{check_name}",status="{check_result.get("status", "unknown")}"}} {status_value}'
            )
            if latency:
                lines.append(
                    f'fortigate_latency_ms{{host="{self.host}",check="{check_name}"}} {latency}'
                )

        lines.append(f'# HELP fortigate_overall_status Overall health status (1=healthy)')
        lines.append(f'# TYPE fortigate_overall_status gauge')
        overall = 1 if self.results["overall_status"] == "pass" else 0
        lines.append(f'fortigate_overall_status{{host="{self.host}"}} {overall}')

        lines.append(f'# HELP fortigate_health_timestamp Last health check timestamp')
        lines.append(f'# TYPE fortigate_health_timestamp gauge')
        lines.append(f'fortigate_health_timestamp{{host="{self.host}"}} {int(time.time())}')

        return "\n".join(lines) + "\n"


def check_backup_infrastructure(backup_dir: str) -> dict:
    """Check the health of the backup infrastructure itself."""
    results = {
        "backup_directory": {"status": "unknown", "details": {}},
        "disk_space": {"status": "unknown", "details": {}},
        "git_repository": {"status": "unknown", "details": {}},
        "database": {"status": "unknown", "details": {}},
    }

    backup_path = Path(backup_dir)

    # Check backup directory
    if backup_path.exists():
        results["backup_directory"]["status"] = "pass"
        results["backup_directory"]["details"]["path"] = str(backup_path)
        results["backup_directory"]["details"]["writable"] = os.access(backup_path, os.W_OK)

        try:
            total, used, free = subprocess.check_output(
                ["df", "-B1", str(backup_path)]
            ).decode().split("\n")[1].split()[1:4]
            results["disk_space"]["status"] = "pass"
            results["disk_space"]["details"]["total_bytes"] = int(total)
            results["disk_space"]["details"]["used_bytes"] = int(used)
            results["disk_space"]["details"]["free_bytes"] = int(free)
            results["disk_space"]["details"]["usage_percent"] = round(int(used) / int(total) * 100, 1)

            if results["disk_space"]["details"]["usage_percent"] > 90:
                results["disk_space"]["status"] = "critical"
            elif results["disk_space"]["details"]["usage_percent"] > 80:
                results["disk_space"]["status"] = "warn"
        except (subprocess.CalledProcessError, IndexError, ValueError):
            results["disk_space"]["status"] = "warn"
            results["disk_space"]["details"]["error"] = "Could not check disk space"
    else:
        results["backup_directory"]["status"] = "fail"
        results["backup_directory"]["details"]["error"] = f"Directory not found: {backup_path}"

    # Check git repository
    git_dir = backup_path / ".git"
    if git_dir.exists():
        try:
            status = subprocess.run(
                ["git", "status", "--porcelain"],
                cwd=str(backup_path), capture_output=True, text=True, timeout=10
            )
            results["git_repository"]["status"] = "pass"
            results["git_repository"]["details"]["uncommitted_changes"] = len(status.stdout.splitlines())
            results["git_repository"]["details"]["last_commit"] = subprocess.run(
                ["git", "log", "-1", "--format=%H %ci", "HEAD"],
                cwd=str(backup_path), capture_output=True, text=True, timeout=5
            ).stdout.strip()
        except (subprocess.CalledProcessError, Exception) as e:
            results["git_repository"]["status"] = "warn"
            results["git_repository"]["details"]["error"] = str(e)
    else:
        results["git_repository"]["status"] = "warn"
        results["git_repository"]["details"]["error"] = "Not a git repository"

    # Check database
    db_path = backup_path / ".." / "data" / "backup_metadata.db"
    if db_path.exists():
        results["database"]["status"] = "pass"
        results["database"]["details"]["path"] = str(db_path)
        results["database"]["details"]["size_bytes"] = db_path.stat().st_size
    else:
        results["database"]["status"] = "warn"
        results["database"]["details"]["error"] = "Database not found"

    return results


def main():
    parser = argparse.ArgumentParser(
        description="FortiGate Infrastructure Health Checker",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--host", help="FortiGate hostname/IP")
    parser.add_argument("--port", type=int, default=443, help="Port number")
    parser.add_argument("--protocol", choices=["https", "ssh"], default="https", help="Connection protocol")
    parser.add_argument("--timeout", type=int, default=30, help="Connection timeout")
    parser.add_argument("--backup-dir", help="Check backup infrastructure health")
    parser.add_argument("--prometheus-output", help="Output Prometheus metrics to file")
    parser.add_argument("--output", "-o", help="Output JSON results to file")
    parser.add_argument("--all", action="store_true", help="Check all devices from inventory")

    args = parser.parse_args()

    if args.backup_dir:
        results = check_backup_infrastructure(args.backup_dir)
        print(json.dumps(results, indent=2, default=str))
        sys.exit(0)

    if not args.host and not args.all:
        parser.print_help()
        sys.exit(1)

    if args.host:
        checker = FortiGateHealthCheck(
            host=args.host,
            port=args.port,
            protocol=args.protocol,
            timeout=args.timeout,
        )
        results = checker.run_all_checks()

        if args.prometheus_output:
            prom_data = checker.to_prometheus()
            path = Path(args.prometheus_output)
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(prom_data)
            print(f"Prometheus metrics written to {args.prometheus_output}")
        elif args.output:
            path = Path(args.output)
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps(results, indent=2, default=str))
            print(f"Results written to {args.output}")
        else:
            print(f"\nHealth Check Results for {args.host}:{args.port}")
            print(f"  Overall Status: {results['overall_status'].upper()}")
            for check_name, check_result in results["checks"].items():
                status_icon = {"pass": "✓", "fail": "✗", "warn": "⚠", "skipped": "→"}
                icon = status_icon.get(check_result.get("status", "unknown"), "?")
                print(f"  [{icon}] {check_name}: {check_result.get('status', 'unknown').upper()}")
                for key, value in check_result.get("details", {}).items():
                    print(f"       {key}: {value}")

        sys.exit(0 if results["overall_status"] == "pass" else 1)


if __name__ == "__main__":
    main()
