# Vekil Proxy Migration Handoff

## Status

This branch is a work in progress. It contains the recovered implementation
state from July 14, 2026, before the final security and migration-cleanup review
findings were addressed. Do not merge it as-is.

The approved design and execution plan are:

- `docs/superpowers/specs/2026-07-14-vekil-proxy-migration-design.md`
- `docs/superpowers/plans/2026-07-14-vekil-proxy-migration.md`

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

## Unresolved Findings

1. **High: lifecycle token symlink hardening**
   - `bin/vekil-proxy` validates the token directory but does not validate
     `$VEKIL_TOKEN_DIR/access-token` before the public `login`, `start`, and
     `logout` commands.
   - A malicious symlink can cause Vekil to overwrite the symlink target.
   - Centralize access-token validation and permission enforcement. Call it
     before and after `login`, before `start`, and around `logout` as
     appropriate. Add an isolated regression harness proving symlinks are
     rejected without invoking Vekil.

2. **Medium: legacy LiteLLM daemons survive repository deletion**
   - Existing LiteLLM processes on ports `4000` and `4001` can remain running
     after their scripts are removed.
   - Add an idempotent, identity-checked migration cleanup or retain a temporary
     stop path. Do not kill by loose name matching. Clean only known PID files
     whose process command matches the expected LiteLLM config and port.
   - Removing obsolete machine-local LiteLLM configuration and credentials
     should remain explicit and conservative.

3. **Medium, pre-existing: `make ai-check` is not side-effect free**
   - `ai/opencode/install.sh --check` attempts to remove existing OpenCode
     symlinks before its dry-run branch, so `make ai-check` can mutate state or
     fail on a read-only filesystem.
   - This predates the Vekil migration. Either fix the OpenCode installer as a
     separate focused change or avoid using the aggregate target for migration
     validation; the Codex and Vekil targeted `--check` commands pass.

4. **Operational caveat: device-flow browser launcher**
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

1. Fix the lifecycle access-token symlink vulnerability test-first.
2. Add identity-checked shutdown of legacy LiteLLM processes.
3. Re-run syntax, ShellCheck, installer harnesses, host/container networking,
   model catalog assertions, and both client smoke tests.
4. Run a final specification and security review.
5. Only then mark the migration complete and open a merge-ready pull request.

## Suggested Skills

- `superpowers:systematic-debugging`
- `superpowers:test-driven-development`
- `superpowers:verification-before-completion`
- `superpowers:requesting-code-review`
- `superpowers:finishing-a-development-branch`
