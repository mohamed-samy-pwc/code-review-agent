# 03: `validate.sh` — Build gate and Test gate

**What to build:** `validate.sh` runs Gate 1 (Build) and Gate 2 (Unit Tests with coverage collection) for every detected project. On any gate failure, it writes the full tool output to a sidecar log under `./validation-logs/`. After both gates complete for all projects, it writes a `validation-report.json` containing build and test gate results (lint and coverage gate fields are null/absent at this stage). Live status lines are printed to the terminal per gate. The hard-gate exit contract is enforced: exit 1 if any gate fails, exit 0 if all pass or are skipped.

**Blocked by:** 02 — project detection and scan

**Status:** ready-for-agent

## Acceptance criteria

### Build gate

- [ ] Running against `fixtures/js-ts-passing/` runs the build command in priority order (`npm run build` → `yarn build` → `pnpm build` → `./node_modules/.bin/tsc`), marks build PASS, and records `duration_seconds` in the JSON report.
- [ ] A project with no build command available marks the gate SKIPPED with reason "toolchain not installed" — not FAIL.
- [ ] The `.NET` build command is `dotnet restore && dotnet build` (not `dotnet build --no-restore`).

### Test gate — test file detection

- [ ] Running against `fixtures/js-ts-no-tests/` detects no test files, marks the test gate FAIL with reason "No test files detected — a project must have tests to be reviewable", writes a sidecar log, and exits 1.
- [ ] The test file detection check runs before invoking any test runner — the runner is never called when no test files exist.

### Test gate — unit test execution with coverage collection

- [ ] Running against `fixtures/js-ts-passing/` runs Jest with the unit-scoped path pattern and coverage enabled. The raw Jest output (including the Istanbul coverage table) is captured to a temp file.
- [ ] Running against `fixtures/js-ts-test-fail/` marks the test gate FAIL, writes the full Jest output to `./validation-logs/root-typescript-test.log`, and exits 1.
- [ ] Coverage output is captured during Gate 2 and stored (in a temp file or variable) for Gate 4 to parse — the test suite is not re-run in Gate 4.
- [ ] Running against `fixtures/python-passing/` runs `python -m pytest -m unit --cov=. --cov-report=term-missing -q`; if exit code 5 (no tests collected), falls back to the full suite without the `-m unit` flag.

### JSON report (partial)

- [ ] `validation-report.json` is written after both gates complete for all projects, even when a gate fails.
- [ ] The report contains `validator_version`, `timestamp`, `invocation_dir`, `overall_pass`, `projects`, and `summary`.
- [ ] Each project entry has `build` and `test` gate objects with `status`, `duration_seconds`, `exit_code`, `reason`, and `log_file` fields.
- [ ] `lint` and `coverage` gate fields are present but set to `{"status": "SKIPPED", "reason": "not yet implemented"}` as placeholders — they will be replaced in ticket 04.
- [ ] `overall_pass` is `false` if build or test failed; `true` if both passed or were skipped.

### Sidecar logs

- [ ] `./validation-logs/` is created at script startup if it does not exist.
- [ ] A sidecar log is written only when a gate fails — PASS and SKIPPED gates produce no log file.
- [ ] Log file names follow the pattern `<project-dir>-<lang>-<gate>.log` (e.g. `root-typescript-test.log`, `backend-python-build.log`).
- [ ] The `log_file` field in the JSON report contains the relative path to the sidecar log, or `null` for PASS/SKIPPED.

### Terminal output

- [ ] A live status line is printed when each gate starts (RUNNING) and when it finishes (PASS / FAIL / SKIPPED) with elapsed time.
- [ ] ANSI color is applied when `$NO_COLOR` is not set. PASS=green, FAIL=red, SKIPPED=yellow, RUNNING=cyan.

### Test harness assertions (activate stubs from ticket 01)

- [ ] `fixtures/js-ts-passing/`: exit code 0, `overall_pass=true`, build=PASS, test=PASS.
- [ ] `fixtures/js-ts-test-fail/`: exit code 1, `overall_pass=false`, test=FAIL, `log_file` field set, sidecar log exists on disk.
- [ ] `fixtures/js-ts-no-tests/`: exit code 1, test=FAIL, reason contains "No test files detected".
- [ ] `fixtures/python-passing/`: exit code 0, `overall_pass=true`, build=SKIPPED, test=PASS.
- [ ] `fixtures/monorepo/`: exit code 0, two project entries, both test gates PASS.
