# Human output, machine output and terminals

See sources C, H and T in [sources.md](sources.md).

## Rules

- Put the primary result on stdout; diagnostics, warnings and progress belong on
  stderr. Stderr is not synonymous with failure: exit status determines success.
- Give humans the useful result or state change, not only an internal ID. Keep
  action summaries brief. For privacy-sensitive tools, preserve opt-in payload
  display and make the opt-in discoverable rather than printing secrets by default.
- Use the tool's explicit structured-output mode for scripts. Check the entire
  stdout as JSON (or the documented JSONL stream), on success and failure.
  Banners, spinners and notices must not contaminate the format. Failure may leave
  stdout empty if that is the documented contract; do not demand a new envelope.
- Define stable machine fields, types and empty-result shapes. Do not truncate
  machine values to screen width. Keep script parsing independent of human prose.
- Keep plain text filterable: one record per line where useful, a small set of
  meaningful columns, and full values available through a documented format.
  Wrapped tables and decorative borders can defeat pipes. Add table controls only
  when the task needs them; every table does not need a flag suite.
- Detect terminal capability per output stream. A redirected stdout can coexist
  with terminal stderr. Suppress animation on nonterminal streams and in machine
  output. Let users disable decoration; respect nonempty `NO_COLOR` and `TERM=dumb`.
- Color and symbols should reinforce words, not be the only indication of failure.
  Check narrow terminals, no-color text and characters unavailable in a fallback font.
- Long output can use an optional pager only in an interactive context. Scripts
  must not get stuck in a pager, browser or editor.

## Review probes

Capture stdout and stderr separately, with stdin closed. Parse all structured
stdout. Compare with a real TTY where available; `COLUMNS=80` alone does not turn a
pipe into a terminal. Test no-color behavior separately from plain-output parsing.
Do not declare TTY, Windows or accessibility behavior passed from source alone.

## Change shape

For a mixed stream, name the exact line to move and the destination stream. For a
hidden result, decide whether to clarify its existing reveal flag or propose a
new human-mode default; the latter needs explicit compatibility/privacy analysis.
