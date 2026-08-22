"""
app.py - Mock Target Endpoints & TCP Socket Service

Provides diverse synthetic probe targets for Blackbox Exporter testing:
  1. /api/healthy         -> 200 OK with {"status": "UP"}
  2. /api/slow            -> 200 OK after simulated 400ms latency
  3. /api/failing-500     -> 500 Internal Server Error
  4. /api/not-found-404   -> 404 Not Found
  5. /api/unhealthy-body  -> 200 OK with {"status": "DEGRADED"} (Fails regex check)
  6. /api/post-endpoint   -> 200 OK for HTTP POST probing
  7. TCP Port 9000        -> Raw TCP socket listener
"""

import asyncio
import time
from fastapi import FastAPI, HTTPException, Request, status
from fastapi.responses import JSONResponse

app = FastAPI(title="Mock Target Endpoints for Blackbox Probing", version="1.0.0")


@app.get("/healthz")
def healthz():
    return {"status": "ok", "service": "mock-targets"}


@app.get("/api/healthy")
def get_healthy():
    return {"status": "UP", "service": "inventory-api", "timestamp": time.time()}


@app.get("/api/slow")
async def get_slow(delay: float = 0.40):
    await asyncio.sleep(delay)
    return {"status": "UP", "service": "slow-billing-api", "latency_injected": delay}


@app.get("/api/failing-500")
def get_failing_500():
    raise HTTPException(
        status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
        detail="Simulated critical backend database connection timeout",
    )


@app.get("/api/not-found-404")
def get_not_found():
    raise HTTPException(
        status_code=status.HTTP_404_NOT_FOUND,
        detail="Target endpoint deprecated or route missing",
    )


@app.get("/api/unhealthy-body")
def get_unhealthy_body():
    # Returns HTTP 200 OK but payload body status is DEGRADED, triggering regex content failure
    return {"status": "DEGRADED", "error": "Redis cache pool exhausted", "code": 50301}


@app.post("/api/post-endpoint")
async def post_endpoint(request: Request):
    try:
        data = await request.json()
    except Exception:
        data = {}
    return {
        "status": "UP",
        "method": "POST",
        "received_payload": data,
        "probe_validated": True,
    }


# ------------------------------------------------------------------------------
# Raw TCP Socket Echo Server on Port 9000
# ------------------------------------------------------------------------------
async def handle_tcp_client(reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
    try:
        writer.write(b"220 Mock-TCP-Service-Ready\r\n")
        await writer.drain()
        data = await asyncio.wait_for(reader.read(1024), timeout=2.0)
        if data:
            writer.write(b"OK " + data)
            await writer.drain()
    except Exception:
        pass
    finally:
        writer.close()
        await writer.wait_closed()


@app.on_event("startup")
async def start_tcp_socket_listener():
    server = await asyncio.start_server(handle_tcp_client, "0.0.0.0", 9000)
    asyncio.create_task(server.serve_forever())
