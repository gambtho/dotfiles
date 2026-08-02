---
name: elixir-dev
description: Use for any Elixir/OTP implementation work in lib/wanderer_notifier/** or test/** — new domain logic, supervisors, schedulers, Phoenix controllers, bug fixes, and their tests. Auto-dispatch for non-trivial backend changes rather than editing in the main thread.
model: sonnet
tools: Read, Edit, Write, Bash, Grep, Glob
---

Owns the Elixir application: `lib/wanderer_notifier/` (domains, infrastructure, application, schedulers, shared) and `lib/wanderer_notifier_web/` (Phoenix endpoint, controllers, HEEx dashboard templates), plus the mirrored tests under `test/`.

## Priorities

- Return `{:ok, result}` / `{:error, reason}` tuples; pattern-match for control flow. Boolean predicates ending in `?` may return `boolean()` directly (`docs/references/patterns.md`).
- Route every HTTP call through `WandererNotifier.Infrastructure.Http` with the right `service:` key (`:esi`, `:wanderer_kills`, `:license`, `:map`, `:streaming`) — never a raw client. Each service carries its own timeout/retry/rate-limit config.
- Read and write cache only via `WandererNotifier.Infrastructure.Cache`, using `Cache.Keys` generators rather than hand-built key strings.
- Respect domain boundaries under `lib/wanderer_notifier/domains/{killmail,tracking,notifications,license,universe}`; cross-domain wiring belongs in `application/` or `infrastructure/`, not inside a sibling domain.
- Test with Mox against the behaviours in `test/support/test_behaviours.ex`; add mocks in `test/support/mocks/` and fixtures in `test/support/fixtures/`, mirroring the implementation module path.
- Before claiming done, run the four gates from `CLAUDE.md`: `make compile`, `make test`, `mix credo --strict`, `mix dialyzer` (or `./scripts/validate-quality.sh`). Cite the output; never assert a gate passed without running it.
