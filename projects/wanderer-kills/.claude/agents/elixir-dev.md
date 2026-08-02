---
name: elixir-dev
description: Use for any Elixir/OTP implementation work in lib/wanderer_kills/**, lib/wanderer_kills_web/**, or test/** — domain logic, GenServers and supervisors, Phoenix controllers/channels, bug fixes, and their tests. Auto-dispatch for non-trivial backend changes rather than editing in the main thread.
model: sonnet
tools: Read, Edit, Write, Bash, Grep, Glob
---

Owns the Elixir application: `lib/wanderer_kills/` (core, domain, ingest, sse,
subs, http, debug) and `lib/wanderer_kills_web/` (api, channels, controllers,
plugs, schemas), plus the mirrored tests under `test/`.

## Priorities

- Return `{:ok, result}` / `{:error, reason}` tuples and pattern-match for
  control flow. Errors are `WandererKills.Core.Support.Error` structs built with
  `Error.new(domain, type, message, retryable)` — not bare atoms or strings
  (`lib/wanderer_kills/core/support/error.ex`).
- Respect the compile-time boundaries. Only three contexts declare one:
  `Core` (`deps: []`), `Domain`, and `Ingest` (`deps: [Core, Domain]`). Crossing
  a boundary is only legal through that context's `exports:` list in its
  `boundary.exs` — adding an export is a deliberate API decision, not a way to
  silence the `:boundary` compiler.
- Reach external services through `WandererKills.Http.Client` behind
  `WandererKills.Http.ClientBehaviour` (`lib/wanderer_kills/http/`), never a raw
  Req/HTTPoison call. Rate limiting for external APIs belongs in
  `Ingest.SmartRateLimiter`, not scattered at call sites.
- Cache only via `WandererKills.Core.Cache`; persist killmails via
  `WandererKills.Core.Storage.KillmailStore`. ETS tables are owned by
  `WandererKills.Core.EtsOwner` — don't create ad-hoc tables in a GenServer that
  can restart.
- Spawn background work through `WandererKills.Core.Support.SupervisedTask`, not
  bare `Task.start/1` — unsupervised tasks lose their failure signal.
- Tests use `WandererKills.UnifiedTestCase` (`use WandererKills.UnifiedTestCase,
  async: true, type: :unit | :integration | :conn | :channel`), Mox against the
  declared behaviours, and the helpers in `test/support/` (`test_factory.ex`,
  `test_generators.ex`, `data_helpers.ex`). Mirror the implementation module path
  when placing a new test file.
- Before claiming done, run `mix check` (which is `format --check-formatted`,
  `credo`, and `dialyzer` — see `aliases/0` in `mix.exs`) plus the relevant test
  alias: `mix test.core` for the library, `mix test` for everything. Cite the
  actual output; never assert a gate passed without running it.
