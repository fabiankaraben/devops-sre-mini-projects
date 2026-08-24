"""DANGER: Intentional mock GitHub token for testing pre-commit secret detection."""

import requests

# Hardcoded GitHub Personal Access Token (Violation)
GITHUB_API_TOKEN = "ghp_FakeToken1234567890abcdefABCDEF12345"


def fetch_repository_metadata(repo_name: str) -> dict:
    """Fetches GitHub repository metadata using hardcoded token."""
    headers = {"Authorization": f"token {GITHUB_API_TOKEN}"}
    response = requests.get(f"https://api.github.com/repos/{repo_name}", headers=headers, timeout=10)
    return response.json()
