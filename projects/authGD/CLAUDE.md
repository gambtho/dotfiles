<!--
This is the project's primary CLAUDE.md, stored in the dotfiles overlay at
~/.dotfiles/projects/authGD/CLAUDE.md and symlinked into the project.
Run `/init` from inside the project to generate the architecture/convention
section, and keep it ABOVE this workflow block.
-->

# Working agreement — authGD

## Agent dispatch

This project has a standing agent catalog. For non-trivial work, dispatch
instead of executing in the main thread.

| Agent | Dispatch when | Tools |
| --- | --- | --- |
| `sync-engine-dev` | Anything in `src/worker/`, `src/jobs/`, `src/core/`, `src/services/`, `src/lib/{esi,discord,wanderer}/`, `src/db/`, `drizzle/` | full |
| `frontend-dev` | Anything in `src/app/` — pages, layouts, server actions, OAuth routes — plus `e2e/` specs | full |
| `code-reviewer` | After implementing, before commit or PR | read-only |
| `ux-polisher` | A page looks rough, cramped, or inconsistent | full, scoped to `src/app/` |

Run `code-reviewer` before declaring any change done. It is read-only, so it
costs nothing but time.

## When to use the team flow

- **Feature touching both web and worker** (most of them — a new sync surface
  needs a job, a service, and a page): run `/new-feature`. Brainstorm, plan,
  then spawn `sync-engine-dev` and `frontend-dev` in parallel.
- **Single-layer change** (one job, one page, one pure function in `src/core/`):
  dispatch the one relevant agent directly.
- **One-line fix, typo, config tweak**: just do it in the main thread.

## Personal preferences

- **Cite test output.** Never claim `npm test`, `npm run typecheck`, or
  `npm run test:e2e` passed without running it and quoting the result.
- **Stay in scope.** Don't rename, restructure, or "clean up" files the task
  didn't ask about. Note the improvement instead.
- **Stop and ask** when a change would touch persisted data, a migration
  already applied, `TOKEN_ENCRYPTION_KEY` handling, or the OAuth state flow.
  These are the irreversible surfaces.
- **Migrations are generated, never hand-written.** `npm run db:generate` after
  a schema edit; never edit a migration already applied in production —
  `fly.toml` runs them as a release command on every deploy.

## Local environment

- Postgres for tests runs on **port 5433** (`docker-compose.dev.yml`):
  `TEST_DATABASE_URL=postgres://authgd:authgd@localhost:5433/authgd_test`
- Deploy target is **Fly.io**, two process groups (`web`, `worker`) off one
  image. Operational runbook and the full secret list live in `docs/ops.md`.
- Plans and specs live in `docs/superpowers/plans/`.
