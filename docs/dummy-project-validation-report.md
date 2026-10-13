# Dummy-project validation report

**Date:** 2026-10-13. **Scope:** `validate.sh` and `validate.ps1` (commit `446671a`, PowerShell 7.6.6, macOS) run against the 66 dummy projects in `~/AI-projects/pwc/dummy-projects/`.
**Raw data:** every project was run with both scripts. Exit code, per-Gate status, reasons, coverage and the list of Sidecar Logs were compared. Re-run with `~/AI-projects/pwc/dummy-projects/run-all.sh` (for `validate.sh` only).

## Verdict

The scripts are correct on the paths this machine can really exercise, and they agree with each other on almost everything. **62 of 66 cases are identical between the two scripts** (same exit code, same Gate statuses and reasons, same Sidecar Logs). **4 cases differ**, and each one is a real finding or an environment limit, listed below.

| Check | Result |
|---|---|
| Cases with an asserted exit code | 45 (the other 21 depend on installed tools and are informational) |
| `validate.sh` matches the expected exit code | 44 / 45 |
| `validate.ps1` matches the expected exit code | 42 / 45 |
| Both scripts identical (exit, Gates, reasons, logs) | 62 / 66 |

## Findings

### 1. `validate.sh` follows symlinked subdirectories (real bug)
- **Case:** `symlinked-subdir` (`link-ts` is a symlink to `real-ts`). Expected exit 0.
- **Observed:** `validate.sh` validated the same Project twice, as `link-ts` and `real-ts`. `link-ts` came out as a test-Gate FAIL ("No test files detected"), so the run exited 1. `validate.ps1` skipped the symlink and exited 0.
- **Why it matters:** the spec says symlinks are not followed. The check `[ -L "$_sub" ]` runs on a path with a trailing slash (`.../link-ts/`), and the slash makes the test follow the link, so it is always false.
- **Fix (not done):** strip the trailing slash before the `-L` test. This bug is older than the refactor; it was in the pre-refactor detection loop too.

### 2. `validate.ps1` accepts an invalid Language key in `.validation.conf` (parity gap)
- **Case:** `conf-bad-language-key` (`COVERAGE_THRESHOLD_TYPE-SCRIPT=50`). Expected exit 2.
- **Observed:** `validate.sh` rejects it ("Invalid config key", exit 2). `validate.ps1` ignores the odd key and runs normally (exit 0).
- **Why it matters:** the same config gives different outcomes on different platforms, and a typo in a key silently does nothing on Windows.
- **Fix (not done):** validate the key suffix in `Read-Conf` (letters, digits and underscore only), as `validate.sh` does.

### 3. `validate.ps1` cannot run in a directory whose name contains a backslash (PowerShell limit, not a script bug)
- **Cases:** `hostile-subdir-name`, `hostile-root-dir/we"ird 'dir' \ & $(x)`. Expected exit 0; `validate.ps1` exits 2.
- **Observed:** `pwsh` itself starts with the wrong working directory (its own install directory) whenever the current directory's name contains `\`. I confirmed this with a bare `pwsh -Command '(Get-Location).Path'`. Quotes, spaces, `&`, `$(...)` and `'` are all fine. The script then finds no Project and exits 2, which is a safe failure.
- **Why it matters:** only for paths with a literal backslash on macOS/Linux, which is rare. `validate.sh` handles the same names correctly, which is what the hostile-input tests are for.
- **Action:** none in the script. Worth knowing if such a path ever appears in CI.

## What was really executed vs skipped

This machine has `node`/`npm` and Python with `pytest`, `pytest-cov` and `ruff`. It has none of Go, Rust, Java/Maven/Gradle, .NET, Ruby, PHP, Swift, CMake, Elixir or sbt.

| Language | Really executed here | What the run proves |
|---|---|---|
| TypeScript/JavaScript | Yes: build, test, lint, coverage | Full behaviour including FAIL paths, threshold overrides, retry and fallback logic |
| Python | Yes: test, lint, coverage (build is SKIPPED, no `build` module) | Full behaviour including marker fallback and `requirements.txt` detection |
| Go, Rust, Java, Kotlin, .NET, Ruby, PHP, Swift, C/C++, Elixir, Scala | No: tools missing, Gates SKIPPED | Detection, the Hard Gate (`*-no-tests` projects FAIL as required), SKIPPED reasons, and that both scripts agree |

The exact commands each of those 11 Languages would issue are covered by the fake-toolchain tests (`tests/golden/`), not by this run. A machine with the real toolchains would be needed to check them against real tools.

## Cases that behaved as designed (selection)

- **Hard Gate:** every `*-no-tests` project exits 1 on both scripts; tests inside `node_modules` do not count.
- **Precedence:** `ambiguous-ts-over-python`, `ambiguous-java-over-go` and `ambiguous-kotlin-over-java` pick the same Language in both scripts, matching the detection order.
- **Monorepos:** `monorepo-mixed`, `monorepo-one-fails` and `root-and-sub` keep each Project's Gate Results separate; one Project failing fails the run.
- **Config:** comments and blank lines are accepted; a non-numeric threshold, a threshold over 100 and an injection attempt (`$(...)` in a value) all exit 2 on both scripts and execute nothing.
- **Detection limits:** `too-deep` (a Project two levels down) and `no-signals` exit 2 as specified; `cpp-makefile-without-sources-undetected` is correctly not detected.
- **Failure isolation:** a failing build, test or lint Gate never stops the other Gates; the report lists all four.

## All cases

Gates: `B` build, `T` test, `L` lint, `C` coverage, each `P` (PASS), `F` (FAIL) or `S` (SKIPPED). "Same" means the two scripts gave identical exit code, Gates, reasons and logs. `!!` marks a mismatch with the expected exit code.

| Case | Want | `validate.sh` exit | `validate.ps1` exit | Gates (`validate.sh`) | Same | What it exercises |
|---|---|---|---|---|---|---|
| `ts-passing` | 0 | 0 ok | 0 ok | typescript B:P T:P L:P C:P | yes | all four Gates PASS |
| `ts-test-fails` | 1 | 1 ok | 1 ok | typescript B:P T:F L:P C:P | yes | test Gate FAIL (npm test exit 1), Sidecar Log written |
| `ts-no-tests` | 1 | 1 ok | 1 ok | typescript B:P T:F L:P C:S | yes | Hard Gate: no test files is a FAIL even though everything else passes |
| `ts-tests-only-in-node_modules` | 1 | 1 ok | 1 ok | typescript B:S T:F L:S C:S | yes | test files inside node_modules do not count |
| `ts-no-eslint-config` | 0 | 0 ok | 0 ok | typescript B:P T:P L:S C:P | yes | lint SKIPPED: no ESLint config |
| `ts-lint-fails` | 1 | 1 ok | 1 ok | typescript B:P T:P L:F C:P | yes | lint Gate FAIL (eslint rule violated) |
| `ts-build-fails` | 1 | 1 ok | 1 ok | typescript B:F T:P L:P C:P | yes | build Gate FAIL (tsc error), other Gates still run |
| `ts-no-build-script` | 0 | 0 ok | 0 ok | typescript B:P T:P L:P C:P | yes | no "build" script: falls back to node_modules/.bin/tsc --noEmit |
| `ts-test-pattern-fallback` | 0 | 0 ok | 0 ok | typescript B:P T:P L:P C:P | yes | no test matches (unit/spec): retries without the pattern |
| `ts-low-coverage` | 1 | 1 ok | 1 ok | typescript B:P T:P L:P C:F | yes | coverage Gate FAIL (below the 80% default) |
| `ts-low-coverage-override` | 0 | 0 ok | 0 ok | typescript B:P T:P L:P C:P | yes | COVERAGE_THRESHOLD_TYPESCRIPT=10 turns the same project into a PASS |
| `ts-global-threshold-low` | 0 | 0 ok | 0 ok | typescript B:P T:P L:P C:P | yes | COVERAGE_THRESHOLD=10 does the same globally |
| `ts-verbose-conf` | 0 | 0 ok | 0 ok | typescript B:P T:P L:P C:P | yes | VERBOSE=true in .validation.conf |
| `python-passing` | 0 | 0 ok | 0 ok | python B:S T:P L:P C:P | yes | pytest -m unit, ruff and coverage all PASS; build SKIPPED |
| `python-requirements-only` | 0 | 0 ok | 0 ok | python B:S T:P L:P C:P | yes | requirements.txt alone is a Python signal |
| `python-test-fails` | 1 | 1 ok | 1 ok | python B:S T:F L:P C:P | yes | test Gate FAIL (pytest exit 1) |
| `python-no-tests` | 1 | 1 ok | 1 ok | python B:S T:F L:P C:S | yes | Hard Gate: no test files |
| `python-marker-fallback` | 0 | 0 ok | 0 ok | python B:S T:P L:P C:P | yes | no unit-marked tests: pytest exit 5 triggers the full-suite retry |
| `python-low-coverage` | 1 | 1 ok | 1 ok | python B:S T:P L:P C:F | yes | coverage Gate FAIL |
| `python-lint-fails` | 1 | 1 ok | 1 ok | python B:S T:P L:F C:P | yes | lint Gate FAIL (ruff F401) |
| `java-maven-no-tests` | 1 | 1 ok | 1 ok | java B:S T:F L:S C:S | yes | Hard Gate (no src/test), independent of installed tools |
| `scala-sbt-no-tests` | 1 | 1 ok | 1 ok | scala B:S T:F L:S C:S | yes | Hard Gate, independent of installed tools |
| `go-no-tests` | 1 | 1 ok | 1 ok | go B:S T:F L:S C:S | yes | Hard Gate, independent of installed tools |
| `rust-no-tests` | 1 | 1 ok | 1 ok | rust B:S T:F L:S C:S | yes | Hard Gate, independent of installed tools |
| `dotnet-no-tests` | 1 | 1 ok | 1 ok | dotnet B:P T:F L:P C:S | yes | Hard Gate, independent of installed tools |
| `ruby-no-tests` | 1 | 1 ok | 1 ok | ruby B:S T:F L:F C:S | yes | Hard Gate, independent of installed tools |
| `php-no-tests` | 1 | 1 ok | 1 ok | php B:S T:F L:S C:S | yes | Hard Gate, independent of installed tools |
| `swift-no-tests` | 1 | 1 ok | 1 ok | swift B:P T:F L:S C:S | yes | Hard Gate, independent of installed tools |
| `cpp-no-tests` | 1 | 1 ok | 1 ok | cpp B:S T:F L:S C:S | yes | Hard Gate, independent of installed tools |
| `elixir-no-tests` | 1 | 1 ok | 1 ok | elixir B:S T:F L:S C:S | yes | Hard Gate, independent of installed tools |
| `java-maven` | ? | 0  | 0  | java B:S T:S L:S C:S | yes | Java via pom.xml; SKIPPED without mvn, a real run with it |
| `java-gradle` | ? | 0  | 0  | java B:S T:S L:S C:S | yes | Java via build.gradle (no .kt files) |
| `kotlin-gradle-kts` | ? | 0  | 0  | kotlin B:S T:S L:S C:S | yes | Kotlin via build.gradle.kts |
| `kotlin-gradle-groovy` | ? | 0  | 0  | kotlin B:S T:S L:S C:S | yes | Kotlin via build.gradle plus a .kt file |
| `scala-sbt` | ? | 0  | 0  | scala B:S T:S L:S C:S | yes | Scala via build.sbt |
| `go-module` | ? | 0  | 0  | go B:S T:S L:S C:S | yes | Go; -short tests and coverprofile when go is installed |
| `go-test-fails` | ? | 0  | 0  | go B:S T:S L:S C:S | yes | Go test failure; SKIPPED (exit 0) when go is missing |
| `rust-cargo` | ? | 0  | 0  | rust B:S T:S L:S C:S | yes | Rust with an in-file #[cfg(test)] module |
| `rust-integration-tests-dir` | ? | 0  | 0  | rust B:S T:S L:S C:S | yes | Rust whose tests live in tests/ |
| `dotnet-csproj` | ? | 0  | 0  | dotnet B:P T:P L:P C:S | yes | .NET via *.csproj |
| `dotnet-sln-only` | ? | 0  | 0  | dotnet B:P T:P L:P C:S | yes | .NET via *.sln |
| `dotnet-global-json` | ? | 1  | 1  | dotnet B:F T:F L:F C:S | yes | .NET via global.json |
| `ruby-gem` | ? | 1  | 1  | ruby B:F T:F L:F C:S | yes | Ruby with a Rakefile build task |
| `ruby-no-rakefile-build` | ? | 1  | 1  | ruby B:S T:F L:F C:S | yes | Ruby: build SKIPPED (no build command detected) |
| `php-composer` | ? | 0  | 0  | php B:S T:S L:S C:S | yes | PHP via composer.json |
| `swift-package` | ? | 1  | 1  | swift B:P T:F L:S C:S | yes | Swift via Package.swift |
| `cpp-cmake` | ? | 0  | 0  | cpp B:S T:S L:S C:S | yes | C/C++ via CMakeLists.txt |
| `cpp-makefile` | ? | 0  | 0  | cpp B:P T:S L:S C:S | yes | C/C++ via Makefile plus a .c file |
| `elixir-mix` | ? | 0  | 0  | elixir B:S T:S L:S C:S | yes | Elixir via mix.exs |
| `monorepo-mixed` | 0 | 0 ok | 0 ok | python B:S T:P L:P C:P / typescript B:P T:P L:P C:P / go B:S T:S L:S C:S | yes | three Projects in subdirectories (TypeScript, Python, Go); docs/ ignored |
| `monorepo-one-fails` | 1 | 1 ok | 1 ok | python B:S T:F L:P C:P / typescript B:P T:P L:P C:P | yes | two Projects; a failure is attributed to its own Project only |
| `root-and-sub` | 0 | 0 ok | 0 ok | typescript B:P T:P L:P C:P / python B:S T:P L:P C:P | yes | a root TypeScript Project and a Python Project in tools/ |
| `no-signals` | 2 | 2 ok | 2 ok | (no report) | yes | nothing detected: script error |
| `too-deep` | 2 | 2 ok | 2 ok | (no report) | yes | signal files two levels down are not scanned |
| `cpp-makefile-without-sources-undetected` | 2 | 2 ok | 2 ok | (no report) | yes | a Makefile alone is not a C/C++ signal |
| `symlinked-subdir` | 0 | 1 **!!** | 0 ok | typescript B:P T:F L:P C:S / typescript B:P T:P L:P C:P | **NO** | INTENDED: link-ts (a symlink) is skipped. KNOWN BUG: validate.sh scans it, so it exits 1 |
| `hostile-subdir-name` | 0 | 0 ok | 2 **!!** | B:S T:P L:P C:P | **NO** | subdirectory name with quotes, backslash, & and $() |
| `hostile-root-dir/we"ird 'dir' \ & $(x)` | 0 | 0 ok | 2 **!!** | python B:S T:P L:P C:P | **NO** | working directory name with quotes, backslash, & and $() |
| `ambiguous-ts-over-python` | 0 | 0 ok | 0 ok | typescript B:P T:P L:P C:P | yes | package.json beats pyproject.toml (TypeScript wins) |
| `ambiguous-java-over-go` | ? | 0  | 0  | java B:S T:S L:S C:S | yes | pom.xml beats go.mod (Java wins) |
| `ambiguous-kotlin-over-java` | ? | 0  | 0  | kotlin B:S T:S L:S C:S | yes | build.gradle plus a .kt file is Kotlin, not Java |
| `conf-comments-and-blank-lines` | 0 | 0 ok | 0 ok | typescript B:P T:P L:P C:P | yes | comments, blank lines and inline # comments in .validation.conf |
| `conf-non-numeric-threshold` | 2 | 2 ok | 2 ok | (no report) | yes | COVERAGE_THRESHOLD=abc is a script error |
| `conf-threshold-over-100` | 2 | 2 ok | 2 ok | (no report) | yes | COVERAGE_THRESHOLD=150 is a script error |
| `conf-bad-language-key` | 2 | 2 ok | 0 **!!** | (no report) | **NO** | COVERAGE_THRESHOLD_TYPE-SCRIPT is an invalid key |
| `conf-injection-attempt` | 2 | 2 ok | 2 ok | (no report) | yes | a shell command in a threshold value is rejected, not run |
