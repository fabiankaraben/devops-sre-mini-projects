# ==============================================================================
# Makefile for SSL/TLS Termination Reverse Proxy Mini-Project
# ==============================================================================
.PHONY: help certs up down restart logs test curl-http curl-https tls-handshake clean

help:
	@echo "Available commands:"
	@echo "  make certs         - Generate local Root CA, server certs, and DH parameters"
	@echo "  make up            - Build and start Nginx proxy and backend containers"
	@echo "  make down          - Stop all containers"
	@echo "  make restart       - Restart containers"
	@echo "  make logs          - View real-time container logs"
	@echo "  make test          - Run automated 14+ point test suite"
	@echo "  make curl-http     - Test HTTP port 80 redirect to HTTPS"
	@echo "  make curl-https    - Test HTTPS port 443 with HSTS headers"
	@echo "  make tls-handshake - Inspect TLS 1.3 handshake and cipher suite"
	@echo "  make clean         - Tear down containers, networks, volumes, and images"

certs:
	chmod +x generate_certs.sh
	./generate_certs.sh

up: certs
	docker compose up -d --build

down:
	docker compose down

restart:
	docker compose restart

logs:
	docker compose logs -f

test:
	chmod +x test_ssl_termination.sh
	./test_ssl_termination.sh

curl-http:
	curl -I http://localhost:80/

curl-https:
	curl -I -k https://localhost:443/

tls-handshake:
	openssl s_client -connect localhost:443 -servername localhost -tls1_3 </dev/null

clean:
	docker compose down --rmi all --volumes --remove-orphans
	./generate_certs.sh --clean
