# 04: `validate.sh` — Lint gate, Coverage gate, and final report

**What to build:** `validate.sh` gains Gate 3 (Lint) and Gate 4 (Coverage threshold check). Gate 4 parses coverage output already captured during Gate 2 — the test suite is never re-run. The `validation-report.json` is now complete: all four gates are populated per project, per-language thresholds are applied, branch and function coverage are recorded where available, and `overall_pass` reflects all four gates. The terminal summary table is printed at the end of every run. The script is now fully functional on macOS and Linux.

**Blocked by:** 03 — Build and Test gates

**Status:** ready-for-agent

## Acceptance criteria

### Lint gate

- [ ] Running against `fixtures/js-ts-passing/` checks for ESLint config presence before invoking the linter. If `eslint.config.*`, `.eslintrc.*`, or `eslintConfig` in `package.json` is found, runs `./node_modules/.bin/eslint .` (never `npx eslint`). Marks lint PASS.
- [ ] Running against `fixtures/js-ts-no-eslint-config/` marks lint SKIPPED with reason "no ESLint config found". No linter binary is invoked.
- [ ] If `./node_modules/.bin/eslint` is absent (not installed), marks lint SKIPPED with reason "linter not installed".
- [ ] Running against `fixtures/python-passing/` tries `ruff check .` first; falls back to `flake8 .` then `pylint src/`; uses the first binary found. Marks lint PASS.
- [ ] All other language linter commands from the spec are present in the script body (even if not exercised by existing fixtures), each with inline comments.

### Coverage gate

- [ ] Gate 4 does NOT invoke any test runner. It reads the captured output from Gate 2 only.
- [ ] Running against `fixtures/js-ts-passing/` parses the Istanbul/c8 "All files" line from the Jest output captured in Gate 2. Extracts the Lines % column. Compares against `COVERAGE_THRESHOLD` (default 80). Marks coverage PASS if at or above threshold.
- [ ] Running against `fixtures/js-ts-low-coverage/` marks coverage FAIL with reason `"<actual>% < <threshold>% threshold"` and writes a sidecar log.
- [ ] Running against `fixtures/python-passing/` parses the `TOTAL ... <n>%` line from the `pytest --cov` output. Marks coverage PASS.
- [ ] If coverage output cannot be parsed (regex finds no match), marks coverage SKIPPED with reason "coverage output unparseable" and records the sidecar log path.
- [ ] `line_coverage_pct`, `branch_coverage_pct` (if available), `function_coverage_pct` (if available), and `threshold_pct` are all populated in the JSON report for the coverage gate.

### Final JSON report (complete)

- [ ] All four gate objects (`build`, `test`, `lint`, `coverage`) are fully populated for every detected project — no placeholder SKIPPED values remain from ticket 03.
- [ ] The complete pinned schema from ADR-0002 is satisfied: `validator_version`, `timestamp` (ISO-8601 UTC), `invocation_dir`, `overall_pass`, `projects[]` with all gate sub-objects, and `summary` with `total_projects`, `total_gates_run`, `passed`, `failed`, `skipped`.
- [ ] `overall_pass` is `true` only when every gate across every project is PASS or SKIPPED.
- [ ] `summary.failed` equals the count of FAIL gates across all projects.

### Terminal summary table

- [ ] After all gates complete, a box-drawing summary table is printed with columns: Project, Language, Gate, Result, Detail.
- [ ] The final line reads `Overall: PASS` or `Overall: FAIL — <n> gate(s) failed across <m> project(s)`.
- [ ] The report path `./validation-report.json` is printed below the table.

### Exit code contract (complete)

- [ ] Exit 0 when all gates PASS or SKIPPED.
- [ ] Exit 1 when one or more gates FAIL.
- [ ] Exit 2 when the script itself errors (already handled in ticket 02; verify it remains correct).

### Test harness assertions (activate stubs from tickets 01–03)

- [ ] `fixtures/js-ts-passing/`: exit 0, all four gates PASS, `line_coverage_pct` ≥ 80, `overall_pass=true`.
- [ ] `fixtures/js-ts-low-coverage/`: exit 1, coverage=FAIL, `line_coverage_pct` < 80, `overall_pass=false`, sidecar log exists.
- [ ] `fixtures/js-ts-no-eslint-config/`: exit 0 (lint SKIPPED is not a failure), lint=SKIPPED, `overall_pass=true`.
- [ ] `fixtures/python-passing/`: exit 0, lint=PASS, coverage=PASS, `overall_pass=true`.
- [ ] `fixtures/monorepo/`: exit 0, two project entries, all gates PASS or SKIPPED, `summary.total_projects=2`.
- [ ] All previously active harness assertions from tickets 02 and 03 still pass.
