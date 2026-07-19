# Vekil Proxy Migration Handoff

## Status

This branch contains the recovered implementation state from July 14, 2026,
plus the security and migration-cleanup hardening completed on July 19, 2026.
Live validation still needs to be repeated on the current machine before merge.

The approved design and execution plan are:

- `docs/superpowers/specs/2026-07-14-vekil-proxy-migration-design.md`
- `docs/superpowers/plans/2026-07-14-vekil-proxy-migration.md`
- `docs/superpowers/specs/2026-07-19-vekil-migration-hardening-design.md`
- `docs/superpowers/plans/2026-07-19-vekil-migration-hardening.md`

## Implemented

- Added `ai/vekil/install.sh` with pinned Vekil `v0.13.3`, release checksum
  verification, atomic installation, Vekil-managed authentication, and durable
  restart recovery after first authentication.
- Added `bin/vekil-proxy` with Docker bridge binding, lifecycle locking,
  PID/process identity checks, bounded health/readiness probes, logs, model
  listing, and host/devcontainer environment output.
- Added `ai/vekil/env.zsh` with automatic host versus devcontainer endpoint
  selection and a managed Codex shell function that supplies Codex's
  `openai_base_url` override.
- Updated Codex to use Vekil's exact `gpt-5.6-sol` model ID and removed the
  LiteLLM provider block.
- Removed the repository-managed LiteLLM installer/configuration and the old
  `codex-proxy` and `copilot-proxy` lifecycle scripts.
- Hardened public Vekil lifecycle commands to reject symlinked or non-regular
  `access-token` entries before invoking Vekil, revalidate resulting token
  state, and enforce mode `0600` on valid token files.
- Added installer-time migration cleanup for the two known legacy LiteLLM PID
  files. Cleanup stops a process only when its PID start identity and arguments
  match LiteLLM, the legacy config path, and the expected port; ambiguous state
  is warned about and preserved.
- Kept legacy LiteLLM binaries, configuration, logs, and credentials untouched
  so rollback data is not removed implicitly.
- Updated `Makefile`, `README.md`, and `AGENTS.md` for Vekil ownership and
  standard `make ai` / `bin/install` discovery.
- Deferred full inference-response caching as documented in the design.

## Live Validation Completed

The following passed on the original machine before this handoff:

- Vekil listened on the Docker bridge at `172.17.0.1:1337`.
- Vekil-managed device authentication exposed `gpt-5.6-sol`,
  `gpt-5.6-terra`, `gpt-5.6-luna`, and `claude-opus-4.8`.
- A disposable devcontainer reached `host.docker.internal:1337/readyz` and
  selected the correct container endpoint.
- Claude Code returned exactly `VEKIL_CLAUDE_OK` through Vekil.
- Codex returned exactly `VEKIL_CODEX_OK` through Vekil's Responses endpoint.
- A second installer run reused managed authentication and left one healthy
  Vekil process.
- Installer regression harnesses passed for forced-auth restart, durable
  restart recovery, steady token refresh, and authentication failure.
- Bash/zsh syntax, ShellCheck excluding the repository's dynamic-source notice,
  `git diff --check`, targeted installer dry runs, and Codex strict config
  parsing passed.

The following focused regression harnesses passed on the current machine after
the July 19 hardening:

- `tests/vekil-proxy-token-safety.sh`
- `tests/vekil-installer-legacy-cleanup.sh`

Current-machine static validation also passed for Bash/zsh syntax, ShellCheck
with the repository's dynamic-source notice excluded, tracked and new-file
whitespace checks, Linux/macOS Vekil installer dry runs, and the Codex installer
dry run.

## Unresolved Findings

1. **Operational caveat: device-flow browser launcher**
   - On the original Linux desktop, Vekil's `xdg-open` child blocked the device
     flow until the code expired. Prepending a no-op `xdg-open` allowed the
     documented URL/code flow to complete.
   - Reproduce on the new machine before deciding whether the repository
     installer needs a managed no-browser helper.

## Runtime State Not In Git

The original machine has Vekil credentials under `~/.config/vekil/`, runtime
state under `~/.local/state/vekil/`, and the binary at `~/.local/bin/vekil`.
None of that transfers with this branch. Run `ai/vekil/install.sh` on the new
machine and complete GitHub device approval.

Do not copy tokens into the repository or the handoff.

## Recommended Next Steps

1. Re-run host/container networking, model catalog assertions, and both client
   smoke tests with machine-local Vekil authentication.
2. Reproduce the device-flow browser behavior on this machine.
3. Run a final specification and security review.
4. Only then mark the migration complete.

## Suggested Skills

- `superpowers:systematic-debugging`
- `superpowers:test-driven-development`
- `superpowers:verification-before-completion`
- `superpowers:requesting-code-review`
- `superpowers:finishing-a-development-branch`
