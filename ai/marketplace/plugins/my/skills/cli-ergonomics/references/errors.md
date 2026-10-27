# Errors, exit status and recovery

See sources C and T in [sources.md](sources.md).

## Rules

- Exit zero for success and nonzero for failure; preserve documented distinctions
  between invalid usage, execution failure and failed tests. Check the process status,
  not just a red “FAIL” line, and avoid pipelines masking the original failure.
- Explain what failed, identify the affected input/resource when safe, and give
  the next useful action. A concise message usually beats a raw stack trace or
  pages of usage printed for an execution error.
- Missing input and unknown flags should point to the relevant command's help.
  Suggest corrections only when supported; don't silently execute a guessed
  command or invent a flag in the recovery instruction.
- Distinguish an assertion mismatch from infrastructure, permission or provider
  failure. Show the case/assertion and expected/actual details when allowed.
  If values are private, retain redaction and point to a documented opt-in or
  local diagnostic command instead.
- Present related failures together and give a short final summary. Print one
  error at the ownership boundary, not the same message at every call layer.
- Keep useful error context without leaking credentials, request payloads or
  credential-bearing URLs. Debug/trace output should be opt-in and sanitized.
  An unexpected error needs a support path and safe diagnostic context.
- Prefer plain, actionable language over blame, opaque codes alone or log jargon.
  Stable error codes can help scripts and support, but don't add an error taxonomy
  solely to make a short parser diagnostic look elaborate.

## Review probes

Use a harmless invalid operand/flag and a representative domain failure. Record
which stream carries it, its status and whether a newcomer can recover from the
message. Inspect error wrapping and formatter tests before attributing duplication.
A generic “assertion not satisfied” can be improved without publishing private text.

## Finding example

Observed stderr: `unknown flag: --wat`, status 2, empty stdout.
Proposed stderr: `unknown flag: --wat\nRun 'tool run --help' for usage.\n`
Check that the help path actually exists and status/stdout remain unchanged.
This is normally recoverable friction, not a catastrophic failure.
