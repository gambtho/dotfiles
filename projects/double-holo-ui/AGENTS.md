# Personal extension to AGENTS.md (Double Holo UI)

The team's shared agreement is in the tracked `AGENTS.md` at the repo root.
This file holds my personal workflow preferences for this project. Loaded via
`AGENTS.local.md` import shim (gitignored globally).

## Standing agents — prefer dispatch over main-thread execution

For non-trivial work in a given surface, dispatch the matching role agent via
the `Agent` tool instead of executing in the main thread. The catalog lives at
`.claude/agents/` (symlinked from this overlay):

- **rails-dev** — anything under `double-holo-api/` (controllers, services,
  jobs, migrations, RSpec). Knows the controller/service/migration/test
  conventions in `.claude/rules/api/`.
- **frontend-dev** — Next.js work in `double-holo-ui-frontend/`, Vite admin
  work in `double-holo-admin-ui/`, React Native in `double-holo-mobile/`,
  Discord bot TS in `double-holo-{discord-bot,admin-discord-bot,discord-ai,reports-bot}/`.
  Knows the frontend rules in `.claude/rules/frontend/`.
- **code-reviewer** — Read-only review against the project's conventions.
  Dispatch before declaring work done (mandatory per `AGENTS.md` post-impl
  review step) and before opening a PR.
- **ux-polisher** — UI polish, copy review, and visual hardening for the
  customer-facing surfaces. Pairs with the `impeccable`, `frontend-design`,
  and `design-system` skills.

The two tracked investigation agents stay as-is:
- `data-quality-investigator` — set remapping, misclassified cards, DH vs
  TCGPlayer cross-references.
- `matching-pipeline-investigator` — TAG / Countdown / GemRate / TCGPlayer
  pipeline diagnostics.

## When to follow the full team flow

The project's `AGENTS.md` documents a six-step workflow (brainstorm → spec →
plan → setup → execute → review). Follow it for:

- New features or screens
- Cross-app changes (api + frontend, or multiple frontends)
- Schema changes (migration + model + controller + service + UI)
- Anything that touches payments, payouts, auctions, or background-job
  lifecycle

Skip the formal flow for:

- Typos, single-line fixes, config tweaks
- Pure copy edits in a single component
- Adding a missing index/import

## Personal preferences (project-scoped)

- Cite real output (test results, curl responses, file paths with line
  numbers) before claiming work is done. Run the verification before the
  assertion.
- When in doubt about a Shopify/Stripe/eBay/Linear UI step or API field,
  stop and ask — don't manufacture plausible-sounding answers.
- Prefer running curl/SQL/`gh` myself over asking the user to paste output.
- For data-quality or matching work, read `docs/DATA_QUALITY_KNOWN_ISSUES.md`
  first.
- For storefront builder work, read `docs/STOREFRONT_BUILDER_GUIDE.md` first.
- Use `just` (with `-q` variants) for build/test/lint. Never `--no-verify`
  unless the failure is unrelated to the change being merged.
- Never `git stash` in this repo — concurrent agents collide.
