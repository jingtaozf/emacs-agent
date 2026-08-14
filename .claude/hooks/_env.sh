# Sourced by literate-agent's plugin hooks before they run.
# Post-2026-08-13 cleanup: the only tangle in this repo is the Pi TS
# extensions (lp/backend/code-agent-pi-extensions.org → ~/.pi/agent/
# extensions/, outside the repo), so there are no in-repo tangled
# outputs to guard.

# .org files live under lp/, searched from repo root
export LITERATE_AGENT_LP_ROOT=""

# No in-repo tangle outputs — nothing to block edits on
export LITERATE_AGENT_TANGLED_ROOTS=""
export LITERATE_AGENT_TANGLED_OUTPUT_EXTS=""

# Re-tangle command for the Pi extensions
export LITERATE_AGENT_TANGLE_MAKE_TARGET="tangle-pi-extensions"
export LITERATE_AGENT_TANGLE_RETANGLE_CMD="make tangle-pi-extensions"
