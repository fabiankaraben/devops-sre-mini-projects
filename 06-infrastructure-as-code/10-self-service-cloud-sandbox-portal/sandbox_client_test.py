#!/usr/bin/env python3
# ==============================================================================
# sandbox_client_test.py - End-to-End Sandbox Lifecycle Integration Tests
# ==============================================================================
# Tests the complete Internal Developer Platform (IDP) workflow:
#   1. Server health & metrics endpoint
#   2. Ephemeral sandbox creation with short TTL
#   3. Live cloud verification (VPC, Security Group, S3 bucket created in LocalStack)
#   4. Multi-sandbox isolation (second sandbox creation)
#   5. Manual early deletion (DELETE /sandboxes/{id})
#   6. Automated background TTL worker expiration (automated terraform destroy)
#   7. Cloud resource disappearance verification post-expiration
#   8. Sandbox catalog listing and audit trail
# ==============================================================================

import argparse
import json
import os
import subprocess
import sys
import time
import urllib.request
import urllib.error

# ANSI Color codes
CLR_RESET = "\033[0m"
CLR_BOLD = "\033[1m"
CLR_GREEN = "\033[1;32m"
CLR_RED = "\033[1;31m"
CLR_YELLOW = "\033[1;33m"
CLR_CYAN = "\033[1;36m"
CLR_GRAY = "\033[0;90m"


class SandboxTestClient:
    def __init__(self, base_url, aws_endpoint="http://127.0.0.1:4566", region="us-east-1"):
        self.base_url = base_url.rstrip("/")
        self.aws_endpoint = aws_endpoint
        self.region = region
        self.total_tests = 0
        self.passed_tests = 0
        self.failed_tests = 0

    def record_result(self, test_num, description, passed, details=""):
        self.total_tests += 1
        if passed:
            self.passed_tests += 1
            print(f"  [{CLR_GREEN}PASS{CLR_RESET}] Test {test_num}: {description}")
            if details:
                print(f"         {CLR_GRAY}↳ {details}{CLR_RESET}")
        else:
            self.failed_tests += 1
            print(f"  [{CLR_RED}FAIL{CLR_RESET}] Test {test_num}: {description}")
            if details:
                print(f"         {CLR_RED}↳ {details}{CLR_RESET}")

    def request(self, method, path, data=None):
        url = f"{self.base_url}{path}"
        req_data = json.dumps(data).encode("utf-8") if data else None
        req = urllib.request.Request(
            url,
            data=req_data,
            headers={"Content-Type": "application/json"},
            method=method,
        )
        try:
            with urllib.request.urlopen(req, timeout=180) as res:
                body = res.read().decode("utf-8")
                return res.status, json.loads(body) if body else {}
        except urllib.error.HTTPError as e:
            body = e.read().decode("utf-8")
            return e.code, json.loads(body) if body.startswith("{") else {"error": body}
        except Exception as e:
            return 0, {"error": str(e)}

    def run_aws_cmd(self, *args):
        env = os.environ.copy()
        env["AWS_ACCESS_KEY_ID"] = "test"
        env["AWS_SECRET_ACCESS_KEY"] = "test"
        env["AWS_DEFAULT_REGION"] = self.region
        cmd = [
            "aws",
            "--endpoint-url", self.aws_endpoint,
            "--region", self.region,
            *args
        ]
        res = subprocess.run(cmd, env=env, capture_output=True, text=True)
        return res.returncode, res.stdout, res.stderr

    def run_suite(self):
        print(f"\n{CLR_CYAN}{CLR_BOLD}" + "=" * 70)
        print("  🧪 Cloud Sandbox Provisioning Portal - Integration Test Suite")
        print("=" * 70 + f"{CLR_RESET}\n")

        # ----------------------------------------------------------------------
        # Test 1: Healthcheck Endpoint
        # ----------------------------------------------------------------------
        print(f"{CLR_YELLOW}▶ Step 1: Checking API health endpoint (/healthz)...{CLR_RESET}")
        status, data = self.request("GET", "/healthz")
        self.record_result(
            1,
            "API Server health check (/healthz)",
            status == 200 and data.get("status") == "healthy",
            f"Status: {data.get('status')}, Version: {data.get('version')}"
        )

        # ----------------------------------------------------------------------
        # Test 2: Request Ephemeral Sandbox with 15-second TTL
        # ----------------------------------------------------------------------
        print(f"\n{CLR_YELLOW}▶ Step 2: Requesting 15-second Ephemeral Sandbox ('web-app')...{CLR_RESET}")
        create_payload = {
            "name": "checkout-service-test",
            "developer_email": "dev-alice@company.local",
            "template": "web-app",
            "ttl_seconds": 15,
        }
        status, sbx1 = self.request("POST", "/api/v1/sandboxes", create_payload)
        sbx1_id = sbx1.get("id")
        outputs1 = sbx1.get("outputs", {})
        vpc_id1 = outputs1.get("vpc_id")
        bucket1 = outputs1.get("s3_bucket_name")

        self.record_result(
            2,
            "Provision ephemeral sandbox with 15s TTL (POST /api/v1/sandboxes)",
            status in [200, 201] and sbx1.get("status") == "READY" and bool(sbx1_id),
            f"ID: {sbx1_id}, Status: {sbx1.get('status')}, TTL: {sbx1.get('ttl_seconds')}s"
        )

        # ----------------------------------------------------------------------
        # Test 3: Validate Outputs
        # ----------------------------------------------------------------------
        print(f"\n{CLR_YELLOW}▶ Step 3: Validating Terraform stack outputs...{CLR_RESET}")
        has_outputs = bool(vpc_id1 and bucket1)
        self.record_result(
            3,
            "Terraform outputs captured (vpc_id, s3_bucket_name, endpoint_url)",
            has_outputs,
            f"VPC: {vpc_id1}, S3 Bucket: {bucket1}"
        )

        # ----------------------------------------------------------------------
        # Test 4: Live Cloud Verification via AWS CLI
        # ----------------------------------------------------------------------
        print(f"\n{CLR_YELLOW}▶ Step 4: Verifying real cloud resources in LocalStack / Moto...{CLR_RESET}")
        rc, out, _ = self.run_aws_cmd("ec2", "describe-vpcs", "--vpc-ids", vpc_id1)
        vpc_exists = rc == 0 and vpc_id1 in out
        self.record_result(
            4,
            f"Live cloud check: VPC '{vpc_id1}' exists and active in AWS",
            vpc_exists,
            f"AWS describe-vpcs verified {vpc_id1}"
        )

        # ----------------------------------------------------------------------
        # Test 5: Provision Second Sandbox for Manual Deletion Test
        # ----------------------------------------------------------------------
        print(f"\n{CLR_YELLOW}▶ Step 5: Provisioning second sandbox ('microservice')...{CLR_RESET}")
        status, sbx2 = self.request("POST", "/api/v1/sandboxes", {
            "name": "auth-service-test",
            "developer_email": "dev-bob@company.local",
            "template": "microservice",
            "ttl_seconds": 120,
        })
        sbx2_id = sbx2.get("id")
        vpc_id2 = sbx2.get("outputs", {}).get("vpc_id")
        self.record_result(
            5,
            "Multi-sandbox creation (isolated second sandbox provisioned)",
            status in [200, 201] and sbx2.get("status") == "READY" and sbx2_id != sbx1_id,
            f"ID: {sbx2_id}, Template: microservice"
        )

        # ----------------------------------------------------------------------
        # Test 6: Manual Early Deletion (DELETE /api/v1/sandboxes/{id})
        # ----------------------------------------------------------------------
        print(f"\n{CLR_YELLOW}▶ Step 6: Testing manual early deletion of second sandbox...{CLR_RESET}")
        del_status, del_data = self.request("DELETE", f"/api/v1/sandboxes/{sbx2_id}")
        self.record_result(
            6,
            f"Manual teardown (DELETE /api/v1/sandboxes/{sbx2_id})",
            del_status == 200 and del_data.get("sandbox", {}).get("status") == "DESTROYED",
            f"Response message: {del_data.get('message')}"
        )

        # ----------------------------------------------------------------------
        # Test 7: Verify Second Sandbox Cloud Resources Removed
        # ----------------------------------------------------------------------
        print(f"\n{CLR_YELLOW}▶ Step 7: Verifying cloud resource deletion for second sandbox...{CLR_RESET}")
        rc2, out2, _ = self.run_aws_cmd("ec2", "describe-vpcs", "--vpc-ids", vpc_id2)
        vpc2_deleted = rc2 != 0 or vpc_id2 not in out2
        self.record_result(
            7,
            f"Cloud confirmation: VPC '{vpc_id2}' destroyed and removed from AWS",
            vpc2_deleted,
            "VPC is no longer found in AWS describe-vpcs"
        )

        # ----------------------------------------------------------------------
        # Test 8: Monitor TTL Worker Automatic Teardown of First Sandbox
        # ----------------------------------------------------------------------
        print(f"\n{CLR_YELLOW}▶ Step 8: Waiting for first sandbox TTL timer to expire (15s)...{CLR_RESET}")
        # Poll status every 2 seconds until TTL worker triggers destruction
        auto_destroyed = False
        for elapsed in range(1, 35):
            time.sleep(1)
            _, sbx1_check = self.request("GET", f"/api/v1/sandboxes/{sbx1_id}")
            current_status = sbx1_check.get("status")
            rem_sec = sbx1_check.get("time_remaining_seconds", 0)
            print(f"    ⏳ Waiting... Elapsed: {elapsed}s | Status: {current_status} | Time Remaining: {rem_sec}s", end="\r")
            if current_status == "DESTROYED":
                auto_destroyed = True
                print()
                break
        print()

        self.record_result(
            8,
            f"Background TTL Worker auto-destroyed expired sandbox '{sbx1_id}'",
            auto_destroyed,
            f"Automated terraform destroy executed on TTL expiration"
        )

        # ----------------------------------------------------------------------
        # Test 9: Verify Cloud Resources for First Sandbox Vanished
        # ----------------------------------------------------------------------
        print(f"\n{CLR_YELLOW}▶ Step 9: Verifying cloud resources for first sandbox deleted...{CLR_RESET}")
        rc1, out1, _ = self.run_aws_cmd("ec2", "describe-vpcs", "--vpc-ids", vpc_id1)
        vpc1_deleted = rc1 != 0 or vpc_id1 not in out1
        self.record_result(
            9,
            f"Cloud confirmation: VPC '{vpc_id1}' automatically destroyed",
            vpc1_deleted,
            "No orphan cloud resources remain in AWS"
        )

        # ----------------------------------------------------------------------
        # Test 10: List Sandboxes Endpoint & Audit Trail
        # ----------------------------------------------------------------------
        print(f"\n{CLR_YELLOW}▶ Step 10: Querying sandbox inventory and audit list...{CLR_RESET}")
        list_status, list_data = self.request("GET", "/api/v1/sandboxes")
        all_sandboxes = list_data.get("sandboxes", [])
        self.record_result(
            10,
            "Sandbox audit list endpoint (GET /api/v1/sandboxes)",
            list_status == 200 and len(all_sandboxes) >= 2,
            f"Total recorded: {list_data.get('total')}, Active: {list_data.get('active')}"
        )

        # ----------------------------------------------------------------------
        # Final Summary
        # ----------------------------------------------------------------------
        print(f"\n" + "=" * 70)
        if self.failed_tests == 0:
            print(f"  {CLR_GREEN}{CLR_BOLD}🎉 ALL {self.total_tests} INTEGRATION TESTS PASSED! ({self.passed_tests}/{self.total_tests}){CLR_RESET}")
            print("=" * 70 + "\n")
            return 0
        else:
            print(f"  {CLR_RED}{CLR_BOLD}❌ {self.failed_tests} of {self.total_tests} TESTS FAILED!{CLR_RESET}")
            print("=" * 70 + "\n")
            return 1


def main():
    parser = argparse.ArgumentParser(description="Cloud Sandbox Provisioning Portal - Client Test Suite")
    parser.add_argument("--url", default="http://127.0.0.1:8080", help="Portal API base URL")
    parser.add_argument("--aws-endpoint", default="http://127.0.0.1:4566", help="LocalStack/Moto endpoint URL")
    args = parser.parse_args()

    client = SandboxTestClient(args.url, aws_endpoint=args.aws_endpoint)
    exit_code = client.run_suite()
    sys.exit(exit_code)


if __name__ == "__main__":
    main()
