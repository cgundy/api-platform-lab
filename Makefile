.DEFAULT_GOAL := help

SERVICE ?= gateway

.PHONY: help up down stop ps logs restart reload check shell reset test loadtest chaos-reset certs

help: ## show this list
	@grep -E '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN{FS=":.*## "}{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

up: ## start everything, detached
	docker compose up -d

down: ## stop and remove containers + network
	docker compose down

stop: ## stop containers without removing them
	docker compose stop

ps: ## what's running, with health and ports
	docker compose ps

logs: ## follow logs for SERVICE (default: gateway) - e.g. make logs SERVICE=echo1
	docker compose logs -f $(SERVICE)

restart: ## restart SERVICE (default: gateway) - drops in-flight connections
	docker compose restart $(SERVICE)

reload: ## zero-downtime nginx reload after a config edit
	docker compose exec gateway nginx -s reload

check: ## check nginx.conf parses - ALWAYS run before restart/reload
	docker compose exec gateway nginx -t

shell: ## shell into SERVICE (default: gateway)
	docker compose exec $(SERVICE) sh

reset: ## full reset: remove volumes, rebuild from scratch
	docker compose down -v
	docker compose up -d --force-recreate

test: ## run the smoke test (bin/test.sh)
	bin/test.sh

loadtest: ## bin/loadtest.sh ROUTE N CONCURRENCY - e.g. make loadtest ROUTE=/users/ N=100 C=10
	bin/loadtest.sh $(ROUTE) $(N) $(C)

chaos-reset: ## undo any toxiproxy chaos
	bin/chaos.sh reset

certs: ## generate a self-signed cert for lab 07
	bin/setup-certs.sh
