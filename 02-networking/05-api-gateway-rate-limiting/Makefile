# ==============================================================================
# Makefile for API Gateway Rate Limiting Mini-Project
# ==============================================================================
.PHONY: help up down restart logs test curl-users curl-auth clean

help:
	@echo "Available commands:"
	@echo "  make up          - Build and start API Gateway and mock API backend"
	@echo "  make down        - Stop all containers"
	@echo "  make restart     - Restart containers"
	@echo "  make logs        - View real-time access and rate-limiting logs"
	@echo "  make test        - Run automated concurrency burst test suite"
	@echo "  make curl-users  - Send GET request to /api/v1/users"
	@echo "  make curl-auth   - Send POST login request to /api/v1/auth/login"
	@echo "  make clean       - Tear down containers, networks, volumes, and images"

up:
	docker compose up -d --build

down:
	docker compose down

restart:
	docker compose restart

logs:
	docker compose logs -f

test:
	chmod +x burst_tester.py
	python3 burst_tester.py --url http://localhost:8085

curl-users:
	curl -s -i http://localhost:8085/api/v1/users

curl-auth:
	curl -s -i -X POST http://localhost:8085/api/v1/auth/login \
	  -H "Content-Type: application/json" \
	  -d '{"username":"admin","password":"password123"}'

clean:
	docker compose down --rmi all --volumes --remove-orphans
