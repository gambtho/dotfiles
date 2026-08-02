# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Wanderer is an EVE Online mapper tool built with Elixir/Phoenix and React. It's a real-time, collaborative mapping application that tracks character locations, wormhole connections, and system information in EVE Online.

- **Backend**: Elixir/Phoenix with PostgreSQL
- **Frontend**: React with TailwindCSS, PrimeReact, and ReactFlow
- **Real-time**: Phoenix LiveView and WebSockets for live updates
- **Data Layer**: Ash Framework for declarative resource management

## Development Environment

### Required Versions
- Erlang: 26.2.5.5
- Elixir: 1.17.3-otp-26
- Node.js: 18.0.0+

### Setup
```bash
cp .env.example .env  # Fill in EVE Online OAuth credentials
mix setup             # Runs: deps.get, ecto.setup, assets.setup, assets.build
make yarn             # or: cd assets && yarn install
```

### Running the Application
```bash
make server  # or: make s — starts dev server at http://localhost:8000
```

### Common Commands

**Database:** `mix ecto.reset` | `mix ash.codegen <name>` | `mix ash.migrate` | `make migrate`

**Testing:** `mix test` | `mix test path/to/file_test.exs` | `mix test path:42` | `mix coveralls`

**Code Quality:** `mix format` | `mix credo` | `mix dialyzer`

**Frontend:** `cd assets && yarn install` | `yarn build` | `yarn watch` | `yarn test`

## Architecture

### Ash Framework Resources

Resources are defined in `lib/wanderer_app/api/` and registered under the `WandererApp.Api` domain (exposed at `/api/v1/`):

- **Map**, **Character**, **MapSystem**, **MapConnection**, **MapSystemSignature**, **User**, **AccessList**

When working with data:
- Use Ash actions (create/read/update/destroy) instead of direct Ecto queries
- Add `define(:action_name, action: :action_name)` in the `code_interface` block for every action callable via `WandererApp.Api.Resource.action_name/n`
- Custom repository modules in `lib/wanderer_app/repositories/` handle complex queries

### Map Server Architecture

Maps are managed by a GenServer pool system. Key modules:
- `WandererApp.Map.Manager` → `PoolSupervisor` → `Pool` (12-hour GC) → `Server` (facade)
- Implementation modules in `lib/wanderer_app/map/server/`: systems, connections, signatures, characters, ACLs, pings

Maps use in-memory caching with R-tree spatial indexing. All changes must be broadcast via PubSub.

### Broadcast Architecture

See `.claude/references/broadcast-architecture.md` for the full coordinated update system, including:
- Update flow (DB write → cache → R-tree → PubSub → webhooks)
- All broadcast event types
- Batch update patterns and atomic update optimizations
- Adding new broadcast events checklist

**Critical rules:** Never bypass `UpdateCoordinator`. Always use `after_transaction` (not `after_action`). Payloads must be serializable.

### Character Tracking

Supervisor pools manage real-time character tracking:
- `TrackerManager` → `TrackerPool` → `Tracker` (GenServer per character)
- Trackers poll EVE ESI API every 10-30 seconds for location, ship, and online status

### Caching Strategy

Caches: `:api_cache` (1h TTL), `:map_cache`, `:character_cache`, `:map_state_cache`, `:character_state_cache`, `:map_pool_cache`, `:acl_cache`

Ensure cache invalidation is handled when modifying data.

### Phoenix LiveView & Frontend

**Entry Point:** `lib/wanderer_app_web/live/map/map_live.ex`
**Event Handlers** in `lib/wanderer_app_web/live/map/`: systems, connections, signatures, characters
**Event Flow:** React frontend → LiveView `handle_event` → map server → PubSub → `"maps:#{map_id}"` → frontend re-render
**Frontend:** React + ReactFlow in `assets/js/hooks/Mapper/`, built with Vite (`npx vite build --emptyOutDir false`)

## EVE Online Integration

See `.claude/references/eve-online-integration.md` for full details (OAuth, ESI API, SDE, Zkillboard).

Key points:
- OAuth2 via Ueberauth, characters identified by `CharacterOwnerHash`
- All ESI calls through `WandererApp.ESI` with automatic token refresh
- SDE data source configurable via `SDE_SOURCE` env var

## Testing Conventions

- `/test/unit/` — Unit tests | `/test/integration/` — API tests | `/test/wanderer_app_web/` — Web tests
- Use `ExUnit.Case, async: true` when tests don't share state
- Integration tests mock ESI via Mox; factories in `test/support/factory.ex`
- See `test/STANDARDS.md` and `test/EXAMPLES.md` for test-specific guidance

## Key Patterns and Conventions

- **Supervision:** DynamicSupervisor for runtime spawning, Registry for process lookup
- **PubSub:** All state changes broadcast to `"maps:#{map_id}"` topic
- **Error Handling:** `{:ok, result}` / `{:error, reason}` tuples; Ash changesets for validation
- **Code Organization:** Business logic in `lib/wanderer_app/`, web layer in `lib/wanderer_app_web/`
- **Naming:** GenServers: `*Manager/*Supervisor/*Pool/*Tracker/*Server`; Ash resources: singular; Tests: `*_test.exs`

## Common Development Workflows

Use the following skills for guided step-by-step workflows:
- **`/new-ash-resource`** — Add a new Ash resource with migration and domain registration
- **`/add-map-feature`** — End-to-end: server impl → event handler → frontend → broadcast → tests
- **`/add-broadcast-event`** — Add a new broadcast event with all required touchpoints

## Important Files

- `lib/wanderer_app/application.ex` — Supervisor tree
- `lib/wanderer_app_web/router.ex` — HTTP routing
- `config/runtime.exs` — Runtime configuration
- `mix.exs` — Dependencies
- `assets/package.json` — Frontend dependencies

## Zoo-Specific Extensions

See `.claude/references/zoo-extensions.md` for the full zoo fork documentation, including:
- Additional database columns (`custom_flags`, `owner_id`, `owner_ticker`, `ready_characters`)
- Zoo theme system (`SolarSystemNodeZoo.tsx`, zoo-theme.scss)
- Label semantics (dead end, gas, EOL, crit, structure, steve)
- On-demand signature cleanup configuration
