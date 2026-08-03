# Persistent Development Workspace Platform — Phase 1 Design

Status: proposed
Date: 2026-08-03
Scope: Phase 1 only. No notification delivery, dashboard, or agent lifecycle management.

## 0. Ground truth

The originating request stated environment facts that the machine contradicts. This design is built
against the machine.

| Stated | Actual | Source |
| --- | --- | --- |
| Repos under `~/src` | `~/workspace`, 37 repos, 7 with `.devcontainer/` | filesystem |
| Shell is bash | `/usr/bin/zsh` (Prezto + p10k); scripts remain bash | `$SHELL` |
| Container runtime unresolved | Native Docker Engine - Community, `unix:///var/run/docker.sock` | `docker context ls` |
| devcontainer CLI presence unknown | Shim present but **non-functional**; see below | `command -v`, execution |
| systemd enabled | Confirmed, and `Linger=yes` | `loginctl show-user` |

The devcontainer CLI row is the one that matters most, because it is a trap rather than a fact:

```
$ command -v devcontainer   → /home/tng/.local/share/mise/shims/devcontainer   (exit 0)
$ devcontainer --version    → mise ERROR No version is set for shim: devcontainer
$ mise exec node@25.9.0 -- devcontainer --version → 0.86.1
```

The CLI was installed under `node@25.9.0`; the active global is `node@26.5.0`, which has no such
package, so the shim resolves, is executable, and fails on every invocation. **Presence detection by
`command -v` is therefore worthless here** — it returns success for a binary that cannot run. Every
detection in this design validates by *executing* the tool, never by finding it, and this is the case
that proves why. See ADR-5 for how the CLI is pinned and invoked.

Additional confirmed facts that shape the design:

- tmux 3.4; per-window `remain-on-exit` verified working on this build.
- yq v4.45.1 (mikefarah) and jq 1.7, both present; yq is already a pinned managed artifact
  (`bin/common.sh` `install_pinned_yq`, `bin/versions` `check_artifact_release`).
- `flock(1)` present.
- No `dev` command, alias, or function currently on `PATH`.
- `bin/claude-link-project` links only `CLAUDE.md`, `AGENTS.md`, and `.claude/` out of
  `projects/<slug>/`; a `workspace.yaml` sibling is inert to it.
- `bin/claude-link-project` resolves its overlay slug from **the primary working tree's** basename
  so linked git worktrees inherit the parent repo's overlay.
- `ai/vekil/vekil.service` documents that a systemd *user* unit cannot order itself after Docker
  (a system service) and solves it with a bounded poll.
- `tools/tmux/tmux.conf.symlink` injects optional config via `# ...-config-start/end` markers
  wrapping a `source-file` of a separate conf under `tools/`.
- Devcontainers mount `~/.dotfiles` read-only at `/host-seed/.dotfiles` and **seed-copy** it into a
  container-local volume. The container's `~/.dotfiles` is a stale copy.
- `extra_hosts: host.docker.internal:host-gateway` plus vekil binding the Docker bridge means
  in-container agents already have a working credential path.

### Standing assumptions

1. `~/.dotfiles/projects/` moves to a private repository before this design is implemented. All
   overlay paths are therefore addressed through `DEV_OVERLAY_ROOT` (default `$DOTFILES/projects`)
   rather than hardcoded, so the migration is a variable change.
2. `~/workspace` is the repository root. Configurable as `DEV_REPO_ROOT`.
3. Phase 1 is local-WSL only in *verification*, but nothing in it may be local-only in *design*.

---

## 1. Architecture

### 1.1 Component boundaries

**`bin/dev`** — dispatcher only. Resolves `dev <word>` to a subcommand, or failing that to
`open <word>`, then delegates to `tools/dev/commands/<name>.sh`. One file per subcommand is what
makes `close`, `doctor`, `update`, `notify`, `logs`, `restart`, and `agent` additive rather than
structural.

Seven libraries under `tools/dev/lib/`, each with a single responsibility:

**Resolver** — turns a name or a `cwd` into `(slug, worktree_path, workspace_id, session_name)`.
`slug` identifies the primary repository and governs *configuration*; `worktree_path` is the actual
working tree; `workspace_id` is the globally unique state key and `session_name` the display name
(ADR-7 defines both). The slug function moves into `bin/common.sh` and `claude-link-project` is
changed to call it, so the two tools cannot develop divergent notions of identity.

**Config** — emits exactly one artifact: a normalized JSON document merging, in order,
`tools/dev/default-workspace.yaml`, `$DEV_OVERLAY_ROOT/<slug>/workspace.yaml`, and
`$DEV_OVERLAY_ROOT/<slug>/workspace.local.yaml`. Every other component consumes that JSON; no other
component reads YAML. `dev config <name>` prints it, which is both the answer to "what layout am I
actually getting" and the seam that makes the merge unit-testable without tmux or Docker.

**Runtime** — detection, never hardcoding: docker socket reachability, compose vs single-container,
and the devcontainer CLI resolved to an **invocation** and recorded. Not a path: on this machine the
CLI's shim resolves and then fails (§0), so Runtime records an absolute `mise` binary plus a pinned
tool spec, and validates it by executing `devcontainer --version` and requiring exit 0 with a
parseable version. A tool that is found but cannot run is recorded as absent (ADR-5).

**Container** — owns all devcontainer concerns: `devcontainer up`, parsing the JSON tail line into
`containerId` / `remoteUser` / `remoteWorkspaceFolder`, liveness checks, and constructing an *exec
command builder*. It attempts `devcontainer exec` and falls back to
`docker exec -u <user> -w <wd> <cid>`, absorbing the compose-path workaround
`bin/claude-devcontainer-up` already discovered. For a plain WSL repo it returns a null container
and a builder that is simply `bash -lc`. This is the boundary that keeps devcontainer handling from
leaking upward: every layer above Container is written once and works for both repository kinds.

**Backend (tmux)** — the only file permitted to reference tmux. Five operations:
`create`, `apply_layout`, `query`, `respawn_pane`, `kill`. `query` returns backend-neutral JSON
(session name, windows, per-pane alive/dead, attached client count). Nothing upstream parses tmux
output, which is what makes acceptance scenario 5 true by construction.

**State** and **Events** — own `~/.local/state/dev/`. One record per working tree under
`workspaces/<workspace_id>.json`, one append-only `events/events.jsonl`, and `locks/`. Three locks
with distinct jobs, detailed in ADR-1 and §4.4: a per-workspace **state lock** held only across a
record read-modify-write, a per-workspace **operation lock** held across repair, and a global
**events lock** serializing rotation against appends.

**Reconcile** — the only component permitted to read both State and Backend and to notice that they
disagree. It is read-only with respect to the workspace: it writes records and events, and never
starts, creates, or respawns anything (ADR-1). Repair belongs to `open`'s ensure phase alone.

**`tools/dev/dev-event`** — a deliberately tiny emitter invoked by tmux hooks. It appends one line
under a *shared* lock on the global event file and touches no record (see §4.4). It never writes to
`workspaces/`; that is reconcile's job alone.

### 1.2 Data flow: `dev slabledger`

1. **Resolve** → slug `slabledger`, tree `~/workspace/slabledger`, `workspace_id` from the path
   digest, session name `slabledger`.
2. **Config** → merged JSON, plus a `config_digest` (sha256 of the normalized document).
3. **Reconcile** (read-only) → take the state lock; ask Backend what is actually live; fold any
   hook-appended events; write deltas to the record and the event log **before anything acts**;
   release the lock. Every command begins from observed truth rather than from a stale record, and
   this step is identical for `open`, `list`, and `status` precisely because it changes nothing.
4. **Ensure** (repair; `open` only) → take the operation lock `flock -n`, or report that another
   `dev` holds it and exit.
5. **Runtime** → detect compose; resolve the devcontainer CLI by *executing* it (ADR-5).
6. **Container** → `devcontainer up`, which is idempotent and returns the existing container when
   one is healthy. This is why acceptance scenario 2 is safe: warm container plus live session means
   `open` degenerates to `attach` and touches nothing.
7. **Backend** → find session `slabledger`, verify its recorded worktree matches the resolved path
   (ADR-7), and attach; or create it and apply the layout, executing each window's command through
   the builder Container supplied.
8. **Events** → `workspace.opened` or `workspace.attached`. Release the operation lock.
9. **`bin/dev`** execs the attach and gets out of the way.

The load-bearing invariant: **`open` never destroys.** It is `reconcile → ensure → attach`, where
`ensure` is a set of idempotent existence checks. There is no code path from `open` to
`kill-session`. In Phase 1 the only command permitted to destroy is `dev stop`, and it says so in its
name; `restart` is deferred (§5.2) because `stop` followed by `open` already is it.

### 1.3 The host-side tmux decision, stated plainly

One tmux server runs on the WSL host. For devcontainer repos, each pane's process is an exec into
the container; the session, the window layout, and the scrollback are host-side objects that outlive
any container.

The existing `bin/claude-devcontainer-up` does the opposite — it ends with
`exec docker exec -it -u "$user" -w "$wd" "$cid" tmux new -A -s claude`, running the tmux *server*
inside the container, which is why it needs 25 lines of apt/apk/dnf logic to install tmux into
images that lack it. That arrangement cannot satisfy acceptance scenario 3: a rebuild takes the
session, the layout, and every line of scrollback with it.

Corollary constraint: **`dev` is a host-side tool and must never be required to run inside a
container.** The container's `~/.dotfiles` is a seed-copy, so a `dev` invoked in there would be
operating on stale configuration against a tmux server it cannot see. Phase 1 handles this by
**refusing**: `dev` detects `/.dockerenv` and exits with a message naming the host tmux server as the
place to run it. Detecting and delegating to the host would be friendlier but requires a host channel
that does not exist, and inventing one to make a wrong invocation work is the wrong trade.

### 1.4 Acceptance scenario walkthroughs

**Scenario 3 — container rebuilt while attached.** The host tmux server never notices; it owns the
session. What dies is each pane's exec process. With per-window `remain-on-exit on`, those panes
remain visible with their output intact, marked dead, and tmux fires `pane-died`. The next `dev`
command reconciles: Container observes the recorded `containerId` no longer exists, `devcontainer up`
returns a new one, the record is updated, the event pair `container.lost` / `container.replaced` is
written, and `respawn_pane` reattaches each dead pane to the new id. The running processes are lost —
nothing can save those — but the session, layout, and prior output survive, and nothing is deleted.

**Scenario 4 — `pkill tmux`, then `dev list`.** The server dies, taking its own hooks with it, so no
`session-closed` event is emitted; this is the one case hooks structurally cannot self-report.
`dev list` reconciles first: records claim `running`, Backend reports no server at all. Every such
record transitions to `stopped` with `reason: vanished`, a `workspace.vanished` event is written
carrying `discovered_at` (when we noticed) as distinct from `ts`, and the listing reports those
workspaces as stopped. The platform reports what it observed and is explicit that the death time is
unknown — honest rather than crashing, and honest rather than inventing a timestamp.

**Scenario 2 — `dev headlamp` with unsaved scratch work.** Reconcile finds a live session. `ensure`
finds the container healthy and every declared window already present. `open` degenerates to
`attach`. No window is recreated, no command re-run, no pane respawned. The scratch buffer is
untouched because no code path from `open` reaches a destructive tmux verb.

Two independent guarantees protect that buffer, which is deliberate. The first is the non-destructive
`open` path above. The second is that the default `scratch` window is host-side (§4.2), so even the
one event that *does* kill panes — a container rebuild — cannot reach it. A repository that moves
`scratch` into the container keeps the first guarantee and gives up the second.

**Scenario 1 — lid closed, reconnect from iPad hours later.** Honest answer, split in two. *Over
SSH to a remote host* (Azure VM, reached via Tailscale): the tmux server and its panes are
unaffected by client disconnection; the test run continues and output is intact on reattach. This
works. *Locally on WSL2*: closing the laptop lid suspends the Windows host, and the WSL2 VM is
suspended with it — Windows may reclaim it entirely. The test process is frozen at the moment of
suspend or gone. **No design decision in this platform can change that**; it is a property of the
virtualization layer. The platform's obligation is to detect the discontinuity and report it
truthfully, which ADR-1 case B specifies via boot-id comparison.

**Scenario 5 — future dashboard, no tmux parsing.** A consumer calls `dev list --json` for current
state and tails `events/events.jsonl` for transitions. Both are stable, versioned, backend-neutral
formats, and the dashboard never learns that tmux exists.

Specifically **not** `workspaces/*.json`. Records are last-observed, not current (ADR-2), so a
dashboard reading them directly would show `running` for sessions killed an hour ago — and it would
look correct in testing, because in testing the record was just written. `dev list --json` reconciles
before printing, which is the whole difference. The record format is documented in §4.3 for
comprehension, not as a consumer interface.

---

## 2. Architecture Decision Records

Presented in dependency order rather than the order originally listed, because the state-authority
choice is downstream of the reconciliation model and the language boundary is downstream of both.
Original decision numbers are noted for cross-reference.

### ADR-1 — Drift and reconciliation model *(originally decision 2)*

**Context.** State and tmux will diverge. The event stream is the only Phase 1 deliverable with
future consumers, so the *timestamps* it carries are as load-bearing as the events themselves. A
model that discovers a death hours later and records it as having happened at discovery time would
poison every notification target built on it, and the defect would only surface after those targets
existed.

**Decision.** tmux hooks emit events at the moment they occur; an on-command reconcile pass acts as
a backstop for anything hooks cannot report. No daemon.

Hooks are registered in `tools/dev/dev.tmux.conf`, sourced from `tools/tmux/tmux.conf.symlink`
between idempotency markers, following the existing `agent-teams-extras.conf` pattern. Hooks call
`tools/dev/dev-event`, which filters by whether the session name maps to a known record and exits
silently otherwise — global hooks fire for ad-hoc sessions too, and the log must not fill with noise
about sessions that were never workspaces.

`remain-on-exit` is set **per-window on platform-created windows only**, never globally. Set `-g` it
would change every ordinary pane in daily tmux use to stop closing on shell exit. This is also a
correctness dependency, not just a courtesy: `pane-died` fires only when `remain-on-exit` keeps the
pane, so scenario 3's event fidelity is downstream of getting this scoping right.

**Two phases, and the boundary between them is the most important line in this ADR.**

*Reconcile* is **read-only with respect to the workspace.** It observes the backend, folds any events
the hooks appended, updates records, and emits discovery events. It never starts a container, never
respawns a pane, never creates a window. It mutates *state*; it does not mutate the *workspace*. Every
command runs it — `dev list` and `dev status` included — which is exactly why it must be this narrow.
A `dev list` that starts seven containers because it noticed they were down is not a listing, and the
one command a user reaches for when they suspect something is wrong must be the one command that
cannot make it worse.

*Ensure* is the repair phase, and **only `open` runs it.** Starting containers, creating windows, and
respawning dead panes all live here. It is still non-destructive — that invariant is unchanged — but
it acts, and acting is a privilege the read-only commands do not get.

Everything below is written as "reconcile observes X, ensure repairs it," and where an earlier draft
said repair happened on "the next `dev` command," it now happens on the next `dev open`.

**Locking, which the phase split makes tractable.** Two locks per workspace, with different lifetimes:

*The state lock* (`locks/<workspace_id>.lock`) is held only across a read-modify-write of the record —
microseconds, no blocking subprocess inside it, ever. This is what ADR-3's boundary requires: holding
a lock across `devcontainer up` would mean holding it for minutes across a process that can hang, in
a language with no way to release it on an unexpected signal path.

*The operation lock* (`locks/<workspace_id>.op`) is taken `flock -n` for the whole of ensure. It is
not a state lock and is never held while writing records; it exists solely so two `dev` invocations
cannot repair the same workspace concurrently — two simultaneous `devcontainer up` calls on one
compose project is a genuine race with a genuinely confusing outcome. Failure to acquire is not an
error condition to retry: it means another `dev` is already working on this workspace, and the right
response is to say so and exit non-zero.

Releasing the state lock before ensure does mean the observation ensure acts on may be a few hundred
milliseconds stale. That is acceptable because every operation ensure performs is idempotent and
re-checks its own precondition immediately before acting — `devcontainer up` on a running container
returns it, `respawn_pane` on a live pane is a no-op. The operation lock covers the case idempotency
does not.

**Reconciliation rules, by drift case:**

*Case A — session killed by hand.* `session-closed` fires and the hook appends `workspace.stopped`
with an accurate timestamp. **The hook does not touch the record** — it cannot, because it holds no
state lock (§4.4 and §1.1), and a lock-free read-modify-write of a JSON file is precisely the corruption this
design is otherwise careful to avoid. The record transitions on the next reconcile, which folds that
event and observes the session gone. If the hook was missed entirely, the same reconcile finds record
`running` / backend absent and emits `workspace.vanished` with `discovered_at` instead.

This is the general rule, and it is worth stating plainly because an earlier draft got it wrong:
**hooks append events; only reconcile writes records.** Records are therefore *eventual* projections
of the event stream — they lag it by exactly one `dev` invocation. ADR-2's claim that records are
"authoritative for what happened" is a claim about the pair (record + event log) reaching the same
answer, not about the record being instantaneously current. The fold-equivalence test in §4.4 tests
precisely this: replay the log, fold it, and the result must equal what reconcile computed.

*Case B — WSL restarts.* The tmux server is gone and no hooks fired. Records claim `running`. Each
record stores the host **boot id** (`/proc/sys/kernel/random/boot_id`) captured at open. Reconcile
compares the current boot id against the recorded one: if they differ, every stale record is closed
with `reason: host_restart` rather than the ambiguous `vanished`. This distinction is what lets a
future consumer tell "the machine rebooted" from "the user killed it" without guessing, and it is
what makes autostart (ADR-5) able to act only on the former.

*Case C — container dies or is rebuilt.* tmux is unaffected; panes die. **Reconcile** observes that
the recorded container id no longer exists, emits `container.lost`, and marks the record. That is all
it does — `dev list` shows the workspace with a dead container and `dev status` says so, and neither
starts anything. **Ensure**, on the next `dev open`, takes the operation lock, calls `devcontainer up`,
emits `container.replaced`, and respawns dead panes against the new id.

This split is what makes scenario 3 recover *when the user asks it to* rather than as a side effect
of a query, and it is why `dev list` on a machine with seven dead containers is fast and inert instead
of a seven-minute rebuild storm.

*Case D — workspace YAML edited while running.* The stored `config_digest` no longer matches the
computed one. Reconcile emits `config.changed` and **does not mutate the running session**.
`dev status` reports that config has drifted and that `dev stop` followed by `dev <workspace>` will
apply it. Additive
reconciliation — creating newly declared windows into a live session — is deliberately *not* done in
Phase 1: it is half a migration, and a half-applied layout is harder to reason about than a clearly
stale one. The record retains both digests so a future `dev update` can implement this properly.

*Case E — VS Code stops the container (unlisted, but real).* `slabledger/.devcontainer/devcontainer.json`
sets `"shutdownAction": "stopCompose"`, so closing a VS Code window can stop the compose stack out
from under a live workspace. This is indistinguishable from case C at the observation layer and is
handled identically. The platform detects and recovers; it cannot prevent this, and this design does
not claim otherwise.

**Alternatives considered.**
*Lazy reconcile only, no hooks.* Simplest, pure bash, one lock per command. Rejected: a workspace
that dies at 03:00 would be recorded as dying at 09:00. Disqualifying for the event stream's stated
purpose.
*systemd daemon watching continuously.* True real-time for tmux *and* containers via `docker events`.
Rejected for Phase 1 as the point where bash stops being appropriate (ADR-3), and premature while
there are zero consumers.

**Consequences.** Session events carry true timestamps. Container events are best-effort: tmux hooks
know nothing about containers, so a container that dies under an idle pane produces no event until
something writes to that pane and fails, or until the next `dev` command reconciles. This is the
model's main limitation and it is the specified trigger for the daemon in ADR-3. The platform also
now owns a fragment of tmux configuration — real coupling to a backend nominally described as
replaceable, mitigated by keeping it in one sourced file that a different backend would simply not
install.

### ADR-2 — Role of `~/.local/state/dev` *(originally decision 1)*

**Context.** The long-term intent is that this directory becomes canonical and tmux becomes one
execution backend among several. Phase 1 should move toward that without pretending to have arrived.

**Decision.** The state directory is **authoritative for what is declared and what happened**, and
**not authoritative for what is running**. tmux is authoritative for liveness. Concretely: records
own identity, configuration digest, container binding, and lifecycle history; tmux owns the answer to
"is this session alive right now," and that answer is always re-observed, never trusted from disk.

**Alternatives considered.**
*Fully authoritative, tmux reconciled to it.* This is the eventual goal, but in Phase 1 tmux is the
actual durability mechanism — it is the only component keeping a process alive across a disconnect. A
state directory claiming authority over liveness would confidently report `running` for a session
killed thirty seconds ago, and every consumer would inherit that lie. Adopting it now buys the
architecture diagram at the cost of correctness.
*Pure cache of observed tmux state.* Honest but inert: it could not record a container binding, a
config digest, or anything tmux does not model, so every future capability would need a second store.
*Event log and metadata only, no records.* Forces every consumer to fold the entire event log to
answer "what is running," which is expensive and makes truncation of old events lossy in a way that
changes answers rather than just detail.

**The public contract that follows: `dev list --json`, not the record files.** Because records are
historical, a consumer that reads `workspaces/*.json` directly gets last-observed state and will
render stale `running` badges — the exact failure §5.1 names as the early warning that this ADR has
leaked. Reading records is therefore not the supported way to consume state. **`dev list --json` is
the snapshot contract**: it reconciles first, so what it prints is observed rather than remembered,
and it is versioned and backend-neutral. The pairing for any consumer is `dev list --json` for
current state and `events.jsonl` for transitions; the record files are an implementation detail of
the platform, documented in §4.3 so the format is understood, not so it is depended upon.

**Consequences.** `dev list` always costs one backend query — it cannot be answered from disk alone.
That is a deliberate price for never lying. The migration path to canonical state is concrete rather
than aspirational: when a backend gains the ability to be *restored from* a record instead of merely
*compared to* one, authority moves field by field. Records are versioned (`"v": 1`) so this can
happen without a flag day.

### ADR-3 — The bash boundary *(originally decision 5)*

**Context.** The request is to name the threshold now rather than discover it at 2,000 lines.

**Decision.** **The boundary is the daemon.** One-shot commands that take a `flock`, do bounded work,
and exit are comfortably within bash's competence — this is precisely what `flock` and `jq` are for,
and the repository already contains substantial, well-tested bash of this shape. A long-lived
reconciler holding state in memory across concurrent writers is not, and no amount of care makes it
so.

Four concrete triggers, any one of which warrants a compiled binary:

1. A persistent reconciler process is required — the moment container lifecycle events must be
   consumed from `docker events` in real time rather than polled at command time.
2. Event log queries need an index rather than `jq` over a tail.
3. Any single library file exceeds ~300 lines, or the total exceeds ~1,500.
4. Any requirement to hold a lock across an operation that can block indefinitely (a container pull,
   a network call), where bash's inability to select on multiple fds forces either a busy-wait or a
   correctness compromise.

Trigger 4 came within one draft of firing before implementation started. An earlier version of ADR-1
had reconcile call `devcontainer up` while holding the state lock — a lock held for minutes across a
process that can hang, which is exactly the condition described. The fix was structural rather than a
language change: the state lock is now held only across a record read-modify-write, and repair runs
under a separate non-blocking operation lock (ADR-1). Phase 1 therefore stays under trigger 4 by
design, not by luck, and if a future change reintroduces a blocking operation inside the state lock,
that is the trigger firing rather than a bug to patch.

**Language when triggered: Go.** The repository already has Go tooling in play, a single static
binary drops into `bin/` with no runtime to install or pin, and it cross-compiles for the Azure VM
target without ceremony. Explicitly rejecting Python: it would add a runtime dependency and a
virtualenv story to a repository that has deliberately avoided both.

**Alternatives considered.** *Start in Go now.* Rejected — it would front-load the cost before any
trigger has fired, and the CLI's actual work in Phase 1 is process orchestration, which is bash's
home ground. *Never leave bash.* Rejected — trigger 1 is a genuine architectural limit, not a
stylistic preference.

**Consequences.** The Backend contract's five operations and the JSON-only interfaces between
components are what make the eventual rewrite incremental: a Go binary can replace one library at a
time behind the same interfaces. This is a real, if unglamorous, reason to hold the line on "no
component parses another's internal format."

### ADR-4 — Where the agent runs for devcontainer repos *(originally decision 3)*

**Context.** The choice affects credentials, file watching, available toolchain, and rebuild
behavior.

**Decision.** **Inside the container**, launched through the same exec builder as every other window.

*Credentials* are already solved by existing machinery. The compose override sets
`extra_hosts: host.docker.internal:host-gateway`, and `ai/vekil/env.zsh` detects `/.dockerenv` and
switches the proxy endpoint accordingly, with `vekil.service` binding the Docker bridge specifically
so this works. The agent's model access requires no new mechanism.

*Configuration* also already reaches the container: `~/.dotfiles` is mounted read-only at
`/host-seed/.dotfiles` and seed-copied into a container-local volume, and per-project `CLAUDE.md` is
materialized as a real file in the repository rather than a symlink into `~/.dotfiles`, so nothing
dangles across the mount boundary.

*File watching* operates on the container's view of the bind-mounted repository. This is a native
Docker Engine on WSL2 ext4, not Docker Desktop over a 9p translation layer, so inotify behaves.

*On rebuild*, the agent panes die with every other pane and are respawned against the new container
id. Each agent restarts fresh. The requirement explicitly declines to assume the agent is a
well-behaved long-running process, so the design preserves no agent state across a rebuild and
promises none — the record notes an `agent.exited` / `agent.started` pair **per agent window** and the
scrollback of the prior conversation remains visible in each dead pane's retained output.

**Alternatives considered.**
*On the WSL host.* Rejected: with vekil already bridging credentials, running the agent outside costs
the container's toolchain — usually the entire reason the repository has a devcontainer — and buys
nothing.
*Configurable per window.* Rejected for Phase 1 as speculative. The schema's `windows[].agent_location`
field is reserved but unimplemented, so adding it later is additive.

**Consequences.** A repository whose devcontainer image lacks the agent binary gets dead agent
windows rather than working ones. The platform emits `agent.failed` carrying the window name and
leaves the pane; it does not
attempt to install the agent into the image. That is a deliberate reversal of what
`claude-devcontainer-up` does for tmux today, and it is correct: the host-tmux decision removes the
need to install anything into images, and re-introducing image mutation for the agent would give back
the property just gained.

### ADR-5 — Reboot and disconnect survival *(originally decision 4)*

**Context.** systemd is available and `Linger=yes` is already set, so user units genuinely start
without an interactive login. The request explicitly asks not to overclaim.

**Decision.** Precisely two mechanisms, with clearly separated claims.

*Survives disconnect:* the tmux server. This is the whole of it. Detaching a client — closing a
terminal, dropping SSH, closing a VS Code window — does not touch the session or its processes. This
requires no systemd involvement whatsoever and it already works.

*Survives reboot:* **containers only, opt-in per workspace, via a `dev-autostart.service` user
unit.** On boot the unit iterates workspaces with `autostart: true` and runs `devcontainer up` for
each. It does **not** create tmux sessions, apply layouts, or run startup commands.

The unit must copy the pattern `ai/vekil/vekil.service` established: a user unit cannot order itself
`After=` Docker, because Docker is a system service. It therefore polls for daemon readiness with a
bounded loop before proceeding.

**Invoking the devcontainer CLI is the sharp edge here, and the obvious approach is broken.**
Recording the absolute shim path would be worse than useless: on this machine
`~/.local/share/mise/shims/devcontainer` exists, is executable, and fails on every call because the
CLI lives under `node@25.9.0` while the active global is `node@26.5.0` (§0). A systemd unit invoking
that path gets a non-zero exit and a mise error on stderr, and the failure would be attributed to
Docker or to the devcontainer config rather than to tool resolution.

Three requirements follow, and they apply to interactive `dev` equally, not just to the unit:

1. **The CLI is a pinned managed artifact**, pinned to a specific mise tool version in
   `tools/dev/versions.toml` and installed by `install.sh`, following the precedent `install_pinned_yq`
   and `bin/versions check_artifact_release` already set for yq. An unpinned CLI whose availability
   depends on whichever node version happens to be global is not a dependency, it is a coin flip.
2. **Invocation is always `mise exec <pinned> -- devcontainer ...`**, resolved through an absolute
   `mise` binary path. Runtime records the mise path and the pinned tool spec, never a shim path.
3. **Detection is by execution, not by presence.** Runtime probes with `devcontainer --version`,
   requires exit 0 *and* a parseable version on stdout, and treats a resolvable-but-failing shim as
   absent. `dev doctor` reports this specific condition by name, because "installed but unrunnable"
   is the state a user is least likely to diagnose unaided.

The unit additionally needs `PATH` set explicitly, since mise shims and mise itself are absent from a
systemd unit's default environment. All of these are failure modes that are silent and confusing when
discovered late, which is the argument for building this in Phase 1 rather than deferring it.

Default is **opt-in, off**. Seven devcontainer repositories building on every boot is a slow boot and
substantial disk churn for workspaces that may not be touched that day.

**What explicitly does not survive a reboot:** tmux sessions, window layouts, scrollback, running
processes, and agents. Nothing in this design recovers them and nothing pretends to.

**Alternatives considered.**
*Full workspace restore on boot.* Rejected. Re-running declared startup commands with no human
present is a correctness question — which commands are safe to replay — that the schema has no way to
express. It would require a per-window `idempotent:` flag, which is exactly the speculative
complexity being avoided. It also collides with "never clobber": restore must distinguish "absent
because we rebooted" from "absent because I killed it deliberately," which is only answerable via the
boot-id discriminator introduced in ADR-1, and even then only for the reboot direction.
*Socket activation.* Rejected: there is no socket. The trigger is boot, not a connection.
*Shell hooks in zsh.* Rejected as a survival mechanism — a shell hook cannot run before a shell
exists, so it can only ever restore on first login, which is strictly worse than a user unit given
`Linger=yes` is already set. Retained only as a possible future ergonomic (auto-attach on `cd`).

**Consequences.** After a reboot, `dev slabledger` finds a warm container and a clean session, and is
fast. The honest limit is stated in the CLI's own output rather than buried in documentation:
`dev list` after a reboot shows prior workspaces as `stopped (host_restart)`, not as missing.

### ADR-6 — tmux server placement *(not in the original list; the most consequential choice made)*

**Context.** For devcontainer repositories the tmux server can live inside the container or on the
host. The existing `bin/claude-devcontainer-up` puts it inside.

**Decision.** One tmux server on the WSL host. Panes exec into containers.

**Alternatives considered.** *Server inside the container* — everything in the window is natively in
the container with no exec indirection, but a rebuild destroys session, layout, and scrollback,
`dev list` cannot enumerate workspaces without exec'ing into every container, and tmux must be
installed into every image. *Hybrid, agent on host* — rejected with ADR-4.

**Consequences.** Acceptance scenario 3 becomes achievable; it is not achievable otherwise.
`dev list` becomes a single host-side query, which is what makes scenario 5 and the event stream
tractable. The tmux-installation logic in `claude-devcontainer-up` becomes deletable. The cost: a pane
running `docker exec` does not receive the devcontainer's `remoteEnv` and `postAttachCommand`
treatment the way `devcontainer exec` does, which is why Container tries `devcontainer exec` first and
falls back only on the compose bug the existing script already documented. tmux's own notion of pane
`cwd` and environment is the host's, not the container's, and layout code must not assume otherwise.

### ADR-7 — Worktree identity *(not in the original list; required by the resolver)*

**Context.** "Every repository gets exactly one workspace" does not define what a git worktree is.
`~/workspace` contains `euro_trip` and `euro_trip-pr5`; `slabledger` has a `.worktrees/` directory.

**Decision.** One workspace per **working tree**; configuration inherited by **slug**. A worktree gets
its own tmux session rooted at its own path, and reads the primary repository's `workspace.yaml`.

**Alternatives considered.** *One workspace per primary repo, worktrees attach to it* — matches the
linker's rule exactly, but leaves you reviewing a PR in a shell sitting in the wrong directory.
*Worktrees out of scope* — they would silently get pure defaults, losing the project's agent and test
commands precisely when reviewing that project's code.

**Consequences.** No second identity concept is invented; the linker's existing rule is reused and
made explicit about governing configuration rather than sessions. A deleted worktree leaves a record
pointing at a nonexistent path — handled as the same case as "repository path no longer exists,"
which reconciliation must handle regardless.

**Naming, which the basename alone cannot carry.** An earlier draft used the working-tree basename as
the session, record, and lock name. That is not globally unique: `.claude/worktrees/<branch>` is a
convention used across this whole repository set, and branch names like `ui-pass`, `todo-cleanup`, and
`readme-branding` are generic enough that two projects will eventually collide. The failure is not a
harmless name clash — it is one workspace attaching to another project's session, or two workspaces
writing the same record and lock. Identity is therefore split in two:

*`workspace_id`* — `sha256(realpath(worktree))`, first 12 hex characters. This is the **only** thing
used to name files: the record is `workspaces/<workspace_id>.json` and the lock is
`locks/<workspace_id>.lock`. It is unconditionally unique, requires no collision check, and is stable
across renames of anything except the path itself. State can therefore never collide, including
before any collision check has had a chance to run.

*`session_name`* — the human-facing name, `<slug>` for a primary working tree and `<slug>--<basename>`
for a worktree. Readable, and the slug prefix already removes cross-project collisions. The residual
case is two worktrees of the *same* project with the same basename in different parents
(`.worktrees/review` and `.claude/worktrees/review`), so **attach is guarded rather than trusted**:
before attaching to an existing session, `open` compares that session's recorded `worktree` against
the resolved path and, on mismatch, uses `<slug>--<basename>--<hash6>` instead. The guard is what
makes the failure impossible rather than merely unlikely, and it is cheap because the record is
already keyed by path.

The record stores both fields; `session_name` is display and backend addressing, `workspace_id` is
identity. No component may derive one from the other.

**The `repo:` key is removed from the schema, because inheritance makes it actively wrong.** A
worktree reads the primary repository's `workspace.yaml`. If that file carries
`repo: ~/workspace/slabledger`, then opening `slabledger-pr5` would redirect it to the primary
checkout — the config layer would silently override the path the resolver just determined, and every
worktree of a project with a `repo:` key would land in the same directory. Since the resolver already
knows the working tree (that is its entire job) and the config layer inherits across trees, a path key
in an inherited file cannot be correct for more than one of its inheritors.

Repositories outside `DEV_REPO_ROOT` are handled where the ambiguity does not exist: `dev` run from
inside such a tree resolves by `cwd`, and `DEV_REPO_ROOT` itself is configurable for a wholesale move.
If a per-project path override is genuinely needed later, it belongs in the un-inherited
`workspace.local.yaml` layer, where it describes one machine's one checkout rather than every
inheritor of a shared file.

This is also what delivers **multiple concurrent window-groups on one project**. Two worktrees of
slabledger — `~/workspace/slabledger` and `~/workspace/slabledger-pr5` — are two workspaces, two tmux
sessions, two sets of four windows, and two containers, both inheriting slabledger's `workspace.yaml`.
Nothing extra is required to support that; it falls out of one-workspace-per-working-tree.

The addressing is deliberately plain: **a worktree is addressed by its directory basename**, so
`dev slabledger-pr5` opens the second group. No new syntax is introduced. `dev list` groups its output
by slug so the several trees of one project read as a set rather than as unrelated entries.

Two things are explicitly deferred to Phase 2. A `dev slabledger@pr5` addressing form, which requires
a worktree-discovery pass and a naming convention neither `~/workspace` nor `.worktrees/` currently
follows consistently. And platform-created worktrees (`dev new slabledger pr5`) — that would put
`git worktree add` and `git worktree remove` inside a tool whose central invariant is that it never
destroys, and Phase 1 should not be where destructive git operations are introduced.

---

## 3. Project structure

```
bin/
  dev                                  # Dispatcher; the only file symlinked onto PATH
  common.sh                            # MODIFIED: gains dev_slug_for_path(), shared with claude-link-project
  claude-devcontainer-up               # MODIFIED: tmux-install block removed; superseded by tools/dev
tools/dev/
  default-workspace.yaml               # The default layout; merged under every workspace
  dev.tmux.conf                        # Hook registrations; sourced from tmux.conf.symlink via markers
  dev-event                            # Minimal event emitter invoked by tmux hooks
  dev-autostart                        # Boot-time container starter; ExecStart of the user unit
  dev-autostart.service                # systemd user unit template (@DOTFILES_ROOT@ substituted)
  install.sh                           # Symlinks bin/dev, injects tmux markers, installs the unit
  lib/
    resolve.sh                         # name|cwd -> (slug, worktree_path)
    config.sh                          # YAML merge -> normalized JSON + config_digest
    runtime.sh                         # Docker/compose/devcontainer-CLI detection; validated by execution
    container.sh                       # devcontainer up, id parsing, liveness, exec-command builder
    backend-tmux.sh                    # create/apply_layout/query/respawn_pane/kill; only tmux consumer
    state.sh                           # Record read/write under flock
    events.sh                          # JSONL append and rotation
    reconcile.sh                       # Diffs records against backend; emits deltas
  commands/
    open.sh                            # Default verb; reconcile -> ensure -> attach. Never destroys
    attach.sh                          # Attach only; fails if absent rather than creating
    list.sh                            # Reconciled listing, human or --json
    status.sh                          # Single-workspace detail including drift
    stop.sh                            # Ends session; optionally stops container. The only destructive verb
    config.sh                          # Prints merged config JSON
tools/tmux/
  tmux.conf.symlink                    # MODIFIED: marker block sourcing tools/dev/dev.tmux.conf
.gitignore                             # MODIFIED: ignore projects/*/workspace.local.yaml
tests/
  dev_resolve.bats                     # Slug/worktree resolution, incl. euro_trip-pr5 case
  dev_config_merge.bats                # Three-layer merge, digest stability, local-overlay precedence
  dev_state_events.bats                # Record round-trip, lock behavior, JSONL rotation
  dev_reconcile.bats                   # All five drift cases against a fake backend
  dev_backend_tmux.bats                # Real tmux on a dedicated -L socket
  claude_link_project.bats             # MODIFIED: covers the extracted shared slug function
docs/superpowers/specs/
  2026-08-03-dev-workspace-platform-design.md   # This document
$DEV_OVERLAY_ROOT/<slug>/
  workspace.yaml                       # Per-repo overrides; version-controlled
  workspace.local.yaml                 # Machine-local, gitignored; secrets and host-specific env
~/.local/state/dev/                    # Runtime state; not in the repository
  workspaces/<workspace_id>.json       # One record per working tree, keyed by path digest
  events/events.jsonl                  # Append-only event stream
  events/events-<ts>.jsonl             # Rotated segments, newest-first retention
  locks/<workspace_id>.lock            # State lock: record read-modify-write only
  locks/<workspace_id>.op              # Operation lock: held across ensure/repair
  locks/events.lock                    # Global: exclusive for rotation, shared for appends
  runtime.json                         # Cached detection: mise path + pinned CLI spec, docker flavor
```

---

## 4. Workspace configuration

### 4.1 Schema

Three layers merge in order, later winning: `tools/dev/default-workspace.yaml`, then
`$DEV_OVERLAY_ROOT/<slug>/workspace.yaml`, then `$DEV_OVERLAY_ROOT/<slug>/workspace.local.yaml`.
Lists of windows merge **by window `name`**, not by position, so an override may adjust one window
without restating the layout.

```yaml
version: 1                      # int, required. Schema version

autostart: false                # bool, optional. Default false. Container-only boot start

devcontainer:                   # optional. Omit entirely for auto-detection
  enabled: auto                 # auto|true|false. auto = presence of .devcontainer/
  config: .devcontainer/devcontainer.json   # str, optional. Non-default location
  start_timeout: 300            # int seconds, optional. Default 300

environment:                    # map<str,str>, optional. NON-SECRET values only
  CGO_ENABLED: "0"              # Secrets belong in workspace.local.yaml

windows:                        # list, required (supplied by the default layer)
  - name: agent-1               # str, required. Unique; also the merge key
    agent: claude               # str|null. Non-null makes this an agent window
    command: null               # str|null. null = interactive shell. Mutually exclusive with agent
    cwd: null                   # str|null. Relative to repo root. null = repo root
    location: container         # container|host. Default container when one exists
    focus: false                # bool. Exactly one window may set true
```

There is deliberately **no top-level `agent:` block**. An agent is a property of a window, which is
what allows more than one per workspace. A single top-level block would need a `window:` field
cross-referencing `windows[]` by name, and that reference can drift out of sync with the list it
points at — a validation burden that buys nothing. Making the window the agent removes the reference
entirely and generalizes to N agents for free.

This also improves the event stream: `agent.started` / `agent.exited` / `agent.failed` carry the
`window` that identifies *which* agent. The single-agent design could not express that, and it is
precisely what the future "agents as first-class objects with status" capability requires.

`agent:` and `command:` are mutually exclusive on the same window; setting both is a config error
reported by `dev config`.

Reserved but unimplemented in Phase 1, documented so their later addition is additive rather than
breaking: `windows[].idempotent`, `windows[].agent_location`, `layouts.*`, `hooks.*`,
`kubernetes.context`.

### 4.2 Worked example — slabledger

`tools/dev/default-workspace.yaml` (the layer every workspace inherits):

```yaml
version: 1
autostart: false
devcontainer:
  enabled: auto
  start_timeout: 300
windows:
  - name: agent-1
    agent: claude
    focus: true
  - name: agent-2
    agent: claude
  - name: shell
    command: null
  - name: scratch
    command: null
    location: host
```

Four windows: two always agents, one shell that is the everyday terminal interface, and one
`scratch` that a repository may repurpose into whatever it actually needs.

`$DEV_OVERLAY_ROOT/slabledger/workspace.yaml` (tracked; overrides only what differs):

```yaml
version: 1
environment:
  CGO_ENABLED: "1"
windows:
  - name: scratch
    command: make test
    location: container
```

`$DEV_OVERLAY_ROOT/slabledger/workspace.local.yaml` (gitignored; never leaves the machine):

```yaml
version: 1
environment:
  DATABASE_URL: postgres://localhost:5432/slabledger_dev
```

Resulting behavior: `dev slabledger` detects the compose-based devcontainer, brings it up, and
creates four windows on the host tmux server. `agent-1`, `agent-2`, and `shell` exec into the `app`
service at `/workspace`; slabledger has repurposed `scratch` into a test window and moved it into the
container, so `make test` runs there with `CGO_ENABLED=1` and `DATABASE_URL` set. A repository that
leaves `scratch` alone gets a host-side pane at `~/workspace/<tree>`, which is where host-side git
operations belong.

Note the default `location:` split. `shell` defaults into the container because for a devcontainer
repository that is the development environment. `scratch` defaults to the **host**, and that is
load-bearing rather than incidental: it is the window most likely to hold unsaved work
(scenario 2), and a host-side pane cannot be killed by a container rebuild. Scenario 2's guarantee is
structural for as long as `scratch` stays on the host — a repository that overrides it into the
container, as slabledger does above, trades that guarantee away knowingly.


### 4.3 Workspace record

Referenced throughout §2 but defined here. One file per working tree at
`~/.local/state/dev/workspaces/<workspace_id>.json` — keyed by the path digest, never by a name, so
two projects with same-named worktrees cannot collide (ADR-7). Mutated only by reconcile, only under
the state lock.

```json
{
  "v": 1,
  "workspace_id": "9f2c4a7b1e05",
  "session_name": "slabledger",
  "slug": "slabledger",
  "worktree": "/home/tng/workspace/slabledger",
  "status": "running",
  "boot_id": "6f2a1c9e-...",
  "config_digest": "sha256:9a3f...",
  "applied_digest": "sha256:9a3f...",
  "container": {
    "kind": "compose",
    "id": "a710...",
    "user": "vscode",
    "workdir": "/workspace",
    "verified": false,
    "observed_at": "2026-08-03T14:02:11.412Z"
  },
  "agents": [
    { "window": "agent-1", "command": "claude", "state": "started" },
    { "window": "agent-2", "command": "claude", "state": "exited" }
  ],
  "opened_at": "2026-08-03T13:58:02.001Z",
  "last_seen": "2026-08-03T14:02:11.412Z",
  "stopped_reason": null
}
```

`status` is one of `running`, `stopped`, `unknown`. It records the **last observation**, never a
claim about the present — ADR-2 requires liveness to be re-observed on every command, and a consumer
that reads this field without a backend query is reading history.

`config_digest` is the digest of the current merged configuration; `applied_digest` is the digest of
the configuration the live session was actually built from. They differ exactly when drift case D has
occurred, which is what `dev status` reports and what a future `dev update` would act on.

`boot_id` is the host boot id captured at open, and is the discriminator that separates "the machine
rebooted" from "you killed it" (ADR-1 case B).

`agents` is a list rather than a single object because the schema makes the agent a property of a
window (§4.1) and the default layout carries two. Each entry's `state` is `started`, `exited`, or
`failed`, and mirrors the last `agent.*` event emitted for that window. This is the field a future
"agents as first-class objects" capability reads.

`container.verified` is `false` whenever the container was reported up but no readiness probe
confirmed it usable. In Phase 1 it is always `false`; see §5.3 for why this is recorded rather than
resolved.

`stopped_reason` is `null` while running, and otherwise one of `user`, `host_restart`, `vanished`,
`container_failed`.

### 4.4 Event stream

**Transport.** A single append-only file, `~/.local/state/dev/events/events.jsonl`, one JSON object
per line, opened `O_APPEND`.

**The concurrency protocol, stated correctly.** An earlier draft justified lock-free appends by citing
`PIPE_BUF`. That was wrong: `PIPE_BUF` is a guarantee about pipes and FIFOs and says nothing about
regular files. What `O_APPEND` actually guarantees is that the seek-to-end and the write are performed
as one indivisible step with respect to other writers, so two appenders cannot land at the same
offset. On Linux a single `write(2)` to a regular file additionally holds the inode lock for its
duration, so one syscall's bytes are not interleaved with another's — but that is an implementation
property of the filesystem, not a POSIX guarantee, and it only holds if the emitter really does issue
**one** syscall.

Three rules follow, and they are requirements on the emitter rather than folklore:

1. **One `write` per event.** `dev-event` composes the entire line in memory and emits it with a
   single `printf`. Not a `printf` of the object followed by a newline; not an incremental build with
   `>>` inside a loop. Anything that produces two syscalls can interleave.
2. **Events are size-capped** at 4 KiB, with free-form `data` truncated and marked `truncated: true`.
   The cap no longer has a `PIPE_BUF` justification — it is there because short writes are the case
   where the single-syscall property is easiest to rely on, and because an event large enough to need
   splitting is an event carrying something that belongs elsewhere.
3. **Rotation is globally serialized, and appends participate in that.** This is the part the earlier
   draft got structurally wrong: it protected rotation with the *per-workspace* lock, which cannot
   work, because the event file is global and workspaces hold different locks. Two workspaces would
   happily rotate the same file simultaneously, and an append during another workspace's rename would
   be written to an unlinked inode and silently lost.

   The protocol is one dedicated lock, `locks/events.lock`. **Rotation takes it exclusively**
   (`flock -x`); **every append takes it shared** (`flock -s`). Shared holders do not contend with one
   another, so the common path stays effectively uncontended, and the rename cannot begin while any
   append is in flight. This does mean `dev-event` takes a lock, contradicting the earlier claim that
   it takes none — a shared `flock` on an uncontended file costs microseconds, which is affordable in
   a tmux hook, and "cheap" was never worth buying with silent event loss.

Rotation is checked during reconcile, which is also the only place with a reason to look.

**Testing this is not optional.** The verification is a bats test that spawns N concurrent emitters
against one file while a rotation runs, then asserts every emitted event appears exactly once across
`events.jsonl` and its rotated segments, and that every line parses as JSON. Concurrency arguments
that are only reasoned about are how the `PIPE_BUF` error survived a draft.

**Schema.**

```json
{
  "v": 1,
  "ts": "2026-08-03T14:02:11.412Z",
  "event": "container.replaced",
  "workspace_id": "9f2c4a7b1e05",
  "slug": "slabledger",
  "session_name": "slabledger",
  "worktree": "/home/tng/workspace/slabledger",
  "data": { "old_id": "3f9c...", "new_id": "a710...", "reason": "rebuild" }
}
```

`v` versions the envelope. There is deliberately **no sequence number**: it could only ever be a
partial order, since hook-emitted events cannot take the lock required to assign one, and a
partially-ordered counter invites exactly the total-ordering assumption it cannot support. Ordering
is by `ts` and by position in the file, both of which are honest about their limits. `ts` is RFC 3339
UTC with milliseconds. Events discovered rather than observed additionally carry `discovered_at`, and
consumers must not treat `ts` as exact when it is present.

**Event types in Phase 1.** `workspace.opened`, `workspace.attached`, `workspace.detached`,
`workspace.stopped`, `workspace.vanished`; `window.created`; `pane.died`, `pane.respawned`;
`container.starting`, `container.ready`, `container.failed`, `container.lost`, `container.replaced`;
`agent.started`, `agent.exited`, `agent.failed`; `config.changed`.

Every `agent.*` event carries `data.window` naming which agent it describes, since a workspace has
more than one. There is no `reconcile.drift` event: a reconcile pass emits the specific events for
what it found (`workspace.vanished`, `container.lost`, `config.changed`), and a summary event on top
of those would carry no information the specific ones do not, while giving consumers a second, vaguer
thing to subscribe to.

The namespacing is deliberate: a future consumer subscribes to `agent.*` or `container.*` without
enumerating types, so adding types later does not break it.

**Retention.** Rotate when `events.jsonl` exceeds 8 MiB, checked during reconcile under an exclusive
`locks/events.lock`. Rotated segments are named `events-<RFC3339-basic>.jsonl`; the five most recent are
retained and older ones deleted. No compression — these are small, and keeping them greppable with
plain `jq` matters more than the disk.

Phase 1 ships **zero consumers**. Two bats tests establish that the stream is nonetheless real. The
first replays a full workspace lifecycle and asserts the log folds to the same state the records
report — this is the test that keeps records honest as *eventual projections* (ADR-1), since a hook
appends the event and only a later reconcile writes the record, and any divergence between the two
paths shows up here. The second is the concurrency test described above. Between them they cover the
two ways this design could be quietly wrong: disagreeing with itself, and losing writes.

---

## 5. Self-critique

### 5.1 The three decisions most likely to force a redesign

**1. ADR-1's no-daemon choice.** This is ranked first because it is the only decision here that is
hard to reverse: hooks and a daemon are different programs, not different configurations, and
everything about how events are timestamped and sequenced follows from it.

*Early signal:* the first time you want a notification for something that is not a tmux state change —
"tests finished," "the agent is waiting for input," "the container died while I was at lunch" — and
find you cannot express it as a tmux hook. Watch specifically for the urge to add polling to
`dev status`. That urge is the daemon asking to exist, and the moment it appears, ADR-3's trigger 1
has fired.

**2. ADR-2's split authority.** Splitting "declared and happened" from "running" is a real position,
not a compromise, but it means every consumer must understand that records are not self-sufficient.

*Early signal:* the first consumer that reads `workspaces/*.json` instead of calling `dev list --json`,
because reading a file is faster than shelling out. ADR-2 now names `dev list --json` as the public
snapshot contract explicitly, so the signal is narrower than it was: it is a consumer *ignoring* a
stated contract rather than one filling a gap. If a future dashboard displays stale `running` badges,
that is what happened.

**3. ADR-6's host-side tmux.** Ranked third only because it is clearly right for scenario 3, but its
cost is diffuse and accumulates: every place where "the pane's environment" matters, the host/container
split has to be reasoned about again.

*Early signal:* accumulating special cases in `backend-tmux.sh` that check whether a window is
host-side or container-side. Two or three are fine. If it reaches five, the exec builder abstraction is
too thin and the right fix is to push more of the environment decision down into Container.

### 5.2 Where this was over-engineered for Phase 1

The three cuts below were identified in review and are **applied** in the sections above; they are
recorded here with their reasoning so the decision is not silently re-litigated later.

**`seq` numbering was not worth what it cost.** It is only partially ordered anyway — hook-emitted
events cannot take the lock to assign one — so it delivered a guarantee weaker than the one its name
implies, while adding a field consumers may misread as total ordering. Timestamps plus the file's
natural append order already give consumers everything they need. Cut; the envelope is versioned, so
it can be added later if a consumer genuinely needs it.

**`reconcile.drift` as a distinct event type** duplicated information already carried by the specific
events emitted during the same pass. Cut.

**`dev restart` is deferred.** `stop` followed by `open` is the same thing, and shipping `restart`
would mean shipping a second destructive code path in Phase 1 before anything needs it. Keeping
Phase 1's destructive surface down to `dev stop` has real value while the reconciliation model is
still being trusted.

One candidate cut was **rejected**: reducing the default layout below four windows. The original
five-window default (`agent`, `shell`, `tests`, `logs`, `scratch`) was speculative in the wrong
places — `logs` and `tests` assume every repository has a meaningful long-running log and a
single test command. The replacement is not smaller but better shaped: two agent windows, a `shell`
that is the everyday terminal interface, and a `scratch` window a repository can repurpose. The
count is unchanged in spirit; what changed is that the default no longer guesses at project-specific
commands, and the layout matches how the workspaces are actually used.

None of these cuts change the Phase 2 destination. Everything genuinely load-bearing — the event
envelope, the record schema, the Backend contract, the merge order — stays.

### 5.3 The failure mode I am least confident about

**A partially-failed `devcontainer up` that reports success.**

Every other failure in this design is discrete and observable: the container exists or it does not,
the session is alive or it is not. This one is neither. `devcontainer up` returns a `containerId` and
exit 0 once the container is *running*, but slabledger's stack runs
`bash -c "bash local-seed.sh; exec sleep infinity"` and depends on a separate `db` service. There is a
window in which the container id is valid, `docker inspect` says running, panes exec in successfully —
and the seed has not finished, or the database is not accepting connections, or `local-seed.sh` failed
silently and the agent's configuration was never copied into place.

The platform will emit `container.ready` and be wrong. Worse, the reconciler cannot detect it: its
liveness check is "does this container id still exist," which returns true throughout. The user sees
an agent window with subtly wrong configuration, or a test window that fails for reasons unrelated to
the code.

The honest mitigation is a per-workspace readiness probe in the schema — a command that must exit 0
before windows are considered ready — but that is real complexity and it is deliberately **not** in
Phase 1. Instead: record the `devcontainer up` exit status and the full parsed JSON in the record,
emit `container.ready` with an explicit `verified: false`, and let the first honest consumer of that
field decide it needs a probe. Naming the uncertainty in the data is cheaper than guessing at the
mechanism now. This is a reversible call — adding a `readiness:` key to the schema later is purely
additive, and `container.verified` is already the field that would flip to `true`.

I am also moderately unconfident about **concurrent `dev` invocations from inside panes of the
workspace being reconciled** — `dev stop` run from within the session it stops kills its own
pane mid-command. This needs an explicit guard (detect `$TMUX` and the target session, refuse or
re-exec detached), and the guard is specified but not proven sufficient. The operation lock (ADR-1)
covers two `dev` processes repairing one workspace, which is the adjacent race, but it does not cover
this one: a single process killing its own pane holds the lock legitimately the whole time.

A third, and the one I would now rank alongside the first: **the event-append protocol is the part of
this design most likely to be subtly wrong in a way that reasoning does not catch.** The `PIPE_BUF`
justification in the previous draft was confidently argued, cited a real constant, reached a
conclusion that happens to hold on Linux ext4, and was wrong about why — and being wrong about why is
what let the rotation bug hide behind it, since a per-workspace lock cannot serialize a global file.
That error is fixed (§4.4), but the general lesson is that this is the one area where the spec's
prose is not evidence. The concurrent-emitters-plus-rotation test is therefore not a nice-to-have; it
is the only thing that will actually establish the protocol works.

### 5.4 Pushback on the specification

**The philosophy is right about layering and wrong about truth.** "tmux is a replaceable
implementation detail" is an excellent *interface* constraint and I have designed to it. But in
Phase 1 tmux is not a detail — it is the entire durability mechanism, the only component that keeps a
process alive across a disconnect. A design that took the philosophy literally would build a state
directory that claims to know what is running, and it would lie within the first week. The version
worth holding: tmux is replaceable *as an interface*, and load-bearing *as a mechanism*. ADR-2 is
where that distinction is cashed out, and it is the single most important disagreement with the spec
as written.

**Acceptance scenario 1 is not achievable as stated, and the reason is environmental.** Closing a
laptop lid suspends the Windows host and the WSL2 VM with it. The test run is frozen or gone. The
scenario is honest only against the Azure VM. I have split it accordingly rather than let the design
imply a guarantee it cannot make — but it is worth being explicit that this is the one requirement
the platform cannot satisfy by being better designed.

**"Every repository gets exactly one workspace" plus 37 repositories is a config-sprawl trap** and it
fights the spec's own goal of layout consistency. The resolution here — the absence of a file *is* the
consistency guarantee, and an override file exists only where a repository genuinely deviates — is a
better expression of the stated intent than the literal requirement. Realistically six or so of the
37 will ever need a file.

**The four drift cases are missing the one you will hit most often.** VS Code's Dev Containers
extension will start and stop the same containers this platform manages, and `shutdownAction:
stopCompose` is already set in slabledger. "VS Code edits code, the platform owns workspaces" is a
statement about intent, not a property the system can enforce. Handled as case E, detect-and-recover
only.

**The event stream is correctly prioritized, and the retention story is where over-engineering will
creep in.** The instinct to build indexing, compression, or a query interface should be resisted until
a consumer exists. Eight megabytes of JSONL and `jq` will serve for a long time.

---

## 6. Open questions and assumptions

**Assumed, proceeding unless corrected:**

1. `~/.dotfiles/projects/` moves to a private repository before implementation. Everything overlay-
   related is addressed through `DEV_OVERLAY_ROOT` so this is a variable change. The
   `workspace.local.yaml` layer is retained regardless — a private repository is not a secrets store.
   The `.gitignore` entry for `projects/*/workspace.local.yaml` ships in the **same commit** as the
   schema, so the safe path exists before the file that would need it. It follows the conventions
   already established at `.gitignore:18,21,41` (`gitconfig.local.symlink`, `projects.local.toml`,
   `projects/*/.claude/settings.local.json`).
2. Autostart defaults to off, per workspace.
3. Identity is split: `workspace_id` (path digest) names all state files; `session_name`
   (`<slug>` or `<slug>--<basename>`) is display-only and attach is guarded by a path check. Slugs
   remain configuration keys (ADR-7).
4. `bin/claude-devcontainer-up` is superseded and its tmux-installation block is removed as part of
   this work rather than left to rot. Its compose-bug workaround moves into `container.sh`.
5. Phase 1 is verified against local WSL only. The SSH/Azure path is designed for but not tested.
6. The default layout is two agent windows, `shell`, and `scratch`, with `shell` defaulting into the
   container and `scratch` defaulting to the host. The `scratch` default is what keeps scenario 2's
   guarantee structural rather than incidental (§4.2).
7. No readiness probe in Phase 1; `container.verified` records the uncertainty instead (§5.3).
   Reversible and additive if a "up but not usable" container bites in practice.
8. `dev` refuses to run inside a container rather than detecting and delegating to the host.
   Refusing is simple and safe; delegating needs a host channel that does not currently exist.
9. Concurrent worktree groups are addressed by directory basename. `dev slabledger@pr5` addressing
   and platform-created worktrees are Phase 2 (ADR-7).
10. The schema has **no `repo:` key**. The resolver owns the working tree; a path in a file inherited
    by every worktree of a project cannot be correct for more than one of them (ADR-7).
11. Reconcile is read-only with respect to the workspace; only `dev open`'s ensure phase repairs.
    `dev list` and `dev status` cannot start a container or respawn a pane (ADR-1).
12. Hooks append events and never write records. Records are eventual projections of the event
    stream, lagging it by one `dev` invocation (ADR-1).
13. The devcontainer CLI is pinned as a mise tool, invoked via `mise exec`, and detected by
    execution rather than by `command -v` (§0, ADR-5).

**Genuinely open, needing your input:**

1. **How much of `claude-devcontainer-up`'s behavior is load-bearing** beyond what I found by
   reading it? If you have hit devcontainer failure modes it silently handles, they belong in
   `container.sh` and I would rather learn them now than rediscover them.
