# 02: Gate Result and Validation Report writer (validate.sh)

**What to build:** Each Gate on each Project produces one Gate Result, stored once and read by exactly two consumers: the Validation Report writer and the summary table. Storage uses prefixed shell variables keyed by Project index and Gate name, with a single `eval` confined to one setter and one getter and a single quoting helper for values. The report writer owns the pinned schema, field order, null handling and JSON escaping. The temp files and the slug helper are removed from the reporting path.

Parent spec: GitHub issue #7 (Spec: Language Recipes, gate runner and Gate Result record). Vocabulary follows `CONTEXT.md`. ADR-0001 (Hard Gate) and ADR-0002 (pinned report schema, no runtime dependencies) apply to every ticket. External behaviour must not change.

**Blocked by:** 01

**Status:** ready-for-agent

- [ ] Gate Results are written once and read only by the report writer and the summary table.
- [ ] Variable names never contain directory names; the only `eval` in the script is in the setter and getter.
- [ ] `validation-report.json` is identical to before for every fixture (ignoring timestamp, duration and invocation directory).
- [ ] Hostile input tests (quotes and backslashes in the directory name, malicious config values) still pass.
- [ ] All ticket 01 tests and the full harness pass.
