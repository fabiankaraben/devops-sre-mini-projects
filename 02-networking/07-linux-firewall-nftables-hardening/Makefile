# ==============================================================================
# Makefile for Linux Firewall Hardening with nftables Mini-Project
# ==============================================================================
.PHONY: help up down restart logs status ruleset audit audit-verbose clean

help:
	@echo "Available commands:"
	@echo "  make up            - Build and start hardened server and security auditor"
	@echo "  make down          - Stop running containers"
	@echo "  make restart       - Restart containers"
	@echo "  make logs          - Stream real-time container logs"
	@echo "  make status        - Display active nftables packet and drop counters"
	@echo "  make ruleset       - View full active nftables ruleset"
	@echo "  make audit         - Execute automated firewall security audit suite (nmap & hping3)"
	@echo "  make audit-verbose - Execute audit suite with verbose diagnostic outputs"
	@echo "  make clean         - Tear down containers, networks, volumes, and Docker images"

up:
	docker compose up -d --build

down:
	docker compose down

restart:
	docker compose restart

logs:
	docker compose logs -f

status:
	@echo "=== Active nftables SRE Observability Counters ==="
	@docker exec nftables-server nft list ruleset | grep -A 2 -E "counter cnt_" || true

ruleset:
	@docker exec nftables-server nft list ruleset

audit:
	chmod +x firewall_audit.sh
	./firewall_audit.sh

audit-verbose:
	chmod +x firewall_audit.sh
	./firewall_audit.sh -v

clean:
	docker compose down --rmi all --volumes --remove-orphans
