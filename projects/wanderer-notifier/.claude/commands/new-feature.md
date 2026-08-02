---
description: Drive a wanderer-notifier feature through the full team flow — brainstorm, plan, spawn role-typed members, review, verify.
argument-hint: <feature-slug or short description>
---

Build **$ARGUMENTS** using the team flow. Do not skip steps; do not start editing before step 3.

## 1. Clarify intent

Invoke `superpowers:brainstorming` to pin down what "$ARGUMENTS" actually means — observable behavior first, then the domains it touches (`killmail`, `tracking`, `notifications`, `license`, `universe`) and whether it crosses into the live SSE/WebSocket surface under `lib/wanderer_notifier/map/`.

Run `my:blindspot-pass` if the change is non-trivial. Pause only for unresolved decisions about supervision structure, public interfaces, persisted/cached data shape, config compatibility, or notification behavior users will see.

## 2. Write the plan

Invoke `superpowers:writing-plans`. The plan must name the modules to add or change, the behaviours needing Mox mocks, and the verification commands.

## 3. Create the team

```
TeamCreate({ team_name: "<feature-slug>", description: "<one line>" })
```

Then seed the work with `TaskCreate`, one task per unit, using `addBlockedBy` for real dependencies (e.g. tests depend on the behaviour existing; the review task depends on all implementation tasks).

## 4. Spawn members in parallel

Issue all `Agent` calls **in a single message** so they run concurrently. Pick only the roles the plan actually needs:

| `subagent_type` | Use when |
|---|---|
| `elixir-dev` | Domain logic, supervisors, schedulers, Phoenix controllers, tests |
| `realtime-integration-dev` | SSE/WebSocket lifecycle, reconnect, dedup, registry reconciliation |
| `config-auditor` | New or changed env vars / feature flags (read-only audit) |

```
Agent({ team_name: "<feature-slug>", name: "impl", subagent_type: "elixir-dev", prompt: "..." })
```

## 5. Orchestrate

Poll `TaskList`, unblock with `SendMessage`, and keep each member scoped to its own task. Don't let two members edit the same module concurrently — sequence them with `addBlockedBy` instead.

## 6. Review gate

Before any "done" claim, dispatch `code-reviewer` over the branch diff. It is read-only: route its findings back to the implementing member and re-review. Do not accept a review that hasn't run the four quality gates.

## 7. Verify

Invoke `superpowers:verification-before-completion`. The gates from `CLAUDE.md` are mandatory and must actually be run:

```
make compile
make test
mix credo --strict
mix dialyzer
```

or `./scripts/validate-quality.sh` for all four. Cite the real output. If a gate fails, the feature is not done.

## 8. Tear down

`TeamDelete` once the work is merged or abandoned. Report what shipped, what was deliberately left out, and any unresolved risk.
