#!/usr/bin/env python3
"""
Report Generator for FortiGate Backup System

Generates comprehensive HTML and JSON reports of backup status,
validation results, and compliance posture.

Usage:
    python3 report_generator.py --backup-dir /opt/backups/fortigates --date 20250101
    python3 report_generator.py --backup-dir /opt/backups/fortigates --date 20250101 --format json
    python3 report_generator.py --backup-dir /opt/backups/fortigates --range 7d
    python3 report_generator.py --backup-dir /opt/backups/fortigates --date 20250101 --output /tmp/report.html
"""

import argparse
import json
import os
import sys
from datetime import datetime, timedelta
from pathlib import Path


class BackupReportGenerator:
    def __init__(self, backup_dir: str):
        self.backup_dir = Path(backup_dir)
        self.report_data = {}

    def generate_daily_report(self, date_str: str) -> dict:
        """Generate a report for a specific date."""
        report = {
            "report_type": "daily",
            "report_date": date_str,
            "generated_at": datetime.utcnow().isoformat(),
            "summary": {
                "total_devices": 0,
                "backed_up": 0,
                "failed": 0,
                "validation_passed": 0,
                "validation_failed": 0,
                "total_size_bytes": 0,
            },
            "devices": [],
        }

        manifest_path = self.backup_dir / f"manifest_{date_str}.json"
        if manifest_path.exists():
            try:
                devices = []
                with open(manifest_path) as f:
                    content = f.read().strip()
                    if content.endswith(","):
                        content = content[:-1]
                    content = f"[{content}]"
                    devices = json.loads(content)

                for device in devices:
                    hostname = device.get("hostname", "unknown")
                    status = device.get("backup_status", "unknown")

                    device_report = self._get_device_details(hostname, date_str, device)
                    report["devices"].append(device_report)

                    report["summary"]["total_devices"] += 1
                    if status == "success":
                        report["summary"]["backed_up"] += 1
                    else:
                        report["summary"]["failed"] += 1

                    report["summary"]["total_size_bytes"] += device.get("config_size_bytes", 0) or 0

            except (json.JSONDecodeError, Exception) as e:
                print(f"Error parsing manifest: {e}", file=sys.stderr)

        self.report_data = report
        return report

    def generate_range_report(self, days: int) -> dict:
        """Generate a report spanning multiple days."""
        report = {
            "report_type": "range",
            "range_days": days,
            "generated_at": datetime.utcnow().isoformat(),
            "summary": {
                "total_backups": 0,
                "successful_backups": 0,
                "failed_backups": 0,
                "unique_devices": set(),
                "total_size_bytes": 0,
            },
            "daily_reports": [],
        }

        for i in range(days):
            date = (datetime.utcnow() - timedelta(days=i)).strftime("%Y-%m-%d")
            daily = self.generate_daily_report(date)
            if daily["devices"]:
                daily_report = {
                    "date": date,
                    "summary": daily["summary"],
                    "device_count": len(daily["devices"]),
                }
                report["daily_reports"].append(daily_report)

                report["summary"]["total_backups"] += daily["summary"]["total_devices"]
                report["summary"]["successful_backups"] += daily["summary"]["backed_up"]
                report["summary"]["failed_backups"] += daily["summary"]["failed"]
                report["summary"]["total_size_bytes"] += daily["summary"]["total_size_bytes"]

        report["summary"]["unique_devices"] = list(report["summary"]["unique_devices"])

        return report

    def _get_device_details(self, hostname: str, date_str: str, manifest_entry: dict) -> dict:
        """Get detailed information for a device backup."""
        details = {
            "hostname": hostname,
            "serial": manifest_entry.get("serial", "N/A"),
            "model": manifest_entry.get("model", "N/A"),
            "firmware": manifest_entry.get("firmware", "N/A"),
            "role": manifest_entry.get("role", "N/A"),
            "region": manifest_entry.get("region", "N/A"),
            "location": manifest_entry.get("location", "N/A"),
            "backup_method": manifest_entry.get("backup_method", "N/A"),
            "backup_timestamp": manifest_entry.get("backup_timestamp", "N/A"),
            "config_size_bytes": manifest_entry.get("config_size_bytes", 0),
            "config_hash": manifest_entry.get("backup_hash_sha256", "N/A"),
            "backup_status": manifest_entry.get("backup_status", "unknown"),
        }

        validation_report_path = (
            self.backup_dir / hostname / date_str / "validation_report.json"
        )
        if validation_report_path.exists():
            try:
                with open(validation_report_path) as f:
                    validation = json.load(f)
                    details["validation"] = {
                        "valid": validation.get("valid", False),
                        "errors": validation.get("errors", []),
                        "warnings": validation.get("warnings", []),
                    }
            except (json.JSONDecodeError, Exception):
                details["validation"] = {"valid": False, "errors": ["Could not parse validation report"]}
        else:
            details["validation"] = None

        return details

    def to_html(self, report: dict) -> str:
        """Convert report to HTML format."""
        summary = report.get("summary", {})
        devices = report.get("devices", [])

        rows = ""
        for device in devices:
            status_color = {
                "success": "#27ae60",
                "failed": "#e74c3c",
                "pending": "#f39c12",
            }.get(device.get("backup_status", "unknown"), "#95a5a6")

            validation_badge = ""
            if device.get("validation"):
                val = device["validation"]
                val_color = "#27ae60" if val.get("valid") else "#e74c3c"
                val_text = "PASS" if val.get("valid") else "FAIL"
                validation_badge = f'<span style="background:{val_color};color:white;padding:2px 8px;border-radius:10px;font-size:11px;">{val_text}</span>'

            rows += f"""
            <tr>
                <td><strong>{device['hostname']}</strong></td>
                <td>{device.get('model', 'N/A')}</td>
                <td>{device.get('region', 'N/A')}</td>
                <td>{device.get('firmware', 'N/A')}</td>
                <td>{device.get('backup_method', 'N/A')}</td>
                <td>{device.get('config_size_bytes', 0):,} bytes</td>
                <td><span style="background:{status_color};color:white;padding:2px 8px;border-radius:10px;font-size:11px;">{device.get('backup_status', 'unknown').upper()}</span></td>
                <td style="text-align:center;">{validation_badge}</td>
            </tr>"""

        device_list = "\n".join(f"<li>{d['hostname']} ({d.get('model', 'N/A')}) - {d.get('backup_status', 'unknown')}</li>" for d in devices)

        html = f"""<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>FortiGate Backup Report - {report.get('report_date', 'N/A')}</title>
    <style>
        * {{ margin: 0; padding: 0; box-sizing: border-box; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; }}
        body {{ background: #f5f6fa; color: #2c3e50; padding: 20px; }}
        .container {{ max-width: 1200px; margin: 0 auto; }}
        .header {{ background: linear-gradient(135deg, #2c3e50, #3498db); color: white; padding: 30px; border-radius: 10px; margin-bottom: 20px; }}
        .header h1 {{ font-size: 24px; }}
        .header p {{ opacity: 0.9; margin-top: 5px; }}
        .stats {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 15px; margin-bottom: 20px; }}
        .stat-card {{ background: white; padding: 20px; border-radius: 10px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }}
        .stat-card .value {{ font-size: 32px; font-weight: bold; }}
        .stat-card .label {{ font-size: 13px; color: #7f8c8d; margin-top: 5px; }}
        table {{ width: 100%; border-collapse: collapse; background: white; border-radius: 10px; overflow: hidden; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }}
        th {{ background: #2c3e50; color: white; padding: 12px 15px; text-align: left; font-size: 12px; text-transform: uppercase; letter-spacing: 1px; }}
        td {{ padding: 12px 15px; border-bottom: 1px solid #ecf0f1; font-size: 13px; }}
        tr:hover {{ background: #f8f9fa; }}
        .footer {{ margin-top: 20px; padding: 15px; text-align: center; color: #95a5a6; font-size: 12px; }}
        .device-list {{ margin-top: 20px; background: white; border-radius: 10px; padding: 20px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }}
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>FortiGate Backup Report</h1>
            <p>Date: {report.get('report_date', 'N/A')} | Generated: {report.get('generated_at', 'N/A')}</p>
        </div>

        <div class="stats">
            <div class="stat-card" style="border-left: 4px solid #3498db;">
                <div class="value">{summary.get('total_devices', 0)}</div>
                <div class="label">Total Devices</div>
            </div>
            <div class="stat-card" style="border-left: 4px solid #27ae60;">
                <div class="value">{summary.get('backed_up', 0)}</div>
                <div class="label">Successful Backups</div>
            </div>
            <div class="stat-card" style="border-left: 4px solid #e74c3c;">
                <div class="value">{summary.get('failed', 0)}</div>
                <div class="label">Failed Backups</div>
            </div>
            <div class="stat-card" style="border-left: 4px solid #f39c12;">
                <div class="value">{summary.get('total_size_bytes', 0):,}</div>
                <div class="label">Total Size (bytes)</div>
            </div>
        </div>

        <table>
            <thead>
                <tr>
                    <th>Hostname</th>
                    <th>Model</th>
                    <th>Region</th>
                    <th>Firmware</th>
                    <th>Method</th>
                    <th>Size</th>
                    <th>Status</th>
                    <th style="text-align:center;">Validation</th>
                </tr>
            </thead>
            <tbody>
                {rows if rows else '<tr><td colspan="8" style="text-align:center;padding:30px;color:#95a5a6;">No backup data available for this date</td></tr>'}
            </tbody>
        </table>

        <div class="device-list">
            <h3 style="margin-bottom:10px;">Device Summary</h3>
            <ul style="columns:3;list-style:none;">
                {device_list if device_list else '<li>No devices</li>'}
            </ul>
        </div>

        <div class="footer">
            <p>FortiGate Backup System | Confidential - Internal Use Only</p>
        </div>
    </div>
</body>
</html>"""

        return html

    def write_report(self, report: dict, output_path: str, fmt: str = "html"):
        """Write report to file."""
        if fmt == "html":
            content = self.to_html(report)
        elif fmt == "json":
            content = json.dumps(report, indent=2, default=str)
        else:
            print(f"Unsupported format: {fmt}", file=sys.stderr)
            return False

        os.makedirs(os.path.dirname(output_path) or ".", exist_ok=True)
        with open(output_path, "w", encoding="utf-8") as f:
            f.write(content)

        return True


def main():
    parser = argparse.ArgumentParser(
        description="FortiGate Backup Report Generator",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--backup-dir", required=True, help="Backup directory path")
    parser.add_argument("--date", help="Report date (YYYY-MM-DD)")
    parser.add_argument("--range", help="Date range (e.g., 7d, 30d)")
    parser.add_argument("--format", choices=["html", "json"], default="html", help="Output format")
    parser.add_argument("--output", "-o", help="Output file path")

    args = parser.parse_args()

    generator = BackupReportGenerator(args.backup_dir)

    if args.date:
        report = generator.generate_daily_report(args.date)
        default_output = f"backup_report_{args.date}.{args.format}"
    elif args.range:
        days = int(args.range.rstrip("d"))
        report = generator.generate_range_report(days)
        default_output = f"backup_report_{days}d.{args.format}"
    else:
        date_str = datetime.utcnow().strftime("%Y-%m-%d")
        report = generator.generate_daily_report(date_str)
        default_output = f"backup_report_{date_str}.{args.format}"

    output_path = args.output or os.path.join(args.backup_dir, "reports", default_output)

    success = generator.write_report(report, output_path, args.format)
    if success:
        print(f"Report generated: {output_path}")
        print(f"  Devices: {report['summary'].get('total_devices', 0)}")
        print(f"  Success: {report['summary'].get('backed_up', 0)}")
        print(f"  Failed: {report['summary'].get('failed', 0)}")
    else:
        sys.exit(1)


if __name__ == "__main__":
    main()
