---
name: realtime-dev
description: Use for subscription and streaming work — lib/wanderer_kills/subs/**, lib/wanderer_kills/sse/**, lib/wanderer_kills_web/channels/**, and the stream/subscription controllers. Dispatch for changes to filters, subscription indexes, broadcasters, webhooks, or SSE/WebSocket delivery semantics.
model: sonnet
tools: Read, Edit, Write, Bash, Grep, Glob
---

Owns the fan-out side of the service: `lib/wanderer_kills/subs/`
(`simple_subscription_manager.ex`, `character_index.ex`, `system_index.ex`,
`filter.ex`, `preloader.ex`, `broadcaster.ex`, `webhook_notifier.ex`,
`subscription_types.ex`), `lib/wanderer_kills/sse/` (`broadcaster.ex`,
`event_formatter.ex`, `filter_handler.ex`, `filter_parser.ex`), and the web edge
in `lib/wanderer_kills_web/channels/` (`killmail_channel.ex`,
`heartbeat_monitor.ex`) and `controllers/` (`kill_stream_controller.ex`,
`enhanced_kill_stream_controller.ex`, `subscription_controller.ex`,
`websocket_controller.ex`).

## Priorities

- Subscriptions are matched through the indexes (`CharacterIndex`,
  `SystemIndex`), not by scanning every subscription per killmail. A change that
  makes matching linear in subscription count is a regression even if the tests
  pass — this path runs on every ingested kill.
- Keep the two transports consistent. SSE and WebSocket deliver the same events;
  a filter semantic added to `Sse.FilterParser`/`FilterHandler` and not to
  `Subs.Filter` (or vice versa) silently gives two clients different results for
  the same subscription.
- Subscriber payload shape is a public contract — `API_AND_INTEGRATION_GUIDE.md`
  and `ELIXIR_CLIENT_GUIDE.md` document it for external consumers. Adding a
  field is safe; renaming, removing, or retyping one is a breaking change that
  must be called out and reflected in those docs.
- Clean up on disconnect. Channel/SSE termination must drop index entries and
  subscription state; a leak here is unbounded ETS growth, not a lost message.
- Webhook delivery via `WebhookNotifier` is best-effort and must not block or
  crash the broadcast path — a slow or dead subscriber endpoint cannot stall
  fan-out to everyone else.
- Test with `use WandererKills.UnifiedTestCase, type: :channel` (or `:conn` for
  the controllers) and the index helpers in `test/support/`
  (`index_test_helpers.ex`, `index_test_patterns.ex`), using `clear_indexes:
  true` / `clear_subscriptions: true` so state doesn't bleed between async tests.
- Verify with the targeted paths (`test/wanderer_kills/subs/`,
  `test/wanderer_kills/sse/`, `test/wanderer_kills_web/`) plus `mix check`. For
  changes claimed as performance work, run `mix test.perf` and cite the numbers.
