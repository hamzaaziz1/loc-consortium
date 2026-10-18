SHELL := /bin/bash
.DEFAULT_GOAL := help

# Which stack commands act on. local holds real chain state; staging is the
# rehearsal environment where risky operations are tried first.
#   make up                 -> local
#   LOC_ENV=staging make up -> staging
LOC_ENV ?= local
export LOC_ENV

COMPOSE := docker compose -p loc-$(LOC_ENV) \
	-f network/compose/compose.yml \
	-f network/compose/compose.$(LOC_ENV).yml

.PHONY: help
help: ## show this help
	@echo "environment: $(LOC_ENV)   (override with LOC_ENV=staging)"
	@echo
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

# --- hygiene ---------------------------------------------------------------

.PHONY: check-eol
check-eol: ## fail if any tracked text file contains CRLF
	@bash tools/check-eol.sh

.PHONY: fmt
fmt: ## format solidity
	@cd contracts && forge fmt

.PHONY: test
test: ## run contract tests
	@cd contracts && forge test -vvv

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

.PHONY: down
down: ## stop the network and remove volumes
	@$(COMPOSE) down -v

.PHONY: ps
ps: ## show node status
	@$(COMPOSE) ps

.PHONY: logs
logs: ## tail logs from all nodes
	@$(COMPOSE) logs -f --tail=50

.PHONY: proxy-up
proxy-up: ## start the operator tooling TLS proxy
	@$(COMPOSE) --profile ops up -d rpc-proxy

.PHONY: proxy-down
proxy-down: ## stop the operator tooling TLS proxy
	@$(COMPOSE) --profile ops stop rpc-proxy

# --- verification -----------------------------------------------------------

.PHONY: smoke
smoke: ## assert the network is healthy
	@bash test/smoke/network.sh

.PHONY: tls-test
tls-test: ## prove the RPC endpoints reject what they should
	@bash test/smoke/tls.sh

.PHONY: verify
verify: smoke tls-test ## run every live check against this environment

.PHONY: clean
clean: ## remove build artefacts
	@rm -rf contracts/out contracts/cache
