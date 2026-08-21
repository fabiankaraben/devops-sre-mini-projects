#!/usr/bin/env python3
"""
Secure Microservice Demo
========================
Demonstrates runtime execution of application built with BuildKit caching
and secure secret mounting.
"""

import os
import sys
import time
from fastapi import FastAPI
import uvicorn

app = FastAPI(
    title="BuildKit Caching & Secrets Demo API",
    version="1.0.0",
    description="Container built with BuildKit layer caching and zero secret leaks.",
)

START_TIME = time.time()


@app.get("/")
def read_root():
    return {
        "service": "buildkit-caching-secrets-demo",
        "status": "operational",
        "uptime_seconds": round(time.time() - START_TIME, 2),
        "uid": os.getuid() if hasattr(os, "getuid") else 0,
        "security": {
            "secret_in_layer_metadata": False,
            "user": "non-root (appuser:10001)",
        },
    }


@app.get("/health")
def read_health():
    return {
        "status": "healthy",
        "uptime_seconds": round(time.time() - START_TIME, 2),
    }


if __name__ == "__main__":
    port = int(os.getenv("PORT", "8080"))
    uvicorn.run(app, host="0.0.0.0", port=port)
