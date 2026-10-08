# Prompt: Universal Project Validation Script

## Purpose

Use this prompt to generate a fully self-contained, cross-platform static analysis
and validation script. It runs as the **first step in a code review agent pipeline**,
immediately after the implementation phase. It requires zero LLM tokens, zero network
calls, and zero runtime installs. It acts as a hard gate: if any quality check fails,
the pipeline stops and code review does not proceed.

---

## Grilling decisions (design tree)

| # | Decision | Settled answer |
|---|---|---|
| Q1 | Primary use context | First step in a code review agent pipeline; hard gate before review |
| Q2 | Monorepo scan strategy | Scan root + depth-1 subdirs; each dir with a signal file is an independent project |
| Q3 | JS vs TS disambiguation | Collapse to JS/TS detected by `package.json` alone; no content reads |
| Q4 | Rust coverage tool | Try `cargo llvm-cov` → `cargo tarpaulin` → SKIPPED |
| Q5 | Double test run | Collect coverage during Gate 2; Gate 4 only parses and thresholds |
| Q6 | Config file format | INI only (`.validation.conf`); no JSON option |
| Q7 | ESLint invocation | Use `./node_modules/.bin/eslint`; never `npx`; SKIPPED if absent |
| Q8 | Machine-readable output | Always write `validation-report.json` with a pinned schema |
| Q9 | Monorepo project model | Every dir with a signal file is an independent scoped project |
| Q10 | Failure behaviour | Hard stop: exit non-zero, pipeline halts, no review proceeds |
| Q11 | Failure log verbosity | Full output to sidecar `./validation-logs/<project>-<lang>-<gate>.log`; JSON holds path |
| Q12 | Coverage metric | Line coverage for gating; branch + function recorded in JSON if available |
| Q13 | Per-language thresholds | `COVERAGE_THRESHOLD_<LANG>=<n>` in config; falls back to global |
| Q14 | JSON schema | Exact schema specified in this prompt |
| Q15 | Sidecar log location | `./validation-logs/` at invocation root; `<project>-<lang>-<gate>.log` |
| Q16 | Unit test scoping | Convention-based per ecosystem (see Gate 2 spec) |
| Q17 | Zero tests detected | Hard FAIL — project must have tests to be reviewable |
| Q18 | .NET build command | `dotnet restore && dotnet build` (fresh checkout assumption) |
| Q19 | ESLint config detection | Check for config file before invoking; SKIPPED if none found |
| Q20 | Script versioning | `VALIDATOR_VERSION` constant embedded; echoed in JSON report |

---

## The Prompt

```
You are an expert software engineer with deep knowledge of build tooling, testing
frameworks, linters, and CI/CD pipelines across every major programming language and
operating system. Your task is to produce a complete, production-ready, cross-platform
project validation script.

---

### ROLE AND CONTEXT

This script is the FIRST STEP in an automated code review agent pipeline. It runs
immediately after the implementation phase, before any code review agent consumes
the output. Its job is to be a HARD GATE: if any quality check fails, the script
exits non-zero and the pipeline must stop. Code review must not proceed on broken,
untested, or unlinted code.

The script must work without modification on:
  - macOS (zsh / bash, Apple Silicon and Intel)
  - Linux  (bash / sh, any major distro)
  - Windows (PowerShell 5.1+ and PowerShell 7+)

It must require ZERO LLM tokens, ZERO network access, and ZERO package installs at
runtime. All execution is purely local, using only tools already present because the
project itself requires them to build.

Embed this version constant at the top of every generated script file:
  VALIDATOR_VERSION="1.0.0"

---

### PROJECT DETECTION

#### Scan strategy

Scan the invocation directory (working directory) AND each immediate subdirectory
(depth = 1 only). For each directory that contains one or more language signal files,
treat that directory as an INDEPENDENT PROJECT and run all four gates scoped to it.

If the same language signal appears at the root AND in a subdirectory, treat them
as separate independent projects. Do not merge them.

Do not scan deeper than depth 1. Do not follow symlinks.

#### Language signal files

| Language    | Detection signal (file presence, no content reads)          |
|-------------|-------------------------------------------------------------|
| JS/TS       | package.json                                                |
| Python      | pyproject.toml OR setup.py OR setup.cfg OR requirements.txt |
| Java        | pom.xml OR build.gradle (no *.kt files in same dir)         |
| Kotlin      | build.gradle.kts OR (build.gradle AND *.kt files present)   |
| Go          | go.mod                                                      |
| Rust        | Cargo.toml                                                  |
| .NET        | *.csproj OR *.sln OR global.json                            |
| Ruby        | Gemfile                                                     |
| PHP         | composer.json                                               |
| Swift       | Package.swift OR *.xcodeproj                                |
| C/C++       | CMakeLists.txt OR (Makefile AND *.c or *.cpp files present) |
| Elixir      | mix.exs                                                     |
| Scala       | build.sbt                                                   |

If no signals are found anywhere, exit with code 2 and message:
  "No recognisable project found in <dir> or its immediate subdirectories."

---

### GATE SPECIFICATIONS

For each detected project, run gates 1–4 in order. On any gate failure:
  - Mark the gate FAIL
  - Record the exit code
  - Write the FULL stdout+stderr of the failed tool to:
      ./validation-logs/<project-dir>-<lang>-<gate>.log
    where <project-dir> is the relative path of the project root from the
    invocation directory (use "root" if it is the invocation directory itself),
    <lang> is the language slug (e.g. "typescript", "python", "go"), and
    <gate> is one of: build, test, lint, coverage.
  - Store the sidecar log path in the JSON report (see JSON REPORT section).
  - Continue to the next gate (do not abort early within a project).
  - After all gates for all projects are complete, exit non-zero.

Create ./validation-logs/ at startup if it does not exist.

#### Gate 1 — BUILD

Run the canonical build command. Try in priority order; use the first whose binary
is found on PATH (use `command -v` in sh, `Get-Command` in PS). If no binary is
found, mark SKIPPED with reason "toolchain not installed".

- JS/TS:    `npm run build` → `yarn build` → `pnpm build` → `./node_modules/.bin/tsc`
- Python:   `python -m build` → `poetry build` → `uv build`
            (SKIPPED if none present — pure library projects often have no build step)
- Java (Maven):  `./mvnw package -DskipTests` → `mvn package -DskipTests`
- Java (Gradle): `./gradlew assemble` → `gradle assemble`
- Kotlin:   same as Java
- Go:       `go build ./...`
- Rust:     `cargo build`
- .NET:     `dotnet restore && dotnet build`
            (always restore first — script runs on fresh checkouts)
- Ruby:     `bundle exec rake build` (SKIPPED if no "build" task in Rakefile)
- PHP:      `composer install --no-dev`
- Swift:    `swift build`
- C/C++ (CMake): `cmake -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build`
- C/C++ (Make):  `make`
- Elixir:   `mix compile`
- Scala:    `sbt compile`

#### Gate 2 — UNIT TESTS (with coverage collection)

Run only UNIT TESTS using the ecosystem's established convention. ALWAYS collect
coverage data during this gate so Gate 4 does not re-run the suite.

If a project has NO test files at all, mark Gate 2 FAIL with reason:
  "No test files detected — a project must have tests to be reviewable."
Do not run the test runner in this case.

Test file detection heuristics (check before running):
  - JS/TS:  any file matching **/*.{test,spec}.{js,ts,jsx,tsx} or __tests__/**
  - Python: any file matching **/test_*.py or **/*_test.py
  - Java/Kotlin: any file under src/test/
  - Go:     any file matching **/*_test.go
  - Rust:   presence of #[cfg(test)] blocks (check with grep) or tests/ directory
  - .NET:   any file matching **/*Tests.cs or **/*Test.cs
  - Ruby:   any file matching spec/**/*_spec.rb or test/**/*_test.rb
  - PHP:    any file matching tests/**/*Test.php
  - Swift:  any file matching **/*Tests.swift
  - C/C++:  any file matching test*/** or **/*_test.{c,cpp}
  - Elixir: any file matching test/**/*_test.exs
  - Scala:  any file under src/test/

Unit test commands (convention-based scoping per ecosystem):

- JS/TS:
    `./node_modules/.bin/jest --coverage --coverageReporters=text --testPathPattern='(unit|spec)'`
    → `./node_modules/.bin/vitest run --coverage --reporter=verbose`
    (vitest does not support --testPathPattern; run all tests)
    Capture coverage output to temp file for Gate 4.

- Python:
    `python -m pytest -m unit --cov=. --cov-report=term-missing -q`
    If no tests are collected with -m unit (exit code 5), fall back to:
    `python -m pytest --cov=. --cov-report=term-missing -q`
    Capture output for Gate 4.

- Java (Maven):
    `./mvnw test -Dtest="**/unit/**/*Test*,**/*UnitTest*" surefire:test`
    → `mvn test` (same pattern)
    Jacoco data collected automatically if plugin is configured.

- Java (Gradle):
    `./gradlew test --tests "*unit*"`
    → `gradle test --tests "*unit*"`

- Kotlin: same as Java.

- Go:
    `go test -short -coverprofile=coverage.out ./...`
    (-short skips tests marked with testing.Short() — Go's convention for
    separating unit from integration tests)

- Rust:
    `cargo test --lib`
    (--lib runs only library unit tests, excluding integration tests in tests/)
    Then run coverage: try `cargo llvm-cov --lib` → `cargo tarpaulin --lib --out Stdout`
    → SKIPPED with note "install cargo-llvm-cov or cargo-tarpaulin for coverage"

- .NET:
    `dotnet test --filter "Category=Unit|TestCategory=Unit" --no-build --collect:"XPlat Code Coverage"`
    If no tests match the filter, fall back to:
    `dotnet test --no-build --collect:"XPlat Code Coverage"`

- Ruby:
    `bundle exec rspec --tag unit spec/`
    If no examples match --tag unit, fall back to:
    `bundle exec rspec spec/`
    SimpleCov must be configured in the project for coverage.

- PHP:
    `./vendor/bin/phpunit --testsuite Unit --coverage-text`
    If no Unit suite defined, fall back to:
    `./vendor/bin/phpunit --coverage-text`

- Swift:
    `swift test --filter Unit --enable-code-coverage`

- C/C++ (CTest):
    `ctest --test-dir build -L unit`
    If no tests match label "unit", fall back to:
    `ctest --test-dir build`

- Elixir:
    `mix test --only unit`
    If no tests match, fall back to:
    `mix test`

- Scala:
    `sbt "testOnly *Unit*"`
    → `sbt test`

#### Gate 3 — LINTING

Run the canonical linter. Non-zero exit = FAIL. If the linter binary is not
installed, mark SKIPPED with reason "linter not installed" — do NOT install it.

Before running ESLint, check that at least one of the following exists:
  eslint.config.js, eslint.config.mjs, eslint.config.cjs,
  .eslintrc.js, .eslintrc.cjs, .eslintrc.yaml, .eslintrc.yml, .eslintrc.json,
  or an "eslintConfig" key in package.json.
If none found, mark lint SKIPPED with reason "no ESLint config found".

Linter commands:
- JS/TS:   `./node_modules/.bin/eslint .`
           (do NOT use npx — it may download from the network)
- Python:  `ruff check .` → `flake8 .` → `pylint src/` (first binary found wins)
- Java (Maven):  `./mvnw checkstyle:check`
- Java (Gradle): `./gradlew checkstyleMain`
- Kotlin:  `./gradlew ktlintCheck` → `ktlint "**/*.kt"`
- Go:      `golangci-lint run` → `go vet ./...`
           (go vet is always available when Go is installed — never SKIPPED for Go)
- Rust:    `cargo clippy -- -D warnings`
- .NET:    `dotnet format --verify-no-changes`
- Ruby:    `bundle exec rubocop`
- PHP:     `./vendor/bin/phpstan analyse` → `./vendor/bin/psalm`
- Swift:   `swiftlint`
- C/C++:   `clang-tidy $(find . -maxdepth 4 -name '*.cpp' -o -name '*.c' | head -100) --`
- Elixir:  `mix credo`
- Scala:   `sbt scalastyle`

#### Gate 4 — COVERAGE THRESHOLD CHECK

Do NOT re-run the test suite. Parse the coverage output already captured in Gate 2.

Gate on LINE COVERAGE only. If branch or function coverage is present in the
output, record those values in the JSON report but do not gate on them.

Coverage threshold: use `COVERAGE_THRESHOLD_<LANG>` from config if set, otherwise
use `COVERAGE_THRESHOLD` (default 80). <LANG> is the uppercase language slug
(e.g. COVERAGE_THRESHOLD_PYTHON=85, COVERAGE_THRESHOLD_TYPESCRIPT=70).

Parsing rules per language:

- JS/TS (Istanbul/c8):
    Find the line matching "All files" in the coverage table.
    Extract the "Lines" column percentage.
    Regex: `All files\s*\|\s*[\d.]+\s*\|\s*[\d.]+\s*\|\s*[\d.]+\s*\|\s*([\d.]+)`

- Python (pytest-cov):
    Find the line starting with "TOTAL".
    Extract the final percentage.
    Regex: `^TOTAL\s+\d+\s+\d+\s+([\d.]+)%`

- Java / Kotlin (Jacoco XML):
    Read `target/site/jacoco/jacoco.xml` or `build/reports/jacoco/test/jacocoTestReport.xml`.
    Find the top-level <counter type="LINE"> element.
    Compute: covered / (covered + missed) * 100.

- Go:
    Find the last line of `go tool cover -func=coverage.out` output.
    Regex: `^total:\s+\(statements\)\s+([\d.]+)%`

- Rust (llvm-cov):
    Find the "TOTAL" row in the coverage table.
    Regex: `TOTAL\s+.*\s+([\d.]+)%$`
  Rust (tarpaulin):
    Regex: `([\d.]+)% coverage`

- .NET (Cobertura XML):
    Read the XML file in TestResults/**/*.xml.
    Extract `line-rate` attribute from the root <coverage> element.
    Multiply by 100.

- Ruby (SimpleCov):
    Read `.last_run.json` in the project root.
    Extract `result.line` field.

- PHP:
    Regex on coverage-text output: `Lines:\s+([\d.]+)%`

- Swift:
    Parse `xcrun llvm-cov report` output.
    Find the TOTAL line. Extract line coverage column.

- Elixir:
    Regex: `([\d.]+)%\s*\|\s*Total`

- Scala (scoverage XML):
    Read `target/scala-*/scoverage-report/scoverage.xml`.
    Extract `statement-rate` attribute (scoverage uses statement coverage ≈ line coverage).

If coverage output cannot be parsed (regex finds no match), mark Gate 4 SKIPPED
with reason "coverage output unparseable" and include the sidecar log path so the
user can inspect the raw output.

---

### JSON REPORT SCHEMA

Always write `./validation-report.json` in the invocation directory on completion,
even if gates failed. This is the machine-readable contract for the downstream
code review agent.

Exact schema (write this structure, no extra or missing fields):

{
  "validator_version": "<VALIDATOR_VERSION constant>",
  "timestamp": "<ISO-8601 UTC datetime>",
  "invocation_dir": "<absolute path>",
  "overall_pass": <boolean>,
  "projects": [
    {
      "project_dir": "<relative path from invocation dir, or 'root'>",
      "language": "<language slug>",
      "gates": {
        "build": {
          "status": "<PASS|FAIL|SKIPPED>",
          "duration_seconds": <number>,
          "exit_code": <number|null>,
          "reason": "<string, null if PASS>",
          "log_file": "<relative path to sidecar log, null if PASS or SKIPPED>"
        },
        "test": {
          "status": "<PASS|FAIL|SKIPPED>",
          "duration_seconds": <number>,
          "exit_code": <number|null>,
          "reason": "<string, null if PASS>",
          "log_file": "<relative path to sidecar log, null if PASS or SKIPPED>"
        },
        "lint": {
          "status": "<PASS|FAIL|SKIPPED>",
          "duration_seconds": <number>,
          "exit_code": <number|null>,
          "reason": "<string, null if PASS>",
          "log_file": "<relative path to sidecar log, null if PASS or SKIPPED>"
        },
        "coverage": {
          "status": "<PASS|FAIL|SKIPPED>",
          "duration_seconds": <number>,
          "line_coverage_pct": <number|null>,
          "branch_coverage_pct": <number|null>,
          "function_coverage_pct": <number|null>,
          "threshold_pct": <number>,
          "reason": "<string, null if PASS>",
          "log_file": "<relative path to sidecar log, null if PASS or SKIPPED>"
        }
      }
    }
  ],
  "summary": {
    "total_projects": <number>,
    "total_gates_run": <number>,
    "passed": <number>,
    "failed": <number>,
    "skipped": <number>
  }
}

"overall_pass" is true only if every gate across every project is PASS or SKIPPED.
It is false if any gate is FAIL.

---

### CONFIGURATION

Config file: `.validation.conf` at the invocation directory root. INI format.
If absent, all defaults apply. CLI flags always override config file values.
No JSON config format — INI only.

```ini
# .validation.conf
VALIDATOR_VERSION_CHECK=true         # fail if script version < this (future use)
COVERAGE_THRESHOLD=80                # global line coverage floor; integer 0–100
COVERAGE_THRESHOLD_PYTHON=80         # per-language override (any lang slug works)
COVERAGE_THRESHOLD_TYPESCRIPT=80
COVERAGE_THRESHOLD_GO=80
# ... repeat pattern for any language
FAIL_FAST=false                      # reserved; currently ignored (always continue)
VERBOSE=false                        # print full tool output to terminal (not just status)
```

No CLI flags for threshold, skip, or lang overrides — the script is self-contained
and determines everything from the project structure. The only supported CLI flag is:

  --verbose    print full tool output to terminal in addition to status lines
  --dry-run    print every command that would run; do not execute anything

---

### OUTPUT FORMAT

#### Terminal (human-readable, live)

Print a header block at startup:

  ╔══════════════════════════════════════════════════╗
  ║  Validator v1.0.0  —  Code Review Pipeline Gate  ║
  ╚══════════════════════════════════════════════════╝
  Scanning: /absolute/path/to/invocation/dir
  Detected 3 project(s): root [JS/TS], backend/ [Python], infra/ [Go]

Then for each project, print a section header followed by live gate lines:

  ── [root / JS/TS] ──────────────────────────────────
  build     RUNNING...
  build     PASS  (4.1s)
  test      RUNNING...
  test      FAIL  (8.3s)  →  log: validation-logs/root-typescript-test.log
  lint      RUNNING...
  lint      PASS  (1.2s)
  coverage  RUNNING...
  coverage  FAIL  →  64.2% < 80% threshold

Use ANSI color when $NO_COLOR is not set and the terminal supports it:
  PASS    → green
  FAIL    → red
  SKIPPED → yellow
  RUNNING → cyan (overwritten in-place on the same line if the terminal supports \r)

#### Final summary table

  ┌──────────────┬────────────┬───────────┬──────────┬──────────────────────────────────────────┐
  │ Project      │ Language   │ Gate      │ Result   │ Detail                                   │
  ├──────────────┼────────────┼───────────┼──────────┼──────────────────────────────────────────┤
  │ root         │ JS/TS      │ build     │ PASS     │                                          │
  │ root         │ JS/TS      │ test      │ FAIL     │ exit 1 — see root-typescript-test.log    │
  │ root         │ JS/TS      │ lint      │ PASS     │                                          │
  │ root         │ JS/TS      │ coverage  │ FAIL     │ 64.2% < 80% threshold                    │
  │ backend/     │ Python     │ build     │ SKIPPED  │ no build script detected                 │
  │ backend/     │ Python     │ test      │ PASS     │                                          │
  │ backend/     │ Python     │ lint      │ PASS     │                                          │
  │ backend/     │ Python     │ coverage  │ PASS     │ 91.4% ≥ 80%                              │
  └──────────────┴────────────┴───────────┴──────────┴──────────────────────────────────────────┘

  Overall: FAIL — 2 gate(s) failed across 1 project(s)
  Report:  ./validation-report.json

#### Exit codes

  0   all detected gates PASS or SKIPPED — pipeline may proceed to code review
  1   one or more gates FAIL — pipeline must stop; do not proceed to code review
  2   script error (unreadable config, no projects found, bad invocation, etc.)

---

### SCRIPT ARCHITECTURE

Produce THREE files:

#### `validate.sh`  (POSIX sh — macOS and Linux)

- Shebang: `#!/usr/bin/env sh`
- Compatible with bash 3.2+, zsh, dash — no bashisms
  (no `declare -a`, no `[[`, no `$'...'` unless bash version-guarded)
- Use `command -v` (not `which`) to check binary availability
- Use `mktemp` for temp files; always clean up with `trap ... EXIT`
- Capture full tool output to temp file during each gate
- On gate failure, move temp file to the appropriate sidecar log path
- Parse coverage output from the captured temp file (do not re-run)
- Write `validation-report.json` using printf (no jq dependency)
- Timing: use `date +%s` before and after each gate; compute duration

#### `validate.ps1`  (PowerShell 5.1+ — Windows, macOS, Linux)

- `#Requires -Version 5.1`
- Use `Test-Path` for file existence; `Get-Command -ErrorAction SilentlyContinue` for binaries
- Capture stdout+stderr via `*>&1` redirection to a variable
- Write sidecar logs with `Set-Content`
- Write JSON report with `ConvertTo-Json -Depth 10`
- Timing: use `[System.Diagnostics.Stopwatch]`
- Color output via `Write-Host -ForegroundColor`; respect `$env:NO_COLOR`
- Parse the same `.validation.conf` with:
    Get-Content .validation.conf | Where-Object { $_ -match '^\s*\w' } |
    ConvertFrom-StringData

#### `validate.bat`  (thin Windows shim)

- Content:
    @echo off
    powershell -ExecutionPolicy Bypass -File "%~dp0validate.ps1" %*

---

### INLINE DOCUMENTATION REQUIREMENTS

Every non-trivial block must have inline comments explaining:
  - WHAT it does
  - WHY this approach over alternatives (if non-obvious)
  - Known edge cases or limitations

Example:

  # Detect Go: go.mod is the canonical signal. Do NOT use *.go file presence —
  # vendor/ directories in non-Go projects may contain .go files.
  if [ -f "$project_dir/go.mod" ]; then
    add_project "$project_dir" "go"
  fi

---

### DELIVERABLES

Produce in order, with NO truncation — every file must be complete and runnable:

1. `validate.sh`              — complete POSIX sh script
2. `validate.ps1`             — complete PowerShell script
3. `validate.bat`             — thin Windows shim
4. `.validation.conf.example` — fully commented example config

Do not emit a Quick Start section or README. This script is consumed by an automated
pipeline, not interactively by a developer.
```

---

## Design decisions & rationale

| Decision | Rationale |
|---|---|
| Hard gate — exit non-zero stops pipeline | Code review on broken/untested code wastes compute and produces misleading review feedback |
| Always write `validation-report.json` | Downstream code review agent reads JSON; terminal output is for human debugging only |
| Pinned JSON schema | A code generator left to choose its own schema produces an unstable contract that breaks on regeneration |
| Coverage collected during Gate 2, parsed in Gate 4 | Halves CI time; no benefit to running the test suite twice |
| Line coverage as gate metric | Universally available across all 13 detected languages; branch coverage is unavailable or unreliable in several ecosystems |
| Per-language `COVERAGE_THRESHOLD_<LANG>` | Monorepos have heterogeneous maturity; one threshold over-gates new sub-projects or under-gates mature ones |
| Full output to sidecar logs | Keeps JSON report small and machine-parseable; preserves full context for debugging without unbounded JSON strings |
| `./validation-logs/<project>-<lang>-<gate>.log` naming | Flat directory, unique filenames, human-scannable; no timestamp (one run per implementation cycle) |
| Convention-based unit test scoping | Naming-pattern or directory-pattern approaches are brittle and language-inconsistent; each ecosystem has an established "short/fast/unit" idiom |
| Zero tests = hard FAIL | A project with no tests cannot be meaningfully reviewed; forcing the issue prevents silent gaps |
| `dotnet restore && dotnet build` | Script runs on fresh checkouts; `--no-restore` assumes a warm cache that does not exist in the agent context |
| ESLint config presence check before invocation | ESLint 9+ exits non-zero with a config error when no config is present; misreporting that as a lint failure is a false positive |
| No `npx` — use `./node_modules/.bin/` | `npx` may fetch from the npm registry if the package is not locally cached, violating the zero-network-access requirement |
| INI config only, no JSON | INI is natively parseable in POSIX sh with `grep`/`cut`/`sed` and in PowerShell with `ConvertFrom-StringData`; no parser dependency |
| No CLI flags for threshold/skip/lang | Script is consumed by an automated pipeline; self-contained detection is more robust than operator-supplied flags that may be wrong or missing |
| `VALIDATOR_VERSION` constant | Lets the downstream agent verify it is reading a report from a known script version; enables safe schema evolution |
| Depth-1 subdirectory scan only | Deep recursion produces false positives (e.g. vendored dependencies); depth-1 covers monorepos without noise |
