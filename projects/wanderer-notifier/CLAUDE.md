# wanderer-notifier — personal overlay

Loaded via `CLAUDE.local.md`. The project's tracked `CLAUDE.md` holds the shared
rules and wins on any conflict; this file is only my working preferences.

## Workflow

- **Non-trivial backend work** → dispatch `elixir-dev` rather than editing in the
  main thread. Work touching `lib/wanderer_notifier/map/**` or
  `infrastructure/messaging/**` → dispatch `realtime-integration-dev` instead.
- **Features spanning more than one domain, or any change to the live feeds** →
  run `/new-feature`. One-line fixes and single-module edits: just do it inline.
- **Before any "done" claim** → dispatch `code-reviewer` over the diff.
- **Any env var or feature-flag change** → dispatch `config-auditor`, even if the
  code change looks trivial. This surface spans `config/runtime.exs`,
  `shared/config.ex`, and two docs files; drift here is silent until production.

## Standing agents

| Agent | Tools | Dispatch when |
|---|---|---|
| `elixir-dev` | full | Domain logic, supervisors, schedulers, Phoenix controllers, tests |
| `realtime-integration-dev` | full | SSE/WebSocket lifecycle, reconnect, dedup, registry reconciliation |
| `code-reviewer` | read-only | Any diff before it's called done; every PR branch |
| `config-auditor` | read-only | Env vars, feature flags, dev/prod/release divergence |

## Personal preferences

- Cite real command output before claiming a quality gate passed. The four gates
  (`make compile`, `make test`, `mix credo --strict`, `mix dialyzer`) are not
  optional and not assumable — `./scripts/validate-quality.sh` runs all four.
- Don't rename, restructure, or "tidy" outside the asked scope. If something
  nearby is wrong, report it; don't fix it in the same change.
- Preserve error context. A rewritten `{:error, reason}` that drops the original
  reason is a regression here, not a cleanup.
- When a decision would change supervision structure, a public interface, cached
  data shape, or user-visible notification behavior — stop and ask.
