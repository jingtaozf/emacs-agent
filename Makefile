# Makefile for Claude Agent SDK
# Provides convenient targets for development, testing, and release

EMACS ?= emacs
BATCH = $(EMACS) -Q --batch

# Source files
SOURCES = lp/trace/code-agent-trace.org

# Test files
# Note: actual test loading is in target recipes below, not this variable
UNIT_TESTS = tests/test-code-agent-unit.el tests/test-code-agent-backend.el
INTEGRATION_TESTS = tests/test-mcp-mode-line.el
ALL_TESTS = $(UNIT_TESTS) $(INTEGRATION_TESTS)

# Load path for tests
LITERATE_ELISP_DIR ?= $(HOME)/projects/literate-elisp
WEB_SERVER_DIR ?= $(HOME)/.emacs.d/straight/build/web-server
COMPANY_DIR ?= $(HOME)/.emacs.d/straight/build/company
WEBSOCKET_DIR ?= $(HOME)/.emacs.d/straight/build/websocket
YASNIPPET_DIR ?= $(HOME)/.emacs.d/straight/build/yasnippet
LOAD_PATH = -L . -L tests -L $(LITERATE_ELISP_DIR) -L $(WEB_SERVER_DIR) -L $(COMPANY_DIR) -L $(WEBSOCKET_DIR) -L $(YASNIPPET_DIR)

# Common literate-elisp load sequences (DRY — used by all test targets)
# Load order: trace → agent (includes backend) → mcp → org
LOAD_LITERATE = --eval "(require 'literate-elisp)"
LOAD_TRACE = --eval "(literate-elisp-load \"$(PWD)/lp/trace/code-agent-trace.org\")"
LOAD_AGENT = $(LOAD_TRACE) --eval "(literate-elisp-load \"$(PWD)/lp/chat/code-agent.org\")" \
             --eval "(literate-elisp-load \"$(PWD)/lp/backend/code-agent-multiplexer.org\")" \
             --eval "(literate-elisp-load \"$(PWD)/lp/backend/code-agent-cmux-backend.org\")" \
             --eval "(literate-elisp-load \"$(PWD)/lp/backend/code-agent-tmux-backend.org\")" \
             --eval "(literate-elisp-load \"$(PWD)/lp/backend/code-agent-orca-backend.org\")"
LOAD_MCP = $(LOAD_TRACE) --eval "(literate-elisp-load \"$(PWD)/lp/sdk/emacs-mcp-server.org\")"
LOAD_ORG = --eval "(literate-elisp-load \"$(PWD)/lp/org/code-agent-org.org\")" \
           --eval "(literate-elisp-load \"$(PWD)/lp/org/code-agent-org-header-line.org\")"
# Presets for common combinations
LOAD_AGENT_ONLY = $(LOAD_LITERATE) $(LOAD_AGENT)
LOAD_ALL = $(LOAD_LITERATE) $(LOAD_AGENT) $(LOAD_MCP) $(LOAD_ORG)

.PHONY: all
all: test-unit

.PHONY: help
help:
	@echo "Claude Agent SDK - Make Targets"
	@echo "================================"
	@echo ""
	@echo "Development:"
	@echo "  make clean            - Remove compiled files"
	@echo "  make reload           - Reload org files in running Emacs"
	@echo "  make install-hooks    - Install/update git pre-commit hook"
	@echo ""
	@echo "Testing:"
	@echo "  make test-smoke       - Fast syntax check (< 2s) — run after every edit"
	@echo "  make test             - Run all tests (unit + org-surface)"
	@echo "  make test-unit        - Run unit tests only (fast, no API, ~13s)"
	@echo "  make test-unit-parallel - Run unit tests in parallel (~4.5s)"
	@echo "  make test-agent-unit  - Run code-agent unit tests"
	@echo "  make test-mcp-mode-line - Run MCP mode-line spinner tests"
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

.PHONY: clean
clean:
	@echo "Cleaning compiled files..."
	rm -f code-agent.elc
	rm -f tests/*.elc

.PHONY: reload
reload:
	@echo "Reloading org files requires running Emacs session"
	@echo "In Emacs, run: M-x eval-expression RET"
	@echo "  (progn"
	@echo "    (literate-elisp-load \"$(PWD)/lp/trace/code-agent-trace.org\")"
	@echo "    (literate-elisp-load \"$(PWD)/lp/chat/code-agent.org\")"
	@echo "    (literate-elisp-load \"$(PWD)/lp/org/code-agent-org.org\"))"

.PHONY: install-hooks
install-hooks:
	@echo "Installing git hooks..."
	@mkdir -p .git/hooks
	@cp scripts/pre-commit .git/hooks/pre-commit
	@chmod +x .git/hooks/pre-commit
	@echo "Pre-commit hook installed successfully."
	@echo "Hook runs: lint, unit, mcp-mode-line"
	@echo "To skip temporarily: git commit --no-verify"

# Testing targets

.PHONY: test
test: test-unit test-org-unit

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
test-unit: test-agent-unit test-backend-unit test-cmux

.PHONY: test-cmux
test-cmux:
	@echo "Running cmux backend E2E tests..."
	$(BATCH) $(LOAD_PATH) \
		$(LOAD_ALL) \
		--eval "(literate-elisp-load \"$(PWD)/lp/org/code-agent-org-terminal-base.org\")" \
		--eval "(literate-elisp-load \"$(PWD)/lp/org/code-agent-org-cmux.org\")" \
		-l tests/test-cmux-e2e-agent-profiles.el \
		-l tests/test-cmux-env-injection.el \
		-l tests/test-cmux-agent-name-lookup.el \
		-l tests/test-cli-session-persistence.el \
		-f ert-run-tests-batch-and-exit

# Convenience target: run unit tests in parallel automatically
UNIT_PARALLEL_JOBS ?= 3
.PHONY: test-unit-parallel
test-unit-parallel:
	@$(MAKE) -j$(UNIT_PARALLEL_JOBS) test-unit

.PHONY: test-agent-unit
test-agent-unit:
	@echo "Running code-agent unit tests..."
	$(BATCH) $(LOAD_PATH) \
		$(LOAD_AGENT_ONLY) \
		-l tests/fixtures/test-config.el \
		-l tests/test-code-agent-unit.el \
		-l tests/test-code-agent-refactor-phase3.el \
		-f ert-run-tests-batch-and-exit

.PHONY: test-backend-unit
test-backend-unit:
	@echo "Running backend protocol unit tests..."
	$(BATCH) $(LOAD_PATH) \
		$(LOAD_AGENT_ONLY) \
		-l tests/test-code-agent-backend.el \
		-l tests/test-backend-protocol3.el \
		-l tests/test-orca-backend.el \
		-f ert-run-tests-batch-and-exit

# Tangle the Pi extensions .org → ~/.pi/agent/extensions/{emacs-mcp,doom-loop}.ts.
# Per the user's decision, the .ts is installed at $HOME (not repo-local)
# so multiple consumer repos share one extension.
PI_EXTENSION_OUT      = $(HOME)/.pi/agent/extensions/emacs-mcp.ts
PI_EXTENSION_DOOM_OUT = $(HOME)/.pi/agent/extensions/doom-loop.ts
.PHONY: tangle-pi-extensions tangle-pi-extension
tangle-pi-extensions tangle-pi-extension:
	@echo "Tangling lp/backend/code-agent-pi-extensions.org → ~/.pi/agent/extensions/{emacs-mcp,doom-loop}.ts..."
	$(BATCH) -l org \
		--eval "(let ((org-confirm-babel-evaluate nil)) (org-babel-tangle-file \"$(PWD)/lp/backend/code-agent-pi-extensions.org\"))"
	@test -f $(PI_EXTENSION_OUT) || (echo "tangle failed: $(PI_EXTENSION_OUT) not created" && exit 1)
	@test -f $(PI_EXTENSION_DOOM_OUT) || (echo "tangle failed: $(PI_EXTENSION_DOOM_OUT) not created" && exit 1)
	@echo "Tangled $$(wc -l < $(PI_EXTENSION_OUT)) lines to $(PI_EXTENSION_OUT)"
	@echo "Tangled $$(wc -l < $(PI_EXTENSION_DOOM_OUT)) lines to $(PI_EXTENSION_DOOM_OUT)"

.PHONY: untangle-pi-extensions untangle-pi-extension
untangle-pi-extensions untangle-pi-extension:
	@rm -f $(PI_EXTENSION_OUT) $(PI_EXTENSION_DOOM_OUT)
	@echo "Removed $(PI_EXTENSION_OUT) $(PI_EXTENSION_DOOM_OUT)"

.PHONY: test-org-unit
test-org-unit:
	@echo "Running code-agent-org unit tests..."
	$(BATCH) $(LOAD_PATH) -L tests/support \
		$(LOAD_ALL) \
		-l tests/support/test-helpers.el \
		-l tests/support/org-fixtures.el \
		-l tests/test-code-agent-org-workspace.el \
		-l tests/test-mcp-report-invocation.el \
		-l tests/test-structural.el \
		-l tests/test-mcp-eval-state.el \
		-l tests/test-agent-workflow.el \
		-l tests/test-codebase-hardening.el \
		-l tests/test-mcp-protocol.el \
		-l tests/test-mcp-lifecycle.el \
		-l tests/test-mcp-eval-handler.el \
		-l tests/test-mcp-http.el \
		--eval "(literate-elisp-load \"$(PWD)/lp/org/code-agent-org-terminal-base.org\")" \
		-l tests/test-ide-open-editors.el \
		-l tests/test-code-agent-input-validation.el \
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

.PHONY: test-org-mock
test-org-mock:
	@echo "Running code-agent-org mock CLI tests..."
	$(BATCH) $(LOAD_PATH) \
		$(LOAD_ALL) \
		-l tests/fixtures/test-config.el \
		-f ert-run-tests-batch-and-exit

.PHONY: test-org-integration
test-org-integration:
	@echo "Running code-agent-org integration tests (requires API key)..."
	@echo "Note: These tests use the fixture at tests/fixtures/test-session.org"
	$(BATCH) $(LOAD_PATH) \
		$(LOAD_ALL) \
		-l tests/fixtures/test-config.el \
		-f ert-run-tests-batch-and-exit

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
		-l tests/test-code-agent-unit.el \
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
	cd python && uv run --extra dev pytest -v

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
		uvx vulture python/code_agent/ --min-confidence 80 || \
		echo "(see findings above — may include false positives from dynamic dispatch)"; \
	else \
		echo "uvx not found; install uv (https://docs.astral.sh/uv/) or run:"; \
		echo "  pip install vulture && vulture python/code_agent/ --min-confidence 80"; \
		exit 1; \
	fi

# Release checks - runs lint + unit tests + org-surface tests + python tests
.PHONY: check
check: lint test-unit test-org-unit test-python
	@echo ""
	@echo "Pre-release checks completed:"
	@echo "  - Static analysis: PASSED"
	@echo "  - Unit tests: PASSED"
	@echo "  - Org-surface tests: PASSED"
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
	fswatch -o code-agent.org code-agent-org.org | while read; do \
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
		--eval "(literate-elisp-load \"$(PWD)/lp/org/code-agent-org-terminal-base.org\")" \
		--eval "(literate-elisp-load \"$(PWD)/lp/org/code-agent-org-cmux.org\")" \
		-l tests/test-e2e-local-trace.el \
		--eval "(ert-run-tests-batch-and-exit '(tag :local-e2e))"

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

# Cross-workspace routing reproducer (2026-05-21 bug).  Verifies that
# CUSTOM_ID-based routing wins over stale session_id, that legacy
# session_id routing still works, and that the strict cmux-resume
# detection aborts cleanly.
.PHONY: test-cross-workspace-routing
test-cross-workspace-routing:
	@echo "Running cross-workspace routing E2E (MCP port $(EMACS_MCP_PORT))..."
	bash tests/test-cross-workspace-routing-e2e.sh $(EMACS_MCP_PORT)

# OTel server targets
.PHONY: otel-server
otel-server:
	@echo "Starting OTel bridge server on port 7331..."
	cd python && uv run python -m code_agent.otel_bridge

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
PYTHON_LP_ORG := lp/sdk/code-agent-python.org

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

# LP scripts now live in literate-agent (shared with other LP projects).
# Override LITERATE_AGENT_HOME if the repo lives elsewhere.
LITERATE_AGENT_HOME ?= $(HOME)/projects/literate-agent

# Each LP-script target sources `.claude/hooks/_env.sh` so code-agent's
# project-specific overrides (LITERATE_AGENT_LP_ROOT="" — single-repo
# layout with .org at root, LITERATE_AGENT_TANGLE_MAKE_TARGET=tangle-python)
# reach the plugin scripts. Without this, the scripts fall back to
# literate-agent defaults (lp/ multi-submodule layout, plain `make tangle`)
# which work by accident here but break the moment _env.sh gains a new var.
LP_ENV := set -a; . .claude/hooks/_env.sh; set +a;

.PHONY: check-python-structure
check-python-structure:
	@$(LP_ENV) python3 $(LITERATE_AGENT_HOME)/scripts/check_org_structure.py $(PYTHON_LP_ORG)

.PHONY: build-python-index
build-python-index:
	@$(LP_ENV) python3 $(LITERATE_AGENT_HOME)/scripts/build_index.py \
	    --output INDEX-python.org \
	    --preamble /dev/null \
	    --filter 'python/code_agent/.*\.py$$' \
	    $(PYTHON_LP_ORG)

# build-tangle-map populates .cache/tangle-map.tsv used by the
# block-tangled-edit.sh PreToolUse hook to print section-precise
# navigation hints (the .org file is 6770 lines, so generic "edit
# code-agent-python.org" is unhelpful). The hook self-heals on
# cache miss; run manually after large reorgs.
.PHONY: build-tangle-map
build-tangle-map:
	@$(LP_ENV) python3 $(LITERATE_AGENT_HOME)/scripts/build_tangle_map.py

# audit-quarterly runs scripts/audit_lp_health.py which composites every
# LP-alignment measurement (prose-less src, CLT violations, big defuns,
# cross-module --leakage, anchor coverage, bare module refs, protocol
# specialisation ratio, factory ratio, docstring gaps, Verified-by
# coverage) into one Markdown report at tasks/audit-YYYY-Qq.md.  Run
# once a quarter per the lp-agent-long-horizon-audit-cadence rule, then
# commit the report so the next quarter's run diffs cleanly.
.PHONY: audit-quarterly
audit-quarterly:
	@python3 scripts/audit_lp_health.py
