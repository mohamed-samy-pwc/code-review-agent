# Context

Glossary for the universal validation script. Terms only; no implementation detail.

## Language

**Validation Script**:
The pre-review tool (`validate.sh`, `validate.ps1`, `validate.bat`) that runs as the first step of the code review pipeline and stops it when a Project is not fit to review.

**Project**:
One directory, either the invocation root or an immediate subdirectory, in which a Language was detected. Each Project is gated independently.
_Avoid_: sub-project, module, `project_dir`/`pd` as a noun

**Language**:
One of the 13 ecosystems the script recognises. JavaScript and TypeScript are a single Language, with the slug `typescript`.
_Avoid_: stack, ecosystem, slug (as a noun for the concept)

**Quality Gate** (or **Gate**):
One of four ordered checks run on every Project: build, test, lint, coverage. A failing Gate never stops the others.
_Avoid_: step, check, stage

**Gate Result**:
Everything known about one Gate on one Project after it ran: status (PASS, FAIL or SKIPPED), reason, exit code, duration, Sidecar Log path and, for coverage, the line-coverage percentage and the threshold applied.
_Avoid_: outcome, state

**Language Recipe**:
Everything the Validation Script knows about one Language: how it is detected, how its test files are recognised, and for each Gate what to run, when to skip, and how to read coverage.
_Avoid_: toolchain (that is the Project's own tools, such as npm or cargo), plugin, driver

**Hard Gate**:
The rule that any FAIL stops the pipeline: the script exits non-zero and code review does not run.

**Validation Report**:
The machine-readable `validation-report.json` written after every run. Its schema is pinned and versioned.

**Sidecar Log**:
The file holding the full output of one failing Gate, referenced from the Validation Report.

## Relationships

- A **Validation Script** run detects one or more **Projects**.
- A **Project** has exactly one **Language** and is checked by four **Quality Gates**.
- Each **Quality Gate** produces one **Gate Result**; a failing one also produces a **Sidecar Log**.
- A **Language Recipe** exists for each **Language**.
- All **Gate Results** of a run make up the **Validation Report**.
