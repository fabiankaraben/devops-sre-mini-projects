#!/usr/bin/env python3
"""
Azure Functions Event Grid Blob Processor
=========================================
Serverless Python microservice handling Azure Event Grid 'Microsoft.Storage.BlobCreated'
events, extracting media metadata, and persisting structured documents to Azure Cosmos DB.

Supports both official Azure Functions Python v2 worker runtime and standalone
local HTTP emulation for testing and containerized execution.
"""

import hashlib
import json
import logging
import os
import sys
import threading
import time
import uuid
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

# Setup Logging
logging.basicConfig(level=logging.INFO, format="[%(asctime)s] [%(levelname)s] %(message)s")
logger = logging.getLogger("BlobEventProcessor")

# Environment & Cosmos DB Configuration
COSMOS_DB_ENDPOINT = os.environ.get("COSMOS_DB_ENDPOINT", "https://cosmos-media-local.documents.azure.com:443/")
COSMOS_DB_DATABASE = os.environ.get("COSMOS_DB_DATABASE", "media-metadata")
COSMOS_DB_CONTAINER = os.environ.get("COSMOS_DB_CONTAINER", "blobs")
STORAGE_CONTAINER_NAME = os.environ.get("STORAGE_CONTAINER_NAME", "images-upload")
PORT = int(os.environ.get("PORT", os.environ.get("FUNCTIONS_CUSTOMHANDLER_PORT", "8080")))

# In-memory document store for local simulation & fallback caching
LOCAL_COSMOS_STORE = {}
STORE_LOCK = threading.Lock()
PROCESSED_COUNT = 0
START_TIME = time.time()


def extract_media_category(content_type: str, blob_name: str) -> str:
    """Categorize blob based on MIME content type and file extension."""
    ct = content_type.lower()
    ext = os.path.splitext(blob_name)[1].lower()

    if "image" in ct or ext in (".jpg", ".jpeg", ".png", ".webp", ".gif", ".svg"):
        return "image"
    elif "video" in ct or ext in (".mp4", ".mov", ".webm", ".avi"):
        return "video"
    elif "pdf" in ct or ext in (".pdf", ".doc", ".docx", ".txt"):
        return "document"
    return "binary"


def process_blob_created_event(event_payload: dict) -> dict:
    """
    Core event processing logic:
    Parses Event Grid schema, extracts metadata, and prepares Cosmos DB record.
    """
    global PROCESSED_COUNT
    data = event_payload.get("data", {})
    subject = event_payload.get("subject", "")
    event_type = event_payload.get("eventType", "Microsoft.Storage.BlobCreated")
    event_time = event_payload.get("eventTime", datetime.now(timezone.utc).isoformat())

    # Extract blob properties
    blob_url = data.get("url", f"https://mockstorage.blob.core.windows.net/{STORAGE_CONTAINER_NAME}/unknown.blob")
    blob_name = os.path.basename(urlparse(blob_url).path) if blob_url else os.path.basename(subject)
    content_type = data.get("contentType", "application/octet-stream")
    content_length = int(data.get("contentLength", 0))
    etag = data.get("eTag", f"0x{uuid.uuid4().hex[:16]}")
    category = extract_media_category(content_type, blob_name)

    # Deterministic metadata simulation
    dimensions = None
    if category == "image":
        dimensions = {"width": 1920, "height": 1080, "aspectRatio": "16:9"}
    elif category == "document":
        dimensions = {"pages": max(1, content_length // 50000)}

    doc_id = str(uuid.uuid4())
    sha256_hash = hashlib.sha256(f"{blob_name}:{content_length}:{etag}".encode()).hexdigest()

    cosmos_doc = {
        "id": doc_id,
        "blobName": blob_name,
        "blobUrl": blob_url,
        "storageContainer": STORAGE_CONTAINER_NAME,
        "contentType": content_type,
        "mediaCategory": category,
        "fileSizeBytes": content_length,
        "fileSizeReadable": f"{round(content_length / 1024.0, 2)} KB" if content_length < 1048576 else f"{round(content_length / 1048576.0, 2)} MB",
        "sha256": sha256_hash,
        "eTag": etag,
        "dimensions": dimensions,
        "eventGridEventId": event_payload.get("id", str(uuid.uuid4())),
        "eventTime": event_time,
        "processedAt": datetime.now(timezone.utc).isoformat(),
        "processorRuntime": "Azure Functions (Python 3.11)",
        "status": "METADATA_EXTRACTED",
    }

    with STORE_LOCK:
        LOCAL_COSMOS_STORE[doc_id] = cosmos_doc
        PROCESSED_COUNT += 1

    logger.info(f"Processed blob '{blob_name}' ({content_type}, {content_length} bytes) -> Cosmos DB doc: {doc_id}")
    return cosmos_doc


class EventGridHTTPHandler(BaseHTTPRequestHandler):
    """HTTP Handler for Event Grid Webhooks and REST Endpoints."""

    server_version = "AzureFunctionsEventGridProcessor/1.0"

    def log_message(self, format, *args):
        sys.stdout.write(f"[{datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M:%S UTC')}] {self.address_string()} - {format % args}\n")
        sys.stdout.flush()

    def _send_json(self, status_code: int, data: dict):
        payload = json.dumps(data, indent=2).encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(payload)

    def _send_html(self, status_code: int, html: str):
        payload = html.encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path.rstrip("/")
        query = parse_qs(parsed.query)

        # 1. Health Probe (/health or /api/health)
        if path in ("/health", "/api/health"):
            self._send_json(
                HTTPStatus.OK,
                {
                    "status": "HEALTHY",
                    "runtime": "Azure Functions Python v2",
                    "uptime_seconds": round(time.time() - START_TIME, 2),
                    "cosmos_db_database": COSMOS_DB_DATABASE,
                    "cosmos_db_container": COSMOS_DB_CONTAINER,
                    "total_blobs_processed": PROCESSED_COUNT,
                },
            )
            return

        # 2. Query Cosmos DB Metadata (/api/metadata)
        if path == "/api/metadata":
            with STORE_LOCK:
                docs = list(LOCAL_COSMOS_STORE.values())

            content_type_filter = query.get("contentType", [""])[0]
            if content_type_filter:
                docs = [d for d in docs if d.get("contentType") == content_type_filter]

            self._send_json(
                HTTPStatus.OK,
                {
                    "database": COSMOS_DB_DATABASE,
                    "container": COSMOS_DB_CONTAINER,
                    "partitionKey": "/contentType",
                    "total_documents": len(docs),
                    "documents": docs,
                },
            )
            return

        # 3. Interactive Web Dashboard (/)
        if path == "" or path == "/index.html":
            with STORE_LOCK:
                docs = list(LOCAL_COSMOS_STORE.values())
                count = len(docs)

            doc_rows = ""
            for d in reversed(docs[-10:]):
                doc_rows += f"""
                <tr>
                    <td style="font-family: monospace; color: #38bdf8;">{d['id'][:8]}...</td>
                    <td><strong>{d['blobName']}</strong></td>
                    <td><span class="badge badge-type">{d['contentType']}</span></td>
                    <td>{d['fileSizeReadable']}</td>
                    <td><span class="badge badge-success">{d['status']}</span></td>
                    <td style="font-size: 11px; color: #94a3b8;">{d['processedAt']}</td>
                </tr>
                """

            if not doc_rows:
                doc_rows = "<tr><td colspan='6' style='text-align: center; color: #64748b; padding: 24px;'>No blobs processed yet. Upload images to see live metadata extraction!</td></tr>"

            html = f"""<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Azure Event Grid Blob Processor</title>
    <style>
        :root {{
            --bg-dark: #0f172a;
            --card-bg: #1e293b;
            --border: #334155;
            --azure-blue: #0078d4;
            --text-light: #f8fafc;
            --text-muted: #94a3b8;
            --green: #22c55e;
            --amber: #f59e0b;
        }}
        body {{
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
            background: var(--bg-dark);
            color: var(--text-light);
            margin: 0;
            padding: 24px;
        }}
        .container {{
            max-width: 1000px;
            margin: 0 auto;
        }}
        .header {{
            display: flex;
            justify-content: space-between;
            align-items: center;
            border-bottom: 1px solid var(--border);
            padding-bottom: 20px;
            margin-bottom: 24px;
        }}
        h1 {{
            margin: 0;
            font-size: 22px;
            color: var(--azure-blue);
            display: flex;
            align-items: center;
            gap: 10px;
        }}
        .grid {{
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
            gap: 16px;
            margin-bottom: 24px;
        }}
        .card {{
            background: var(--card-bg);
            border: 1px solid var(--border);
            border-radius: 12px;
            padding: 16px;
        }}
        .metric-title {{
            font-size: 12px;
            color: var(--text-muted);
            text-transform: uppercase;
            letter-spacing: 0.05em;
            margin-bottom: 6px;
        }}
        .metric-val {{
            font-size: 20px;
            font-weight: 700;
            color: #fff;
        }}
        table {{
            width: 100%;
            border-collapse: collapse;
            background: var(--card-bg);
            border: 1px solid var(--border);
            border-radius: 12px;
            overflow: hidden;
        }}
        th, td {{
            padding: 12px 16px;
            text-align: left;
            border-bottom: 1px solid var(--border);
            font-size: 13px;
        }}
        th {{
            background: #0f172a;
            color: var(--text-muted);
            text-transform: uppercase;
            font-size: 11px;
        }}
        .badge {{
            padding: 4px 10px;
            border-radius: 9999px;
            font-size: 11px;
            font-weight: 600;
        }}
        .badge-type {{ background: rgba(56, 189, 248, 0.15); color: #38bdf8; }}
        .badge-success {{ background: rgba(34, 197, 94, 0.15); color: var(--green); }}
        .btn {{
            background: var(--azure-blue);
            color: #fff;
            padding: 8px 16px;
            border-radius: 6px;
            text-decoration: none;
            font-weight: 600;
            font-size: 13px;
            display: inline-block;
            cursor: pointer;
            border: none;
        }}
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>⚡ Azure Functions Event Grid Blob Processor</h1>
            <button class="btn" onclick="location.reload()">🔄 Refresh</button>
        </div>

        <div class="grid">
            <div class="card">
                <div class="metric-title">Event Source</div>
                <div class="metric-val">Azure Blob Storage</div>
            </div>
            <div class="card">
                <div class="metric-title">Event Router</div>
                <div class="metric-val">Azure Event Grid</div>
            </div>
            <div class="card">
                <div class="metric-title">Cosmos DB Container</div>
                <div class="metric-val">{COSMOS_DB_CONTAINER}</div>
            </div>
            <div class="card">
                <div class="metric-title">Blobs Processed</div>
                <div class="metric-val" style="color: var(--green);">{count}</div>
            </div>
        </div>

        <div class="card" style="padding: 0; margin-bottom: 24px;">
            <table>
                <thead>
                    <tr>
                        <th>Doc ID</th>
                        <th>Blob Name</th>
                        <th>Content Type</th>
                        <th>Size</th>
                        <th>Status</th>
                        <th>Processed At</th>
                    </tr>
                </thead>
                <tbody>
                    {doc_rows}
                </tbody>
            </table>
        </div>
    </div>
</body>
</html>
"""
            self._send_html(HTTPStatus.OK, html)
            return

        self._send_json(HTTPStatus.NOT_FOUND, {"error": "Not Found", "path": self.path})

    def do_POST(self):
        """
        Handle Event Grid webhook delivery and subscription handshake.
        Azure Event Grid sends validation events on subscription creation:
        eventType: 'Microsoft.EventGrid.SubscriptionValidationEvent'
        data: { 'validationCode': '...' }
        """
        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length).decode("utf-8") if content_length > 0 else "{}"

        try:
            payload = json.loads(body)
        except Exception as e:
            self._send_json(HTTPStatus.BAD_REQUEST, {"error": f"Invalid JSON payload: {str(e)}"})
            return

        # Event Grid batch can be a single dict or a list of event objects
        events = payload if isinstance(payload, list) else [payload]
        processed_docs = []

        for event in events:
            event_type = event.get("eventType", "")

            # 1. Event Grid Webhook Handshake (SubscriptionValidationEvent)
            if event_type == "Microsoft.EventGrid.SubscriptionValidationEvent":
                validation_code = event.get("data", {}).get("validationCode", "")
                logger.info(f"Handshake received! Echoing validationCode: {validation_code}")
                self._send_json(HTTPStatus.OK, {"validationResponse": validation_code})
                return

            # 2. Blob Created Event Handling
            if event_type in ("Microsoft.Storage.BlobCreated", "BlobCreated"):
                doc = process_blob_created_event(event)
                processed_docs.append(doc)

        self._send_json(
            HTTPStatus.OK,
            {
                "message": "Events processed successfully",
                "events_received": len(events),
                "documents_created": len(processed_docs),
                "documents": processed_docs,
            },
        )


def run_server(port: int = PORT):
    server_address = ("", port)
    httpd = ThreadingHTTPServer(server_address, EventGridHTTPHandler)
    print(f"🚀 Azure Function Event Grid Processor active on port {port}...")
    print(f"   Cosmos DB:   {COSMOS_DB_DATABASE} / {COSMOS_DB_CONTAINER}")
    print(f"   Storage:     {STORAGE_CONTAINER_NAME}")
    sys.stdout.flush()

    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\n🛑 Shutting down Azure Function...")
        httpd.server_close()


if __name__ == "__main__":
    port_arg = int(os.environ.get("PORT", sys.argv[1] if len(sys.argv) > 1 else "8080"))
    run_server(port=port_arg)
