"""Property-based tests using Hypothesis (lens #15).

Run: ``pytest tests/test_property_based.py``

Why property-based, not unit:
- Pure string transformations like ``_escape_elisp_string`` look simple
  but have an exponential edge-case space (Unicode, control chars,
  embedded backslashes, mixed quote types). Fixed-input unit tests
  pass while the function silently fails on the case nobody thought of.
- LLM-generated tests cluster around training-data patterns and miss
  exactly these corner cases (CodeRabbit study: AI tests achieve only
  ~20% mutation score on real-world functions).
- Hypothesis runs ~100 random inputs per test by default, including
  shrinking failures to minimal reproducer — much higher coverage of
  the input space than human-imagined samples.

Add new tests here for any pure function whose correctness depends on
input shape rather than business logic. Don't use Hypothesis for tests
that need fixtures, side effects, or mocked external services — that's
what the rest of the test suite is for.
"""

from __future__ import annotations

from hypothesis import given, strategies as st, settings, HealthCheck

from claude_agent.workspace_bridge import _escape_elisp_string

# Reasonable budget — pure-string functions don't need 100k iterations.
SETTINGS = settings(
    max_examples=200, deadline=500, suppress_health_check=[HealthCheck.too_slow]
)


class TestEscapeElispString:
    """Properties of `_escape_elisp_string` — invariants that must hold
    for any input string the bridge could see in real prompts.
    """

    @SETTINGS
    @given(st.text())
    def test_output_is_a_str(self, s: str) -> None:
        """Function must return ``str`` for any text input — never raise,
        never return None. The bridge embeds the result directly into an
        Elisp s-expression, so a non-str return crashes downstream.
        """
        result = _escape_elisp_string(s)
        assert isinstance(result, str)

    @SETTINGS
    @given(
        # Only ASCII letters, digits, and a single space — explicitly excludes
        # any character that Elisp legitimately escapes (newline → \\n,
        # tab → \\t, control chars → \\xNN, quote, backslash). The earlier
        # broader alphabet caught a *test bug*, not a function bug:
        # newline is non-quote, non-backslash but still gets escaped.
        # Lesson: when writing pass-through properties, the alphabet must
        # exclude *every* char the function transforms, not just the
        # obvious ones.
        st.text(
            alphabet=st.characters(
                min_codepoint=0x20, max_codepoint=0x7E, blacklist_characters='"\\'
            )
        )
    )
    def test_safe_ascii_passes_through_without_added_escapes(self, s: str) -> None:
        """Inputs containing only printable ASCII (no quote/backslash, no
        control chars) must come back without spurious escape sequences.
        """
        result = _escape_elisp_string(s)
        assert "\\" not in result, f"safe input got escapes: {s!r} → {result!r}"

    @SETTINGS
    @given(st.text())
    def test_no_unescaped_quote_in_output(self, s: str) -> None:
        """Result is meant to live inside Elisp double-quotes. Every ``"``
        in output must be preceded by a backslash (escaped). An unescaped
        quote would terminate the Elisp string early and cause a parse
        error in Emacs.

        Counts even quotes appearing mid-string — if input has ``"``,
        output must have ``\\"`` for each one.
        """
        result = _escape_elisp_string(s)
        # Walk the result; flag any " that isn't preceded by an escape.
        for i, ch in enumerate(result):
            if ch == '"':
                # Count preceding consecutive backslashes; need an odd count
                # for the quote to be escaped.
                bs_count = 0
                j = i - 1
                while j >= 0 and result[j] == "\\":
                    bs_count += 1
                    j -= 1
                assert bs_count % 2 == 1, (
                    f"unescaped quote at position {i} in output {result!r}"
                )

    @SETTINGS
    @given(st.text())
    def test_idempotent_on_already_escaped(self, s: str) -> None:
        """Escaping the result of escaping should not crash. We don't
        assert equality — escaping ``\\n`` once may yield ``\\\\n``, then
        escaping that yields ``\\\\\\\\n``, growing each pass. But the
        function must not raise or return None.
        """
        result1 = _escape_elisp_string(s)
        result2 = _escape_elisp_string(result1)
        assert isinstance(result2, str)
