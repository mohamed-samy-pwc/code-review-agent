# 03: Gate runner and TypeScript and Python recipes (validate.sh)

**What to build:** A shared gate runner owns timing, status classification, Sidecar Log writing, dry-run and verbose handling and the Hard Gate rule that a Project with no test files fails its test Gate. A recipe reports an outcome through three helpers: run a command with a failure reason, skip with a reason, or pass. TypeScript and Python become Language Recipes, one function each answering `has_tests`, `build`, `test`, `lint` and `coverage`, and run through the runner. Other Languages keep working through the old path.

Parent spec: GitHub issue #7 (Spec: Language Recipes, gate runner and Gate Result record). Vocabulary follows `CONTEXT.md`. ADR-0001 (Hard Gate) and ADR-0002 (pinned report schema, no runtime dependencies) apply to every ticket. External behaviour must not change.

**Blocked by:** 02

**Status:** ready-for-agent

- [x] The runner enforces the no-test-files FAIL for recipe-based Languages with the existing reason text.
- [x] Recipes do not write files, time themselves or print status lines.
- [x] TypeScript and Python reports and Sidecar Logs are identical to before on all fixtures, including the monorepo.
- [x] Detection signals and test-file patterns for these two Languages live in their recipes.
- [x] Ticket 01 tests and the full harness pass; Languages not yet migrated are unaffected.
