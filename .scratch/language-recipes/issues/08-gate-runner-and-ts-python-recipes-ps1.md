# 08: Gate runner and TypeScript and Python recipes (validate.ps1)

**What to build:** The PowerShell gate runner and the first two Language Recipes (TypeScript and Python), mirroring the structure and names of `validate.sh` after ticket 03. Other Languages keep working through the old path.

Parent spec: GitHub issue #7 (Spec: Language Recipes, gate runner and Gate Result record). Vocabulary follows `CONTEXT.md`. ADR-0001 (Hard Gate) and ADR-0002 (pinned report schema, no runtime dependencies) apply to every ticket. External behaviour must not change.

**Blocked by:** 03, 07

**Status:** ready-for-agent

- [x] The runner enforces the no-test-files FAIL with the same reason text as `validate.sh`.
- [x] TypeScript and Python reports and Sidecar Logs from `validate.ps1` are identical to before.
- [x] Parity group passes for all fixtures.
- [x] Full harness passes with pwsh installed.
