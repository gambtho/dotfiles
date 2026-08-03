# Personal Claude project overlays

Personal, machine-side Claude Code config for projects where you don't want to
commit your AI setup. Useful when:

- The project is public or open-source and your `CLAUDE.md` shouldn't leak.
- The team hasn't agreed on a `.claude/` convention.
- You want a private set of skills/agents for one project without shipping
  them to collaborators.

## Where the overlays live

Overlays are **not** in this repository. They describe the architecture,
security boundaries, and operational details of non-public codebases, and this
repository is public — so they live in a separate private repository that
`bin/bootstrap` clones to `~/.dotfiles/projects`.

`projects/` is ignored here, and `tests/repository_hygiene.bats` asserts that
nothing under it is ever tracked again.

### Attaching the overlay repo

Bootstrap reads the clone URL from `~/.dotfiles-projects-remote` — an untracked,
machine-local file, so the private repo's name never appears in this public
repository:

```bash
printf '%s\n' 'git@github.com:<you>/<your-overlay-repo>.git' \
  > ~/.dotfiles-projects-remote
~/.dotfiles/bin/bootstrap        # clones it to ~/.dotfiles/projects
```

The attach step is deliberately non-fatal. Bootstrap skips it and continues if:

- `~/.dotfiles/projects` is already a git repo (nothing to do),
- the pointer file is missing or empty (no overlay repo configured),
- `~/.dotfiles/projects` exists, is not a repo, and is not empty (it refuses to
  touch your files — move the directory aside and re-run), or
- the clone fails (no network, no key, no access).

A machine without overlays is a working machine. Only the overlay links are
missing.

## Layout

```text
~/.dotfiles/projects/          <- the private repo's working tree
  <project-name>/
    CLAUDE.md          # your personal instructions for this project
    .claude/
      settings.json    # project-scoped permissions, model, etc.
      settings.local.json  # machine-local; gitignored in the private repo too
      agents/          # personal subagents for this project
      commands/        # personal slash commands
```

A project name matches the directory name under `~/workspace/`, e.g.
`projects/slabledger/` overlays onto `~/workspace/slabledger/`.

## Linking into a project

Run `bin/claude-link-project <project-dir>` to symlink the overlay files
into a project working tree. The global gitignore at
`~/.dotfiles/core/git/gitignore.symlink` ignores `.claude/` and `CLAUDE.md`,
so the symlinks won't show up in `git status` for the project repo.

### The stable link root

Symlinks store an **absolute** target, so a link written as
`/home/<you>/.dotfiles/projects/myrepo/.claude/skills` only resolves on a
machine whose `$HOME` matches. A devcontainer bind-mounts the same working tree
under a different home (`/home/developer`, repo at `/app`), so every overlay
link dangles at once — `.claude/skills`, `.claude/agents`, `.claude/references`,
**and `CLAUDE.md`**, which means the project instructions never load either. The
same break happens on a second machine with a different username.

Repairing the links per environment cannot work: the host and the container see
the *same* bind-mounted file, so fixing it in one breaks the other.

Links therefore go through a stable root that every environment publishes at the
same path and aims at its own checkout:

```
host:      /opt/dotfiles -> /home/<you>/.dotfiles
container: /opt/dotfiles -> /home/developer/.dotfiles

~/workspace/myrepo/.claude/skills -> /opt/dotfiles/projects/myrepo/.claude/skills
```

Both sides stay writable; the container's root resolves into its own named
volume, so container writes never reach the host.

`bin/bootstrap` and `bin/relink` create the root for you. It needs `sudo` once
per machine, because `/opt` is root-owned:

```bash
~/.dotfiles/bin/relink        # prompts for sudo the first time
readlink /opt/dotfiles        # -> /home/<you>/.dotfiles
```

If it cannot be created — a locked-down host, no `sudo` — the linker warns and
falls back to `$HOME`-absolute targets. That is the old behavior, not a new
failure: links work locally and dangle in containers. Re-running the linker
after the root exists migrates every existing link in place.

`/opt` rather than a new top-level `/dotfiles` because macOS needs
`/etc/synthetic.conf` plus a reboot to create one, while `/opt` takes a plain
`sudo mkdir` on both platforms.

```bash
# Create a new overlay:
mkdir -p ~/.dotfiles/projects/myrepo/.claude
echo "# Personal notes for myrepo" > ~/.dotfiles/projects/myrepo/CLAUDE.md

# Link it into the project:
~/.dotfiles/bin/claude-link-project ~/workspace/myrepo

# Verify:
ls -la ~/workspace/myrepo/.claude ~/workspace/myrepo/CLAUDE.md
# both are symlinks into /opt/dotfiles/projects/myrepo/, which resolves to
# ~/.dotfiles/projects/myrepo/ here and to the container's own checkout there
```

## Committing an overlay

Overlay changes are commits in the **private** repo, not this one:

```bash
cd ~/.dotfiles/projects
git add myrepo && git commit -m "add project overlay for myrepo" && git push
```

Running `git add projects/...` from `~/.dotfiles` does nothing — `projects/` is
ignored here, and a forced add would fail the hygiene test.

## Removing the overlay from a project

```bash
~/.dotfiles/bin/claude-link-project --unlink ~/workspace/myrepo
```

This removes the symlinks but leaves the overlay files in place under
`~/.dotfiles/projects/`.

## Caveats

- Private is not the same as safe. Don't put **secrets** in an overlay even
  though the overlay repo is private — secrets belong in a secrets manager, or
  in a `.env` file that the project's own `.gitignore` already excludes, never
  in `CLAUDE.md` or any other overlay file. `settings.local.json` is gitignored
  in the private repo specifically because it accumulates machine-local
  permission grants and has captured a live token before.
- If a project already has a checked-in `CLAUDE.md` or `.claude/`, the
  linker refuses to clobber it. Rename it first or remove it.
- The overlay symlinks only exist inside the project working tree. Devcontainers
  that run inside a project see them like any other file — but only if the
  container publishes `/opt/dotfiles` too. The seed script generated by
  `my:project-claude-setup` does that on every start; without it the links
  dangle inside the container even though they are fine on the host.
- `git clean -xdf` in `~/.dotfiles` leaves `projects/` alone: git does not
  descend into a nested repository without a second `-f`. `git clean -xdff`
  **will** delete it, along with any unpushed overlay commits.
