# 05: `validate.ps1` — full parity with `validate.sh`

**What to build:** `validate.ps1` (PowerShell 5.1+) and `validate.bat` (thin cmd.exe shim) are produced. They implement the complete validation pipeline — project detection, all four quality gates, sidecar log writing, and `validation-report.json` output — with identical behaviour and an identical JSON schema to `validate.sh`. The same fixture-based test harness is extended to run both scripts and assert that their JSON output is equivalent. The validation pipeline now runs on Windows, macOS, and Linux.

**Blocked by:** 04 — Lint and Coverage gates and final report

**Status:** ready-for-agent

## Acceptance criteria

### `validate.ps1` structure

- [ ] `#Requires -Version 5.1` is the first line.
- [ ] `VALIDATOR_VERSION="1.0.0"` constant appears at the top of the script.
- [ ] Binary availability is checked with `Get-Command -ErrorAction SilentlyContinue` (not `where.exe` or `which`).
- [ ] File existence is checked with `Test-Path`.
- [ ] Subprocesses are invoked capturing both stdout and stderr via `*>&1` redirection to a variable; the captured content is written to sidecar logs on failure with `Set-Content`.
- [ ] Gate timing uses `[System.Diagnostics.Stopwatch]`.
- [ ] `validation-report.json` is written using `ConvertTo-Json -Depth 10` — not manual string construction.
- [ ] Color output uses `Write-Host -ForegroundColor`. Color is suppressed when `$env:NO_COLOR` is set.

### `validate.bat`

- [ ] Contains exactly: `@echo off` and `powershell -ExecutionPolicy Bypass -File "%~dp0validate.ps1" %*`
- [ ] Passes all CLI arguments through to `validate.ps1` unmodified.

### Behavioural parity with `validate.sh`

- [ ] Running `validate.ps1` against `fixtures/js-ts-passing/` produces a `validation-report.json` whose `overall_pass`, gate statuses, `validator_version`, and `summary` counts are identical to those produced by `validate.sh` against the same fixture.
- [ ] Running `validate.ps1` against `fixtures/js-ts-test-fail/` exits with code 1, writes the same sidecar log content as `validate.sh`, and sets `overall_pass=false`.
- [ ] Running `validate.ps1` against `fixtures/no-signals/` exits with code 2.
- [ ] Running `validate.ps1` against `fixtures/monorepo/` detects two projects and produces a report with two entries, matching `validate.sh` output.
- [ ] `timestamp` fields will differ between runs; all other top-level and gate-level fields must be identical.

### Test harness extension

- [ ] `tests/run.sh` is extended with a PowerShell parity test that (on macOS/Linux where `pwsh` is available) runs `pwsh validate.ps1` against each fixture and asserts that `overall_pass` and all gate statuses match the `validate.sh` results.
- [ ] The parity test is skipped gracefully (PENDING, not FAIL) when `pwsh` is not installed in the test environment.

### INI config parsing in PowerShell

- [ ] `validate.ps1` reads `.validation.conf` using `Get-Content | Where-Object { $_ -match '^\s*\w' } | ConvertFrom-StringData` — no external parser dependency.
- [ ] Lines starting with `#` are ignored correctly.
- [ ] If `.validation.conf` is absent, all defaults apply without error.
