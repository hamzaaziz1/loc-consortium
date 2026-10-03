SHELL := /bin/bash
.DEFAULT_GOAL := help

.PHONY: help
help: ## show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

.PHONY: check-eol
check-eol: ## fail if any tracked text file contains CRLF
	@bash tools/check-eol.sh

.PHONY: fmt
fmt: ## format solidity
	@cd contracts && forge fmt

.PHONY: test
test: ## run contract tests
	@cd contracts && forge test -vvv

.PHONY: pki
pki: ## generate the full CA tree and all certificates
	@./network/pki/gen-root.sh
	@./network/pki/gen-intermediates.sh
	@./network/pki/gen-leaves.sh

.PHONY: pki-test
pki-test: ## prove the PKI controls are enforced
	@bash test/pki/name-constraints.sh

.PHONY: pki-clean
pki-clean: ## destroy all generated key material and certificates
	@rm -rf network/pki/out
	@echo "removed network/pki/out"

.PHONY: genesis
genesis: ## assemble the QBFT genesis file (m2)
	@echo "not implemented until m2"

.PHONY: up
up: ## start the consortium network (m2)
	@echo "not implemented until m2"

.PHONY: down
down: ## stop the network and remove volumes (m2)
	@echo "not implemented until m2"

.PHONY: smoke
smoke: ## full LoC lifecycle against a running network (m5)
	@echo "not implemented until m5"

.PHONY: clean
clean: ## remove generated artefacts
	@rm -rf contracts/out contracts/cache network/compose/data
