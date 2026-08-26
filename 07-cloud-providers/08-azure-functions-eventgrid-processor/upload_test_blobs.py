#!/usr/bin/env python3
"""
upload_test_blobs.py - Azure Event Grid Blob Test Ingestion & Verification
==========================================================================
Generates synthetic media blobs (JPEG, PNG, PDF), dispatches Event Grid
notifications to the Azure Function endpoint, and queries Cosmos DB records
to verify automated metadata extraction and persistence.
"""

import argparse
import hashlib
import json
import os
import sys
import time
import urllib.error
import urllib.request
import uuid
from datetime import datetime, timezone

# ANSI Colors
CLR_RESET = "\033[0m"
CLR_BOLD = "\033[1m"
CLR_GREEN = "\033[1;32m"
CLR_RED = "\033[1;31m"
CLR_YELLOW = "\033[1;33m"
CLR_CYAN = "\033[1;36m"
CLR_BLUE = "\033[1;34m"
CLR_GRAY = "\033[0;90m"

SAMPLE_FILES = [
    {
        "filename": "hero_landscape.jpg",
        "content_type": "image/jpeg",
        "content": b"\xFF\xD8\xFF\xE0\x00\x10JFIF" + b"\x00" * 4096,
    },
    {
        "filename": "brand_logo.png",
        "content_type": "image/png",
        "content": b"\x89PNG\r\n\x1a\n" + b"\x00" * 2048,
    },
    {
        "filename": "monthly_report.pdf",
        "content_type": "application/pdf",
        "content": b"%PDF-1.7\n" + b"Sample Document Content " * 50,
    },
    {
        "filename": "banner_wide.webp",
        "content_type": "image/webp",
        "content": b"RIFF\x00\x00\x00\x00WEBPVP8 " + b"\x00" * 1024,
    },
]


def send_http_json(url: str, payload: dict = None, method: str = "GET") -> tuple:
    """Helper to dispatch HTTP JSON requests."""
    data = json.dumps(payload).encode("utf-8") if payload else None
    req = urllib.request.Request(
        url,
        data=data,
        headers={"Content-Type": "application/json", "User-Agent": "AzureBlobTester/1.0"},
        method=method,
    )
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            body = resp.read().decode("utf-8")
            elapsed_ms = (time.time() - t0) * 1000.0
            return resp.getcode(), json.loads(body) if body else {}, elapsed_ms
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8")
        elapsed_ms = (time.time() - t0) * 1000.0
        try:
            parsed = json.loads(body)
        except Exception:
            parsed = {"error": body}
        return e.code, parsed, elapsed_ms
    except Exception as e:
        elapsed_ms = (time.time() - t0) * 1000.0
        return 500, {"error": str(e)}, elapsed_ms


def main():
    parser = argparse.ArgumentParser(description="Upload test blobs and verify Event Grid + Cosmos DB processing")
    parser.add_argument("--url", type=str, default="", help="Azure Function endpoint (e.g. http://localhost:8080)")
    parser.add_argument("--mock", action="store_true", help="Run against offline simulator engine")
    parser.add_argument("--count", type=int, default=4, help="Number of test blobs to upload (default: 4)")
    parser.add_argument("--container", type=str, default="images-upload", help="Target Blob container")
    parser.add_argument("--json-output", type=str, default="", help="Path to write JSON summary")
    parser.add_argument("--verbose", "-v", action="store_true", help="Verbose logging")

    args = parser.parse_args()

    # Route to offline simulator if --mock is specified or no URL is available
    target_url = args.url
    if not target_url and not args.mock:
        if os.path.exists("terraform.tfstate"):
            try:
                import subprocess
                tf_url = subprocess.check_output(["terraform", "output", "-raw", "function_default_hostname"]).decode().strip()
                if tf_url and tf_url != "null":
                    target_url = tf_url
            except Exception:
                pass

        if not target_url:
            # Check local docker container
            code, _, _ = send_http_json("http://localhost:8080/health")
            if code == 200:
                target_url = "http://localhost:8080"
            else:
                args.mock = True

    if args.mock:
        print(f"\n{CLR_BLUE}{CLR_BOLD}======================================================================{CLR_RESET}")
        print(f"{CLR_BLUE}{CLR_BOLD}  🧪 Running Test Ingestion via Offline Event Grid Simulator{CLR_RESET}")
        print(f"{CLR_BLUE}{CLR_BOLD}======================================================================{CLR_RESET}\n")
        from eventgrid_blob_simulator import AzureEventGridSimulator

        sim = AzureEventGridSimulator(verbose=args.verbose)
        success = sim.run_all_tests()
        if args.json_output:
            sim.export_json_report(args.json_output)
        sys.exit(0 if success else 1)

    print(f"\n{CLR_BLUE}{CLR_BOLD}======================================================================{CLR_RESET}")
    print(f"{CLR_BLUE}{CLR_BOLD}  ⚡ Azure Event Grid Blob Test Ingestion & Verification{CLR_RESET}")
    print(f"{CLR_BLUE}{CLR_BOLD}======================================================================{CLR_RESET}")
    print(f"  Target Endpoint  : {target_url}")
    print(f"  Blob Container   : {args.container}")
    print(f"  Test Blobs Count : {min(args.count, len(SAMPLE_FILES))}")
    print(f"{CLR_BLUE}======================================================================{CLR_RESET}\n")

    # Step 1: Health probe
    print(f"{CLR_YELLOW}▶ [1/3] Checking Azure Function Health...{CLR_RESET}")
    code, health, elapsed = send_http_json(f"{target_url}/health")
    if code != 200:
        print(f"  [{CLR_RED}FAIL{CLR_RESET}] Function endpoint unreachable (HTTP {code}): {health}")
        sys.exit(1)
    print(f"  [{CLR_GREEN}OK{CLR_RESET}] Azure Function is healthy! (Uptime: {health.get('uptime_seconds', 0)}s, Latency: {elapsed:.1f}ms)")

    # Step 2: Upload blobs & emit Event Grid notifications
    print(f"\n{CLR_YELLOW}▶ [2/3] Ingesting Blobs & Dispatched Event Grid Notifications...{CLR_RESET}")
    processed_records = []
    blobs_to_send = SAMPLE_FILES[: min(args.count, len(SAMPLE_FILES))]

    for i, item in enumerate(blobs_to_send, 1):
        filename = item["filename"]
        content_type = item["content_type"]
        data_bytes = item["content"]
        size_bytes = len(data_bytes)
        etag = f"0x{uuid.uuid4().hex[:16].upper()}"
        blob_url = f"https://stgmedia.blob.core.windows.net/{args.container}/{filename}"

        event_payload = {
            "topic": f"/subscriptions/0000-0000/resourceGroups/rg-demo/providers/Microsoft.Storage/storageAccounts/stgmedia",
            "subject": f"/blobServices/default/containers/{args.container}/blobs/{filename}",
            "eventType": "Microsoft.Storage.BlobCreated",
            "eventTime": datetime.now(timezone.utc).isoformat(),
            "id": str(uuid.uuid4()),
            "data": {
                "api": "PutBlob",
                "clientRequestId": str(uuid.uuid4()),
                "requestId": str(uuid.uuid4()),
                "eTag": etag,
                "contentType": content_type,
                "contentLength": size_bytes,
                "blobType": "BlockBlob",
                "url": blob_url,
                "sequencer": "00000000000004420000000000028d30",
            },
            "dataVersion": "",
            "metadataVersion": "1",
        }

        print(f"  • Uploading '{filename}' ({content_type}, {size_bytes} bytes)...")
        code, resp, duration = send_http_json(f"{target_url}/", payload=[event_payload], method="POST")

        if code == 200:
            docs = resp.get("documents", [])
            doc_id = docs[0].get("id", "N/A") if docs else "N/A"
            print(f"    [{CLR_GREEN}PROCESSED{CLR_RESET}] Event Grid -> Function -> Cosmos DB (Doc: {doc_id[:8]}..., Time: {duration:.1f}ms)")
            if docs:
                processed_records.extend(docs)
        else:
            print(f"    [{CLR_RED}FAIL{CLR_RESET}] Processing error (HTTP {code}): {resp}")

    # Step 3: Verify records in Cosmos DB
    print(f"\n{CLR_YELLOW}▶ [3/3] Querying Cosmos DB for Extracted Metadata...{CLR_RESET}")
    code, meta_resp, _ = send_http_json(f"{target_url}/api/metadata")

    if code == 200:
        docs = meta_resp.get("documents", [])
        print(f"  Found {len(docs)} total records in Cosmos DB [{meta_resp.get('database')}/{meta_resp.get('container')}]:")
        for doc in docs:
            print(f"    • Blob: {CLR_BOLD}{doc.get('blobName')}{CLR_RESET} | Type: {doc.get('contentType')} | Size: {doc.get('fileSizeReadable')} | SHA256: {doc.get('sha256', '')[:12]}...")

        print(f"\n{CLR_GREEN}{CLR_BOLD}🎉 Ingestion & Cosmos DB Metadata Verification Complete!{CLR_RESET}\n")

        if args.json_output:
            with open(args.json_output, "w") as f:
                json.dump(meta_resp, f, indent=2)
            print(f"  [OK] Exported summary to {args.json_output}")
    else:
        print(f"  [{CLR_RED}FAIL{CLR_RESET}] Failed to query Cosmos DB records: {meta_resp}")
        sys.exit(1)


if __name__ == "__main__":
    main()
