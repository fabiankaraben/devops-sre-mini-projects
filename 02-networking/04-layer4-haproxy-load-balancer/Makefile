# ==============================================================================
# Makefile for Layer 4 HAProxy Load Balancer Mini-Project
# ==============================================================================
.PHONY: help up down restart logs test test-failover curl-lb stats clean

help:
	@echo "Available commands:"
	@echo "  make up            - Build and start HAProxy and 3 backend instances"
	@echo "  make down          - Stop all containers"
	@echo "  make restart       - Restart containers"
	@echo "  make logs          - View real-time container logs"
	@echo "  make test          - Run 60-request round-robin traffic distribution test"
	@echo "  make test-failover - Run full failover and self-healing test"
	@echo "  make curl-lb       - Send single test request through HAProxy (port 9000)"
	@echo "  make stats         - Fetch live HAProxy CSV stats from port 8404"
	@echo "  make clean         - Tear down all containers, networks, volumes, and images"

up:
	docker compose up -d --build

down:
	docker compose down

restart:
	docker compose restart

logs:
	docker compose logs -f

test:
	chmod +x traffic_simulator.sh
	./traffic_simulator.sh

test-failover:
	chmod +x traffic_simulator.sh
	./traffic_simulator.sh --failover

curl-lb:
	curl -s http://localhost:9000/api/info

stats:
	curl -s -u admin:admin123 http://localhost:8404/\;csv

clean:
	docker compose down --rmi all --volumes --remove-orphans
