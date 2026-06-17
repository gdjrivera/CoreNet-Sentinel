#!/usr/bin/env python3
"""
Ansible Prometheus Exporter for FortiGate Backup

Exports Ansible playbook metrics to Prometheus via
the textfile collector or pushgateway.

Usage:
    # Textfile collector mode
    python3 ansible_exporter.py --textfile /var/lib/node_exporter/textfile/ansible.prom

    # Pushgateway mode
    python3 ansible_exporter.py --pushgateway http://pushgateway:9091 --job fortigate_backup
"""

import argparse
import json
import os
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path
from typing import Optional


class AnsibleMetricsExporter:
    def __init__(self, backup_dir: str, ansible_dir: str):
        self.backup_dir = Path(backup_dir)
        self.ansible_dir = Path(ansible_dir)
        self.metrics = []

    def collect_backup_metrics(self) -> list[str]:
        """Collect metrics about backup files."""
        metrics = []
        total_size = 0
        total_files = 0
        devices_found = set()

        for config_file in self.backup_dir.rglob("*full_config*"):
            if config_file.is_file():
                size = config_file.stat().st_size
                total_size += size
                total_files += 1
                devices_found.add(config_file.parent.parent.name)

                mtime = config_file.stat().st_mtime
                metrics.append(
                    f'fortigate_backup_file_size{{hostname="{config_file.parent.parent.name}",file="{config_file.name}"}} {size}'
                )
                metrics.append(
                    f'fortigate_backup_file_mtime{{hostname="{config_file.parent.parent.name}",file="{config_file.name}"}} {mtime}'
                )

        metrics.append(f'fortigate_backup_total_files {total_files}')
        metrics.append(f'fortigate_backup_total_size_bytes {total_size}')
        metrics.append(f'fortigate_backup_unique_devices {len(devices_found)}')

        return metrics

    def collect_git_metrics(self) -> list[str]:
        """Collect metrics about git repository health."""
        metrics = []
        git_dir = self.backup_dir / ".git"

        if not git_dir.exists():
            metrics.append('fortigate_git_health{status="no_repo"} 0')
            return metrics

        try:
            result = subprocess.run(
                ["git", "log", "--oneline", "-1"],
                cwd=str(self.backup_dir),
                capture_output=True, text=True, timeout=10,
            )
            last_commit = result.stdout.strip()
            metrics.append(f'fortigate_git_last_commit_timestamp {time.time()}')

            result = subprocess.run(
                ["git", "rev-list", "--count", "HEAD"],
                cwd=str(self.backup_dir),
                capture_output=True, text=True, timeout=10,
            )
            commit_count = int(result.stdout.strip())
            metrics.append(f'fortigate_git_total_commits {commit_count}')

            result = subprocess.run(
                ["git", "status", "--porcelain"],
                cwd=str(self.backup_dir),
                capture_output=True, text=True, timeout=10,
            )
            dirty_files = len([l for l in result.stdout.splitlines() if l.strip()])
            metrics.append(f'fortigate_git_dirty_files {dirty_files}')

            metrics.append('fortigate_git_health{status="healthy"} 1')

        except subprocess.TimeoutExpired:
            metrics.append('fortigate_git_health{status="timeout"} 0')
        except Exception as e:
            metrics.append(f'fortigate_git_health{{status="error"}} 0')

        return metrics

    def collect_disk_metrics(self) -> list[str]:
        """Collect disk usage metrics for backup directory."""
        metrics = []

        try:
            stat = os.statvfs(str(self.backup_dir))
            total = stat.f_frsize * stat.f_blocks
            free = stat.f_frsize * stat.f_bfree
            used = total - free
            percent = (used / total) * 100

            metrics.append(f'fortigate_backup_disk_total_bytes {total}')
            metrics.append(f'fortigate_backup_disk_used_bytes {used}')
            metrics.append(f'fortigate_backup_disk_free_bytes {free}')
            metrics.append(f'fortigate_backup_disk_usage_percent {percent:.1f}')
        except Exception:
            pass

        return metrics

    def collect_validation_metrics(self) -> list[str]:
        """Collect metrics from validation reports."""
        metrics = []
        today = datetime.utcnow().strftime("%Y-%m-%d")

        for device_dir in self.backup_dir.iterdir():
            if not device_dir.is_dir() or device_dir.name.startswith("."):
                continue

            validation_file = device_dir / today / "validation_report.json"
            if validation_file.exists():
                try:
                    with open(validation_file) as f:
                        report = json.load(f)
                    valid = 1 if report.get("valid") else 0
                    errors = len(report.get("errors", []))
                    warnings = len(report.get("warnings", []))

                    metrics.append(
                        f'fortigate_validation_status{{hostname="{device_dir.name}"}} {valid}'
                    )
                    metrics.append(
                        f'fortigate_validation_errors{{hostname="{device_dir.name}"}} {errors}'
                    )
                    metrics.append(
                        f'fortigate_validation_warnings{{hostname="{device_dir.name}"}} {warnings}'
                    )
                except (json.JSONDecodeError, Exception):
                    pass

        return metrics

    def collect_metadata_metrics(self, db_path: Optional[str] = None) -> list[str]:
        """Collect metrics from metadata database."""
        metrics = []

        if db_path and Path(db_path).exists():
            try:
                import sqlite3
                conn = sqlite3.connect(db_path)
                cursor = conn.cursor()

                cursor.execute("SELECT COUNT(*) FROM device_backups WHERE backup_status='success' AND backup_date >= date('now', '-7 days')")
                success_7d = cursor.fetchone()[0]

                cursor.execute("SELECT COUNT(*) FROM device_backups WHERE backup_status='failed' AND backup_date >= date('now', '-7 days')")
                failed_7d = cursor.fetchone()[0]

                cursor.execute("SELECT COUNT(DISTINCT hostname) FROM device_backups WHERE backup_date >= date('now', '-7 days')")
                active_devices = cursor.fetchone()[0]

                metrics.append(f'fortigate_backups_7d_success {success_7d}')
                metrics.append(f'fortigate_backups_7d_failed {failed_7d}')
                metrics.append(f'fortigate_backups_7d_total {success_7d + failed_7d}')
                metrics.append(f'fortigate_backups_active_devices_7d {active_devices}')

                if (success_7d + failed_7d) > 0:
                    success_rate = (success_7d / (success_7d + failed_7d)) * 100
                    metrics.append(f'fortigate_backups_7d_success_rate {success_rate:.1f}')

                conn.close()
            except Exception:
                pass

        return metrics

    def export_textfile(self, output_path: str):
        """Export metrics in Prometheus textfile format."""
        timestamp = int(time.time())

        all_metrics = [
            "# HELP fortigate_backup_metrics FortiGate backup system metrics",
            "# TYPE fortigate_backup_metrics gauge",
            f"fortigate_backup_collector_timestamp {timestamp}",
            "",
        ]

        collectors = [
            ("backup", self.collect_backup_metrics),
            ("git", self.collect_git_metrics),
            ("disk", self.collect_disk_metrics),
            ("validation", self.collect_validation_metrics),
            ("metadata", lambda: self.collect_metadata_metrics(
                str(self.backup_dir.parent / "data" / "backup_metadata.db")
            )),
        ]

        for name, collector in collectors:
            try:
                metrics = collector()
                if metrics:
                    all_metrics.append(f"# === {name.upper()} METRICS ===")
                    all_metrics.extend(metrics)
                    all_metrics.append("")
            except Exception as e:
                all_metrics.append(f"# ERROR collecting {name} metrics: {e}")

        output = "\n".join(all_metrics) + "\n"
        Path(output_path).parent.mkdir(parents=True, exist_ok=True)
        Path(output_path).write_text(output)

        print(f"Metrics written to {output_path} ({len(all_metrics)} lines)")


def main():
    parser = argparse.ArgumentParser(
        description="FortiGate Backup Prometheus Exporter",
    )
    parser.add_argument("--backup-dir", default="/opt/backups/fortigates")
    parser.add_argument("--ansible-dir", default="/opt/fortigate-backup/ansible")
    parser.add_argument("--textfile", default="/var/lib/node_exporter/textfile/fortigate_backup.prom")
    parser.add_argument("--pushgateway", help="Pushgateway URL")

    args = parser.parse_args()

    exporter = AnsibleMetricsExporter(args.backup_dir, args.ansible_dir)

    if args.pushgateway:
        import requests
        metrics = "\n".join(exporter.collect_backup_metrics())
        resp = requests.post(
            f"{args.pushgateway}/metrics/job/fortigate_backup",
            data=metrics,
            timeout=30,
        )
        resp.raise_for_status()
        print(f"Metrics pushed to {args.pushgateway}")
    else:
        exporter.export_textfile(args.textfile)


if __name__ == "__main__":
    main()
