#!/usr/bin/env python3
"""
Dynamic Inventory Generator for FortiGate Backup System

Generates Ansible inventory from external sources:
- CMDB API
- CSV/Excel files
- Network discovery
- Static configuration

Usage:
    python3 inventory_generator.py --cmbd-api https://cmdb.internal.local/api/devices
    python3 inventory_generator.py --csv devices.csv --output inventory.yml
    python3 inventory_generator.py --validate --inventory ../ansible/inventory/production/hosts.yml
"""

import argparse
import csv
import json
import os
import re
import sys
from datetime import datetime
from pathlib import Path

try:
    import yaml
except ImportError:
    yaml = None


class InventoryGenerator:
    FORTIGATE_MODEL_PATTERNS = {
        "FortiGate-60F": (60, "entry"),
        "FortiGate-80F": (80, "branch"),
        "FortiGate-100F": (100, "branch"),
        "FortiGate-200F": (200, "midrange"),
        "FortiGate-400F": (400, "midrange"),
        "FortiGate-600F": (600, "high-end"),
        "FortiGate-900F": (900, "high-end"),
        "FortiGate-1800F": (1800, "data-center"),
        "FortiGate-2400F": (2400, "data-center"),
        "FortiGate-VM64": (0, "virtual"),
    }

    REGIONS = {
        "norte": {"dc": "10.100", "suc": "10.101"},
        "sur": {"dc": "10.200", "suc": "10.201"},
        "centro": {"dc": "10.150", "suc": "10.151"},
        "oriente": {"dc": "10.50", "suc": "10.51"},
    }

    def __init__(self, output_dir: str = None):
        self.output_dir = Path(output_dir or ".")
        self.devices = []

    def from_csv(self, csv_path: str) -> list[dict]:
        """Parse devices from CSV file."""
        devices = []
        with open(csv_path, newline="", encoding="utf-8") as f:
            reader = csv.DictReader(f)
            for row in reader:
                device = {
                    "hostname": row.get("hostname", "").strip().lower(),
                    "ansible_host": row.get("mgmt_ip", "").strip(),
                    "ansible_port": int(row.get("ssh_port", 22)),
                    "fgt_hostname": row.get("hostname", "").strip().upper(),
                    "fgt_model": row.get("model", "").strip(),
                    "fgt_serial": row.get("serial", "").strip(),
                    "fgt_version": row.get("firmware", "").strip(),
                    "fgt_role": row.get("role", "edge").strip().lower(),
                    "fgt_location": row.get("location", "").strip(),
                    "fgt_region": row.get("region", "").strip().lower(),
                    "backup_priority": int(row.get("priority", 3)),
                    "backup_method": row.get("method", "ssh").strip().lower(),
                }
                devices.append(device)
        self.devices = devices
        return devices

    def to_ansible_inventory(self, devices: list[dict] = None) -> dict:
        """Convert device list to Ansible inventory YAML structure."""
        if devices is None:
            devices = self.devices

        inventory = {
            "all": {
                "children": {
                    "fortigates": {
                        "children": {},
                        "vars": {
                            "ansible_user": "{{ vault_ansible_user }}",
                            "ansible_ssh_private_key_file": "{{ vault_ssh_key_path }}",
                            "ansible_network_os": "fortinet.fortios.fortios",
                            "ansible_connection": "ansible.netcommon.network_cli",
                            "backup_base_dir": "/opt/backups/fortigates",
                            "backup_retention_days": 90,
                            "notify_on_failure": True,
                            "notify_on_success": False,
                            "notify_on_change": True,
                        }
                    }
                }
            }
        }

        for device in devices:
            region = device.get("fgt_region", "unknown")
            region_key = f"region_{region}"

            if region_key not in inventory["all"]["children"]["fortigates"]["children"]:
                inventory["all"]["children"]["fortigates"]["children"][region_key] = {
                    "hosts": {}
                }

            host_entry = {
                "ansible_host": device["ansible_host"],
                "ansible_port": device.get("ansible_port", 22),
                "fgt_hostname": device["fgt_hostname"],
                "fgt_model": device["fgt_model"],
                "fgt_serial": device["fgt_serial"],
                "fgt_version": device["fgt_version"],
                "fgt_role": device["fgt_role"],
                "fgt_location": device["fgt_location"],
                "fgt_region": region,
                "backup_priority": device.get("backup_priority", 3),
                "backup_method": device.get("backup_method", "ssh"),
            }

            inventory["all"]["children"]["fortigates"]["children"][region_key]["hosts"][
                device["hostname"]
            ] = host_entry

        return inventory

    def validate_inventory(self, inventory_path: str) -> list[str]:
        """Validate an existing inventory file for correctness."""
        errors = []

        try:
            with open(inventory_path) as f:
                data = yaml.safe_load(f) if yaml else json.load(f)
        except Exception as e:
            return [f"Cannot parse inventory: {e}"]

        fortigates = (
            data.get("all", {})
            .get("children", {})
            .get("fortigates", {})
            .get("children", {})
        )

        for region, region_data in fortigates.items():
            for hostname, host_vars in region_data.get("hosts", {}).items():
                if not host_vars.get("ansible_host"):
                    errors.append(f"{hostname}: missing ansible_host")
                if not host_vars.get("fgt_model"):
                    errors.append(f"{hostname}: missing fgt_model")
                if host_vars.get("backup_method") not in ["ssh", "api"]:
                    errors.append(f"{hostname}: invalid backup_method '{host_vars.get('backup_method')}'")
                if host_vars.get("fgt_role") not in ["primary", "secondary", "edge", "lab", "staging"]:
                    errors.append(f"{hostname}: invalid fgt_role '{host_vars.get('fgt_role')}'")
                if host_vars.get("backup_priority", 0) < 1:
                    errors.append(f"{hostname}: backup_priority must be >= 1")

        return errors

    def write_inventory(self, inventory: dict, output_path: str):
        """Write inventory to YAML file."""
        if yaml:
            with open(output_path, "w", encoding="utf-8") as f:
                yaml.dump(inventory, f, default_flow_style=False, sort_keys=False, allow_unicode=True)
        else:
            with open(output_path, "w", encoding="utf-8") as f:
                json.dump(inventory, f, indent=2)
        print(f"Inventory written to {output_path}")


def main():
    parser = argparse.ArgumentParser(
        description="FortiGate Inventory Generator",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--csv", help="Input CSV file with device list")
    parser.add_argument("--output", "-o", default="inventory/hosts.yml", help="Output inventory path")
    parser.add_argument("--validate", help="Validate existing inventory file")
    parser.add_argument("--output-dir", default=".", help="Output directory")

    args = parser.parse_args()

    if not yaml:
        print("Warning: PyYAML not installed, using JSON format", file=sys.stderr)

    generator = InventoryGenerator(output_dir=args.output_dir)

    if args.validate:
        errors = generator.validate_inventory(args.validate)
        if errors:
            print(f"Found {len(errors)} validation error(s):")
            for error in errors:
                print(f"  - {error}")
            sys.exit(1)
        else:
            print("Inventory validation passed!")
            sys.exit(0)

    if args.csv:
        devices = generator.from_csv(args.csv)
        inventory = generator.to_ansible_inventory(devices)
        generator.write_inventory(inventory, args.output)
        print(f"Generated inventory with {len(devices)} devices across "
              f"{len(inventory['all']['children']['fortigates']['children'])} regions")
    else:
        parser.print_help()
        sys.exit(1)


if __name__ == "__main__":
    main()
