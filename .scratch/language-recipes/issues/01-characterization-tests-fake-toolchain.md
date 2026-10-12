# 01: Characterization tests: fake toolchain for all 13 Languages

**What to build:** A test layer that runs the script against every Language without needing the real tools. Stub executables placed first on the PATH record the arguments they receive and exit with a configurable code, optionally printing canned coverage output. One tiny fixture per Language holds its signal file and one test file. Tests assert the exact command each Gate issued and the resulting Gate Result. All tests pass against the current, unrefactored code. `CONTEXT.md` is committed in this ticket.

Parent spec: GitHub issue #7 (Spec: Language Recipes, gate runner and Gate Result record). Vocabulary follows `CONTEXT.md`. ADR-0001 (Hard Gate) and ADR-0002 (pinned report schema, no runtime dependencies) apply to every ticket. External behaviour must not change.

**Blocked by:** None (can start immediately)

**Status:** ready-for-agent

- [x] Stub binaries exist for every tool the 13 Languages invoke, and log their arguments to a file the tests can read.
- [x] One fixture per Language (signal file plus one test file) is added; fixtures need no network and no installed toolchain.
- [x] For each Language, tests assert the exact command line issued for each Gate that runs a command, and the Gate Result status and reason for all four Gates.
- [x] Tests give the same result on a machine with none of the real tools installed.
- [x] The existing harness assertions, including parity and hostile-input groups, still pass.
- [x] `CONTEXT.md` is committed.
