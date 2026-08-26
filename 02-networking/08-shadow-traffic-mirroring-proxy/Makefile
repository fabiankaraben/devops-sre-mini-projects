# ==============================================================================
# Makefile for Shadow Traffic Mirroring Proxy Mini-Project
# ==============================================================================
.PHONY: help up down restart logs status inject test test-verbose clean

help:
	@echo "Available commands:"
	@echo "  make up           - Build and start Nginx proxy, Primary API, and Shadow API"
	@echo "  make down         - Stop running containers"
	@echo "  make restart      - Restart containers"
	@echo "  make logs         - Stream real-time container logs"
	@echo "  make status       - Check health and live request statistics across all services"
	@echo "  make inject       - Inject 50 simulated live requests with payload verification"
	@echo "  make test         - Execute automated test suite (7 verification phases)"
	@echo "  make test-verbose - Execute automated test suite with verbose diagnostics"
	@echo "  make clean        - Tear down containers, networks, volumes, and Docker images"

up:
	docker compose up -d --build

down:
	docker compose down

restart:
	docker compose restart

logs:
	docker compose logs -f

status:
	@echo "=== Proxy Health ==="
	@curl -s http://localhost:8080/health || echo "Proxy offline"
	@echo "\n=== Primary API Stats ==="
	@curl -s http://localhost:8080/primary/api/stats | grep -E '"(total_requests|service|version)"' || echo "Primary offline"
	@echo "\n=== Shadow API Stats ==="
	@curl -s http://localhost:8080/shadow/api/stats | grep -E '"(total_mirrored_requests|service|version)"' || echo "Shadow offline"
	@echo "\n=== Replication Diff ==="
	@curl -s http://localhost:8080/shadow/api/shadow/diff || echo "Diff offline"
	@echo ""

inject:
	python3 traffic_injector.py --requests 50 --concurrency 5

test:
	chmod +x test_traffic_mirroring.sh
	./test_traffic_mirroring.sh

test-verbose:
	chmod +x test_traffic_mirroring.sh
	./test_traffic_mirroring.sh -v

clean:
	docker compose down --rmi all --volumes --remove-orphans
