FROM python:3.12-alpine

# Install Go, Bash, curl, and nmap for network auditing & validation
RUN apk add --no-cache bash curl nmap go jq

WORKDIR /app

# Copy scanner scripts and target manifest
COPY net_troubleshoot.py net_troubleshoot.go net_troubleshoot.sh targets.txt ./
RUN chmod +x net_troubleshoot.py net_troubleshoot.sh

# Pre-compile Go scanner binary for high performance
RUN go build -o /usr/local/bin/net_troubleshoot_go net_troubleshoot.go

ENTRYPOINT ["python3", "net_troubleshoot.py"]
CMD ["--help"]
