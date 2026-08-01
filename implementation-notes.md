# Reliability Follow-ups Implementation Notes

## Approved constraints

- Devcontainer credential sharing is deny-by-default. Host SSH and GitHub CLI
  credentials require the explicit `--share-host-auth` opt-in and remain
  read-only.
- Project-overlay ownership is home-independent and matched by the exact
  `projects/<slug>/...` target suffix; foreign overlays and edited shims remain
  untouched.
- `KUBERNETES_CHANNEL` is operator-owned compatibility policy. Automated pin
  updates report upstream drift but never choose a new cluster minor.
- Every new behavior is covered by `make check`. The Python suite must be an
  actual `check` prerequisite, executable seed source must participate in bash,
  shellcheck, and shfmt discovery, and Compose publication must test rollback
  after the first of two files is published.

## Decisions and deviations

- The extracted seed previously exited the whole script when its sentinel was
  current. That would bypass the new base-command dispatch on warm starts, so
  the sentinel now skips only gated persisted-volume work before continuing to
  `--argv` or `--shell`. Focused tests cover this warm-start path.
- The approved helper interface has no workspace argument even though the old
  prose template expected one. The seed now discovers the enclosing Git
  worktree from its own mounted path (falling back to its directory), preserving
  the public CLI and supporting both root-level and `.devcontainer/` Compose
  layouts without path guessing.
