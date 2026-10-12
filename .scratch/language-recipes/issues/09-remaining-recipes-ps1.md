# 09: Remaining Language recipes (validate.ps1)

**What to build:** The other 11 Languages move onto the PowerShell runner as Language Recipes. The characterization tests from ticket 01 also run against `validate.ps1` (where pwsh is available), asserting the same commands and Gate Results as for `validate.sh`.

Parent spec: GitHub issue #7 (Spec: Language Recipes, gate runner and Gate Result record). Vocabulary follows `CONTEXT.md`. ADR-0001 (Hard Gate) and ADR-0002 (pinned report schema, no runtime dependencies) apply to every ticket. External behaviour must not change.

**Blocked by:** 04, 05, 06, 08

**Status:** ready-for-agent

- [x] Every Language in `validate.ps1` runs through the runner.
- [x] The ticket 01 tests run against both scripts and pass; they report PENDING, not FAIL, when pwsh is absent.
- [x] Parity group passes.
- [x] Full harness passes with pwsh installed.
