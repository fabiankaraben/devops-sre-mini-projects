"""
Hardcoded configuration secrets for secret scanner testing.
"""

# Dummy JWT Private Signing Secret
JWT_SECRET_SIGNING_KEY = "super_secret_production_key_dont_commit_me_12345"

# Dummy RSA Private Key Block (Synthetic)
DUMMY_RSA_PRIVATE_KEY = """-----BEGIN RSA PRIVATE KEY-----
MIIEowIBAAKCAQEA0Y1oexamplekeyfakeprivatekeycontentfake1234567890
ABCDEFabcdef1234567890ABCDEFabcdef1234567890ABCDEFabcdef12345678
90ABCDEFabcdef1234567890ABCDEFabcdef1234567890ABCDEFabcdef123456
-----END RSA PRIVATE KEY-----"""
