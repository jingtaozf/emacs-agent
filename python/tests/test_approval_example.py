"""Approval / characterization test framework example (lens #8, #16).

The test in this file demonstrates how to use ``approvaltests`` to
capture a function's *current* behaviour as a versioned baseline. Future
changes that drift from baseline cause the test to fail until the new
output is explicitly approved (rename .received → .approved).

Why this framework matters:

- Lens #8 (don't break existing behaviour): when refactoring a module,
  characterization tests prove the new code is functionally equivalent
  to the old. Without them, "I'm pretty sure" is the only safety net.

- Lens #16 (framework migration / legacy modernization): test-driven
  modernization extracts business logic, generates tests that capture
  current behaviour, then lets AI rewrite the implementation. The tests
  are the safety net; AI translates with confidence because *equivalence
  is provable*.

Workflow:

1. First run produces ``<name>.received.txt`` next to this file.
   Inspect; if correct, ``mv <name>.received.txt <name>.approved.txt``.
2. Subsequent runs compare actual output to ``.approved.txt``. Any drift
   fails the test. Re-approve only when the drift is intentional.

Approvaltests stores baselines in plain-text files next to the test, so
they're git-tracked and appear in code review when behaviour changes.
"""

from __future__ import annotations

import pytest

# approvaltests is a dev dep — skip cleanly if it's not installed locally.
approvaltests = pytest.importorskip("approvaltests")
from approvaltests import verify, Options  # noqa: E402
from approvaltests.reporters import PythonNativeReporter  # noqa: E402

from claude_agent.workspace_bridge import _format_todos_as_elisp


# Default reporter is GUI-launching (BeyondCompare, Meld, etc.) — that hangs
# pytest in CI / non-interactive runs. PythonNativeReporter prints a unified
# diff to stdout and lets pytest fail with a normal mismatch — no GUI, no
# hang. .received.txt is still written for inspection. To approve:
#     mv tests/<TestClass>.<test_name>.received.txt \
#        tests/<TestClass>.<test_name>.approved.txt
_QUIET = Options().with_reporter(PythonNativeReporter())


class TestFormatTodosAsElisp:
    """Capture the current Elisp representation of a list of todos.

    If ``_format_todos_as_elisp`` ever changes its output shape, this
    test fails and forces an explicit re-approval — so a refactor can't
    silently change what gets written into org buffers.
    """

    def test_empty_list(self):
        """Baseline: empty list of todos."""
        verify(_format_todos_as_elisp([]), options=_QUIET)

    def test_single_pending_todo(self):
        """Baseline: one pending todo."""
        verify(
            _format_todos_as_elisp(
                [{"content": "Review PR", "status": "pending", "activeForm": "Reviewing PR"}]
            ),
            options=_QUIET,
        )

    def test_mixed_states(self):
        """Baseline: completed + in-progress + pending."""
        verify(
            _format_todos_as_elisp(
                [
                    {"content": "Done thing", "status": "completed",
                     "activeForm": "Doing thing"},
                    {"content": "Active thing", "status": "in_progress",
                     "activeForm": "Working on thing"},
                    {"content": "Future thing", "status": "pending",
                     "activeForm": "Will do thing"},
                ]
            ),
            options=_QUIET,
        )
