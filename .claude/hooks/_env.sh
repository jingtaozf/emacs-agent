# Sourced by claude-agent's hooks before they run literate-agent's actual hook scripts.
# Override the literate-agent defaults for this single-repo Python LP layout.

# .org files at repo root, not under lp/
export LITERATE_AGENT_LP_ROOT=""

# Tangle target inheriting nothing (whole repo)
export LITERATE_AGENT_TANGLED_ROOTS=""

# Block edits to .py files only (default)
export LITERATE_AGENT_TANGLED_OUTPUT_EXTS=".py"

# claude-agent uses 'make tangle-python', not 'make tangle'
export LITERATE_AGENT_TANGLE_MAKE_TARGET="tangle-python"

# claude-agent's `make tangle-python` takes no FILE arg — it always
# tangles claude-agent-python.org. Override the default suggestion.
export LITERATE_AGENT_TANGLE_RETANGLE_CMD="make tangle-python"

# Whitelist exemptions (claude-agent has no alembic, but keep default)
export LITERATE_AGENT_TANGLED_WHITELIST_FRAGMENTS="/alembic/versions/"
