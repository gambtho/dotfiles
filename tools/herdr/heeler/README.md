# Heeler access to the default Herdr session

[Heeler](https://github.com/ZingerLittleBee/Heeler) is a native iOS console for
Herdr. It attaches to the **real terminal running native Pi**, rather than
starting a separate Pi RPC session. The desktop command remains `herdr`.

This optional configuration persists the **default** Herdr session and a
key-only SSH listener on the current Tailscale IPv4, port **2222**. It connects
directly over SSH: no browser backend, reverse proxy, DNS-provider credential or
Tailscale Serve/Funnel route is required. Native Pi resources and ordinary
provisioning phases are unchanged.
The Heeler plugin, pairing bootstrap, notifications and push relay are not installed.

## Boundaries and prerequisites

- Linux with systemd, its user manager and cgroup v2. Tested on Ubuntu 24.04 WSL,
  Herdr 0.8.0/protocol 19, native Pi 1.2.0 with its existing Herdr integration,
  and OpenSSH 9.6. Herdr stays managed by the existing [pinned installer](../README.md).
- Existing Mise at `~/.local/bin/mise` (normal bootstrap) or `/usr/bin/mise`,
  native Pi in `~/.pi/agent/bin`, Herdr in
  `~/.local/bin`, Tailscale, OpenSSH server and systemd's `busctl`. This feature
  does not install or update these dependencies. The user service uses `mise exec`
  so Node is available without relying on an interactive shell's startup timing.
  The same selected absolute Mise launcher is rendered into the user unit and
  used by preparation probes; a user-local installation takes precedence.
  Preparation tests Node/Herdr with the same PATH and user-manager environment
  the service inherits, not shell-only tool overrides. Manager preferences and
  credentials stay in memory for these probes and are never printed or saved;
  the manager's HOME must match the account.
- User lingering must be enabled for startup before login. The guided command
  below can enable it, but only with an **already-running** correct-user manager
  and bus. It binds the manager's InvocationID/MainPID into the approved request
  and rechecks immediately before enabling lingering. Inactive or changed managers
  are refused: enabling lingering must not start dormant previously enabled units.
  The lower-level `make ai-heeler` still requires lingering to be enabled first.
- The ordinary `ssh.service` and `ssh.socket` must be **masked**. Do not disable
  someone else's SSH deployment to satisfy this requirement. On a new Noble
  host with no existing SSH deployment, an operator may mask both units **before**
  installing `openssh-server`, preventing the package from starting a wildcard
  listener. Existing SSH host keys are reused, never copied into Git.
- Use a normal Linux user with UID >=1000 and a conventional absolute home path
  without whitespace, traversal or systemd specifiers. Heeler and Herdr use
  `$HOME/.config/herdr`; a directory symlink or alternate HOME is not adopted.

SSH grants the selected account **ordinary shell access**, including its normal
filesystem and process authority. The forwarding allowlist is not a sandbox.
Keep tailnet ACLs and phone-key access appropriately narrow. No password login,
root login, agent forwarding, X11 forwarding or wildcard/LAN listener is enabled.

WSL startup is not Windows startup: this starts services **when WSL boots**;
it does not launch WSL, wake Windows, or keep a powered-off machine reachable.

## Guided per-host WSL setup

Each computer keeps its own default Herdr/Pi sessions, Tailscale identity and SSH
host keys. Add a separate Heeler host on the phone for each machine; this does not
synchronize or migrate conversations. The same phone public key can be enrolled
independently on each host.

1. Run normal bootstrap and `bin/dot-install` for the selected WSL profile.
   This supplies OpenSSH server and Tailscale, with both stock SSH units masked
   **before** package mutations. Existing/custom SSH requires explicit migration.
2. Finish native Tailscale sign-in and get the node online. Authentication may
   separately need administrator access; setup never joins a tailnet, resets
   preferences, enables Tailscale SSH or configures Serve/Funnel for you.
3. From an ordinary interactive login and the reviewed **canonical checkout**:

   ```bash
   DOTFILES_HEELER_ENABLED=1 make ai-heeler-setup
   ```

   Paste the phone's plain SSH **public** key when requested, never a private key.
   To read a public-key file instead, use the private entrypoint:
   `DOTFILES_HEELER_ENABLED=1 bash tools/herdr/heeler/setup.sh --key-file /path/to/phone.pub`.
4. Review the exact administrator command, fixed payload filenames and SHA256
   digests. Type `publish` to authorize the single Root transaction. Sudo may use
   cached authentication or ask for a password; setup does not force a fresh
   password or collect it. Cancellation before authorization leaves enrollment
   untouched. A valid existing phone-key file is preserved byte-for-byte; an empty
   legacy file is reported for explicit enrollment rather than overwritten.
5. Setup installs the approved bytes into private Root staging before executing
   the isolated publisher. It validates policy, then publishes/enables the system
   and user units **without starting/restarting them**. It prints a connection
   card with the tailnet IP, port 2222, Linux user, `default` session and SSH host
   public-key fingerprint. Verify that fingerprint on the phone.
6. If pending, save work and perform a controlled restart of **only the selected
   WSL distro** yourself. Setup never terminates WSL or adopts existing daemons.
   Run `DOTFILES_HEELER_ENABLED=1 make ai-heeler-check`, then verify an actual
   phone connection. Enabled units and mocked tests alone are not live proof.

Missing prerequisites, an inactive user manager/bus or an offline/unjoined node
stop before authorization. Already-healthy setups print the card without another
Root command. Ordinary install/update/AI/profile flows never invoke guided setup.
Direct launcher exits are healthy/unselected `0`, pending/canceled `2`, error `1`;
Make reports only command success/failure.

Root executes only the digest-bound, Root-owned staged publisher/runtime and
absolute system tools; Mise, Herdr and Pi remain user-side. Initial trust is the
operator-approved canonical source and exact command: hashes prevent subsequent
payload substitution, not compromise of that same-user command itself. A fresh
host may need Root-owned `/run/sshd` (0755) before OpenSSH configuration validation;
this temporary privilege-separation directory contains no SSH keys and opens no
listener. It is recreated at service startup after a reboot.

Root recovery metadata is private under `/var/lib/dotfiles-heeler/` (0700): a
0600 ownership receipt/lock and 0700 `recovery-*` snapshots of only the owned policy
and enablement state. Unknown policy is refused, not adopted. Incomplete recovery
retains originals and blocks another publication until operator inspection.
The doctor still compares published bytes against authored runtime/staged unit
bytes, not a marker or receipt. During an owned policy upgrade, discovery validates
the live listener against the currently published policy; the Root phase verifies
the private receipt before replacing it with the candidate for a later restart.
Manual legacy installations without a receipt are adopted only when both published
files already match the current reviewed policy; otherwise explicit migration is
required. If publication commits but backup cleanup fails, setup reports completion
and the retained private cleanup path instead of claiming a rollback. Newly enabled lingering is not undone by stopping
the manager during recovery. Root and user phases are separate: if Root succeeds
but user preparation fails, that completed Root phase is reported and phone keys
remain enrolled; no session/credential rollback is claimed.

The following lower-level preparation/publication steps remain available for
advanced use and recovery.

## Explicit preparation — no live takeover

From the reviewed **canonical checkout**, not an implementation worktree:

```bash
DOTFILES_HEELER_ENABLED=1 make ai-heeler
```

Unset, empty or `0` opts out without writes; opting out does not stop an already
installed service. Ordinary `make ai`, installs, updates and profile changes
never select this feature implicitly.

Preparation:

1. Checks prerequisites and refuses foreign/symlinked managed destinations.
2. Copies an owned `dotfiles-herdr.service` into the user manager configuration
   and enables it **without starting or restarting it**.
3. Stages the rendered root unit at
   `~/.local/share/heeler/dotfiles-heeler-sshd.service` for operator publication.
4. Preserves the existing phone key **byte-for-byte** at
   `~/.local/share/heeler-trial/authorized_keys`. This historical path is kept
   deliberately so the working phone identity needs no migration. New machines
   get an empty private file and require explicit public-key enrollment.

The existing default daemon, its workspaces, native Pi session files, credentials,
mutable Herdr preferences and the trial are not stopped, moved or adopted.
Reapplying identical configuration is a no-op. Changed service policy applies
only at a later controlled restart. A private preparation lock serializes applies.
Failed policy publication restores previous files/enablement; incomplete rollback
retains originals and `manifest.json` under a `.rollback-*` directory in
`~/.local/share/heeler/` and refuses another apply until an operator resolves it.
A snapshot-write failure before publication removes its partial backup so retry is
possible; if cleanup fails, the error identifies the retained directory instead.
Never restore or delete live session data as part of policy rollback.

For a new phone, copy its **public** `authorized_keys` line into the dedicated
key file, keeping permissions `0600`. The file accepts plain public keys, not
private keys or authorized-key command/options. Existing keys are never silently
replaced. Do not put keys, passwords, session state or rendered machine-specific
units in Git.

## Operator-only system publication

These are explicit administrator operations in your terminal—not a privileged
installer hidden behind the preparation target. Never run them from an
implementation worktree. Review the canonical feature files and rendered unit
first. If an existing destination is foreign, a symlink or unexpectedly writable,
stop rather than overwrite it. Back up any prior owned artifacts before replacing
them; a partial publication must be completed or restored before enabling the unit.

Validate the rendered units without starting them:

```bash
systemd-analyze --user verify "$HOME/.config/systemd/user/dotfiles-herdr.service"
systemd-analyze verify "$HOME/.local/share/heeler/dotfiles-heeler-sshd.service"
```

From the canonical dotfiles directory, publish regular root-owned files. Parent
directories, the entrypoint and system unit must be root-controlled and not
writable by group/other users. No runtime symlink into the checkout is used.

```bash
sudo install -d -o root -g root -m 0755 /usr/local/lib/dotfiles-heeler
sudo install -o root -g root -m 0755 tools/herdr/heeler/sshd-entrypoint.py \
  /usr/local/lib/dotfiles-heeler/sshd-entrypoint.py.new
sudo mv -T /usr/local/lib/dotfiles-heeler/sshd-entrypoint.py.new \
  /usr/local/lib/dotfiles-heeler/sshd-entrypoint.py
sudo install -o root -g root -m 0644 \
  "$HOME/.local/share/heeler/dotfiles-heeler-sshd.service" \
  /etc/systemd/system/dotfiles-heeler-sshd.service.new
sudo mv -T /etc/systemd/system/dotfiles-heeler-sshd.service.new \
  /etc/systemd/system/dotfiles-heeler-sshd.service
```

Check published ownership with `namei -l` before executing the entrypoint. It is
invoked with Python isolated mode: root never loads the user's Python packages,
Mise configuration, Herdr binary or Pi extensions.

```bash
sudo install -d -o root -g root -m 0755 /run/sshd
sudo /usr/bin/python3 -I /usr/local/lib/dotfiles-heeler/sshd-entrypoint.py \
  --user "$(id -un)" --check
sudo systemctl daemon-reload
sudo systemctl enable dotfiles-heeler-sshd.service
```

`--check` validates the full effective sshd configuration without listening.
It requires an online Tailscale node and valid SSH host keys. Enabling the unit
without `--now` deliberately leaves the current trial listener alone.

At startup the root unit waits for Tailscale, resolves exactly one online IPv4
in `100.64.0.0/10`, and execs foreground sshd on that address only. Missing,
offline, malformed, public or ambiguous addresses fail closed; systemd retries
without exhausting a permanent start limit. No static node IP is committed.
If Tailscale assigns a different IPv4 while running, an operator restarts this
unit to re-resolve it; update the phone's address if needed. Tailscale restarts
propagate to this unit; enabling also installs a Tailscale start dependency so a
separate stop followed by start brings the listener back.

**OpenSSH forwarding caveat:** `AllowTcpForwarding=no` also blocks Unix forwarding
in OpenSSH 9.6. This setup instead uses local forwarding plus the exact default
socket allowlist `PermitOpen=[/home/ACCOUNT/.config/herdr/herdr.sock]:*`. The brackets
are significant. Live trial regression tested a successful Unix ping and denial
of ordinary TCP and another Unix socket; repeat that acceptance check after a
platform/OpenSSH change. Do not replace this with unrestricted forwarding or
`PermitOpen none` as an apparent hardening shortcut.

## Controlled cutover and acceptance

There is **no automatic stop/restart of the active default daemon or trial**.
After preparation and root publication, schedule a controlled WSL reboot or
maintenance window. A reboot ends running processes, including active Pi turns;
save work and stop ongoing tasks first. The transient trial services then vanish,
and the two enabled persistent units start. Trial session/key data remain on disk.

The user service uses mixed-cgroup shutdown: Herdr receives the graceful stop
first, then remaining children are bounded by its stop timeout. On startup,
Herdr can restore supported agent panes to their recorded native conversation
sessions. This is a **new process resuming the same conversation**, not a process
surviving reboot. Existing `session.resume_agents_on_restore` preferences are
preserved; if you deliberately disabled restore, this feature does not override it.

In Heeler, retain the working SSH host/key/network settings and port **2222**, but
select the **default** Herdr session (or leave the session name blank). With the
existing iPhone Tailscale VPN, Heeler's Network setting remains Direct. Check the
host fingerprint against the machine's public SSH host key before trusting changes.

```bash
DOTFILES_HEELER_ENABLED=1 make ai-heeler-check
```

Make reports success or a failed recipe; it does not preserve distinct checker
failure codes. To distinguish states, invoke the launcher directly:

```bash
DOTFILES_HEELER_ENABLED=1 bash tools/herdr/heeler/install.sh --check
```

The launcher's exit `0` means the owned persistent services/default Herdr API
pass inspection; `2` means publication (including root publication drift or
unsafe metadata), enrollment, enablement or cutover is pending; `1` means invalid
user preparation, a failed service (including failed attempts awaiting automatic
restart), an inspection error or invalid live state. SSH retries caused by an
offline Tailscale node instead report an explicit waiting state with exit `2`.
A pending-publication result never makes foreign or writable root artifacts safe
to overwrite: inspect and resolve them before following the publication recipe.
The check performs no repair or mutation.
It verifies immutable root publication paths, persistent enablement, lingering,
loaded unit identity, default API peer PID/cgroup, actual SSH process arguments
and the sole listener on the current tailnet IPv4. A merely working unmanaged
default socket is **not** reported as managed-live. Phone authentication and
terminal usability still require the device check.

Verify after the controlled boot:

- Both persistent services are active and enabled; standard SSH remains masked.
- Heeler checks pass for **default**, displaying the expected real agents.
- Desktop `herdr` and the phone operate the same conversation; test reconnect
  and cellular with Tailscale connected.
- Native Pi authentication and conversation history remain in their original
  locations; no browser state or proxy service is needed for terminal access.

## Disable and rollback

Opting out alone stops no service. To remove boot persistence without interrupting
current work, disable the two new units without stopping them. A full stop is a
separate maintenance operation: stopping `dotfiles-herdr.service` terminates its
owned agent processes, so do not do that during active turns.

Restore operator-created backups of owned root policy files if rolling back an
update, reload the relevant manager, and restore the previous enablement. The
preparer removes automatic transaction backups after success: they are not a
successful-update archive. To revert user policy after a successful update,
re-prepare the previous reviewed canonical revision, or restore an explicit
operator backup; stop Pi first if changing any of its linked resources. Do not
unmask ordinary SSH, change Tailscale networking, delete Herdr trial state, rotate
keys, or rewrite Pi sessions as a rollback side effect. The historical
`heeler-trial/authorized_keys` file is still the active phone key, not disposable
trial data. Controlled WSL restarts remain explicit operator operations.
