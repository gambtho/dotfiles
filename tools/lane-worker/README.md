# Lanes worker box

A lanes worker runs lanes with Claude Code but is not a full dotfiles machine. For a
lane's review round it needs the `gambtho-skills` plugin and the review CLIs those
skills call. `install.sh` installs only those:

| What | Why | Where |
|---|---|---|
| `gambtho-skills` plugin at the pinned tag | the review skills (`pr-closeout`, `adversarial-review`, `codex-review.sh`) | `ai/claude/install.sh`, user scope in `~/.claude` |
| `codex` (pinned) | cross-family review through `codex-review.sh` | `~/.local/bin/codex` |
| `coderabbit` (pinned) | the local CodeRabbit review round in `pr-closeout` | `~/.local/bin/coderabbit` |
| `jq` (pinned), only if none is on PATH | the plugin installer and `pr_snapshot.sh` | `~/.local/bin/jq` |

Versions and SHA-256 digests live in `config/versions.env`; `make pins-check` reports
newer releases. Every download is checked against its digest before it is installed.

## First run on a box without dotfiles

The box needs `git`, `curl`, `tar`, `python3` and Claude Code (`claude`), which a
worker already has. No `make` or `sudo` is needed.

```bash
git clone https://github.com/gambtho/dotfiles ~/.dotfiles
bash ~/.dotfiles/tools/lane-worker/install.sh --check   # dry run: says what it would do
bash ~/.dotfiles/tools/lane-worker/install.sh --apply
```

With `make` installed, `make lane-worker-check` and `make lane-worker` do the same.
Later, `git -C ~/.dotfiles pull --ff-only` and `--apply` again move to new pins. A
second run with the same pins downloads and changes nothing.

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

Running Claude Code sessions keep their loaded plugins; a new lane started after the
run loads `gambtho-skills`.

## What it leaves alone

It writes only the three binaries above, its receipt at
`~/.local/state/dotfiles/lane-worker-tools`, and what `claude plugin` writes under
`~/.claude`. It does not change the login shell, shell profiles, `environment.d` or any
other PATH file, systemd user units, Herdr, lanes or `~/.developerlanes`, and it runs
no `sudo`, `systemctl`, `chsh`, `herdr` or `lane` command. It also does not use
CodeRabbit's own `install.sh`, because that edits shell profiles to add `~/.local/bin`
to PATH. `tests/lane_worker_install.bats` checks all of this against a sandboxed home.

`~/.local/bin` is where a worker's `claude` already lives, so lanes find the new tools
there. If the script reports that `~/.local/bin` is not on PATH, it does not fix that
for you.

A tool already on PATH somewhere else is left as it is. So is a file in
`~/.local/bin` that this script did not install, or that changed after it was
installed (for example by `coderabbit update`). Move it aside and rerun to get the
pinned build.

To undo: remove the binaries the receipt lists, then the receipt, then run
`claude plugin marketplace remove gambtho-skills`.
