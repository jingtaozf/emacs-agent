# Makefile for emacs-agent — Emacs MCP server (+ Pi extensions tangle)
# Post 2026-08-13 cleanup: everything beyond the MCP server lives on
# the legacy-2026-08-13 branch.  New in-Emacs agents (org-ai-agent-
# pi-topics) will add their targets here as they land.

EMACS ?= emacs
BATCH = $(EMACS) -Q --batch

# Load path for tests
LITERATE_ELISP_DIR ?= $(HOME)/projects/literate-elisp
WEB_SERVER_DIR ?= $(HOME)/.emacs.d/straight/build/web-server
LOAD_PATH = -L . -L tests -L $(LITERATE_ELISP_DIR) -L $(WEB_SERVER_DIR)

# Literate-elisp load sequences
LOAD_LITERATE = --eval "(require 'literate-elisp)"
LOAD_TRACE = --eval "(literate-elisp-load \"$(PWD)/lp/trace/code-agent-trace.org\")"
LOAD_MCP = $(LOAD_TRACE) --eval "(literate-elisp-load \"$(PWD)/lp/sdk/emacs-mcp-server.org\")"
LOAD_PI_TOPIC = $(LOAD_TRACE) --eval "(literate-elisp-load \"$(PWD)/lp/org/pi-topic.org\")" \
	--eval "(literate-elisp-load \"$(PWD)/lp/org/pi-topic-chat.org\")"

.PHONY: all
all: test-unit

.PHONY: help
help:
	@echo "emacs-agent — Make Targets"
	@echo "=========================="
	@echo "  make lint               - Static analysis (undefined functions/variables)"
	@echo "  make test-unit          - All unit tests (mcp + mode-line + otel)"
	@echo "  make test-mcp-unit      - MCP server unit tests"
	@echo "  make test-mcp-mode-line - MCP mode-line spinner tests"
	@echo "  make test-otel          - OTel trace unit tests"
	@echo "  make test-pi-topic      - pi-topic org + chat layer unit tests"
	@echo "  make check              - lint + test-unit (pre-commit gate)"
	@echo "  make tangle-pi-extensions - Tangle Pi TS extensions to ~/.pi/agent/extensions/"
	@echo "  make install-hooks      - Install git pre-commit hook"
	@echo "  make reload             - Show reload snippet for a running Emacs"

.PHONY: clean
clean:
	rm -f code-agent.elc tests/*.elc

.PHONY: reload
reload:
	@echo "In a running Emacs, evaluate:"
	@echo "  (progn"
	@echo "    (literate-elisp-load \"$(PWD)/lp/trace/code-agent-trace.org\")"
	@echo "    (literate-elisp-load \"$(PWD)/lp/sdk/emacs-mcp-server.org\"))"

.PHONY: install-hooks
install-hooks:
	@mkdir -p .git/hooks
	@cp scripts/pre-commit .git/hooks/pre-commit
	@chmod +x .git/hooks/pre-commit
	@echo "Pre-commit hook installed (runs: lint, test-unit)."

# Testing

.PHONY: test
test: test-unit

.PHONY: test-unit
test-unit: test-mcp-unit test-mcp-mode-line test-otel test-pi-topic

.PHONY: test-pi-topic
test-pi-topic:
	@echo "Running pi-topic org + chat layer unit tests..."
	$(BATCH) $(LOAD_PATH) \
		$(LOAD_LITERATE) \
		$(LOAD_PI_TOPIC) \
		-l tests/test-pi-topic.el \
		-l tests/test-pi-topic-chat.el \
		--eval "(ert-run-tests-batch-and-exit '(tag :pi-topic))"

.PHONY: test-mcp-unit
test-mcp-unit:
	@echo "Running MCP server unit tests..."
	$(BATCH) $(LOAD_PATH) \
		$(LOAD_LITERATE) \
		$(LOAD_MCP) \
		-l tests/test-mcp-protocol.el \
		-l tests/test-mcp-lifecycle.el \
		-l tests/test-mcp-eval-handler.el \
		-l tests/test-mcp-eval-state.el \
		-l tests/test-mcp-report-invocation.el \
		-l tests/test-mcp-http.el \
		--eval "(ert-run-tests-batch-and-exit '(not (tag :integration)))"

.PHONY: test-mcp-mode-line
test-mcp-mode-line:
	@echo "Running MCP mode-line spinner tests..."
	$(BATCH) $(LOAD_PATH) \
		$(LOAD_LITERATE) \
		$(LOAD_MCP) \
		-l tests/test-mcp-mode-line.el \
		--eval "(ert-run-tests-batch-and-exit '(tag :mcp-mode-line))"

.PHONY: test-otel
test-otel:
	@echo "Running OTel trace unit tests..."
	$(BATCH) $(LOAD_PATH) \
		$(LOAD_LITERATE) \
		$(LOAD_TRACE) \
		-l tests/test-otel-trace.el \
		-f ert-run-tests-batch-and-exit

# Static Analysis — undefined functions/variables, code outside src
# blocks, duplicate definitions across the literate sources.
.PHONY: lint
lint:
	@echo "Running static analysis..."
	$(BATCH) $(LOAD_PATH) \
		$(LOAD_LITERATE) \
		-l tests/test-static-analysis.el \
		--eval "(ert-run-tests-batch-and-exit '(tag :static))"

.PHONY: check
check: lint test-unit
	@echo ""
	@echo "Pre-release checks completed:"
	@echo "  - Static analysis: PASSED"
	@echo "  - Unit tests: PASSED"

# Tangle the Pi extensions .org → ~/.pi/agent/extensions/{emacs-mcp,doom-loop}.ts.
# The .ts is installed at $HOME (not repo-local) so multiple consumer
# repos share one extension.
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
