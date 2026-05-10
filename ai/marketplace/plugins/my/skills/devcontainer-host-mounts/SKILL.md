---
name: devcontainer-host-mounts
description: Set up a `.devcontainer/docker-compose.override.yml` that mounts the host's dev tools (Claude Code config, OpenCode config, dotfiles, SSH keys, gh CLI auth) into a devcontainer so the container reuses host credentials and tooling. Also wires up the `host.docker.internal` host entry and an optional `gitconfig_local` config for HTTPS credential reuse. Use whenever the user is setting up or re-bootstrapping a devcontainer, asks to share host SSH/gh/Claude/OpenCode/dotfiles with a container, mentions a docker-compose override file, or starts a new project that uses `.devcontainer/docker-compose.yml` — even if they don't say the word "override".
---

# Devcontainer host mounts

The user runs the same devcontainer pattern across most of their projects: a `.devcontainer/docker-compose.yml` that defines the dev container, plus a `.devcontainer/docker-compose.override.yml` that adds host-specific bind mounts so the container reuses what's already on the host (SSH keys, `gh` auth, Claude Code config + plugins + commands, OpenCode config, dotfiles). Compose auto-merges the override on top of the base file.

This skill writes that override file. It is not for scaffolding a devcontainer from scratch — there must already be a `.devcontainer/` with a compose-based setup.

## When to use this

Trigger this skill when the user says things like:
- "set up the devcontainer mounts" / "add the docker compose override"
- "share my ssh keys / gh auth / Claude config / dotfiles with the container"
- "bootstrap a new project's devcontainer the way I usually do"
- starts working on a fresh project and the devcontainer comes up without their host tools

If `.devcontainer/` doesn't exist yet, stop and tell the user this skill assumes a compose-based devcontainer is already in place — offer to help create one separately, but don't invent one as part of this task.

## Step 1 — Verify the prerequisites

Confirm these exist:
- `.devcontainer/devcontainer.json`
- a compose file referenced from it — read the `dockerComposeFile` key in `devcontainer.json` to find the actual paths. The compose files commonly live under `.devcontainer/`, but some projects keep them at the project root and reference them with `../docker-compose.yml`. The override goes wherever the base compose lives, not blindly under `.devcontainer/`.

If a `docker-compose.override.yml` already exists at that location, read it before doing anything else. The user may have a partial or different override they want extended rather than clobbered. Surface what's already there in one sentence and confirm before overwriting.

## Step 2 — Discover the service name and container user

These two values vary per project and must be filled in correctly, otherwise the mounts land in the wrong place inside the container.

**Service name.** Open `.devcontainer/docker-compose.yml`. The override must target the same top-level service. Most projects use `app`, but some name it after the project (e.g. `wanderer:` in the wanderer repo). Use whichever name appears under `services:` in the base compose file. If `devcontainer.json` has a `service:` key, that is authoritative.

**In-container user.** The mount targets must use the user's actual home path inside the container. Resolve in this order:
1. `remoteUser` in `.devcontainer/devcontainer.json` if set
2. `USER` instruction in the Dockerfile (parse the last one that wins)
3. Base image default — common ones below

| Base image | Default user |
|---|---|
| `mcr.microsoft.com/devcontainers/javascript-node` | `node` |
| `mcr.microsoft.com/devcontainers/typescript-node` | `node` |
| `mcr.microsoft.com/devcontainers/base:ubuntu` (and most language variants) | `vscode` |
| `mcr.microsoft.com/devcontainers/universal` | `codespace` |
| Custom Dockerfile with no `USER` | `root` (warn — bind mounts will be owned by root) |

If you can't determine the user from any of these signals, ask. Do not guess between `vscode` / `node` / `developer` — getting it wrong silently mounts into a path the shell never visits.

## Step 3 — Decide which mounts to include

The default set, in order:

```
~/.ssh                  →  /home/{USER}/.ssh                 (ro)
~/.config/gh            →  /home/{USER}/.config/gh           (ro)
~/.claude               →  /home/{USER}/.claude              (cached)
~/.config/opencode      →  /home/{USER}/.config/opencode     (cached)
~/.dotfiles             →  /home/{USER}/.dotfiles            (cached,ro)
```

Why each one:
- **`~/.ssh` (ro)**: lets the container `git push` over SSH and connect to remote hosts using the host's keys. Read-only because the container should never modify host keys.
- **`~/.config/gh` (ro)**: shares the `gh` CLI's stored auth token so `gh pr create`, `gh api`, etc. work without a fresh login inside the container.
- **`~/.claude` (cached)**: Claude Code's config, plugins, commands, agents, and settings. Read-write so the container can update its own state (history, sessions). `cached` is a macOS-specific perf hint that's harmless on Linux/WSL — keep it for portability.
- **`~/.config/opencode` (cached)**: same idea for OpenCode.
- **`~/.dotfiles` (cached,ro)**: shell config, aliases, anything sourced at startup. Read-only because dotfiles are managed on the host.

Optional, ask before adding:
- **`~/.pi`** — only used in some of the user's projects (e.g. `abyssalwatch`). Don't include by default.
- **Project-specific dirs** — if the user mentions another tool's config they want shared, mount it the same way.

If a host directory doesn't exist, Docker creates an empty one when the container starts. That's not a failure mode — just means the tool isn't on the host yet. Don't add `if`-checks or skip mounts on this basis.

## Step 4 — Write the override file

Write to the same directory as the base compose file (per Step 1). If the base is `.devcontainer/docker-compose.yml`, the override is `.devcontainer/docker-compose.override.yml`; if the base lives at the project root, the override lives at the project root too. Compose's auto-merge of `*.override.yml` only kicks in when both files are siblings or both are listed in `dockerComposeFile` — putting the override in the wrong directory silently does nothing.

Use this template, filling in `{SERVICE}` and `{USER}` from Step 2:

```yaml
# Host-specific volume mounts for sharing development tools with the container.
# Gives the container access to host-installed CLI tools, plugins, slash
# commands, and settings (Claude Code, OpenCode, dotfiles, SSH, gh).
#
# Tilde paths expand to the invoking user's home directory, so this file is
# portable across machines. If a host directory doesn't exist, Docker creates
# an empty one — no harm done.
services:
  {SERVICE}:
    volumes:
      - ~/.ssh:/home/{USER}/.ssh:ro
      - ~/.config/gh:/home/{USER}/.config/gh:ro
      # Two mounts per dotfile-touched directory: one at the container
      # user's home (where tools look by default) and a parallel mount at
      # the host's absolute home (so absolute symlinks and absolute paths
      # baked into JSON configs — e.g. installed_plugins.json's installPath
      # — resolve inside the container). See "The absolute-path gotcha"
      # below for why both are needed.
      - ~/.claude:/home/{USER}/.claude:cached
      - ${HOME}/.claude:${HOME}/.claude:cached
      - ~/.config/opencode:/home/{USER}/.config/opencode:cached
      - ${HOME}/.config/opencode:${HOME}/.config/opencode:cached
      - ~/.dotfiles:/home/{USER}/.dotfiles:cached,ro
      - ${HOME}/.dotfiles:${HOME}/.dotfiles:cached,ro
    configs:
      - source: gitconfig_local
        target: /home/{USER}/.gitconfig.local
        mode: 0644
    extra_hosts:
      - "host.docker.internal:host-gateway"

configs:
  gitconfig_local:
    content: |
      [credential]
          useHttpPath = true
```

Why the two non-volume blocks:

- **`extra_hosts: host.docker.internal:host-gateway`** — on Docker Desktop (macOS/Windows) this DNS name exists automatically, but on Linux and WSL2 it does not. Adding `host-gateway` makes it resolve to the host on every platform, so anything in the container that talks to a host-side service (a dev server, a database tunnel, etc.) works the same everywhere. Include it in the override unless the base compose already declares it on the same service — grep the base for `host.docker.internal` first. Duplicating works (compose merges and dedupes by host name) but adds noise.
- **`gitconfig_local` config** — sets `credential.useHttpPath = true` in a separate `~/.gitconfig.local` that the user's main gitconfig is expected to `[include]`. With this on, git's credential helper keys credentials by full URL path, which means cached creds for one repo don't get reused for another. Include this by default; the only project the user has without it is one of the older ones.

If the container user is `root`, mount targets become `/root/...` instead of `/home/{USER}/...`. Same shape otherwise.

### The absolute-path gotcha

Dotfile-touched directories typically contain absolute references back into the host's `$HOME`. Two flavors:

1. **Absolute symlinks**: dotfile installers (stow, the user's `~/.dotfiles/ai/*/install.sh` scripts, etc.) create symlinks like `~/.claude/settings.json -> /home/<host-user>/.dotfiles/ai/claude/settings.json`. Bind mounts preserve the symlink's target text verbatim, so inside the container that absolute path doesn't resolve (the container has `/home/{USER}` but no `/home/<host-user>`), and the symlink dangles.
2. **Absolute paths in JSON**: Claude Code records `installPath: /home/<host-user>/.claude/plugins/cache/...` in `installed_plugins.json` (and `installLocation` in `known_marketplaces.json`) when plugins are installed on the host. Inside the container those paths don't resolve, so the plugin loader fails with errors like `Plugin X not found in marketplace Y` even though the marketplace dir is mounted.

Both failures look unrelated and have noisy symptoms (`ENOENT: ... open '/home/<host-user>/...'`, plugin-not-found cascades). The cause is the same: the container has the data but not at the path baked into the references.

The parallel `${HOME}:${HOME}` mounts fix both by making the host's absolute home path resolve inside the container to the same backing data as `/home/{USER}/`. `${HOME}` evaluates on the host at `docker compose up`, so the override stays portable across machines. Permissions are fine when the container's primary user shares the host user's uid — the standard `vscode`/`node` devcontainer images use uid 1000, matching most Linux desktop setups.

You can verify after a rebuild:

```bash
docker compose exec {SERVICE} ls -L /home/{USER}/.claude/settings.json
docker compose exec {SERVICE} ls -d ${HOME}/.claude/plugins/cache
```

`-L` on the first follows the symlink chain; if it prints the file, dotfile symlinks resolve. The second checks that the parallel-mount path exists inside the container.

Skip the parallel mounts only when you're certain the host directory contains no absolute self-references (e.g. `~/.ssh` and `~/.config/gh` are typically self-contained — that's why the template doesn't dual-mount them).

## Step 5 — Verify

Once written:
1. Run `docker compose -f .devcontainer/docker-compose.yml -f .devcontainer/docker-compose.override.yml config` from the project root. Compose will print the merged config or fail loudly on a typo. Check that the service name matches and the volume target paths look right.
2. If the devcontainer is currently running, the override only takes effect on next rebuild — tell the user "Rebuild Container" in VS Code is needed to pick up the new mounts.

Don't rebuild for them; that's their call.

## Things to avoid

- Don't add fallbacks for missing host directories. Docker handles it.
- Don't add comments explaining each mount line — the file header covers the why, and per-line comments age badly when the list changes. Match the style of the user's existing override files.
- Don't promote the override into the base `docker-compose.yml`. The whole point of the override is that it's host-specific and stays out of the committed compose file (or is committed but understood as the local-dev overlay).
- Don't change the service name to `app` if the base compose uses something else. The override must target the real service.
