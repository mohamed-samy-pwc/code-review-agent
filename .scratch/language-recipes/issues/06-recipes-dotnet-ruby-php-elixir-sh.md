# 06: Recipes: .NET, Ruby, PHP, Elixir (validate.sh)

**What to build:** The remaining four Languages move onto the gate runner as Language Recipes, preserving .NET restore-then-build, the unit-test scoping with full-suite fallbacks, and their skip reasons.

Parent spec: GitHub issue #7 (Spec: Language Recipes, gate runner and Gate Result record). Vocabulary follows `CONTEXT.md`. ADR-0001 (Hard Gate) and ADR-0002 (pinned report schema, no runtime dependencies) apply to every ticket. External behaviour must not change.

**Blocked by:** 03

**Status:** ready-for-agent

- [x] Each of the four Languages is a recipe that runs through the runner.
- [x] The ticket 01 tests for these Languages pass unchanged.
- [x] After this ticket, every Language in `validate.sh` runs through the runner.
- [x] Full harness passes.
