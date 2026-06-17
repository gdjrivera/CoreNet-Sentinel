#!/usr/bin/env python3
"""
Metadata Logger for FortiGate Backup System

Records backup metadata to PostgreSQL for auditing,
reporting, and historical tracking.

Schema:
    - device_backups (hostname, serial, model, firmware, timestamp, hash, size, status)
    - backup_audit_log (action, user, device, timestamp, details)
    - compliance_records (device, check_type, passed, details, timestamp)

Usage:
    python3 metadata_logger.py --record-backup --hostname FGT-01 --serial FG123 --status success
    python3 metadata_logger.py --audit-log --action restore --user admin --device FGT-01
    python3 metadata_logger.py --query --hostname FGT-01 --last 30
"""

import argparse
import json
import os
import sqlite3
import sys
from datetime import datetime, timedelta
from pathlib import Path


class BackupMetadataLogger:
    def __init__(self, db_path: str = None):
        if db_path is None:
            db_path = os.environ.get(
                "BACKUP_METADATA_DB",
                str(Path(__file__).parent.parent.parent / "data" / "backup_metadata.db"),
            )

        self.db_path = db_path
        os.makedirs(os.path.dirname(self.db_path) or ".", exist_ok=True)
        self._init_database()

    def _init_database(self):
        """Initialize SQLite database schema."""
        conn = sqlite3.connect(self.db_path)
        cursor = conn.cursor()

        # Device backups table
        cursor.execute("""
            CREATE TABLE IF NOT EXISTS device_backups (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                hostname TEXT NOT NULL,
                serial TEXT,
                model TEXT,
                firmware TEXT,
                role TEXT,
                region TEXT,
                location TEXT,
                backup_timestamp TEXT NOT NULL,
                backup_date TEXT NOT NULL,
                backup_time TEXT NOT NULL,
                backup_method TEXT,
                config_hash_sha256 TEXT,
                config_size_bytes INTEGER,
                backup_status TEXT NOT NULL,
                backup_file_path TEXT,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                UNIQUE(hostname, backup_timestamp)
            )
        """)

        # Audit log table
        cursor.execute("""
            CREATE TABLE IF NOT EXISTS backup_audit_log (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                action TEXT NOT NULL,
                user_name TEXT NOT NULL,
                device_hostname TEXT,
                details TEXT,
                ip_address TEXT,
                status TEXT,
                timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            )
        """)

        # Compliance records table
        cursor.execute("""
            CREATE TABLE IF NOT EXISTS compliance_records (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                device_hostname TEXT NOT NULL,
                check_type TEXT NOT NULL,
                passed INTEGER NOT NULL,
                details TEXT,
                score REAL,
                check_timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            )
        """)

        # Backup summary table
        cursor.execute("""
            CREATE TABLE IF NOT EXISTS backup_summary (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                backup_date TEXT NOT NULL,
                total_devices INTEGER NOT NULL,
                successful_devices INTEGER NOT NULL,
                failed_devices INTEGER NOT NULL,
                total_size_bytes INTEGER,
                duration_seconds INTEGER,
                summary_timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            )
        """)

        # Indexes for performance
        cursor.execute("CREATE INDEX IF NOT EXISTS idx_backups_hostname ON device_backups(hostname)")
        cursor.execute("CREATE INDEX IF NOT EXISTS idx_backups_date ON device_backups(backup_date)")
        cursor.execute("CREATE INDEX IF NOT EXISTS idx_backups_status ON device_backups(backup_status)")
        cursor.execute("CREATE INDEX IF NOT EXISTS idx_audit_action ON backup_audit_log(action)")
        cursor.execute("CREATE INDEX IF NOT EXISTS idx_audit_timestamp ON backup_audit_log(timestamp)")

        conn.commit()
        conn.close()

    def record_backup(self, metadata: dict) -> bool:
        """Record a device backup entry."""
        try:
            conn = sqlite3.connect(self.db_path)
            cursor = conn.cursor()

            cursor.execute("""
                INSERT OR REPLACE INTO device_backups
                (hostname, serial, model, firmware, role, region, location,
                 backup_timestamp, backup_date, backup_time, backup_method,
                 config_hash_sha256, config_size_bytes, backup_status, backup_file_path)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, (
                metadata.get("hostname"),
                metadata.get("serial"),
                metadata.get("model"),
                metadata.get("firmware"),
                metadata.get("role"),
                metadata.get("region"),
                metadata.get("location"),
                metadata.get("backup_timestamp"),
                metadata.get("backup_date"),
                metadata.get("backup_time"),
                metadata.get("backup_method"),
                metadata.get("config_hash_sha256"),
                metadata.get("config_size_bytes"),
                metadata.get("backup_status", "success"),
                metadata.get("backup_file_path"),
            ))

            conn.commit()
            conn.close()
            return True
        except Exception as e:
            print(f"Error recording backup: {e}", file=sys.stderr)
            return False

    def log_audit_entry(self, action: str, user: str, device: str = None,
                        details: str = None, ip: str = None, status: str = "success") -> bool:
        """Record an audit log entry."""
        try:
            conn = sqlite3.connect(self.db_path)
            cursor = conn.cursor()

            cursor.execute("""
                INSERT INTO backup_audit_log
                (action, user_name, device_hostname, details, ip_address, status)
                VALUES (?, ?, ?, ?, ?, ?)
            """, (action, user, device, details, ip, status))

            conn.commit()
            conn.close()
            return True
        except Exception as e:
            print(f"Error logging audit entry: {e}", file=sys.stderr)
            return False

    def record_compliance(self, device: str, check_type: str, passed: bool,
                          details: str = None, score: float = None) -> bool:
        """Record a compliance check result."""
        try:
            conn = sqlite3.connect(self.db_path)
            cursor = conn.cursor()

            cursor.execute("""
                INSERT INTO compliance_records
                (device_hostname, check_type, passed, details, score)
                VALUES (?, ?, ?, ?, ?)
            """, (device, check_type, 1 if passed else 0, details, score))

            conn.commit()
            conn.close()
            return True
        except Exception as e:
            print(f"Error recording compliance: {e}", file=sys.stderr)
            return False

    def record_backup_summary(self, backup_date: str, total: int, successful: int,
                              failed: int, total_size: int = 0, duration: int = 0) -> bool:
        """Record a daily backup summary."""
        try:
            conn = sqlite3.connect(self.db_path)
            cursor = conn.cursor()

            cursor.execute("""
                INSERT INTO backup_summary
                (backup_date, total_devices, successful_devices, failed_devices,
                 total_size_bytes, duration_seconds)
                VALUES (?, ?, ?, ?, ?, ?)
            """, (backup_date, total, successful, failed, total_size, duration))

            conn.commit()
            conn.close()
            return True
        except Exception as e:
            print(f"Error recording summary: {e}", file=sys.stderr)
            return False

    def query_recent_backups(self, hostname: str = None, days: int = 7) -> list[dict]:
        """Query recent backup records."""
        conn = sqlite3.connect(self.db_path)
        conn.row_factory = sqlite3.Row
        cursor = conn.cursor()

        if hostname:
            cursor.execute("""
                SELECT * FROM device_backups
                WHERE hostname = ? AND backup_date >= date('now', ?)
                ORDER BY backup_timestamp DESC
            """, (hostname, f"-{days} days"))
        else:
            cursor.execute("""
                SELECT * FROM device_backups
                WHERE backup_date >= date('now', ?)
                ORDER BY backup_timestamp DESC
            """, (f"-{days} days",))

        rows = [dict(row) for row in cursor.fetchall()]
        conn.close()
        return rows

    def get_latest_backup(self, hostname: str) -> dict | None:
        """Get the most recent backup for a device."""
        conn = sqlite3.connect(self.db_path)
        conn.row_factory = sqlite3.Row
        cursor = conn.cursor()

        cursor.execute("""
            SELECT * FROM device_backups
            WHERE hostname = ?
            ORDER BY backup_timestamp DESC LIMIT 1
        """, (hostname,))

        row = cursor.fetchone()
        conn.close()
        return dict(row) if row else None

    def get_backup_statistics(self, days: int = 30) -> dict:
        """Get backup statistics for the given period."""
        conn = sqlite3.connect(self.db_path)
        cursor = conn.cursor()

        cursor.execute("""
            SELECT
                COUNT(*) as total_backups,
                SUM(CASE WHEN backup_status = 'success' THEN 1 ELSE 0 END) as successful,
                SUM(CASE WHEN backup_status = 'failed' THEN 1 ELSE 0 END) as failed,
                COUNT(DISTINCT hostname) as unique_devices,
                AVG(config_size_bytes) as avg_size,
                MAX(config_size_bytes) as max_size
            FROM device_backups
            WHERE backup_date >= date('now', ?)
        """, (f"-{days} days",))

        stats = dict(zip(
            ["total_backups", "successful", "failed", "unique_devices", "avg_size", "max_size"],
            [v or 0 for v in cursor.fetchone()]
        ))

        conn.close()
        return stats

    def export_to_json(self, output_path: str, days: int = 7) -> bool:
        """Export backup records to JSON file."""
        records = self.query_recent_backups(days=days)
        try:
            with open(output_path, "w") as f:
                json.dump(records, f, indent=2, default=str)
            return True
        except Exception as e:
            print(f"Error exporting to JSON: {e}", file=sys.stderr)
            return False


def main():
    parser = argparse.ArgumentParser(
        description="FortiGate Backup Metadata Logger",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )

    # Record actions
    parser.add_argument("--record-backup", action="store_true", help="Record a backup entry")
    parser.add_argument("--audit-log", action="store_true", help="Record an audit log entry")
    parser.add_argument("--record-compliance", action="store_true", help="Record compliance check")

    # Backup fields
    parser.add_argument("--hostname", help="Device hostname")
    parser.add_argument("--serial", help="Device serial number")
    parser.add_argument("--model", help="Device model")
    parser.add_argument("--firmware", help="Firmware version")
    parser.add_argument("--role", help="Device role (primary/secondary/edge)")
    parser.add_argument("--region", help="Device region")
    parser.add_argument("--location", help="Device physical location")
    parser.add_argument("--status", default="success", help="Backup status")

    # Audit fields
    parser.add_argument("--action", help="Audit action (backup/restore/validate/rollback)")
    parser.add_argument("--user", help="User who performed the action")
    parser.add_argument("--device", help="Device hostname")
    parser.add_argument("--details", help="Additional details")
    parser.add_argument("--ip", help="IP address")

    # Compliance fields
    parser.add_argument("--check-type", help="Type of compliance check")
    parser.add_argument("--passed", action="store_true", help="Check passed")
    parser.add_argument("--score", type=float, help="Compliance score")

    # Query actions
    parser.add_argument("--query", action="store_true", help="Query backup records")
    parser.add_argument("--last", type=int, default=7, help="Number of days to query")
    parser.add_argument("--stats", action="store_true", help="Show backup statistics")
    parser.add_argument("--export-json", help="Export records to JSON file")
    parser.add_argument("--db-path", help="Path to SQLite database")

    args = parser.parse_args()

    logger = BackupMetadataLogger(db_path=args.db_path)

    if args.record_backup:
        metadata = {
            "hostname": args.hostname,
            "serial": args.serial,
            "model": args.model,
            "firmware": args.firmware,
            "role": args.role,
            "region": args.region,
            "location": args.location,
            "backup_timestamp": datetime.utcnow().strftime("%Y%m%d_%H%M%S"),
            "backup_date": datetime.utcnow().strftime("%Y-%m-%d"),
            "backup_time": datetime.utcnow().strftime("%H:%M:%S"),
            "backup_status": args.status,
        }
        success = logger.record_backup(metadata)
        print(f"Backup record {'created' if success else 'failed'}")
        sys.exit(0 if success else 1)

    elif args.audit_log:
        success = logger.log_audit_entry(
            action=args.action,
            user=args.user,
            device=args.device or args.hostname,
            details=args.details,
            ip=args.ip,
            status=args.status,
        )
        print(f"Audit entry {'created' if success else 'failed'}")
        sys.exit(0 if success else 1)

    elif args.record_compliance:
        success = logger.record_compliance(
            device=args.device or args.hostname,
            check_type=args.check_type,
            passed=args.passed,
            details=args.details,
            score=args.score,
        )
        print(f"Compliance record {'created' if success else 'failed'}")
        sys.exit(0 if success else 1)

    elif args.query:
        records = logger.query_recent_backups(hostname=args.hostname, days=args.last)

        if not records:
            print(f"No backup records found for the last {args.last} days")
            sys.exit(0)

        for record in records:
            print(f"[{record['backup_date']} {record.get('backup_time', '')}] "
                  f"{record['hostname']} - {record.get('backup_status', 'unknown')} "
                  f"({record.get('config_size_bytes', 0)} bytes)")

        print(f"\nTotal records: {len(records)}")

    elif args.stats:
        stats = logger.get_backup_statistics(days=args.last)
        print(f"Backup Statistics (last {args.last} days):")
        print(f"  Total backups: {stats['total_backups']}")
        print(f"  Successful: {stats['successful']}")
        print(f"  Failed: {stats['failed']}")
        print(f"  Unique devices: {stats['unique_devices']}")
        print(f"  Average size: {stats['avg_size']:.0f} bytes")
        print(f"  Max size: {stats['max_size']} bytes")

    elif args.export_json:
        success = logger.export_to_json(args.export_json, days=args.last)
        print(f"Records exported to {args.export_json}" if success else "Export failed")
        sys.exit(0 if success else 1)

    else:
        parser.print_help()


if __name__ == "__main__":
    main()
