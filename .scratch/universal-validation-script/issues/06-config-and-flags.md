# 06: `.validation.conf` config, `--verbose` / `--dry-run` flags, and `.validation.conf.example`

**What to build:** Both `validate.sh` and `validate.ps1` fully honour the `.validation.conf` INI config file and the two supported CLI flags (`--verbose`, `--dry-run`). Per-language coverage thresholds (`COVERAGE_THRESHOLD_<LANG>`) override the global threshold per project. `--verbose` pipes full tool output to the terminal in addition to status lines. `--dry-run` prints every command that would be executed without running any of them. A `.validation.conf.example` file is produced. The validation pipeline is now fully complete and production-ready.

**Blocked by:** 04 — Lint and Coverage gates and final report (sh config), 05 — `validate.ps1` full parity (PS config)

**Status:** ready-for-agent

## Acceptance criteria

### `.validation.conf` parsing — both scripts

- [ ] Both `validate.sh` and `validate.ps1` read `.validation.conf` from the invocation directory if it exists. If absent, all defaults apply without error or warning.
- [ ] `COVERAGE_THRESHOLD=<n>` sets the global line coverage floor (default 80 when key is absent).
- [ ] `COVERAGE_THRESHOLD_<LANG>=<n>` (e.g. `COVERAGE_THRESHOLD_PYTHON=85`, `COVERAGE_THRESHOLD_TYPESCRIPT=70`) overrides the global threshold for that language only. Any language slug from the detection table is a valid key.
- [ ] `VERBOSE=true` in the config has the same effect as the `--verbose` CLI flag.
- [ ] CLI flags always override config file values — if `VERBOSE=false` is in the config but `--verbose` is passed on the command line, verbose mode is active.
- [ ] Lines starting with `#` in `.validation.conf` are treated as comments and ignored.
- [ ] Unknown config keys are silently ignored — the script does not error on unrecognised keys.

### Per-language threshold fixture test

- [ ] A fixture `fixtures/js-ts-low-coverage/` already exists (from ticket 01) with intentionally low coverage. Add a `.validation.conf` to that fixture setting `COVERAGE_THRESHOLD_TYPESCRIPT=50`. Running the script against that fixture now marks coverage PASS (because actual coverage ≥ 50%) and the JSON report shows `threshold_pct=50`.
- [ ] Removing the per-language override causes coverage FAIL again (actual coverage < 80% global default).

### `--verbose` flag — both scripts

- [ ] When `--verbose` is passed, the full stdout+stderr of every tool invocation is printed to the terminal as it runs, in addition to the live status lines.
- [ ] When `--verbose` is not passed, only the status lines and summary table are printed. Full output is still captured to sidecar logs on failure regardless of verbose mode.

### `--dry-run` flag — both scripts

- [ ] When `--dry-run` is passed, every command that would be executed is printed to the terminal (e.g. `[DRY RUN] npm run build`) but no subprocess is started.
- [ ] In dry-run mode, `validation-report.json` is not written and `./validation-logs/` is not created.
- [ ] Dry-run mode exits with code 0 regardless of what the commands would have returned.
- [ ] The startup header and detected project list are still printed in dry-run mode.

### `.validation.conf.example`

- [ ] A fully commented `.validation.conf.example` file is produced at the repo root.
- [ ] It documents every supported config key, its type, its default value, and a one-line description.
- [ ] It includes examples of per-language threshold overrides for at least three languages.

### Test harness assertions

- [ ] A new test case runs `validate.sh` against `fixtures/js-ts-low-coverage/` with a `.validation.conf` setting `COVERAGE_THRESHOLD_TYPESCRIPT=50` and asserts exit code 0, coverage=PASS, `threshold_pct=50` in the JSON report.
- [ ] A new test case runs `validate.sh --dry-run` against `fixtures/js-ts-passing/` and asserts: exit code 0, no `validation-report.json` written, no `./validation-logs/` created, DRY RUN lines present in terminal output.
- [ ] All previously passing harness assertions from tickets 01–05 continue to pass.
