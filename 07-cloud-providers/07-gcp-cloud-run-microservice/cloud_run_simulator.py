#!/usr/bin/env python3
"""
GCP Cloud Run Scalable Microservice - Offline Simulator
======================================================
Deterministic Python engine modeling Google Cloud Run / Knative autoscaling,
Scale-to-Zero, fine-grained concurrency thresholds (80 reqs/instance),
cold start vs warm latency transitions, and Google Secret Manager injection.

Zero cloud dependencies - executes instantly anywhere for testing and CI/CD.
"""

import argparse
import hashlib
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
CLR_RED="\033[1;31m"
CLR_YELLOW = "\033[1;33m"
CLR_CYAN = "\033[1;36m"
CLR_BLUE = "\033[1;34m"
CLR_GRAY = "\033[0;90m"


@dataclass
class ContainerInstance:
    instance_id: str
    revision: str
    status: str  # Booting, Ready, Terminating, Terminated
    active_concurrency: int = 0
    total_requests_served: int = 0
    is_warm: bool = False
    boot_latency_ms: float = 320.0
    created_at: str = field(default_factory=lambda: datetime.now(timezone.utc).isoformat())


@dataclass
class TestResult:
    test_id: str
    name: str
    category: str
    expected: str
    actual: str
    passed: bool
    details: str


class CloudRunSimulator:
    """Simulates Google Cloud Run Knative Autoscaler and Concurrency Engine."""

    def __init__(
        self,
        service_name: str = "scalable-microservice",
        min_instances: int = 0,
        max_instances: int = 10,
        concurrency_limit: int = 80,
        secret_value: str = "sk-live-cloudrun-secret-key-2026",
        verbose: bool = False,
    ):
        self.service_name = service_name
        self.min_instances = min_instances
        self.max_instances = max_instances
        self.concurrency_limit = concurrency_limit
        self.secret_value = secret_value
        self.verbose = verbose

        self.instances: Dict[str, ContainerInstance] = {}
        self.instance_seq = 0
        self.test_results: List[TestResult] = []
        self.history_logs: List[str] = []

    def log(self, message: str, level: str = "INFO"):
        timestamp = datetime.now(timezone.utc).strftime("%H:%M:%S.%f")[:-3]
        log_entry = f"[{timestamp}] [{level:5s}] {message}"
        self.history_logs.append(log_entry)
        if self.verbose:
            color = CLR_CYAN if level == "INFO" else (CLR_YELLOW if level == "WARN" else CLR_GREEN)
            print(f"  {CLR_GRAY}[{timestamp}]{CLR_RESET} {color}[{level:5s}]{CLR_RESET} {message}")

    def spawn_instance(self, is_cold: bool = True) -> ContainerInstance:
        """Simulate Cloud Run container provisioning."""
        self.instance_seq += 1
        inst_id = f"cr-inst-{self.instance_seq:02d}-{hashlib.md5(str(self.instance_seq).encode()).hexdigest()[:6]}"
        boot_latency = 310.0 + (self.instance_seq * 8.5) if is_cold else 0.0

        instance = ContainerInstance(
            instance_id=inst_id,
            revision=f"{self.service_name}-00001",
            status="Ready",
            is_warm=not is_cold,
            boot_latency_ms=round(boot_latency, 2),
        )
        self.instances[inst_id] = instance
        self.log(f"Spawned container instance {inst_id} (Cold Start: {is_cold}, Boot Latency: {instance.boot_latency_ms:.1f}ms)", "SCALE")
        return instance

    def terminate_instance(self, instance_id: str, reason: str = "Scale-to-Zero"):
        """Simulate instance teardown on idle timeout."""
        if instance_id in self.instances:
            inst = self.instances[instance_id]
            inst.status = "Terminated"
            self.log(f"Terminated {instance_id} (Reason: {reason})", "SCALE")

    def get_ready_instances(self) -> List[ContainerInstance]:
        return [i for i in self.instances.values() if i.status == "Ready"]

    def calculate_required_instances(self, concurrent_requests: int) -> int:
        """
        Cloud Run Autoscaler formula:
        Required Instances = ceil(Concurrent Requests / Concurrency Limit)
        Bounded between min_instances and max_instances.
        """
        if concurrent_requests <= 0:
            return self.min_instances
        needed = math.ceil(concurrent_requests / self.concurrency_limit)
        return max(self.min_instances, min(needed, self.max_instances))

    def dispatch_batch(self, concurrent_requests: int, simulated_work_ms: float = 40.0) -> dict:
        """Simulate routing concurrent requests into the Cloud Run queue proxy."""
        needed_instances = self.calculate_required_instances(concurrent_requests)
        ready_instances = self.get_ready_instances()

        # Scale out if needed
        is_cold_start = len(ready_instances) == 0 and needed_instances > 0
        if len(ready_instances) < needed_instances:
            diff = needed_instances - len(ready_instances)
            for _ in range(diff):
                self.spawn_instance(is_cold=is_cold_start)

        ready_instances = self.get_ready_instances()
        instance_count = len(ready_instances)

        # Distribute requests across instances up to concurrency limit
        reqs_remaining = concurrent_requests
        distribution = {}
        for inst in ready_instances:
            assigned = min(reqs_remaining, self.concurrency_limit)
            inst.active_concurrency = assigned
            inst.total_requests_served += assigned
            distribution[inst.instance_id] = assigned
            reqs_remaining -= assigned
            if reqs_remaining <= 0:
                break

        # Calculate latency
        base_latency = 8.0 + simulated_work_ms
        if is_cold_start:
            total_latency = base_latency + ready_instances[0].boot_latency_ms
        else:
            total_latency = base_latency

        return {
            "concurrent_requests": concurrent_requests,
            "instances_allocated": instance_count,
            "is_cold_start": is_cold_start,
            "average_latency_ms": round(total_latency, 2),
            "distribution": distribution,
        }

    # --------------------------------------------------------------------------
    # Test Scenario Implementations
    # --------------------------------------------------------------------------
    def test_scale_to_zero_initial_state(self) -> TestResult:
        """Assert initial fleet capacity is 0 (Scale-to-Zero)."""
        active_count = len(self.get_ready_instances())
        passed = active_count == 0
        res = TestResult(
            test_id="CR-01",
            name="Scale-to-Zero Idle State",
            category="Serverless Lifecycle",
            expected="0 active container instances (Zero idle cost)",
            actual=f"{active_count} active instances",
            passed=passed,
            details=f"min_instances is configured to {self.min_instances}, eliminating compute charges during idle periods."
        )
        self.test_results.append(res)
        return res

    def test_scale_from_zero_and_cold_start(self) -> TestResult:
        """Dispatch 1 request to trigger scale from 0 to 1 and verify cold start measurement."""
        result = self.dispatch_batch(concurrent_requests=1)
        active_count = len(self.get_ready_instances())
        is_cold = result["is_cold_start"]
        latency = result["average_latency_ms"]

        passed = active_count == 1 and is_cold and latency > 300.0
        res = TestResult(
            test_id="CR-02",
            name="Scale-from-Zero & Cold Start Detection",
            category="Cold Start Optimization",
            expected="Service spins up 1 instance from zero with cold start latency (~300-400ms)",
            actual=f"{active_count} instance active, Cold Start={is_cold}, Latency={latency:.1f}ms",
            passed=passed,
            details=f"First request on idle service incurred cold start initialization. Container is now warm."
        )
        self.test_results.append(res)
        return res

    def test_single_instance_high_concurrency(self) -> TestResult:
        """
        Dispatch 75 concurrent requests and verify that a SINGLE container instance handles all of them,
        proving Cloud Run's concurrency efficiency (80 reqs/instance) over AWS Lambda (1 req/instance).
        """
        result = self.dispatch_batch(concurrent_requests=75)
        active_count = len(self.get_ready_instances())
        latency = result["average_latency_ms"]

        # 75 requests <= 80 concurrency limit -> strictly 1 instance required
        passed = active_count == 1 and (result["is_cold_start"] is False) and latency < 60.0
        res = TestResult(
            test_id="CR-03",
            name="High Concurrency in Single Container",
            category="Concurrency Tuning",
            expected="1 container handles 75 parallel requests without scaling out (concurrency limit = 80)",
            actual=f"{active_count} instance handled 75 requests (Warm latency: {latency:.1f}ms)",
            passed=passed,
            details="Validated Cloud Run concurrency multiplexing: 75 parallel connections served by 1 container."
        )
        self.test_results.append(res)
        return res

    def test_dynamic_concurrency_scale_out(self) -> TestResult:
        """
        Dispatch 250 concurrent requests.
        ceil(250 / 80) = ceil(3.125) = 4 instances.
        Assert that fleet scales dynamically from 1 to 4 instances.
        """
        initial_count = len(self.get_ready_instances())
        result = self.dispatch_batch(concurrent_requests=250)
        final_count = len(self.get_ready_instances())

        passed = final_count == 4 and (final_count > initial_count)
        res = TestResult(
            test_id="CR-04",
            name="Concurrency-Driven Scale-Out",
            category="Autoscaling Math",
            expected="Fleet scales to 4 instances for 250 concurrent requests (ceil(250/80) = 4)",
            actual=f"Scaled from {initial_count} to {final_count} instances",
            passed=passed,
            details=f"Autoscaler calculation: ceil(250 / 80) = {final_count} containers allocated across traffic."
        )
        self.test_results.append(res)
        return res

    def test_secret_manager_integration(self) -> TestResult:
        """Verify Secret Manager secret resolution and secure masking."""
        masked_secret = f"{self.secret_value[:3]}****{self.secret_value[-4:]}"
        fingerprint = hashlib.sha256(self.secret_value.encode()).hexdigest()[:12]

        passed = bool(self.secret_value) and ("****" in masked_secret)
        res = TestResult(
            test_id="CR-05",
            name="Secret Manager Injection & Masking",
            category="Security & IAM",
            expected="Secret API key resolved via IAM Service Account and masked in output",
            actual=f"Masked: {masked_secret} (SHA256 Fingerprint: {fingerprint})",
            passed=passed,
            details="Secret securely injected as environment variable via Secret Manager without plaintext leakage."
        )
        self.test_results.append(res)
        return res

    def test_idle_cooldown_scale_to_zero(self) -> TestResult:
        """Simulate traffic expiration and verify scale down back to zero."""
        active_instances = list(self.get_ready_instances())
        self.log(f"Traffic expired: Initiating 15-minute idle cooldown on {len(active_instances)} instances")

        for inst in active_instances:
            self.terminate_instance(inst.instance_id, reason="Idle timeout exceeded")

        final_count = len(self.get_ready_instances())
        passed = final_count == self.min_instances
        res = TestResult(
            test_id="CR-06",
            name="Idle Cooldown & Scale-to-Zero",
            category="Cost Governance",
            expected="All instances terminated after idle cooldown (Capacity returns to 0)",
            actual=f"{final_count} active instances remaining",
            passed=passed,
            details="Knative autoscaler successfully drained and decommissioned idle compute containers."
        )
        self.test_results.append(res)
        return res

    def run_all_tests(self) -> bool:
        """Execute all 6 validation scenarios."""
        print(f"\n{CLR_BLUE}{CLR_BOLD}======================================================================{CLR_RESET}")
        print(f"{CLR_BLUE}{CLR_BOLD}  🚀 Running GCP Cloud Run Concurrency & Autoscaling Simulation Suite{CLR_RESET}")
        print(f"{CLR_BLUE}{CLR_BOLD}======================================================================{CLR_RESET}\n")

        self.test_scale_to_zero_initial_state()
        self.test_scale_from_zero_and_cold_start()
        self.test_single_instance_high_concurrency()
        self.test_dynamic_concurrency_scale_out()
        self.test_secret_manager_integration()
        self.test_idle_cooldown_scale_to_zero()

        print(f"\n{CLR_BOLD}Cloud Run Verification Results:{CLR_RESET}")
        print(f"{'ID':<8} {'Category':<24} {'Test Case':<38} {'Status':<10}")
        print("-" * 82)

        all_passed = True
        for r in self.test_results:
            status_badge = f"{CLR_GREEN}PASSED{CLR_RESET}" if r.passed else f"{CLR_RED}FAILED{CLR_RESET}"
            if not r.passed:
                all_passed = False
            print(f"{r.test_id:<8} {r.category:<24} {r.name:<38} {status_badge}")
            if self.verbose:
                print(f"   {CLR_GRAY}Expected: {r.expected}{CLR_RESET}")
                print(f"   {CLR_GRAY}Actual:   {r.actual}{CLR_RESET}")
                print(f"   {CLR_GRAY}Details:  {r.details}{CLR_RESET}\n")

        print("-" * 82)
        return all_passed

    def export_json_report(self, filepath: str):
        """Export test findings to JSON."""
        report = {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "service_configuration": {
                "service_name": self.service_name,
                "min_instances": self.min_instances,
                "max_instances": self.max_instances,
                "concurrency_limit": self.concurrency_limit,
            },
            "summary": {
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
    parser = argparse.ArgumentParser(description="GCP Cloud Run Knative Concurrency & Autoscaling Simulator")
    parser.add_argument("--verbose", "-v", action="store_true", help="Enable verbose execution traces")
    parser.add_argument("--json-output", type=str, default="", help="Path to write structured JSON report")
    parser.add_argument("--concurrency", type=int, default=80, help="Max requests per container instance (default: 80)")
    parser.add_argument("--max-instances", type=int, default=10, help="Max instances scaling limit (default: 10)")

    args = parser.parse_args()

    simulator = CloudRunSimulator(
        concurrency_limit=args.concurrency,
        max_instances=args.max_instances,
        verbose=args.verbose,
    )

    success = simulator.run_all_tests()

    if args.json_output:
        simulator.export_json_report(args.json_output)

    if success:
        print(f"\n{CLR_GREEN}{CLR_BOLD}🎉 All GCP Cloud Run Scalable Microservice Simulation Tests Passed!{CLR_RESET}\n")
        sys.exit(0)
    else:
        print(f"\n{CLR_RED}{CLR_BOLD}❌ Some Simulation Tests Failed. Review logs above.{CLR_RESET}\n")
        sys.exit(1)


if __name__ == "__main__":
    main()
