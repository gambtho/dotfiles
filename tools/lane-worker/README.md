# Lanes worker box

A lanes worker runs lanes with Claude Code but is not a full dotfiles machine. For a
lane's review round it needs the `gambtho-skills` plugin and the review CLIs those
skills call. `install.sh` installs only those:

| What | Why | Where |
|---|---|---|
| `gambtho-skills` plugin at the pinned tag | the review skills (`pr-closeout`, `adversarial-review`, `codex-review.sh`) | `ai/claude/install.sh`, user scope |
| `codex` (pinned, whole release package) | cross-family review through `codex-review.sh` | `~/.local/bin/codex` |
| `coderabbit` (pinned) | the local CodeRabbit review round in `pr-closeout` | `~/.local/bin/coderabbit` |
| `jq` (pinned), only if lanes find none | the plugin installer and `pr_snapshot.sh` | `~/.local/bin/jq` |

Each tool unpacks into `~/.local/share/lane-worker/<tool>-<version>/`, and
`~/.local/bin/<tool>` links to it. Codex keeps its whole package there, including the
`bwrap` helper its read-only sandbox uses. Versions and SHA-256 digests live in
`config/versions.env`; `make pins-check` reports newer releases. Every download is
checked against its digest before anything is unpacked.

## First run on a box without dotfiles

The box needs `git`, `curl`, `tar`, `python3` and Claude Code (`claude`), which a
worker already has. No `make` or `sudo` is needed. Run it from a plain login shell
as the user the lanes run as, not from inside a lane (a lane may set
`CLAUDE_CONFIG_DIR`, and the plugin would go there).

```bash
git clone https://github.com/gambtho/dotfiles ~/.dotfiles
bash ~/.dotfiles/tools/lane-worker/install.sh --check   # dry run: says what it would do
bash ~/.dotfiles/tools/lane-worker/install.sh --apply
```

With `make` installed, `make lane-worker-check` and `make lane-worker` do the same. A
second run with the same pins downloads and changes nothing. Later,
`git -C ~/.dotfiles pull --ff-only` and `--apply` again move to new pins.

Do not run `make install`, `make bootstrap` or `make ai` on a worker. They set up a
whole machine.

## Sign-in afterwards

The script never signs in or copies credentials. Once per box, as the user the lanes
run as:

```bash
gh auth status              # GitHub CLI; lanes already need it
codex login --device-auth   # Codex, for codex-review.sh (works without a browser on the box)
coderabbit auth login       # CodeRabbit, for the local review round
```

Running Claude Code sessions keep the skills they loaded; a new lane started after
the run loads `gambtho-skills`.

To check Codex's sandbox once on a new box:
`codex exec --skip-git-repo-check --sandbox read-only - <<<'run ls' </dev/null`. If it
reports that bubblewrap cannot run, the box's AppArmor policy blocks unprivileged user
namespaces; that needs an owner decision (for example a system `bubblewrap` package),
not this script.

## What it changes, and what it leaves alone

It writes the tool folders, their links in `~/.local/bin`, and what `ai/claude/install.sh`
and the `claude` CLI write. On a box where the plugin is already at the pinned tag,
that is nothing. Otherwise `ai/claude/install.sh`:

- adds the marketplace and installs the plugin at user scope;
- when the marketplace points at another ref (a later pin bump), removes it, which
  uninstalls the plugin, then adds and installs it again. Run a pin bump when no lane is
  in the middle of a review;
- removes `~/.claude/skills` links that point into `~/.dotfiles`, recording their names
  in `~/.local/state/dotfiles/claude-legacy-links.txt`. A worker set up this way has none.

The `claude` CLI itself may rewrite `~/.claude.json` when queried, even under `--check`.

It does not change the login shell, shell profiles, `environment.d` or any other PATH
file, systemd user units, Herdr, lanes or `~/.developerlanes`, and it runs no `sudo`,
`systemctl`, `chsh`, `herdr` or `lane` command. It does not use CodeRabbit's own
`install.sh`, which may edit shell profiles to put `~/.local/bin` on PATH.
`tests/lane_worker_install.bats` checks this against a sandboxed home.

A tool counts as present when lanes would find it: in `~/.local/bin` or the system
directories a systemd user service has on PATH (`/usr/local/bin`, `/usr/bin`, `/bin`).
One found only through an interactive shell (mise shims, npm or bun folders) does not
count, so the pinned build is installed. A file in `~/.local/bin` that is not a link
this script made is left alone; move it aside and rerun to get the pinned build. If
`~/.local/bin` is not on the shell's PATH, the script says so and does not fix it.

Old version folders stay after a pin bump, because a running lane may still use them.
Delete them once no lane does. To undo everything: remove the links in `~/.local/bin`
that point into `~/.local/share/lane-worker`, that folder, then run
`claude plugin marketplace remove gambtho-skills`.
