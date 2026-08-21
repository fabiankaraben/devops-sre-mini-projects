#!/usr/bin/env python3
"""
Multi-Service Docker Compose Stack - Web API Backend
====================================================
Demonstrates:
  1. PostgreSQL database integration (CRUD persistence).
  2. Redis Cache-Aside pattern (cache hits, misses, and auto-invalidation).
  3. Comprehensive dependency healthcheck probe (/api/health).
  4. Non-root unprivileged container execution.
"""

import json
import logging
import os
import signal
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse

import psycopg2
from psycopg2.extras import RealDictCursor
import redis

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger("web-api")

# Configuration via environment variables
PORT = int(os.getenv("PORT", "8000"))
DB_HOST = os.getenv("DB_HOST", "db")
DB_PORT = int(os.getenv("DB_PORT", "5432"))
DB_NAME = os.getenv("DB_NAME", "appdb")
DB_USER = os.getenv("DB_USER", "postgres")
DB_PASSWORD = os.getenv("DB_PASSWORD", "postgrespassword")

REDIS_HOST = os.getenv("REDIS_HOST", "cache")
REDIS_PORT = int(os.getenv("REDIS_PORT", "6379"))

START_TIME = time.time()
CACHE_KEY_ITEMS = "cache:items:all"
CACHE_TTL_SECONDS = 60


def get_db_connection():
    """Establish and return a PostgreSQL connection."""
    return psycopg2.connect(
        host=DB_HOST,
        port=DB_PORT,
        dbname=DB_NAME,
        user=DB_USER,
        password=DB_PASSWORD,
        connect_timeout=3,
    )


def get_redis_client():
    """Establish and return a Redis client."""
    return redis.Redis(
        host=REDIS_HOST,
        port=REDIS_PORT,
        decode_responses=True,
        socket_connect_timeout=3,
    )


def init_db():
    """Ensure database schema exists and seed initial records if empty."""
    for attempt in range(10):
        try:
            with get_db_connection() as conn:
                with conn.cursor() as cur:
                    cur.execute("""
                        CREATE TABLE IF NOT EXISTS items (
                            id SERIAL PRIMARY KEY,
                            title VARCHAR(120) NOT NULL,
                            description TEXT,
                            priority VARCHAR(20) DEFAULT 'MEDIUM',
                            created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
                            updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
                        );
                        INSERT INTO items (title, description, priority)
                        SELECT 'Setup Docker Compose Stack', 'Orchestrate multi-tier microservices with custom bridge networks and healthchecks.', 'HIGH'
                        WHERE NOT EXISTS (SELECT 1 FROM items WHERE title = 'Setup Docker Compose Stack');
                        INSERT INTO items (title, description, priority)
                        SELECT 'Implement Cache-Aside Pattern', 'Leverage Redis to accelerate repetitive read queries and invalidate on mutation.', 'HIGH'
                        WHERE NOT EXISTS (SELECT 1 FROM items WHERE title = 'Implement Cache-Aside Pattern');
                        INSERT INTO items (title, description, priority)
                        SELECT 'Verify Volume Persistence', 'Ensure PostgreSQL data survives container crashes and restarts via named volumes.', 'MEDIUM'
                        WHERE NOT EXISTS (SELECT 1 FROM items WHERE title = 'Verify Volume Persistence');
                    """)
                conn.commit()
            logger.info("Database schema initialized successfully.")
            return
        except Exception as e:
            logger.warning("Database init attempt %d failed: %s. Retrying in 2s...", attempt + 1, e)
            time.sleep(2)


class APIHandler(BaseHTTPRequestHandler):
    """HTTP Request Handler implementing REST endpoints and Cache-Aside logic."""

    def _set_headers(self, status_code=200, content_type="application/json", extra_headers=None):
        self.send_response(status_code)
        self.send_header("Content-Type", f"{content_type}; charset=utf-8")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, Authorization")
        self.send_header("X-Content-Type-Options", "nosniff")

        if extra_headers:
            for key, value in extra_headers.items():
                self.send_header(key, value)

        self.end_headers()

    def do_OPTIONS(self):
        """Handle CORS pre-flight requests."""
        self._set_headers(204)

    def _send_json(self, status_code, data, extra_headers=None):
        body = json.dumps(data, default=str).encode("utf-8")
        self._set_headers(status_code, extra_headers=extra_headers)
        self.wfile.write(body)

    def do_GET(self):
        """Handle GET requests."""
        parsed_url = urlparse(self.path)
        path = parsed_url.path.rstrip("/")

        # Healthcheck endpoint (probes both Postgres and Redis)
        if path == "/api/health" or path == "/health":
            self._handle_health()
        elif path == "/api/stats":
            self._handle_stats()
        elif path == "/api/items":
            self._handle_get_items()
        elif path.startswith("/api/items/"):
            item_id = path.split("/")[-1]
            self._handle_get_item_by_id(item_id)
        elif path == "" or path == "/api":
            self._send_json(200, {
                "service": "multi-service-compose-api",
                "version": "1.0.0",
                "endpoints": [
                    "GET /api/health",
                    "GET /api/stats",
                    "GET /api/items",
                    "POST /api/items",
                    "GET /api/items/<id>",
                    "DELETE /api/items/<id>",
                ],
            })
        else:
            self._send_json(404, {"error": "Route not found", "path": path})

    def do_POST(self):
        """Handle POST requests."""
        parsed_url = urlparse(self.path)
        path = parsed_url.path.rstrip("/")

        if path == "/api/items":
            self._handle_create_item()
        else:
            self._send_json(404, {"error": "Route not found", "path": path})

    def do_DELETE(self):
        """Handle DELETE requests."""
        parsed_url = urlparse(self.path)
        path = parsed_url.path.rstrip("/")

        if path.startswith("/api/items/"):
            item_id = path.split("/")[-1]
            self._handle_delete_item(item_id)
        else:
            self._send_json(404, {"error": "Route not found", "path": path})

    def _handle_health(self):
        """Perform active healthchecks against PostgreSQL and Redis."""
        pg_status = "unhealthy"
        redis_status = "unhealthy"
        pg_latency_ms = -1
        redis_latency_ms = -1

        # Check Postgres
        t0 = time.time()
        try:
            with get_db_connection() as conn:
                with conn.cursor() as cur:
                    cur.execute("SELECT 1;")
                    cur.fetchone()
            pg_latency_ms = round((time.time() - t0) * 1000, 2)
            pg_status = "connected"
        except Exception as e:
            logger.error("Postgres healthcheck failed: %s", e)
            pg_status = f"error: {str(e)}"

        # Check Redis
        t0 = time.time()
        try:
            r = get_redis_client()
            if r.ping():
                redis_latency_ms = round((time.time() - t0) * 1000, 2)
                redis_status = "connected"
        except Exception as e:
            logger.error("Redis healthcheck failed: %s", e)
            redis_status = f"error: {str(e)}"

        is_healthy = (pg_status == "connected" and redis_status == "connected")
        status_code = 200 if is_healthy else 503

        self._send_json(status_code, {
            "status": "healthy" if is_healthy else "degraded",
            "uptime_seconds": round(time.time() - START_TIME, 2),
            "dependencies": {
                "postgres": {
                    "status": pg_status,
                    "host": f"{DB_HOST}:{DB_PORT}",
                    "latency_ms": pg_latency_ms,
                },
                "redis": {
                    "status": redis_status,
                    "host": f"{REDIS_HOST}:{REDIS_PORT}",
                    "latency_ms": redis_latency_ms,
                },
            },
        })

    def _handle_stats(self):
        """Return system, database, and cache metrics."""
        db_items_count = 0
        redis_keys = []
        try:
            with get_db_connection() as conn:
                with conn.cursor() as cur:
                    cur.execute("SELECT COUNT(*) FROM items;")
                    db_items_count = cur.fetchone()[0]
        except Exception as e:
            logger.error("Failed to query DB stats: %s", e)

        try:
            r = get_redis_client()
            redis_keys = r.keys("*")
        except Exception as e:
            logger.error("Failed to query Redis stats: %s", e)

        self._send_json(200, {
            "database": {
                "total_items": db_items_count,
                "table": "items",
            },
            "cache": {
                "cached_keys_count": len(redis_keys),
                "cached_keys": redis_keys,
            },
            "server": {
                "uptime_seconds": round(time.time() - START_TIME, 2),
                "pid": os.getpid(),
                "uid": os.getuid(),
            },
        })

    def _handle_get_items(self):
        """Retrieve items applying the Cache-Aside pattern."""
        r = get_redis_client()
        cached_data = None

        # 1. Try reading from Redis Cache
        try:
            cached_data = r.get(CACHE_KEY_ITEMS)
        except Exception as e:
            logger.warning("Redis read exception: %s", e)

        if cached_data:
            items = json.loads(cached_data)
            self._send_json(
                200,
                {
                    "source": "cache",
                    "cache_status": "HIT",
                    "count": len(items),
                    "items": items,
                },
                extra_headers={"X-Cache": "HIT"},
            )
            return

        # 2. Cache MISS: Query PostgreSQL database
        items = []
        try:
            with get_db_connection() as conn:
                with conn.cursor(cursor_factory=RealDictCursor) as cur:
                    cur.execute("SELECT id, title, description, priority, created_at FROM items ORDER BY id ASC;")
                    items = cur.fetchall()
        except Exception as e:
            logger.error("Postgres query failed: %s", e)
            self._send_json(500, {"error": "Database query failed", "details": str(e)})
            return

        # 3. Populate Redis Cache
        try:
            r.setex(CACHE_KEY_ITEMS, CACHE_TTL_SECONDS, json.dumps(items, default=str))
        except Exception as e:
            logger.warning("Redis write exception: %s", e)

        self._send_json(
            200,
            {
                "source": "database",
                "cache_status": "MISS",
                "count": len(items),
                "items": items,
            },
            extra_headers={"X-Cache": "MISS"},
        )

    def _handle_get_item_by_id(self, item_id):
        """Retrieve a single item by ID."""
        try:
            item_id_int = int(item_id)
        except ValueError:
            self._send_json(400, {"error": "Invalid item ID format"})
            return

        try:
            with get_db_connection() as conn:
                with conn.cursor(cursor_factory=RealDictCursor) as cur:
                    cur.execute("SELECT id, title, description, priority, created_at FROM items WHERE id = %s;", (item_id_int,))
                    item = cur.fetchone()
                    if not item:
                        self._send_json(404, {"error": "Item not found", "id": item_id_int})
                        return
                    self._send_json(200, {"item": item})
        except Exception as e:
            logger.error("Database query error: %s", e)
            self._send_json(500, {"error": "Database query error", "details": str(e)})

    def _handle_create_item(self):
        """Create a new item in PostgreSQL and invalidate Redis cache."""
        try:
            content_length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(content_length).decode("utf-8")
            data = json.loads(body)
        except Exception as e:
            self._send_json(400, {"error": "Invalid JSON payload", "details": str(e)})
            return

        title = data.get("title", "").strip()
        description = data.get("description", "").strip()
        priority = data.get("priority", "MEDIUM").strip().upper()

        if not title:
            self._send_json(400, {"error": "Field 'title' is required"})
            return

        if priority not in ["LOW", "MEDIUM", "HIGH", "CRITICAL"]:
            priority = "MEDIUM"

        created_item = None
        try:
            with get_db_connection() as conn:
                with conn.cursor(cursor_factory=RealDictCursor) as cur:
                    cur.execute(
                        "INSERT INTO items (title, description, priority) VALUES (%s, %s, %s) RETURNING id, title, description, priority, created_at;",
                        (title, description, priority),
                    )
                    created_item = cur.fetchone()
                conn.commit()
        except Exception as e:
            logger.error("Database insert error: %s", e)
            self._send_json(500, {"error": "Database insert error", "details": str(e)})
            return

        # Invalidate Redis Cache upon mutation
        try:
            r = get_redis_client()
            r.delete(CACHE_KEY_ITEMS)
            logger.info("Invalidated cache key '%s'", CACHE_KEY_ITEMS)
        except Exception as e:
            logger.warning("Redis cache invalidation failed: %s", e)

        self._send_json(201, {
            "message": "Item created successfully",
            "item": created_item,
            "cache_invalidated": True,
        })

    def _handle_delete_item(self, item_id):
        """Delete an item from PostgreSQL and invalidate Redis cache."""
        try:
            item_id_int = int(item_id)
        except ValueError:
            self._send_json(400, {"error": "Invalid item ID format"})
            return

        deleted_rows = 0
        try:
            with get_db_connection() as conn:
                with conn.cursor() as cur:
                    cur.execute("DELETE FROM items WHERE id = %s;", (item_id_int,))
                    deleted_rows = cur.rowcount
                conn.commit()
        except Exception as e:
            logger.error("Database deletion error: %s", e)
            self._send_json(500, {"error": "Database deletion error", "details": str(e)})
            return

        if deleted_rows == 0:
            self._send_json(404, {"error": "Item not found for deletion", "id": item_id_int})
            return

        # Invalidate Redis Cache upon mutation
        try:
            r = get_redis_client()
            r.delete(CACHE_KEY_ITEMS)
            logger.info("Invalidated cache key '%s'", CACHE_KEY_ITEMS)
        except Exception as e:
            logger.warning("Redis cache invalidation failed: %s", e)

        self._send_json(200, {
            "message": "Item deleted successfully",
            "id": item_id_int,
            "cache_invalidated": True,
        })

    def log_message(self, format, *args):
        """Override to use standard logger."""
        logger.info("%s - - [%s] %s", self.address_string(), self.log_date_time_string(), format % args)


def run_server():
    """Start HTTP server with signal handling for graceful shutdown."""
    server_address = ("", PORT)
    httpd = HTTPServer(server_address, APIHandler)

    def signal_handler(signum, frame):
        logger.info("Received termination signal %s. Shutting down gracefully...", signum)
        httpd.server_close()
        sys.exit(0)

    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)

    logger.info("🚀 Web API Server running on port %d (UID: %d)", PORT, os.getuid() if hasattr(os, "getuid") else 0)
    init_db()
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()
        logger.info("Server terminated.")


if __name__ == "__main__":
    run_server()
