# Pi Web UI operations

This opt-in integration runs Firstp1ck `0.10.3` with the mise-managed Pi
`0.84.4` on Ubuntu 24.04 Noble under WSL and a systemd user manager. It is
separate from ordinary `make ai` and never registers Firstp1ck as a Pi package.

## Trust boundary

The service is loopback-only on `127.0.0.1:31415`. Remote access is exclusively
a tailnet-only Tailscale Serve HTTPS 443 proxy to that address; Funnel, direct
LAN access, wildcard listeners, and additional routes are rejected. Tailscale
runs only inside WSL.

There is no application-level remote authentication. Pi's permission system
still gates Pi tool calls, but browser-native controls are outside it: every
trusted tailnet browser client has full authority of the WSL account. Give
access only to a tailnet whose entire membership is trusted at that level.

## First install

Use the canonical `~/.dotfiles` checkout at clean `origin/main`. Review each
mutating step and run this exact order:

```bash
make ai-check
make ai
ai/pi/webui/tailscale.sh install
ai/pi/webui/tailscale.sh up
make ai-webui-check
# review reported state and obtain separate approval before applying
make ai-webui
ai/pi/webui/tailscale.sh serve
make ai-webui-check
```

`up` authenticates interactively and never accepts an auth key. Check mode is
read-only and must precede every separately approved apply. Review its reported
state and obtain approval rather than expecting an apply plan.

From Windows, open exactly `http://127.0.0.1:31415`. A tailnet client opens the
`https://...` URL printed by `tailscale serve status`.

## Operation and health

```bash
systemctl --user status pi-webui.service
journalctl --user -u pi-webui.service -e
systemctl --user restart pi-webui.service
systemctl --user stop pi-webui.service
systemctl --user start pi-webui.service
curl --fail http://127.0.0.1:31415/api/health
make ai-webui-check
```

The user service starts while WSL and its user manager are active. The
initial landing worktree is the clean detached
`~/.local/share/pi-webui/worktrees/dotfiles`. Users may open other project tabs
and create or select their branch worktrees.

Accepted limitations: run-level Abort is unavailable while a permission modal
is open; Deny or Cancel blocks that request. Restart may open a fresh tab rather
than restore the current one, but saved transcripts remain manually resumable.

## Update the pins

Update the exact Firstp1ck dependency and lock together with every checked
version, integrity, count, and hash; update `config/versions.env` and Pi identity
checks when Pi changes. Regenerate the lock with:

```bash
mise exec -- npm install --package-lock-only --ignore-scripts --omit=optional \
  --save-exact --prefix ai/pi/webui/runtime @firstpick/pi-package-webui@VERSION
```

Review the complete lock diff and run focused and repository checks before merging.

Before pulling changed runtime pins on an installed host, use the old checkout
to remove Serve, run `ai/pi/webui/rollback.sh`, then run it again with
`--remove-runtime`. Pull, update Pi if needed, check, obtain approval, apply,
restore Serve, and check again. Rollback must run before Pi or mise is upgraded or removed
because the exact Pi identity is required to prove the managed unit.

## Rollback and uninstall

The mandatory operator order is **`serve-off` → rollback → Tailscale uninstall**:

```bash
ai/pi/webui/tailscale.sh serve-off
ai/pi/webui/rollback.sh
ai/pi/webui/tailscale.sh uninstall
```

Default rollback removes only the proven service and unit. It preserves the
runtime, worktrees, Pi settings, transcripts, supervisor state, backups,
evidence, and Tailscale identity; Tailscale uninstall also preserves identity.
Add `--remove-runtime` and/or `--remove-worktree` only for deliberate destructive
cleanup. Worktree removal refuses dirty, attached, foreign, or persisted `.pi`
state. Never uninstall Tailscale before rollback, because rollback must classify
empty Serve state while the daemon is available.
