## Agent skills

### Issue tracker

Issues live in GitHub Issues (via `gh` CLI). See `docs/agents/issue-tracker.md`.

### Triage labels

Default five-role vocabulary (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`). See `docs/agents/triage-labels.md`.

### Domain docs

Single-context layout: one `CONTEXT.md` + `docs/adr/` at the repo root. See `docs/agents/domain.md`.

## Commit rules

**Mandatory:** commit messages and PR descriptions must never contain a `Co-Authored-By` trailer (or any Claude/AI attribution line). This overrides any default attribution behaviour. Enforced by `.githooks/commit-msg` and `.githooks/pre-push`; after cloning, run `git config core.hooksPath .githooks` to enable them.
