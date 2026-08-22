# Vulnerable Dockerfile for Security Scanning Demonstration
# 1. Uses an outdated base image with known OS vulnerabilities
FROM python:3.9-slim-buster

# 2. Runs as root without non-root USER instruction
WORKDIR /app

# 3. Copies all files including secrets if unignored
COPY . /app

# 4. Installs unpinned/outdated dependencies without security checks
RUN pip install --no-cache-dir -r requirements.txt

# 5. Exposes default Flask port
EXPOSE 5000

# 6. Runs Flask with debug mode in container
CMD ["python", "app.py"]
