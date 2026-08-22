#!/usr/bin/env python3
"""
network_simulator.py - Multi-VPC Transit Gateway Routing Simulator
=============================================================================
Simulates and verifies AWS VPC Route Tables, Transit Gateway (TGW) Route Domains,
Security Group rules, and packet reachability / isolation policies.

Features:
  - Evaluates Layer 3 IP routing (longest prefix match) and TGW route domains.
  - Enforces strict Hub-and-Spoke isolation (Spoke-to-Spoke isolation: Prod <-> Staging).
  - Simulates Security Group ingress/egress stateful rule evaluation.
  - Exports structured JSON test reports for automated CI/CD validation.
=============================================================================
"""

import argparse
import ipaddress
import json
import sys
import time
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional, Tuple

CLR_RESET = "\033[0m"
CLR_BOLD = "\033[1m"
CLR_GREEN = "\033[1;32m"
CLR_RED = "\033[1;31m"
CLR_YELLOW = "\033[1;33m"
CLR_CYAN = "\033[1;36m"
CLR_MAGENTA = "\033[1;35m"
CLR_GRAY = "\033[0;90m"
CLR_WHITE = "\033[1;37m"


# ==============================================================================
# Network Model Data Structures
# ==============================================================================

@dataclass
class Subnet:
    name: str
    cidr: str
    network: ipaddress.IPv4Network = field(init=False)

    def __post_init__(self):
        self.network = ipaddress.ip_network(self.cidr)


@dataclass
class VPC:
    name: str
    vpc_id: str
    cidr: str
    role: str  # "Spoke" or "Hub"
    subnets: List[Subnet]
    network: ipaddress.IPv4Network = field(init=False)

    def __post_init__(self):
        self.network = ipaddress.ip_network(self.cidr)


@dataclass
class RouteEntry:
    destination_cidr: str
    target: str  # "local", "tgw", or "blackhole"
    dest_network: ipaddress.IPv4Network = field(init=False)

    def __post_init__(self):
        self.dest_network = ipaddress.ip_network(self.destination_cidr)


@dataclass
class TGWRouteTable:
    name: str
    role: str  # "SpokeRouteDomain" or "HubRouteDomain"
    routes: List[RouteEntry]


# ==============================================================================
# Multi-VPC Architecture Definition
# ==============================================================================

class MultiVPCNetworkTopology:
    """Represents the complete multi-VPC Hub-and-Spoke cloud network."""

    def __init__(self):
        # 1. VPCs
        self.vpc_prod = VPC(
            name="Production-VPC",
            vpc_id="vpc-prod-01",
            cidr="10.10.0.0/16",
            role="Spoke",
            subnets=[
                Subnet("prod-app-subnet", "10.10.1.0/24"),
                Subnet("prod-db-subnet", "10.10.2.0/24"),
            ],
        )

        self.vpc_staging = VPC(
            name="Staging-VPC",
            vpc_id="vpc-staging-02",
            cidr="10.20.0.0/16",
            role="Spoke",
            subnets=[
                Subnet("staging-app-subnet", "10.20.1.0/24"),
                Subnet("staging-db-subnet", "10.20.2.0/24"),
            ],
        )

        self.vpc_shared = VPC(
            name="SharedServices-VPC",
            vpc_id="vpc-shared-03",
            cidr="10.30.0.0/16",
            role="Hub",
            subnets=[
                Subnet("shared-tools-subnet", "10.30.1.0/24"),
                Subnet("shared-logging-subnet", "10.30.2.0/24"),
            ],
        )

        self.vpcs = [self.vpc_prod, self.vpc_staging, self.vpc_shared]

        # 2. VPC Subnet Route Tables
        self.vpc_route_tables = {
            "vpc-prod-01": [
                RouteEntry("10.10.0.0/16", "local"),
                RouteEntry("10.30.0.0/16", "tgw"),  # Route to Shared Services Hub
                # Note: NO route to 10.20.0.0/16 (Staging)
            ],
            "vpc-staging-02": [
                RouteEntry("10.20.0.0/16", "local"),
                RouteEntry("10.30.0.0/16", "tgw"),  # Route to Shared Services Hub
                # Note: NO route to 10.10.0.0/16 (Prod)
            ],
            "vpc-shared-03": [
                RouteEntry("10.30.0.0/16", "local"),
                RouteEntry("10.10.0.0/16", "tgw"),  # Route to Prod Spoke
                RouteEntry("10.20.0.0/16", "tgw"),  # Route to Staging Spoke
            ],
        }

        # 3. Transit Gateway Route Tables (Segmentation Domains)
        self.tgw_spoke_rt = TGWRouteTable(
            name="Spoke-TGW-RouteTable",
            role="SpokeRouteDomain",
            routes=[
                # Spokes can ONLY route to the Shared Services Hub
                RouteEntry("10.30.0.0/16", "shared-attachment"),
            ],
        )

        self.tgw_hub_rt = TGWRouteTable(
            name="Hub-TGW-RouteTable",
            role="HubRouteDomain",
            routes=[
                # Hub can route to both Spokes
                RouteEntry("10.10.0.0/16", "prod-attachment"),
                RouteEntry("10.20.0.0/16", "staging-attachment"),
            ],
        )

        # 4. TGW Route Table Associations
        self.tgw_associations = {
            "vpc-prod-01": self.tgw_spoke_rt,
            "vpc-staging-02": self.tgw_spoke_rt,
            "vpc-shared-03": self.tgw_hub_rt,
        }

    def find_vpc_for_ip(self, ip_str: str) -> Optional[VPC]:
        ip = ipaddress.ip_address(ip_str)
        for vpc in self.vpcs:
            if ip in vpc.network:
                return vpc
        return None

    def trace_packet(self, src_ip: str, dst_ip: str, dst_port: int = 443, protocol: str = "tcp") -> Dict[str, Any]:
        """
        Traces a packet through VPC Route Tables, TGW Route Tables, and Security Groups.
        Returns trace metadata and final reachability decision.
        """
        src_vpc = self.find_vpc_for_ip(src_ip)
        dst_vpc = self.find_vpc_for_ip(dst_ip)
        hops: List[str] = [f"Source: {src_ip}"]

        # 1. Check Source VPC existence
        if not src_vpc:
            return {
                "src_ip": src_ip,
                "dst_ip": dst_ip,
                "port": dst_port,
                "status": "DROPPED",
                "reason": f"Source IP {src_ip} does not belong to any configured VPC",
                "hops": hops,
            }

        hops.append(f"Ingress VPC: {src_vpc.name} ({src_vpc.cidr})")

        # 2. VPC Route Table Lookup (Local vs TGW)
        dst_addr = ipaddress.ip_address(dst_ip)
        vpc_routes = self.vpc_route_tables.get(src_vpc.vpc_id, [])
        matching_vpc_route = None

        for route in vpc_routes:
            if dst_addr in route.dest_network:
                matching_vpc_route = route
                break

        if not matching_vpc_route:
            hops.append(f"VPC Route Table ({src_vpc.name}): NO ROUTE for {dst_ip}")
            return {
                "src_ip": src_ip,
                "dst_ip": dst_ip,
                "port": dst_port,
                "status": "DROPPED",
                "reason": f"No matching route in {src_vpc.name} Route Table (Packet dropped at VPC boundary)",
                "hops": hops,
            }

        if matching_vpc_route.target == "local":
            hops.append(f"VPC Route Table ({src_vpc.name}): Matched local route -> Delivered locally")
            return {
                "src_ip": src_ip,
                "dst_ip": dst_ip,
                "port": dst_port,
                "status": "ALLOWED",
                "reason": "Intra-VPC local routing",
                "hops": hops,
            }

        # 3. Packet reaches AWS Transit Gateway
        hops.append(f"VPC Route Table ({src_vpc.name}): Next hop -> AWS Transit Gateway (TGW)")
        tgw_rt = self.tgw_associations.get(src_vpc.vpc_id)
        if not tgw_rt:
            return {
                "src_ip": src_ip,
                "dst_ip": dst_ip,
                "port": dst_port,
                "status": "DROPPED",
                "reason": "VPC not associated with any TGW Route Table",
                "hops": hops,
            }

        hops.append(f"TGW Route Table Domain: {tgw_rt.name} ({tgw_rt.role})")

        # 4. TGW Route Table Lookup
        matching_tgw_route = None
        for route in tgw_rt.routes:
            if dst_addr in route.dest_network:
                matching_tgw_route = route
                break

        if not matching_tgw_route:
            hops.append(f"TGW Route Table ({tgw_rt.name}): NO ROUTE for {dst_ip} -> BLACKHOLE / ISOLATED")
            return {
                "src_ip": src_ip,
                "dst_ip": dst_ip,
                "port": dst_port,
                "status": "DROPPED",
                "reason": f"TGW Route Table '{tgw_rt.name}' isolates spoke traffic (No route to destination CIDR)",
                "hops": hops,
            }

        hops.append(f"TGW Forwarding: Matched route -> {matching_tgw_route.target}")

        if not dst_vpc:
            hops.append(f"Destination {dst_ip}: External unknown target")
            return {
                "src_ip": src_ip,
                "dst_ip": dst_ip,
                "port": dst_port,
                "status": "DROPPED",
                "reason": f"Destination IP {dst_ip} is unreachable outside VPC fabric",
                "hops": hops,
            }

        hops.append(f"Egress VPC: {dst_vpc.name} ({dst_vpc.cidr})")

        # 5. Security Group Ingress Rule Check
        sg_decision, sg_reason = self._evaluate_security_group(src_vpc, dst_vpc, dst_port, protocol)
        hops.append(f"Security Group Check: {sg_reason}")

        if not sg_decision:
            return {
                "src_ip": src_ip,
                "dst_ip": dst_ip,
                "port": dst_port,
                "status": "DROPPED",
                "reason": f"Security Group Block: {sg_reason}",
                "hops": hops,
            }

        hops.append(f"Destination Host {dst_ip}:{dst_port} -> PACKET DELIVERED")
        return {
            "src_ip": src_ip,
            "dst_ip": dst_ip,
            "port": dst_port,
            "status": "ALLOWED",
            "reason": "Packet successfully routed through Transit Gateway Hub-and-Spoke fabric",
            "hops": hops,
        }

    def _evaluate_security_group(self, src_vpc: VPC, dst_vpc: VPC, dst_port: int, protocol: str) -> Tuple[bool, str]:
        """Simulates Security Group Layer 4 stateful filtering."""
        # Destination is Shared Services
        if dst_vpc.vpc_id == "vpc-shared-03":
            if dst_port in (443, 8080, 22):
                return True, f"Shared SG allows port {dst_port} from {src_vpc.name}"
            return False, f"Shared SG denies unallowed port {dst_port}"

        # Destination is Production
        if dst_vpc.vpc_id == "vpc-prod-01":
            if src_vpc.vpc_id == "vpc-staging-02":
                return False, "Prod SG explicitly denies all traffic originating from Staging"
            if src_vpc.vpc_id == "vpc-shared-03" and dst_port in (443, 22):
                return True, f"Prod SG allows port {dst_port} from Shared Services Hub"
            return False, f"Prod SG denies traffic from {src_vpc.name}"

        # Destination is Staging
        if dst_vpc.vpc_id == "vpc-staging-02":
            if src_vpc.vpc_id == "vpc-prod-01":
                return False, "Staging SG explicitly denies all traffic originating from Production"
            if src_vpc.vpc_id == "vpc-shared-03" and dst_port in (8080, 22):
                return True, f"Staging SG allows port {dst_port} from Shared Services Hub"
            return False, f"Staging SG denies traffic from {src_vpc.name}"

        return True, "Default allow"


# ==============================================================================
# Test Execution and Assertion Suite
# ==============================================================================

def run_reachability_tests(verbose: bool = False, json_out: Optional[str] = None):
    print(f"\n{CLR_CYAN}{CLR_BOLD}{'=' * 85}{CLR_RESET}")
    print(f"{CLR_CYAN}{CLR_BOLD}  🌐 AWS Multi-VPC Transit Gateway Network Reachability & Isolation Suite{CLR_RESET}")
    print(f"{CLR_GRAY}  Topology: Hub (Shared 10.30.0.0/16) | Spoke 1 (Prod 10.10.0.0/16) | Spoke 2 (Staging 10.20.0.0/16){CLR_RESET}")
    print(f"{CLR_CYAN}{CLR_BOLD}{'=' * 85}{CLR_RESET}\n")

    network = MultiVPCNetworkTopology()

    # --------------------------------------------------------------------------
    # Test Cases Matrix
    # --------------------------------------------------------------------------
    test_cases = [
        {
            "id": "NET-01",
            "name": "Prod Spoke ➔ Shared Services Hub (App to Artifactory/Tools)",
            "src": "10.10.1.50",
            "dst": "10.30.1.10",
            "port": 443,
            "expected_status": "ALLOWED",
            "desc": "Production workloads can reach central Shared Services tools over HTTPS.",
        },
        {
            "id": "NET-02",
            "name": "Shared Services Hub ➔ Prod Spoke (CI/CD Deployment Deploy)",
            "src": "10.30.1.10",
            "dst": "10.10.1.50",
            "port": 443,
            "expected_status": "ALLOWED",
            "desc": "Shared CI/CD runners can dispatch deployments to Production hosts.",
        },
        {
            "id": "NET-03",
            "name": "Staging Spoke ➔ Shared Services Hub (Build Artifact Retrieval)",
            "src": "10.20.1.50",
            "dst": "10.30.1.10",
            "port": 443,
            "expected_status": "ALLOWED",
            "desc": "Staging environments can download build packages from Shared Hub.",
        },
        {
            "id": "NET-04",
            "name": "Shared Services Hub ➔ Staging Spoke (Integration Test Agent)",
            "src": "10.30.1.10",
            "dst": "10.20.1.50",
            "port": 8080,
            "expected_status": "ALLOWED",
            "desc": "Shared monitoring & testing agents can reach Staging endpoints.",
        },
        {
            "id": "NET-05",
            "name": "Prod Spoke ➔ Staging Spoke ISOLATION (Lateral Movement Defense)",
            "src": "10.10.1.50",
            "dst": "10.20.1.50",
            "port": 8080,
            "expected_status": "DROPPED",
            "desc": "Production CANNOT reach Staging (Spoke TGW Route Table isolates domains).",
        },
        {
            "id": "NET-06",
            "name": "Staging Spoke ➔ Prod Spoke ISOLATION (Blast Radius Containment)",
            "src": "10.20.1.50",
            "dst": "10.10.1.50",
            "port": 443,
            "expected_status": "DROPPED",
            "desc": "Staging CANNOT reach Production (Compromised staging cannot pivot to prod).",
        },
        {
            "id": "NET-07",
            "name": "Non-Transitive Hop Attempt: Prod ➔ Staging via Shared",
            "src": "10.10.1.50",
            "dst": "10.20.2.99",
            "port": 3306,
            "expected_status": "DROPPED",
            "desc": "Spokes cannot perform transitive hops across TGW route domains.",
        },
        {
            "id": "NET-08",
            "name": "External / Bogus CIDR Route Boundary (192.168.1.1)",
            "src": "10.10.1.50",
            "dst": "192.168.1.1",
            "port": 80,
            "expected_status": "DROPPED",
            "desc": "Unroutable non-VPC traffic is dropped at the VPC route table boundary.",
        },
    ]

    total = len(test_cases)
    passed = 0
    failed = 0
    results_list = []

    print(f"{CLR_WHITE}{'ID':<8} {'TEST CASE DESCRIPTION':<56} {'EXPECTED':<10} {'ACTUAL':<10} {'STATUS':<8}{CLR_RESET}")
    print(f"{CLR_GRAY}{'-' * 96}{CLR_RESET}")

    for tc in test_cases:
        trace = network.trace_packet(tc["src"], tc["dst"], tc["port"])
        actual_status = trace["status"]
        is_pass = (actual_status == tc["expected_status"])

        if is_pass:
            passed += 1
            status_str = f"{CLR_GREEN}PASS{CLR_RESET}"
        else:
            failed += 1
            status_str = f"{CLR_RED}FAIL{CLR_RESET}"

        results_list.append({
            "id": tc["id"],
            "name": tc["name"],
            "src": tc["src"],
            "dst": tc["dst"],
            "port": tc["port"],
            "expected": tc["expected_status"],
            "actual": actual_status,
            "passed": is_pass,
            "trace_hops": trace["hops"],
            "reason": trace["reason"],
        })

        print(f"{CLR_WHITE}{tc['id']:<8}{CLR_RESET} {tc['name']:<56} {tc['expected_status']:<10} {actual_status:<10} [{status_str}]")

        if verbose:
            print(f"  {CLR_CYAN}Packet Trace:{CLR_RESET}")
            for hop in trace["hops"]:
                print(f"    ↳ {CLR_GRAY}{hop}{CLR_RESET}")
            print(f"    {CLR_MAGENTA}Decision:{CLR_RESET} {trace['reason']}\n")

    pass_pct = int((passed * 100) / total)
    failed_str = f"{CLR_RED}{failed}{CLR_RESET}" if failed > 0 else f"{CLR_GREEN}0{CLR_RESET}"
    score_str = f"{CLR_GREEN}{pass_pct}%{CLR_RESET}" if pass_pct == 100 else f"{CLR_YELLOW}{pass_pct}%{CLR_RESET}"

    # Summary Box
    print(f"\n{CLR_CYAN}{CLR_BOLD}{'=' * 85}{CLR_RESET}")
    print(f"  {CLR_BOLD}Multi-VPC Reachability & Isolation Summary:{CLR_RESET}")
    print(f"  Total Network Test Cases : {CLR_WHITE}{total}{CLR_RESET}")
    print(f"  Passed Assertions        : {CLR_GREEN}{passed}{CLR_RESET}")
    print(f"  Failed Assertions        : {failed_str}")
    print(f"  Compliance Score         : {score_str}")
    print(f"{CLR_CYAN}{CLR_BOLD}{'=' * 85}{CLR_RESET}\n")

    if json_out:
        out_data = {
            "total_tests": total,
            "passed": passed,
            "failed": failed,
            "compliance_percentage": pass_pct,
            "test_results": results_list,
        }
        with open(json_out, "w", encoding="utf-8") as f:
            json.dump(out_data, f, indent=2)
        print(f"{CLR_GRAY}[INFO] JSON test report exported to: {json_out}{CLR_RESET}\n")

    if failed > 0:
        sys.exit(1)
    sys.exit(0)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Multi-VPC Transit Gateway Network Reachability Simulator")
    parser.add_argument("--verbose", "-v", action="store_true", help="Display full packet tracer hops")
    parser.add_argument("--json-output", default=None, help="Save structured JSON test report")
    args = parser.parse_args()

    run_reachability_tests(verbose=args.verbose, json_out=args.json_output)
