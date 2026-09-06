# Pi Web UI operations

This opt-in integration runs Firstp1ck `0.10.4` with the mise-managed Pi
`0.85.1` on Ubuntu 24.04 Noble under WSL and a systemd user manager. It is
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
ai/pi/webui/tailscale.sh serve-legacy
```

`up` authenticates interactively and never accepts an auth key. Check mode is
read-only and must precede every separately approved apply. Review its reported
state and obtain approval rather than expecting an apply plan.

`serve-legacy` publishes the transitional MagicDNS HTTPS route
(`HTTPS 443 -> http://127.0.0.1:31415`), which is the only ingress available
before the custom-domain Caddy service exists and the only state custom-domain
setup accepts. `serve` and `serve-off` own the raw custom-domain route
exclusively and must not be used before Caddy is installed and healthy: raw
forwarding to an absent `127.0.0.1:8443` publishes a dead route.

While the transitional legacy route is published, `make ai-webui-check`
intentionally refuses it: this branch's accepted steady states are empty Serve
or the raw custom-domain route. Use `ai/pi/webui/custom-domain.sh check` in
that window, and rerun `make ai-webui-check` once migration has completed.

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
to remove Serve (`ai/pi/webui/tailscale.sh serve-legacy-off`, or
`ai/pi/webui/custom-domain.sh rollback --full` when the custom domain is
installed), run `ai/pi/webui/rollback.sh`, then run it again with
`--remove-runtime`. Pull, update Pi if needed, check, obtain approval, apply,
restore Serve, and check again. Rollback must run before Pi or mise is upgraded or removed
because the exact Pi identity is required to prove the managed unit.

## Custom domain (`pi.dpao.la`)

This opt-in, separate layer publishes the existing loopback-only Web UI at
`https://pi.dpao.la` over public GoDaddy DNS and a Tailscale raw TCP route,
without adding LAN, wildcard, or Funnel ingress:

```text
pi.dpao.la -> public GoDaddy A 100.84.88.33 -> WSL Tailscale IP:443
  -> Tailscale Serve raw TCP -> Caddy 127.0.0.1:8443 -> Firstp1ck 127.0.0.1:31415
```

It is entirely separate from ordinary `make ai`, `make ai-check`, `make
ai-webui`, and `make ai-webui-check`, which are unchanged by this layer and do
not acquire any custom-domain side effect. The only public entry points are
`make ai-webui-domain-check` and `make ai-webui-domain-setup`; live route
migration and rollback remain explicit script commands, never Make
dependencies.

### Disclosure and credential

The public `pi.dpao.la A 100.84.88.33` record intentionally discloses the
hostname and the CGNAT-range Tailscale address. ACME DNS-01 issuance also
discloses the hostname through Certificate Transparency logs. The address
remains unroutable without Tailscale connectivity and applicable tailnet
policy, but some client resolvers or browsers reject a public answer in
`100.64.0.0/10` through DNS-rebinding or Private Network Access defenses, so
every expected client must be tested. If the node is deleted and re-enrolled,
a changed Tailscale IP causes a hard stale-DNS failure until the record is
manually updated.

The classic GoDaddy Production credential is broad and deprecated; isolate its
use and rotate it. The `caddy-dns/godaddy` module manages the exact
`_acme-challenge.pi.dpao.la` TXT record; reserve that name for this flow and
never point an unrelated value or a concurrent certificate client there.

Caddy is a pinned private build (Caddy `v2.11.4` with `caddy-dns/godaddy`
`v1.2.0` via xcaddy `v0.4.7`), installed under `/usr/local/lib/pi-webui/` and
run as the dedicated system service `pi-webui-caddy.service`. It listens only
on loopback `127.0.0.1:8443` and reverse-proxies to the existing Firstp1ck
listener `127.0.0.1:31415`; Funnel remains disabled throughout.

### Live operation, in order

1. Resolve the known Pi drift under a separate approval before any
   custom-domain setup or migration; the strict preflight refuses until
   alignment is proven, and a restart or WSL reboot before alignment risks
   launching the unaligned Pi version.
2. Manually create `pi.dpao.la A 100.84.88.33` in GoDaddy (no CNAME or AAAA),
   using the current node's Tailscale IPv4, and wait for exact public
   resolvers to answer it before proceeding.
3. Create the encrypted GoDaddy credential without shell-history exposure:

   ```bash
   sudo install -d -o root -g root -m 0700 /etc/credstore.encrypted
   sudo systemd-creds encrypt --name=godaddy-api-token - \
     /etc/credstore.encrypted/godaddy-api-token
   # Paste KEY:SECRET, then press Ctrl-D. Do not paste it into chat.
   sudo chmod 0600 /etc/credstore.encrypted/godaddy-api-token
   ```

4. Inspect read-only state: `make ai-webui-domain-check`.
5. Review the report and obtain separate approval, then build and install the
   candidate Caddy service while legacy ingress stays live:
   `make ai-webui-domain-setup`.
6. Inspect the exact installed service, unit, loopback listeners, and issued
   certificate before migrating.
7. Review the printed migration plan and obtain approval, then run
   `ai/pi/webui/custom-domain.sh migrate`. It removes only the legacy exact
   route (`Old: HTTPS 443 -> http://127.0.0.1:31415`), publishes only the raw
   exact route (`New: TCP 443 -> tcp://127.0.0.1:8443`), verifies TLS and
   health through the tailnet, and prompts for a separate trusted-tailnet-
   client confirmation before disarming restoration. Interruption is normally
   several seconds; browser WebSockets disconnect during the switch. A
   preflight, verification, or confirmation failure restores the legacy route
   automatically only when the observed route is
   empty or exactly the raw route; an unexpected or foreign concurrent route
   is refused rather than overwritten, and is reported with the exact manual
   recovery commands.
8. Verify: a trusted tailnet client reaches `https://pi.dpao.la` successfully;
   an off-tailnet client fails to connect; Caddy and the Tailscale Serve
   backend expose only loopback listeners and no LAN listener; Funnel remains
   disabled; `systemctl --user restart pi-webui.service` and a full WSL
   reboot both restore service correctly; and no orphaned process remains.
   The old `.ts.net` URL is no longer valid once migration succeeds.
9. Recover with `ai/pi/webui/custom-domain.sh rollback`, which restores the
   legacy route, proves the old URL answers, and removes only the managed
   Caddy service artifacts, or with the exact route commands printed by the
   migration plan
   (`sudo tailscale serve --tcp=443 off; sudo tailscale serve --bg --https=443
   http://127.0.0.1:31415`) if the script itself is unavailable. Rollback
   preserves certificates, the encrypted credential, Pi state, and the
   Tailscale identity by default.

## Rollback and uninstall

The mandatory operator order is **remove ingress → Web UI rollback → Tailscale
uninstall**. Which ingress removal applies depends on what is published:

```bash
# custom domain installed (raw or transitional legacy route)
ai/pi/webui/custom-domain.sh rollback --full

# custom domain never installed, transitional legacy route published
ai/pi/webui/tailscale.sh serve-legacy-off

# raw route published with the Caddy service already removed
ai/pi/webui/tailscale.sh serve-off

# then, in every case
ai/pi/webui/rollback.sh
ai/pi/webui/tailscale.sh uninstall
```

`custom-domain.sh rollback` (without `--full`) is the migration rollback: it
returns ingress to the transitional legacy route, proves the old MagicDNS URL
answers, and removes the managed Caddy artifacts. `custom-domain.sh rollback
--full` is the uninstall path: it takes the exact raw or exact legacy route
down to empty, removes the same artifacts, and leaves Serve empty so
`rollback.sh` can run. Both preserve certificates, ACME state, and the
encrypted credential.

Default rollback removes only the proven service and unit. It preserves the
runtime, worktrees, Pi settings, transcripts, supervisor state, backups,
evidence, and Tailscale identity; Tailscale uninstall also preserves identity.
Add `--remove-runtime` and/or `--remove-worktree` only for deliberate destructive
cleanup. Worktree removal refuses dirty, attached, foreign, or persisted `.pi`
state. Never uninstall Tailscale before rollback, because rollback must classify
empty Serve state while the daemon is available.
