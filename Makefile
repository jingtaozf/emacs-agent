# Makefile for Claude Agent SDK
# Provides convenient targets for development, testing, and release

EMACS ?= emacs
BATCH = $(EMACS) -Q --batch

# Source files
SOURCES = claude-agent.org code-agent-org.org claude-agent-trace.org

# Test files
# Note: actual test loading is in target recipes below, not this variable
UNIT_TESTS = tests/test-claude-agent-unit.el tests/test-code-agent-org-unit.el tests/test-claude-agent-json-protocol.el tests/test-claude-agent-backend.el tests/test-claude-agent-backend-protocol.el
MOCK_TESTS = tests/test-claude-agent-mock.el tests/test-code-agent-org-mock.el
INTEGRATION_TESTS = tests/test-claude-agent-integration.el tests/test-code-agent-org-integration.el tests/test-claude-agent-permissions.el tests/test-mcp-ide-integration.el tests/test-mcp-mode-line.el
ALL_TESTS = $(UNIT_TESTS) $(MOCK_TESTS) $(INTEGRATION_TESTS)

# Load path for tests
LITERATE_ELISP_DIR ?= $(HOME)/projects/literate-elisp
WEB_SERVER_DIR ?= $(HOME)/.emacs.d/straight/build/web-server
COMPANY_DIR ?= $(HOME)/.emacs.d/straight/build/company
WEBSOCKET_DIR ?= $(HOME)/.emacs.d/straight/build/websocket
YASNIPPET_DIR ?= $(HOME)/.emacs.d/straight/build/yasnippet
ACP_DIR ?= $(HOME)/.emacs.d/straight/build/acp
LOAD_PATH = -L . -L tests -L $(LITERATE_ELISP_DIR) -L $(WEB_SERVER_DIR) -L $(COMPANY_DIR) -L $(WEBSOCKET_DIR) -L $(YASNIPPET_DIR) -L $(ACP_DIR)

# Common literate-elisp load sequences (DRY — used by all test targets)
# Load order: trace → agent (includes backend) → mcp → org
LOAD_LITERATE = --eval "(require 'literate-elisp)"
LOAD_TRACE = --eval "(literate-elisp-load \"$(PWD)/claude-agent-trace.org\")"
LOAD_AGENT = $(LOAD_TRACE) --eval "(literate-elisp-load \"$(PWD)/claude-agent.org\")" \
             --eval "(literate-elisp-load \"$(PWD)/claude-agent-refine.org\")" \
             --eval "(literate-elisp-load \"$(PWD)/claude-agent-multiplexer.org\")" \
             --eval "(literate-elisp-load \"$(PWD)/claude-agent-cmux-backend.org\")" \
             --eval "(literate-elisp-load \"$(PWD)/claude-agent-tmux-backend.org\")"
LOAD_ACP = --eval "(literate-elisp-load \"$(PWD)/claude-agent-jsonrpc.org\")" \
           --eval "(literate-elisp-load \"$(PWD)/claude-agent-acp.org\")" \
           --eval "(literate-elisp-load \"$(PWD)/claude-agent-acp-opencode.org\")" \
           --eval "(literate-elisp-load \"$(PWD)/claude-agent-acp-gemini.org\")" \
           --eval "(literate-elisp-load \"$(PWD)/claude-agent-acp-codex.org\")"
LOAD_MCP = $(LOAD_TRACE) --eval "(literate-elisp-load \"$(PWD)/emacs-mcp-server.org\")"
LOAD_ORG = --eval "(literate-elisp-load \"$(PWD)/code-agent-org.org\")"
# Presets for common combinations
LOAD_AGENT_ONLY = $(LOAD_LITERATE) $(LOAD_AGENT)
LOAD_ALL = $(LOAD_LITERATE) $(LOAD_AGENT) $(LOAD_MCP) $(LOAD_ORG)

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
	@echo "  make install-hooks    - Install/update git pre-commit hook"
	@echo ""
	@echo "Testing:"
	@echo "  make test-smoke       - Fast syntax check (< 2s) — run after every edit"
	@echo "  make test             - Run all tests (unit + parallel integration)"
	@echo "  make test-unit        - Run unit tests only (fast, no API, ~13s)"
	@echo "  make test-unit-parallel - Run unit tests in parallel (~4.5s)"
	@echo "  make test-integration - Run integration tests in parallel (6 jobs, default)"
	@echo "  make test-integration-seq     - Run integration tests sequentially"
	@echo "  make test-integration PARALLEL_JOBS=N  - Custom parallelism"
	@echo "  make test-agent-unit  - Run claude-agent unit tests"
	@echo "  make test-org-unit    - Run code-agent-org unit tests"
	@echo "  make test-permissions - Run permission functions tests"
	@echo "  make test-mcp-mode-line - Run MCP mode-line spinner tests"
	@echo "  make test-mock        - Run mock CLI tests (no API, fast)"
	@echo "  make test-agent-mock  - Run agent mock CLI tests"
	@echo "  make test-org-mock    - Run org mock CLI tests"
	@echo "  make test-docker      - Run Docker unit tests (path translation)"
	@echo "  make test-docker-sandbox - Run Docker sandbox tests (requires container)"
	@echo "  make test-workspace-bridge  - E2E tests for terminal workspace bridge (requires MCP)"
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
		$(LOAD_LITERATE) \
		--eval "(literate-elisp-tangle-file \"claude-agent.org\")" \
		--eval "(literate-elisp-tangle-file \"code-agent-org.org\")" \
		--eval "(byte-compile-file \"claude-code.el\")" \
		--eval "(byte-compile-file \"code-agent-org.el\")"

.PHONY: clean
clean:
	@echo "Cleaning compiled files..."
	rm -f claude-code.elc
	rm -f code-agent-org.el code-agent-org.elc
	rm -f tests/*.elc

.PHONY: reload
reload:
	@echo "Reloading org files requires running Emacs session"
	@echo "In Emacs, run: M-x eval-expression RET"
	@echo "  (progn"
	@echo "    (literate-elisp-load \"$(PWD)/claude-agent-trace.org\")"
	@echo "    (literate-elisp-load \"$(PWD)/claude-agent.org\")"
	@echo "    (literate-elisp-load \"$(PWD)/code-agent-org.org\"))"

.PHONY: install-hooks
install-hooks:
	@echo "Installing git hooks..."
	@mkdir -p .git/hooks
	@cp scripts/pre-commit .git/hooks/pre-commit
	@chmod +x .git/hooks/pre-commit
	@echo "Pre-commit hook installed successfully."
	@echo "Hook runs 656 tests (~50s): lint, unit, permissions, mock CLI"
	@echo "To skip temporarily: git commit --no-verify"

# Testing targets

.PHONY: test
test: test-unit test-integration

# Fast syntax check — agents run after every edit (< 2s)
.PHONY: test-smoke
test-smoke:
	@echo "Running smoke tests..."
	$(BATCH) $(LOAD_PATH) \
		$(LOAD_ALL) \
		-L tests/support \
		-l tests/support/test-helpers.el \
		-l tests/test-agent-workflow.el \
		--eval "(ert-run-tests-batch-and-exit '(tag :smoke))"

# Unit test targets are independent — use 'make -j4 test-unit' for parallel
.PHONY: test-unit
test-unit: test-agent-unit test-org-unit test-backend-unit test-acp-unit test-cmux

.PHONY: test-cmux
test-cmux:
	@echo "Running cmux backend E2E tests..."
	$(BATCH) $(LOAD_PATH) \
		$(LOAD_ALL) \
		--eval "(literate-elisp-load \"$(PWD)/code-agent-org-workspace-bridge.org\")" \
		--eval "(literate-elisp-load \"$(PWD)/code-agent-org-terminal-base.org\")" \
		--eval "(literate-elisp-load \"$(PWD)/code-agent-org-cmux.org\")" \
		-l tests/test-cmux-e2e-simulated.el \
		-l tests/test-cmux-e2e-agent-profiles.el \
		-l tests/test-cmux-env-injection.el \
		-f ert-run-tests-batch-and-exit

# Convenience target: run unit tests in parallel automatically
UNIT_PARALLEL_JOBS ?= 3
.PHONY: test-unit-parallel
test-unit-parallel:
	@$(MAKE) -j$(UNIT_PARALLEL_JOBS) test-unit

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
			$(LOAD_ALL) \
			-l tests/fixtures/test-config.el \
			-l tests/fixtures/test-parallel.el \
			-l tests/test-claude-agent-integration.el \
			-l tests/test-code-agent-org-integration.el \
			-l tests/test-code-agent-org-cancel-active-queries.el \
			-l tests/test-code-agent-org-cancel-race.el \
			-l tests/test-code-agent-org-exec-status.el \
			--eval "(test-claude-run-shard $(TOTAL_SHARDS) {})"'

# Internal: run shards using bash background jobs (portable fallback)
.PHONY: _run-sharded-tests-bash
_run-sharded-tests-bash:
	@mkdir -p .test-results
	@rm -f .test-results/shard-*.log .test-results/shard-*.exit
	@echo "Starting $(TOTAL_SHARDS) test shards..."
	@for i in $$(seq 0 $$(($(TOTAL_SHARDS) - 1))); do \
		( $(BATCH) $(LOAD_PATH) \
			$(LOAD_ALL) \
			-l tests/fixtures/test-config.el \
			-l tests/fixtures/test-parallel.el \
			-l tests/test-claude-agent-integration.el \
			-l tests/test-code-agent-org-integration.el \
			-l tests/test-code-agent-org-cancel-active-queries.el \
			-l tests/test-code-agent-org-cancel-race.el \
			-l tests/test-code-agent-org-exec-status.el \
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
		$(LOAD_AGENT_ONLY) \
		-l tests/fixtures/test-config.el \
		-l tests/test-claude-agent-unit.el \
		-l tests/test-claude-agent-refactor-phase3.el \
		-l tests/test-claude-agent-json-protocol.el \
		-l tests/test-claude-agent-state-management.el \
		-l tests/test-claude-agent-background-tasks.el \
		-l tests/test-claude-agent-chat.el \
		-l tests/test-claude-agent-error-injection.el \
		-l tests/test-claude-agent-sentinel.el \
		-l tests/test-json-parser-property.el \
		-l tests/test-harness-phase2.el \
		-l tests/test-permission-round-trip.el \
		-l tests/test-verbose-formatter.el \
		-f ert-run-tests-batch-and-exit

.PHONY: test-backend-unit
test-backend-unit:
	@echo "Running backend protocol unit tests..."
	$(BATCH) $(LOAD_PATH) \
		$(LOAD_AGENT_ONLY) \
		-l tests/test-claude-agent-backend.el \
		-l tests/test-claude-agent-backend-protocol.el \
		-l tests/test-claude-agent-chat-backend.el \
		-l tests/test-backend-protocol3.el \
		-f ert-run-tests-batch-and-exit

.PHONY: test-acp-unit
test-acp-unit:
	@echo "Running ACP backend unit tests..."
	$(BATCH) $(LOAD_PATH) \
		$(LOAD_AGENT_ONLY) \
		$(LOAD_ACP) \
		-l tests/test-claude-agent-acp.el \
		-f ert-run-tests-batch-and-exit

.PHONY: test-org-unit
test-org-unit:
	@echo "Running code-agent-org unit tests..."
	$(BATCH) $(LOAD_PATH) -L tests/support \
		$(LOAD_ALL) \
		-l tests/support/test-helpers.el \
		-l tests/test-code-agent-org-unit.el \
		-l tests/test-code-agent-org-refine.el \
		-l tests/test-code-agent-org-scheduled.el \
		-l tests/test-code-agent-org-response.el \
		-l tests/test-code-agent-org-queue.el \
		-l tests/test-code-agent-org-cancel.el \
		-l tests/test-code-agent-org-refactor-phase1.el \
		-l tests/test-code-agent-org-refactor-phase2.el \
		-l tests/test-code-agent-org-refactor-phase4.el \
		-l tests/support/org-fixtures.el \
		-l tests/test-code-agent-org-refactor-phase5.el \
		-l tests/test-code-agent-org-heading-level.el \
		-l tests/test-code-agent-org-content-loss-repro.el \
		-l tests/test-code-agent-org-wrong-level-repro.el \
		-l tests/test-code-agent-org-wrong-position-repro.el \
		-l tests/test-code-agent-org-loop.el \
		-l tests/test-code-agent-org-marker-lifecycle.el \
		-l tests/test-code-agent-org-query-id.el \
		-l tests/test-code-agent-org-query-id-issues.el \
		-l tests/test-code-agent-org-workspace.el \
		-l tests/test-mcp-report-invocation.el \
		-l tests/test-plugin-discovery.el \
		-l tests/test-code-agent-org-edge-cases.el \
		-l tests/test-slash-completion.el \
		-l tests/test-code-agent-org-loop-detection.el \
		-l tests/test-code-agent-org-pre-completion.el \
		-l tests/test-code-agent-org-telemetry.el \
		-l tests/test-structural.el \
		-l tests/test-mcp-eval-state.el \
		-l tests/test-agent-workflow.el \
		-l tests/test-codebase-hardening.el \
		-l tests/test-mcp-protocol.el \
		-l tests/test-mcp-lifecycle.el \
		-l tests/test-mcp-eval-handler.el \
		-l tests/test-mcp-http.el \
		-l tests/test-code-agent-org-cleanup.el \
		-l tests/test-code-agent-org-cleanup-r2.el \
		--eval "(literate-elisp-load \"$(PWD)/code-agent-org-workspace-bridge.org\")" \
		--eval "(literate-elisp-load \"$(PWD)/code-agent-org-terminal-base.org\")" \
		-l tests/test-workspace-bridge-response.el \
		-l tests/test-ide-open-editors.el \
		-l tests/test-claude-agent-input-validation.el \
		--eval "(ert-run-tests-batch-and-exit '(or (not (tag :integration)) (tag :unit)))"

.PHONY: test-mcp-unit
test-mcp-unit:
	@echo "Running MCP server unit tests..."
	$(BATCH) $(LOAD_PATH) \
		$(LOAD_LITERATE) \
		$(LOAD_MCP) \
		-l tests/test-mcp-protocol.el \
		-l tests/test-mcp-lifecycle.el \
		-l tests/test-mcp-eval-handler.el \
		-l tests/test-mcp-http.el \
		-f ert-run-tests-batch-and-exit

.PHONY: test-mock
test-mock: test-agent-mock test-org-mock

.PHONY: test-agent-mock
test-agent-mock:
	@echo "Running claude-agent mock CLI tests..."
	$(BATCH) $(LOAD_PATH) \
		$(LOAD_AGENT_ONLY) \
		-l tests/fixtures/test-config.el \
		-l tests/test-claude-agent-mock.el \
		-f ert-run-tests-batch-and-exit

.PHONY: test-org-mock
test-org-mock:
	@echo "Running code-agent-org mock CLI tests..."
	$(BATCH) $(LOAD_PATH) \
		$(LOAD_ALL) \
		-l tests/fixtures/test-config.el \
		-l tests/test-code-agent-org-mock.el \
		-f ert-run-tests-batch-and-exit

.PHONY: test-agent-integration
test-agent-integration:
	@echo "Running claude-agent integration tests (requires API key)..."
	$(BATCH) $(LOAD_PATH) \
		$(LOAD_AGENT_ONLY) \
		-l tests/fixtures/test-config.el \
		-l tests/test-claude-agent-integration.el \
		-f ert-run-tests-batch-and-exit

.PHONY: test-org-integration
test-org-integration:
	@echo "Running code-agent-org integration tests (requires API key)..."
	@echo "Note: These tests use the fixture at tests/fixtures/test-session.org"
	$(BATCH) $(LOAD_PATH) \
		$(LOAD_ALL) \
		-l tests/fixtures/test-config.el \
		-l tests/test-code-agent-org-integration.el \
		-l tests/test-code-agent-org-cancel-active-queries.el \
		-l tests/test-code-agent-org-cancel-race.el \
		-l tests/test-code-agent-org-exec-status.el \
		-f ert-run-tests-batch-and-exit

.PHONY: test-permissions
test-permissions:
	@echo "Running permission functions tests..."
	$(BATCH) $(LOAD_PATH) \
		$(LOAD_AGENT_ONLY) \
		$(LOAD_ORG) \
		-l tests/test-claude-agent-permissions.el \
		--eval "(ert-run-tests-batch-and-exit '(tag :permissions))"

.PHONY: test-org-permissions
test-org-permissions:
	@echo "Running org file protection permission tests..."
	$(BATCH) $(LOAD_PATH) \
		$(LOAD_AGENT_ONLY) \
		$(LOAD_ORG) \
		-l tests/test-claude-agent-permissions.el \
		--eval "(ert-run-tests-batch-and-exit '(tag :org))"

# NOTE: test-extraction and test-mcp-ide targets removed — source files were deleted.
# See git log for history.


.PHONY: test-mcp-mode-line
test-mcp-mode-line:
	@echo "Running MCP mode-line spinner tests..."
	$(BATCH) $(LOAD_PATH) \
		$(LOAD_LITERATE) \
		$(LOAD_MCP) \
		-l tests/test-mcp-mode-line.el \
		--eval "(ert-run-tests-batch-and-exit '(tag :mcp-mode-line))"

.PHONY: test-docker
test-docker:
	@echo "Running Docker unit tests (path translation, etc.)..."
	$(BATCH) $(LOAD_PATH) \
		$(LOAD_ALL) \
		-l tests/test-docker-integration.el \
		--eval "(ert-run-tests-batch-and-exit '(and (tag :docker) (not (tag :sandbox))))"

.PHONY: test-docker-sandbox
test-docker-sandbox:
	@echo "Running Docker sandbox integration tests..."
	@echo "Prerequisites: make docker-up && make docker-auth"
	@echo ""
	$(BATCH) $(LOAD_PATH) \
		$(LOAD_ALL) \
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
		$(LOAD_LITERATE) \
		--eval "(setq literate-elisp-test-p t)" \
		$(LOAD_AGENT) $(LOAD_MCP) $(LOAD_ORG) \
		--eval "(literate-elisp-load \"$(PWD)/README.org\")" \
		--eval "(ert-run-tests-batch-and-exit '(tag :readme-smoke))"

.PHONY: test-readme
test-readme:
	@echo "Running full README tutorial tests (requires Claude API)..."
	$(BATCH) $(LOAD_PATH) \
		$(LOAD_LITERATE) \
		--eval "(setq literate-elisp-test-p t)" \
		$(LOAD_AGENT) $(LOAD_MCP) $(LOAD_ORG) \
		--eval "(literate-elisp-load \"$(PWD)/README.org\")" \
		--eval "(ert-run-tests-batch-and-exit '(tag :readme))"

# Interactive test runner (opens in Emacs UI)
.PHONY: test-interactive
test-interactive:
	@echo "Opening test runner in Emacs..."
	$(EMACS) -Q $(LOAD_PATH) \
		$(LOAD_ALL) \
		-l tests/test-claude-agent-unit.el \
		-l tests/test-code-agent-org-unit.el \
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
		$(LOAD_LITERATE) \
		-l tests/test-static-analysis.el \
		--eval "(ert-run-tests-batch-and-exit '(tag :static))"

# OTel trace tests
.PHONY: test-otel
test-otel:
	@echo "Running OTel trace unit tests..."
	$(BATCH) $(LOAD_PATH) \
		$(LOAD_LITERATE) \
		$(LOAD_TRACE) \
		-l tests/test-otel-trace.el \
		-f ert-run-tests-batch-and-exit

# Python package tests
.PHONY: test-python
test-python:
	@echo "Running Python package tests..."
	cd python && uv run pytest -v

# Dead-code scan via vulture (lens #6 of AI codebase mastery research).
# Confidence 80 = high-signal only; lower thresholds get noisy because the
# codebase uses heavy dynamic dispatch (Claude Code hook handlers, typing.Protocol
# classes registered at runtime) that vulture can't see statically.
# Not part of `make check` by default — run periodically (quarterly) or before
# major refactors.
.PHONY: vulture
vulture:
	@echo "Running vulture (dead-code scan, 80% confidence)..."
	@if command -v uvx >/dev/null 2>&1; then \
		uvx vulture python/claude_agent/ --min-confidence 80 || \
		echo "(see findings above — may include false positives from dynamic dispatch)"; \
	else \
		echo "uvx not found; install uv (https://docs.astral.sh/uv/) or run:"; \
		echo "  pip install vulture && vulture python/claude_agent/ --min-confidence 80"; \
		exit 1; \
	fi

# Release checks - runs lint + unit tests + python tests
.PHONY: check
check: lint test-unit test-python
	@echo ""
	@echo "Pre-release checks completed:"
	@echo "  - Static analysis: PASSED"
	@echo "  - Unit tests: PASSED"
	@echo "  - Python tests: PASSED"

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
	fswatch -o claude-agent.org code-agent-org.org | while read; do \
		echo "Files changed, reloading..."; \
		$(MAKE) test-unit; \
	done

# Local-only E2E tests (requires Phoenix + OTel bridge + cmux)
# Excluded from CI — run on dev machines only
.PHONY: test-e2e-local
test-e2e-local:
	@echo "Running local E2E tests (requires Phoenix + OTel bridge)..."
	$(BATCH) $(LOAD_PATH) \
		$(LOAD_ALL) \
		--eval "(literate-elisp-load \"$(PWD)/code-agent-org-workspace-bridge.org\")" \
		--eval "(literate-elisp-load \"$(PWD)/code-agent-org-terminal-base.org\")" \
		--eval "(literate-elisp-load \"$(PWD)/code-agent-org-cmux.org\")" \
		-l tests/test-e2e-local-trace.el \
		-l tests/test-acp-integration.el \
		--eval "(ert-run-tests-batch-and-exit '(tag :local-e2e))"

# ACP backend E2E tests (requires opencode CLI)
.PHONY: test-acp-local
test-acp-local:
	@echo "Running ACP backend E2E tests (requires opencode CLI)..."
	$(BATCH) $(LOAD_PATH) \
		$(LOAD_ALL) \
		-l tests/test-acp-integration.el \
		--eval "(ert-run-tests-batch-and-exit '(tag :acp))"

# ACP multi-agent E2E (opencode, gemini, codex — each auto-skipped if unavailable)
.PHONY: test-acp-multi-local
test-acp-multi-local:
	@echo "Running multi-agent ACP E2E tests (skips agents not reachable)..."
	$(BATCH) $(LOAD_PATH) \
		$(LOAD_ALL) \
		-l tests/test-acp-integration-multi.el \
		--eval "(ert-run-tests-batch-and-exit '(tag :acp))"

# Trace health check (requires Phoenix at localhost:6006)
.PHONY: test-trace-health
test-trace-health:
	@echo "Running Phoenix trace health check..."
	python3 tests/e2e/trace_health.py

# Workspace Bridge E2E tests (requires running Emacs MCP server)
EMACS_MCP_PORT ?= 9999
.PHONY: test-workspace-bridge
test-workspace-bridge:
	@echo "Running Workspace Bridge E2E tests (MCP port $(EMACS_MCP_PORT))..."
	bash tests/test-workspace-bridge-e2e.sh $(EMACS_MCP_PORT)

# OTel server targets
.PHONY: otel-server
otel-server:
	@echo "Starting OTel bridge server on port 7331..."
	cd python && uv run python -m claude_agent.otel_bridge

.PHONY: phoenix-start
phoenix-start:
	@echo "Starting Arize Phoenix..."
	cd python && uv run --extra phoenix python -m phoenix.server.main serve &
	@echo "Phoenix UI at http://localhost:6006"

.PHONY: phoenix-stop
phoenix-stop:
	@echo "Stopping Arize Phoenix..."
	@pkill -f "phoenix.server.main serve" 2>/dev/null || echo "Phoenix not running"

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

# Literate programming — tangle Python sources
PYTHON_LP_ORG := claude-agent-python.org

.PHONY: tangle-python
tangle-python:
	@if [ ! -f "$(PYTHON_LP_ORG)" ]; then \
	  echo "make tangle-python: $(PYTHON_LP_ORG) not found" >&2; exit 2; \
	fi
	$(BATCH) \
	  --eval "(require (quote org))" \
	  --eval "(setq org-confirm-babel-evaluate nil)" \
	  --eval "(org-babel-tangle-file \"$(PWD)/$(PYTHON_LP_ORG)\")"
	@ruff format --quiet python/ 2>/dev/null || true

.PHONY: check-python-structure
check-python-structure:
	@python3 scripts/check_org_structure.py $(PYTHON_LP_ORG)

.PHONY: build-python-index
build-python-index:
	@python3 scripts/build_index.py $(PYTHON_LP_ORG)
