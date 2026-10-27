# Prompts, configuration and responsiveness

See sources C, H and T in [sources.md](sources.md).

## Rules

- Prompt only when input is interactive. Every required answer must have a
  noninteractive route. With closed/nonterminal stdin, fail promptly with the missing
  input and the correct flag/config path rather than waiting indefinitely.
- Distinguish disabling prompts from approving an action. `--no-input` means never
  prompt; `--yes` means the documented consent, not permission for unrelated actions.
  Existing equivalent controls are fine; don't add flags when behavior already works.
- Scale confirmation to actual risk and the project's user decisions. Do not
  add confirmations to harmless actions or add refusal rules just from a checklist.
  Dry-run and explicit scope help risky changes; do not imply “dry-run” is offline
  or side-effect-free without examining its contract.
- Show what will change and how to cancel. Handle Ctrl-C promptly; bounded cleanup
  should explain any partial state and recovery. Don't blindly retry a mutation.
- Respond quickly, especially for help/version. Measure startup separately from
  real work; slow remote work needs timely stderr progress, not fake certainty.
  The 12 Factor timing ranges are heuristics, not universal release gates.
- Validate missing/invalid input before expensive work or mutations where practical.
  Use meaningful configurable deadlines for network work. Audit latency with actual
  timings; never fix a failure by just raising timeouts.
- Separate project config, user preferences, data and disposable caches. Follow XDG
  on compatible systems and native platform locations elsewhere; document overrides.
  Existing persisted locations need migration analysis before being moved.
- Honor relevant environment conventions (editor, pager, proxy, temp directory)
  through existing libraries. Show effective context/defaults without dumping the
  environment. Secrets belong in credential stores, files or protected input,
  not literal command arguments/history or diagnostic output.
- First run should explain required setup and external work; no surprise downloads,
  browser launches, telemetry or changes to unrelated files. Follow project consent
  policy rather than inventing a new policy during an ergonomics audit.

## Review probes

In scratch state, test missing input with stdin closed and the documented prompt
control. Record generated files and isolate the user's real credentials/config.
If no safe route exists, inspect source and mark the runtime case not tested.
For long-running fixtures, check interruption only when it is safe to cancel.
