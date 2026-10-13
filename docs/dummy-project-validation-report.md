# Dummy-project validation report

**Date:** 2026-10-13. **Scripts:** `validate.sh` and `validate.ps1` at commit `4556c1e` (PowerShell 7.6.6, macOS arm64).
**Scope:** every one of the 101 projects in `~/AI-projects/pwc/dummy-projects/` was run with **both** scripts, against **real toolchains** (see "Toolchains used"). Exit code, per-Gate status and reason, coverage and the Sidecar Log file names were compared between the scripts and against the expected exit code in `cases.tsv`.

## Verdict

| Check | Result |
|---|---|
| Projects run | 101 |
| `validate.sh` gives the expected exit code | 100 / 100 |
| `validate.ps1` gives the expected exit code | 99 / 100 |
| Both scripts identical (exit code, every Gate status and reason, Sidecar Logs) | 99 / 101 |
| Test harness (`tests/run.sh`, fake toolchains plus fixtures plus parity) | 134 passed, 0 failed |

The 2 cases that differ are the same single limit: PowerShell 7 on macOS starts in the wrong directory when the current directory's name contains a backslash (`hostile-subdir-name`, `hostile-root-dir/…`). `validate.sh` handles those names; `validate.ps1` exits 2 (a safe failure) because `pwsh` itself cannot see the project. It is a runtime limit, not a script bug.

## Correction to the first version of this report

The first version said .NET, Ruby, Swift and C/C++ were not executed and that 62 of 66 cases agreed. That was wrong in two ways. Several of those toolchains were installed (.NET, Ruby, Swift, `make`, a JDK), and the cases marked "?" were not asserted, so projects that were broken or that the script mishandled looked fine. This version installs every toolchain, makes every dummy project a real, valid project of its kind, and asserts the exit code of every case.

## Toolchains used

Installed or already present, all real: Node/npm, Python (pytest, pytest-cov, ruff, Flask), Go 1.27, Rust 1.99 (clippy, `cargo-llvm-cov`), Java 17 with Maven 3.9 and Gradle 9.8, .NET SDK 10, Ruby 3.3 (RSpec, Minitest, SimpleCov, RuboCop), PHP 8.5 with `pcov` (PHPUnit, PHPStan via Composer), Swift 6.2 with SwiftLint, CMake and `clang-tidy`, Elixir 1.20/OTP 29 (Credo), sbt (ScalaTest, scalastyle, sbt-scoverage), `golangci-lint`. Homebrew bottles were only partly reachable, so Go, Rust, Maven, Gradle, Elixir and Erlang came from their upstream releases into `~/toolchains` (`env.sh` puts them on `PATH`).

## What running real projects found

The fake-toolchain tests only prove that the scripts issue the commands the scripts expect. Real tools showed that many of those commands were wrong. All of these are fixed, with the fake-toolchain goldens and new regression tests updated.

**Detection and layout**
- A symlinked subdirectory was scanned as a second Project (`validate.sh` only).
- A standard C# layout (a solution at the root, `src/App` and `tests/App.Tests` below) was gated three times, and the library project failed the Hard Gate for having no tests. A workspace root (`.sln`, `.slnx`, Maven modules, Gradle `include`, Cargo workspace, `go.work`) now owns its same-family subdirectories.
- `.slnx`, the default solution format of .NET 10, was not a signal, so those projects were not detected at all.

**Test discovery and runners**
- C# test projects whose files are not named `*Test(s).cs` (the xUnit template creates `UnitTest1.cs`) failed the Hard Gate. They are now recognised by `[Fact]`, `[Test]`, `[TestMethod]` attributes.
- Vitest projects always FAILed: the TypeScript recipe passed Jest-only flags.
- Ruby Minitest and Rails projects always FAILed (RSpec was assumed). Ruby `rspec --tag unit` with no tagged examples ran nothing and passed.
- sbt `testOnly *Unit*` with no match ran nothing and exited 0, giving 0% coverage and a false FAIL.
- A Gradle project FAILed on any machine that had Maven installed (`mvn` was run without a `pom.xml`), and Gradle projects without a wrapper were skipped even when `gradle` was installed.
- C/C++ projects built with a plain `Makefile` could not run tests; a `test` target is now used.

**Coverage that was never produced**
- Rust: the spec asks for `cargo-llvm-cov` then `cargo-tarpaulin`, but only `cargo test` was run, so coverage was always SKIPPED.
- Elixir: `mix test` was run without `--cover`.
- .NET, Ruby, Swift, Scala: coverage was "not implemented". It is now read from coverlet Cobertura, SimpleCov, the SwiftPM JSON and sbt-scoverage.
- JaCoCo (Java, Kotlin): the parser took the last `missed=` on a one-line XML file, which is the wrong counter, so low-coverage projects passed. It also read a report left on disk by an earlier run, so a failing test run could still show coverage PASS. A missing report reported "null%" as a FAIL instead of SKIPPED.

**False FAILs from missing optional tools or config**
- PHP: `composer install --no-dev` deleted PHPUnit and PHPStan, so tests and lint were SKIPPED. `phpunit --coverage-text` exits 1 without a coverage driver even when every test passes.
- RuboCop, Credo, ktlint, scalastyle, clippy and `.clang-tidy` that are not set up in the Project produced FAILs; they are SKIPPED now.
- SwiftLint linted SwiftPM's generated `.build/` files.

**Parity and consistency**
- `validate.ps1` accepted an invalid Language key in `.validation.conf`; `validate.sh` rejects it.
- `validate.ps1` wrote `"log_file": ""` instead of `null`.
- Skipped coverage Gates in `validate.sh` reported the global threshold instead of the Language's.

## Known limits (not hidden)

- **C/C++:** tests run, coverage is not read (SKIPPED, "not implemented").
- **Scala coverage** is statement coverage (what sbt-scoverage measures), not line coverage.
- **PHP** coverage needs `pcov` or Xdebug; without one the Gate is SKIPPED with an install hint. Here `pcov` was built locally.
- **.NET** flat projects (code and tests in one project) report no coverage, because coverlet does not measure the test assembly. Use a library plus a test project.
- **Mocha, Ava and Tap** test runners are not recognised (Jest and Vitest are).
- **Integration tests** are out of scope by design, so a Rust crate with tests only in `tests/` has 0% unit coverage and fails (`rust-integration-tests-dir`).
- **Platforms:** `validate.ps1` was only run under PowerShell 7 on macOS. Windows PowerShell 5.1, Linux and `validate.bat` were not exercised.
- Dummy projects need network access for their own dependencies (Maven Central, NuGet, npm, PyPI, RubyGems, crates.io, Hex, Packagist), because they are real projects. The scripts themselves still use no network.

## All cases

Gates: `B` build, `T` test, `L` lint, `C` coverage, each `P` (PASS), `F` (FAIL) or `S` (SKIPPED). "Same" means the two scripts gave identical exit code, Gates, reasons and logs. `!!` marks a mismatch with the expected exit code. Exit codes in the table are `validate.sh` then `validate.ps1`.

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
| `java-maven-no-tests` | 1 | 1 ok | 1 ok | java B:P T:F L:F C:S | yes | Hard Gate (no src/test), independent of installed tools |
| `scala-sbt-no-tests` | 1 | 1 ok | 1 ok | scala B:P T:F L:S C:S | yes | Hard Gate, independent of installed tools |
| `go-no-tests` | 1 | 1 ok | 1 ok | go B:P T:F L:P C:S | yes | Hard Gate, independent of installed tools |
| `rust-no-tests` | 1 | 1 ok | 1 ok | rust B:P T:F L:P C:S | yes | Hard Gate, independent of installed tools |
| `dotnet-no-tests` | 1 | 1 ok | 1 ok | dotnet B:P T:F L:P C:S | yes | Hard Gate, independent of installed tools |
| `ruby-no-tests` | 1 | 1 ok | 1 ok | ruby B:S T:F L:S C:S | yes | Hard Gate, independent of installed tools |
| `php-no-tests` | 1 | 1 ok | 1 ok | php B:P T:F L:S C:S | yes | Hard Gate, independent of installed tools |
| `swift-no-tests` | 1 | 1 ok | 1 ok | swift B:P T:F L:F C:S | yes | Hard Gate, independent of installed tools |
| `cpp-no-tests` | 1 | 1 ok | 1 ok | cpp B:P T:F L:S C:S | yes | Hard Gate, independent of installed tools |
| `elixir-no-tests` | 1 | 1 ok | 1 ok | elixir B:P T:F L:S C:S | yes | Hard Gate, independent of installed tools |
| `java-maven` | 0 | 0 ok | 0 ok | java B:P T:P L:P C:P | yes | Maven + JUnit 5 + JaCoCo + Checkstyle: all four Gates really run |
| `java-gradle` | 0 | 0 ok | 0 ok | java B:P T:P L:P C:P | yes | Gradle (no wrapper: system gradle) + JUnit 5 + JaCoCo + Checkstyle |
| `kotlin-gradle-kts` | 0 | 0 ok | 0 ok | kotlin B:P T:P L:P C:P | yes | Kotlin via build.gradle.kts + kotlin.test + JaCoCo + ktlint |
| `kotlin-gradle-groovy` | 0 | 0 ok | 0 ok | kotlin B:P T:P L:P C:P | yes | Kotlin via build.gradle (Groovy DSL) plus a .kt file, with JaCoCo and ktlint |
| `scala-sbt` | 0 | 0 ok | 0 ok | scala B:P T:P L:P C:P | yes | sbt + ScalaTest + scalastyle + sbt-scoverage (statement coverage) |
| `go-module` | 0 | 0 ok | 0 ok | go B:P T:P L:P C:P | yes | Go: -short tests, coverprofile, go vet / golangci-lint |
| `go-test-fails` | 1 | 1 ok | 1 ok | go B:P T:F L:P C:S | yes | Go test failure |
| `rust-cargo` | 0 | 0 ok | 0 ok | rust B:P T:P L:P C:P | yes | Rust with an in-file #[cfg(test)] module; coverage via cargo-llvm-cov |
| `rust-integration-tests-dir` | 1 | 1 ok | 1 ok | rust B:P T:P L:P C:F | yes | Rust whose tests live only in tests/: cargo test --lib runs none, so coverage is 0% and FAILs (integration tests are out of scope by design) |
| `dotnet-csproj` | 0 | 0 ok | 0 ok | dotnet B:P T:P L:P C:S | yes | .NET: one flat xUnit project (coverlet does not measure the test assembly, so coverage is SKIPPED) |
| `dotnet-sln-only` | 0 | 0 ok | 0 ok | dotnet B:P T:P L:P C:P | yes | .NET: classic .sln at the root, library and xUnit test project in subdirectories |
| `dotnet-global-json` | 1 | 1 ok | 1 ok | dotnet B:F T:F L:F C:S | yes | .NET: global.json alone is a signal but there is no project, so build fails |
| `ruby-gem` | 0 | 0 ok | 0 ok | ruby B:P T:P L:P C:P | yes | Ruby: RSpec + SimpleCov + RuboCop + a Rakefile build task |
| `ruby-no-rakefile-build` | 0 | 0 ok | 0 ok | ruby B:S T:P L:S C:P | yes | Ruby Minitest project without a Rakefile: build SKIPPED (no build command detected) |
| `php-composer` | 0 | 0 ok | 0 ok | php B:P T:P L:P C:P | yes | PHP: PHPUnit 11 + PHPStan via composer; coverage needs pcov (installed here) |
| `swift-package` | 0 | 0 ok | 0 ok | swift B:P T:P L:P C:P | yes | Swift Package: XCTest, SwiftLint, coverage from the SwiftPM JSON |
| `cpp-cmake` | 0 | 0 ok | 0 ok | cpp B:P T:P L:P C:S | yes | C/C++ via CMakeLists.txt: cmake build, ctest, clang-tidy; coverage not implemented |
| `cpp-makefile` | 0 | 0 ok | 0 ok | cpp B:P T:P L:P C:S | yes | C/C++ via Makefile plus a .c file, with a `test` target |
| `elixir-mix` | 0 | 0 ok | 0 ok | elixir B:P T:P L:P C:P | yes | Elixir: ExUnit with mix test --cover, Credo |
| `monorepo-mixed` | 0 | 0 ok | 0 ok | python B:S T:P L:P C:P / typescript B:P T:P L:P C:P / go B:P T:P L:P C:P | yes | three Projects in subdirectories (TypeScript, Python, Go); docs/ ignored |
| `monorepo-one-fails` | 1 | 1 ok | 1 ok | python B:S T:F L:P C:P / typescript B:P T:P L:P C:P | yes | two Projects; a failure is attributed to its own Project only |
| `root-and-sub` | 0 | 0 ok | 0 ok | typescript B:P T:P L:P C:P / python B:S T:P L:P C:P | yes | a root TypeScript Project and a Python Project in tools/ |
| `no-signals` | 2 | 2 ok | 2 ok | (no report) | yes | nothing detected: script error |
| `too-deep` | 2 | 2 ok | 2 ok | (no report) | yes | signal files two levels down are not scanned |
| `cpp-makefile-without-sources-undetected` | 2 | 2 ok | 2 ok | (no report) | yes | a Makefile alone is not a C/C++ signal |
| `symlinked-subdir` | 0 | 0 ok | 0 ok | typescript B:P T:P L:P C:P | yes | link-ts (a symlink) is skipped; only real-ts is a Project |
| `hostile-subdir-name` | 0 | 0 ok | 2 **!!** | B:S T:P L:P C:P | **NO** | subdirectory name with quotes, backslash, & and $() |
| `hostile-root-dir/we"ird 'dir' \ & $(x)` | 0 | 0 | 2 | python B:S T:P L:P C:P | **NO** |  |
| `ambiguous-ts-over-python` | 0 | 0 ok | 0 ok | typescript B:P T:P L:P C:P | yes | package.json beats pyproject.toml (TypeScript wins) |
| `ambiguous-java-over-go` | 0 | 0 ok | 0 ok | java B:P T:P L:P C:P | yes | pom.xml beats go.mod (Java wins); a real Maven project |
| `ambiguous-kotlin-over-java` | 0 | 0 ok | 0 ok | kotlin B:P T:P L:S C:P | yes | build.gradle plus a .kt file is Kotlin, not Java; Gradle project without ktlint or JaCoCo, so lint and coverage are SKIPPED |
| `conf-comments-and-blank-lines` | 0 | 0 ok | 0 ok | typescript B:P T:P L:P C:P | yes | comments, blank lines and inline # comments in .validation.conf |
| `conf-non-numeric-threshold` | 2 | 2 ok | 2 ok | (no report) | yes | COVERAGE_THRESHOLD=abc is a script error |
| `conf-threshold-over-100` | 2 | 2 ok | 2 ok | (no report) | yes | COVERAGE_THRESHOLD=150 is a script error |
| `conf-bad-language-key` | 2 | 2 ok | 2 ok | (no report) | yes | COVERAGE_THRESHOLD_TYPE-SCRIPT is an invalid key |
| `conf-injection-attempt` | 2 | 2 ok | 2 ok | (no report) | yes | a shell command in a threshold value is rejected, not run |
| `python-flask` | 0 | 0 ok | 0 ok | python B:S T:P L:P C:P | yes | Flask app tested with the test client under pytest |
| `ts-vitest` | 0 | 0 ok | 0 ok | typescript B:P T:P L:S C:P | yes | Vitest (not Jest): own flags and coverage reporter |
| `ts-vitest-test-fails` | 1 | 1 ok | 1 ok | typescript B:F T:F L:S C:S | yes | Vitest test failure |
| `ts-vitest-low-coverage` | 1 | 1 ok | 1 ok | typescript B:F T:P L:S C:F | yes | Vitest coverage below the threshold |
| `go-low-coverage` | 1 | 1 ok | 1 ok | go B:P T:P L:P C:F | yes | Go coverage below the threshold |
| `rust-test-fails` | 1 | 1 ok | 1 ok | rust B:P T:F L:P C:S | yes | Rust test failure |
| `rust-low-coverage` | 1 | 1 ok | 1 ok | rust B:P T:P L:P C:F | yes | Rust coverage below the threshold |
| `rust-lint-fails` | 1 | 1 ok | 1 ok | rust B:P T:P L:F C:P | yes | clippy -D warnings failure |
| `java-maven-test-fails` | 1 | 1 ok | 1 ok | java B:P T:F L:P C:S | yes | JUnit failure |
| `java-maven-low-coverage` | 1 | 1 ok | 1 ok | java B:P T:P L:P C:F | yes | JaCoCo coverage below the threshold |
| `java-maven-lint-fails` | 1 | 1 ok | 1 ok | java B:P T:P L:F C:P | yes | Checkstyle violation (unused import) |
| `kotlin-test-fails` | 1 | 1 ok | 1 ok | kotlin B:P T:F L:P C:P | yes | kotlin.test failure |
| `kotlin-lint-fails` | 1 | 1 ok | 1 ok | kotlin B:P T:P L:F C:P | yes | ktlint violation |
| `scala-test-fails` | 1 | 1 ok | 1 ok | scala B:P T:F L:P C:S | yes | ScalaTest failure |
| `scala-low-coverage` | 1 | 1 ok | 1 ok | scala B:P T:P L:P C:F | yes | scoverage below the threshold |
| `ruby-test-fails` | 1 | 1 ok | 1 ok | ruby B:P T:F L:P C:P | yes | RSpec failure |
| `ruby-lint-fails` | 1 | 1 ok | 1 ok | ruby B:P T:P L:F C:P | yes | RuboCop offences |
| `ruby-low-coverage` | 1 | 1 ok | 1 ok | ruby B:P T:P L:P C:F | yes | SimpleCov below the threshold |
| `ruby-minitest` | 0 | 0 ok | 0 ok | ruby B:S T:P L:S C:P | yes | Plain Minitest in test/, no RSpec |
| `php-test-fails` | 1 | 1 ok | 1 ok | php B:P T:F L:P C:P | yes | PHPUnit failure |
| `php-lint-fails` | 1 | 1 ok | 1 ok | php B:P T:P L:F C:P | yes | PHPStan error |
| `php-low-coverage` | 1 | 1 ok | 1 ok | php B:P T:P L:P C:F | yes | pcov coverage below the threshold |
| `elixir-test-fails` | 1 | 1 ok | 1 ok | elixir B:P T:F L:P C:F | yes | ExUnit failure |
| `elixir-low-coverage` | 1 | 1 ok | 1 ok | elixir B:P T:P L:P C:F | yes | mix test --cover below the threshold |
| `elixir-lint-fails` | 1 | 1 ok | 1 ok | elixir B:P T:P L:F C:F | yes | Credo issue (IO.inspect, missing moduledoc) |
| `swift-test-fails` | 1 | 1 ok | 1 ok | swift B:P T:F L:P C:S | yes | XCTest failure |
| `swift-low-coverage` | 1 | 1 ok | 1 ok | swift B:P T:P L:F C:F | yes | SwiftPM coverage below the threshold |
| `cpp-makefile-test-fails` | 1 | 1 ok | 1 ok | cpp B:P T:F L:P C:S | yes | make test fails |
| `cpp-cmake-test-fails` | 1 | 1 ok | 1 ok | cpp B:P T:F L:P C:S | yes | ctest fails |
| `dotnet-xunit` | 0 | 0 ok | 0 ok | dotnet B:P T:P L:P C:P | yes | C# solution (.slnx) with a library and an xUnit project; coverlet Cobertura coverage |
| `dotnet-nunit` | 0 | 0 ok | 0 ok | dotnet B:P T:P L:P C:P | yes | C# solution with an NUnit project |
| `dotnet-aspnet` | 0 | 0 ok | 0 ok | dotnet B:P T:P L:P C:P | yes | ASP.NET Core minimal API tested through WebApplicationFactory |
| `dotnet-xunit-test-fails` | 1 | 1 ok | 1 ok | dotnet B:P T:F L:P C:P | yes | xUnit failure |
| `dotnet-xunit-low-coverage` | 1 | 1 ok | 1 ok | dotnet B:P T:P L:P C:F | yes | Cobertura coverage below the threshold |
| `dotnet-xunit-lint-fails` | 1 | 1 ok | 1 ok | dotnet B:P T:P L:F C:P | yes | dotnet format --verify-no-changes reports formatting |
