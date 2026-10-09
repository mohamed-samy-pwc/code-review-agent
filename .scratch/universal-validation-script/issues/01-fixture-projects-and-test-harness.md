# 01: Scaffold fixture projects and test harness

**What to build:** A set of minimal fixture project directories and a language-agnostic test runner that can invoke `validate.sh`, read the resulting `validation-report.json`, assert on specific field values and the process exit code, and report pass/fail. Nothing in the validation script itself passes yet — this ticket builds the test bed that all subsequent tickets run against.

**Blocked by:** None (can start immediately)

**Status:** ready-for-agent

## Fixture projects to create

Each fixture is a self-contained directory under `fixtures/` at the repo root. Every fixture must be runnable locally without network access.

- [ ] `fixtures/js-ts-passing/` — a minimal JS/TS project with a `package.json`, one passing Jest test, a Jest coverage config (Istanbul), and an `.eslintrc.json`. All four gates must be capable of passing once the script exists.
- [ ] `fixtures/js-ts-test-fail/` — same structure, but one test is written to always fail.
- [ ] `fixtures/js-ts-no-tests/` — a JS/TS project with no test files whatsoever.
- [ ] `fixtures/js-ts-no-eslint-config/` — a JS/TS project with tests but no ESLint config file.
- [ ] `fixtures/js-ts-low-coverage/` — a JS/TS project where the test suite runs but line coverage is intentionally below 80%.
- [ ] `fixtures/python-passing/` — a minimal Python project with a `pyproject.toml`, one passing `pytest` test, `pytest-cov` configured, and `ruff` as linter.
- [ ] `fixtures/monorepo/` — a directory containing two sub-directories: `frontend/` (JS/TS, passing) and `backend/` (Python, passing). No language signal files at the monorepo root itself.
- [ ] `fixtures/no-signals/` — an empty directory with no language signal files.

## Test harness to create

- [ ] A POSIX sh test runner script (`tests/run.sh`) that: invokes `validate.sh` against a given fixture directory; captures the exit code; reads and parses `validation-report.json` using only `grep`/`sed` (no `jq` dependency); asserts on specific field values; prints PASS or FAIL per assertion with a summary at the end.
- [ ] Helper assertion functions in the test runner: `assert_exit_code <expected> <actual>`, `assert_json_field <path> <expected> <json-file>`, `assert_file_exists <path>`.
- [ ] The test runner must be invocable as `./tests/run.sh` from the repo root and exit 0 when all assertions pass, non-zero when any fail.
- [ ] Test cases wired up for the no-signals fixture only (exit code 2, `overall_pass` absent or false). All other fixture test cases are stubs that are marked PENDING — they will be completed as gate tickets land.

## Acceptance criteria

- [ ] `./tests/run.sh` executes without error from the repo root (even though most test cases are PENDING stubs).
- [ ] Running against `fixtures/no-signals/` produces exit code 2 and the test harness correctly reports the assertion as PENDING (not FAIL — the script does not exist yet).
- [ ] Each fixture directory contains only what is documented above — no transitive dependencies that require network access to install.
- [ ] The harness readme (inline comments in `tests/run.sh`) explains how to add a new test case in three steps or fewer.
