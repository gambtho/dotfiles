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
This removes rebuildable data and can cause cold builds/downloads or remove offline
availability. It never prompts; inspect the scope below before running it.

| Cache | Native-cleanable allocated size that triggers cleanup | Pinned root |
|---|---|---|
| Go | at least 20 GiB; hex buckets and `log.txt` only | `${XDG_CACHE_HOME:-$HOME/.cache}/go-build` |
| uv | at least 5 GiB; whole cache | `${XDG_CACHE_HOME:-$HOME/.cache}/uv` |
| npm | at least 5 GiB; `_cacache` only | `$HOME/.npm` |

Only these conventional home cache paths are used; custom tool cache settings are
not followed. Root ancestors and immediate cleanup targets must not be symlinks.
Native internal links are allowed. The helper uses only native cache-clean commands,
never a recursive-delete fallback. Go modules/fuzz cache, npm npx/logs, Docker and
other application data are left alone. npm startup logging is pinned inside `_cacache`
too, so inherited log-rotation settings cannot reach a separate directory. Small Go
metadata files remain after cleaning.

Missing tools, unresolved mise shims, absent caches, unsafe paths or observed busy
work are logged as skips. Mise auto-install is disabled; Go ignores inherited flags
and user Go settings, and cannot auto-download a toolchain. Go skips on current-user
`go`, `compile`, `link`, `asm`, `cgo` or `vet`, not `gopls`. npm skips only fetching
`npm install`, `npm i`, `npm ci`, `npm update` or `npm add` titles, not long-running
`npm exec`, `npm run`, `npx` or node agents. Inspection failures also cause a skip.

The process check is best effort, **not a lock against builds**: a build can start
between the check and Go cleanup, so cleanup may fail or disrupt it. uv uses its
native cache locking. A private flock only prevents two copies of this helper from
running together. Native tools/PATH are trusted; same-user path replacement races
are not contained. Nothing kills or waits for another build.

Results and residual usage go to the journal. Measurements are bounded to 60 seconds,
probes to 10 seconds, and each native cleanup to 2 minutes; the service limit is
15 minutes. A very large cache may exceed the measurement budget and remain untouched.
Measurement or cleanup errors/timeouts continue to other caches but return failure;
expected skips return success. There are no retries or escalating deletion commands.
