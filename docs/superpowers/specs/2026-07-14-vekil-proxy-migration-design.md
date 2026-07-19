# Vekil Proxy Migration Design

## Summary

Replace the two LiteLLM-backed proxy commands, `bin/codex-proxy` and
`bin/copilot-proxy`, with one repository-managed Vekil installation and one
lifecycle command, `bin/vekil-proxy`.

Vekil will expose GitHub Copilot models through one local endpoint for both
Codex and Claude Code. The dotfiles repository remains the source of truth for
installation, configuration, startup, and client integration. Machine-local
credentials and runtime files remain outside Git because they contain secrets
or ephemeral state, but repository scripts create and manage them.

## Goals

- Replace LiteLLM with Vekil for GitHub Copilot-backed model access.
- Serve Codex and Claude Code from one Vekil process and one port.
- Install and start Vekil through the existing `make ai` and `bin/install`
  flows.
- Make the proxy reachable from frequently used devcontainers without binding
  to every host network interface.
- Preserve the useful lifecycle and diagnostic commands from the existing
  scripts.
- Keep migration reversible until live Claude and Codex requests succeed.

## Non-Goals

- Adding full inference-response caching.
- Introducing Redis or another persistent proxy dependency.
- Running Vekil in Docker.
- Adding a general-purpose AI gateway or multi-tenant control plane.
- Migrating GitHub Copilot credentials from LiteLLM's private cache format.

## Current State

The repository currently runs two LiteLLM processes against one shared model
configuration:

- `bin/copilot-proxy` serves Claude Code on port `4000` through the Anthropic
  Messages API.
- `bin/codex-proxy` serves Codex on port `4001` through the OpenAI Responses
  API.
- `ai/litellm/config.yaml` defines aliases for Claude, OpenAI, Gemini, and
  Microsoft models backed by GitHub Copilot.
- `ai/litellm/install.sh` installs LiteLLM with `uv`, links its configuration,
  and leaves the first Copilot OAuth flow as a separate manual step.
- `ai/codex/config.toml` points Codex at the LiteLLM process.

This duplicates lifecycle management, starts a large Python proxy twice, and
requires LiteLLM-specific authentication and model configuration even though
the only upstream is GitHub Copilot.

## Selected Solution

Use the native Vekil binary in zero-config GitHub Copilot mode.

Vekil is purpose-built for this client combination. It provides GitHub device
authentication, Copilot token caching and refresh, required Copilot request
headers, dynamic model discovery, Anthropic Messages translation, OpenAI
Responses support, and Codex compatibility shims.

One Vekil process will listen on port `1337`. Both clients will select models
from Vekil's dynamic `/v1/models` catalog rather than a repository-maintained
alias list.

## Repository Layout

### `ai/vekil/install.sh`

The installer is the canonical installation entry point and follows the same
pattern as the other directories under `ai/`.

Responsibilities:

- Pin the supported Vekil version in the repository.
- Detect the operating system and architecture.
- Download the corresponding release binary and published checksum.
- Verify the checksum before installation.
- Install or upgrade `vekil` under `~/.local/bin`.
- Invoke `bin/vekil-proxy start` so installation and startup remain
  repository-managed.
- Remain idempotent when the requested version is already installed.
- Produce actionable warnings when network access, checksum verification, or
  installation fails.

The existing `Makefile` and `bin/install` automatically execute
`ai/*/install.sh`, so no new top-level bootstrap command is required.

### `bin/vekil-proxy`

This becomes the only user-facing proxy lifecycle command. It is directly
available because the repository's shell configuration already includes
`~/.dotfiles/bin` in `PATH`.

Supported commands:

- `install`: delegate to `ai/vekil/install.sh`.
- `login`: run Vekil's managed Copilot login flow.
- `logout`: clear Vekil-managed Copilot authentication.
- `start`: detect networking, start Vekil, and wait for readiness.
- `stop`: gracefully terminate the tracked Vekil process.
- `restart`: stop and start the process.
- `status`: report PID, bind address, port, health, and readiness.
- `env`: print host and devcontainer client configuration.
- `logs`: follow the Vekil log.
- `models`: list model IDs from `/v1/models`.

With no arguments, the command will ensure Vekil is running and print the
client environment, matching the convenience of the current scripts.

### `ai/vekil/env.zsh`

The repository's shell loader automatically sources every `*.zsh` file under
the dotfiles tree. A Vekil environment file will therefore configure clients
without requiring `eval`, copied exports, or per-machine shell edits.

Responsibilities:

- On the host, read the selected listener from
  `~/.local/state/vekil/proxy-host`.
- Inside a container, use `host.docker.internal`.
- Export `OPENAI_BASE_URL`, `OPENAI_API_KEY`, `ANTHROPIC_BASE_URL`, and
  `ANTHROPIC_API_KEY` for diagnostics and Claude Code.
- Define a managed `codex` shell function that passes Codex's documented
  `openai_base_url` config override using the selected host or container URL.
- Export repository-selected default model IDs while allowing an existing
  explicit user value to take precedence.
- Do nothing when no Vekil listener state exists, avoiding broken client
  configuration before installation.

### Runtime Files

Machine-local runtime files will live under `~/.local/state/vekil/`:

- `proxy.pid`
- `proxy.log`
- `proxy-host`

Vekil credentials remain under its standard `~/.config/vekil/` directory.
These files are not linked into the repository because they contain credentials
or ephemeral state. Their creation and use are controlled exclusively by the
repository installer and lifecycle script.

## Networking

### Host Selection

The lifecycle script chooses one listen address in this order:

1. An explicit non-empty `VEKIL_HOST` override.
2. The gateway returned by `docker network inspect bridge` on Linux or WSL.
3. `127.0.0.1` when Docker is unavailable or no usable bridge gateway exists.

`VEKIL_PORT` overrides the default port `1337`.

The detected host is written to `~/.local/state/vekil/proxy-host` so `status`,
`env`, and `models` address the same listener that `start` created.

### Security

Automatic detection must never select `0.0.0.0` or `::`. Binding to all
interfaces is permitted only through an explicit `VEKIL_HOST` override and
must print a warning because Vekil's client-facing inference and dashboard
routes are unauthenticated.

On Linux and WSL, binding to the Docker bridge gateway makes the proxy
reachable through `host.docker.internal` while avoiding exposure on the host's
LAN interfaces. On macOS, where Docker Desktop provides its own host bridge,
loopback remains the default unless explicitly overridden.

If Docker is unavailable during startup, Vekil starts on loopback and warns
that devcontainer access requires restarting the proxy after Docker becomes
available.

### Client Addresses

- Host clients use the detected address recorded in `proxy-host`, for example
  `http://172.17.0.1:1337`.
- Devcontainers use `http://host.docker.internal:1337`.
- Compose-based devcontainers continue declaring
  `host.docker.internal:host-gateway`, following the existing repository
  convention.

## Authentication

The installer starts Vekil after installing it. When no reusable Copilot
credential exists, Vekil initiates its device-code login flow. OAuth approval
is the only unavoidable interactive part of first-machine setup; users do not
need to remember or run a separate repository-specific authentication command.

The installer uses Vekil-managed authentication rather than the raw GitHub CLI
OAuth token. A missing token triggers Vekil's forced device-code flow; an
existing managed token is refreshed normally. Creating a new managed token
durably records that the running proxy must restart before the installer can
report success.

The old LiteLLM credential directory is left untouched during validation so a
rollback remains possible. Vekil creates and refreshes its own credentials in
`~/.config/vekil`.

## Codex Configuration

Update `ai/codex/config.toml` to stop selecting the LiteLLM provider and use
Vekil's exact model ID:

```toml
model = "gpt-5.6-sol"
```

Codex requires a non-empty API key even though Vekil does not authenticate
local clients, so the shell environment exports `OPENAI_API_KEY=dummy`. Codex
does not read `OPENAI_BASE_URL` for provider routing, so `ai/vekil/env.zsh`
defines a managed shell function that invokes the real CLI with
`-c openai_base_url=...`. On the host the override uses the detected listener;
inside a devcontainer it uses `http://host.docker.internal:1337/v1`.

This keeps `ai/codex/config.toml` static and symlinked while all machine-specific
network selection remains in repository-managed shell logic.

## Claude Code Configuration

`ai/vekil/env.zsh` automatically configures Claude Code. `vekil-proxy env` also
prints the equivalent values for diagnostics and non-zsh shells:

```bash
export ANTHROPIC_BASE_URL="http://172.17.0.1:1337"
export ANTHROPIC_API_KEY="dummy"
export ANTHROPIC_MODEL="claude-opus-4.8"
```

It also prints a devcontainer block using `host.docker.internal`. Vekil accepts
the dummy client key and supplies its own refreshed Copilot bearer token to the
upstream API.

## Model Discovery

`vekil-proxy models` calls Vekil's `/v1/models` endpoint and prints sorted model
IDs. Vekil obtains the catalog dynamically from the authenticated Copilot
account, eliminating the manually maintained alias list in
`ai/litellm/config.yaml`.

Client defaults will use upstream model IDs. The smoke-test phase must confirm
the exact IDs available to the account before obsolete aliases are removed.

## Process Management

The lifecycle script will:

- Validate that `vekil`, `curl`, and `jq` are available where required.
- Create the runtime directory before startup.
- Reject a live PID file that belongs to a non-Vekil process.
- Use `setsid` where available and `nohup` as the portable fallback.
- Redirect standard input and all output away from the invoking terminal.
- Wait for `/healthz`, then `/readyz`, with a bounded timeout.
- Print recent logs when startup fails.
- Send a graceful termination signal first and use force only after a bounded
  shutdown timeout.
- Avoid broad `pkill -f` patterns that could terminate unrelated processes.

## Migration Sequence

1. Add `ai/vekil/install.sh` and `bin/vekil-proxy` without removing LiteLLM.
2. Add `ai/vekil/env.zsh` and update the repository-managed Codex
   configuration.
3. Install the pinned Vekil release through the new installer.
4. Start Vekil and complete Copilot authentication if required.
5. Open a fresh shell and verify the repository-managed client environment.
6. Verify `/healthz`, `/readyz`, and `/v1/models` from the host.
7. Verify `/v1/models` through `host.docker.internal` from a devcontainer.
8. Run a minimal Claude Code request through `/v1/messages`.
9. Run a minimal Codex request through `/v1/responses`.
10. Remove `bin/codex-proxy`, `bin/copilot-proxy`, and
   `ai/litellm/install.sh`.
11. Remove `ai/litellm/config.yaml` after both client smoke tests pass.
12. Update repository documentation and AI-tool listings from LiteLLM to
    Vekil.

## Validation

Local validation will include:

- `bash -n` for all modified shell scripts.
- Installer idempotency when the pinned Vekil version is already present.
- Checksum failure handling using a controlled bad checksum fixture or mocked
  download path.
- Bridge detection with Docker available and unavailable.
- Explicit-host validation, including warnings for wildcard binds.
- PID-file handling for live, stale, and unrelated processes.
- Startup failure output and bounded timeout behavior.
- Host health, readiness, and model-list requests.
- Devcontainer access through `host.docker.internal`.
- Automatic host and container environment selection from `ai/vekil/env.zsh`.
- One minimal Claude Code inference request.
- One minimal Codex inference request using the Responses API.
- `make ai` or the individual installer to confirm the standard repository
  installation path works end to end.

Live inference tests consume Copilot quota and require network access. They are
run only during final validation, after local lifecycle tests pass.

## Rollback

Until live validation succeeds:

- Keep the LiteLLM binary and cached credentials installed.
- Keep `ai/litellm/config.yaml` available.
- Do not delete the old scripts before Vekil serves both clients successfully.

If validation fails, stop Vekil and restore the old Codex configuration and
proxy commands from Git. Vekil's separate credential and state directories do
not alter LiteLLM's cached authentication.

## Deferred Inference-Response Cache

AIProxy includes an exact-request response cache based on a hash of the request
body, with in-memory or Redis storage and configurable TTLs. Vekil does not
provide an equivalent full inference-response cache.

This is intentionally deferred because the current LiteLLM configuration does
not enable response caching, so migration does not remove an active capability.
Coding-agent requests also contain changing conversation state, tool outputs,
and external-system context, which makes exact repeats uncommon and cached tool
calls potentially unsafe.

Revisit response caching only if observed traffic demonstrates meaningful
duplicate requests. Any future cache must exclude tool-call responses,
streaming requests, background requests, stateful Responses sessions, and
requests whose correctness depends on current filesystem or external-service
state.

## Success Criteria

- `bin/install` and `make ai` install or update Vekil without manual binary or
  configuration steps.
- The repository lifecycle script starts one Vekil process on the Docker bridge
  gateway when available.
- Host and devcontainer clients can list the same Copilot model catalog.
- Claude Code completes a request through Vekil's Anthropic endpoint.
- Codex completes a request through Vekil's Responses endpoint.
- No LiteLLM process, installer, configuration, or client provider remains in
  active use.
- A fresh machine requires only the standard dotfiles bootstrap/install flow
  plus unavoidable GitHub OAuth approval.
