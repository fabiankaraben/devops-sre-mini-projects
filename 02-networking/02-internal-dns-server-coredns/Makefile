# ==============================================================================
# Makefile for CoreDNS Internal DNS Server Mini-Project
# ==============================================================================
.PHONY: help up down restart logs test dig-app dig-cname dig-txt dig-srv dig-ptr dig-corp clean

help:
	@echo "Available commands:"
	@echo "  make up        - Build and start CoreDNS container in background"
	@echo "  make down      - Stop CoreDNS container"
	@echo "  make restart   - Restart CoreDNS container"
	@echo "  make logs      - View real-time query and server logs"
	@echo "  make test      - Run automated 13-point test suite"
	@echo "  make dig-app   - Query 'app.internal' A record"
	@echo "  make dig-cname - Query 'web.internal' CNAME alias"
	@echo "  make dig-txt   - Query 'info.internal' TXT metadata"
	@echo "  make dig-srv   - Query '_http._tcp.app.internal' SRV record"
	@echo "  make dig-ptr   - Query reverse DNS for 10.0.1.10"
	@echo "  make dig-corp  - Query split-horizon rewrite 'app.corp'"
	@echo "  make clean     - Tear down all containers, networks, volumes, and images"

up:
	docker compose up -d --build

down:
	docker compose down

restart:
	docker compose restart

logs:
	docker compose logs -f

test:
	chmod +x dns_test_client.sh
	./dns_test_client.sh

dig-app:
	dig @127.0.0.1 -p 53 app.internal A

dig-cname:
	dig @127.0.0.1 -p 53 web.internal A

dig-txt:
	dig @127.0.0.1 -p 53 info.internal TXT

dig-srv:
	dig @127.0.0.1 -p 53 _http._tcp.app.internal SRV

dig-ptr:
	dig @127.0.0.1 -p 53 -x 10.0.1.10

dig-corp:
	dig @127.0.0.1 -p 53 app.corp A

clean:
	docker compose down --rmi all --volumes --remove-orphans
