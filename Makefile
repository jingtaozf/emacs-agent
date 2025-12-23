# Makefile for Claude Agent SDK
# Provides convenient targets for development, testing, and release

EMACS ?= emacs
BATCH = $(EMACS) -Q --batch

# Source files
SOURCES = claude-agent.org claude-org.org

# Test files
UNIT_TESTS = tests/test-claude-agent-unit.el tests/test-claude-org-unit.el
INTEGRATION_TESTS = tests/test-claude-agent-integration.el tests/test-claude-org-integration.el tests/test-claude-agent-hooks.el tests/test-mcp-ide-integration.el
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
	@echo "  make test             - Run all tests (unit + integration)"
	@echo "  make test-unit        - Run unit tests only (fast, no API)"
	@echo "  make test-integration - Run integration tests (requires API key)"
	@echo "  make test-agent-unit  - Run claude-agent unit tests"
	@echo "  make test-org-unit    - Run claude-org unit tests"
	@echo "  make test-hooks       - Run hook system tests"
	@echo "  make test-mcp-ide     - Run MCP IDE diagnostics tests"
	@echo "  make test-mcp-ide-unit - Run MCP IDE unit tests only"
	@echo ""
	@echo "Coverage:"
	@echo "  make coverage         - Generate test coverage report"
	@echo ""
	@echo "Release:"
	@echo "  make package          - Create release package"
	@echo "  make check            - Run all checks before release"
	@echo ""
	@echo "Documentation:"
	@echo "  make docs             - Generate documentation"
	@echo "  make readme           - Update README from org files"

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
test-unit: test-agent-unit test-org-unit

.PHONY: test-integration
test-integration: test-agent-integration test-org-integration

.PHONY: test-agent-unit
test-agent-unit:
	@echo "Running claude-agent unit tests..."
	$(BATCH) $(LOAD_PATH) \
		--eval "(require 'literate-elisp)" \
		--eval "(literate-elisp-load \"$(PWD)/claude-agent.org\")" \
		-l tests/test-claude-agent-unit.el \
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
		-f ert-run-tests-batch-and-exit

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

.PHONY: test-hooks
test-hooks:
	@echo "Running hook system tests..."
	$(BATCH) $(LOAD_PATH) \
		--eval "(require 'literate-elisp)" \
		--eval "(literate-elisp-load \"$(PWD)/claude-agent.org\")" \
		-l tests/test-claude-agent-hooks.el \
		--eval "(ert-run-tests-batch-and-exit '(tag :hooks))"

.PHONY: test-org-hooks
test-org-hooks:
	@echo "Running org file protection hook tests..."
	$(BATCH) $(LOAD_PATH) \
		--eval "(require 'literate-elisp)" \
		--eval "(literate-elisp-load \"$(PWD)/claude-agent.org\")" \
		--eval "(literate-elisp-load \"$(PWD)/claude-org.org\")" \
		-l tests/test-claude-agent-hooks.el \
		--eval "(ert-run-tests-batch-and-exit '(tag :org))"

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

# Release checks
.PHONY: check
check: test-unit
	@echo "Running pre-release checks..."
	@echo "- Unit tests: PASSED"
	@echo "- TODO: Add linting checks"
	@echo "- TODO: Add documentation checks"

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
