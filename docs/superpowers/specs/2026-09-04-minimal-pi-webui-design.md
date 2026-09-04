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
worktree state when present, installed runtime when present, rendered unit when
present, health when active, and Tailscale state through the checker.

`install.sh --apply` performs this sequence:

1. Run the same preflight and refuse unresolved legacy candidate, transaction,
   or apply-lock evidence without deleting it.
2. Create a private sibling candidate runtime and run the exact npm command.
3. Revalidate the unchanged lock and validate the installed candidate.
4. Accept or create the landing worktree only when it belongs to the same Git
   common repository, is detached, and is clean. Permit only an absent `.pi`
   tree or an exactly empty `.pi/plans/` tree; reject other ignored state.
5. Record the previous detached commit and advance the landing worktree to the
   invoking checkout's `HEAD`.
6. Render and validate the candidate unit using stable live paths.
7. After every candidate check passes, record prior service enablement/activity,
   stop the known managed service, and replace the runtime and unit.
8. Reload systemd, enable and start the service, then verify health.
9. If publication or health fails, restore the immediately prior runtime, unit,
   landing commit, enablement, and activity. Report any failed restoration and
   retain affected state for manual inspection.

The reconciler keeps only one immediate previous runtime needed for rollback.
It does not create persistent transaction metadata or manage historical trial
evidence. Existing backups, evaluation records, and recognized old marker files
remain untouched.

Health requires Web UI `0.10.3`, Pi `0.84.4`, loopback host and port,
`network.open=false`, and an exactly empty `network.networkUrls`. It validates
the managed initial cwd and Pi launcher from the unit or initial managed tab,
but does not reject user-created tabs in other projects.

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

Use Bats and TDD for meaningful behavior. Approximately 20–25 tests cover:

1. exact tracked hashes, identities, and installed optional-dependency absence;
2. unsupported-platform refusal before mutation;
3. exact npm flags and lock preservation;
4. candidate validation before stopping an existing service;
5. landing-worktree creation and primary, attached, foreign, or dirty refusal;
6. unit loopback, durable cwd, exact Pi launcher, and clean shutdown settings;
7. health versions and network fields while permitting other project tabs;
8. simple restoration after failed health verification;
9. empty/exact/foreign/Funnel Tailscale route classification;
10. interface-agnostic LAN detection excluding `tailscale0`;
11. default rollback preservation and explicit cleanup guards; and
12. Make target isolation from ordinary `make ai`.

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
