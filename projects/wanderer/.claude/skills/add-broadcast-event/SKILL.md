---
name: add-broadcast-event
description: "Checklist for adding new broadcast events with all required touchpoints"
---

# Add a New Broadcast Event

Read `.claude/references/broadcast-architecture.md` for full context on the broadcast system.

## Steps

1. **Add event type to `UpdateCoordinator`**
   - File: `lib/wanderer_app/map/update_coordinator.ex`
   - Add the new event atom to the coordinator

2. **Create coordinator function**
   - Add a function like `add_foo/3` to `UpdateCoordinator`
   - Follow the pattern: cache update -> R-tree update (if spatial) -> PubSub broadcast -> external events broadcast

3. **Update cache logic in coordinator**
   - Ensure the cache is updated BEFORE the broadcast
   - Use the appropriate cache (`:map_cache`, `:character_cache`, etc.)

4. **Add to `BroadcastMapUpdate` change module**
   - File: look for `BroadcastMapUpdate` in `lib/wanderer_app/`
   - Register the new event type

5. **Add telemetry event**
   - Add `[:wanderer_app, :broadcast, :success]` telemetry for the new event
   - Include metadata: event type, map_id

6. **Handle on the frontend**
   - Add channel listener for the new event in `assets/js/hooks/Mapper/`
   - Ensure payload handling matches the broadcast payload structure

7. **Verify**
   ```bash
   bash .claude/skills/add-broadcast-event/scripts/validate.sh <event_name>
   ```

## Critical Rules
- **Never bypass UpdateCoordinator** — direct cache manipulation causes inconsistencies
- **Always use `after_transaction`** — `after_action` causes race conditions
- **Broadcast payloads must be serializable** — no PIDs, refs, or function captures
- **Use `require_atomic? false`** for broadcast compatibility
