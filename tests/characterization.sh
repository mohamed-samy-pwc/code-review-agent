# =============================================================================
# tests/characterization.sh — fake-toolchain characterization tests
#
# Sourced by tests/run.sh (uses its assert counters and colour helpers).
#
# Seam: run the validation script as a black box in a throwaway Project and
# record (a) the exact commands each Gate issued, read from a log written by
# stub executables on the PATH, and (b) each Gate's status and reason, read from
# validation-report.json. Both are compared with a golden file in tests/golden/.
#
# Nothing here needs a real toolchain: the PATH holds only the stubs and a
# directory of symlinks to the system utilities the script itself uses.
#
# Scenarios, run for each of the 13 Languages:
#   ok       every tool exists and exits 0 (some print canned coverage output)
#   missing  no tools exist at all
#   fail     every tool exists and exits 1
#
# Regenerate golden files after an intended behaviour change, then review the diff:
#   UPDATE_GOLDEN=1 ./tests/run.sh
#
# Add a Language: add a line to CHAR_LANGS and a case to _char_make_project and
# _char_canned_output below, then run with UPDATE_GOLDEN=1 and review the files.
# =============================================================================

CHAR_LANGS="typescript python java kotlin go rust dotnet ruby php swift cpp elixir scala"
CHAR_SCENARIOS="ok missing fail"
GOLDEN_DIR="$REPO_ROOT/tests/golden"

# Utilities validate.sh itself needs; linked into an otherwise empty bin dir so
# that no real build tool (python3, make, swift, ...) can be found by accident.
_CHAR_SYSTOOLS="sh grep sed awk find date mktemp cat cp rm mkdir tr head tail basename dirname ls tee wc cut sort uname expr env test true false touch"

_char_make_stub() { # <path>   (the stub's file name is the tool name it impersonates)
  cat > "$1" <<'STUB'
#!/bin/sh
_n=$(basename "$0")
printf '%s %s\n' "$_n" "$*" >> "$STUB_LOG"
# A real build writes its coverage report during the run; refresh the fixture's report the same way.
[ -n "${STUB_TOUCH:-}" ] && [ -f "$STUB_TOUCH" ] && touch "$STUB_TOUCH"
[ -f "$STUB_DIR/$_n.out" ] && cat "$STUB_DIR/$_n.out"
if [ -f "$STUB_DIR/$_n.exit" ]; then exit "$(cat "$STUB_DIR/$_n.exit")"; fi
exit 0
STUB
  chmod +x "$1"
}

# Canned stdout for the tools whose output the coverage Gate parses.
_char_canned_output() { # <lang> <stub dir> <project dir>
  case "$1" in
    typescript) printf 'All files | 90 | 80 | 70 | 85 |\n' > "$2/npm.out" ;;
    python)     printf 'TOTAL    142    12    92%%\n' > "$2/python3.out" ;;
    go)         printf 'total:\t(statements)\t91.2%%\n' > "$2/go.out" ;;
    rust)       printf 'TOTAL    100    15    85.00%%\n' > "$2/cargo.out" ;;
    php)        printf 'Lines:   91.00%% (10/11)\n' > "$2/phpunit.out" ;;
    elixir)     printf '88.00%% | Total\n' > "$2/mix.out" ;;
    ruby)       printf 'Line coverage: 90 / 100 (90.00%%)\n' > "$2/bundle.out" ;;
    dotnet)     printf 'Attachments:\n  %s/TestResults/g/coverage.cobertura.xml\n' "$3" > "$2/dotnet.out" ;;
  esac
}

# Tools each Language may call on the PATH.
_char_path_tools() { # <lang>
  case "$1" in
    typescript) echo "npm" ;;
    python)     echo "python3 ruff" ;;
    java)       echo "mvn" ;;
    kotlin)     echo "" ;;
    go)         echo "go golangci-lint" ;;
    rust)       echo "cargo" ;;
    dotnet)     echo "dotnet" ;;
    ruby)       echo "bundle" ;;
    php)        echo "composer" ;;
    swift)      echo "swift swiftlint" ;;
    cpp)        echo "cmake ctest clang-tidy" ;;
    elixir)     echo "mix" ;;
    scala)      echo "sbt" ;;
  esac
}

# Create a minimal Project for <lang> in <dir>. With <local>=yes also create the
# executables that live inside the project (wrappers, node_modules/.bin, vendor/bin).
_char_make_project() { # <lang> <dir> <local yes|no>
  _l="$1"; _d="$2"; _loc="$3"
  mkdir -p "$_d"
  case "$_l" in
    typescript)
      printf '{"name":"t","scripts":{"build":"true","test":"jest"}}\n' > "$_d/package.json"
      : > "$_d/a.test.ts"; : > "$_d/eslint.config.js"
      if [ "$_loc" = yes ]; then mkdir -p "$_d/node_modules/.bin"; _char_make_stub "$_d/node_modules/.bin/eslint"; fi ;;
    python) : > "$_d/pyproject.toml"; : > "$_d/test_a.py" ;;
    java)
      : > "$_d/pom.xml"; mkdir -p "$_d/src/test" "$_d/target/site/jacoco"; : > "$_d/src/test/A.java"
      printf '<counter type="LINE" missed="10" covered="90"/>\n' > "$_d/target/site/jacoco/jacoco.xml"
      if [ "$_loc" = yes ]; then _char_make_stub "$_d/mvnw"; fi ;;
    kotlin)
      printf 'plugins { id("org.jlleitschuh.gradle.ktlint") }\n' > "$_d/build.gradle.kts"; mkdir -p "$_d/src/test" "$_d/build/reports/jacoco/test"; : > "$_d/src/test/A.kt"
      printf '<counter type="LINE" missed="20" covered="80"/>\n' > "$_d/build/reports/jacoco/test/jacocoTestReport.xml"
      if [ "$_loc" = yes ]; then _char_make_stub "$_d/gradlew"; fi ;;
    go)     : > "$_d/go.mod"; : > "$_d/a_test.go" ;;
    rust)   : > "$_d/Cargo.toml"; mkdir -p "$_d/src"; printf '#[cfg(test)]\n' > "$_d/src/lib.rs" ;;
    dotnet)
      : > "$_d/app.csproj"; : > "$_d/ATests.cs"; mkdir -p "$_d/TestResults/g"
      printf '<coverage line-rate="0.88" lines-covered="88" lines-valid="100" version="1.9">\n' > "$_d/TestResults/g/coverage.cobertura.xml" ;;
    ruby)   printf "gem 'rubocop'\n" > "$_d/Gemfile"; : > "$_d/a_spec.rb"; printf 'task :build\n' > "$_d/Rakefile" ;;
    php)
      printf '{}\n' > "$_d/composer.json"; : > "$_d/ATest.php"
      if [ "$_loc" = yes ]; then
        mkdir -p "$_d/vendor/bin"; _char_make_stub "$_d/vendor/bin/phpunit"; _char_make_stub "$_d/vendor/bin/phpstan"
      fi ;;
    swift)  : > "$_d/Package.swift"; : > "$_d/ATests.swift" ;;
    cpp)    : > "$_d/CMakeLists.txt"; : > "$_d/a_test.cpp"; printf 'Checks: "-*,bugprone-*"\n' > "$_d/.clang-tidy" ;;
    elixir) printf '{:credo, "~> 1.7"}\n' > "$_d/mix.exs"; : > "$_d/a_test.exs" ;;
    scala)  printf 'addSbtPlugin("org.scalastyle" %% "scalastyle-sbt-plugin" %% "1.0.0")\n' > "$_d/build.sbt"; mkdir -p "$_d/src/test"; : > "$_d/src/test/A.scala" ;;
  esac
}

# Reduce validation-report.json to one stable line per Gate (no durations/paths).
_char_gate_lines() { # <report>
  # Flatten first: validate.ps1 pretty-prints its JSON over many lines.
  tr -d '\r\n' < "$1" | sed -e 's/  */ /g' -e 's/{ /{/g' -e 's/ }/}/g' | \
    grep -o '"\(build\|test\|lint\|coverage\)": {"status": "[A-Z]*"[^}]*}' | \
    sed -E 's/^"([a-z]+)": \{"status": "([A-Z]+)", "duration_seconds": [0-9.]+, "exit_code": ([^,]+), "reason": (.*), "log_file": ([^,}]*)(, "line_coverage_pct": ([^,]+), [^}]*"threshold_pct": ([0-9.]+))?.*/\1 \2 exit=\3 reason=\4 log=\5 line_pct=\7 threshold=\8/' | \
    sed -E -e 's/(line_pct=[0-9]+)\.0+ /\1 /' -e 's/(line_pct=[0-9]+\.[0-9]*[1-9])0+ /\1 /'
}

# Run one Language in one scenario; print the observed behaviour on stdout.
_char_observe() { # <lang> <scenario> <script command...>
  _l="$1"; _s="$2"; shift 2
  _root="$CHAR_ROOT/$_l.$_s"
  _fix="$_root/project"; _stubs="$_root/bin"; _sdir="$_root/stubdata"
  rm -rf "$_root"; mkdir -p "$_stubs" "$_sdir"
  STUB_LOG="$_root/calls.log"; : > "$STUB_LOG"
  STUB_DIR="$_sdir"
  case "$_l" in
    java)   STUB_TOUCH="$_fix/target/site/jacoco/jacoco.xml" ;;
    kotlin) STUB_TOUCH="$_fix/build/reports/jacoco/test/jacocoTestReport.xml" ;;
    *)      STUB_TOUCH="" ;;
  esac
  export STUB_LOG STUB_DIR STUB_TOUCH

  case "$_s" in
    missing) _char_make_project "$_l" "$_fix" no ;;
    *)       _char_make_project "$_l" "$_fix" yes
             for _t in $(_char_path_tools "$_l"); do _char_make_stub "$_stubs/$_t"; done
             _char_canned_output "$_l" "$_sdir" "$_fix"
             if [ "$_s" = fail ]; then
               for _t in $(_char_path_tools "$_l") mvnw gradlew eslint phpunit phpstan; do printf '1\n' > "$_sdir/$_t.exit"; done
             fi ;;
  esac

  _exit=0
  (cd "$_fix" && PATH="$_stubs:$CHAR_SYSBIN" NO_COLOR=1 "$@") > "$_root/stdout" 2>&1 || _exit=$?

  printf 'exit %s\n' "$_exit"
  printf 'calls:\n'
  sed -e "s|/private$_fix|<DIR>|g" -e "s|$_fix|<DIR>|g" -e 's|[^ =]*/cov\.out|<WORK>/cov.out|g' "$STUB_LOG"
  printf 'gates:\n'
  if [ -f "$_fix/validation-report.json" ]; then _char_gate_lines "$_fix/validation-report.json"
  else printf '(no report)\n'; fi
}

run_characterization() { # <label> <script command...>
  _label="$1"; shift
  printf '── Group 13: fake-toolchain characterization (%s) ─────────\n' "$_label"

  CHAR_ROOT="$(mktemp -d)"; CHAR_SYSBIN="$CHAR_ROOT/sysbin"; mkdir -p "$CHAR_SYSBIN" "$GOLDEN_DIR"
  for _t in $_CHAR_SYSTOOLS; do
    _p=$(command -v "$_t" 2>/dev/null || true)
    case "$_p" in /*) ln -s "$_p" "$CHAR_SYSBIN/$_t" ;; esac
  done

  for _l in $CHAR_LANGS; do
    for _s in $CHAR_SCENARIOS; do
      _gold="$GOLDEN_DIR/$_l.$_s.txt"
      _got="$CHAR_ROOT/$_l.$_s.observed"
      _char_observe "$_l" "$_s" "$@" > "$_got"
      if [ -n "${UPDATE_GOLDEN:-}" ] && [ "$_label" = "validate.sh" ]; then
        cp "$_got" "$_gold"
        pending "$_l/$_s golden file written"
      elif [ ! -f "$_gold" ]; then
        _color "$RED"; printf '  FAIL'; _color "$RESET"; printf ' %s/%s: no golden file (run with UPDATE_GOLDEN=1)\n' "$_l" "$_s"
        FAIL_COUNT=$((FAIL_COUNT + 1))
      elif diff "$_gold" "$_got" > "$CHAR_ROOT/diff" 2>&1; then
        _color "$GREEN"; printf '  PASS'; _color "$RESET"; printf ' %s/%s commands and Gate Results match golden\n' "$_l" "$_s"
        PASS_COUNT=$((PASS_COUNT + 1))
      else
        _color "$RED"; printf '  FAIL'; _color "$RESET"; printf ' %s/%s differs from golden:\n' "$_l" "$_s"
        sed 's/^/      /' "$CHAR_ROOT/diff" | head -20
        FAIL_COUNT=$((FAIL_COUNT + 1))
      fi
    done
  done
  rm -rf "$CHAR_ROOT"
  printf '\n'
}
