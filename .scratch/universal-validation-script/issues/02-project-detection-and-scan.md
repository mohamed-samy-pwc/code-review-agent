# 02: `validate.sh` — project detection and scan

**What to build:** The `validate.sh` script exists and, when invoked from any directory, scans the invocation root and every immediate subdirectory (depth = 1, no symlinks) for language signal files. It prints a startup header identifying the detected projects and their language slugs, then exits 0. No quality gates run yet. `validation-report.json` is not written yet. The no-signals case exits with code 2 and a clear error message.

**Blocked by:** 01 — fixture projects and test harness

**Status:** ready-for-agent

## Acceptance criteria

- [ ] `validate.sh` exists at the repo root and is executable.
- [ ] Running against `fixtures/js-ts-passing/` detects one project: `root [JS/TS]` and exits 0.
- [ ] Running against `fixtures/monorepo/` detects two projects: `frontend/ [JS/TS]` and `backend/ [Python]` and exits 0. No project is detected at the monorepo root itself (no signal files there).
- [ ] Running against `fixtures/no-signals/` prints an error message naming the directory and exits with code 2.
- [ ] Detection does not read any file's contents — only file presence is checked. Inline comments in the script explain the signal file chosen per language and why (e.g. `go.mod` not `*.go` files).
- [ ] The `VALIDATOR_VERSION="1.0.0"` constant appears at the top of the script.
- [ ] The startup terminal header matches the format specified in the spec: box-drawing border, validator version, invocation path, detected project list.
- [ ] Symlinks in immediate subdirectories are not followed.
- [ ] All 13 language signal detection blocks are present and commented, even though only JS/TS and Python fixtures exist yet — the detection logic is complete from this ticket.
- [ ] The test harness `tests/run.sh` has active (non-stub) assertions for: correct project detection output against `fixtures/js-ts-passing/`, `fixtures/monorepo/`, and `fixtures/no-signals/`; exit code 2 for no-signals; exit code 0 for valid projects.
