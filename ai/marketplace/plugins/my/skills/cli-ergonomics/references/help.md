# Help, first-run and discovery

See sources H and C in [sources.md](sources.md).

## Rules

- Make `-h` and `--help` work at every relevant command level without login,
  network access or side effects. Keep `-h` reserved for help. A no-argument
  invocation that cannot do useful work should explain usage, not silently mutate.
- Lead with the task and one or two runnable examples. Explain what artifact a
  command creates or changes; distinguish creating a file from creating a service.
- Keep the common path visible before advanced deployment or administration.
  Group related commands by user task when an alphabetical wall hides the start.
- Show a synopsis, positional meanings, required inputs, useful defaults, allowed
  values and flag scope. Keep inherited flags from overwhelming the command.
- Make the first success reachable from help alone: prerequisites, a minimal
  command, expected result and the next useful action. Empty lists should distinguish
  “nothing exists” from “wrong project/account/filter.”
- Make the installed version easy to obtain through the established version command
  or flag, without authentication. Include it in useful support diagnostics.
- Link relevant docs and support from help. Local help should describe the installed
  version; web docs can explain advanced workflows. Completion aids discovery but
  does not replace help.
- Use concise, consistent verbs and concrete nouns; keep lines usable on a roughly
  80-column terminal. Test paths with spaces and examples in supported shells.
  Avoid assuming POSIX quoting works in PowerShell.

## Review probes

Read root and key subcommand help as a newcomer. Can the user tell what to type,
where to type it, what it affects, and what success looks like? Check `help COMMAND`
if the tool advertises it. Compare examples with parser tests, not just the docs.

## Change shape

Replace vague descriptions such as “Manage resources” with the actual user action
and artifact. Propose command reordering or renaming separately from a text edit;
help cannot promise a file creator when the command creates a remote resource.

Heroku's colon-separated topics and lowercase/no-period descriptions are house
style, not universal requirements. Match the host CLI.
