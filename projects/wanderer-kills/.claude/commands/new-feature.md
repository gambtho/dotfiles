---
description: Drive a wanderer-kills feature through the full team flow — brainstorm, plan, spawn role-typed members, review, verify.
argument-hint: <feature-slug or short description>
---

Build **$ARGUMENTS** using the team flow. Do not skip steps; do not start editing before step 3.

## 1. Clarify intent

Invoke `superpowers:brainstorming` to pin down what "$ARGUMENTS" actually means — observable behavior first, then which contexts it touches (`core`, `domain`, `ingest`, `subs`, `sse`, `wanderer_kills_web`) and whether it crosses a declared compile-time boundary (`Core`, `Domain`, `Ingest`).

Run `my:blindspot-pass` if the change is non-trivial. Pause only for unresolved decisions about boundary `exports:`, subscriber payload shape, external API rate-limit/retry behavior, supervision structure, or cached/persisted data shape.

Two questions worth asking early, because they change the whole plan:

- **Does this alter the subscriber payload?** Killmail, subscription, and SSE/WebSocket event shapes are a public contract documented in `API_AND_INTEGRATION_GUIDE.md` and `ELIXIR_CLIENT_GUIDE.md`. Additive is cheap; renames and removals are breaking and pull those docs into scope.
- **Does this touch both ingest and fan-out?** If yes, it needs two members and a sequencing plan, not one agent making a sweep.

## 2. Write the plan

Invoke `superpowers:writing-plans`. The plan must name the modules to add or change, any `exports:` entries it needs (each one justified — widening a boundary is a decision, not a compiler workaround), the behaviours needing Mox mocks, and the verification commands.

## 3. Create the team

```
TeamCreate({ team_name: "<feature-slug>", description: "<one line>" })
```

Then seed the work with `TaskCreate`, one task per unit, using `addBlockedBy` for real dependencies (tests depend on the behaviour existing; the review task depends on all implementation tasks).

## 4. Spawn members in parallel

Issue all `Agent` calls **in a single message** so they run concurrently. Pick only the roles the plan actually needs:

| `subagent_type` | Use when |
|---|---|
| `elixir-dev` | General domain logic, GenServers/supervisors, Phoenix controllers, tests |
| `ingest-dev` | zKillboard/RedisQ, ESI enrichment, rate limiting, circuit breaking, retries, historical fetch |
| `realtime-dev` | Subscriptions, filters, indexes, SSE, WebSocket channels, webhooks, stream controllers |

```
Agent({ team_name: "<feature-slug>", name: "impl", subagent_type: "elixir-dev", prompt: "..." })
```

## 5. Orchestrate

Poll `TaskList`, unblock with `SendMessage`, and keep each member scoped to its own task. Don't let two members edit the same module concurrently — sequence them with `addBlockedBy` instead. `ingest-dev` and `realtime-dev` overlap on the domain structs and on `Core.Cache`; if both need to change one, give it to a single member.

## 6. Review gate

Before any "done" claim, dispatch `code-reviewer` over the branch diff. It is read-only: route its findings back to the implementing member and re-review. Do not accept a review that hasn't checked boundary compliance and the gates below.

## 7. Verify

Invoke `superpowers:verification-before-completion`. The gates are mandatory and must actually be run:

```
mix check          # format --check-formatted + credo + dialyzer (aliases/0 in mix.exs)
mix test.core      # library tests, offline-safe
```

Add `mix test` for a full run when the change reaches the web layer, and `mix test.perf` for anything claimed as a performance win. Cite the real output. If a gate fails, the feature is not done.

## 8. Tear down

`TeamDelete` once the work is merged or abandoned. Report what shipped, what was deliberately left out, and any unresolved risk.
