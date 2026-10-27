# Names, inputs and defaults

See sources C, H and T in [sources.md](sources.md).

## Rules

- Keep names guessable, lowercase and consistent with neighboring commands.
  Use the same verb for the same action and the same flag for the same concept.
  A noun/verb hierarchy can help large tools; do not retrofit it just for style.
- Use a positional argument for an obvious primary subject or familiar file
  operation. Prefer named flags when several inputs have easily confused roles.
  `copy SOURCE DEST` is a familiar exception, not automatically a design defect.
- Give flags descriptive long forms; save short forms for frequent actions.
  Explain required values, units, repeatability, mutually exclusive choices and
  whether a flag is global or local. Reject unknown flags with useful guidance.
- Pick defaults for the primary task, not internal architecture. Check whether
  users must repeatedly supply the same corrective flag. Record any costs,
  network/provider choices or sensitive output affected by a new default.
- Keep established output syntax. `--json`, `--format json` and `-o json` can
  all be sound contracts; consistency within the tool beats adding synonyms.
  Do not repurpose an existing `-o` that means a file or a format.
- Support `--` for option-like operands where appropriate, and `-` for stdin/stdout
  when a file-oriented command can meaningfully stream. Don't require all inputs
  to be buffered merely to mimic a convention.
- Check flag placement around subcommands against the parser. Make common placements
  work when practical and document genuine restrictions.
- Stable explicit aliases can save typing. Inferred abbreviations or catch-all
  execution make future command additions ambiguous; favor an explicit contract.
- Document precedence: typically explicit flags, environment, project config, user
  config, then system defaults. Preserve a documented alternative deliberately.

## Review probes

Try a missing operand, an unknown flag, a value beginning with `-`, and conflicting
options, using harmless fixtures. Compare the same concept across two commands.
Trace defaults to parser/config code and test overrides.

## Design decisions to expose

For a new command, show the invocation, subject, optional controls and why they
match the user's task. Specify overwrite/bulk/remote behavior as a proposal, not
an assumption. Existing names, exit codes and machine fields are compatibility
surfaces: use the project's versioning policy and an actionable migration note.
