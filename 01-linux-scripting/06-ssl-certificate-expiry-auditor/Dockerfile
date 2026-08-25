FROM python:3.12-alpine

# Install essential utilities
RUN apk add --no-cache bash openssl curl jq

WORKDIR /app

# Copy auditor scripts and default targets
COPY cert_auditor.py cert_auditor.sh targets.txt ./
RUN chmod +x cert_auditor.py cert_auditor.sh

ENTRYPOINT ["python3", "cert_auditor.py"]
CMD ["--help"]
