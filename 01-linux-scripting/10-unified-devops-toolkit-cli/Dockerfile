FROM python:3.12-alpine

# Install Go, Bash, OpenSSH client, curl, and jq
RUN apk add --no-cache bash openssh-client curl jq go

WORKDIR /app

# Copy Go code and Python toolkit
COPY go.mod main.go devops_cli.py ./
COPY fixtures/ ./fixtures/

RUN chmod +x devops_cli.py

# Compile Go devops-cli binary
RUN go build -o /usr/local/bin/devops-cli main.go

ENTRYPOINT ["/usr/local/bin/devops-cli"]
CMD ["--help"]
