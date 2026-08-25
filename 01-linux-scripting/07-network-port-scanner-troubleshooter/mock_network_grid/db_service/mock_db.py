#!/usr/bin/env python3
"""
Mock Database Multi-Port Listener
Simulates PostgreSQL (5432) and Redis (6379) protocol banners for network scanner testing.
"""

import asyncio
import signal
import sys


async def handle_postgres(reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
    """Responds to PostgreSQL connection probes with simulated version banner."""
    try:
        data = await asyncio.wait_for(reader.read(1024), timeout=2.0)
    except asyncio.TimeoutError:
        data = b""

    # Send mock PostgreSQL response banner
    response = b"PostgreSQL 16.3 (Ubuntu 16.3-1.pgdg22.04+1) on x86_64-pc-linux-gnu\n"
    try:
        writer.write(response)
        await writer.drain()
    except Exception:
        pass
    finally:
        try:
            writer.close()
            await writer.wait_closed()
        except Exception:
            pass


async def handle_redis(reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
    """Responds to Redis PING and INFO commands."""
    try:
        while True:
            data = await asyncio.wait_for(reader.read(1024), timeout=3.0)
            if not data:
                break
            cmd = data.decode("utf-8", errors="ignore").strip().upper()
            if "PING" in cmd:
                writer.write(b"+PONG\r\n")
            elif "INFO" in cmd:
                writer.write(b"$34\r\n# Server\r\nredis_version:7.2.4\r\n\r\n")
            else:
                writer.write(b"+PONG\r\n")
            await writer.drain()
    except Exception:
        pass
    finally:
        try:
            writer.close()
            await writer.wait_closed()
        except Exception:
            pass


async def main():
    print("[MOCK-DB] Starting PostgreSQL listener on 0.0.0.0:5432...")
    server_pg = await asyncio.start_server(handle_postgres, "0.0.0.0", 5432)

    print("[MOCK-DB] Starting Redis listener on 0.0.0.0:6379...")
    server_redis = await asyncio.start_server(handle_redis, "0.0.0.0", 6379)

    loop = asyncio.get_running_loop()
    stop_event = asyncio.Event()

    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, stop_event.set)

    async with server_pg, server_redis:
        print("[MOCK-DB] Database services active. Press Ctrl+C or send SIGTERM to stop.")
        await stop_event.wait()

    print("[MOCK-DB] Shutting down database servers.")


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        sys.exit(0)
