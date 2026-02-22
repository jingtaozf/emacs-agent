# Makefile for Claude Agent SDK
# Provides convenient targets for development, testing, and release

EMACS ?= emacs
BATCH = $(EMACS) -Q --batch

# Source files
SOURCES = claude-agent.org claude-org.org

# Test files
UNIT_TESTS = tests/test-claude-agent-unit.el tests/test-claude-org-unit.el tests/test-claude-agent-error.el tests/test-claude-agent-json-protocol.el tests/test-claude-agent-backend.el tests/test-claude-agent-backend-protocol.el
INTEGRATION_TESTS = tests/test-claude-agent-integration.el tests/test-claude-org-integration.el tests/test-claude-agent-permissions.el tests/test-mcp-ide-integration.el tests/test-mcp-mode-line.el
ALL_TESTS = $(UNIT_TESTS) $(INTEGRATION_TESTS)

# Load path for tests
LITERATE_ELISP_DIR = $(HOME)/projects/literate-elisp
WEB_SERVER_DIR = $(HOME)/.emacs.d/straight/build/web-server
LOAD_PATH = -L . -L tests -L $(LITERATE_ELISP_DIR) -L $(WEB_SERVER_DIR)

.PHONY: all
all: compile test-unit

.PHONY: help
help:
	@echo "Claude Agent SDK - Make Targets"
	@echo "================================"
	@echo ""
	@echo "Development:"
	@echo "  make compile          - Byte-compile source files"
	@echo "  make clean            - Remove compiled files"
	@echo "  make reload           - Reload org files in running Emacs"
	@echo ""
	@echo "Testing:"
	@echo "  make test             - Run all tests (unit + parallel integration)"
	@echo "  make test-unit        - Run unit tests only (fast, no API)"
	@echo "  make test-integration - Run integration tests in parallel (6 jobs, default)"
	@echo "  make test-integration-seq     - Run integration tests sequentially"
	@echo "  make test-integration PARALLEL_JOBS=N  - Custom parallelism"
	@echo "  make test-agent-unit  - Run claude-agent unit tests"
	@echo "  make test-org-unit    - Run claude-org unit tests"
	@echo "  make test-permissions - Run permission functions tests"
	@echo "  make test-extraction  - Run skill/rule extraction unit tests"
	@echo "  make test-extraction-integration - Run extraction integration tests (API)"
	@echo "  make test-mcp-ide     - Run MCP IDE diagnostics tests"
	@echo "  make test-mcp-ide-unit - Run MCP IDE unit tests only"
	@echo "  make test-mcp-mode-line - Run MCP mode-line spinner tests"
	@echo "  make test-docker      - Run Docker unit tests (path translation)"
	@echo "  make test-docker-sandbox - Run Docker sandbox tests (requires container)"
	@echo "  make test-readme-smoke - Run README tutorial smoke tests (no API)"
	@echo "  make test-readme      - Run full README tutorial tests (requires API)"
	@echo ""
	@echo "Coverage:"
	@echo "  make coverage         - Generate test coverage report"
	@echo ""
	@echo "Release:"
	@echo "  make package          - Create release package"
	@echo "  make check            - Run all checks before release"
	@echo ""
	@echo "Docker:"
	@echo "  make docker-auth      - First-time auth (opens browser for OAuth)"
	@echo "  make docker-up        - Start Claude Code container"
	@echo "  make docker-down      - Stop Claude Code container"
	@echo "  make docker-status    - Show container and auth volume status"
	@echo ""
	@echo "Documentation:"
	@echo "  make docs             - Generate documentation"
	@echo "  make readme           - Update README from org files"
	@echo ""
	@echo "Static Analysis:"
	@echo "  make lint             - Run static analysis:"
	@echo "                          * Undefined functions/variables"
	@echo "                          * Code outside src blocks (literate programming)"
	@echo "                          * Duplicate definitions"
	@echo "  make check            - Run all checks (lint + test-unit)"

.PHONY: compile
compile:
	@echo "Compiling literate org files..."
	$(BATCH) $(LOAD_PATH) \
		--eval "(require 'literate-elisp)" \
		--eval "(literate-elisp-tangle-file \"claude-agent.org\")" \
		--eval "(literate-elisp-tangle-file \"claude-org.org\")" \
		--eval "(byte-compile-file \"claude-code.el\")" \
		--eval "(byte-compile-file \"claude-org.el\")"

.PHONY: clean
clean:
	@echo "Cleaning compiled files..."
	rm -f claude-code.elc
	rm -f claude-org.el claude-org.elc
	rm -f tests/*.elc

.PHONY: reload
reload:
	@echo "Reloading org files requires running Emacs session"
	@echo "In Emacs, run: M-x eval-expression RET"
	@echo "  (progn"
	@echo "    (literate-elisp-load \"$(PWD)/claude-agent.org\")"
	@echo "    (literate-elisp-load \"$(PWD)/claude-org.org\"))"

# Testing targets

.PHONY: test
test: test-unit test-integration

.PHONY: test-unit
test-unit: test-agent-unit test-org-unit test-backend-unit

# Parallel integration testing configuration
PARALLEL_JOBS ?= 8
PARALLEL := $(shell which parallel 2>/dev/null)
BREW := $(shell which brew 2>/dev/null)

# Main integration target - now uses parallel by default
.PHONY: test-integration
test-integration: _ensure-parallel
	@if which parallel >/dev/null 2>&1; then \
		echo "Running integration tests with $(PARALLEL_JOBS) parallel jobs (GNU parallel)..."; \
		$(MAKE) _run-sharded-tests-parallel TOTAL_SHARDS=$(PARALLEL_JOBS); \
	else \
		echo "Running integration tests with $(PARALLEL_JOBS) parallel jobs (bash background)..."; \
		$(MAKE) _run-sharded-tests-bash TOTAL_SHARDS=$(PARALLEL_JOBS); \
	fi

# Sequential integration tests (old behavior)
.PHONY: test-integration-seq
test-integration-seq: test-agent-integration test-org-integration

# Ensure GNU parallel is installed (auto-install via brew if missing)
.PHONY: _ensure-parallel
_ensure-parallel:
ifndef PARALLEL
ifdef BREW
	@echo "GNU parallel not found. Installing via Homebrew..."
	@brew install parallel
	@echo "GNU parallel installed successfully."
else
	@echo "Note: GNU parallel not found. Using bash background jobs."
	@echo "For better output, install: brew install parallel (macOS) or apt install parallel (Linux)"
endif
endif

# Internal: run shards using GNU parallel
.PHONY: _run-sharded-tests-parallel
_run-sharded-tests-parallel:
	@seq 0 $$(($(TOTAL_SHARDS) - 1)) | $(PARALLEL) -j$(TOTAL_SHARDS) --group --tag \
		'$(BATCH) $(LOAD_PATH) \
			--eval "(require '\''literate-elisp)" \
			--eval "(literate-elisp-load \"$(PWD)/claude-agent.org\")" \
			--eval "(literate-elisp-load \"$(PWD)/emacs-mcp-server.org\")" \
			--eval "(literate-elisp-load \"$(PWD)/claude-org.org\")" \
			-l tests/fixtures/test-config.el \
			-l tests/fixtures/test-parallel.el \
			-l tests/test-claude-agent-integration.el \
			-l tests/test-claude-org-integration.el \
			--eval "(test-claude-run-shard $(TOTAL_SHARDS) {})"'

# Internal: run shards using bash background jobs (portable fallback)
.PHONY: _run-sharded-tests-bash
_run-sharded-tests-bash:
	@mkdir -p .test-results
	@rm -f .test-results/shard-*.log .test-results/shard-*.exit
	@echo "Starting $(TOTAL_SHARDS) test shards..."
	@for i in $$(seq 0 $$(($(TOTAL_SHARDS) - 1))); do \
		( $(BATCH) $(LOAD_PATH) \
			--eval "(require 'literate-elisp)" \
			--eval "(literate-elisp-load \"$(PWD)/claude-agent.org\")" \
			--eval "(literate-elisp-load \"$(PWD)/emacs-mcp-server.org\")" \
			--eval "(literate-elisp-load \"$(PWD)/claude-org.org\")" \
			-l tests/fixtures/test-config.el \
			-l tests/fixtures/test-parallel.el \
			-l tests/test-claude-agent-integration.el \
			-l tests/test-claude-org-integration.el \
			--eval "(test-claude-run-shard $(TOTAL_SHARDS) $$i)" \
			> .test-results/shard-$$i.log 2>&1; \
			echo $$? > .test-results/shard-$$i.exit ) & \
	done; \
	echo "Waiting for all shards to complete..."; \
	wait; \
	echo ""; \
	echo "=== Test Results by Shard ==="; \
	failed=0; \
	for i in $$(seq 0 $$(($(TOTAL_SHARDS) - 1))); do \
		exit_code=$$(cat .test-results/shard-$$i.exit 2>/dev/null || echo 1); \
		if [ "$$exit_code" = "0" ]; then \
			echo "Shard $$i: PASSED"; \
		else \
			echo "Shard $$i: FAILED (exit $$exit_code)"; \
			failed=1; \
		fi; \
	done; \
	echo ""; \
	if [ "$$failed" = "1" ]; then \
		echo "=== Failed Shard Logs ==="; \
		for i in $$(seq 0 $$(($(TOTAL_SHARDS) - 1))); do \
			exit_code=$$(cat .test-results/shard-$$i.exit 2>/dev/null || echo 1); \
			if [ "$$exit_code" != "0" ]; then \
				echo "--- Shard $$i ---"; \
				tail -50 .test-results/shard-$$i.log; \
			fi; \
		done; \
		exit 1; \
	fi

# View test logs from parallel run
.PHONY: test-logs
test-logs:
	@if [ -d .test-results ]; then \
		for f in .test-results/shard-*.log; do \
			echo "=== $$f ==="; \
			cat "$$f"; \
			echo ""; \
		done; \
	else \
		echo "No test results found. Run 'make test-integration' first."; \
	fi

.PHONY: test-agent-unit
test-agent-unit:
	@echo "Running claude-agent unit tests..."
	$(BATCH) $(LOAD_PATH) \
		--eval "(require 'literate-elisp)" \
		--eval "(literate-elisp-load \"$(PWD)/claude-agent.org\")" \
		-l tests/test-claude-agent-unit.el \
		-f ert-run-tests-batch-and-exit

.PHONY: test-backend-unit
test-backend-unit:
	@echo "Running backend protocol unit tests..."
	$(BATCH) $(LOAD_PATH) \
		--eval "(require 'literate-elisp)" \
		--eval "(literate-elisp-load \"$(PWD)/claude-agent.org\")" \
		-l tests/test-claude-agent-backend.el \
		-l tests/test-claude-agent-backend-protocol.el \
		-l tests/test-claude-agent-claude-backend.el \
		-l tests/test-claude-agent-chat-backend.el \
		-f ert-run-tests-batch-and-exit

.PHONY: test-backend-integration
test-backend-integration:
	@echo "Running backend integration tests..."
	$(BATCH) $(LOAD_PATH) \
		--eval "(require 'literate-elisp)" \
		--eval "(literate-elisp-load \"$(PWD)/claude-agent.org\")" \
		--eval "(literate-elisp-load \"$(PWD)/claude-org.org\")" \
		-l tests/test-claude-agent-claude-backend-integration.el \
		-f ert-run-tests-batch-and-exit

.PHONY: test-org-unit
test-org-unit:
	@echo "Running claude-org unit tests..."
	$(BATCH) $(LOAD_PATH) \
		--eval "(require 'literate-elisp)" \
		--eval "(literate-elisp-load \"$(PWD)/claude-agent.org\")" \
		--eval "(literate-elisp-load \"$(PWD)/emacs-mcp-server.org\")" \
		--eval "(literate-elisp-load \"$(PWD)/claude-org.org\")" \
		-l tests/test-claude-org-unit.el \
		-l tests/test-claude-org-refine.el \
		-l tests/test-claude-org-scheduled.el \
		-l tests/test-claude-org-response.el \
		-l tests/test-claude-org-queue.el \
		--eval "(ert-run-tests-batch-and-exit '(or (not (tag :integration)) (tag :unit)))"

.PHONY: test-agent-integration
test-agent-integration:
	@echo "Running claude-agent integration tests (requires API key)..."
	$(BATCH) $(LOAD_PATH) \
		--eval "(require 'literate-elisp)" \
		--eval "(literate-elisp-load \"$(PWD)/claude-agent.org\")" \
		-l tests/fixtures/test-config.el \
		-l tests/test-claude-agent-integration.el \
		-f ert-run-tests-batch-and-exit

.PHONY: test-org-integration
test-org-integration:
	@echo "Running claude-org integration tests (requires API key)..."
	@echo "Note: These tests use the fixture at tests/fixtures/test-session.org"
	$(BATCH) $(LOAD_PATH) \
		--eval "(require 'literate-elisp)" \
		--eval "(literate-elisp-load \"$(PWD)/claude-agent.org\")" \
		--eval "(literate-elisp-load \"$(PWD)/emacs-mcp-server.org\")" \
		--eval "(literate-elisp-load \"$(PWD)/claude-org.org\")" \
		-l tests/fixtures/test-config.el \
		-l tests/test-claude-org-integration.el \
		-f ert-run-tests-batch-and-exit

.PHONY: test-permissions
test-permissions:
	@echo "Running permission functions tests..."
	$(BATCH) $(LOAD_PATH) \
		--eval "(require 'literate-elisp)" \
		--eval "(literate-elisp-load \"$(PWD)/claude-agent.org\")" \
		--eval "(literate-elisp-load \"$(PWD)/claude-org.org\")" \
		-l tests/test-claude-agent-permissions.el \
		--eval "(ert-run-tests-batch-and-exit '(tag :permissions))"

.PHONY: test-org-permissions
test-org-permissions:
	@echo "Running org file protection permission tests..."
	$(BATCH) $(LOAD_PATH) \
		--eval "(require 'literate-elisp)" \
		--eval "(literate-elisp-load \"$(PWD)/claude-agent.org\")" \
		--eval "(literate-elisp-load \"$(PWD)/claude-org.org\")" \
		-l tests/test-claude-agent-permissions.el \
		--eval "(ert-run-tests-batch-and-exit '(tag :org))"

.PHONY: test-extraction
test-extraction:
	@echo "Running skill/rule extraction unit tests..."
	$(BATCH) $(LOAD_PATH) \
		--eval "(require 'literate-elisp)" \
		--eval "(literate-elisp-load \"$(PWD)/claude-agent.org\")" \
		--eval "(literate-elisp-load \"$(PWD)/emacs-mcp-server.org\")" \
		--eval "(literate-elisp-load \"$(PWD)/claude-org.org\")" \
		-l tests/test-claude-org-extraction-integration.el \
		--eval "(ert-run-tests-batch-and-exit '(tag :extraction))"

.PHONY: test-extraction-integration
test-extraction-integration:
	@echo "Running skill/rule extraction integration tests (requires API key)..."
	$(BATCH) $(LOAD_PATH) \
		--eval "(require 'literate-elisp)" \
		--eval "(literate-elisp-load \"$(PWD)/claude-agent.org\")" \
		--eval "(literate-elisp-load \"$(PWD)/emacs-mcp-server.org\")" \
		--eval "(literate-elisp-load \"$(PWD)/claude-org.org\")" \
		-l tests/fixtures/test-config.el \
		-l tests/test-claude-org-extraction-integration.el \
		--eval "(ert-run-tests-batch-and-exit '(and (tag :extraction) (tag :integration)))"

.PHONY: test-mcp-ide
test-mcp-ide:
	@echo "Running MCP IDE diagnostics tests..."
	$(BATCH) $(LOAD_PATH) \
		--eval "(require 'literate-elisp)" \
		--eval "(literate-elisp-load \"$(PWD)/emacs-mcp-server.org\")" \
		-l tests/fixtures/test-config.el \
		-l tests/test-mcp-ide-integration.el \
		--eval "(ert-run-tests-batch-and-exit '(tag :mcp-ide))"

.PHONY: test-mcp-ide-unit
test-mcp-ide-unit:
	@echo "Running MCP IDE unit tests only (no flycheck required)..."
	$(BATCH) $(LOAD_PATH) \
		--eval "(require 'literate-elisp)" \
		--eval "(literate-elisp-load \"$(PWD)/emacs-mcp-server.org\")" \
		-l tests/test-mcp-ide-integration.el \
		--eval "(ert-run-tests-batch-and-exit '(and (tag :mcp-ide) (tag :unit)))"

.PHONY: test-mcp-mode-line
test-mcp-mode-line:
	@echo "Running MCP mode-line spinner tests..."
	$(BATCH) $(LOAD_PATH) \
		--eval "(require 'literate-elisp)" \
		--eval "(literate-elisp-load \"$(PWD)/emacs-mcp-server.org\")" \
		-l tests/test-mcp-mode-line.el \
		--eval "(ert-run-tests-batch-and-exit '(tag :mcp-mode-line))"

.PHONY: test-docker
test-docker:
	@echo "Running Docker unit tests (path translation, etc.)..."
	$(BATCH) $(LOAD_PATH) \
		--eval "(require 'literate-elisp)" \
		--eval "(literate-elisp-load \"$(PWD)/claude-agent.org\")" \
		--eval "(literate-elisp-load \"$(PWD)/emacs-mcp-server.org\")" \
		--eval "(literate-elisp-load \"$(PWD)/claude-org.org\")" \
		-l tests/test-docker-integration.el \
		--eval "(ert-run-tests-batch-and-exit '(and (tag :docker) (not (tag :sandbox))))"

.PHONY: test-docker-sandbox
test-docker-sandbox:
	@echo "Running Docker sandbox integration tests..."
	@echo "Prerequisites: make docker-up && make docker-auth"
	@echo ""
	$(BATCH) $(LOAD_PATH) \
		--eval "(require 'literate-elisp)" \
		--eval "(literate-elisp-load \"$(PWD)/claude-agent.org\")" \
		--eval "(literate-elisp-load \"$(PWD)/emacs-mcp-server.org\")" \
		--eval "(literate-elisp-load \"$(PWD)/claude-org.org\")" \
		-l tests/test-docker-integration.el \
		--eval "(ert-run-tests-batch-and-exit '(tag :sandbox))"

# Docker container management
.PHONY: docker-auth
docker-auth:
	@echo "╔══════════════════════════════════════════════════════════════╗"
	@echo "║  Claude Code Docker Authentication                           ║"
	@echo "╠══════════════════════════════════════════════════════════════╣"
	@echo "║  This will open a browser for OAuth login.                   ║"
	@echo "║  Credentials will be stored in Docker volume:                ║"
	@echo "║    claude-sandbox-data                                       ║"
	@echo "║                                                              ║"
	@echo "║  After auth, you can run: docker compose exec claude claude  ║"
	@echo "╚══════════════════════════════════════════════════════════════╝"
	@echo ""
	cd .devcontainer && docker compose run --rm -it --entrypoint sh claude -c " \
		apt-get update && apt-get install -y --no-install-recommends git curl ca-certificates && \
		bun install -g @anthropic-ai/claude-code@latest && \
		claude /login"

.PHONY: docker-up
docker-up:
	@echo "Starting Claude Code Docker container..."
	cd .devcontainer && docker compose up -d
	@echo "Container started. Run 'docker compose exec claude claude --version' to verify."

.PHONY: docker-down
docker-down:
	@echo "Stopping Claude Code Docker container..."
	cd .devcontainer && docker compose down

.PHONY: docker-status
docker-status:
	@echo "Claude Code Docker Status:"
	@docker compose -f .devcontainer/docker-compose.yml ps 2>/dev/null || echo "Container not running"
	@echo ""
	@echo "Auth volume:"
	@docker volume inspect claude-sandbox-data 2>/dev/null | grep -E "Name|CreatedAt" || echo "Volume not created (run 'make docker-auth' first)"

# README tutorial tests
.PHONY: test-readme-smoke
test-readme-smoke:
	@echo "Running README smoke tests (no API calls)..."
	$(BATCH) $(LOAD_PATH) \
		--eval "(require 'literate-elisp)" \
		--eval "(setq literate-elisp-test-p t)" \
		--eval "(literate-elisp-load \"$(PWD)/claude-agent.org\")" \
		--eval "(literate-elisp-load \"$(PWD)/emacs-mcp-server.org\")" \
		--eval "(literate-elisp-load \"$(PWD)/claude-org.org\")" \
		--eval "(literate-elisp-load \"$(PWD)/README.org\")" \
		--eval "(ert-run-tests-batch-and-exit '(tag :readme-smoke))"

.PHONY: test-readme
test-readme:
	@echo "Running full README tutorial tests (requires Claude API)..."
	$(BATCH) $(LOAD_PATH) \
		--eval "(require 'literate-elisp)" \
		--eval "(setq literate-elisp-test-p t)" \
		--eval "(literate-elisp-load \"$(PWD)/claude-agent.org\")" \
		--eval "(literate-elisp-load \"$(PWD)/emacs-mcp-server.org\")" \
		--eval "(literate-elisp-load \"$(PWD)/claude-org.org\")" \
		--eval "(literate-elisp-load \"$(PWD)/README.org\")" \
		--eval "(ert-run-tests-batch-and-exit '(tag :readme))"

# Interactive test runner (opens in Emacs UI)
.PHONY: test-interactive
test-interactive:
	@echo "Opening test runner in Emacs..."
	$(EMACS) -Q $(LOAD_PATH) \
		--eval "(require 'literate-elisp)" \
		--eval "(literate-elisp-load \"$(PWD)/claude-agent.org\")" \
		--eval "(literate-elisp-load \"$(PWD)/claude-org.org\")" \
		-l tests/test-claude-agent-unit.el \
		-l tests/test-claude-org-unit.el \
		--eval "(ert t)"

# Coverage (requires undercover or similar)
.PHONY: coverage
coverage:
	@echo "Generating coverage report..."
	@echo "TODO: Implement coverage reporting"

# Static Analysis / Linting
# These tests catch undefined functions/variables that would only error at runtime
# Dynamically extracts all definitions from source and verifies they are bound
.PHONY: lint
lint:
	@echo "Running static analysis..."
	$(BATCH) $(LOAD_PATH) \
		--eval "(require 'literate-elisp)" \
		-l tests/test-static-analysis.el \
		--eval "(ert-run-tests-batch-and-exit '(tag :static))"

# Release checks - runs lint + unit tests
.PHONY: check
check: lint test-unit
	@echo ""
	@echo "Pre-release checks completed:"
	@echo "  - Static analysis: PASSED"
	@echo "  - Unit tests: PASSED"

.PHONY: package
package: clean check
	@echo "Creating release package..."
	@echo "TODO: Implement packaging"

# Documentation
.PHONY: docs
docs:
	@echo "Generating documentation..."
	@echo "TODO: Generate API docs from org files"

.PHONY: readme
readme:
	@echo "Updating README.md..."
	@echo "TODO: Extract README content from org files"

# Development helpers
.PHONY: watch
watch:
	@echo "Watching for changes (requires fswatch)..."
	@which fswatch > /dev/null || (echo "fswatch not found. Install with: brew install fswatch" && exit 1)
	fswatch -o claude-agent.org claude-org.org | while read; do \
		echo "Files changed, reloading..."; \
		$(MAKE) test-unit; \
	done

# Quick development cycle
.PHONY: dev
dev:
	@echo "Running development cycle: reload + test-unit"
	$(MAKE) test-unit

# Display current configuration
.PHONY: config
config:
	@echo "Claude Agent SDK Configuration"
	@echo "=============================="
	@echo "EMACS:  $(EMACS)"
	@echo "PWD:    $(PWD)"
	@echo ""
	@echo "Source files:"
	@for file in $(SOURCES); do echo "  - $$file"; done
	@echo ""
	@echo "Test files:"
	@for file in $(ALL_TESTS); do echo "  - $$file"; done
