---
name: add-map-feature
description: "End-to-end workflow for adding a new feature to the map system"
---

# Add a New Map Feature

## Steps

1. **Update the map server implementation** in `lib/wanderer_app/map/server/`
   - Choose the correct implementation module:
     - `map_server_systems_impl.ex` - System management
     - `map_server_connections_impl.ex` - Connection/wormhole handling
     - `map_server_signatures_impl.ex` - Signature tracking
     - `map_server_characters_impl.ex` - Character positions
     - `map_server_acls_impl.ex` - Access control
     - `map_server_pings_impl.ex` - System notifications
   - Add the server function to `map_server.ex` (the facade)

2. **Add a LiveView event handler** in `lib/wanderer_app_web/live/map/`
   - Add handler function to the appropriate event handler module:
     - `map_systems_event_handler.ex` - System operations
     - `map_connections_event_handler.ex` - Wormhole management
     - `map_signatures_event_handler.ex` - Signature linking
     - `map_characters_event_handler.ex` - Character UI events
   - Or add to `map_event_handler.ex` (central dispatcher) if it doesn't fit elsewhere

3. **Add PubSub broadcast** for real-time updates
   - Read `.claude/references/broadcast-architecture.md` for the broadcast pattern
   - Use `UpdateCoordinator` — never bypass it
   - Use `after_transaction` — never `after_action`
   - If this is a new event type, use the `/add-broadcast-event` skill

4. **Update the frontend** in `assets/js/hooks/Mapper/`
   - Add UI components or modify existing ones
   - Handle the new event in the channel listener
   - Build with: `cd assets && npx vite build --emptyOutDir false`

5. **Add tests**
   - Unit tests in `test/unit/`
   - Integration tests in `test/integration/` if needed
   - Run: `mix test`

6. **Verify** by running the validation script:
   ```bash
   bash .claude/skills/add-map-feature/scripts/validate.sh
   ```

## Key Reminders
- Broadcast payloads must be serializable (no PIDs, refs, or function captures)
- Use batch update patterns for multi-attribute changes (see `.claude/references/broadcast-architecture.md`)
- Ensure cache invalidation is handled properly
