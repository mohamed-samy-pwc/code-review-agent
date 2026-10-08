# Spec: Universal Project Validation Script

## Problem Statement

Automated code review agents waste compute — and produce misleading feedback — when
they run on code that does not build, has no tests, fails its test suite, or does not
meet a minimum coverage threshold. There is no existing, language-agnostic tool that
can be dropped into any project and act as a hard gate before a code review agent
runs. Teams either skip pre-review validation entirely, write bespoke per-project CI
scripts, or rely on CI pipelines that are too slow or too coupled to a specific
platform to be useful as an agent pipeline step.

## Solution

A self-contained, cross-platform validation script (`validate.sh` / `validate.ps1` /
`validate.bat`) that runs as the first step in the code review agent pipeline,
immediately after the implementation phase. The script:

- Auto-detects every language present in the project (root and immediate
  subdirectories) using file-presence signals alone.
- Runs four quality gates in order for every detected project: Build, Unit Tests,
  Lint, and Coverage Threshold.
- Collects coverage data during the test gate and parses it in the coverage gate —
  the test suite is never run twice.
- Writes a machine-readable `validation-report.json` with a pinned, versioned schema
  for the downstream code review agent to consume.
- Writes full tool output for any failing gate to a sidecar log file so failures are
  debuggable without re-running the script.
- Exits non-zero on any gate failure, stopping the pipeline before code review
  proceeds (hard gate, per ADR-0001).
- Requires zero LLM tokens, zero network access, and zero runtime package installs.

## User Stories

1. As a code review agent pipeline, I want to know whether the project builds
   successfully before starting review, so that I do not annotate style issues on
   code that does not compile.

2. As a code review agent pipeline, I want to know whether unit tests pass before
   starting review, so that I do not waste review compute on a broken implementation.

3. As a code review agent pipeline, I want to read a machine-readable report of all
   gate results in a single JSON file, so that I can incorporate pass/fail context
   into my review output without screen-scraping terminal output.

4. As a code review agent pipeline, I want the validation script to exit non-zero
   when any gate fails, so that the pipeline can halt without any additional
   orchestration logic.

5. As a code review agent pipeline, I want the JSON report to carry a validator
   version field, so that I can detect when the script has been regenerated with an
   incompatible schema version and refuse to parse a stale report.

6. As a developer debugging a gate failure, I want the full output of the failed tool
   written to a sidecar log file, so that I can inspect the exact error without
   re-running the script.

7. As a developer working on a monorepo, I want the script to detect and gate every
   sub-project independently, so that a failure in the frontend does not mask a
   passing backend and vice versa.

8. As a developer on macOS, I want to run the validation script with a single
   `./validate.sh` invocation, so that I do not need to configure anything before
   the code review pipeline can use it.

9. As a developer on Windows, I want to run the validation script with a single
   `.\validate.ps1` invocation, so that I do not need WSL or Git Bash installed.

10. As a developer on Windows who prefers cmd.exe, I want to double-click
    `validate.bat` and have the PowerShell script run transparently, so that I do not
    need to open a PowerShell window manually.

11. As a project maintainer, I want to configure a per-language coverage threshold
    in `.validation.conf`, so that a mature Python backend can be held to 85% while
    a new TypeScript frontend is held to 60% without either gate blocking the other.

12. As a project maintainer, I want the config file to be plain INI format, so that
    I can edit it without a JSON parser or schema tool.

13. As a CI engineer, I want the script to exit with code 0 when all gates pass or
    are skipped, code 1 when any gate fails, and code 2 when the script itself errors,
    so that I can branch pipeline logic on the specific failure mode.

14. As a CI engineer, I want the script to print a structured summary table to the
    terminal at the end of each run, so that a human reading the CI log can see at a
    glance which project and gate failed.

15. As a CI engineer, I want the terminal output to respect the `NO_COLOR`
    environment variable, so that ANSI escape codes do not pollute CI log files.

16. As a CI engineer, I want to run the script in `--dry-run` mode and see every
    command that would be executed without actually running them, so that I can
    verify detection logic before committing to a long build.

17. As a developer with a verbose test runner, I want to pass `--verbose` so that
    the full tool output is printed to the terminal in addition to the summary, so
    that I can debug failures without opening sidecar log files.

18. As a developer on a project with no build step (e.g. a pure Python library), I
    want the build gate to be marked SKIPPED rather than FAIL when no build command
    applies, so that the absence of a build step is not treated as a failure.

19. As a developer on a project with no linter installed, I want the lint gate to be
    marked SKIPPED with a clear reason, so that I am informed without being blocked.

20. As a developer on a project with no test files at all, I want the test gate to
    be marked FAIL with the reason "No test files detected", so that the absence of
    tests is treated as a hard blocker for code review.

21. As a developer on a Go project, I want the script to use `go test -short ./...`
    to scope execution to unit tests, so that slow integration tests do not inflate
    the gate runtime.

22. As a developer on a Rust project, I want the script to use `cargo test --lib`
    to run only library unit tests, so that integration tests in `tests/` are
    excluded from the gate.

23. As a developer on a Python project, I want the script to attempt `-m unit` marker
    scoping and fall back to the full suite if no tests are marked, so that projects
    without pytest markers are not incorrectly gated.

24. As a developer on a JS/TS project, I want coverage collected by Jest or Vitest
    during the test gate and parsed by the coverage gate without a second test run,
    so that the total gate runtime is not doubled.

25. As a developer on a .NET project, I want the script to run `dotnet restore`
    before `dotnet build`, so that fresh checkouts (as in an agent pipeline) succeed
    without pre-warmed package caches.

26. As a developer on a JS/TS project, I want the script to use
    `./node_modules/.bin/eslint` instead of `npx eslint`, so that no network request
    is made even if the local cache is cold.

27. As a developer on a JS/TS project without an ESLint config file, I want the lint
    gate to be marked SKIPPED rather than FAIL, so that the absence of a linter
    config is not misreported as a lint failure.

28. As a developer on a Rust project without `cargo-llvm-cov` or `cargo-tarpaulin`
    installed, I want the coverage gate to be marked SKIPPED with a note naming which
    tool to install, so that I know exactly how to unblock it.

29. As a downstream code review agent, I want the `validation-report.json` to include
    line coverage percentage, branch coverage percentage (if available), and the
    threshold that was applied, so that I can include accurate coverage context in my
    review comments.

30. As a downstream code review agent, I want sidecar log paths referenced in the
    JSON report rather than raw log content embedded in JSON strings, so that the
    report remains small and parseable even when tool output is thousands of lines.

31. As a project maintainer maintaining the script over time, I want `VALIDATOR_VERSION`
    embedded in the script and echoed in the report, so that I can correlate a report
    with the exact script version that produced it.

32. As a developer in a monorepo with a Python backend and a TypeScript frontend, I
    want each sub-project gated independently and both reported in the same
    `validation-report.json`, so that the downstream agent sees the full picture in
    one file read.

## Implementation Decisions

### Script deliverables

Three files are produced: `validate.sh` (POSIX sh, macOS and Linux), `validate.ps1`
(PowerShell 5.1+, Windows / macOS / Linux), and `validate.bat` (thin cmd.exe shim
that delegates to `validate.ps1`). A `.validation.conf.example` is also produced as
a fully commented reference config.

### Project detection strategy

The script scans the invocation directory and every immediate subdirectory (depth = 1
only; no symlink following). Each directory that contains one or more language signal
files is treated as an independent project. Root-level and subdirectory-level signals
are never merged — they gate independently. If no signals are found anywhere, the
script exits with code 2.

Thirteen languages are detected via file-presence signals (no file content reads):
JS/TS (`package.json`), Python (`pyproject.toml` / `setup.py` / `setup.cfg` /
`requirements.txt`), Java (`pom.xml` / `build.gradle` without `.kt` files), Kotlin
(`build.gradle.kts` or `build.gradle` with `.kt` files), Go (`go.mod`), Rust
(`Cargo.toml`), .NET (`*.csproj` / `*.sln` / `global.json`), Ruby (`Gemfile`), PHP
(`composer.json`), Swift (`Package.swift` / `*.xcodeproj`), C/C++ (`CMakeLists.txt`
or `Makefile` with `.c`/`.cpp` files), Elixir (`mix.exs`), Scala (`build.sbt`).

JavaScript and TypeScript are collapsed into a single `JS/TS` language slug. The
gate commands are identical; the distinction adds no gate-command payoff.

### Gate execution model

Gates run in order: Build → Test → Lint → Coverage. A gate failure does not abort
the remaining gates for that project — all four gates always run and are always
reported. After all projects are processed, the script exits non-zero if any gate
failed (ADR-0001). There is no `--fail-fast` flag exposed to callers.

### Coverage collection model

Coverage data is collected during Gate 2 (test), not Gate 4 (coverage). Gate 4 only
parses the already-captured output and applies the threshold. The test suite is never
run twice. This halves the execution time of the full gate set.

### Coverage metric

Line coverage is the gating metric. Branch and function coverage are recorded in the
JSON report if the tool emits them, but no threshold is applied to them. Line coverage
is the only metric universally available across all 13 detected languages.

### Per-language coverage thresholds

The config key `COVERAGE_THRESHOLD_<LANG>=<n>` (where `<LANG>` is the uppercase
language slug, e.g. `COVERAGE_THRESHOLD_PYTHON=85`) overrides the global
`COVERAGE_THRESHOLD` for that language. This allows heterogeneous maturity levels in
a monorepo without forcing a single threshold that over-gates new sub-projects or
under-gates mature ones.

### Unit test scoping

Each ecosystem's established convention for scoping to unit tests is used:
- Go: `go test -short ./...` (`-short` skips tests that call `testing.Short()`)
- Rust: `cargo test --lib` (library unit tests only; integration tests in `tests/` excluded)
- Python: `pytest -m unit` with fallback to full suite if no tests are collected (exit 5)
- JS/TS: Jest `--testPathPattern='(unit|spec)'`; Vitest runs all tests (no equivalent flag)
- .NET: `dotnet test --filter "Category=Unit|TestCategory=Unit"` with fallback to full suite
- Ruby: `rspec --tag unit` with fallback to full suite
- PHP: `phpunit --testsuite Unit` with fallback to full suite
- Java/Kotlin: `--tests "*unit*"` pattern via Maven Surefire / Gradle
- Swift: `--filter Unit` with fallback
- Elixir: `mix test --only unit` with fallback
- Scala: `sbt "testOnly *Unit*"` with fallback

### Zero tests detection

Before invoking any test runner, the script checks for the presence of test files
using language-specific glob patterns. If no test files are found, Gate 2 is marked
FAIL with reason "No test files detected — a project must have tests to be reviewable."
This is a hard failure that stops the pipeline (ADR-0001).

### .NET build

Uses `dotnet restore && dotnet build`, not `dotnet build --no-restore`. The script
operates on fresh checkouts in the agent pipeline context; `--no-restore` assumes a
warm NuGet cache that does not exist.

### ESLint invocation

Uses `./node_modules/.bin/eslint .` only. `npx eslint` is never used — it may fetch
from the npm registry if the local cache is cold, violating the zero-network-access
requirement. If the binary is not in `node_modules/.bin/`, the lint gate is SKIPPED.

Before invoking ESLint, the script checks for the presence of at least one config
file (`eslint.config.*`, `.eslintrc.*`) or an `eslintConfig` key in `package.json`.
If none is found, lint is SKIPPED with reason "no ESLint config found" — this
prevents ESLint 9+'s config-not-found error from being misreported as a lint failure.

### Rust coverage

Tries `cargo llvm-cov --lib` first, then `cargo tarpaulin --lib --out Stdout`. If
neither is installed, the coverage gate is SKIPPED with a note naming both tools and
how to install them. Neither tool is installed by the script.

### Configuration

`.validation.conf` at the invocation root. INI format only — no JSON config format.
Parsed in POSIX sh via `grep`/`cut`/`sed`; parsed in PowerShell via
`ConvertFrom-StringData`. Two CLI flags only: `--verbose` and `--dry-run`.

### JSON report schema (pinned, ADR-0002)

`validation-report.json` is always written to the invocation directory, even on
failure. The schema is pinned and versioned. Top-level fields: `validator_version`,
`timestamp` (ISO-8601 UTC), `invocation_dir`, `overall_pass`. Per-project array:
`project_dir`, `language`, and a `gates` object with four keys (`build`, `test`,
`lint`, `coverage`). Each gate carries: `status` (PASS/FAIL/SKIPPED), `duration_seconds`,
`exit_code`, `reason`, `log_file`. The coverage gate additionally carries
`line_coverage_pct`, `branch_coverage_pct`, `function_coverage_pct`, `threshold_pct`.
A `summary` object at the top level counts `total_projects`, `total_gates_run`,
`passed`, `failed`, `skipped`.

Any schema change requires a `VALIDATOR_VERSION` bump and a corresponding update to
the consuming code review agent.

### Sidecar logs

Full stdout+stderr of any failing gate tool is written to
`./validation-logs/<project-dir>-<lang>-<gate>.log` (relative to the invocation
root). `./validation-logs/` is created at script startup. The log path is referenced
in `validation-report.json` under the gate's `log_file` field. PASS and SKIPPED gates
produce no sidecar log.

### Terminal output

Live status lines are printed per gate as they start and finish. ANSI color is
applied when `$NO_COLOR` is not set and the terminal supports it (PASS=green,
FAIL=red, SKIPPED=yellow, RUNNING=cyan). A structured box-drawing summary table is
printed after all gates complete. The `--verbose` flag causes full tool output to be
printed to the terminal in addition to the summary.

### Exit codes

- `0` — all gates PASS or SKIPPED; pipeline may proceed to code review.
- `1` — one or more gates FAIL; pipeline must stop.
- `2` — script error (no projects found, unreadable config, bad invocation).

## Testing Decisions

### What makes a good test

Tests must assert on externally observable behaviour only — the content of
`validation-report.json` and the script's exit code. Tests must not assert on
terminal output format, internal function names, temporary file names, or the order
in which sidecar logs are created. Internal implementation details change; the JSON
contract and exit code are the stable surface.

### Test seam

One seam: invoke the script against a fixture project directory and assert on the
written `validation-report.json` and the process exit code. This seam covers the
full pipeline end-to-end and is the highest possible seam — it tests both scripts
(`validate.sh` and `validate.ps1`) as black boxes.

### Fixture projects

A set of minimal fixture projects, each in their own directory, covering:
- A passing JS/TS project (all four gates pass)
- A failing JS/TS project (test gate fails — broken test)
- A JS/TS project with no test files (test gate hard FAIL)
- A JS/TS project with no ESLint config (lint gate SKIPPED)
- A JS/TS project below coverage threshold (coverage gate fails)
- A passing Python project (all four gates pass)
- A monorepo fixture with a Python backend dir and a JS/TS frontend dir
- A project with no language signals (script exits with code 2)

### What to assert per test

- `overall_pass` boolean
- `projects[*].language`
- `projects[*].gates.<gate>.status` (PASS / FAIL / SKIPPED)
- `projects[*].gates.<gate>.reason` on FAIL and SKIPPED cases
- `projects[*].gates.coverage.line_coverage_pct` on PASS cases
- `projects[*].gates.coverage.threshold_pct`
- `summary.failed` count
- Process exit code (0, 1, or 2)
- Existence of sidecar log file when a gate is FAIL

### Prior art

No existing tests exist in this repository. The fixture-based integration test pattern
described above is the founding pattern for this codebase's test suite.

## Out of Scope

- **Generating the scripts**: this spec covers the prompt that drives generation and
  the contract the generated scripts must satisfy. Generating `validate.sh` and
  `validate.ps1` is a separate implementation task driven by
  `docs/universal-validation-script-prompt.md`.
- **Integration test gating**: only unit tests (scoped by ecosystem convention) are
  run. Integration, e2e, and performance tests are out of scope for this gate.
- **Security scanning**: SAST, dependency vulnerability scanning, and secret detection
  are not included. They may be added as a Gate 5 in a future version.
- **Auto-fixing lint errors**: the script reports lint failures; it never modifies
  source files.
- **Installing missing tools**: if a linter or coverage tool is not installed, the
  gate is SKIPPED. The script never installs packages.
- **Parallelising gates across projects**: gates run sequentially. Parallel execution
  across projects is a future performance optimisation.
- **Per-gate timeout configuration**: individual gate timeouts are not configurable
  in this version.
- **Windows cmd.exe native support**: `validate.bat` is a thin shim to PowerShell.
  A native cmd.exe implementation is out of scope.
- **Languages beyond the 13 detected**: any language not listed in the detection
  table is silently ignored.

## Further Notes

- The prompt that drives script generation lives at
  `docs/universal-validation-script-prompt.md`. All design decisions in this spec
  are reflected in that prompt. If the prompt is regenerated, the `VALIDATOR_VERSION`
  constant must be bumped and the consuming code review agent updated (ADR-0002).
- ADR-0001 records why soft-continue and warn-only modes were rejected.
- ADR-0002 records why the JSON schema is pinned rather than generator-chosen.
- No `CONTEXT.md` exists yet. The domain terms introduced by this feature
  (Validation Script, Quality Gate, Hard Gate, Project Detection, Validation Report,
  Sidecar Log) are candidates for a future `/domain-modeling` session.
- The `ready-for-agent` label should be applied when this spec is published to
  GitHub Issues, indicating it is fully specified and ready for an automated
  implementation agent to act on.
