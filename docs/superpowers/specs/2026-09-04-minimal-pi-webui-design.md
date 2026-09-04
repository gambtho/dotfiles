# Minimal Pi Web UI integration design

## Goal

Replace PR #15 with a reviewable, opt-in integration for
`@firstpick/pi-package-webui@0.10.3` around the existing
`@earendil-works/pi-coding-agent@0.84.4`. Preserve the healthy machine-local
installation and its tailnet-only access model while removing historical trial
documents, adversarial same-user hardening, forensic transaction machinery,
and exhaustive syscall-level tests.

The implementation starts from `origin/main`, not from PR #15. The two exact
runtime lock artifacts are the only source files copied directly from that PR.

## Supported environment and trust model

The installer supports Ubuntu 24.04 Noble under WSL with a working systemd user
manager. Explicit Web UI commands fail before mutation elsewhere. Normal
`make ai` behavior remains portable and unchanged.

Validate user input and external-system boundaries. Trust normal guarantees from
the current Unix account, `/usr/bin`, mise, Pi, Git linked-worktree metadata,
npm lock integrity, systemd user services, Tailscale, and files already owned by
the current user under the managed state root.

A malicious or concurrently mutating same-user process is out of scope. Do not
add executable hashing, file-descriptor trampolines, inode-race defenses,
signal-boundary transactions, crash consistency at every operation, or retained
forensic generations. Use strict shell mode, quote paths, create private
staging directories, check important statuses, and reject obvious symlinks or
foreign ownership at destructive boundaries.

## Stable product behavior

- Firstp1ck runs standalone and is never registered with `pi install`.
- Runtime installation uses `npm ci --ignore-scripts --omit=optional`.
- Optional companions and `node-pty` must not be installed.
- The service binds only to `127.0.0.1:31415`.
- Remote ingress is only Tailscale Serve HTTPS 443 proxying to
  `http://127.0.0.1:31415`; Funnel, wildcard binds, direct LAN exposure, and
  foreign or additional routes are refused.
- The existing Pi permission system remains enabled and unchanged. Browser-native
  controls are outside that permission boundary, so trusted tailnet clients
  have the authority of the WSL account.
- A systemd user service starts while WSL and its user manager are active.
- The initial tab uses the clean detached linked worktree at
  `~/.local/share/pi-webui/worktrees/dotfiles`. Firstp1ck may subsequently open
  other projects and create or select branch worktrees.
- Default rollback removes only the managed service and unit. It preserves
  runtime, worktrees, settings, transcripts, supervisor state, Tailscale
  identity, backups, and trial evidence.
- Run-level Abort remains unavailable while a permission modal is open; dialog
  Deny or Cancel blocks the request. Restart may create a fresh tab, while saved
  transcripts remain manually resumable.
- Windows-local access uses `http://127.0.0.1:31415`; Tailscale runs only inside
  WSL.

## Repository interface

The integration consists of:

- `ai/pi/webui/runtime/package.json` and `package-lock.json`: byte-pinned runtime.
- `bin/validate-pi-webui`: compact tracked and installed-runtime validation.
- `ai/pi/webui/install.sh`: read-only check and candidate-first reconciliation.
- `ai/pi/webui/pi-webui.service.in`: systemd user-unit template.
- `ai/pi/webui/tailscale.sh`: explicit operator actions and route checks.
- `ai/pi/webui/rollback.sh`: conservative service removal and optional cleanup.
- `ai/pi/webui/README.md`: setup, operation, trust boundary, and recovery.
- `tests/pi_webui.bats`: focused behavior tests.
- `make ai-webui` and `make ai-webui-check`: opt-in public entry points.

Normal `make ai`, `make ai-check`, `bin/install`, and ordinary Pi package
reconciliation do not invoke these helpers.

## Runtime validation

The tracked validator requires:

- manifest SHA-256
  `073ba87cad124eb709eb8cafdd77c44c10b5d12bf5841acea140a50ac5177763`;
- lock SHA-256
  `39593de061e22a36668a0a0d1449e339b84e644d6c65e6b1618af9d177fc71d0`;
- lockfile version 3 and exact root dependency;
- Firstp1ck `0.10.3` with its accepted registry integrity;
- the expected 350 registry package entries and six repaired nested Earendil
  `0.84.4` entries.

Installed-runtime validation additionally proves the expected package versions
and launchers and that no `node-pty` directory was installed. Optional
`node-pty` metadata may remain in the lock because installation omits optional
dependencies.

## Installation and update flow

`install.sh --check` performs no mutation. It validates platform, systemd, the
tracked lock, external Pi `0.84.4`, source repository identity, landing
worktree state when present, installed runtime when present, unit configuration
when present, active health when the service is running, and Tailscale state
through the checker. Check mode may run from a linked review worktree.

Production `--apply` runs only from the canonical primary checkout when its
`HEAD` exactly matches `origin/main`. This prevents an unmerged implementation
branch from changing the persistent landing revision. Tests may opt into an
explicit fixture-only source override that is unavailable in ordinary use.

`install.sh --apply` performs this sequence:

1. Run apply preflight and refuse unresolved legacy candidate, transaction, or
   apply-lock evidence without deleting it.
2. Create a private sibling candidate runtime and run the exact npm command.
3. Revalidate the unchanged lock and validate the installed candidate.
4. Accept or create the landing worktree only when it belongs to the same Git
   common repository, is detached, and is clean. Permit only an absent `.pi`
   tree or an exactly empty `.pi/plans/` tree; reject other ignored state.
5. Render and validate the candidate unit using stable live paths.
6. Record the previous detached commit, runtime and unit locations, and service
   enablement/activity in shell state and a private temporary staging directory.
7. After every candidate check passes, stop the known managed service, advance
   the landing worktree to canonical `origin/main`, and publish the candidate
   runtime and unit in that order.
8. Reload systemd, restore the intended enablement, start the service, and verify
   active health.
9. After successful health verification, discard the temporary rollback copies.

The post-stop portion is a bounded recovery state machine. Before service stop,
a failure removes only the candidate and leaves live state unchanged. After
service stop, every failure path first stops any candidate service, then restores
in reverse publication order: prior unit, prior runtime, prior landing commit,
systemd daemon state, enablement, and finally activity. Each step is conditional
on whether its corresponding publication checkpoint completed. Restoration is
attempted for failures after runtime publication, worktree checkout, unit
publication, daemon reload, enablement changes, startup, and health validation.
A failed restoration is reported with the retained private staging path for
manual inspection. Process death or machine failure at every instruction
boundary remains outside the simplified threat model; there is no persistent
transaction journal.

The reconciler retains only the temporary prior runtime and unit needed during
an apply. It does not rotate or manage historical trial evidence. Existing
backups, evaluation records, old runtime generations, and recognized marker
files remain untouched.

Configuration validation proves that the rendered unit has the exact loopback
arguments, durable initial cwd, and external Pi launcher. Active-health
validation separately requires an active managed unit, a loopback-only listener,
Web UI `0.10.3`, Pi `0.84.4`, `network.open=false`, and an exactly empty
`network.networkUrls`. Every running managed tab must report the exact Pi
launcher, but its cwd may be any user-selected project or worktree. Under the
accepted same-user trust model, service state, exact unit configuration, the
loopback listener, and Firstp1ck health identity are sufficient; process-ancestry
or inode-level listener proofs are deliberately excluded.

## Tailscale boundary

`tailscale.sh` retains these explicit actions:

- `check`: non-mutating platform, daemon, authentication, local-service, LAN,
  and route validation.
- `install`: publish the official Noble repository and install Tailscale at an
  explicit sudo checkpoint.
- `up`: run interactive authentication without accepting or persisting an auth
  key.
- `serve`: publish only HTTPS 443 to the exact loopback backend.
- `serve-off`: remove only that exact route.
- `uninstall`: remove only the managed package and repository files after the
  route is empty, without purging identity.

Route classification accepts only a semantically empty state or one root proxy
to the exact backend. It rejects public `AllowFunnel`, additional handlers,
multiple hosts, and foreign targets. Because Serve and Funnel can share JSON
state, public exposure is determined from `AllowFunnel` and tailnet-only human
status rather than non-empty Funnel JSON alone.

The LAN check discovers global IPv4 interfaces without assuming `eth0`, excludes
`tailscale0`, and confirms the Web UI port is unreachable on discovered WSL LAN
addresses.

## Rollback

The default rollback first requires empty Serve state, proves that the unit is
the managed Web UI service, stops and disables it, removes only its unit, and
reloads systemd. A shutdown POST or systemd's normal cgroup cleanup must leave
no listener on port 31415.

`--remove-runtime` and `--remove-worktree` are separate explicit choices. They
reject symlinks, foreign ownership, an active installation, dirty or attached
worktrees, foreign repositories, and persisted `.pi` state before recursive
deletion. They never remove settings, transcripts, Tailscale identity, backups,
or retained evidence.

## Testing

Use Bats and TDD for meaningful behavior. The 43 focused tests cover:

1. exact tracked hashes, identities, and installed optional-dependency absence;
2. unsupported-platform refusal before mutation;
3. exact npm flags and lock preservation;
4. candidate validation before stopping an existing service;
5. canonical `origin/main` apply refusal from an implementation worktree;
6. landing-worktree creation and primary, attached, foreign, or dirty refusal;
7. unit loopback, durable cwd, exact Pi launcher, and clean shutdown settings;
8. separate active health for versions, network fields, and exact tab launchers
   while permitting other project cwd values;
9. restoration after representative runtime, unit, systemd-reload, and health
   publication-boundary failures;
10. empty/exact/foreign/Funnel Tailscale route classification;
11. interface-agnostic LAN detection excluding `tailscale0`;
12. default rollback preservation and explicit cleanup guards; and
13. Make target isolation from ordinary `make ai`.

Verification includes the focused Bats suite, syntax, shellcheck, shfmt,
`bash bin/validate-ai --verbose`, and full `make check`. After source review,
run only check mode against the healthy live installation. Any apply that would
replace live state or service files requires separate user approval.

## Size and scope controls

The generated lockfile is excluded from the authored budget. Target 1,000–2,000
human-authored added lines and stop for approval before exceeding 2,500.

Do not add Piface or Firstp1ck trial documents, the old permanent execution
plan, SDD ledgers, evaluation transcripts, syscall-permutation tests, archive
machinery, browser self-update, optional voice/LAN/package-management
companions, Funnel, or same-user adversarial defenses.
