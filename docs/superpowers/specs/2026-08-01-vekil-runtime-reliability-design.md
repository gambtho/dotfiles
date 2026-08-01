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
absent, emits an actionable failure, and returns nonzero. A reused PID is never
signalled or treated as the original process.

This behavior applies equally when invoked directly and through systemd. A
failed `ExecStop` therefore remains visible to the service manager instead of
silently orphaning the proxy.

## Single shell readiness probe

Early `.zshrc` loading remains authoritative because Codex needs managed Vekil
configuration before deferred customizations run. `ai/vekil/env.zsh` will expose
or honor an initialization marker so a second source during the same shell does
not repeat filesystem validation and the readiness curl.

Deferred `load-custom.zsh` retains the second source point only if it is needed
to reconcile variables after other customizations; otherwise it will omit it.
Whichever implementation is smallest must preserve these observable rules:

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
SIGKILL or surviving process, PID reuse/start-identity change, PID-file
preservation on failure, and successful cleanup. Shell tests will create valid
state files, stub curl, count readiness probes, exercise repeated sourcing, and
verify `.localrc` precedence and managed-variable cleanup.

## Compatibility and exclusions

No command names, environment variable names, ports, state paths, or systemd
unit interfaces change. This wave does not redesign the proxy lock, migrate the
legacy LiteLLM cleanup, or change readiness endpoint semantics.
