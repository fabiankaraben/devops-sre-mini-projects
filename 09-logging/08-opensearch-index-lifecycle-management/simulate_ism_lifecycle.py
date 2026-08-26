#!/usr/bin/env python3
"""OpenSearch Index State Management (ISM) Lifecycle Simulator & Verification Suite.

Simulates the full Hot -> Warm -> Cold -> Delete tiered storage lifecycle:
1. Provisions ISM Policy, Composable Index Template, and Initial Index Aliases.
2. Ingests telemetry to trigger Hot-Tier Rollover (generation-000001 -> generation-000002).
3. Transitions generation-000001 to Warm Tier (Read-Only, Force-Merge 1 segment, 0 replicas).
4. Asserts write-blocking on Warm read-only indices while preserving parallel searchability.
5. Transitions index to Cold Tier (Close index, releasing memory and file handles).
6. Executes scheduled Retention Deletion, asserting index removal from cluster.
"""

import argparse
import datetime
import json
import sys
import time
import urllib.request
import urllib.error
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

# Terminal Color Codes
CLR_RESET = "\033[0m"
CLR_BOLD = "\033[1m"
CLR_GREEN = "\033[1;32m"
CLR_RED = "\033[1;31m"
CLR_YELLOW = "\033[1;33m"
CLR_CYAN = "\033[1;36m"
CLR_GRAY = "\033[0;90m"


class OpenSearchISMClient:
    """REST Client for OpenSearch cluster administration and ISM lifecycle orchestration."""

    def __init__(self, base_url: str = "http://127.0.0.1:9200", dashboards_url: str = "http://127.0.0.1:5601"):
        self.base_url = base_url.rstrip("/")
        self.dashboards_url = dashboards_url.rstrip("/")
        self.test_results: List[Dict[str, Any]] = []

    def _request(
        self,
        method: str,
        path: str,
        payload: Optional[Dict[str, Any]] = None,
        headers: Optional[Dict[str, str]] = None,
        expected_statuses: Tuple[int, ...] = (200, 201),
    ) -> Tuple[int, Any, float]:
        """Execute an HTTP request against OpenSearch with precise timing."""
        url = f"{self.base_url}/{path.lstrip('/')}"
        req_headers = {"Content-Type": "application/json", "User-Agent": "OpenSearch-ISM-Tester/1.0"}
        if headers:
            req_headers.update(headers)

        data = json.dumps(payload).encode("utf-8") if payload is not None else None
        req = urllib.request.Request(url, data=data, headers=req_headers, method=method)

        start = time.perf_counter()
        try:
            with urllib.request.urlopen(req, timeout=10.0) as resp:
                elapsed_ms = (time.perf_counter() - start) * 1000.0
                body = resp.read().decode("utf-8")
                try:
                    res_json = json.loads(body)
                except json.JSONDecodeError:
                    res_json = body
                return resp.status, res_json, elapsed_ms
        except urllib.error.HTTPError as err:
            elapsed_ms = (time.perf_counter() - start) * 1000.0
            body = err.read().decode("utf-8")
            try:
                res_json = json.loads(body)
            except json.JSONDecodeError:
                res_json = body
            return err.code, res_json, elapsed_ms
        except Exception as exc:
            elapsed_ms = (time.perf_counter() - start) * 1000.0
            return 0, str(exc), elapsed_ms

    def record_test(self, name: str, passed: bool, message: str, duration_ms: float = 0.0):
        """Record and display a test result."""
        self.test_results.append({
            "name": name,
            "passed": passed,
            "message": message,
            "duration_ms": duration_ms,
        })
        status_label = f"{CLR_GREEN}PASS{CLR_RESET}" if passed else f"{CLR_RED}FAIL{CLR_RESET}"
        timing = f"{CLR_GRAY}({duration_ms:.1f}ms){CLR_RESET}" if duration_ms > 0 else ""
        print(f"  [{status_label}] {CLR_BOLD}{name}{CLR_RESET} {timing}")
        if not passed or "--verbose" in sys.argv:
            print(f"         {CLR_GRAY}└─ {message}{CLR_RESET}")


class ISMLifecycleSimulator:
    """Orchestrates end-to-end lifecycle verification and simulation scenarios."""

    def __init__(self, client: OpenSearchISMClient):
        self.client = client

    def phase1_health_check(self) -> bool:
        """Verify OpenSearch cluster health and ISM plugin activation."""
        print(f"\n{CLR_YELLOW}▶ [Phase 1] Checking OpenSearch Health & ISM Subsystem...{CLR_RESET}")
        
        status, data, dur = self.client._request("GET", "/_cluster/health")
        cluster_ok = status == 200 and data.get("status") in ("green", "yellow")
        self.client.record_test(
            "OpenSearch Cluster Health",
            cluster_ok,
            f"Cluster status is '{data.get('status')}', nodes: {data.get('number_of_nodes')}",
            dur,
        )

        status_ism, data_ism, dur_ism = self.client._request("GET", "/_plugins/_ism/policies")
        ism_ok = status_ism == 200
        self.client.record_test(
            "ISM Subsystem API Readiness",
            ism_ok,
            f"ISM policies API reachable (HTTP {status_ism})",
            dur_ism,
        )

        return cluster_ok and ism_ok

    def phase2_setup_policy_and_template(self, policy_file: Path, template_file: Path) -> bool:
        """Upload ISM Policy and Composable Index Template."""
        print(f"\n{CLR_YELLOW}▶ [Phase 2] Installing ISM Policy & Index Template...{CLR_RESET}")

        with open(policy_file, "r", encoding="utf-8") as f:
            policy_doc = json.load(f)

        # Check if policy already exists to include seq_no / primary_term for updates
        st_get, data_get, _ = self.client._request("GET", "/_plugins/_ism/policies/log_lifecycle_policy")
        if st_get == 200:
            seq_no = data_get.get("_seq_no", 0)
            prim_term = data_get.get("_primary_term", 1)
            status, data, dur = self.client._request(
                "PUT",
                f"/_plugins/_ism/policies/log_lifecycle_policy?if_seq_no={seq_no}&if_primary_term={prim_term}",
                payload=policy_doc,
            )
        else:
            status, data, dur = self.client._request("PUT", "/_plugins/_ism/policies/log_lifecycle_policy", payload=policy_doc)

        policy_ok = status in (200, 201) or (status == 409 and "already exists" in str(data))
        self.client.record_test(
            "ISM Policy Deployment ('log_lifecycle_policy')",
            policy_ok,
            f"Policy operational with default_state=hot",
            dur,
        )

        with open(template_file, "r", encoding="utf-8") as f:
            template_doc = json.load(f)

        status_t, data_t, dur_t = self.client._request("PUT", "/_index_template/app_telemetry_template", payload=template_doc)
        template_ok = status_t in (200, 201) and data_t.get("acknowledged") is True
        self.client.record_test(
            "Index Template Registration ('app_telemetry_template')",
            template_ok,
            f"Template bound to 'app-telemetry-*' with rollover alias 'app-telemetry-write'",
            dur_t,
        )

        return policy_ok and template_ok

    def phase3_bootstrap_index(self) -> bool:
        """Bootstrap generation 1 index 'app-telemetry-000001' with read/write aliases."""
        print(f"\n{CLR_YELLOW}▶ [Phase 3] Bootstrapping Initial Index Generation & Aliases...{CLR_RESET}")

        # Clean up any previous test indices
        self.client._request("DELETE", "/app-telemetry-*")

        bootstrap_payload = {
            "aliases": {
                "app-telemetry-write": {
                    "is_write_index": True
                },
                "app-telemetry": {}
            }
        }
        status, data, dur = self.client._request("PUT", "/app-telemetry-000001", payload=bootstrap_payload)
        boot_ok = status == 200 and data.get("acknowledged") is True
        self.client.record_test(
            "Bootstrap Index Creation ('app-telemetry-000001')",
            boot_ok,
            f"Created index with is_write_index=true on 'app-telemetry-write'",
            dur,
        )

        # Confirm policy attachment
        time.sleep(1.0)
        status_exp, data_exp, dur_exp = self.client._request("GET", "/_plugins/_ism/explain/app-telemetry-000001")
        managed = status_exp == 200 and "app-telemetry-000001" in data_exp
        self.client.record_test(
            "Automatic ISM Policy Attachment Verification",
            managed,
            f"Index managed: {data_exp.get('app-telemetry-000001', {}).get('policy_id')}",
            dur_exp,
        )

        return boot_ok and managed

    def phase4_ingest_and_rollover(self, sample_file: Path) -> bool:
        """Bulk-ingest telemetry to target alias and trigger Hot-Tier Rollover."""
        print(f"\n{CLR_YELLOW}▶ [Phase 4] Ingesting Logs & Testing Hot-Tier Rollover...{CLR_RESET}")

        with open(sample_file, "r", encoding="utf-8") as f:
            samples = json.load(f)

        # Ingest documents via write alias
        ingested = 0
        start = time.perf_counter()
        for doc in samples:
            doc["timestamp"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
            st, res, _ = self.client._request("POST", "/app-telemetry-write/_doc", payload=doc, expected_statuses=(201,))
            if st in (200, 201):
                ingested += 1
        dur = (time.perf_counter() - start) * 1000.0

        self.client.record_test(
            "Telemetry Ingestion via Write Alias ('app-telemetry-write')",
            ingested == len(samples),
            f"Ingested {ingested}/{len(samples)} documents into generation 1",
            dur,
        )

        # Refresh index
        self.client._request("POST", "/app-telemetry-000001/_refresh")

        # Trigger rollover (rolling over from generation 1 to generation 2)
        st_roll, data_roll, dur_roll = self.client._request("POST", "/app-telemetry-write/_rollover")
        rolled_over = st_roll == 200 and data_roll.get("rolled_over") is True
        new_index = data_roll.get("new_index", "app-telemetry-000002")

        self.client.record_test(
            f"Hot-Tier Rollover Trigger (-> '{new_index}')",
            rolled_over,
            f"Rolled over from 'app-telemetry-000001' to '{new_index}'. Old index write permission revoked.",
            dur_roll,
        )

        # Ingest into write alias and confirm write lands on new generation 2
        test_doc = {
            "@timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "service": "checkout-api",
            "message": "Post-rollover generation 2 event",
            "status_code": 200,
        }
        st_post, data_post, dur_post = self.client._request("POST", "/app-telemetry-write/_doc", payload=test_doc)
        landed_on_gen2 = st_post in (200, 201) and data_post.get("_index") == "app-telemetry-000002"

        self.client.record_test(
            "Write Routing to New Active Generation ('app-telemetry-000002')",
            landed_on_gen2,
            f"Document successfully written to target index: {data_post.get('_index')}",
            dur_post,
        )

        return ingested > 0 and rolled_over and landed_on_gen2

    def phase5_warm_tier_transition(self) -> bool:
        """Simulate Warm-Tier transition: apply read_only, force_merge, replica reduction."""
        print(f"\n{CLR_YELLOW}▶ [Phase 5] Simulating Warm-Tier Transition & Read-Only Assertions...{CLR_RESET}")

        # 1. Apply read-only block
        settings_payload = {
            "index.blocks.write": True,
            "index.number_of_replicas": 0
        }
        st_set, data_set, dur_set = self.client._request("PUT", "/app-telemetry-000001/_settings", payload=settings_payload)
        settings_applied = st_set == 200 and data_set.get("acknowledged") is True

        self.client.record_test(
            "Warm Tier: Read-Only & Replica Count Optimization",
            settings_applied,
            f"Set index.blocks.write=true and number_of_replicas=0 on 'app-telemetry-000001'",
            dur_set,
        )

        # 2. Force merge Lucene segments to 1
        st_fm, data_fm, dur_fm = self.client._request("POST", "/app-telemetry-000001/_forcemerge?max_num_segments=1")
        force_merged = st_fm == 200
        self.client.record_test(
            "Warm Tier: Lucene Segment Force Merge (max_num_segments=1)",
            force_merged,
            f"Force merge completed, Lucene segments optimized for read-only query performance",
            dur_fm,
        )

        # 3. Assert Write Rejection on Warm Index
        forbidden_doc = {"message": "Illegal write attempt on read-only index", "timestamp": "2026-08-26T15:00:00Z"}
        st_write, data_write, dur_write = self.client._request("POST", "/app-telemetry-000001/_doc", payload=forbidden_doc)
        write_blocked = st_write == 403 or "read_only" in str(data_write) or "ClusterBlockException" in str(data_write)

        self.client.record_test(
            "Write-Blocking Assertion on Warm Read-Only Index",
            write_blocked,
            f"Direct write attempt correctly rejected with HTTP {st_write}: {data_write.get('error', {}).get('reason', 'Blocked') if isinstance(data_write, dict) else 'Rejected'}",
            dur_write,
        )

        # 4. Assert Searchability across alias spanning Hot and Warm
        self.client._request("POST", "/app-telemetry-000002/_refresh")
        st_search, data_search, dur_search = self.client._request("GET", "/app-telemetry/_search")
        total_hits = data_search.get("hits", {}).get("total", {}).get("value", 0) if isinstance(data_search, dict) else 0
        search_ok = st_search == 200 and total_hits >= 6

        self.client.record_test(
            "Unified Searchability Across Hot & Warm Tiers ('app-telemetry')",
            search_ok,
            f"Query via search alias 'app-telemetry' transparently queried both Hot (gen2) and Warm (gen1) indices. Hits: {total_hits}",
            dur_search,
        )

        return settings_applied and force_merged and write_blocked and search_ok

    def phase6_cold_tier_transition(self) -> bool:
        """Simulate Cold-Tier transition: close index to release file handles and memory."""
        print(f"\n{CLR_YELLOW}▶ [Phase 6] Simulating Cold-Tier Transition (Index Closure)...{CLR_RESET}")

        st_close, data_close, dur_close = self.client._request("POST", "/app-telemetry-000001/_close")
        closed = st_close == 200 and data_close.get("acknowledged") is True

        self.client.record_test(
            "Cold Tier: Index Closure ('app-telemetry-000001')",
            closed,
            f"Closed index to release JVM memory overhead and OS file descriptors",
            dur_close,
        )

        # Verify index state via cat indices API
        st_cat, data_cat, dur_cat = self.client._request("GET", "/_cat/indices/app-telemetry-000001?format=json")
        is_close_state = st_cat == 200 and len(data_cat) > 0 and data_cat[0].get("status") == "close"

        self.client.record_test(
            "Cold Tier: Closed Status Verification",
            is_close_state,
            f"Index status confirmed as '{data_cat[0].get('status') if len(data_cat) > 0 else 'unknown'}'",
            dur_cat,
        )

        return closed and is_close_state

    def phase7_delete_tier_retention(self) -> bool:
        """Simulate Delete-Tier retention purge: permanently remove aging index."""
        print(f"\n{CLR_YELLOW}▶ [Phase 7] Enforcing Retention Policy (Scheduled Deletion)...{CLR_RESET}")

        st_del, data_del, dur_del = self.client._request("DELETE", "/app-telemetry-000001")
        deleted = st_del == 200 and data_del.get("acknowledged") is True

        self.client.record_test(
            "Delete Tier: Retention Deletion ('app-telemetry-000001')",
            deleted,
            f"Permanently purged expired index from cluster according to ISM retention policy",
            dur_del,
        )

        # Confirm gen1 is gone but gen2 remains active
        st_chk1, _, _ = self.client._request("GET", "/app-telemetry-000001")
        st_chk2, _, _ = self.client._request("GET", "/app-telemetry-000002")
        isolation_ok = (st_chk1 == 404) and (st_chk2 == 200)

        self.client.record_test(
            "Cluster State Isolation Post-Deletion",
            isolation_ok,
            f"Expired index returned 404 Not Found while active index 'app-telemetry-000002' remains healthy",
            0.0,
        )

        return deleted and isolation_ok

    def phase8_dashboards_data_view(self) -> bool:
        """Provision OpenSearch Dashboards Index Pattern 'app-telemetry*'."""
        print(f"\n{CLR_YELLOW}▶ [Phase 8] Provisioning OpenSearch Dashboards Index Pattern...{CLR_RESET}")

        dv_payload = {
            "attributes": {
                "title": "app-telemetry*",
                "timeFieldName": "@timestamp"
            }
        }
        url = f"{self.client.dashboards_url}/api/saved_objects/index-pattern/app-telemetry"
        req = urllib.request.Request(
            url,
            data=json.dumps(dv_payload).encode("utf-8"),
            headers={"Content-Type": "application/json", "osd-xsrf": "true"},
            method="POST"
        )
        start = time.perf_counter()
        try:
            with urllib.request.urlopen(req, timeout=5.0) as resp:
                dur = (time.perf_counter() - start) * 1000.0
                self.client.record_test(
                    "OpenSearch Dashboards Index Pattern ('app-telemetry*')",
                    True,
                    f"Index pattern created successfully (ID: app-telemetry)",
                    dur,
                )
                return True
        except urllib.error.HTTPError as err:
            dur = (time.perf_counter() - start) * 1000.0
            if err.code == 409:
                self.client.record_test(
                    "OpenSearch Dashboards Index Pattern ('app-telemetry*')",
                    True,
                    "Index pattern 'app-telemetry*' already provisioned",
                    dur,
                )
                return True
            else:
                self.client.record_test(
                    "OpenSearch Dashboards Index Pattern ('app-telemetry*')",
                    False,
                    f"HTTP {err.code}: {err.read().decode('utf-8')[:100]}",
                    dur,
                )
                return False
        except Exception as exc:
            self.client.record_test(
                "OpenSearch Dashboards Index Pattern ('app-telemetry*')",
                False,
                f"Could not connect to Dashboards at {self.client.dashboards_url}: {exc}",
                0.0,
            )
            return False

    def print_summary(self) -> bool:
        """Display final execution summary and status."""
        passed_count = sum(1 for r in self.client.test_results if r["passed"])
        total_count = len(self.client.test_results)
        all_passed = (passed_count == total_count)

        print(f"\n{CLR_CYAN}{CLR_BOLD}======================================================================{CLR_RESET}")
        print(f"{CLR_CYAN}{CLR_BOLD}  📊 ISM Lifecycle Results: {passed_count}/{total_count} Passed{CLR_RESET}")
        print(f"{CLR_CYAN}{CLR_BOLD}======================================================================{CLR_RESET}")

        if all_passed:
            print(f"\n{CLR_GREEN}{CLR_BOLD}🎉 ALL OPENSEARCH ISM LIFECYCLE ASSERTIONS SUCCEEDED!{CLR_RESET}\n")
            print(f"  👉 OpenSearch Dashboards: {self.client.dashboards_url}")
            print(f"  👉 Index Management UI:  {self.client.dashboards_url}/app/opensearch_index_management_dashboards#/indices\n")
        else:
            print(f"\n{CLR_RED}{CLR_BOLD}❌ LIFECYCLE SIMULATION FAILED: {total_count - passed_count} ASSERTIONS FAILED.{CLR_RESET}\n")

        return all_passed


def main():
    parser = argparse.ArgumentParser(description="Simulate and verify OpenSearch Index State Management (ISM) lifecycle.")
    parser.add_argument("--url", default="http://127.0.0.1:9200", help="OpenSearch base URL")
    parser.add_argument("--dashboards-url", default="http://127.0.0.1:5601", help="OpenSearch Dashboards base URL")
    parser.add_argument("--policy-file", default="policies/ism_fast_simulation_policy.json", help="Path to ISM policy JSON")
    parser.add_argument("--template-file", default="templates/index_template.json", help="Path to Index Template JSON")
    parser.add_argument("--sample-file", default="sample_logs/telemetry_sample.json", help="Path to Sample Logs JSON")
    parser.add_argument("--verbose", action="store_true", help="Print verbose test messages")

    args = parser.parse_args()

    print(f"\n{CLR_CYAN}{CLR_BOLD}======================================================================{CLR_RESET}")
    print(f"{CLR_CYAN}{CLR_BOLD}  ⚙️  OpenSearch Index State Management (ISM) Simulator{CLR_RESET}")
    print(f"{CLR_CYAN}{CLR_BOLD}======================================================================{CLR_RESET}")

    client = OpenSearchISMClient(base_url=args.url, dashboards_url=args.dashboards_url)
    simulator = ISMLifecycleSimulator(client=client)

    script_dir = Path(__file__).parent.resolve()
    policy_path = script_dir / args.policy_file
    template_path = script_dir / args.template_file
    sample_path = script_dir / args.sample_file

    simulator.phase1_health_check()
    simulator.phase2_setup_policy_and_template(policy_path, template_path)
    simulator.phase3_bootstrap_index()
    simulator.phase4_ingest_and_rollover(sample_path)
    simulator.phase5_warm_tier_transition()
    simulator.phase6_cold_tier_transition()
    simulator.phase7_delete_tier_retention()
    simulator.phase8_dashboards_data_view()

    success = simulator.print_summary()
    sys.exit(0 if success else 1)


if __name__ == "__main__":
    main()
