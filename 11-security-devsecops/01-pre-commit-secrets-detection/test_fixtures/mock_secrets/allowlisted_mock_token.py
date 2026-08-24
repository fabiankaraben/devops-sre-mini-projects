"""Mock token test fixture explicitly registered in .gitleaks.toml and .secrets.baseline.

This file demonstrates allowlist / baseline exception handling for known safe test fixtures.
"""

# Explicitly allowlisted mock token in .gitleaks.toml & .secrets.baseline
TEST_API_KEY = "sk-mock-allowlisted-demo-key-1234567890abcdef"


def get_mock_token() -> str:
    """Returns the allowlisted mock token."""
    return TEST_API_KEY
