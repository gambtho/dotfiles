# Vekil Runtime Reliability Design

## Goal

Make Vekil lifecycle status truthful under termination failures and ensure an
interactive shell performs at most one readiness probe while preserving managed
environment and local override behavior.

## Scope

This wave changes `vekil-proxy stop` failure handling and the division of
responsibility between early and deferred Vekil shell initialization. Existing
host validation, token safety, PID start-identity checks, endpoint variables,
and systemd integration remain in place.

## Verified shutdown

Stopping uses the existing recorded PID and start identity throughout the
operation. The proxy first sends the graceful signal and waits to the configured
deadline. If the same recorded process remains, it sends SIGKILL and performs a
bounded confirmation wait.

The PID record is removed and `STOPPED` is printed only after the recorded
process no longer exists or no longer has the recorded start identity. If the
process survives, the command preserves the PID record, leaves the ready marker
absent, writes a mode-0600 `proxy-stop-failed` marker containing the recorded
process identity, emits an actionable failure, and returns nonzero. `status`
checks this marker before ordinary readiness classification and reports
`STOP_FAILED host=... port=... pid=...` while that same process remains alive,
even if the endpoint is still serving. A subsequent successful stop or start
removes the failure marker. A reused PID is never signalled or treated as the
original process.

Ownership is judged by PID plus recorded start identity, not by whether the
process still looks like Vekil. Termination and confirmation therefore continue
to track a recorded process that has `exec`ed into another program: it is still
the process this repository started and is still holding the port. The stricter
"is this Vekil" check remains only where the question is whether to adopt an
already-running proxy. PID reuse is still excluded, because a reused PID carries
a different start identity.

Graceful termination uses the existing `VEKIL_STOP_TIMEOUT` (default 15
seconds). Confirmation after SIGKILL uses a separate
`VEKIL_KILL_CONFIRM_TIMEOUT` with a 2-second default and a validated 0–30 second
range. A zero value performs one immediate identity check, which keeps failure
tests fast without skipping confirmation logic.

This behavior applies equally when invoked directly and through systemd. A
failed `ExecStop` therefore remains visible to the service manager instead of
silently orphaning the proxy.

## Single shell readiness probe

Early `.zshrc` loading remains authoritative because Codex needs managed Vekil
configuration before deferred customizations run. The later source in
`core/shell/load-custom.zsh` is unnecessary: it occurs before `.localrc`, does
not protect any intervening Vekil mutation, and only repeats initialization.
It will be removed. No exported or global initialization sentinel is introduced,
so child shells cannot inherit stale probe state; a deliberate manual source of
`env.zsh` still performs a fresh convergence check.

The implementation preserves these observable rules:

- one readiness curl per interactive shell initialization,
- safe repeated sourcing,
- local `.localrc` endpoint overrides win,
- managed variables are removed when Vekil becomes unavailable,
- `claude-direct`, `codex-direct`, and the managed Codex wrapper remain
  available and correct.

## Failure behavior

An unavailable endpoint must not abort shell startup. It clears only variables
that are proven to be Vekil-managed and leaves user-provided endpoint or API-key
values untouched. Re-sourcing after state changes must converge rather than
accumulate functions, PATH entries, or stale ownership markers.

## Testing

Lifecycle tests will cover graceful termination, forced termination, failed
SIGKILL or surviving process, PID reuse/start-identity change, PID-file and
failure-marker preservation, `STOP_FAILED` status, stale-marker cleanup, and
successful shutdown. Shell tests will create valid state files, stub curl,
count one readiness probe through normal `.zshrc` initialization, exercise
deliberate repeated sourcing, and verify `.localrc` precedence and
managed-variable cleanup.

## Compatibility and exclusions

No command names, environment variable names, ports, primary state directory,
or systemd unit interfaces change. The new failure marker is internal state;
`status` gains the explicit `STOP_FAILED` result described above. This wave does
not redesign the proxy lock, migrate the legacy LiteLLM cleanup, or change
readiness endpoint semantics.

Recovery remains idempotent: after correcting the condition that prevented
termination, rerunning `vekil-proxy stop` removes the preserved PID and failure
records only when the recorded process is gone. `restart` continues only after
stop succeeds.
