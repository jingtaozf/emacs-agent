# Reproduce Before Fix

Before fixing any issue:

1. **Reproduce with harness** — write a test that triggers the exact bug
   using the E2E test infrastructure (real org buffers + mock externals)
2. **Confirm the test fails** — run it and verify it fails for the right reason
3. **Fix the code** — apply the minimal fix
4. **Confirm the test passes** — the same test now succeeds
5. **Run full suite** — ensure no regressions

Never fix a bug without a failing test first. The test is proof the bug
existed and proof it's fixed. It also prevents the same class of mistake
from recurring.
