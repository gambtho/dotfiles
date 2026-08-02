# wanderer-kills — personal working notes

> Personal overlay, not committed to the project. Lives in
> `~/.dotfiles/projects/wanderer-kills/CLAUDE.md`, symlinked in.
>
> **No project-facing architecture/build content here yet — run `/init` from
> inside this project to generate it, then keep the workflow sections below.**

## Workflow

- **Non-trivial backend work → dispatch a standing agent, don't edit in the main
  thread.** The catalog below exists so the main thread stays a coordinator.
- **One-line fixes, typos, config tweaks → just do it.** No agent, no ceremony.
- **Work spanning ingest + fan-out (or a public payload change) → run
  `/new-feature`.** It brainstorms, plans, spawns one member per area, and gates
  on `code-reviewer` plus the real test/check output before anything is called
  done. Single-area work doesn't need the team flow — dispatch the one agent.

## Standing agents

| Agent | Dispatch when |
|---|---|
| `elixir-dev` | General Elixir/OTP work in `lib/wanderer_kills/**`, `lib/wanderer_kills_web/**`, and mirrored tests. |
| `ingest-dev` | Anything under `lib/wanderer_kills/ingest/**` — zKillboard/RedisQ, ESI enrichment, rate limiting, circuit breaking, retries, historical fetch. |
| `realtime-dev` | Subscriptions, filters, indexes, SSE, WebSocket channels, webhooks, stream controllers. |
| `code-reviewer` | Read-only pass before claiming done and before opening a PR. |

Agents are discovered at session start — a newly added one needs a restart.

## Personal preferences

- **Cite gate output before claiming done.** `mix check` is
  `format --check-formatted` + `credo` + `dialyzer` (see `aliases/0` in
  `mix.exs`). Tests: `mix test.core` for the library, `mix test.headless` for an
  offline-safe run, `mix test.perf` for anything claimed as a perf win. Never
  assert a gate passed without running it.
- **Boundaries are load-bearing.** `Core`, `Domain`, and `Ingest` declare
  compile-time boundaries. Adding to an `exports:` list widens a public API —
  treat it as a decision to raise, not a way to quiet the `:boundary` compiler.
- **Upstream constants need a reason.** Rate limits, timeouts, and backoff
  values encode observed zKillboard/ESI behavior. Changing one without saying
  what upstream does to justify it is how the last few regressions happened.
- **Subscriber payloads are a public contract**, documented in
  `API_AND_INTEGRATION_GUIDE.md` and `ELIXIR_CLIENT_GUIDE.md`. Additive changes
  are fine; renames and removals are breaking and must update those docs.
- **Stay in scope.** No opportunistic renames, restructuring, or drive-by fixes
  outside what was asked. When genuinely unsure, stop and ask.

## Local environment

- Devcontainer: Compose-based, service `wanderer-kills`, workspace `/app`, user
  `vscode`. API on port 4004.
- `.devcontainer/docker-compose.override.yml` and `.devcontainer/local-seed.sh`
  are local-only (gitignored) and carry my Claude config, dotfiles, and Vekil
  proxy into the container. They are not part of the project.
