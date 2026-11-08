# User cache maintenance

Opt-in Linux systemd user timer, separate from the AI review automations. Normal
install, update, AI setup and automation installation do not enable it.

From the primary `~/.dotfiles` checkout, after the change has landed:

```sh
make cache-maintenance        # copy units and enable the timer; no cleanup now
make cache-maintenance-check  # next run, last result, or not installed / never run
systemctl --user disable --now dotfiles-cache-prune.timer
journalctl --user -u dotfiles-cache-prune.service
```

The timer runs Sundays at 04:00 local time with up to 30 minutes' random delay.
There is no catch-up after an offline period or login. WSL and the user manager
must be running; without linger, expect missed runs while logged out. Installation
only warns about linger and never enables it. Units live in the user systemd config
directory; they invoke the primary checkout, so installation rejects linked worktrees.

To explicitly run cleanup now, use `bash libexec/cache-prune` from the checkout.
This deletes caches and unused Docker data, including stopped containers and their
writable layers. It can cause cold builds/downloads, remove offline availability,
or lose persistent data. **Stopped containers are removed first, then all unused
named and anonymous local volumes are deleted in the same run.** This includes a
stopped database's volumes or a `compose down` stack's data when no remaining
container references them. It never prompts. To opt out of weekly cleanup, disable
the timer with `systemctl --user disable --now dotfiles-cache-prune.timer` as shown
above. This stops all weekly cache cleanup, not just Docker.

| Cache | Native-cleanable allocated size that triggers cleanup | Pinned root |
|---|---|---|
| Go | at least 20 GiB; hex buckets and `log.txt` only | `${XDG_CACHE_HOME:-$HOME/.cache}/go-build` |
| uv | at least 5 GiB; whole cache | `${XDG_CACHE_HOME:-$HOME/.cache}/uv` |
| npm | at least 5 GiB; `_cacache` only | `$HOME/.npm` |

Only these conventional home cache paths are used; custom tool cache settings are
not followed. Root ancestors and immediate cleanup targets must not be symlinks.
Native internal links are allowed. The helper uses only native cache-clean commands,
never a recursive-delete fallback. Go modules/fuzz cache, npm npx/logs and other
application data outside the Docker scope below are left alone. npm startup logging
is pinned inside `_cacache` too, so inherited log-rotation settings cannot reach a
separate directory. Small Go metadata files remain after cleaning.

Missing tools, unresolved mise shims, absent caches, unsafe paths or observed busy
work are logged as skips. Mise auto-install is disabled; Go ignores inherited flags
and user Go settings, and cannot auto-download a toolchain. Go skips on current-user
`go`, `compile`, `link`, `asm`, `cgo` or `vet`, not `gopls`. npm skips only fetching
`npm install`, `npm i`, `npm ci`, `npm update` or `npm add` titles, not long-running
`npm exec`, `npm run`, `npx` or node agents. Inspection failures also cause a skip.

## Docker

Docker has no size threshold or age filter: every run with a responsive daemon uses
`docker system prune -a -f`, then `docker volume prune -a -f`, then
`docker buildx prune -a -f`. This removes all stopped
containers (including writable-layer data), unused networks, unused images (not just
dangling images), and unused build cache, including buildx internal/frontend cache.
An image used only by a stopped container may be deleted once that container is removed.
Local images that were never pushed must be rebuilt; running containers are not pruned.

Volume pruning removes **all unused local volumes**, not just anonymous ones.
"Unused" means no remaining container references the volume, not that its data is
disposable. Volumes formerly used only by stopped containers become eligible after
system pruning removes those containers. Volumes referenced by remaining containers
and bind-mounted host files are not pruned. Volume `-a` requires Docker API 1.42+;
unsupported versions report a cleanup failure, with no fallback.

Docker uses the invoking user's native configuration and environment. The timer does
not load interactive shell startup files; configure its environment explicitly if
needed. The configured daemon may be remote or shared (including Docker Desktop's
WSL/Windows daemon), so pruning is not restricted to data created by this checkout
or Linux user. Buildx prunes the **selected builder**, which can also be remote;
other configured builders are not enumerated. Journal entries include before/after
`docker system df` summaries, not verbose inventories; these show daemon usage and
may not include a separate buildx builder's cache. Native output is prefixed `docker|`.

A missing CLI or a daemon that fails its 10-second probe is a successful skip.
Once, immediately before the first deletion, a current-user process snapshot skips
Docker for observed
`docker` command lines containing `build`, `buildx` or `compose` words, and for
`docker-buildx`, `buildx` or `docker-compose` processes. Matching is conservative:
those words in a `docker exec`/`run` command can also cause a skip. Inspection failures
skip Docker too. A missing buildx plugin is a cleanup failure after system pruning,
not a successful skip; install buildx to complete all cleanup steps.

## Safety and results

The process check is best effort, **not a lock against builds**: a build can start
between the check and Go or Docker cleanup, so cleanup may fail or disrupt it.
Other users' or remote Docker builds are not visible in the snapshot. uv uses its
native cache locking. A private flock only prevents two copies of this helper from
running together. Native tools/PATH are trusted; same-user path replacement races
are not contained. Nothing kills or waits for another build.

Results and residual usage go to the journal. Measurements are bounded to 60 seconds,
probes to 10 seconds, and each native cleanup to 2 minutes. Docker calls also have a
5-second forced-termination grace period. The service's overall limit remains
15 minutes; if several tools approach their limits, systemd may interrupt the run
before Docker completes or logs its after summary. A very large cache may exceed the
measurement budget and remain untouched.

Measurement or cleanup errors/timeouts continue to other caches but return failure;
expected skips return success. A failed Docker before measurement prevents its cleanup.
After a Docker cleanup failure, the helper still attempts the remaining cleanups and after
summary, within the service limit. There are no retries or escalating deletion commands.
