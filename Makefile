# Sentinel Shield — convenience wrapper over the POSIX shell scripts.
# These targets only invoke scripts/*.sh; the scripts remain the source of truth
# and are runnable directly without make.
SHELL := /bin/sh

# Overridable variables:
#   MODE      adoption mode for `resolve` (default: read from profile)
#   TARGET    destination project dir for `install`/`sync`
#   FORMAT    output format for resolve/enforce (default: all)
MODE ?=
TARGET ?=
FORMAT ?= all
OUTPUT_DIR ?= reports

MODE_ARG := $(if $(MODE),--mode $(MODE),)

.POSIX:
.PHONY: help detect resolve enforce report quality-php quality-node security \
        install sync self-test validate clean

help: ## Show this help
	@echo "Sentinel Shield — make targets:"
	@grep -E '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) \
		| sed 's/:.*## /\t/' \
		| awk -F'\t' '{ printf "  \033[1m%-14s\033[0m %s\n", $$1, $$2 }'
	@echo ""
	@echo "Variables: MODE=<mode> TARGET=<dir> FORMAT=<fmt> OUTPUT_DIR=<dir>"

detect: ## Detect the stack(s) in the current directory
	@sh scripts/detect-stack.sh

resolve: ## Resolve gates from .sentinel-shield/profile.yaml (MODE=... to force)
	@sh scripts/resolve-gates.sh $(MODE_ARG) --output-dir $(OUTPUT_DIR) --format $(FORMAT)

enforce: ## Enforce resolved gates against reports/security-summary.json
	@sh scripts/enforce-gates.sh --output-dir $(OUTPUT_DIR) --format $(FORMAT)

report: ## Generate the Markdown baseline report
	@sh scripts/generate-report.sh .

quality-php: ## Run available PHP quality tools (skips missing ones)
	@sh scripts/run-php-quality.sh .

quality-node: ## Run available Node quality tools (skips missing ones)
	@sh scripts/run-node-quality.sh .

security: ## Run available local security scanners (skips missing ones)
	@sh scripts/run-local-security.sh .

install: ## Dry-run install into TARGET (add APPLY=1 to apply; FORCE=1 to overwrite)
	@if [ -z "$(TARGET)" ]; then echo "set TARGET=<dir>"; exit 2; fi
	@sh scripts/install-baseline.sh --target "$(TARGET)" \
		$(if $(APPLY),--apply,) $(if $(FORCE),--force,)

sync: ## Report baseline drift in TARGET (non-destructive)
	@if [ -z "$(TARGET)" ]; then echo "set TARGET=<dir>"; exit 2; fi
	@sh scripts/sync-baseline.sh "$(TARGET)"

self-test: ## Resolve baseline + enforce the example summary (expect pass)
	@sh scripts/resolve-gates.sh --mode baseline --output-dir $(OUTPUT_DIR) --format env
	@cp templates/security-summary.example.json $(OUTPUT_DIR)/security-summary.json
	@sh scripts/enforce-gates.sh --output-dir $(OUTPUT_DIR) --format all
	@echo "self-test: PASS"

validate: ## Syntax-check all scripts and run the self-test
	@echo "== sh -n =="
	@for f in scripts/*.sh scripts/lib/*.sh; do sh -n "$$f" || exit 1; echo "ok: $$f"; done
	@echo "== self-test =="
	@$(MAKE) --no-print-directory self-test

clean: ## Remove generated reports/
	@rm -rf $(OUTPUT_DIR)
	@echo "removed $(OUTPUT_DIR)/"

.DEFAULT_GOAL := help
