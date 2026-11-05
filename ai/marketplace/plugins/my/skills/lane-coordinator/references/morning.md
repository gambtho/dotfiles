# Shared morning sweep and STATE drift

Run the bundled checker from a configured project, or select its root explicitly:

```sh
python3 /path/to/lane-coordinator/scripts/morning.py --root ~/example-local
python3 /path/to/lane-coordinator/scripts/morning.py --root ~/example-local --check
```

Requires Python 3.10+, `gh`, and a POSIX host. Git is used for the advisory local
STATE commit. The checker reads GitHub; it never mutates PRs/issues/notifications,
edits STATE, reserves lane numbers, deletes files, or runs cleanup.

## Project configuration

The selected root must contain `coordination.json`; there is no fallback project,
repository inventory, or personal login. Existing configured projects keep their
base file's vocabulary. A minimal base file is:

```json
{"repos":["example/project"],"me":"example-user"}
```

Existing keys remain accepted: `repos`, `ours`, `own_only`, `watch`, `aliases`,
`notifications`, `internal_tracker`, `me`, `record_files`, `shared_root`,
`decision_prefix`, `lane_prefix`, and `tracked_series`. Unknown keys are errors.
Groups are subsets of repos; watch entries are `["owner/repo", 12]`; aliases map
shorthand to repositories. Relative paths resolve against the selected root;
`~` expands, shell expressions do not. Local text inputs are capped at 1 MiB.

Login precedence is `--me`, base `me`, then authenticated `gh api user`. Unknown
identity leaves dependent activity unknown; no guessed author/global search.
Summary labels use the first configured alias for a repo, else its basename.
Notifications and the internal tracker default **off** in a configured project.
When externalizing former defaults, explicitly retain intended flags and aliases.

New settings belong only in the optional `coordination-checks.json`, not in the
base file (other tools may use its original strict allowlist):

```json
{"limits":{"seconds":300,"queries":10}}
```

`limits` can lower the default 300 seconds / 600 HTTP requests. Every read/page,
identity lookup, watched issue and review-thread query consumes the same budget.
Five seconds are reserved for output publication. Network reads are individually
bounded to 30 seconds; captured stdout/stderr is bounded to 16 MiB per command.
Pagination follows `Link rel=next`, including short nonfinal notifications pages.
Failure, malformed data, truncation or exhaustion means unknown, never clean.
The limits are not throughput guarantees; busy windows may need explicit `--since`
recovery. There are no automatic retries or timeout increases.

For `internal_tracker: true`, supply its target in the sidecar:

```json
{"internal_tracker_source":{"host":"git.example.test","repo":"example/tracker"}}
```

The sidecar also accepts reserved `checkouts` (repo/path objects) and `disk`
settings (filesystem, floor, output roots, caches, cache-check checkout). **This
version does not implement these collectors.** They are explicitly not checked,
not healthy; no configured local roots or cache commands are invoked. The prior
unconditional home-disk line/cleanup hint is not retained. Adoption can begin with
the shared GitHub sweep; local collectors arrive in a separate change.

## Output, checkpoint and failures

Default mode prints the sweep with a compact summary. `--since` overrides the
root's `.morning-last-run`; otherwise the window is the preceding 24 hours.
`--no-save` prevents advancing that checkpoint. Complete requested GitHub activity
advances it atomically; failed/incomplete activity retains its previous bytes.
This includes required tracked-series CSV inputs. Supplemental local health
unknowns cannot freeze the activity window. No skipped activity is acknowledged.

`--check` reads STATE and writes `STATE-DRIFT.md` plus `STATE-DRIFT-folders.txt`
under the selected root, without changing the checkpoint. **`--check --no-save`
still writes these receipts**; the flag controls the sweep checkpoint only.
Writes use private same-directory temporary files and atomic replacement per file,
not a multi-file transaction. Failed folder-list publication is disclosed as
potentially stale. Missing STATE does not replace a prior receipt with a stub.

Check mode retains the existing bounded project-root old-folder advisory and
local document/closed-owner checks. Archive discovery uses `CLOSED-*.md`, with
shared-root fallback. Candidate/archive reads are capped at 100 and old-folder
walks at 10,000 entries; skipped coverage is unknown. This is not a disk scan.
PR check summaries are tied to the queried head commit; absent/truncated/mismatched
metadata is unknown. `checks=none` means no reported checks, not passing CI.

Exit 0 means the observation was rendered, **not** healthy or merge-ready.
Exit 1 means required input/publication failed; exit 2 means invalid CLI/config.
Failure messages avoid raw subprocess diagnostics. Report contents are private
project observations: keep them local; nothing uploads them. Run one coordinator
invocation per project at a time; atomic publication does not prevent lost updates
between competing writers. `--help` is offline and does not change files.
