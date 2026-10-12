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

# ---------------------------------------------------------------------------
# Temp dir — always cleaned up
# ---------------------------------------------------------------------------
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------
# Config (.validation.conf INI format)
# ---------------------------------------------------------------------------
COVERAGE_THRESHOLD=80
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
        # Key suffix is validated here, so the eval below can only assign a number.
        case "${_k#COVERAGE_THRESHOLD_}" in
          *[!A-Za-z0-9_]*|'') printf 'Invalid config key: %s\n' "$_k" >&2; exit 2 ;;
        esac
        eval "CLANG_THRESH_${_k#COVERAGE_THRESHOLD_}=$_v" ;;
    esac
  done < ".validation.conf"
}
_read_conf

_get_threshold() {
  _U=$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')
  eval "_t=\${CLANG_THRESH_${_U}:-}"
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
# Language detection — file presence only, no content reads
# Writes detected projects to $WORK/projects: one "reldir|lang" per line
# ---------------------------------------------------------------------------
_detect_lang() {
  _d="$1"
  [ -f "$_d/package.json" ]   && printf 'typescript' && return
  { [ -f "$_d/pyproject.toml" ] || [ -f "$_d/setup.py" ] || \
    [ -f "$_d/setup.cfg" ]    || [ -f "$_d/requirements.txt" ]; } \
    && printf 'python' && return
  [ -f "$_d/build.gradle.kts" ] && printf 'kotlin' && return
  { [ -f "$_d/build.gradle" ] && ls "$_d"/*.kt >/dev/null 2>&1; } \
    && printf 'kotlin' && return
  { [ -f "$_d/pom.xml" ] || [ -f "$_d/build.gradle" ]; } \
    && printf 'java' && return
  # go.mod is canonical — *.go files may appear in vendor/ of non-Go projects
  [ -f "$_d/go.mod" ]         && printf 'go'     && return
  [ -f "$_d/Cargo.toml" ]     && printf 'rust'   && return
  { ls "$_d"/*.csproj >/dev/null 2>&1 || ls "$_d"/*.sln >/dev/null 2>&1 || \
    [ -f "$_d/global.json" ]; } && printf 'dotnet' && return
  [ -f "$_d/Gemfile" ]        && printf 'ruby'   && return
  [ -f "$_d/composer.json" ]  && printf 'php'    && return
  { [ -f "$_d/Package.swift" ] || ls -d "$_d"/*.xcodeproj >/dev/null 2>&1; } \
    && printf 'swift' && return
  [ -f "$_d/CMakeLists.txt" ] && printf 'cpp'    && return
  { [ -f "$_d/Makefile" ] && \
    { ls "$_d"/*.c >/dev/null 2>&1 || ls "$_d"/*.cpp >/dev/null 2>&1; }; } \
    && printf 'cpp' && return
  [ -f "$_d/mix.exs" ]        && printf 'elixir' && return
  [ -f "$_d/build.sbt" ]      && printf 'scala'  && return
}

> "$WORK/projects"

_l=$(_detect_lang "$INVOCATION_DIR")
[ -n "$_l" ] && printf 'root|%s\n' "$_l" >> "$WORK/projects"

for _sub in "$INVOCATION_DIR"/*/; do
  [ -d "$_sub" ] || continue
  [ -L "$_sub" ] && continue          # do not follow symlinks
  _sl=$(_detect_lang "$_sub")
  [ -n "$_sl" ] && printf '%s|%s\n' "$(basename "$_sub")" "$_sl" >> "$WORK/projects"
done

if [ ! -s "$WORK/projects" ]; then
  printf 'Error: No recognisable project found in %s or its immediate subdirectories.\n' \
    "$INVOCATION_DIR" >&2
  exit 2
fi

printf 'Detected project(s):\n'
while IFS='|' read -r _pd _pl; do printf '  %s [%s]\n' "$_pd" "$_pl"; done < "$WORK/projects"
printf '\n'

# ---------------------------------------------------------------------------
# State files — written per gate so JSON builder reads them from parent shell
# (POSIX sh subshells can't export variables back; we use files instead)
#
# Per gate: $WORK/STATUS_<slug>_<lang>_<gate>   (PASS|FAIL|SKIPPED)
#           $WORK/REASON_<slug>_<lang>_<gate>   (reason string)
#           $WORK/EXIT_<slug>_<lang>_<gate>     (numeric exit code)
#           $WORK/DUR_<slug>_<lang>_<gate>      (duration seconds)
#           $WORK/LOG_<slug>_<lang>_<gate>      (sidecar log rel path)
# Coverage: $WORK/COV_<slug>_<lang>             (raw tool output)
#           $WORK/LPCT_<slug>_<lang>            (line coverage %)
# ---------------------------------------------------------------------------

_slug() { printf '%s' "$1" | sed 's|[/.-]|_|g'; }

_write_state() {
  _slug="$1"; _lang="$2"; _gate="$3"
  _status="$4"; _reason="$5"; _exit="$6"; _dur="$7"; _log="${8:-null}"
  printf '%s' "$_status" > "$WORK/STATUS_${_slug}_${_lang}_${_gate}"
  printf '%s' "$_reason" > "$WORK/REASON_${_slug}_${_lang}_${_gate}"
  printf '%s' "${_exit:-null}" > "$WORK/EXIT_${_slug}_${_lang}_${_gate}"
  printf '%s' "$_dur"    > "$WORK/DUR_${_slug}_${_lang}_${_gate}"
  printf '%s' "$_log"    > "$WORK/LOG_${_slug}_${_lang}_${_gate}"
}

_sidecar_path() { printf 'validation-logs/%s-%s-%s.log' "$1" "$2" "$3"; }

_save_sidecar() {
  _pd="$1"; _lang="$2"; _gate="$3"
  _logrel=$(_sidecar_path "$_pd" "$_lang" "$_gate")
  cp "$WORK/out" "$INVOCATION_DIR/$_logrel" 2>/dev/null || true
  printf '%s' "$_logrel"
}

_status_line() {
  _pd="$1"; _lang="$2"; _gate="$3"; _st="$4"; _detail="${5:-}"
  case "$_st" in
    PASS)    _c="$C_GREEN" ;;
    FAIL)    _c="$C_RED"   ;;
    SKIPPED) _c="$C_YELLOW";;
    RUNNING) _c="$C_CYAN"  ;;
    *)       _c="$C_RESET" ;;
  esac
  printf '[%s/%s] %-10s %b%-8s%b' "$_pd" "$_lang" "$_gate" "$_c" "$_st" "$C_RESET"
  [ -n "$_detail" ] && printf '  %s' "$_detail"
  printf '\n'
}

# ---------------------------------------------------------------------------
# Test file detection
# ---------------------------------------------------------------------------
_has_tests() {
  _d="$1"; _l="$2"
  case "$_l" in
    typescript)
      find "$_d" -not -path '*/node_modules/*' \
        \( -name '*.test.js' -o -name '*.test.ts' -o -name '*.test.jsx' \
           -o -name '*.test.tsx' -o -name '*.spec.js' -o -name '*.spec.ts' \
           -o -name '*.spec.jsx' -o -name '*.spec.tsx' \) 2>/dev/null | grep -q . ;;
    python) find "$_d" \( -name 'test_*.py' -o -name '*_test.py' \) 2>/dev/null | grep -q . ;;
    java|kotlin) [ -d "$_d/src/test" ] ;;
    go)     find "$_d" -name '*_test.go' 2>/dev/null | grep -q . ;;
    rust)   grep -r '#\[cfg(test)\]' "$_d/src" >/dev/null 2>&1 || [ -d "$_d/tests" ] ;;
    dotnet) find "$_d" \( -name '*Tests.cs' -o -name '*Test.cs' \) 2>/dev/null | grep -q . ;;
    ruby)   find "$_d" \( -name '*_spec.rb' -o -name '*_test.rb' \) 2>/dev/null | grep -q . ;;
    php)    find "$_d" -name '*Test.php' 2>/dev/null | grep -q . ;;
    swift)  find "$_d" -name '*Tests.swift' 2>/dev/null | grep -q . ;;
    cpp)    find "$_d" \( -name '*_test.c' -o -name '*_test.cpp' \) 2>/dev/null | grep -q . || \
              [ -d "$_d/test" ] || [ -d "$_d/tests" ] ;;
    elixir) find "$_d" -name '*_test.exs' 2>/dev/null | grep -q . ;;
    scala)  [ -d "$_d/src/test" ] ;;
    *)      return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# Gate 1: BUILD
# ---------------------------------------------------------------------------
_build() {
  _pd="$1"; _abs="$2"; _lang="$3"
  _slug=$(_slug "$_pd")
  _st=SKIPPED; _rs="no build command applies"; _ex=null; _log=null
  _t0=$(date +%s)
  _status_line "$_pd" "$_lang" "build" "RUNNING"

  _run() {
    if [ "$DRY_RUN" = "true" ]; then printf '[DRY RUN] %s\n' "$*"; return 0; fi
    if $VERBOSE; then eval "$*" 2>&1 | tee "$WORK/out"; return "${PIPESTATUS:-$?}"
    else eval "$*" > "$WORK/out" 2>&1; fi
  }

  case "$_lang" in
    typescript)
      if ! command -v npm >/dev/null 2>&1; then
        _st=SKIPPED; _rs="toolchain not installed (npm not found)"
      elif grep -q '"build"' "$_abs/package.json" 2>/dev/null; then
        _run "(cd '$_abs' && npm run build)" && { _st=PASS; _rs=""; _ex=0; } || \
          { _ex=$?; _st=FAIL; _rs="npm run build failed (exit $_ex)"; _log=$(_save_sidecar "$_pd" "$_lang" build); }
      elif [ -f "$_abs/node_modules/.bin/tsc" ]; then
        _run "(cd '$_abs' && ./node_modules/.bin/tsc --noEmit)" && { _st=PASS; _rs=""; _ex=0; } || \
          { _ex=$?; _st=FAIL; _rs="tsc failed (exit $_ex)"; _log=$(_save_sidecar "$_pd" "$_lang" build); }
      else
        _st=SKIPPED; _rs="no build script and tsc not found"
      fi ;;
    python)
      _py=$(command -v python3 2>/dev/null || command -v python 2>/dev/null || true)
      if [ -n "$_py" ] && "$_py" -c "import build" >/dev/null 2>&1; then
        _run "(cd '$_abs' && '$_py' -m build)" && { _st=PASS; _rs=""; _ex=0; } || \
          { _ex=$?; _st=FAIL; _rs="python build failed"; _log=$(_save_sidecar "$_pd" "$_lang" build); }
      elif command -v poetry >/dev/null 2>&1; then
        _run "(cd '$_abs' && poetry build)" && { _st=PASS; _rs=""; _ex=0; } || \
          { _ex=$?; _st=FAIL; _rs="poetry build failed"; _log=$(_save_sidecar "$_pd" "$_lang" build); }
      else
        _st=SKIPPED; _rs="no build tool detected"
      fi ;;
    java)
      if [ -f "$_abs/mvnw" ]; then
        _run "(cd '$_abs' && ./mvnw package -DskipTests)" && { _st=PASS; _rs=""; _ex=0; } || \
          { _ex=$?; _st=FAIL; _rs="mvnw failed"; _log=$(_save_sidecar "$_pd" "$_lang" build); }
      elif command -v mvn >/dev/null 2>&1; then
        _run "(cd '$_abs' && mvn package -DskipTests)" && { _st=PASS; _rs=""; _ex=0; } || \
          { _ex=$?; _st=FAIL; _rs="mvn failed"; _log=$(_save_sidecar "$_pd" "$_lang" build); }
      elif [ -f "$_abs/gradlew" ]; then
        _run "(cd '$_abs' && ./gradlew assemble)" && { _st=PASS; _rs=""; _ex=0; } || \
          { _ex=$?; _st=FAIL; _rs="gradlew assemble failed"; _log=$(_save_sidecar "$_pd" "$_lang" build); }
      else
        _st=SKIPPED; _rs="toolchain not installed"
      fi ;;
    kotlin)
      if [ -f "$_abs/gradlew" ]; then
        _run "(cd '$_abs' && ./gradlew assemble)" && { _st=PASS; _rs=""; _ex=0; } || \
          { _ex=$?; _st=FAIL; _rs="gradlew assemble failed"; _log=$(_save_sidecar "$_pd" "$_lang" build); }
      else
        _st=SKIPPED; _rs="toolchain not installed"
      fi ;;
    go)
      if command -v go >/dev/null 2>&1; then
        _run "(cd '$_abs' && go build ./...)" && { _st=PASS; _rs=""; _ex=0; } || \
          { _ex=$?; _st=FAIL; _rs="go build failed"; _log=$(_save_sidecar "$_pd" "$_lang" build); }
      else
        _st=SKIPPED; _rs="toolchain not installed (go not found)"
      fi ;;
    rust)
      if command -v cargo >/dev/null 2>&1; then
        _run "(cd '$_abs' && cargo build)" && { _st=PASS; _rs=""; _ex=0; } || \
          { _ex=$?; _st=FAIL; _rs="cargo build failed"; _log=$(_save_sidecar "$_pd" "$_lang" build); }
      else
        _st=SKIPPED; _rs="toolchain not installed (cargo not found)"
      fi ;;
    dotnet)
      if command -v dotnet >/dev/null 2>&1; then
        _run "(cd '$_abs' && dotnet restore && dotnet build)" && { _st=PASS; _rs=""; _ex=0; } || \
          { _ex=$?; _st=FAIL; _rs="dotnet build failed"; _log=$(_save_sidecar "$_pd" "$_lang" build); }
      else
        _st=SKIPPED; _rs="toolchain not installed (dotnet not found)"
      fi ;;
    ruby)
      if command -v bundle >/dev/null 2>&1 && [ -f "$_abs/Rakefile" ] && \
         grep -q 'build' "$_abs/Rakefile" 2>/dev/null; then
        _run "(cd '$_abs' && bundle exec rake build)" && { _st=PASS; _rs=""; _ex=0; } || \
          { _ex=$?; _st=FAIL; _rs="rake build failed"; _log=$(_save_sidecar "$_pd" "$_lang" build); }
      else
        _st=SKIPPED; _rs="no build step detected"
      fi ;;
    php)
      if command -v composer >/dev/null 2>&1; then
        _run "(cd '$_abs' && composer install --no-dev)" && { _st=PASS; _rs=""; _ex=0; } || \
          { _ex=$?; _st=FAIL; _rs="composer install failed"; _log=$(_save_sidecar "$_pd" "$_lang" build); }
      else
        _st=SKIPPED; _rs="toolchain not installed (composer not found)"
      fi ;;
    swift)
      if command -v swift >/dev/null 2>&1; then
        _run "(cd '$_abs' && swift build)" && { _st=PASS; _rs=""; _ex=0; } || \
          { _ex=$?; _st=FAIL; _rs="swift build failed"; _log=$(_save_sidecar "$_pd" "$_lang" build); }
      else
        _st=SKIPPED; _rs="toolchain not installed (swift not found)"
      fi ;;
    cpp)
      if [ -f "$_abs/CMakeLists.txt" ] && command -v cmake >/dev/null 2>&1; then
        _run "(cd '$_abs' && cmake -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build)" && \
          { _st=PASS; _rs=""; _ex=0; } || \
          { _ex=$?; _st=FAIL; _rs="cmake build failed"; _log=$(_save_sidecar "$_pd" "$_lang" build); }
      elif [ -f "$_abs/Makefile" ] && command -v make >/dev/null 2>&1; then
        _run "(cd '$_abs' && make)" && { _st=PASS; _rs=""; _ex=0; } || \
          { _ex=$?; _st=FAIL; _rs="make failed"; _log=$(_save_sidecar "$_pd" "$_lang" build); }
      else
        _st=SKIPPED; _rs="toolchain not installed"
      fi ;;
    elixir)
      if command -v mix >/dev/null 2>&1; then
        _run "(cd '$_abs' && mix compile)" && { _st=PASS; _rs=""; _ex=0; } || \
          { _ex=$?; _st=FAIL; _rs="mix compile failed"; _log=$(_save_sidecar "$_pd" "$_lang" build); }
      else
        _st=SKIPPED; _rs="toolchain not installed (mix not found)"
      fi ;;
    scala)
      if command -v sbt >/dev/null 2>&1; then
        _run "(cd '$_abs' && sbt compile)" && { _st=PASS; _rs=""; _ex=0; } || \
          { _ex=$?; _st=FAIL; _rs="sbt compile failed"; _log=$(_save_sidecar "$_pd" "$_lang" build); }
      else
        _st=SKIPPED; _rs="toolchain not installed (sbt not found)"
      fi ;;
    *) _st=SKIPPED; _rs="unknown language" ;;
  esac

  _t1=$(date +%s); _dur=$((_t1 - _t0))
  _status_line "$_pd" "$_lang" "build" "$_st" "(${_dur}s)"
  _write_state "$_slug" "$_lang" "build" "$_st" "$_rs" "$_ex" "$_dur" "$_log"
}

# ---------------------------------------------------------------------------
# Gate 2: TEST (with coverage collection)
# ---------------------------------------------------------------------------
_test() {
  _pd="$1"; _abs="$2"; _lang="$3"
  _slug=$(_slug "$_pd")
  _st=SKIPPED; _rs=""; _ex=null; _log=null
  _t0=$(date +%s)
  _status_line "$_pd" "$_lang" "test" "RUNNING"

  # Hard FAIL if no test files exist
  if ! _has_tests "$_abs" "$_lang"; then
    _st=FAIL; _ex=1
    _rs="No test files detected — a project must have tests to be reviewable"
    printf '%s\n' "$_rs" > "$WORK/out"
    _log=$(_save_sidecar "$_pd" "$_lang" test)
    _t1=$(date +%s); _dur=$((_t1 - _t0))
    _status_line "$_pd" "$_lang" "test" "$_st" "$_rs"
    _write_state "$_slug" "$_lang" "test" "$_st" "$_rs" "$_ex" "$_dur" "$_log"
    return
  fi

  _covfile="$WORK/COV_${_slug}_${_lang}"

  _run_test() {
    if [ "$DRY_RUN" = "true" ]; then printf '[DRY RUN] %s\n' "$*"; return 0; fi
    if $VERBOSE; then eval "$*" 2>&1 | tee "$WORK/out"
    else eval "$*" > "$WORK/out" 2>&1; fi
  }

  case "$_lang" in
    typescript)
      if ! command -v npm >/dev/null 2>&1; then
        _st=SKIPPED; _rs="toolchain not installed (npm not found)"
      else
        # Run with unit pattern; if no tests match, retry without pattern
        _run_test "(cd '$_abs' && npm test -- --coverage --coverageReporters=text \
          --testPathPattern='(unit|spec)' --forceExit)" && _ex=0 || _ex=$?
        if grep -qE 'Your test suite must contain at least one test|No tests found' \
             "$WORK/out" 2>/dev/null; then
          _run_test "(cd '$_abs' && npm test -- --coverage --coverageReporters=text \
            --forceExit)" && _ex=0 || _ex=$?
        fi
        cp "$WORK/out" "$_covfile" 2>/dev/null || true
        if [ "$_ex" = "0" ]; then _st=PASS; _rs=""
        else _st=FAIL; _rs="npm test failed (exit $_ex)"; _log=$(_save_sidecar "$_pd" "$_lang" test); fi
      fi ;;
    python)
      _py=$(command -v python3 2>/dev/null || command -v python 2>/dev/null || true)
      if [ -z "$_py" ]; then
        _st=SKIPPED; _rs="toolchain not installed (python not found)"
      else
        _run_test "(cd '$_abs' && '$_py' -m pytest -m unit --cov=src --cov-report=term-missing -q)" \
          && _ex=0 || _ex=$?
        if [ "$_ex" = "5" ]; then
          _run_test "(cd '$_abs' && '$_py' -m pytest --cov=src --cov-report=term-missing -q)" \
            && _ex=0 || _ex=$?
        fi
        cp "$WORK/out" "$_covfile" 2>/dev/null || true
        if [ "$_ex" = "0" ]; then _st=PASS; _rs=""
        else _st=FAIL; _rs="pytest failed (exit $_ex)"; _log=$(_save_sidecar "$_pd" "$_lang" test); fi
      fi ;;
    go)
      if command -v go >/dev/null 2>&1; then
        _run_test "(cd '$_abs' && go test -short -coverprofile='$WORK/cov.out' ./... && \
          go tool cover -func='$WORK/cov.out')" && _ex=0 || _ex=$?
        cp "$WORK/out" "$_covfile" 2>/dev/null || true
        if [ "$_ex" = "0" ]; then _st=PASS; _rs=""
        else _st=FAIL; _rs="go test failed"; _log=$(_save_sidecar "$_pd" "$_lang" test); fi
      else
        _st=SKIPPED; _rs="toolchain not installed (go not found)"
      fi ;;
    rust)
      if command -v cargo >/dev/null 2>&1; then
        _run_test "(cd '$_abs' && cargo test --lib)" && _ex=0 || _ex=$?
        cp "$WORK/out" "$_covfile" 2>/dev/null || true
        if [ "$_ex" = "0" ]; then _st=PASS; _rs=""
        else _st=FAIL; _rs="cargo test failed"; _log=$(_save_sidecar "$_pd" "$_lang" test); fi
      else
        _st=SKIPPED; _rs="toolchain not installed (cargo not found)"
      fi ;;
    java|kotlin)
      if [ -f "$_abs/mvnw" ]; then _tcmd="(cd '$_abs' && ./mvnw test)"
      elif command -v mvn >/dev/null 2>&1; then _tcmd="(cd '$_abs' && mvn test)"
      elif [ -f "$_abs/gradlew" ]; then _tcmd="(cd '$_abs' && ./gradlew test)"
      else _st=SKIPPED; _rs="toolchain not installed"
        _t1=$(date +%s); _dur=$((_t1 - _t0))
        _status_line "$_pd" "$_lang" "test" "$_st" "$_rs"
        _write_state "$_slug" "$_lang" "test" "$_st" "$_rs" "$_ex" "$_dur" "$_log"; return; fi
      _run_test "$_tcmd" && _ex=0 || _ex=$?
      cp "$WORK/out" "$_covfile" 2>/dev/null || true
      if [ "$_ex" = "0" ]; then _st=PASS; _rs=""
      else _st=FAIL; _rs="test failed"; _log=$(_save_sidecar "$_pd" "$_lang" test); fi ;;
    dotnet)
      if command -v dotnet >/dev/null 2>&1; then
        _run_test "(cd '$_abs' && dotnet test --no-build --collect:'XPlat Code Coverage')" \
          && _ex=0 || _ex=$?
        cp "$WORK/out" "$_covfile" 2>/dev/null || true
        if [ "$_ex" = "0" ]; then _st=PASS; _rs=""
        else _st=FAIL; _rs="dotnet test failed"; _log=$(_save_sidecar "$_pd" "$_lang" test); fi
      else
        _st=SKIPPED; _rs="toolchain not installed (dotnet not found)"
      fi ;;
    ruby)
      if command -v bundle >/dev/null 2>&1; then
        _run_test "(cd '$_abs' && bundle exec rspec --tag unit spec/ || bundle exec rspec spec/)" \
          && _ex=0 || _ex=$?
        cp "$WORK/out" "$_covfile" 2>/dev/null || true
        if [ "$_ex" = "0" ]; then _st=PASS; _rs=""
        else _st=FAIL; _rs="rspec failed"; _log=$(_save_sidecar "$_pd" "$_lang" test); fi
      else
        _st=SKIPPED; _rs="toolchain not installed (bundle not found)"
      fi ;;
    php)
      if [ -f "$_abs/vendor/bin/phpunit" ]; then
        _run_test "(cd '$_abs' && ./vendor/bin/phpunit --coverage-text)" && _ex=0 || _ex=$?
        cp "$WORK/out" "$_covfile" 2>/dev/null || true
        if [ "$_ex" = "0" ]; then _st=PASS; _rs=""
        else _st=FAIL; _rs="phpunit failed"; _log=$(_save_sidecar "$_pd" "$_lang" test); fi
      else
        _st=SKIPPED; _rs="toolchain not installed (phpunit not found)"
      fi ;;
    swift)
      if command -v swift >/dev/null 2>&1; then
        _run_test "(cd '$_abs' && swift test --enable-code-coverage)" && _ex=0 || _ex=$?
        cp "$WORK/out" "$_covfile" 2>/dev/null || true
        if [ "$_ex" = "0" ]; then _st=PASS; _rs=""
        else _st=FAIL; _rs="swift test failed"; _log=$(_save_sidecar "$_pd" "$_lang" test); fi
      else
        _st=SKIPPED; _rs="toolchain not installed (swift not found)"
      fi ;;
    cpp)
      if command -v ctest >/dev/null 2>&1; then
        _run_test "(cd '$_abs' && ctest --test-dir build)" && _ex=0 || _ex=$?
        if [ "$_ex" = "0" ]; then _st=PASS; _rs=""
        else _st=FAIL; _rs="ctest failed"; _log=$(_save_sidecar "$_pd" "$_lang" test); fi
      else
        _st=SKIPPED; _rs="toolchain not installed (ctest not found)"
      fi ;;
    elixir)
      if command -v mix >/dev/null 2>&1; then
        _run_test "(cd '$_abs' && mix test --only unit || mix test)" && _ex=0 || _ex=$?
        cp "$WORK/out" "$_covfile" 2>/dev/null || true
        if [ "$_ex" = "0" ]; then _st=PASS; _rs=""
        else _st=FAIL; _rs="mix test failed"; _log=$(_save_sidecar "$_pd" "$_lang" test); fi
      else
        _st=SKIPPED; _rs="toolchain not installed (mix not found)"
      fi ;;
    scala)
      if command -v sbt >/dev/null 2>&1; then
        _run_test "(cd '$_abs' && sbt 'testOnly *Unit*' || sbt test)" && _ex=0 || _ex=$?
        cp "$WORK/out" "$_covfile" 2>/dev/null || true
        if [ "$_ex" = "0" ]; then _st=PASS; _rs=""
        else _st=FAIL; _rs="sbt test failed"; _log=$(_save_sidecar "$_pd" "$_lang" test); fi
      else
        _st=SKIPPED; _rs="toolchain not installed (sbt not found)"
      fi ;;
    *) _st=SKIPPED; _rs="unknown language" ;;
  esac

  _t1=$(date +%s); _dur=$((_t1 - _t0))
  _status_line "$_pd" "$_lang" "test" "$_st" "(${_dur}s)"
  _write_state "$_slug" "$_lang" "test" "$_st" "$_rs" "$_ex" "$_dur" "$_log"
}

# ---------------------------------------------------------------------------
# Gate 3: LINT
# ---------------------------------------------------------------------------
_lint() {
  _pd="$1"; _abs="$2"; _lang="$3"
  _slug=$(_slug "$_pd")
  _st=SKIPPED; _rs=""; _ex=null; _log=null
  _t0=$(date +%s)
  _status_line "$_pd" "$_lang" "lint" "RUNNING"

  _run_lint() {
    if [ "$DRY_RUN" = "true" ]; then printf '[DRY RUN] %s\n' "$*"; return 0; fi
    if $VERBOSE; then eval "$*" 2>&1 | tee "$WORK/out"
    else eval "$*" > "$WORK/out" 2>&1; fi
  }

  case "$_lang" in
    typescript)
      # Check for ESLint config before invoking — prevents false FAIL from missing config error
      _has_eslint_conf=false
      for _cf in eslint.config.js eslint.config.mjs eslint.config.cjs \
                 .eslintrc.js .eslintrc.cjs .eslintrc.yaml .eslintrc.yml .eslintrc.json; do
        [ -f "$_abs/$_cf" ] && _has_eslint_conf=true && break
      done
      if [ "$_has_eslint_conf" = "false" ] && \
         grep -q '"eslintConfig"' "$_abs/package.json" 2>/dev/null; then
        _has_eslint_conf=true
      fi
      if [ "$_has_eslint_conf" = "false" ]; then
        _st=SKIPPED; _rs="no ESLint config found"
      elif [ -f "$_abs/node_modules/.bin/eslint" ]; then
        _run_lint "(cd '$_abs' && ./node_modules/.bin/eslint .)" && { _st=PASS; _ex=0; } || \
          { _ex=$?; _st=FAIL; _rs="eslint failed (exit $_ex)"; _log=$(_save_sidecar "$_pd" "$_lang" lint); }
      else
        _st=SKIPPED; _rs="linter not installed (eslint not in node_modules/.bin)"
      fi ;;
    python)
      # Prefer ruff; fall back to python3 -m ruff, then flake8, then pylint
      _py=$(command -v python3 2>/dev/null || command -v python 2>/dev/null || true)
      if command -v ruff >/dev/null 2>&1; then
        _run_lint "(cd '$_abs' && ruff check .)" && { _st=PASS; _ex=0; } || \
          { _ex=$?; _st=FAIL; _rs="ruff failed"; _log=$(_save_sidecar "$_pd" "$_lang" lint); }
      elif [ -n "$_py" ] && "$_py" -m ruff --version >/dev/null 2>&1; then
        _run_lint "(cd '$_abs' && '$_py' -m ruff check .)" && { _st=PASS; _ex=0; } || \
          { _ex=$?; _st=FAIL; _rs="ruff failed"; _log=$(_save_sidecar "$_pd" "$_lang" lint); }
      elif command -v flake8 >/dev/null 2>&1; then
        _run_lint "(cd '$_abs' && flake8 .)" && { _st=PASS; _ex=0; } || \
          { _ex=$?; _st=FAIL; _rs="flake8 failed"; _log=$(_save_sidecar "$_pd" "$_lang" lint); }
      elif [ -n "$_py" ] && "$_py" -m flake8 --version >/dev/null 2>&1; then
        _run_lint "(cd '$_abs' && '$_py' -m flake8 .)" && { _st=PASS; _ex=0; } || \
          { _ex=$?; _st=FAIL; _rs="flake8 failed"; _log=$(_save_sidecar "$_pd" "$_lang" lint); }
      elif command -v pylint >/dev/null 2>&1; then
        _run_lint "(cd '$_abs' && pylint src/)" && { _st=PASS; _ex=0; } || \
          { _ex=$?; _st=FAIL; _rs="pylint failed"; _log=$(_save_sidecar "$_pd" "$_lang" lint); }
      else
        _st=SKIPPED; _rs="linter not installed (ruff/flake8/pylint not found)"
      fi ;;
    java)
      if [ -f "$_abs/mvnw" ]; then
        _run_lint "(cd '$_abs' && ./mvnw checkstyle:check)" && { _st=PASS; _ex=0; } || \
          { _ex=$?; _st=FAIL; _rs="checkstyle failed"; _log=$(_save_sidecar "$_pd" "$_lang" lint); }
      elif [ -f "$_abs/gradlew" ]; then
        _run_lint "(cd '$_abs' && ./gradlew checkstyleMain)" && { _st=PASS; _ex=0; } || \
          { _ex=$?; _st=FAIL; _rs="checkstyle failed"; _log=$(_save_sidecar "$_pd" "$_lang" lint); }
      else
        _st=SKIPPED; _rs="linter not installed"
      fi ;;
    kotlin)
      if [ -f "$_abs/gradlew" ]; then
        _run_lint "(cd '$_abs' && ./gradlew ktlintCheck)" && { _st=PASS; _ex=0; } || \
          { _ex=$?; _st=FAIL; _rs="ktlint failed"; _log=$(_save_sidecar "$_pd" "$_lang" lint); }
      else
        _st=SKIPPED; _rs="linter not installed"
      fi ;;
    go)
      # go vet is always available when Go is installed
      if command -v go >/dev/null 2>&1; then
        if command -v golangci-lint >/dev/null 2>&1; then
          _run_lint "(cd '$_abs' && golangci-lint run)" && { _st=PASS; _ex=0; } || \
            { _ex=$?; _st=FAIL; _rs="golangci-lint failed"; _log=$(_save_sidecar "$_pd" "$_lang" lint); }
        else
          _run_lint "(cd '$_abs' && go vet ./...)" && { _st=PASS; _ex=0; } || \
            { _ex=$?; _st=FAIL; _rs="go vet failed"; _log=$(_save_sidecar "$_pd" "$_lang" lint); }
        fi
      else
        _st=SKIPPED; _rs="toolchain not installed (go not found)"
      fi ;;
    rust)
      if command -v cargo >/dev/null 2>&1; then
        _run_lint "(cd '$_abs' && cargo clippy -- -D warnings)" && { _st=PASS; _ex=0; } || \
          { _ex=$?; _st=FAIL; _rs="clippy failed"; _log=$(_save_sidecar "$_pd" "$_lang" lint); }
      else
        _st=SKIPPED; _rs="toolchain not installed (cargo not found)"
      fi ;;
    dotnet)
      if command -v dotnet >/dev/null 2>&1; then
        _run_lint "(cd '$_abs' && dotnet format --verify-no-changes)" && { _st=PASS; _ex=0; } || \
          { _ex=$?; _st=FAIL; _rs="dotnet format failed"; _log=$(_save_sidecar "$_pd" "$_lang" lint); }
      else
        _st=SKIPPED; _rs="toolchain not installed (dotnet not found)"
      fi ;;
    ruby)
      if command -v bundle >/dev/null 2>&1; then
        _run_lint "(cd '$_abs' && bundle exec rubocop)" && { _st=PASS; _ex=0; } || \
          { _ex=$?; _st=FAIL; _rs="rubocop failed"; _log=$(_save_sidecar "$_pd" "$_lang" lint); }
      else
        _st=SKIPPED; _rs="linter not installed (bundle not found)"
      fi ;;
    php)
      if [ -f "$_abs/vendor/bin/phpstan" ]; then
        _run_lint "(cd '$_abs' && ./vendor/bin/phpstan analyse)" && { _st=PASS; _ex=0; } || \
          { _ex=$?; _st=FAIL; _rs="phpstan failed"; _log=$(_save_sidecar "$_pd" "$_lang" lint); }
      else
        _st=SKIPPED; _rs="linter not installed (phpstan/psalm not found)"
      fi ;;
    swift)
      if command -v swiftlint >/dev/null 2>&1; then
        _run_lint "(cd '$_abs' && swiftlint)" && { _st=PASS; _ex=0; } || \
          { _ex=$?; _st=FAIL; _rs="swiftlint failed"; _log=$(_save_sidecar "$_pd" "$_lang" lint); }
      else
        _st=SKIPPED; _rs="linter not installed (swiftlint not found)"
      fi ;;
    cpp)
      if command -v clang-tidy >/dev/null 2>&1; then
        _cfiles=$(find "$_abs" -maxdepth 4 \( -name '*.cpp' -o -name '*.c' \) \
          ! -path '*/build/*' 2>/dev/null | head -100 | tr '\n' ' ')
        if [ -n "$_cfiles" ]; then
          _run_lint "(cd '$_abs' && clang-tidy $_cfiles --)" && { _st=PASS; _ex=0; } || \
            { _ex=$?; _st=FAIL; _rs="clang-tidy failed"; _log=$(_save_sidecar "$_pd" "$_lang" lint); }
        else
          _st=SKIPPED; _rs="no .c/.cpp source files found"
        fi
      else
        _st=SKIPPED; _rs="linter not installed (clang-tidy not found)"
      fi ;;
    elixir)
      if command -v mix >/dev/null 2>&1; then
        _run_lint "(cd '$_abs' && mix credo)" && { _st=PASS; _ex=0; } || \
          { _ex=$?; _st=FAIL; _rs="mix credo failed"; _log=$(_save_sidecar "$_pd" "$_lang" lint); }
      else
        _st=SKIPPED; _rs="toolchain not installed (mix not found)"
      fi ;;
    scala)
      if command -v sbt >/dev/null 2>&1; then
        _run_lint "(cd '$_abs' && sbt scalastyle)" && { _st=PASS; _ex=0; } || \
          { _ex=$?; _st=FAIL; _rs="scalastyle failed"; _log=$(_save_sidecar "$_pd" "$_lang" lint); }
      else
        _st=SKIPPED; _rs="toolchain not installed (sbt not found)"
      fi ;;
    *) _st=SKIPPED; _rs="unknown language" ;;
  esac

  _t1=$(date +%s); _dur=$((_t1 - _t0))
  _status_line "$_pd" "$_lang" "lint" "$_st" "(${_dur}s)"
  _write_state "$_slug" "$_lang" "lint" "$_st" "$_rs" "$_ex" "$_dur" "$_log"
}

# ---------------------------------------------------------------------------
# Gate 4: COVERAGE (parse output captured in Gate 2 — no re-run)
# ---------------------------------------------------------------------------
_coverage() {
  _pd="$1"; _abs="$2"; _lang="$3"
  _slug=$(_slug "$_pd")
  _st=SKIPPED; _rs=""; _ex=null; _log=null
  _lpct=null; _bpct=null; _fpct=null
  _thr=$(_get_threshold "$_lang")
  _t0=$(date +%s)
  _status_line "$_pd" "$_lang" "coverage" "RUNNING"

  if [ "$DRY_RUN" = "true" ]; then
    printf '[DRY RUN] coverage parse (no re-run)\n'
    _st=SKIPPED; _rs="dry-run mode"
    _t1=$(date +%s); _dur=$((_t1 - _t0))
    _status_line "$_pd" "$_lang" "coverage" "$_st" "$_rs"
    _write_state "$_slug" "$_lang" "coverage" "$_st" "$_rs" "$_ex" "$_dur" "$_log"
    printf '%s' "$_lpct" > "$WORK/LPCT_${_slug}_${_lang}"
    return
  fi

  _covfile="$WORK/COV_${_slug}_${_lang}"
  if [ ! -f "$_covfile" ]; then
    _st=SKIPPED; _rs="no coverage data (test gate skipped or failed)"
    _t1=$(date +%s); _dur=$((_t1 - _t0))
    _status_line "$_pd" "$_lang" "coverage" "$_st" "$_rs"
    _write_state "$_slug" "$_lang" "coverage" "$_st" "$_rs" "$_ex" "$_dur" "$_log"
    printf '%s' "$_lpct" > "$WORK/LPCT_${_slug}_${_lang}"
    return
  fi

  # Parse line coverage percentage from the captured output
  case "$_lang" in
    typescript)
      # Istanbul/c8 table row: All files | stmts | branch | func | lines |
      _lpct=$(grep 'All files' "$_covfile" 2>/dev/null | \
        sed 's/|/ /g' | awk '{for(i=1;i<=NF;i++) if($i+0>0 || $i=="0") print $i}' | \
        tail -1 | sed 's/[^0-9.]//g')
      # Simpler fallback: 5th pipe-delimited field
      if [ -z "$_lpct" ] || [ "$_lpct" = "0" ]; then
        _lpct=$(grep 'All files' "$_covfile" 2>/dev/null | \
          awk -F'|' '{gsub(/ /,"",$5); print $5+0}')
      fi ;;
    python)
      # TOTAL    142    12    92%   → last field, strip %
      _lpct=$(grep '^TOTAL' "$_covfile" 2>/dev/null | \
        awk '{print $NF}' | sed 's/%//' | head -1) ;;
    go)
      # total:  (statements)   77.8%
      _lpct=$(grep '^total:' "$_covfile" 2>/dev/null | \
        awk '{print $NF}' | sed 's/%//' | head -1) ;;
    java|kotlin)
      _jxml="$_abs/target/site/jacoco/jacoco.xml"
      [ -f "$_abs/build/reports/jacoco/test/jacocoTestReport.xml" ] && \
        _jxml="$_abs/build/reports/jacoco/test/jacocoTestReport.xml"
      if [ -f "$_jxml" ]; then
        _missed=$(grep 'type="LINE"' "$_jxml" | tail -1 | sed 's/.*missed="\([0-9]*\)".*/\1/')
        _cov=$(grep 'type="LINE"' "$_jxml" | tail -1 | sed 's/.*covered="\([0-9]*\)".*/\1/')
        [ -n "$_missed" ] && [ -n "$_cov" ] && _tot=$((_missed + _cov)) && [ "$_tot" -gt 0 ] && \
          _lpct=$(awk "BEGIN{printf \"%.1f\",($_cov/$_tot)*100}")
      fi ;;
    rust)
      _lpct=$(grep 'TOTAL' "$_covfile" 2>/dev/null | awk '{print $NF}' | sed 's/%//' | head -1)
      [ -z "$_lpct" ] && _lpct=$(grep -o '[0-9]*\.[0-9]*% coverage' "$_covfile" 2>/dev/null | \
        sed 's/% coverage//' | head -1) ;;
    php)
      _lpct=$(grep 'Lines:' "$_covfile" 2>/dev/null | \
        grep -o '[0-9]*\.[0-9]*%' | sed 's/%//' | head -1) ;;
    elixir)
      _lpct=$(grep -o '[0-9]*\.[0-9]*% | Total' "$_covfile" 2>/dev/null | \
        sed 's/% | Total//' | head -1) ;;
    *)
      _st=SKIPPED; _rs="coverage parsing not implemented for $_lang"
      _t1=$(date +%s); _dur=$((_t1 - _t0))
      _status_line "$_pd" "$_lang" "coverage" "$_st" "$_rs"
      _write_state "$_slug" "$_lang" "coverage" "$_st" "$_rs" "$_ex" "$_dur" "$_log"
      printf '%s' "$_lpct" > "$WORK/LPCT_${_slug}_${_lang}"
      return ;;
  esac

  if [ -z "$_lpct" ]; then
    _st=SKIPPED; _rs="coverage output unparseable"
    cp "$_covfile" "$LOG_DIR/${_slug}-${_lang}-coverage-raw.log" 2>/dev/null || true
    _log="validation-logs/${_slug}-${_lang}-coverage-raw.log"
  else
    _passes=$(awk "BEGIN{print ($_lpct+0 >= $_thr+0) ? \"yes\" : \"no\"}")
    if [ "$_passes" = "yes" ]; then
      _st=PASS; _rs=""
    else
      _st=FAIL; _rs="${_lpct}% < ${_thr}% threshold"
      printf '%s\n' "$_rs" > "$WORK/out"
      _log=$(_save_sidecar "$_pd" "$_lang" coverage)
    fi
  fi

  _t1=$(date +%s); _dur=$((_t1 - _t0))
  [ -n "$_lpct" ] && _detail="(${_lpct}% vs ${_thr}%, ${_dur}s)" || _detail="(${_dur}s)"
  _status_line "$_pd" "$_lang" "coverage" "$_st" "$_detail"
  _write_state "$_slug" "$_lang" "coverage" "$_st" "$_rs" "$_ex" "$_dur" "$_log"
  printf '%s' "${_lpct:-null}" > "$WORK/LPCT_${_slug}_${_lang}"
  printf '%s' "$_thr" > "$WORK/THR_${_slug}_${_lang}"
}

# ---------------------------------------------------------------------------
# RUN ALL GATES
# ---------------------------------------------------------------------------
while IFS='|' read -r _pd _lang; do
  [ -z "$_pd" ] && continue
  [ "$_pd" = "root" ] && _abs="$INVOCATION_DIR" || _abs="$INVOCATION_DIR/$_pd"

  printf '── [%s / %s] ──────────────────────────────────\n' "$_pd" "$_lang"
  _build   "$_pd" "$_abs" "$_lang"
  _test    "$_pd" "$_abs" "$_lang"
  _lint    "$_pd" "$_abs" "$_lang"
  _coverage "$_pd" "$_abs" "$_lang"
  printf '\n'
done < "$WORK/projects"

# ---------------------------------------------------------------------------
# JSON REPORT
# ---------------------------------------------------------------------------
if [ "$DRY_RUN" = "false" ]; then
  _ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%SZ')

  # Count totals
  _tp=0; _tg=0; _tpass=0; _tfail=0; _tskip=0; _op=true

  # Build projects JSON
  _proj_arr=""
  _pfirst=true
  while IFS='|' read -r _pd _lang; do
    [ -z "$_pd" ] && continue
    _tp=$((_tp + 1))
    _slug=$(_slug "$_pd")
    _gates_json=""
    _gfirst=true

    for _gate in build test lint coverage; do
      _tg=$((_tg + 1))
      _stf="$WORK/STATUS_${_slug}_${_lang}_${_gate}"
      _rsf="$WORK/REASON_${_slug}_${_lang}_${_gate}"
      _exf="$WORK/EXIT_${_slug}_${_lang}_${_gate}"
      _duf="$WORK/DUR_${_slug}_${_lang}_${_gate}"
      _lgf="$WORK/LOG_${_slug}_${_lang}_${_gate}"

      _gs=$(cat "$_stf" 2>/dev/null || printf 'SKIPPED')
      _rs=$(cat "$_rsf" 2>/dev/null || true)
      _ex=$(cat "$_exf" 2>/dev/null || printf 'null')
      _du=$(cat "$_duf" 2>/dev/null || printf '0')
      _lp=$(cat "$_lgf" 2>/dev/null || printf 'null')

      case "$_gs" in
        PASS)    _tpass=$((_tpass+1)) ;;
        FAIL)    _tfail=$((_tfail+1)); _op=false ;;
        SKIPPED) _tskip=$((_tskip+1)) ;;
      esac

      # JSON-escape reason
      _rs_j=$(_json_esc "$_rs")

      # Log file JSON value
      if [ "$_lp" = "null" ] || [ -z "$_lp" ]; then _lp_j="null"
      else _lp_j="\"$(_json_esc "$_lp")\""; fi

      # Reason JSON value
      if [ -z "$_rs_j" ]; then _rs_jv="null"; else _rs_jv="\"$_rs_j\""; fi

      _xtra=""
      if [ "$_gate" = "coverage" ]; then
        _lpct=$(cat "$WORK/LPCT_${_slug}_${_lang}" 2>/dev/null || printf 'null')
        _thr=$(cat "$WORK/THR_${_slug}_${_lang}" 2>/dev/null || printf '%s' "$COVERAGE_THRESHOLD")
        [ -z "$_lpct" ] && _lpct="null"
        _xtra=', "line_coverage_pct": '"$_lpct"', "branch_coverage_pct": null, "function_coverage_pct": null, "threshold_pct": '"$_thr"
      fi

      _ge='"'"$_gate"'": {"status": "'"$_gs"'", "duration_seconds": '"$_du"', "exit_code": '"$_ex"', "reason": '"$_rs_jv"', "log_file": '"$_lp_j$_xtra"'}'

      if [ "$_gfirst" = "true" ]; then _gates_json="$_ge"; _gfirst=false
      else _gates_json="$_gates_json, $_ge"; fi
    done

    _pe='{"project_dir": "'"$(_json_esc "$_pd")"'", "language": "'"$_lang"'", "gates": {'"$_gates_json"'}}'
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
fi

# ---------------------------------------------------------------------------
# SUMMARY TABLE
# ---------------------------------------------------------------------------
printf '\n'
printf '┌──────────────┬────────────┬───────────┬──────────┬────────────────────────────────────────────┐\n'
printf '│ %-12s │ %-10s │ %-9s │ %-8s │ %-42s │\n' "Project" "Language" "Gate" "Result" "Detail"
printf '├──────────────┼────────────┼───────────┼──────────┼────────────────────────────────────────────┤\n'

while IFS='|' read -r _pd _lang; do
  [ -z "$_pd" ] && continue
  _slug=$(_slug "$_pd")
  for _gate in build test lint coverage; do
    _stf="$WORK/STATUS_${_slug}_${_lang}_${_gate}"
    _rsf="$WORK/REASON_${_slug}_${_lang}_${_gate}"
    _gs=$(cat "$_stf" 2>/dev/null || printf 'SKIPPED')
    _rs=$(cat "$_rsf" 2>/dev/null || true)
    _detail=$(printf '%.42s' "$_rs")
    printf '│ %-12s │ %-10s │ %-9s │ %-8s │ %-42s │\n' \
      "$_pd" "$_lang" "$_gate" "$_gs" "$_detail"
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
