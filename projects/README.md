# Personal Claude project overlays

This directory holds **personal**, **machine-side** Claude Code config for
projects where you don't want to commit your AI setup. Useful when:

- The project is public or open-source and your `CLAUDE.md` shouldn't leak.
- The team hasn't agreed on an `.claude/` convention.
- You want a private set of skills/agents for one project without shipping
  them to collaborators.

## Layout

```
projects/
  <project-name>/
    CLAUDE.md          # your personal instructions for this project
    .claude/
      settings.json    # project-scoped permissions, model, etc.
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

```bash
# Create a new overlay:
mkdir -p ~/.dotfiles/projects/myrepo/.claude
echo "# Personal notes for myrepo" > ~/.dotfiles/projects/myrepo/CLAUDE.md

# Link it into the project:
~/.dotfiles/bin/claude-link-project ~/workspace/myrepo

# Verify:
ls -la ~/workspace/myrepo/.claude ~/workspace/myrepo/CLAUDE.md
# both are symlinks into ~/.dotfiles/projects/myrepo/
```

## Removing the overlay from a project

```bash
~/.dotfiles/bin/claude-link-project --unlink ~/workspace/myrepo
```

This removes the symlinks but leaves the overlay files in place under
`~/.dotfiles/projects/`.

## Caveats

- Don't put **secrets** here — this directory is committed to your dotfiles
  repo. Secrets belong in `.env` files or a secrets manager, not in
  `CLAUDE.md`.
- If a project already has a checked-in `CLAUDE.md` or `.claude/`, the
  linker refuses to clobber it. Rename it first or remove it.
- The overlay symlinks only exist inside the project working tree. Devcontainers
  that run inside a project will see them like any other file, so the host
  mount pattern from `my:project-claude-setup` Just Works.
