# TODO — claude-do: omp features not in default pi

Delegated to workspace `Emacs-claude dev2` (workspace:30, surface:48).

## Unit 1 — Feature-diff research: oh-my-pi (omp) vs default Pi — DONE
- [x] Executor researched features present in oh-my-pi (can1357 fork) but
      absent in default Pi (`@earendil-works/pi-coding-agent`).
- [x] Grounded each claim in a source; self-reported benchmarks flagged UNVERIFIED.
- [x] Wrote structured findings to `/tmp/claude-do/omp-features.md`.
- [x] Wrote marker `/tmp/claude-do/omp-features.done.json` (status success).
- [x] VERIFIED by me: 4/4 spot-checks matched `reference/pi` source
      (7-tool set, usage.md:304 omissions, ACP-absent/RPC-present, no LSP/DAP).

### Acceptance (verified by ME, not the marker)
- Findings file exists, non-trivial, structured as a feature list.
- Spot-check ≥3 claims against `reference/pi` source / research doc — no hallucinated features.
- Each "omp-only" feature is plausibly absent in default pi (cross-check tool set).
