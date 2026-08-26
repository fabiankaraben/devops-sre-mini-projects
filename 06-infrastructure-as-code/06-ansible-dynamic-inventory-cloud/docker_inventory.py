#!/usr/bin/env python3
"""
==============================================================================
docker_inventory.py - Ansible Dynamic Inventory Script for Docker Cloud Fleets
==============================================================================
Discovers running Docker containers labeled with fleet metadata and dynamically
groups them by Environment, Role, App, and Cluster tags according to the
Ansible Dynamic Inventory JSON specification.

Supported CLI invocations:
  ./docker_inventory.py --list
  ./docker_inventory.py --host <hostname>
==============================================================================
"""

import argparse
import json
import os
import re
import subprocess
import sys

# Ensure local containment directories exist before Ansible attempts logging
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
os.makedirs(os.path.join(SCRIPT_DIR, "logs"), exist_ok=True)
os.makedirs(os.path.join(SCRIPT_DIR, ".ansible", "tmp"), exist_ok=True)
os.makedirs(os.path.join(SCRIPT_DIR, ".ansible", "cp"), exist_ok=True)


def sanitize_group_name(name: str) -> str:
    """Sanitizes strings to be safe Ansible group identifiers."""
    return re.sub(r"[^a-zA-Z0-9_]", "_", str(name)).lower()


def get_docker_containers():
    """
    Queries the local Docker daemon for containers labeled with devops.fleet.
    Returns a list of parsed container metadata dictionaries.
    """
    try:
        # Query running containers matching our fleet label
        cmd = [
            "docker", "ps",
            "--filter", "label=devops.fleet=ansible-dynamic-inventory",
            "--format", "{{.ID}}"
        ]
        result = subprocess.run(cmd, capture_output=True, text=True, check=False)
        if result.returncode != 0 or not result.stdout.strip():
            return []

        container_ids = result.stdout.strip().splitlines()
        if not container_ids:
            return []

        # Inspect all matched containers in a single call for high performance
        inspect_cmd = ["docker", "inspect"] + container_ids
        inspect_result = subprocess.run(inspect_cmd, capture_output=True, text=True, check=False)
        if inspect_result.returncode != 0 or not inspect_result.stdout.strip():
            return []

        return json.loads(inspect_result.stdout)
    except Exception as exc:
        sys.stderr.write(f"Warning: Failed to fetch Docker containers: {exc}\n")
        return []


def build_dynamic_inventory():
    """
    Constructs the Ansible Dynamic Inventory dictionary from Docker inspection data.
    """
    inventory = {
        "_meta": {
            "hostvars": {}
        },
        "all": {
            "children": ["ungrouped"]
        },
        "ungrouped": {
            "hosts": []
        }
    }

    containers = get_docker_containers()
    discovered_groups = set()

    def add_to_group(group_name: str, host_name: str):
        if group_name not in inventory:
            inventory[group_name] = {"hosts": [], "vars": {}}
            discovered_groups.add(group_name)
        if host_name not in inventory[group_name]["hosts"]:
            inventory[group_name]["hosts"].append(host_name)

    for item in containers:
        # Extract container name (strip leading slash)
        raw_name = item.get("Name", "")
        hostname = raw_name.lstrip("/") if raw_name else item.get("Id", "")[:12]

        config = item.get("Config", {})
        labels = config.get("Labels", {})
        state = item.get("State", {})
        network_settings = item.get("NetworkSettings", {})

        # Ensure container is running
        if not state.get("Running", False):
            continue

        # Extract fleet tags / labels
        environment = labels.get("Environment", labels.get("environment", "unknown"))
        role = labels.get("Role", labels.get("role", "unknown"))
        app = labels.get("App", labels.get("app", "unknown"))
        cluster = labels.get("Cluster", labels.get("cluster", "default"))
        version = labels.get("Version", labels.get("version", "1.0.0"))
        host_port = labels.get("HostPort", labels.get("host_port", "8080"))

        # Extract internal IP address if available
        networks = network_settings.get("Networks", {})
        internal_ip = ""
        for net_name, net_data in networks.items():
            internal_ip = net_data.get("IPAddress", "")
            if internal_ip:
                break

        # Populate hostvars for direct Docker connection
        inventory["_meta"]["hostvars"][hostname] = {
            "ansible_connection": "docker",
            "ansible_host": hostname,
            "ansible_python_interpreter": "/usr/local/bin/python3",
            "container_id": item.get("Id", "")[:12],
            "container_image": config.get("Image", ""),
            "ip_address": internal_ip,
            "environment_tag": environment,
            "role_tag": role,
            "app_tag": app,
            "cluster_tag": cluster,
            "app_version": version,
            "host_port": host_port,
            "container_port": 8080,
            "health_endpoint": "http://localhost:8080/health"
        }

        # Keyed groups by Environment (e.g. env_production, env_staging)
        env_group = f"env_{sanitize_group_name(environment)}"
        add_to_group(env_group, hostname)

        # Keyed groups by Role (e.g. role_web, role_api, role_db)
        role_group = f"role_{sanitize_group_name(role)}"
        add_to_group(role_group, hostname)

        # Keyed groups by App (e.g. app_frontend, app_backend)
        app_group = f"app_{sanitize_group_name(app)}"
        add_to_group(app_group, hostname)

        # AWS EC2 Tag Mirroring Groups (e.g. tag_Environment_production)
        tag_env_group = f"tag_Environment_{sanitize_group_name(environment)}"
        add_to_group(tag_env_group, hostname)
        tag_role_group = f"tag_Role_{sanitize_group_name(role)}"
        add_to_group(tag_role_group, hostname)

        # Composite intersection group: env_production_role_web
        composite_group = f"env_{sanitize_group_name(environment)}_role_{sanitize_group_name(role)}"
        add_to_group(composite_group, hostname)

    # Register discovered groups under 'all.children'
    for group in sorted(discovered_groups):
        if group not in inventory["all"]["children"]:
            inventory["all"]["children"].append(group)

    return inventory


def get_host_vars(hostname: str):
    """Returns host-specific variables for a given hostname."""
    inventory = build_dynamic_inventory()
    return inventory["_meta"]["hostvars"].get(hostname, {})


def main():
    parser = argparse.ArgumentParser(
        description="Ansible Dynamic Inventory Script for Docker Fleet Nodes"
    )
    parser.add_argument(
        "--list",
        action="store_true",
        help="Output JSON object containing all host groups and variables"
    )
    parser.add_argument(
        "--host",
        type=str,
        help="Output JSON object with host variables for a single host"
    )

    args = parser.parse_args()

    if args.host:
        host_data = get_host_vars(args.host)
        print(json.dumps(host_data, indent=2))
    elif args.list:
        inventory_data = build_dynamic_inventory()
        print(json.dumps(inventory_data, indent=2))
    else:
        # Default behavior when invoked by Ansible without flags
        inventory_data = build_dynamic_inventory()
        print(json.dumps(inventory_data, indent=2))


if __name__ == "__main__":
    main()
