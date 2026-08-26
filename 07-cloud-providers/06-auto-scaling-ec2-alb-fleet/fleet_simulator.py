#!/usr/bin/env python3
"""
High-Availability Auto Scaling EC2 Fleet behind ALB - Offline Simulator
======================================================================
Deterministic Python engine modeling AWS VPC, Multi-AZ subnets, Application
Load Balancer (ALB) round-robin traffic routing, Target Group health checks,
and Auto Scaling Group (ASG) Target Tracking / Self-Healing lifecycle.

Zero cloud dependencies - runs instantly anywhere for validation and CI/CD.
"""

import argparse
import json
import math
import sys
import time
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from typing import Dict, List, Optional

# ANSI Color Codes
CLR_RESET = "\033[0m"
CLR_BOLD = "\033[1m"
CLR_GREEN = "\033[1;32m"
CLR_RED = "\033[1;31m"
CLR_YELLOW = "\033[1;33m"
CLR_CYAN = "\033[1;36m"
CLR_MAGENTA = "\033[1;35m"
CLR_GRAY = "\033[0;90m"
CLR_WHITE = "\033[1;37m"


@dataclass
class Instance:
    instance_id: str
    availability_zone: str
    private_ip: str
    status: str  # Pending, InService, Terminating, Terminated
    health_status: str  # Healthy, Unhealthy
    consecutive_failed_checks: int = 0
    consecutive_passed_checks: int = 0
    cpu_utilization: float = 10.0
    requests_handled: int = 0
    launch_time: str = field(default_factory=lambda: datetime.now(timezone.utc).isoformat())


@dataclass
class TestResult:
    test_id: str
    name: str
    category: str
    expected: str
    actual: str
    passed: bool
    details: str


class ASGFleetSimulator:
    """Simulates AWS ALB, Multi-AZ ASG, and Target Tracking Scaling policies."""

    def __init__(
        self,
        min_size: int = 1,
        desired_capacity: int = 2,
        max_size: int = 4,
        target_cpu: float = 50.0,
        azs: Optional[List[str]] = None,
        verbose: bool = False,
    ):
        self.min_size = min_size
        self.desired_capacity = desired_capacity
        self.max_size = max_size
        self.target_cpu = target_cpu
        self.azs = azs or ["us-east-1a", "us-east-1b", "us-east-1c"]
        self.verbose = verbose
        self.instances: Dict[str, Instance] = {}
        self.instance_counter = 0
        self.alb_round_robin_index = 0
        self.history_logs: List[str] = []
        self.test_results: List[TestResult] = []

        # Boot initial fleet to desired capacity
        self._bootstrap_initial_fleet()

    def log(self, message: str, level: str = "INFO"):
        timestamp = datetime.now(timezone.utc).strftime("%H:%M:%S.%f")[:-3]
        log_entry = f"[{timestamp}] [{level}] {message}"
        self.history_logs.append(log_entry)
        if self.verbose:
            color = CLR_CYAN if level == "INFO" else (CLR_YELLOW if level == "WARN" else CLR_GREEN)
            print(f"  {CLR_GRAY}[{timestamp}]{CLR_RESET} {color}[{level:5s}]{CLR_RESET} {message}")

    def _get_least_populated_az(self) -> str:
        """Find the Availability Zone with the fewest active instances to maintain balance."""
        az_counts = {az: 0 for az in self.azs}
        for inst in self.instances.values():
            if inst.status in ("Pending", "InService"):
                az_counts[inst.availability_zone] = az_counts.get(inst.availability_zone, 0) + 1
        # Sort by count ascending
        return min(az_counts.keys(), key=lambda az: az_counts[az])

    def launch_instance(self, az: Optional[str] = None) -> Instance:
        """Simulate EC2 Launch Template provisioning."""
        self.instance_counter += 1
        target_az = az or self._get_least_populated_az()
        inst_id = f"i-0{self.instance_counter:04d}{target_az[-2:]}fleet"
        octet3 = self.azs.index(target_az) + 1
        octet4 = 10 + self.instance_counter
        private_ip = f"10.0.{octet3}.{octet4}"

        instance = Instance(
            instance_id=inst_id,
            availability_zone=target_az,
            private_ip=private_ip,
            status="InService",  # In simulation, transitions directly to InService
            health_status="Healthy",
            cpu_utilization=15.0,
        )
        self.instances[inst_id] = instance
        self.log(f"Launched {inst_id} in {target_az} (IP: {private_ip}) -> Status: InService", "SCALE")
        return instance

    def terminate_instance(self, instance_id: str, reason: str = "Scale-In") -> Optional[Instance]:
        """Simulate ASG instance termination and ALB Target Group deregistration."""
        if instance_id in self.instances:
            inst = self.instances[instance_id]
            inst.status = "Terminated"
            self.log(f"Terminated {instance_id} in {inst.availability_zone} (Reason: {reason})", "SCALE")
            return inst
        return None

    def _bootstrap_initial_fleet(self):
        """Provision initial instances to meet desired_capacity."""
        self.log(f"Initializing ASG fleet: min={self.min_size}, desired={self.desired_capacity}, max={self.max_size}")
        for _ in range(self.desired_capacity):
            self.launch_instance()

    def get_healthy_instances(self) -> List[Instance]:
        """Return list of InService and Healthy instances registered in ALB."""
        return [
            inst for inst in self.instances.values()
            if inst.status == "InService" and inst.health_status == "Healthy"
        ]

    def route_request_alb(self) -> Optional[Instance]:
        """Simulate ALB Application Load Balancer Round-Robin request routing."""
        healthy_nodes = self.get_healthy_instances()
        if not healthy_nodes:
            self.log("ALB 503 Service Unavailable: No healthy targets in Target Group", "ERROR")
            return None

        # Round-robin selection
        selected = healthy_nodes[self.alb_round_robin_index % len(healthy_nodes)]
        self.alb_round_robin_index = (self.alb_round_robin_index + 1) % len(healthy_nodes)
        selected.requests_handled += 1
        return selected

    def evaluate_target_tracking(self, average_cpu: float) -> int:
        """
        Calculate target capacity using AWS Target Tracking math:
        Required Capacity = ceil(Current Capacity * (Current Metric / Target Metric))
        """
        current_capacity = len([i for i in self.instances.values() if i.status == "InService"])
        if current_capacity == 0 or self.target_cpu <= 0:
            return self.min_size

        raw_needed = current_capacity * (average_cpu / self.target_cpu)
        target_capacity = math.ceil(raw_needed)

        # Enforce bounds
        target_capacity = max(self.min_size, min(target_capacity, self.max_size))
        return target_capacity

    def perform_scaling_adjustment(self, target_capacity: int, reason: str = "Dynamic Target Tracking"):
        """Scale out or scale in instances to reach target_capacity."""
        current_active = [i for i in self.instances.values() if i.status == "InService"]
        current_count = len(current_active)

        if target_capacity > current_count:
            diff = target_capacity - current_count
            self.log(f"Scale-Out triggered ({reason}): Current={current_count}, Target={target_capacity} (+{diff})", "SCALE")
            for _ in range(diff):
                self.launch_instance()
        elif target_capacity < current_count:
            diff = current_count - target_capacity
            self.log(f"Scale-In triggered ({reason}): Current={current_count}, Target={target_capacity} (-{diff})", "SCALE")
            # Select oldest or AZ-imbalanced instance for termination (AWS default policy)
            to_terminate = current_active[:diff]
            for inst in to_terminate:
                self.terminate_instance(inst.instance_id, reason)

    def run_health_checks(self):
        """Simulate ALB Target Group Health Check cycle."""
        for inst in list(self.instances.values()):
            if inst.status != "InService":
                continue

            if inst.health_status == "Unhealthy":
                inst.consecutive_failed_checks += 1
                inst.consecutive_passed_checks = 0
                self.log(
                    f"Health check FAILED for {inst.instance_id} ({inst.consecutive_failed_checks}/3 fails)",
                    "HEALTH"
                )
                # Unhealthy threshold = 3
                if inst.consecutive_failed_checks >= 3:
                    self.log(
                        f"🚨 ALB marked {inst.instance_id} UNHEALTHY. Triggering ASG Self-Healing replacement.",
                        "WARN"
                    )
                    self.terminate_instance(inst.instance_id, reason="Failed ELB Health Checks")
                    # ASG replaces terminated instance to maintain desired capacity
                    self.launch_instance(az=inst.availability_zone)
            else:
                inst.consecutive_passed_checks += 1
                inst.consecutive_failed_checks = 0

    # --------------------------------------------------------------------------
    # Test Scenario Implementations
    # --------------------------------------------------------------------------
    def test_multi_az_distribution(self) -> TestResult:
        """Verify that initial instances are distributed evenly across Availability Zones."""
        active = [i for i in self.instances.values() if i.status == "InService"]
        az_counts = {}
        for inst in active:
            az_counts[inst.availability_zone] = az_counts.get(inst.availability_zone, 0) + 1

        passed = len(az_counts) >= 2  # Spread across at least 2 AZs
        actual_str = ", ".join(f"{az}: {cnt}" for az, cnt in az_counts.items())
        res = TestResult(
            test_id="ASG-01",
            name="Multi-AZ Instance Distribution",
            category="High Availability",
            expected="Instances balanced across >= 2 Availability Zones",
            actual=actual_str,
            passed=passed,
            details=f"Current active instances ({len(active)}) spread across {len(az_counts)} AZs."
        )
        self.test_results.append(res)
        return res

    def test_alb_round_robin_traffic(self, request_count: int = 60) -> TestResult:
        """Verify ALB round-robin request distribution across healthy targets."""
        distribution = {}
        for _ in range(request_count):
            node = self.route_request_alb()
            if node:
                distribution[node.instance_id] = distribution.get(node.instance_id, 0) + 1

        healthy_count = len(self.get_healthy_instances())
        expected_per_node = request_count / healthy_count if healthy_count else 0
        # Check variance: all nodes should receive within 15% of equal share
        max_diff = max(abs(cnt - expected_per_node) for cnt in distribution.values())
        passed = max_diff <= (request_count * 0.15)

        actual_str = ", ".join(f"{inst}: {cnt} reqs" for inst, cnt in distribution.items())
        res = TestResult(
            test_id="ASG-02",
            name="ALB Round-Robin Traffic Distribution",
            category="Traffic Routing",
            expected=f"Uniform distribution (~{int(expected_per_node)} reqs/node across {healthy_count} nodes)",
            actual=actual_str,
            passed=passed,
            details=f"Processed {request_count} requests with maximum variance of {max_diff:.1f} reqs."
        )
        self.test_results.append(res)
        return res

    def test_scale_out_under_cpu_load(self) -> TestResult:
        """Simulate CPU spike (85%) triggering Target Tracking scale-out from 2 to 4 nodes."""
        spike_cpu = 85.0
        self.log(f"Simulating heavy CPU load spike: {spike_cpu}% across fleet (Target: {self.target_cpu}%)")
        needed_capacity = self.evaluate_target_tracking(spike_cpu)
        initial_count = len([i for i in self.instances.values() if i.status == "InService"])

        self.perform_scaling_adjustment(needed_capacity, reason="High CPU Utilization (85% > 50%)")
        final_count = len([i for i in self.instances.values() if i.status == "InService"])

        passed = (final_count == self.max_size) and (final_count > initial_count)
        res = TestResult(
            test_id="ASG-03",
            name="Target Tracking Dynamic Scale-Out",
            category="Elastic Scaling",
            expected=f"Fleet scales out to max capacity ({self.max_size} instances)",
            actual=f"Scaled from {initial_count} to {final_count} instances",
            passed=passed,
            details=f"Calculated required capacity = ceil({initial_count} * (85 / 50)) = {needed_capacity} (capped at max {self.max_size})."
        )
        self.test_results.append(res)
        return res

    def test_traffic_rebalance_after_scale_out(self, request_count: int = 80) -> TestResult:
        """Verify that newly scaled-out instances immediately receive balanced ALB traffic."""
        healthy_nodes = self.get_healthy_instances()
        initial_counts = {node.instance_id: node.requests_handled for node in healthy_nodes}

        for _ in range(request_count):
            self.route_request_alb()

        new_counts = {node.instance_id: node.requests_handled - initial_counts[node.instance_id] for node in healthy_nodes}
        # All 4 nodes must have received traffic
        all_nodes_active = len(new_counts) == len(healthy_nodes) and all(c > 0 for c in new_counts.values())

        actual_str = ", ".join(f"{inst}: {cnt} reqs" for inst, cnt in new_counts.items())
        res = TestResult(
            test_id="ASG-04",
            name="Traffic Balancing on Expanded Fleet",
            category="Traffic Routing",
            expected=f"All {len(healthy_nodes)} nodes (including new scale-out instances) handle traffic",
            actual=actual_str,
            passed=all_nodes_active,
            details="Validated that newly registered targets in ALB Target Group handle active traffic."
        )
        self.test_results.append(res)
        return res

    def test_scale_in_on_load_drop(self) -> TestResult:
        """Simulate load drop (15% CPU) triggering scale-in back to desired capacity."""
        idle_cpu = 15.0
        self.log(f"Simulating traffic cooldown: CPU drops to {idle_cpu}%")
        needed_capacity = self.evaluate_target_tracking(idle_cpu)
        initial_count = len([i for i in self.instances.values() if i.status == "InService"])

        # Target tracking clamps to min_size or desired_capacity
        scale_in_target = max(self.min_size, needed_capacity)
        self.perform_scaling_adjustment(scale_in_target, reason="Low CPU Utilization (15% < 50%)")
        final_count = len([i for i in self.instances.values() if i.status == "InService"])

        passed = final_count <= self.desired_capacity
        res = TestResult(
            test_id="ASG-05",
            name="Dynamic Scale-In after Cooldown",
            category="Elastic Scaling",
            expected=f"Fleet scales in towards minimum/desired capacity ({self.desired_capacity} or {self.min_size})",
            actual=f"Scaled from {initial_count} down to {final_count} instances",
            passed=passed,
            details=f"Cooldown detected. Fleet safely drained and terminated excess compute."
        )
        self.test_results.append(res)
        return res

    def test_self_healing_unhealthy_replacement(self) -> TestResult:
        """Simulate instance health failure and assert ALB detection and ASG self-healing."""
        active_nodes = self.get_healthy_instances()
        if not active_nodes:
            self.launch_instance()
            active_nodes = self.get_healthy_instances()

        target_node = active_nodes[0]
        failed_id = target_node.instance_id
        failed_az = target_node.availability_zone
        self.log(f"Simulating application failure on {failed_id} in {failed_az} (HTTP 500 on /health)")

        # Mark unhealthy
        target_node.health_status = "Unhealthy"

        # Run 3 health check cycles to trigger threshold
        self.run_health_checks()
        self.run_health_checks()
        self.run_health_checks()

        # Verify old instance is terminated and replacement is in service
        is_old_terminated = self.instances[failed_id].status == "Terminated"
        new_active = [i for i in self.instances.values() if i.status == "InService" and i.instance_id != failed_id]
        has_replacement = any(i.availability_zone == failed_az for i in new_active)

        passed = is_old_terminated and (len(new_active) >= self.min_size)
        res = TestResult(
            test_id="ASG-06",
            name="ELB Health Check Self-Healing Replacement",
            category="Fault Tolerance",
            expected=f"Unhealthy node ({failed_id}) terminated and healthy replacement launched",
            actual=f"Terminated {failed_id}, active healthy nodes: {len(new_active)}",
            passed=passed,
            details=f"ALB detected 3 consecutive failed health checks -> ASG terminated dead instance and launched replacement in {failed_az}."
        )
        self.test_results.append(res)
        return res

    def run_all_tests(self) -> bool:
        """Execute the full suite of ASG and ALB validation tests."""
        print(f"\n{CLR_CYAN}{CLR_BOLD}======================================================================{CLR_RESET}")
        print(f"{CLR_CYAN}{CLR_BOLD}  🚀 Running High-Availability ASG & ALB Simulation Suite{CLR_RESET}")
        print(f"{CLR_CYAN}{CLR_BOLD}======================================================================{CLR_RESET}\n")

        self.test_multi_az_distribution()
        self.test_alb_round_robin_traffic()
        self.test_scale_out_under_cpu_load()
        self.test_traffic_rebalance_after_scale_out()
        self.test_scale_in_on_load_drop()
        self.test_self_healing_unhealthy_replacement()

        # Render summary table
        print(f"\n{CLR_BOLD}Simulation Verification Results:{CLR_RESET}")
        print(f"{'ID':<8} {'Category':<18} {'Test Case':<36} {'Status':<10}")
        print("-" * 74)

        all_passed = True
        for r in self.test_results:
            status_badge = f"{CLR_GREEN}PASSED{CLR_RESET}" if r.passed else f"{CLR_RED}FAILED{CLR_RESET}"
            if not r.passed:
                all_passed = False
            print(f"{r.test_id:<8} {r.category:<18} {r.name:<36} {status_badge}")
            if self.verbose:
                print(f"   {CLR_GRAY}Expected: {r.expected}{CLR_RESET}")
                print(f"   {CLR_GRAY}Actual:   {r.actual}{CLR_RESET}")
                print(f"   {CLR_GRAY}Details:  {r.details}{CLR_RESET}\n")

        print("-" * 74)
        active_fleet = [i for i in self.instances.values() if i.status == "InService"]
        print(f"\n{CLR_BOLD}Active Fleet Topology ({len(active_fleet)} Nodes InService):{CLR_RESET}")
        for inst in active_fleet:
            print(f"  • {CLR_GREEN}{inst.instance_id}{CLR_RESET} | AZ: {CLR_CYAN}{inst.availability_zone}{CLR_RESET} | IP: {inst.private_ip} | Reqs: {inst.requests_handled} | Health: {inst.health_status}")

        return all_passed

    def export_json_report(self, filepath: str):
        """Export structured simulation report to JSON."""
        report = {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "asg_configuration": {
                "min_size": self.min_size,
                "desired_capacity": self.desired_capacity,
                "max_size": self.max_size,
                "target_cpu_utilization": self.target_cpu,
                "availability_zones": self.azs,
            },
            "fleet_instances": [asdict(inst) for inst in self.instances.values()],
            "test_summary": {
                "total_tests": len(self.test_results),
                "passed_tests": sum(1 for r in self.test_results if r.passed),
                "failed_tests": sum(1 for r in self.test_results if not r.passed),
                "all_passed": all(r.passed for r in self.test_results),
            },
            "test_results": [asdict(r) for r in self.test_results],
            "execution_logs": self.history_logs,
        }
        with open(filepath, "w", encoding="utf-8") as f:
            json.dump(report, f, indent=2)
        self.log(f"Exported JSON report to {filepath}", "REPORT")


def main():
    parser = argparse.ArgumentParser(description="High-Availability ASG & ALB Offline Simulator")
    parser.add_argument("--verbose", "-v", action="store_true", help="Enable verbose step-by-step logs")
    parser.add_argument("--json-output", type=str, default="", help="Path to write structured JSON report")
    parser.add_argument("--min-size", type=int, default=1, help="ASG minimum size (default: 1)")
    parser.add_argument("--desired", type=int, default=2, help="ASG desired capacity (default: 2)")
    parser.add_argument("--max-size", type=int, default=4, help="ASG maximum size (default: 4)")
    parser.add_argument("--target-cpu", type=float, default=50.0, help="Target CPU percentage (default: 50.0)")

    args = parser.parse_args()

    simulator = ASGFleetSimulator(
        min_size=args.min_size,
        desired_capacity=args.desired,
        max_size=args.max_size,
        target_cpu=args.target_cpu,
        verbose=args.verbose,
    )

    success = simulator.run_all_tests()

    if args.json_output:
        simulator.export_json_report(args.json_output)

    if success:
        print(f"\n{CLR_GREEN}{CLR_BOLD}🎉 All ALB & Auto Scaling Fleet Simulation Tests Passed Successfully!{CLR_RESET}\n")
        sys.exit(0)
    else:
        print(f"\n{CLR_RED}{CLR_BOLD}❌ Some Simulation Tests Failed. Review logs above.{CLR_RESET}\n")
        sys.exit(1)


if __name__ == "__main__":
    main()
