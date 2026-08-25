#!/usr/bin/env python3
"""
Secure Microservice Application.
Demonstrates a production-ready containerized service whose supply chain,
dependencies, and build integrity are verified using Cosign and Syft.
"""

import os
import sys
import platform
from flask import Flask, jsonify

app = Flask(__name__)

APP_VERSION = os.getenv("APP_VERSION", "1.0.0")
APP_ENVIRONMENT = os.getenv("APP_ENVIRONMENT", "production")
APP_BUILD_COMMIT = os.getenv("APP_BUILD_COMMIT", "a1b2c3d4e5f6")


@app.route("/", methods=["GET"])
def root():
    """Root endpoint returning basic service metadata."""
    return jsonify({
        "service": "secure-payment-gateway",
        "status": "online",
        "version": APP_VERSION,
        "environment": APP_ENVIRONMENT,
        "signed_by": "Cosign Sigstore Infrastructure",
        "sbom_attached": True
    })


@app.route("/health", methods=["GET"])
def health():
    """Healthcheck endpoint for orchestrators (Kubernetes/Docker)."""
    return jsonify({
        "status": "healthy",
        "python_version": platform.python_version(),
        "platform": platform.platform()
    }), 200


@app.route("/api/v1/info", methods=["GET"])
def info():
    """Detailed runtime configuration and security posture."""
    return jsonify({
        "app_name": "secure-payment-gateway",
        "version": APP_VERSION,
        "build_commit": APP_BUILD_COMMIT,
        "python_runtime": {
            "version": sys.version.split()[0],
            "implementation": platform.python_implementation()
        },
        "security_policy": {
            "enforce_signed_images": True,
            "sbom_standard": "SPDX-2.3 & CycloneDX-1.5",
            "crypto_signature_algorithm": "ECDSA-P256-SHA256"
        }
    }), 200


if __name__ == "__main__":
    port = int(os.getenv("PORT", 8080))
    app.run(host="0.0.0.0", port=port)
