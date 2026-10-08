# validation-report.json has a pinned, versioned schema

The validation script always writes `validation-report.json` to the invocation
directory. The schema is specified exactly in the prompt (field names, types, nesting,
nullability) and is not left to the code generator to decide. The script embeds a
`VALIDATOR_VERSION` constant that is echoed into the report under `"validator_version"`.

We pinned the schema because the downstream code review agent parses this file
directly. A schema chosen ad-hoc by a code generator is unstable: regenerating the
script with a different model or prompt version silently changes field names or
nesting, breaking the agent without any error at generation time.

## Consequences

- Any change to the schema requires a version bump in `VALIDATOR_VERSION` and a
  corresponding update to the consuming code review agent.
- The schema must be treated as a public contract, not an implementation detail of
  the script.

## Considered options

- **Let the generator decide the schema**: simpler prompt, but produces a different
  schema on every regeneration. Rejected.
- **Use a shared JSON Schema file**: more rigorous, but adds a validation dependency
  the script would need to resolve at runtime. Rejected — the script must have zero
  runtime dependencies beyond the project's own toolchain.
