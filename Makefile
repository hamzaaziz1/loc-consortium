SHELL := /bin/bash
.DEFAULT_GOAL := help

# Which stack commands act on. local holds real chain state; staging is the
# rehearsal environment where risky operations are tried first.
#   make up                 -> local
#   LOC_ENV=staging make up -> staging
LOC_ENV ?= local
export LOC_ENV

# Host ports differ per environment so the two stacks cannot collide and a
# command aimed at the wrong one fails rather than quietly succeeding.
PROXY_PORT_local        := 8600
PROXY_PORT_staging      := 8700
PROXY_PORT              := $(PROXY_PORT_$(LOC_ENV))
PROMETHEUS_PORT_local   := 9090
PROMETHEUS_PORT_staging := 9190
PROMETHEUS_PORT         := $(PROMETHEUS_PORT_$(LOC_ENV))
GRAFANA_PORT_local      := 3000
GRAFANA_PORT_staging    := 3100
GRAFANA_PORT            := $(GRAFANA_PORT_$(LOC_ENV))
export PROXY_PORT PROMETHEUS_PORT GRAFANA_PORT

COMPOSE := docker compose -p loc-$(LOC_ENV) \
	-f network/compose/compose.yml \
	-f network/compose/compose.$(LOC_ENV).yml

.PHONY: help
help: ## show this help
	@echo "environment: $(LOC_ENV)   proxy: $(PROXY_PORT)   (override with LOC_ENV=staging)"
	@echo
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

# --- hygiene ----------------------------------------------------------------

.PHONY: check-eol
check-eol: ## fail if any tracked text file contains CRLF
	@bash tools/check-eol.sh

.PHONY: fmt
fmt: ## format solidity
	@cd contracts && forge fmt

.PHONY: test
test: ## run contract tests
	@cd contracts && forge test -vvv

.PHONY: test-controller
test-controller: ## run the permissioning controller tests
	@cd services/permissioning-controller && npm test

# --- PKI (shared by both environments) --------------------------------------

.PHONY: pki
pki: ## generate the CA tree, all certificates and keystores
	@./network/pki/gen-root.sh
	@./network/pki/gen-intermediates.sh
	@./network/pki/gen-leaves.sh
	@./network/pki/gen-keystores.sh

.PHONY: keystores
keystores: ## rebuild only the PKCS12 keystores and truststore
	@./network/pki/gen-keystores.sh

.PHONY: pki-test
pki-test: ## prove the PKI controls are enforced, offline
	@bash test/pki/name-constraints.sh

.PHONY: pki-clean
pki-clean: ## destroy all generated key material and certificates
	@rm -rf network/pki/out
	@echo "removed network/pki/out"

# --- chain material (per environment) ---------------------------------------

.PHONY: network-keys
network-keys: ## generate the QBFT genesis and node keys
	@./tools/gen-network.sh

.PHONY: network-config
network-config: ## generate static nodes and the compose override
	@./tools/gen-static-nodes.sh

.PHONY: permissions
permissions: ## write the initial allowlist (before nodes start)
	@./tools/gen-permissions.sh

.PHONY: deploy-config
deploy-config: ## join the founding consortium into deploy.json
	@./tools/gen-deploy-config.sh

.PHONY: network-clean
network-clean: ## destroy this environment's genesis, keys and generated config
	@rm -rf network/genesis/$(LOC_ENV) network/keys/$(LOC_ENV)
	@rm -f network/config/$(LOC_ENV)/static-nodes.json network/config/$(LOC_ENV)/deploy.json
	@rm -f network/compose/compose.$(LOC_ENV).yml
	@echo "removed generated material for $(LOC_ENV)"

# --- running ----------------------------------------------------------------

.PHONY: up
up: ## start the consortium network
	@$(COMPOSE) up -d
	@echo "$(LOC_ENV) is up"

.PHONY: restart
restart: ## restart every node, required after any genesis or permissions change
	@echo "restarting $(LOC_ENV) so nodes reread their configuration..."
	@$(COMPOSE) restart
	@echo "waiting for the network to answer"
	@bash test/smoke/network.sh >/dev/null 2>&1 || true
	@bash test/smoke/network.sh | tail -3

.PHONY: down
down: ## stop the network and remove volumes
	@$(COMPOSE) down -v

.PHONY: stop
stop: ## stop the network, keeping volumes and chain state
	@$(COMPOSE) --profile ops stop

.PHONY: ps
ps: ## show node status
	@$(COMPOSE) ps

.PHONY: logs
logs: ## tail logs from all nodes
	@$(COMPOSE) logs -f --tail=50

# --- operator services (ops profile) ----------------------------------------

.PHONY: proxy-up
proxy-up: ## start the TLS-terminating proxy for Foundry
	@$(COMPOSE) --profile ops up -d rpc-proxy
	@echo "$(LOC_ENV) RPC available at http://127.0.0.1:$(PROXY_PORT)"

.PHONY: proxy-down
proxy-down: ## stop the operator tooling proxy
	@$(COMPOSE) --profile ops stop rpc-proxy

.PHONY: controller-up
controller-up: ## start the permissioning controller (needs REGISTRY_ADDRESS)
	@$(COMPOSE) --profile ops up -d --build permissioning-controller

.PHONY: controller-logs
controller-logs: ## tail the permissioning controller
	@$(COMPOSE) --profile ops logs -f --tail=30 permissioning-controller

.PHONY: cert-metrics
cert-metrics: ## refresh certificate expiry metrics
	@bash tools/cert-expiry-metrics.sh

.PHONY: observability-up
observability-up: cert-metrics ## start prometheus, grafana and cert metrics
	@$(COMPOSE) --profile ops up -d prometheus grafana cert-metrics
	@echo "prometheus http://127.0.0.1:$(PROMETHEUS_PORT)"
	@echo "grafana    http://127.0.0.1:$(GRAFANA_PORT)"

.PHONY: observability-down
observability-down: ## stop the observability stack
	@$(COMPOSE) --profile ops stop prometheus grafana cert-metrics

# --- verification -----------------------------------------------------------

.PHONY: smoke
smoke: ## assert the network is healthy
	@bash test/smoke/network.sh

.PHONY: tls-test
tls-test: ## prove the RPC endpoints reject what they should
	@bash test/smoke/tls.sh

.PHONY: perm-test
perm-test: ## prove the permissioning layer enforces membership
	@bash test/smoke/permissioning.sh

.PHONY: privacy-test
privacy-test: ## prove sealed terms are unreadable by non-recipients
	@bash test/privacy/terms.sh

.PHONY: verify
verify: smoke tls-test ## run the live checks against this environment

.PHONY: verify-all
verify-all: pki-test smoke tls-test perm-test privacy-test ## every suite that needs a running network

.PHONY: loc-demo
loc-demo: ## run a full letter of credit lifecycle (needs FACTORY=0x...)
	@bash tools/loc-demo.sh

.PHONY: clean
clean: ## remove build artefacts
	@rm -rf contracts/out contracts/cache
