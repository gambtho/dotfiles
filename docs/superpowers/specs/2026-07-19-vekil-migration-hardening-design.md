# Vekil Migration Hardening Design

## Goal

Finish the Vekil proxy migration by closing the access-token symlink vulnerability and safely stopping repository-managed LiteLLM daemons left running from the previous implementation.

## Scope

This change modifies `bin/vekil-proxy` and `ai/vekil/install.sh`, adds focused shell regression harnesses, and updates the migration handoff. It does not remove LiteLLM binaries, configuration, logs, credentials, or other machine-local rollback data.

## Access-Token Safety

`bin/vekil-proxy` will centralize validation of `$VEKIL_TOKEN_DIR/access-token`:

- An absent token is valid where authentication may create it.
- An existing token must be a non-symlink regular file.
- Valid existing tokens are restricted to mode `0600`.
- `login` validates before invoking Vekil and validates the resulting token afterward.
- `start` validates before launching or accepting an existing Vekil process.
- `logout` validates before invoking Vekil and validates the resulting state afterward.
- Unsafe entries fail before Vekil is invoked.

An isolated fake-Vekil harness will prove that symlinked token entries are rejected for `login`, `start`, and `logout`, and that valid token permissions are corrected.

## Legacy LiteLLM Cleanup

`ai/vekil/install.sh` will perform automatic, idempotent cleanup of the two repository-managed legacy processes before starting Vekil:

| PID file | Expected port |
| --- | ---: |
| `~/.config/litellm/proxy.pid` | 4000 |
| `~/.config/litellm/codex-proxy.pid` | 4001 |

For each PID file, cleanup will:

1. Reject symlinked or non-regular PID files.
2. Parse a single positive integer PID.
3. Treat a missing or dead PID as stale and remove only the safe PID file.
4. Inspect the live process command.
5. Stop the process only when its start identity remains stable and its arguments identify a LiteLLM executable with both the literal legacy config path (or its resolved target when available) and the expected port.
6. Warn and preserve both process and PID file when identity cannot be proven.
7. Wait for graceful shutdown, then use a bounded force kill only after rechecking process identity.

The installer `--check` path will report the cleanup targets without mutating runtime state. The cleanup will not use broad `pkill` or name-only matching.

## Failure Behavior

Unsafe token state is fatal because continuing could overwrite an unrelated file or start with compromised credentials. Ambiguous legacy process identity is non-fatal: the installer warns, leaves the process untouched, and continues so an unrelated process cannot block Vekil installation.

## Verification

- Run token-safety regression harnesses against fake Vekil binaries.
- Run legacy-cleanup harnesses for matching, stale, malformed, symlinked, and mismatched PID state.
- Run Bash/zsh syntax checks and `git diff --check`.
- Run targeted Vekil and Codex installer dry runs.
- Run ShellCheck when available.
- Preserve the existing live host/devcontainer and client smoke tests as final machine-dependent verification.

## Exclusions

- Removing LiteLLM packages or cached credentials.
- Changing Vekil model selection, networking, or deferred response caching.
