"""Clean application module utilizing secure environment variables for authentication."""

import os
import sys
import logging

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger("secure_app")


class ApiClient:
    """Safe API Client retrieving secrets exclusively from environment variables."""

    def __init__(self) -> None:
        self.api_key = os.getenv("APP_API_KEY")
        self.base_url = os.getenv("API_BASE_URL", "https://api.example.com/v1")

        if not self.api_key:
            logger.warning("APP_API_KEY environment variable is not configured.")

    def fetch_data(self, endpoint: str) -> dict:
        """Simulates fetching secure data from an external endpoint."""
        logger.info("Querying endpoint: %s/%s", self.base_url, endpoint.lstrip("/"))
        return {"status": "success", "endpoint": endpoint, "authenticated": bool(self.api_key)}


def main() -> int:
    client = ApiClient()
    response = client.fetch_data("health")
    print(f"Health check response: {response}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
