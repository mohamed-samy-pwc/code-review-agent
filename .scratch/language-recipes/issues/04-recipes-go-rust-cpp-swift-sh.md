# 04: Recipes: Go, Rust, C/C++, Swift (validate.sh)

**What to build:** Go, Rust, C/C++ and Swift move onto the gate runner as Language Recipes, preserving their unit-test scoping (`-short`, `--lib`), the Rust coverage fallbacks and their skip reasons.

Parent spec: GitHub issue #7 (Spec: Language Recipes, gate runner and Gate Result record). Vocabulary follows `CONTEXT.md`. ADR-0001 (Hard Gate) and ADR-0002 (pinned report schema, no runtime dependencies) apply to every ticket. External behaviour must not change.

**Blocked by:** 03

**Status:** ready-for-agent

- [x] Each of the four Languages is a recipe that runs through the runner.
- [x] The ticket 01 tests for these Languages pass unchanged.
- [x] The old per-Language branches for them are no longer reachable.
- [x] Full harness passes.
