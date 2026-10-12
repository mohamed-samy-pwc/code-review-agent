# 10: Delete the old per-gate functions and plumbing (both scripts)

**What to build:** Remove the old per-gate functions and any leftover temp-file or slug plumbing from both scripts, leaving a single structure: detection, Language Recipes, one gate runner, Gate Results, report writer. Update the README to describe it.

Parent spec: GitHub issue #7 (Spec: Language Recipes, gate runner and Gate Result record). Vocabulary follows `CONTEXT.md`. ADR-0001 (Hard Gate) and ADR-0002 (pinned report schema, no runtime dependencies) apply to every ticket. External behaviour must not change.

**Blocked by:** 04, 05, 06, 09

**Status:** ready-for-agent

- [ ] No unreachable per-Language gate code or temp-file state plumbing remains in either script.
- [ ] The only `eval` in `validate.sh` is in the Gate Result setter and getter.
- [ ] README describes the Language Recipe structure and how to add a Language.
- [ ] Full harness passes with pwsh installed; `validation-report.json` is unchanged for every fixture.
