# Validation script is a hard gate before code review

The universal validation script runs as the first step in the code review agent
pipeline. If any quality gate (build, test, lint, coverage) fails, the script exits
non-zero and the pipeline stops — code review does not proceed.

We chose hard-stop over soft-continue because the entire point of running validation
*before* review is to avoid spending review compute on code that is broken, untested,
or unlinted. A reviewer (human or agent) annotating style issues on code that does
not compile produces misleading feedback and wastes the review cycle entirely.

## Considered options

- **Soft continue**: exit non-zero but hand the report to the review agent anyway,
  letting it annotate failures alongside review comments. Rejected because it
  conflates two separate concerns (does the code work? is the code good?) and
  produces a noisy, hard-to-action review output.

- **Warn-only mode via flag**: add a `--warn-only` flag that downgrades failures to
  warnings so the pipeline continues. Rejected because the script is consumed by an
  automated pipeline with no operator at the keyboard; a flag that undermines the
  gate defeats the gate's purpose and will be cargo-culted into every repo's CI
  config within weeks.
