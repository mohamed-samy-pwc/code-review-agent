#!/usr/bin/env sh
# =============================================================================
# validate.sh — Universal Project Validation Script v1.0.0
#
# Runs as the FIRST step in an automated code review agent pipeline.
# Hard gate: exits non-zero on any failure; pipeline must stop.
#
# Usage:  ./validate.sh [--verbose] [--dry-run]
#
# Exit codes:
#   0  all gates PASS or SKIPPED  → pipeline may proceed to code review
#   1  one or more gates FAIL     → pipeline must stop
#   2  script error
#
# Platform: macOS (bash 3.2+/zsh), Linux (bash/sh/dash). No bashisms.
# =============================================================================

VALIDATOR_VERSION="1.0.0"

# ---------------------------------------------------------------------------
# Flags
# ---------------------------------------------------------------------------
VERBOSE=false
DRY_RUN=false
for _a in "$@"; do
  case "$_a" in
    --verbose) VERBOSE=true ;;
    --dry-run) DRY_RUN=true ;;
    *) printf 'Unknown flag: %s\n' "$_a" >&2; exit 2 ;;
  esac
done

# ---------------------------------------------------------------------------
# Color
# ---------------------------------------------------------------------------
C_GREEN=''; C_RED=''; C_YELLOW=''; C_CYAN=''; C_RESET=''
if [ -z "${NO_COLOR:-}" ] && [ -t 1 ]; then
  C_GREEN='\033[0;32m'; C_RED='\033[0;31m'
  C_YELLOW='\033[0;33m'; C_CYAN='\033[0;36m'; C_RESET='\033[0m'
fi

# Tool output is captured and parsed (coverage, test counts), so child tools must
# not emit ANSI colour even if the caller's environment forces it.
FORCE_COLOR=0; CLICOLOR_FORCE=0; NO_COLOR=1
export FORCE_COLOR CLICOLOR_FORCE NO_COLOR

# ---------------------------------------------------------------------------
# Temp dir — always cleaned up
# ---------------------------------------------------------------------------
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------
# Config (.validation.conf INI format)
# ---------------------------------------------------------------------------
COVERAGE_THRESHOLD=80
LANG_THRESHOLDS=''   # space-separated KEY=value pairs from COVERAGE_THRESHOLD_<KEY>
# Thresholds must be integers 0-100; anything else is a script error (exit 2).
_check_threshold() {
  case "$2" in
    ''|*[!0-9]*) printf 'Invalid value for %s in .validation.conf: "%s" (expected integer 0-100)\n' "$1" "$2" >&2; exit 2 ;;
  esac
  if [ "$2" -gt 100 ]; then
    printf 'Invalid value for %s in .validation.conf: "%s" (expected integer 0-100)\n' "$1" "$2" >&2; exit 2
  fi
}
_read_conf() {
  [ -f ".validation.conf" ] || return 0
  while IFS='=' read -r _k _v; do
    case "$_k" in \#*|'') continue ;; esac
    _k=$(printf '%s' "$_k" | sed 's/[[:space:]]//g')
    _v=$(printf '%s' "$_v" | sed 's/#.*//;s/[[:space:]]*$//')
    case "$_k" in
      COVERAGE_THRESHOLD)   _check_threshold "$_k" "$_v"; COVERAGE_THRESHOLD="$_v" ;;
      VERBOSE)              [ "$_v" = "true" ] && VERBOSE=true ;;
      COVERAGE_THRESHOLD_*)
        _check_threshold "$_k" "$_v"
        case "${_k#COVERAGE_THRESHOLD_}" in
          *[!A-Za-z0-9_]*|'') printf 'Invalid config key: %s\n' "$_k" >&2; exit 2 ;;
        esac
        LANG_THRESHOLDS="$LANG_THRESHOLDS ${_k#COVERAGE_THRESHOLD_}=$_v" ;;
    esac
  done < ".validation.conf"
}
_read_conf

_get_threshold() {
  _U=$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')
  _t=''
  for _e in $LANG_THRESHOLDS; do
    case "$_e" in "$_U="*) _t="${_e#*=}" ;; esac
  done
  [ -n "$_t" ] && printf '%s' "$_t" || printf '%s' "$COVERAGE_THRESHOLD"
}

# ---------------------------------------------------------------------------
# JSON string escaping: \\ " and control characters (tab, CR; newlines become \\n)
# ---------------------------------------------------------------------------
_json_esc() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e "s/$(printf '\t')/\\\\t/g" -e "s/$(printf '\r')/\\\\r/g" | awk 'BEGIN{ORS=""} NR>1{print "\\n"} {print}'
}

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
INVOCATION_DIR="$(pwd)"
LOG_DIR="$INVOCATION_DIR/validation-logs"
REPORT_FILE="$INVOCATION_DIR/validation-report.json"

[ "$DRY_RUN" = "false" ] && mkdir -p "$LOG_DIR"

# ---------------------------------------------------------------------------
# Header
# ---------------------------------------------------------------------------
printf '%b╔══════════════════════════════════════════════════╗\n' "$C_CYAN"
printf '║  Validator v%-5s — Code Review Pipeline Gate  ║\n' "$VALIDATOR_VERSION"
printf '╚══════════════════════════════════════════════════╝%b\n' "$C_RESET"
printf 'Scanning: %s\n' "$INVOCATION_DIR"

# ---------------------------------------------------------------------------
# Language Recipes — one function per Language, called as
#   _recipe_<lang> <request> <project dir>
# Requests: detect, has_tests, build, test, lint, coverage.
# A recipe never writes files, never times itself and never prints status
# lines; it reports a Gate outcome through gate_run / gate_skip / gate_pass
# (or gate_exec/gate_exec_more + gate_finish when a Gate runs more than one
# command). Commands are argument lists run in the Project directory — never
# evaluated as shell text.
# `coverage` prints the line-coverage percentage (nothing if unparseable).
# ---------------------------------------------------------------------------
_try_recipe() { "_recipe_$1" detect "$_d" && printf '%s' "$1"; }

_recipe_typescript() {
  _req="$1"; _d="$2"
  case "$_req" in
    workspace_root) return 1 ;;
    detect) [ -f "$_d/package.json" ] ;;
    has_tests)
      find "$_d" -not -path '*/node_modules/*' \
        \( -name '*.test.js' -o -name '*.test.ts' -o -name '*.test.jsx' \
           -o -name '*.test.tsx' -o -name '*.spec.js' -o -name '*.spec.ts' \
           -o -name '*.spec.jsx' -o -name '*.spec.tsx' \) 2>/dev/null | grep -q . ;;
    build)
      if ! command -v npm >/dev/null 2>&1; then
        gate_skip "toolchain not installed (npm not found)"
      elif grep -q '"build"' "$_d/package.json" 2>/dev/null; then
        gate_run "npm run build failed (exit {exit})" "$_d" npm run build
      elif [ -f "$_d/node_modules/.bin/tsc" ]; then
        gate_run "tsc failed (exit {exit})" "$_d" ./node_modules/.bin/tsc --noEmit
      else
        gate_skip "no build script and tsc not found"
      fi ;;
    test)
      if ! command -v npm >/dev/null 2>&1; then
        gate_skip "toolchain not installed (npm not found)"
      else
        if grep -q '"vitest"' "$_d/package.json" 2>/dev/null; then
          # Vitest has none of Jest's flags; run the whole suite with its text reporter.
          gate_run "npm test failed (exit {exit})" "$_d" npm test -- --coverage --coverage.reporter=text
        else
          # Jest: run with unit pattern; if no tests match, retry without pattern
          gate_exec "$_d" npm test -- --coverage --coverageReporters=text \
            --testPathPattern='(unit|spec)' --forceExit
          if gate_output_matches 'Your test suite must contain at least one test|No tests found'; then
            gate_exec "$_d" npm test -- --coverage --coverageReporters=text \
              --forceExit
          fi
          gate_finish "npm test failed (exit {exit})"
        fi
      fi ;;
    lint)
      # Check for ESLint config before invoking — prevents false FAIL from missing config error
      _has_eslint_conf=false
      for _cf in eslint.config.js eslint.config.mjs eslint.config.cjs \
                 .eslintrc.js .eslintrc.cjs .eslintrc.yaml .eslintrc.yml .eslintrc.json; do
        [ -f "$_d/$_cf" ] && _has_eslint_conf=true && break
      done
      if [ "$_has_eslint_conf" = "false" ] && \
         grep -q '"eslintConfig"' "$_d/package.json" 2>/dev/null; then
        _has_eslint_conf=true
      fi
      if [ "$_has_eslint_conf" = "false" ]; then
        gate_skip "no ESLint config found"
      elif [ -f "$_d/node_modules/.bin/eslint" ]; then
        gate_run "eslint failed (exit {exit})" "$_d" ./node_modules/.bin/eslint .
      else
        gate_skip "linter not installed (eslint not in node_modules/.bin)"
      fi ;;
    coverage)
      # Istanbul/c8 table row: All files | stmts | branch | func | lines |
      _esc=$(printf '\033')
      _lpct=$(sed "s/${_esc}\\[[0-9;]*m//g" "$GATE_COVFILE" 2>/dev/null | grep 'All files' | \
        sed 's/|/ /g' | awk '{for(i=1;i<=NF;i++) if($i+0>0 || $i=="0") print $i}' | \
        tail -1 | sed 's/[^0-9.]//g')
      # Simpler fallback: 5th pipe-delimited field
      if [ -z "$_lpct" ] || [ "$_lpct" = "0" ]; then
        _lpct=$(sed "s/${_esc}\\[[0-9;]*m//g" "$GATE_COVFILE" 2>/dev/null | grep 'All files' | \
          awk -F'|' '{gsub(/ /,"",$5); print $5+0}')
      fi
      printf '%s' "$_lpct" ;;
  esac
}

_recipe_python() {
  _req="$1"; _d="$2"
  _py=$(command -v python3 2>/dev/null || command -v python 2>/dev/null || true)
  case "$_req" in
    workspace_root) return 1 ;;
    detect)
      [ -f "$_d/pyproject.toml" ] || [ -f "$_d/setup.py" ] || \
        [ -f "$_d/setup.cfg" ] || [ -f "$_d/requirements.txt" ] ;;
    has_tests) find "$_d" \( -name 'test_*.py' -o -name '*_test.py' \) 2>/dev/null | grep -q . ;;
    build)
      if [ -n "$_py" ] && "$_py" -c "import build" >/dev/null 2>&1; then
        gate_run "python build failed" "$_d" "$_py" -m build
      elif command -v poetry >/dev/null 2>&1; then
        gate_run "poetry build failed" "$_d" poetry build
      else
        gate_skip "no build tool detected"
      fi ;;
    test)
      if [ -z "$_py" ]; then
        gate_skip "toolchain not installed (python not found)"
      else
        gate_exec "$_d" "$_py" -m pytest -m unit --cov=src --cov-report=term-missing -q
        if [ "$GATE_EXIT" = "5" ]; then
          gate_exec "$_d" "$_py" -m pytest --cov=src --cov-report=term-missing -q
        fi
        gate_finish "pytest failed (exit {exit})"
      fi ;;
    lint)
      # Prefer ruff; fall back to python3 -m ruff, then flake8, then pylint
      if command -v ruff >/dev/null 2>&1; then
        gate_run "ruff failed" "$_d" ruff check .
      elif [ -n "$_py" ] && "$_py" -m ruff --version >/dev/null 2>&1; then
        gate_run "ruff failed" "$_d" "$_py" -m ruff check .
      elif command -v flake8 >/dev/null 2>&1; then
        gate_run "flake8 failed" "$_d" flake8 .
      elif [ -n "$_py" ] && "$_py" -m flake8 --version >/dev/null 2>&1; then
        gate_run "flake8 failed" "$_d" "$_py" -m flake8 .
      elif command -v pylint >/dev/null 2>&1; then
        gate_run "pylint failed" "$_d" pylint src/
      else
        gate_skip "linter not installed (ruff/flake8/pylint not found)"
      fi ;;
    coverage)
      # TOTAL    142    12    92%   → last field, strip %
      grep '^TOTAL' "$GATE_COVFILE" 2>/dev/null | awk '{print $NF}' | sed 's/%//' | head -1 ;;
  esac
}

_recipe_go() {
  _req="$1"; _d="$2"
  case "$_req" in
    workspace_root) [ -f "$_d/go.work" ] ;;
    # go.mod is canonical — *.go files may appear in vendor/ of non-Go projects
    detect)    [ -f "$_d/go.mod" ] ;;
    has_tests) find "$_d" -name '*_test.go' 2>/dev/null | grep -q . ;;
    build)
      if command -v go >/dev/null 2>&1; then
        gate_run "go build failed" "$_d" go build ./...
      else
        gate_skip "toolchain not installed (go not found)"
      fi ;;
    test)
      if command -v go >/dev/null 2>&1; then
        gate_exec "$_d" go test -short -coverprofile="$WORK/cov.out" ./...
        [ "$GATE_EXIT" = "0" ] && gate_exec_more "$_d" go tool cover -func="$WORK/cov.out"
        gate_finish "go test failed"
      else
        gate_skip "toolchain not installed (go not found)"
      fi ;;
    lint)
      # go vet is always available when Go is installed
      if command -v go >/dev/null 2>&1; then
        if command -v golangci-lint >/dev/null 2>&1; then
          gate_run "golangci-lint failed" "$_d" golangci-lint run
        else
          gate_run "go vet failed" "$_d" go vet ./...
        fi
      else
        gate_skip "toolchain not installed (go not found)"
      fi ;;
    coverage)
      # total:  (statements)   77.8%
      grep '^total:' "$GATE_COVFILE" 2>/dev/null | awk '{print $NF}' | sed 's/%//' | head -1
      return 0 ;;
  esac
}

_recipe_rust() {
  _req="$1"; _d="$2"
  case "$_req" in
    workspace_root) grep -q '^\[workspace\]' "$_d/Cargo.toml" 2>/dev/null ;;
    coverage_hint) printf 'install cargo-llvm-cov or cargo-tarpaulin' ;;
    detect)    [ -f "$_d/Cargo.toml" ] ;;
    has_tests) grep -r '#\[cfg(test)\]' "$_d/src" >/dev/null 2>&1 || [ -d "$_d/tests" ] ;;
    build)
      if command -v cargo >/dev/null 2>&1; then
        gate_run "cargo build failed" "$_d" cargo build
      else
        gate_skip "toolchain not installed (cargo not found)"
      fi ;;
    test)
      if command -v cargo >/dev/null 2>&1; then
        # Tests run once; a coverage tool, when installed, measures that same run.
        if cargo llvm-cov --version >/dev/null 2>&1; then
          gate_run "cargo test failed" "$_d" cargo llvm-cov --lib
        elif cargo tarpaulin --version >/dev/null 2>&1; then
          gate_run "cargo test failed" "$_d" cargo tarpaulin --lib --out Stdout
        else
          gate_run "cargo test failed" "$_d" cargo test --lib
        fi
      else
        gate_skip "toolchain not installed (cargo not found)"
      fi ;;
    lint)
      if ! command -v cargo >/dev/null 2>&1; then
        gate_skip "toolchain not installed (cargo not found)"
      elif ! cargo clippy --version >/dev/null 2>&1; then
        gate_skip "linter not installed (cargo clippy not found)"
      else
        gate_run "clippy failed" "$_d" cargo clippy -- -D warnings
      fi ;;
    coverage)
      # cargo-llvm-cov: "TOTAL regions missed cover% functions missed exec% lines missed cover% ..."
      _lpct=$(grep 'TOTAL' "$GATE_COVFILE" 2>/dev/null | awk '{print (NF >= 10 ? $10 : $NF)}' | sed 's/%//' | head -1)
      [ -z "$_lpct" ] && _lpct=$(grep -o '[0-9]*\.[0-9]*% coverage' "$GATE_COVFILE" 2>/dev/null | \
        sed 's/% coverage//' | head -1)
      printf '%s' "$_lpct"
      return 0 ;;
  esac
}

_recipe_swift() {
  _req="$1"; _d="$2"
  case "$_req" in
    workspace_root) return 1 ;;
    detect)
      [ -f "$_d/Package.swift" ] || ls -d "$_d"/*.xcodeproj >/dev/null 2>&1 ;;
    has_tests) find "$_d" -name '*Tests.swift' 2>/dev/null | grep -q . ;;
    build)
      if command -v swift >/dev/null 2>&1; then
        gate_run "swift build failed" "$_d" swift build
      else
        gate_skip "toolchain not installed (swift not found)"
      fi ;;
    test)
      if command -v swift >/dev/null 2>&1; then
        gate_exec "$_d" swift test --enable-code-coverage
        # Ask SwiftPM where it wrote the coverage JSON; the path lands in the captured output.
        [ "$GATE_EXIT" = "0" ] && gate_exec_more "$_d" swift test --show-codecov-path
        gate_finish "swift test failed"
      else
        gate_skip "toolchain not installed (swift not found)"
      fi ;;
    lint)
      if command -v swiftlint >/dev/null 2>&1; then
        gate_run "swiftlint failed" "$_d" swiftlint
      else
        gate_skip "linter not installed (swiftlint not found)"
      fi ;;
    coverage)
      # SwiftPM's coverage JSON: sum line counts over the package's own sources
      # (not Tests/ and not .build/).
      _cj=$(grep '\.json$' "$GATE_COVFILE" 2>/dev/null | tail -1)
      [ -f "$_cj" ] && awk '{
        n = split($0, p, /"filename":"/)
        for (i = 2; i <= n; i++) {
          f = p[i]; sub(/".*/, "", f)
          if (f ~ /\/Tests\// || f ~ /\.build\//) continue
          if (match(p[i], /"lines":\{"count":[0-9]+,"covered":[0-9]+/)) {
            q = substr(p[i], RSTART, RLENGTH); gsub(/[^0-9,]/, "", q); split(q, a, ","); c += a[1]; v += a[2]
          }
        }
      } END { if (c > 0) printf "%.1f", v / c * 100 }' "$_cj"
      return 0 ;;
  esac
}

_recipe_cpp() {
  _req="$1"; _d="$2"
  case "$_req" in
    workspace_root) return 1 ;;
    detect)
      [ -f "$_d/CMakeLists.txt" ] || \
        { [ -f "$_d/Makefile" ] && \
          { ls "$_d"/*.c >/dev/null 2>&1 || ls "$_d"/*.cpp >/dev/null 2>&1; }; } ;;
    has_tests)
      find "$_d" \( -name '*_test.c' -o -name '*_test.cpp' \) 2>/dev/null | grep -q . || \
        [ -d "$_d/test" ] || [ -d "$_d/tests" ] ;;
    build)
      if [ -f "$_d/CMakeLists.txt" ] && command -v cmake >/dev/null 2>&1; then
        gate_exec "$_d" cmake -B build -DCMAKE_BUILD_TYPE=Release
        [ "$GATE_EXIT" = "0" ] && gate_exec_more "$_d" cmake --build build
        gate_finish "cmake build failed"
      elif [ -f "$_d/Makefile" ] && command -v make >/dev/null 2>&1; then
        gate_run "make failed" "$_d" make
      else
        gate_skip "toolchain not installed"
      fi ;;
    test)
      if [ -f "$_d/CMakeLists.txt" ] || [ ! -f "$_d/Makefile" ]; then
        if command -v ctest >/dev/null 2>&1; then
          gate_run "ctest failed" "$_d" ctest --test-dir build
        else
          gate_skip "toolchain not installed (ctest not found)"
        fi
      elif grep -q '^test:' "$_d/Makefile" 2>/dev/null && command -v make >/dev/null 2>&1; then
        # Makefile project with a `test` target
        gate_run "make test failed" "$_d" make test
      else
        gate_skip "no test command detected (no CMakeLists.txt, or no test target in Makefile)"
      fi ;;
    lint)
      if ! command -v clang-tidy >/dev/null 2>&1; then
        gate_skip "linter not installed (clang-tidy not found)"
      elif [ ! -f "$_d/.clang-tidy" ]; then
        # Without a config clang-tidy exits with "no checks enabled", which is not a lint failure.
        gate_skip "no .clang-tidy config found"
      else
        _cfiles=$(find "$_d" -maxdepth 4 \( -name '*.cpp' -o -name '*.c' \) \
          ! -path '*/build/*' 2>/dev/null | head -100 | tr '\n' ' ')
        if [ -n "$_cfiles" ]; then
          gate_run "clang-tidy failed" "$_d" clang-tidy $_cfiles --
        else
          gate_skip "no .c/.cpp source files found"
        fi
      fi ;;
    coverage) return 1 ;;
  esac
}

# Gradle launcher for a Project: its wrapper, else a system `gradle` when the Project has a build file.
_gradle() { # <dir>
  if [ -f "$1/gradlew" ]; then printf './gradlew'
  elif { [ -f "$1/build.gradle" ] || [ -f "$1/build.gradle.kts" ]; } && command -v gradle >/dev/null 2>&1; then printf 'gradle'
  else return 1; fi
}

# Line coverage from a JaCoCo XML report; prints "null" when there is none.
_jacoco_line_pct() {
  _jxml="$1/target/site/jacoco/jacoco.xml"
  [ -f "$1/build/reports/jacoco/test/jacocoTestReport.xml" ] && \
    _jxml="$1/build/reports/jacoco/test/jacocoTestReport.xml"
  _jp=null
  if [ -f "$_jxml" ]; then
    _missed=$(grep 'type="LINE"' "$_jxml" | tail -1 | sed 's/.*missed="\([0-9]*\)".*/\1/')
    _cov=$(grep 'type="LINE"' "$_jxml" | tail -1 | sed 's/.*covered="\([0-9]*\)".*/\1/')
    [ -n "$_missed" ] && [ -n "$_cov" ] && _tot=$((_missed + _cov)) && [ "$_tot" -gt 0 ] && \
      _jp=$(awk "BEGIN{printf \"%.1f\",($_cov/$_tot)*100}")
  fi
  printf '%s' "$_jp"
}

_recipe_java() {
  _req="$1"; _d="$2"
  case "$_req" in
    workspace_root) grep -q '<modules>' "$_d/pom.xml" 2>/dev/null || grep -qs '^[[:space:]]*include' "$_d/settings.gradle" "$_d/settings.gradle.kts" ;;
    detect)
      { [ -f "$_d/pom.xml" ] || [ -f "$_d/build.gradle" ]; } ;;
    has_tests) [ -d "$_d/src/test" ] ;;
    build)
      if [ -f "$_d/mvnw" ]; then
        gate_run "mvnw failed" "$_d" ./mvnw package -DskipTests
      elif [ -f "$_d/pom.xml" ] && command -v mvn >/dev/null 2>&1; then
        gate_run "mvn failed" "$_d" mvn package -DskipTests
      elif _g=$(_gradle "$_d"); then
        gate_run "gradlew assemble failed" "$_d" "$_g" assemble
      else
        gate_skip "toolchain not installed"
      fi ;;
    test) _jvm_test "$_d" ;;
    lint)
      if [ -f "$_d/mvnw" ]; then
        gate_run "checkstyle failed" "$_d" ./mvnw checkstyle:check
      elif [ -f "$_d/pom.xml" ] && command -v mvn >/dev/null 2>&1; then
        gate_run "checkstyle failed" "$_d" mvn checkstyle:check
      elif _g=$(_gradle "$_d") && grep -qs checkstyle "$_d/build.gradle" "$_d/build.gradle.kts"; then
        gate_run "checkstyle failed" "$_d" "$_g" checkstyleMain
      else
        gate_skip "linter not installed"
      fi ;;
    coverage) _jacoco_line_pct "$_d"; return 0 ;;
  esac
}

_recipe_kotlin() {
  _req="$1"; _d="$2"
  case "$_req" in
    workspace_root) grep -qs '^[[:space:]]*include' "$_d/settings.gradle" "$_d/settings.gradle.kts" ;;
    detect)
      [ -f "$_d/build.gradle.kts" ] || \
        { [ -f "$_d/build.gradle" ] && ls "$_d"/*.kt >/dev/null 2>&1; } ;;
    has_tests) [ -d "$_d/src/test" ] ;;
    build)
      if _g=$(_gradle "$_d"); then
        gate_run "gradlew assemble failed" "$_d" "$_g" assemble
      else
        gate_skip "toolchain not installed"
      fi ;;
    test) _jvm_test "$_d" ;;
    lint)
      if _g=$(_gradle "$_d") && grep -qs ktlint "$_d/build.gradle" "$_d/build.gradle.kts"; then
        gate_run "ktlint failed" "$_d" "$_g" ktlintCheck
      else
        gate_skip "linter not installed"
      fi ;;
    coverage) _jacoco_line_pct "$_d"; return 0 ;;
  esac
}

# Test Gate shared by the JVM Languages (Java, Kotlin).
_jvm_test() {
  if [ -f "$1/mvnw" ]; then gate_run "test failed" "$1" ./mvnw test
  elif [ -f "$1/pom.xml" ] && command -v mvn >/dev/null 2>&1; then gate_run "test failed" "$1" mvn test
  elif _g=$(_gradle "$1"); then gate_run "test failed" "$1" "$_g" test
  else gate_skip "toolchain not installed"; fi
}

_recipe_scala() {
  _req="$1"; _d="$2"
  case "$_req" in
    workspace_root) return 1 ;;
    detect)    [ -f "$_d/build.sbt" ] ;;
    has_tests) [ -d "$_d/src/test" ] ;;
    build)
      if command -v sbt >/dev/null 2>&1; then
        gate_run "sbt compile failed" "$_d" sbt compile
      else
        gate_skip "toolchain not installed (sbt not found)"
      fi ;;
    test)
      if command -v sbt >/dev/null 2>&1; then
        if grep -rqs scoverage "$_d/project" 2>/dev/null; then
          # sbt-scoverage measures the same run; its report prints "Statement coverage.: NN.NN%".
          gate_exec "$_d" sbt coverage 'testOnly *Unit*' coverageReport
          # sbt exits 0 when the pattern matches nothing, so also fall back on "No tests to run".
          if [ "$GATE_EXIT" != "0" ] || gate_output_matches 'No tests to run'; then
            gate_exec "$_d" sbt coverage test coverageReport
          fi
        else
          gate_exec "$_d" sbt 'testOnly *Unit*'
          if [ "$GATE_EXIT" != "0" ] || gate_output_matches 'No tests to run'; then
            gate_exec "$_d" sbt test
          fi
        fi
        gate_finish "sbt test failed"
      else
        gate_skip "toolchain not installed (sbt not found)"
      fi ;;
    lint)
      if ! command -v sbt >/dev/null 2>&1; then
        gate_skip "toolchain not installed (sbt not found)"
      elif ! grep -rqs scalastyle "$_d/build.sbt" "$_d/project" 2>/dev/null; then
        gate_skip "linter not installed (scalastyle plugin not configured)"
      else
        gate_run "scalastyle failed" "$_d" sbt scalastyle
      fi ;;
    coverage)
      # sbt-scoverage reports statement coverage (the closest it has to line coverage).
      grep -o 'Statement coverage[.]*: *[0-9.]*%' "$GATE_COVFILE" 2>/dev/null | tail -1 | sed 's/.*: *//; s/%//'
      return 0 ;;
    coverage_hint) printf 'add the sbt-scoverage plugin to project/plugins.sbt' ;;
  esac
}

_recipe_dotnet() {
  _req="$1"; _d="$2"
  case "$_req" in
    workspace_root) ls "$_d"/*.sln >/dev/null 2>&1 || ls "$_d"/*.slnx >/dev/null 2>&1 ;;
    detect)
      ls "$_d"/*.csproj >/dev/null 2>&1 || ls "$_d"/*.sln >/dev/null 2>&1 || \
        ls "$_d"/*.slnx >/dev/null 2>&1 || [ -f "$_d/global.json" ] ;;
    has_tests)
      # By file name, or by a test attribute (xUnit [Fact]/[Theory], NUnit [Test], MSTest [TestMethod]).
      find "$_d" \( -name '*Tests.cs' -o -name '*Test.cs' \) 2>/dev/null | grep -q . || \
        grep -rlE '\[(Fact|Theory|Test|TestCase|TestMethod|DataTestMethod)\b' --include='*.cs' \
          --exclude-dir=obj --exclude-dir=bin --exclude-dir=node_modules "$_d" 2>/dev/null | grep -q . ;;
    build)
      if command -v dotnet >/dev/null 2>&1; then
        gate_exec "$_d" dotnet restore
        [ "$GATE_EXIT" = "0" ] && gate_exec_more "$_d" dotnet build
        gate_finish "dotnet build failed"
      else
        gate_skip "toolchain not installed (dotnet not found)"
      fi ;;
    test)
      if command -v dotnet >/dev/null 2>&1; then
        gate_run "dotnet test failed" "$_d" dotnet test --no-build --collect:'XPlat Code Coverage'
      else
        gate_skip "toolchain not installed (dotnet not found)"
      fi ;;
    lint)
      if command -v dotnet >/dev/null 2>&1; then
        gate_run "dotnet format failed" "$_d" dotnet format --verify-no-changes
      else
        gate_skip "toolchain not installed (dotnet not found)"
      fi ;;
    coverage)
      # Cobertura files written by coverlet; the test output lists their paths.
      # Sum covered and valid lines over all of them.
      grep -o '[^ ]*coverage\.cobertura\.xml' "$GATE_COVFILE" 2>/dev/null | sort -u | while read -r _x; do
        [ -f "$_x" ] || continue
        _root=$(grep -m1 '<coverage ' "$_x")
        printf '%s %s\n' "$(printf '%s' "$_root" | sed -n 's/.* lines-covered="\([0-9]*\)".*/\1/p')" \
                          "$(printf '%s' "$_root" | sed -n 's/.* lines-valid="\([0-9]*\)".*/\1/p')"
      done | awk '$2 ~ /^[0-9]+$/ {c+=$1; v+=$2} END {if (v>0) printf "%.1f", c/v*100}'
      return 0 ;;
  esac
}

_recipe_ruby() {
  _req="$1"; _d="$2"
  case "$_req" in
    workspace_root) return 1 ;;
    detect)    [ -f "$_d/Gemfile" ] ;;
    has_tests) find "$_d" \( -name '*_spec.rb' -o -name '*_test.rb' \) 2>/dev/null | grep -q . ;;
    build)
      if command -v bundle >/dev/null 2>&1 && [ -f "$_d/Rakefile" ] && \
         grep -q 'build' "$_d/Rakefile" 2>/dev/null; then
        gate_run "rake build failed" "$_d" bundle exec rake build
      else
        gate_skip "no build command detected"
      fi ;;
    test)
      if command -v bundle >/dev/null 2>&1; then
        if [ -x "$_d/bin/rails" ] && [ ! -d "$_d/spec" ]; then
          gate_run "rails test failed" "$_d" bundle exec rails test
        elif [ ! -d "$_d/spec" ] && [ -d "$_d/test" ]; then
          # Minitest without Rails
          gate_run "minitest failed" "$_d" bundle exec ruby -Itest -e "Dir.glob('./test/**/*_test.rb').sort.each { |f| require f }"
        else
          gate_exec "$_d" bundle exec rspec --tag unit spec/
          # RSpec exits 0 when no example carries the tag, so also fall back on "0 examples".
          if [ "$GATE_EXIT" != "0" ] || gate_output_matches '(^|[^0-9])0 examples,'; then
            gate_exec_more "$_d" bundle exec rspec spec/
          fi
          gate_finish "rspec failed"
        fi
      else
        gate_skip "toolchain not installed (bundle not found)"
      fi ;;
    lint)
      if ! command -v bundle >/dev/null 2>&1; then
        gate_skip "linter not installed (bundle not found)"
      elif ! grep -qs rubocop "$_d/Gemfile" "$_d/Gemfile.lock"; then
        gate_skip "linter not installed (rubocop not in Gemfile)"
      else
        gate_run "rubocop failed" "$_d" bundle exec rubocop
      fi ;;
    coverage)
      # SimpleCov prints "Line coverage: 2 / 2 (100.00%)", sometimes with ANSI colour.
      sed 's/\x1b\[[0-9;]*m//g' "$GATE_COVFILE" 2>/dev/null | \
        sed -n 's/.*[Ll]ine coverage:[^(]*(\([0-9.]*\)%).*/\1/p' | tail -1
      return 0 ;;
  esac
}

_recipe_php() {
  _req="$1"; _d="$2"
  case "$_req" in
    workspace_root) return 1 ;;
    coverage_hint) printf 'install xdebug or pcov so PHPUnit can measure coverage' ;;
    detect)    [ -f "$_d/composer.json" ] ;;
    has_tests) find "$_d" -name '*Test.php' 2>/dev/null | grep -q . ;;
    build)
      if command -v composer >/dev/null 2>&1; then
        # Dev dependencies stay: the test and lint Gates need phpunit and phpstan from vendor/.
        gate_run "composer install failed" "$_d" composer install --no-interaction
      else
        gate_skip "toolchain not installed (composer not found)"
      fi ;;
    test)
      if [ -f "$_d/vendor/bin/phpunit" ]; then
        gate_exec "$_d" ./vendor/bin/phpunit --coverage-text
        # Without xdebug or pcov PHPUnit exits 1 even when every test passes; rerun without coverage.
        if [ "$GATE_EXIT" != "0" ] && gate_output_matches 'No code coverage driver available'; then
          gate_exec "$_d" ./vendor/bin/phpunit
        fi
        gate_finish "phpunit failed"
      else
        gate_skip "toolchain not installed (phpunit not found)"
      fi ;;
    lint)
      if [ -f "$_d/vendor/bin/phpstan" ]; then
        gate_run "phpstan failed" "$_d" ./vendor/bin/phpstan analyse
      else
        gate_skip "linter not installed (phpstan/psalm not found)"
      fi ;;
    coverage)
      grep 'Lines:' "$GATE_COVFILE" 2>/dev/null | \
        grep -o '[0-9]*\.[0-9]*%' | sed 's/%//' | head -1
      return 0 ;;
  esac
}

_recipe_elixir() {
  _req="$1"; _d="$2"
  case "$_req" in
    workspace_root) return 1 ;;
    detect)    [ -f "$_d/mix.exs" ] ;;
    has_tests) find "$_d" -name '*_test.exs' 2>/dev/null | grep -q . ;;
    build)
      if command -v mix >/dev/null 2>&1; then
        gate_run "mix compile failed" "$_d" mix compile
      else
        gate_skip "toolchain not installed (mix not found)"
      fi ;;
    test)
      if command -v mix >/dev/null 2>&1; then
        gate_exec "$_d" mix test --cover --only unit
        [ "$GATE_EXIT" = "0" ] || gate_exec_more "$_d" mix test --cover
        gate_finish "mix test failed"
      else
        gate_skip "toolchain not installed (mix not found)"
      fi ;;
    lint)
      if ! command -v mix >/dev/null 2>&1; then
        gate_skip "toolchain not installed (mix not found)"
      elif ! grep -qs credo "$_d/mix.exs"; then
        gate_skip "linter not installed (credo not in mix.exs)"
      else
        gate_run "mix credo failed" "$_d" mix credo
      fi ;;
    coverage)
      grep -o '[0-9]*\.[0-9]*% | Total' "$GATE_COVFILE" 2>/dev/null | \
        sed 's/% | Total//' | tail -1
      return 0 ;;
  esac
}

# ---------------------------------------------------------------------------
# Gate runner — owns timing, status classification, Sidecar Log writing,
# dry-run and verbose handling, and the Hard Gate rule that a Project with no
# test files fails its test Gate (ADR-0001).
# ---------------------------------------------------------------------------

# Outcome helpers a recipe calls.
gate_pass() { GATE_STATUS=PASS; GATE_REASON=""; GATE_EXIT_CODE=0; }
gate_skip() { GATE_STATUS=SKIPPED; GATE_REASON="$1"; GATE_EXIT_CODE=null; }

# Run one command in <dir> (dry-run prints it instead). Leaves its exit code in
# $GATE_EXIT and its output in $WORK/out. gate_exec_more appends to that output,
# for a second command that follows the first (a && b, a || b).
_gate_cmd() { # <append yes|no> <dir> <cmd> [args...]
  _app="$1"; _dir="$2"; shift 2
  GATE_RAN=true
  if [ "$DRY_RUN" = "true" ]; then printf "[DRY RUN] (cd '%s' && %s)\n" "$_dir" "$*"; GATE_EXIT=0; return 0; fi
  [ "$_app" = "yes" ] || : > "$WORK/out"
  if $VERBOSE; then
    # POSIX sh has no PIPESTATUS, so carry the command's status past tee in a file.
    { (cd "$_dir" && "$@") 2>&1; printf '%s' "$?" > "$WORK/status"; } | tee -a "$WORK/out"
    GATE_EXIT=$(cat "$WORK/status")
  else (cd "$_dir" && "$@") >> "$WORK/out" 2>&1; GATE_EXIT=$?; fi
}
gate_exec()      { _gate_cmd no "$@"; }
gate_exec_more() { _gate_cmd yes "$@"; }

gate_output_matches() { grep -qE "$1" "$WORK/out" 2>/dev/null; }

# Classify the last gate_exec: PASS on exit 0, otherwise FAIL with the given
# reason ({exit} is replaced by the exit code) and a Sidecar Log.
gate_finish() {
  if [ "$GATE_EXIT" = "0" ]; then gate_pass; return; fi
  _failreason="$1"
  case "$_failreason" in *'{exit}'*) _failreason="${_failreason%%'{exit}'*}${GATE_EXIT}${_failreason#*'{exit}'}" ;; esac
  GATE_STATUS=FAIL; GATE_REASON="$_failreason"; GATE_EXIT_CODE=$GATE_EXIT
  GATE_LOG=$(_save_sidecar "$GATE_PROJECT" "$GATE_LANG" "$GATE_NAME")
}

gate_run() { _failreason_run="$1"; shift; gate_exec "$@"; gate_finish "$_failreason_run"; }

# Test Gate precondition (Hard Gate, ADR-0001): no test files is a FAIL.
_gate_no_tests() {
  GATE_STATUS=FAIL; GATE_EXIT_CODE=1
  GATE_REASON="No test files detected — a project must have tests to be reviewable"
  printf '%s\n' "$GATE_REASON" > "$WORK/out"
  GATE_LOG=$(_save_sidecar "$GATE_PROJECT" "$GATE_LANG" "$GATE_NAME")
  GATE_DETAIL="$GATE_REASON"
}

# Coverage Gate: parse the output captured by the test Gate (no re-run) and
# compare line coverage with the Language's threshold.
_gate_coverage() {
  GATE_THRESHOLD=$(_get_threshold "$GATE_LANG")
  GATE_EXIT_CODE=null
  if [ "$DRY_RUN" = "true" ]; then
    printf '[DRY RUN] coverage parse (no re-run)\n'
    gate_skip "dry-run mode"; GATE_DETAIL="$GATE_REASON"; return
  fi
  GATE_COVFILE="$WORK/COV_${_project_index}"
  if [ ! -f "$GATE_COVFILE" ]; then
    gate_skip "no coverage data (test gate skipped or failed)"; GATE_DETAIL="$GATE_REASON"; return
  fi
  # A recipe with no coverage reader returns non-zero.
  if ! GATE_LPCT=$("_recipe_$GATE_LANG" coverage "$_abs"); then
    GATE_LPCT=''
    gate_skip "coverage parsing not implemented for $GATE_LANG"; GATE_DETAIL="$GATE_REASON"; return
  fi
  if [ -z "$GATE_LPCT" ]; then
    _hint=$("_recipe_$GATE_LANG" coverage_hint "$_abs" 2>/dev/null)
    gate_skip "coverage output unparseable${_hint:+ ($_hint)}"
    cp "$GATE_COVFILE" "$LOG_DIR/${GATE_PROJECT}-${GATE_LANG}-coverage-raw.log" 2>/dev/null || true
    GATE_LOG="validation-logs/${GATE_PROJECT}-${GATE_LANG}-coverage-raw.log"
  elif [ "$(awk "BEGIN{print ($GATE_LPCT+0 >= $GATE_THRESHOLD+0) ? \"yes\" : \"no\"}")" = "yes" ]; then
    GATE_STATUS=PASS; GATE_REASON=""
  else
    GATE_STATUS=FAIL; GATE_REASON="${GATE_LPCT}% < ${GATE_THRESHOLD}% threshold"
    printf '%s\n' "$GATE_REASON" > "$WORK/out"
    GATE_LOG=$(_save_sidecar "$GATE_PROJECT" "$GATE_LANG" "$GATE_NAME")
  fi
}

_run_gate() {
  _gate="$1"; _project="$2"; _abs="$3"; _lang="$4"
  GATE_NAME="$_gate"; GATE_PROJECT="$_project"; GATE_LANG="$_lang"
  GATE_STATUS=SKIPPED; GATE_REASON=""; GATE_EXIT_CODE=null; GATE_LOG=null
  GATE_RAN=false; GATE_DETAIL=''; GATE_LPCT=''; GATE_THRESHOLD=''
  [ "$_gate" = "build" ] && GATE_REASON="no build command applies"
  _t0=$(date +%s)
  _status_line "$_project" "$_lang" "$_gate" "RUNNING"

  if [ "$_gate" = "coverage" ]; then
    _gate_coverage
  elif [ "$_gate" = "test" ] && ! "_recipe_$_lang" has_tests "$_abs"; then
    _gate_no_tests
  else
    "_recipe_$_lang" "$_gate" "$_abs"
    # Coverage is parsed later from the test Gate's captured output.
    if [ "$_gate" = "test" ] && [ "$GATE_RAN" = "true" ] && [ "$DRY_RUN" != "true" ]; then
      cp "$WORK/out" "$WORK/COV_${_project_index}" 2>/dev/null || true
    fi
  fi

  _t1=$(date +%s); _dur=$((_t1 - _t0))
  if [ -n "$GATE_DETAIL" ]; then _detail="$GATE_DETAIL"
  elif [ -n "$GATE_LPCT" ]; then _detail="(${GATE_LPCT}% vs ${GATE_THRESHOLD}%, ${_dur}s)"
  else _detail="(${_dur}s)"; fi
  _status_line "$_project" "$_lang" "$_gate" "$GATE_STATUS" "$_detail"
  _write_state "$_gate" "$GATE_STATUS" "$GATE_REASON" "$GATE_EXIT_CODE" "$_dur" "$GATE_LOG"
  if [ "$_gate" = "coverage" ]; then
    _gr_set "$_project_index" coverage lpct "${GATE_LPCT:-null}"
    _gr_set "$_project_index" coverage bpct null
    _gr_set "$_project_index" coverage fpct null
    _gr_set "$_project_index" coverage thr "$GATE_THRESHOLD"
  fi
}

# ---------------------------------------------------------------------------
# Language detection — file presence only, no content reads
# Writes detected projects to $WORK/projects: one "reldir|lang" per line
# ---------------------------------------------------------------------------
_detect_lang() {
  _d="$1"
  _try_recipe typescript && return
  _try_recipe python && return
  _try_recipe kotlin && return
  _try_recipe java && return
  # go.mod is canonical — *.go files may appear in vendor/ of non-Go projects
  _try_recipe go && return
  _try_recipe rust && return
  _try_recipe dotnet && return
  _try_recipe ruby && return
  _try_recipe php && return
  _try_recipe swift && return
  _try_recipe cpp && return
  _try_recipe elixir && return
  _try_recipe scala && return
}

> "$WORK/projects"

_l=$(_detect_lang "$INVOCATION_DIR")
[ -n "$_l" ] && printf 'root|%s\n' "$_l" >> "$WORK/projects"

# A workspace root (solution file, Maven modules, Cargo workspace, go.work, Gradle
# include) builds its own subprojects, so same-family subdirectories are not Projects.
_root_owns=false
[ -n "$_l" ] && "_recipe_$_l" workspace_root "$INVOCATION_DIR" && _root_owns=true
_same_family() { # <root lang> <sub lang>
  case "$1/$2" in java/kotlin|kotlin/java) return 0 ;; esac
  [ "$1" = "$2" ]
}

for _sub in "$INVOCATION_DIR"/*/; do
  [ -d "$_sub" ] || continue
  [ -L "${_sub%/}" ] && continue      # do not follow symlinks (a trailing slash would resolve the link)
  _sl=$(_detect_lang "$_sub")
  [ "$_root_owns" = "true" ] && _same_family "$_l" "$_sl" && continue
  [ -n "$_sl" ] && printf '%s|%s\n' "$(basename "$_sub")" "$_sl" >> "$WORK/projects"
done

if [ ! -s "$WORK/projects" ]; then
  printf 'Error: No recognisable project found in %s or its immediate subdirectories.\n' \
    "$INVOCATION_DIR" >&2
  exit 2
fi

printf 'Detected project(s):\n'
while IFS='|' read -r _project _pl; do printf '  %s [%s]\n' "$_project" "$_pl"; done < "$WORK/projects"
printf '\n'

# ---------------------------------------------------------------------------
# Gate Results — one record per Project index and Gate, written once by the
# gate functions and read only by the report writer and the summary table.
# Stored as shell variables GR_<index>_<gate>_<field>; names never contain
# directory names. The only evals in the script are in
# _gr_set and _gr_get.
#   fields: status reason exit dur log   (+ lpct bpct fpct thr on the coverage gate)
# ---------------------------------------------------------------------------

# Single-quote a value so eval assigns it verbatim.
_q() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

_gr_set() { eval "GR_${1}_${2}_${3}=$(_q "$4")"; }
_gr_get() { eval "printf '%s' \"\${GR_${1}_${2}_${3}:-}\""; }

# Record a Gate Result for the current Project ($_project_index).
_write_state() {
  _gate="$1"; _status="$2"; _reason="$3"; _exit="$4"; _dur="$5"; _log="${6:-null}"
  _gr_set "$_project_index" "$_gate" status "$_status"
  _gr_set "$_project_index" "$_gate" reason "$_reason"
  _gr_set "$_project_index" "$_gate" exit "${_exit:-null}"
  _gr_set "$_project_index" "$_gate" dur "$_dur"
  _gr_set "$_project_index" "$_gate" log "$_log"
}

_sidecar_path() { printf 'validation-logs/%s-%s-%s.log' "$1" "$2" "$3"; }

_save_sidecar() {
  _project="$1"; _lang="$2"; _gate="$3"
  _logrel=$(_sidecar_path "$_project" "$_lang" "$_gate")
  cp "$WORK/out" "$INVOCATION_DIR/$_logrel" 2>/dev/null || true
  printf '%s' "$_logrel"
}

_status_line() {
  _project="$1"; _lang="$2"; _gate="$3"; _st="$4"; _detail="${5:-}"
  case "$_st" in
    PASS)    _c="$C_GREEN" ;;
    FAIL)    _c="$C_RED"   ;;
    SKIPPED) _c="$C_YELLOW";;
    RUNNING) _c="$C_CYAN"  ;;
    *)       _c="$C_RESET" ;;
  esac
  printf '[%s/%s] %-10s %b%-8s%b' "$_project" "$_lang" "$_gate" "$_c" "$_st" "$C_RESET"
  [ -n "$_detail" ] && printf '  %s' "$_detail"
  printf '\n'
}

# ---------------------------------------------------------------------------
# RUN ALL GATES
# ---------------------------------------------------------------------------
_project_index=0
while IFS='|' read -r _project _lang; do
  [ -z "$_project" ] && continue
  _project_index=$((_project_index + 1))
  [ "$_project" = "root" ] && _abs="$INVOCATION_DIR" || _abs="$INVOCATION_DIR/$_project"

  printf '── [%s / %s] ──────────────────────────────────\n' "$_project" "$_lang"
  _run_gate build "$_project" "$_abs" "$_lang"
  _run_gate test  "$_project" "$_abs" "$_lang"
  _run_gate lint  "$_project" "$_abs" "$_lang"
  _run_gate coverage "$_project" "$_abs" "$_lang"
  printf '\n'
done < "$WORK/projects"

# ---------------------------------------------------------------------------
# Totals — read from the Gate Results; used by the report and the summary
# ---------------------------------------------------------------------------
_summarise() {
  _tp=0; _tg=0; _tpass=0; _tfail=0; _tskip=0; _op=true
  _project_index=0
  while IFS='|' read -r _project _lang; do
    [ -z "$_project" ] && continue
    _project_index=$((_project_index + 1))
    _tp=$((_tp + 1))
    for _gate in build test lint coverage; do
      _tg=$((_tg + 1))
      _gs=$(_gr_get "$_project_index" "$_gate" status); [ -n "$_gs" ] || _gs=SKIPPED
      case "$_gs" in
        PASS)    _tpass=$((_tpass+1)) ;;
        FAIL)    _tfail=$((_tfail+1)); _op=false ;;
        SKIPPED) _tskip=$((_tskip+1)) ;;
      esac
    done
  done < "$WORK/projects"
}

# ---------------------------------------------------------------------------
# Validation Report writer — owns the pinned schema, field order, null
# handling and JSON escaping (ADR-0002). Reads Gate Results and the totals.
# ---------------------------------------------------------------------------
_write_report() {
  _ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%SZ')
  _proj_arr=""
  _pfirst=true
  _project_index=0
  while IFS='|' read -r _project _lang; do
    [ -z "$_project" ] && continue
    _project_index=$((_project_index + 1))
    _gates_json=""
    _gfirst=true

    for _gate in build test lint coverage; do
      _gs=$(_gr_get "$_project_index" "$_gate" status); [ -n "$_gs" ] || _gs=SKIPPED
      _rs=$(_gr_get "$_project_index" "$_gate" reason)
      _ex=$(_gr_get "$_project_index" "$_gate" exit); [ -n "$_ex" ] || _ex=null
      _du=$(_gr_get "$_project_index" "$_gate" dur); [ -n "$_du" ] || _du=0
      _lp=$(_gr_get "$_project_index" "$_gate" log); [ -n "$_lp" ] || _lp=null

      # JSON-escape reason
      _rs_j=$(_json_esc "$_rs")

      # Log file JSON value
      if [ "$_lp" = "null" ] || [ -z "$_lp" ]; then _lp_j="null"
      else _lp_j="\"$(_json_esc "$_lp")\""; fi

      # Reason JSON value
      if [ -z "$_rs_j" ]; then _rs_jv="null"; else _rs_jv="\"$_rs_j\""; fi

      _xtra=""
      if [ "$_gate" = "coverage" ]; then
        _lpct=$(_gr_get "$_project_index" coverage lpct); [ -n "$_lpct" ] || _lpct=null
        _bpct=$(_gr_get "$_project_index" coverage bpct); [ -n "$_bpct" ] || _bpct=null
        _fpct=$(_gr_get "$_project_index" coverage fpct); [ -n "$_fpct" ] || _fpct=null
        _thr=$(_gr_get "$_project_index" coverage thr); [ -n "$_thr" ] || _thr=$COVERAGE_THRESHOLD
        _xtra=', "line_coverage_pct": '"$_lpct"', "branch_coverage_pct": '"$_bpct"', "function_coverage_pct": '"$_fpct"', "threshold_pct": '"$_thr"
      fi

      _ge='"'"$_gate"'": {"status": "'"$_gs"'", "duration_seconds": '"$_du"', "exit_code": '"$_ex"', "reason": '"$_rs_jv"', "log_file": '"$_lp_j$_xtra"'}'

      if [ "$_gfirst" = "true" ]; then _gates_json="$_ge"; _gfirst=false
      else _gates_json="$_gates_json, $_ge"; fi
    done

    _pe='{"project_dir": "'"$(_json_esc "$_project")"'", "language": "'"$_lang"'", "gates": {'"$_gates_json"'}}'
    if [ "$_pfirst" = "true" ]; then _proj_arr="$_pe"; _pfirst=false
    else _proj_arr="$_proj_arr, $_pe"; fi
  done < "$WORK/projects"

  cat > "$REPORT_FILE" << ENDJSON
{
  "validator_version": "$VALIDATOR_VERSION",
  "timestamp": "$_ts",
  "invocation_dir": "$(_json_esc "$INVOCATION_DIR")",
  "overall_pass": $_op,
  "projects": [$_proj_arr],
  "summary": {
    "total_projects": $_tp,
    "total_gates_run": $_tg,
    "passed": $_tpass,
    "failed": $_tfail,
    "skipped": $_tskip
  }
}
ENDJSON
}

_op=true
if [ "$DRY_RUN" = "false" ]; then
  _summarise
  _write_report
fi

# ---------------------------------------------------------------------------
# SUMMARY TABLE
# ---------------------------------------------------------------------------
printf '\n'
printf '┌──────────────┬────────────┬───────────┬──────────┬────────────────────────────────────────────┐\n'
printf '│ %-12s │ %-10s │ %-9s │ %-8s │ %-42s │\n' "Project" "Language" "Gate" "Result" "Detail"
printf '├──────────────┼────────────┼───────────┼──────────┼────────────────────────────────────────────┤\n'

_project_index=0
while IFS='|' read -r _project _lang; do
  [ -z "$_project" ] && continue
  _project_index=$((_project_index + 1))
  for _gate in build test lint coverage; do
    _gs=$(_gr_get "$_project_index" "$_gate" status); [ -n "$_gs" ] || _gs=SKIPPED
    _rs=$(_gr_get "$_project_index" "$_gate" reason)
    _detail=$(printf '%.42s' "$_rs")
    printf '│ %-12s │ %-10s │ %-9s │ %-8s │ %-42s │\n' \
      "$_project" "$_lang" "$_gate" "$_gs" "$_detail"
  done
done < "$WORK/projects"

printf '└──────────────┴────────────┴───────────┴──────────┴────────────────────────────────────────────┘\n\n'

if $_op; then
  printf '%bOverall: PASS%b\n' "$C_GREEN" "$C_RESET"
else
  printf '%bOverall: FAIL — %d gate(s) failed%b\n' "$C_RED" "$_tfail" "$C_RESET"
fi
[ "$DRY_RUN" = "false" ] && printf 'Report:  %s\n\n' "$REPORT_FILE"

$_op && exit 0 || exit 1
