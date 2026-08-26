# ==============================================================================
# Makefile for Envoy L7 Canary Router and Circuit Breaker Mini-Project
# ==============================================================================
.PHONY: help up down restart logs status verify test test-verbose clean

help:
	@echo "Available commands:"
	@echo "  make up           - Build and start Envoy Router, Service V1, Service V2, and Dashboard"
	@echo "  make down         - Stop running containers"
	@echo "  make restart      - Restart containers"
	@echo "  make logs         - Stream real-time container logs"
	@echo "  make status       - Check Envoy cluster health and backend statistics"
	@echo "  make verify       - Run statistical load generator and verification tool (1000 requests)"
	@echo "  make test         - Execute automated test suite (7 verification phases)"
	@echo "  make test-verbose - Execute automated test suite with verbose output"
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
	@echo "=== Envoy Ingress Health ==="
	@curl -s http://localhost:10000/health || echo "Envoy offline"
	@echo "\n=== Envoy Cluster Status (Admin :9901) ==="
	@curl -s http://localhost:9901/clusters | grep -E "(service_v1|service_v2)::health_flags" || echo "Admin offline"
	@echo "\n=== Service V1 Stats ==="
	@curl -s http://localhost:8001/api/stats | grep -E '"(total_requests|service|version)"' || echo "V1 offline"
	@echo "\n=== Service V2 Stats ==="
	@curl -s http://localhost:8002/api/stats | grep -E '"(total_requests|service|version)"' || echo "V2 offline"
	@echo ""

verify:
	python3 canary_verification.py --requests 1000 --concurrency 10

test:
	chmod +x test_canary_routing.sh
	./test_canary_routing.sh

test-verbose:
	chmod +x test_canary_routing.sh
	./test_canary_routing.sh -v

clean:
	docker compose down --rmi all --volumes --remove-orphans
