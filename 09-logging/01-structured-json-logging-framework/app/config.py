"""Application configuration management via environment variables."""

import os
from dataclasses import dataclass


@dataclass(frozen=True)
class Settings:
    """Immutable application runtime settings."""

    service_name: str = os.getenv("SERVICE_NAME", "order-processing-service")
    environment: str = os.getenv("ENVIRONMENT", "production")
    log_level: str = os.getenv("LOG_LEVEL", "INFO").upper()
    host: str = os.getenv("HOST", "0.0.0.0")
    port: int = int(os.getenv("PORT", "8000"))
    app_version: str = os.getenv("APP_VERSION", "1.0.0")


# Global singleton settings instance
settings = Settings()
