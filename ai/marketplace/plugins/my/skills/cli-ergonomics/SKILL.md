---
name: cli-ergonomics
description: Reviews and improves command-line ergonomics. Use when auditing or designing a CLI, command, help text, errors, flags, arguments, defaults, first-run flow, prompts, terminal output, or JSON and CI interfaces. Not for full-screen TUIs or backend-only reviews.
license: CC-BY-SA-4.0
---

# CLI ergonomics

Make the next action obvious to a human and the result dependable in a script.
Use `audit <target>` for evidence-backed review; `design <command>` for a proposed
interface. Natural-language requests work too. Audit is read-only; implement only
when requested.

## Context and references

Read repository guidance, command definitions, tests and user-facing docs. Identify
the primary user, task, supported shells/platforms, current command vocabulary and
compatibility/privacy promises. Reuse existing context; do not require new files.
Ask only about missing choices that materially affect the interface or behavior.

Load the references relevant to the task (all five for a broad audit):

| Area | Reference |
|---|---|
| Help, first-run, discovery | [Help](references/help.md) |
| Names, flags, arguments, defaults | [Interface](references/interface.md) |
| Humans, pipes, JSON, terminal rendering | [Output](references/output.md) |
| Errors, recovery, exit status | [Errors](references/errors.md) |
| Prompts, config, responsiveness, interruption | [Interaction](references/interaction.md) |

## Audit an existing CLI

1. Pin the source revision and binary/build provenance. Inspect side effects before
   running commands. Use scratch fixtures and offline/fake routes; record generated
   state. Do not exercise destructive or paid paths without existing authorization.
2. Walk the user's first task: top-level and relevant subcommand `--help`, a small
   success, a representative failure, missing input and an unknown flag.
3. Capture the exact invocation, working-directory context, stdin/TTY conditions,
   stdout, stderr and exit status separately. Use the advertised machine format
   (`-o json`, `--json`, etc.); parse the *whole* stream, not just a JSON-looking line.
4. Compare terminal and redirected/closed-stdin behavior where feasible. Record
   unexercised paths as **not tested**, not pass/fail. Trace findings to source and
   tests. A fixture cannot establish real-provider, platform or terminal behavior.
5. Apply the report contract below. Keep the highest-impact findings; don't fill a
   quota. Recognize sound behavior and intentional tradeoffs.

## Design a new command

Describe the user outcome and a concrete invocation before listing flags. Check
nearby commands for vocabulary and conventions. Specify help with examples,
inputs/defaults/precedence, stdout/stderr, exit status, TTY/noninteractive behavior,
and failure/recovery cases. Include the machine-output contract when useful.
Mark unapproved behavior as **proposed** and unknown product choices as **open**.
Preserve existing syntax, privacy and script contracts; explain migration when a
change is needed. Give acceptance checks, not just an attractive help mockup.

## Report contract

Lead with the user's blocked task and up to five prioritized findings, then details.
Use **P1** for task failure, broken automation or data risk; **P2** for recoverable
friction; **P3** for polish. Reserve **P0** for demonstrated catastrophic impact.
For each finding include:
- **Status:** observed / source-only / proposed; confidence and affected user.
- **Evidence:** invocation, relevant stdout/stderr/status, and `file:line`.
  If source is unavailable, name the captured output and say so; never invent lines.
- **Change:** exact current → replacement text (help/error/output), or a concrete
  before/after interface contract. Distinguish a copy fix from a behavior change.
- **Check:** a reproduction or acceptance test and compatibility/privacy tradeoff.

Finish with good patterns to preserve, coverage/not-tested paths and the next step.

Example: **P1 observed** `tool run demo --json` exits 0 but stdout is
`Starting…\n{"ok":true}\n`. At `cmd/run.go:44`, move `Starting…` from stdout to
stderr; keep stdout `{"ok":true}\n`. Check: parse all stdout as one JSON document.

## Common mistakes

A convention is a default, not a feature mandate. Don't add every possible flag,
replace established `-o json` with `--json`, infer prompting from help alone, or
expose private payloads to improve an error. Give exact changes, not “make clearer.”

[Sources, attribution and license](references/sources.md). The reference rules are
summaries, not a substitute for project-specific user decisions.
