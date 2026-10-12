# 07: Gate Result and Validation Report writer (validate.ps1)

**What to build:** The PowerShell script gets the same structure and names: a Gate Result record per Gate per Project and a report writer that owns the pinned schema, read by the report and the summary table.

Parent spec: GitHub issue #7 (Spec: Language Recipes, gate runner and Gate Result record). Vocabulary follows `CONTEXT.md`. ADR-0001 (Hard Gate) and ADR-0002 (pinned report schema, no runtime dependencies) apply to every ticket. External behaviour must not change.

**Blocked by:** 02

**Status:** ready-for-agent

- [x] Gate Results are `[pscustomobject]` records created once and read only by the report writer and the summary table.
- [x] `validation-report.json` from `validate.ps1` is identical to before for every fixture.
- [x] The strict sh-versus-ps1 parity group passes.
- [x] Full harness passes with pwsh installed.
