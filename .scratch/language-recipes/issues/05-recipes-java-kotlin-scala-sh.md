# 05: Recipes: Java, Kotlin, Scala (validate.sh)

**What to build:** Java, Kotlin and Scala move onto the gate runner as Language Recipes, preserving Maven and Gradle handling, Kotlin-versus-Java detection and the unit-test filters.

Parent spec: GitHub issue #7 (Spec: Language Recipes, gate runner and Gate Result record). Vocabulary follows `CONTEXT.md`. ADR-0001 (Hard Gate) and ADR-0002 (pinned report schema, no runtime dependencies) apply to every ticket. External behaviour must not change.

**Blocked by:** 03

**Status:** ready-for-agent

- [x] Each of the three Languages is a recipe that runs through the runner.
- [x] The ticket 01 tests for these Languages pass unchanged.
- [x] The old per-Language branches for them are no longer reachable.
- [x] Full harness passes.
