# ==============================================================================
# Makefile for Site-to-Site WireGuard VPN Mesh Mini-Project
# ==============================================================================
.PHONY: help up down restart logs status test test-verbose test-encryption clean

help:
	@echo "Available commands:"
	@echo "  make up              - Build and start all Gateways and App containers across 4 networks"
	@echo "  make down            - Stop all running containers"
	@echo "  make restart         - Restart containers"
	@echo "  make logs            - Stream real-time container logs"
	@echo "  make status          - Inspect active WireGuard interface & peer status on all gateways"
	@echo "  make test            - Execute automated end-to-end VPN connectivity test suite"
	@echo "  make test-verbose    - Execute test suite with verbose diagnostics and outputs"
	@echo "  make test-encryption - Inspect transit WAN traffic via tcpdump for UDP 51820 encryption"
	@echo "  make clean           - Tear down containers, networks, volumes, and Docker images"

up:
	docker compose up -d --build

down:
	docker compose down

restart:
	docker compose restart

logs:
	docker compose logs -f

status:
	@echo "=== Gateway A (Site A) WireGuard Status ==="
	@docker exec wg-gateway-a wg show || true
	@echo "\n=== Gateway B (Site B) WireGuard Status ==="
	@docker exec wg-gateway-b wg show || true
	@echo "\n=== Gateway C (Site C) WireGuard Status ==="
	@docker exec wg-gateway-c wg show || true

test:
	chmod +x vpn_connectivity_test.sh
	./vpn_connectivity_test.sh

test-verbose:
	chmod +x vpn_connectivity_test.sh
	./vpn_connectivity_test.sh -v

test-encryption:
	@echo "Capturing encrypted packets on Gateway A WAN interface while sending cross-site traffic..."
	@WAN_IF=$$(docker exec wg-gateway-a sh -c "ip -o -4 addr list | grep '192.168.100.' | awk '{print \$$2}'"); \
	docker exec wg-gateway-a tcpdump -n -i $$WAN_IF -c 10 -v "udp port 51820" & \
	sleep 1; \
	docker exec wg-app-a curl -s http://10.20.0.10:8080/api/info > /dev/null; \
	wait

clean:
	docker compose down --rmi all --volumes --remove-orphans
