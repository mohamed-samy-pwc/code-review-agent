#!/usr/bin/env sh
# =============================================================================
# tests/run.sh — Universal Validation Script test harness
#
# Usage:   ./tests/run.sh [--verbose]
#
# How to add a new test case (3 steps):
#   1. exit_code=$(run_validate "$FIXTURES/<fixture>" [flags])
#   2. assert_exit_code <expected> "$exit_code" "<description>"
#   3. assert_json_field "$FIXTURES/<fixture>/validation-report.json" '"key"' <value> "<description>"
#      (or assert_file_exists <path> "<description>"), then run ./tests/run.sh.
#
# The harness uses only POSIX sh tools: grep, sed, cut — no jq required.
# =============================================================================

set -e

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VALIDATE_SH="$REPO_ROOT/validate.sh"
FIXTURES="$REPO_ROOT/fixtures"
VERBOSE=false

if [ "$1" = "--verbose" ]; then
  VERBOSE=true
fi

# ---------------------------------------------------------------------------
# Counters
# ---------------------------------------------------------------------------
PASS_COUNT=0
FAIL_COUNT=0
PENDING_COUNT=0

# ---------------------------------------------------------------------------
# Color helpers (suppressed when NO_COLOR is set)
# ---------------------------------------------------------------------------
_color() {
  if [ -z "${NO_COLOR:-}" ] && [ -t 1 ]; then
    printf '%b' "$1"
  fi
}
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
RESET='\033[0m'

# ---------------------------------------------------------------------------
# Core assertion helpers
# ---------------------------------------------------------------------------

# assert_exit_code <expected> <actual> <description>
assert_exit_code() {
  expected="$1"; actual="$2"; desc="$3"
  if [ "$actual" = "$expected" ]; then
    _color "$GREEN"; printf '  PASS'; _color "$RESET"
    printf ' exit_code=%s — %s\n' "$actual" "$desc"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    _color "$RED"; printf '  FAIL'; _color "$RESET"
    printf ' exit_code expected=%s got=%s — %s\n' "$expected" "$actual" "$desc"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

# _json_value <json_file> <pattern>
# The report may be single-line JSON, so match with grep -o rather than whole lines.
#   '"key"'           -> first scalar value of that key
#   '"key": "value"'  -> "value" if that exact pair appears anywhere, else "(absent)"
_json_value() {
  case "$2" in
    *:*)
      if grep -qF "$2" "$1"; then
        printf '%s' "$2" | sed 's/.*: *//;s/"//g'
      else
        printf '(absent)'
      fi ;;
    *)
      grep -o "$2 *: *[^,}]*" "$1" | head -1 | sed 's/.*: *//;s/"//g;s/ *$//' ;;
  esac
}

# assert_json_field <json_file> <field_grep_pattern> <expected_value> <description>
# Extracts the scalar value for field_grep_pattern via _json_value (see above).
assert_json_field() {
  json_file="$1"; pattern="$2"; expected="$3"; desc="$4"
  if [ ! -f "$json_file" ]; then
    _color "$RED"; printf '  FAIL'; _color "$RESET"
    printf ' %s not found — %s\n' "$json_file" "$desc"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    return
  fi
  actual=$(_json_value "$json_file" "$pattern")
  if [ "$actual" = "$expected" ]; then
    _color "$GREEN"; printf '  PASS'; _color "$RESET"
    printf ' %s="%s" — %s\n' "$pattern" "$actual" "$desc"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    _color "$RED"; printf '  FAIL'; _color "$RESET"
    printf ' %s expected="%s" got="%s" — %s\n' "$pattern" "$expected" "$actual" "$desc"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

# assert_json_field_contains <json_file> <field_grep_pattern> <substring> <description>
# Like assert_json_field but checks that the value contains a substring
assert_json_field_contains() {
  json_file="$1"; pattern="$2"; substring="$3"; desc="$4"
  if [ ! -f "$json_file" ]; then
    _color "$RED"; printf '  FAIL'; _color "$RESET"
    printf ' %s not found — %s\n' "$json_file" "$desc"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    return
  fi
  actual=$(grep -o "$pattern *: *\"[^\"]*\"" "$json_file" | sed 's/.*: *//;s/"//g')
  if printf '%s' "$actual" | grep -q "$substring"; then
    _color "$GREEN"; printf '  PASS'; _color "$RESET"
    printf ' %s contains "%s" — %s\n' "$pattern" "$substring" "$desc"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    _color "$RED"; printf '  FAIL'; _color "$RESET"
    printf ' %s="%s" does not contain "%s" — %s\n' "$pattern" "$actual" "$substring" "$desc"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

# assert_file_exists <path> <description>
assert_file_exists() {
  path="$1"; desc="$2"
  if [ -f "$path" ]; then
    _color "$GREEN"; printf '  PASS'; _color "$RESET"
    printf ' file exists: %s — %s\n' "$path" "$desc"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    _color "$RED"; printf '  FAIL'; _color "$RESET"
    printf ' file not found: %s — %s\n' "$path" "$desc"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

# assert_file_not_exists <path> <description>
assert_file_not_exists() {
  path="$1"; desc="$2"
  if [ ! -f "$path" ]; then
    _color "$GREEN"; printf '  PASS'; _color "$RESET"
    printf ' file absent (expected): %s — %s\n' "$path" "$desc"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    _color "$RED"; printf '  FAIL'; _color "$RESET"
    printf ' file exists but should not: %s — %s\n' "$path" "$desc"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

# pending <description>
# Marks a test case as not yet implemented (script not yet built)
pending() {
  desc="$1"
  _color "$YELLOW"; printf '  PENDING'; _color "$RESET"
  printf ' %s\n' "$desc"
  PENDING_COUNT=$((PENDING_COUNT + 1))
}

# ---------------------------------------------------------------------------
# Helper: run validate.sh against a fixture dir, return exit code
# Cleans up report/log artifacts in fixture dir before and after
# ---------------------------------------------------------------------------
run_validate() {
  fixture_dir="$1"
  shift
  flags="$*"

  # Remove stale artifacts from previous runs
  rm -f "$fixture_dir/validation-report.json"
  rm -rf "$fixture_dir/validation-logs"

  # Run the script; capture exit code without set -e aborting us
  actual_exit=0
  if [ -x "$VALIDATE_SH" ]; then
    # shellcheck disable=SC2086
    (cd "$fixture_dir" && sh "$VALIDATE_SH" $flags) > "${TMPDIR:-/tmp}/validate_stdout.$$" 2>&1 || actual_exit=$?
    if $VERBOSE; then
      cat "${TMPDIR:-/tmp}/validate_stdout.$$"
    fi
  else
    actual_exit=127  # script not found / not executable
  fi

  printf '%s' "$actual_exit"
}

# ---------------------------------------------------------------------------
# TEST SUITE
# ---------------------------------------------------------------------------

printf '\n'
_color "$RESET"
printf '══════════════════════════════════════════════════════════\n'
printf '  Universal Validation Script — Test Harness\n'
printf '══════════════════════════════════════════════════════════\n\n'

# ==========================================================================
# GROUP 1: no-signals fixture — exit code 2 (active from ticket 01)
# ==========================================================================
printf '── Group 1: no-signals (exit code 2) ──────────────────────\n'

exit_code=$(run_validate "$FIXTURES/no-signals")
assert_exit_code "2" "$exit_code" "no-signals fixture exits with code 2"

printf '\n'

# ==========================================================================
# GROUP 2: js-ts-passing — all four gates PASS (active from ticket 04)
# ==========================================================================
printf '── Group 2: js-ts-passing (all gates PASS) ─────────────────\n'

exit_code=$(run_validate "$FIXTURES/js-ts-passing")
REPORT="$FIXTURES/js-ts-passing/validation-report.json"

assert_exit_code "0" "$exit_code" "js-ts-passing exits 0"
assert_json_field "$REPORT" '"overall_pass"' "true" "overall_pass is true"
assert_json_field "$REPORT" '"validator_version"' "1.0.0" "validator_version is 1.0.0"
assert_json_field "$REPORT" '"status": "PASS"' "PASS" "at least one gate is PASS"

printf '\n'

# ==========================================================================
# GROUP 3: js-ts-test-fail — test gate FAIL, exit 1
# ==========================================================================
printf '── Group 3: js-ts-test-fail (test FAIL) ───────────────────\n'

exit_code=$(run_validate "$FIXTURES/js-ts-test-fail")
REPORT="$FIXTURES/js-ts-test-fail/validation-report.json"

assert_exit_code "1" "$exit_code" "js-ts-test-fail exits 1"
assert_json_field "$REPORT" '"overall_pass"' "false" "overall_pass is false"

printf '\n'

# ==========================================================================
# GROUP 4: js-ts-no-tests — test gate FAIL (no test files), exit 1
# ==========================================================================
printf '── Group 4: js-ts-no-tests (no test files → FAIL) ─────────\n'

exit_code=$(run_validate "$FIXTURES/js-ts-no-tests")
REPORT="$FIXTURES/js-ts-no-tests/validation-report.json"

assert_exit_code "1" "$exit_code" "js-ts-no-tests exits 1"
assert_json_field "$REPORT" '"overall_pass"' "false" "overall_pass is false"
assert_json_field_contains "$REPORT" '"reason"' "No test files" "reason mentions No test files"

printf '\n'

# ==========================================================================
# GROUP 5: js-ts-no-eslint-config — lint SKIPPED, overall PASS, exit 0
# ==========================================================================
printf '── Group 5: js-ts-no-eslint-config (lint SKIPPED) ─────────\n'

exit_code=$(run_validate "$FIXTURES/js-ts-no-eslint-config")
REPORT="$FIXTURES/js-ts-no-eslint-config/validation-report.json"

assert_exit_code "0" "$exit_code" "js-ts-no-eslint-config exits 0 (SKIPPED is not FAIL)"
assert_json_field "$REPORT" '"overall_pass"' "true" "overall_pass is true"

printf '\n'

# ==========================================================================
# GROUP 6: js-ts-low-coverage — coverage FAIL, exit 1
# ==========================================================================
printf '── Group 6: js-ts-low-coverage (coverage FAIL) ─────────────\n'

exit_code=$(run_validate "$FIXTURES/js-ts-low-coverage")
REPORT="$FIXTURES/js-ts-low-coverage/validation-report.json"

assert_exit_code "1" "$exit_code" "js-ts-low-coverage exits 1"
assert_json_field "$REPORT" '"overall_pass"' "false" "overall_pass is false"
assert_file_exists "$FIXTURES/js-ts-low-coverage/validation-logs/root-typescript-coverage.log" \
  "sidecar log written for coverage failure"

printf '\n'

# ==========================================================================
# GROUP 7: python-passing — all gates PASS or SKIPPED, exit 0
# ==========================================================================
printf '── Group 7: python-passing (all gates PASS/SKIPPED) ────────\n'

exit_code=$(run_validate "$FIXTURES/python-passing")
REPORT="$FIXTURES/python-passing/validation-report.json"

assert_exit_code "0" "$exit_code" "python-passing exits 0"
assert_json_field "$REPORT" '"overall_pass"' "true" "overall_pass is true"

printf '\n'

# ==========================================================================
# GROUP 8: monorepo — two projects detected, all gates PASS/SKIPPED, exit 0
# ==========================================================================
printf '── Group 8: monorepo (two projects detected) ───────────────\n'

exit_code=$(run_validate "$FIXTURES/monorepo")
REPORT="$FIXTURES/monorepo/validation-report.json"

assert_exit_code "0" "$exit_code" "monorepo exits 0"
assert_json_field "$REPORT" '"overall_pass"' "true" "overall_pass is true"
assert_json_field "$REPORT" '"total_projects"' "2" "summary.total_projects is 2"

printf '\n'

# ==========================================================================
# GROUP 9: --dry-run flag — no report written, exits 0
# ==========================================================================
printf '── Group 9: --dry-run flag ──────────────────────────────────\n'

DRY_REPORT="$FIXTURES/js-ts-passing/validation-report.json"
rm -f "$DRY_REPORT"
exit_code=$(run_validate "$FIXTURES/js-ts-passing" "--dry-run")

assert_exit_code "0" "$exit_code" "--dry-run exits 0"
assert_file_not_exists "$DRY_REPORT" "--dry-run does not write validation-report.json"

printf '\n'

# ==========================================================================
# GROUP 10: per-language coverage threshold via .validation.conf
# ==========================================================================
printf '── Group 10: per-language coverage threshold override ───────\n'

# Write a temporary .validation.conf with a low TypeScript threshold
printf 'COVERAGE_THRESHOLD_TYPESCRIPT=10\n' > "$FIXTURES/js-ts-low-coverage/.validation.conf"
exit_code=$(run_validate "$FIXTURES/js-ts-low-coverage")
REPORT="$FIXTURES/js-ts-low-coverage/validation-report.json"

assert_exit_code "0" "$exit_code" "low-coverage passes when COVERAGE_THRESHOLD_TYPESCRIPT=10"
assert_json_field "$REPORT" '"overall_pass"' "true" "overall_pass is true with low threshold"

# Clean up the override config
rm -f "$FIXTURES/js-ts-low-coverage/.validation.conf"

printf '\n'

# ==========================================================================
# GROUP 11: validate.ps1 parity with validate.sh (needs pwsh, else PENDING)
# ==========================================================================
printf '── Group 11: validate.ps1 parity with validate.sh ─────────\n'

# Reduce a report to the fields that must match across both scripts.
_report_signature() {
  grep -o '"\(validator_version\|overall_pass\|status\|total_projects\|total_gates_run\|passed\|failed\|skipped\)" *: *[^,}]*' "$1" | tr -d ' \n'
}

if command -v pwsh >/dev/null 2>&1; then
  for fx in js-ts-passing js-ts-test-fail js-ts-no-tests js-ts-no-eslint-config js-ts-low-coverage python-passing monorepo no-signals; do
    dir="$FIXTURES/$fx"
    sh_exit=$(run_validate "$dir")
    sh_sig=""; [ -f "$dir/validation-report.json" ] && sh_sig=$(_report_signature "$dir/validation-report.json")
    rm -rf "$dir/validation-report.json" "$dir/validation-logs"
    ps_exit=0
    (cd "$dir" && NO_COLOR=1 pwsh -NoProfile -File "$REPO_ROOT/validate.ps1") > /dev/null 2>&1 || ps_exit=$?
    ps_sig=""; [ -f "$dir/validation-report.json" ] && ps_sig=$(_report_signature "$dir/validation-report.json")
    assert_exit_code "$sh_exit" "$ps_exit" "validate.ps1 exit code matches validate.sh on $fx"
    if [ "$sh_sig" = "$ps_sig" ]; then
      _color "$GREEN"; printf '  PASS'; _color "$RESET"
      printf ' report signature matches on %s\n' "$fx"
      PASS_COUNT=$((PASS_COUNT + 1))
    else
      _color "$RED"; printf '  FAIL'; _color "$RESET"
      printf ' report signature differs on %s\n    sh: %s\n    ps: %s\n' "$fx" "$sh_sig" "$ps_sig"
      FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
  done
else
  pending "validate.ps1 parity (pwsh not installed)"
fi

printf '\n'

# ==========================================================================
# GROUP 12: hostile input — JSON escaping and config injection
# ==========================================================================
printf '── Group 12: JSON escaping and config injection ───────────\n'

# A directory name containing a double quote and a backslash must not break the report.
WEIRD_ROOT="$(mktemp -d)"
WEIRD_DIR="$WEIRD_ROOT/we\"ir\\d"
mkdir -p "$WEIRD_DIR"
cp -R "$FIXTURES/python-passing/." "$WEIRD_DIR/"
rm -f "$WEIRD_DIR/validation-report.json"
exit_code=0
(cd "$WEIRD_DIR" && sh "$VALIDATE_SH") > /dev/null 2>&1 || exit_code=$?
assert_exit_code "0" "$exit_code" "validate.sh runs in a directory whose name has quote and backslash"
if grep -qF '"invocation_dir": "'"$WEIRD_ROOT"'/we\"ir\\d"' "$WEIRD_DIR/validation-report.json" 2>/dev/null; then
  _color "$GREEN"; printf '  PASS'; _color "$RESET"; printf ' invocation_dir is JSON-escaped\n'
  PASS_COUNT=$((PASS_COUNT + 1))
else
  _color "$RED"; printf '  FAIL'; _color "$RESET"; printf ' invocation_dir is not JSON-escaped\n'
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi
rm -rf "$WEIRD_ROOT"

# A shell payload in .validation.conf must not execute; the script exits 2 (script error).
INJECT_MARK="$(mktemp -u)"
printf 'COVERAGE_THRESHOLD_TYPESCRIPT=1; touch %s\n' "$INJECT_MARK" > "$FIXTURES/js-ts-passing/.validation.conf"
exit_code=$(run_validate "$FIXTURES/js-ts-passing")
rm -f "$FIXTURES/js-ts-passing/.validation.conf"
assert_exit_code "2" "$exit_code" "non-numeric threshold in .validation.conf exits 2"
assert_file_not_exists "$INJECT_MARK" "config value is never executed"
rm -f "$INJECT_MARK"

# validate.ps1 must agree on the bad-config exit code.
if command -v pwsh >/dev/null 2>&1; then
  printf 'COVERAGE_THRESHOLD_TYPESCRIPT=1; touch x\n' > "$FIXTURES/js-ts-passing/.validation.conf"
  ps_exit=0
  (cd "$FIXTURES/js-ts-passing" && NO_COLOR=1 pwsh -NoProfile -File "$REPO_ROOT/validate.ps1") > /dev/null 2>&1 || ps_exit=$?
  rm -f "$FIXTURES/js-ts-passing/.validation.conf" "$FIXTURES/js-ts-passing/x"
  assert_exit_code "2" "$ps_exit" "validate.ps1: non-numeric threshold in .validation.conf exits 2"
else
  pending "validate.ps1 bad-config exit code (pwsh not installed)"
fi

printf '\n'

# ==========================================================================
# SUMMARY
# ==========================================================================
printf '══════════════════════════════════════════════════════════\n'
_color "$GREEN"; printf 'PASS: %d' "$PASS_COUNT"; _color "$RESET"
printf '  '
_color "$RED"; printf 'FAIL: %d' "$FAIL_COUNT"; _color "$RESET"
printf '  '
_color "$YELLOW"; printf 'PENDING: %d' "$PENDING_COUNT"; _color "$RESET"
printf '\n'
printf '══════════════════════════════════════════════════════════\n\n'

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
