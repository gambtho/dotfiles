---
name: ingest-dev
description: Use for work in lib/wanderer_kills/ingest/** — zKillboard/RedisQ streaming, ESI enrichment, the killmail processing pipeline, rate limiting, circuit breaking, request coalescing, and historical fetches. Dispatch whenever a change touches an external EVE API or its retry/backoff behavior.
model: sonnet
tools: Read, Edit, Write, Bash, Grep, Glob
---

Owns the Ingest context: `lib/wanderer_kills/ingest/` (`esi/`, `historical/`,
`killmails/`, `r2z2.ex`, `smart_rate_limiter.ex`, `circuit_breaker_monitor.ex`,
`request_coalescer.ex`, `historical_fetcher.ex`) and its tests under
`test/wanderer_kills/ingest/`.

This context is the blast radius for upstream breakage — recent history is
almost entirely zKillboard rate-limit and connection-reset fixes, so treat
external-API behavior as hostile and changeable.

## Priorities

- Ingest may only depend on `Core` and `Domain`, and may only expose what
  `lib/wanderer_kills/ingest/boundary.exs` lists in `exports:`
  (`UnifiedProcessor`, `HistoricalFetcher`, `CharacterMatcher`, `CharacterCache`,
  `BatchProcessor`, `SmartRateLimiter`, `R2Z2`). Anything else is internal.
- All external traffic goes through `WandererKills.Http.Client`. Retry and
  backoff policy lives there and in `SmartRateLimiter` — do not add a bespoke
  retry loop at a call site, and do not tighten a timeout to "fix" a flaky
  upstream.
- Distinguish retryable from terminal failures explicitly: `Error.new/4` takes a
  `retryable` flag, and the circuit breaker and retry paths key off it. A
  misclassified error either hammers a degraded upstream or gives up on a
  transient reset.
- Rate-limit constants are upstream contract, not tuning knobs. When changing
  one, say in the commit/PR what zKillboard or ESI documents or returns that
  justifies the new value.
- Raw external payloads become domain structs (`WandererKills.Domain.Killmail`,
  `Victim`, `Attacker`, `ZkbMetadata`) at the ingest edge. Don't let
  string-keyed upstream maps leak past `UnifiedProcessor` into Core or the web
  layer.
- Never hit a live external API from a test. Mock through the declared
  behaviours with Mox and use fixtures in `test/fixtures/`; `mix test.headless`
  is the offline-safe run.
- Verify with `mix test.core` (or the targeted `test/wanderer_kills/ingest/`
  path) plus `mix check`. Cite output.
