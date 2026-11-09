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
base settings, with the optional imported-prefix extension below. A minimal base file is:

```json
{"repos":["example/project"],"me":"example-user"}
```

Existing keys remain accepted: `repos`, `ours`, `own_only`, `watch`, `aliases`,
`notifications`, `internal_tracker`, `me`, `record_files`, `shared_root`,
`decision_prefix`, `lane_prefix`, `legacy_lane_prefixes`, and `tracked_series`. Unknown keys are errors.
`legacy_lane_prefixes` is a list of `W` or lowercase letters followed by `-w`, for example
`["old-w"]`. Imported prefixes affect observation only, never allocation; the active
`lane_prefix` remains unchanged. Omitted or empty lists retain legacy `W` observation;
repeated prefixes are deduplicated.
Groups are subsets of repos; watch entries are `["owner/repo", 12]`; aliases map
shorthand to repositories. Relative paths resolve against the selected root;
`~` expands, shell expressions do not. Local text inputs are capped at 1 MiB.

Login precedence is `--me`, base `me`, then authenticated `gh api user`. Unknown
identity leaves dependent activity unknown; no guessed author/global search.
Summary labels use the first configured alias for a repo, else its basename.
Notifications and the internal tracker default **off** in a configured project.
When externalizing former defaults, explicitly retain intended flags and aliases.

Other supplemental settings belong in optional `coordination-checks.json`, not in
`coordination.json`; other consumers must support its imported-prefix extension before use:

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

## Optional local observations

Add only the resources the coordinator wants observed:

```json
{
  "checkouts": [{"repo":"example/project","path":"~/project"}],
  "disk": {
    "filesystem":"~", "minimum_free_gib":50,
    "output_roots":["lanes","reports","~/project-worktrees"],
    "caches":{"go":"~/.cache/go-build","uv":"~/.cache/uv","npm":"~/.npm"},
    "cache_check_checkout":"~/config"
  }
}
```

Absent components say not checked; configured failures say unknown. In `--check`,
checkout/worktree observations run before STATE queries, disk/cache last. In sweep
mode disk/cache runs after activity; checkouts require `--check`. They share the
same global deadline/request ledger. Disk gets at most 120 remaining seconds;
Git/df commands get at most 10 seconds, du/cache commands 20, clipped to budget.

Primary status includes branch, HEAD, dirtiness and local tracking-ref divergence,
not live upstream freshness. NUL-delimited Git output preserves paths with spaces
or newlines. Worktrees are capped at 100; detached, missing, prunable and locked
entries are explicit. One cached query per repository observes at most 100 open
and 100 recently updated closed PRs. Mapping matches head repository **and** branch;
forks do not match by branch name alone. Prefer a unique current open match;
otherwise report a unique observed recent closed match. Incomplete/ambiguous
coverage stays unknown. No match is not proof of merge/deletion; no fetch/prune.

Disk compares `df -Pk` available KiB with the configured floor (default 50 GiB).
Below-floor output says Needs the human; nothing edits STATE or cleans up.
Only immediate output directories are candidates (max 100); files/child symlinks
are excluded and overlapping candidates deduplicated. Show up to five largest
`du -sk` measurements; omitted/failed coverage qualifies the ranking as partial.
Only configured caches are measured; missing caches say absent, not measured zero.

Cache inspection runs only fixed `make -s --no-print-directory -C CHECKOUT
cache-maintenance-check`. This trusts the operator-owned checkout/target, not
arbitrary configured commands. Exit 0 is not health: preserve not-installed,
never-run, failed last result and the reported timer/service details. A successful
last run does not assert timer health; unrecognized/non-systemd output is unknown.

## Output, checkpoint and failures

Default mode prints the sweep with a compact summary. `--since` overrides the
root's `.morning-last-run`; otherwise the window is the preceding 24 hours.
`--no-save` prevents advancing that checkpoint. Complete requested GitHub activity
advances it atomically; failed/incomplete activity retains its previous bytes.
This includes required tracked-series CSV inputs. Supplemental local health
unknowns cannot freeze the activity window. The sole enrichment exception is the
referenced-issues section: its 25-lookup/global-budget skips list every unchecked
`repo#number` and count as not checked, not failed, so they cannot trap the stamp.
A real read failure there still retains it; all other activity rules are unchanged.

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
Failed commands show a bounded first stderr line with rate-limit (including
secondary), authentication, not-found or timeout classification. Credential/token
patterns and URLs are removed; raw stderr is never dumped. No retries or waiting
for rate limits. Report contents are private
project observations: keep them local; nothing uploads them. Run one coordinator
invocation per project at a time; atomic publication does not prevent lost updates
between competing writers. `--help` is offline and does not change files.
