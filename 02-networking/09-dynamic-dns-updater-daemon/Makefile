# ==============================================================================
# Makefile for Dynamic DNS (DDNS) Updater Daemon Mini-Project
# ==============================================================================
.PHONY: help up down restart logs status trigger-ip-change test test-verbose clean

help:
	@echo "Available commands:"
	@echo "  make up                - Build and start Mock DNS API and DDNS Daemon"
	@echo "  make down              - Stop running containers"
	@echo "  make restart           - Restart containers"
	@echo "  make logs              - Stream real-time container logs"
	@echo "  make status            - View live WAN IP, DNS records, and daemon cache status"
	@echo "  make trigger-ip-change - Simulate an ISP dynamic WAN IP transition"
	@echo "  make test              - Execute automated test suite (7 verification phases)"
	@echo "  make test-verbose      - Execute automated test suite with verbose output"
	@echo "  make clean             - Tear down containers, networks, volumes, and Docker images"

up:
	docker compose up -d --build

down:
	docker compose down

restart:
	docker compose restart

logs:
	docker compose logs -f

status:
	@echo "=== Mock Cloudflare DNS Status ==="
	@curl -s http://localhost:8080/api/dns/status | grep -E '"(current_wan_ip|name|content)"' || echo "Mock API offline"
	@echo "\n=== DDNS Daemon Observability Metrics ==="
	@curl -s http://localhost:8000/status | grep -E '"(status|last_discovered_ip|last_synced_ip|redundant_calls_avoided|total_checks)"' || echo "Daemon offline"
	@echo ""

trigger-ip-change:
	@curl -s -X POST http://localhost:8080/api/wan/simulate-ip-change -H "Content-Type: application/json" -d '{}'

test:
	chmod +x test_ddns_daemon.sh
	./test_ddns_daemon.sh

test-verbose:
	chmod +x test_ddns_daemon.sh
	./test_ddns_daemon.sh -v

clean:
	docker compose down --rmi all --volumes --remove-orphans
