# Broadcast Architecture

Wanderer uses a coordinated update system to ensure cache consistency and prevent race conditions when map data changes.

## Update Flow

When a map resource is created/updated/destroyed:

1. **Database Write** - Ash action persists to PostgreSQL (atomic transaction)
2. **Transaction Commit** - Changes become visible to other connections
3. **UpdateCoordinator** - Coordinates the following steps:
   a. **Cache Update** - `:map_cache` updated via `WandererApp.Map.add_system/2`
   b. **R-tree Update** - Spatial index updated via `CacheRTree.insert/2`
   c. **PubSub Broadcast** - Internal clients notified via `Impl.broadcast!/3`
   d. **ExternalEvents Broadcast** - Webhooks/SSE notified

This ordering is enforced by `WandererApp.Map.UpdateCoordinator` to prevent race conditions where clients receive broadcasts before cache is ready.

## Broadcast Events

**System Events:**
- `:add_system` - New system added to map
- `:update_system` - System updated (position, name, etc.)
- `:systems_removed` - System(s) removed (array of solar_system_ids)

**Connection Events:**
- `:add_connection` - New wormhole connection
- `:update_connection` - Connection updated
- `:remove_connections` - Connection(s) removed (array of connection records)

**Signature Events:**
- `:signatures_updated` - Signatures changed for a system (payload: solar_system_id)

**Character Events:**
- `:character_added` - Character tracked on map
- `:character_updated` - Character position/ship updated
- `:character_removed` - Character no longer tracked

## Adding New Broadcast Events

1. Add event type to `UpdateCoordinator`
2. Create coordinator function (e.g., `add_foo/3`)
3. Update cache logic in coordinator
4. Add to `BroadcastMapUpdate` change module
5. Add telemetry event
6. Update documentation

## Performance Considerations

- All updates use `require_atomic? false` for broadcast compatibility
- This adds ~2 extra queries per update (SELECT before, SELECT after)
- For bulk operations, use `Ash.bulk_update/4` with `:stream` strategy
- High-frequency operations may use minimal broadcasts (future optimization)

## Batch Update Pattern

For operations that modify multiple attributes, use batch update actions to prevent UI flicker and reduce server load:

**Anti-pattern (5 broadcasts, UI flickers):**
```elixir
system
|> MapSystemRepo.update_position!(%{position_x: 100, position_y: 200})
|> MapSystemRepo.cleanup_labels!(map_opts)
|> MapSystemRepo.update_visible!(%{visible: true})
|> MapSystemRepo.cleanup_tags!()
|> MapSystemRepo.cleanup_temporary_name!()
# Result: 5 database queries, 5 broadcasts, UI flickers 5 times
```

**Correct pattern (1 broadcast, smooth UX):**
```elixir
MapSystemRepo.update_position_and_attributes!(system, %{
  position_x: 100,
  position_y: 200,
  labels: labels,
  tag: tag,
  temporary_name: temp_name
}, map_opts: map_opts)
# Result: 1 database query, 1 broadcast, smooth UI rendering
```

**Benefits:**
- 80% reduction in database queries and broadcasts
- Eliminates UI flicker during drag operations
- Single atomic transaction

**When to use:**
- System position updates (drag operations)
- Any operation that updates multiple related attributes
- High-frequency updates where UX matters

**Implementation:**
- Action: `WandererApp.Api.MapSystem.update_position_and_attributes`
- Repo function: `MapSystemRepo.update_position_and_attributes!/3`
- Automatically sets `visible: true`
- Cleans up empty strings (converts to `nil`)
- Cleans labels based on map options
- Single UpdateCoordinator call with one broadcast

## Atomic Update Optimization

For high-frequency position updates (e.g., drag operations), use atomic updates with minimal broadcasts to maximize performance:

**Standard position update (3 queries, full payload):**
```elixir
MapSystemRepo.update_position!(system, %{position_x: 100, position_y: 200})
# ~15ms, full broadcast payload (~800 bytes)
```

**Atomic position update (1 query + reload, minimal payload):**
```elixir
MapSystemRepo.update_position_atomic!(system, %{position_x: 100, position_y: 200})
# ~5ms, minimal broadcast payload (~120 bytes)
```

**When to use atomic updates:**
- User actively dragging systems (100+ updates per session)
- Programmatic bulk position updates (auto-layout)
- High-frequency operations where latency matters

**When NOT to use atomic updates:**
- Position update with other attribute changes (use `update_position_and_attributes`)
- First-time system positioning (use standard `update_position` - auto-sets visible)
- Single position update where performance isn't critical

**Key differences from standard update:**
- Does NOT automatically set `visible: true`
- Does NOT clean up labels/tags/temporary_name
- Broadcasts `:position_updated` event instead of `:update_system`
- Minimal broadcast payload (only id, solar_system_id, position_x, position_y, updated_at)

**Frontend requirement:**
```typescript
channel.on('position_updated', (data) => {
  updateNodePosition(data.id, data.position_x, data.position_y);
});
```

**Performance impact:**
- 3x faster updates (15ms -> 5ms per update)
- 85% smaller broadcast payloads (800 bytes -> 120 bytes)

**Implementation details:**
- Action: `WandererApp.Api.MapSystem.update_position_atomic`
- Repo function: `MapSystemRepo.update_position_atomic!/2`
- UpdateCoordinator: Supports `minimal: true` flag for minimal payloads
- Event type: `:position_updated` (vs `:update_system`)

## Error Handling

Broadcast failures are logged but **do not fail** the database transaction:
- Database changes always commit successfully
- Broadcast errors are logged with full stacktrace
- Telemetry events track success/failure rates
- Clients should implement retry/polling for resilience

## Monitoring

Key metrics (via Telemetry):
- `[:wanderer_app, :broadcast, :success]` - Successful broadcasts
- `[:wanderer_app, :broadcast, :error]` - Failed broadcasts
- Metadata: event type, map_id, error reason

## Important Notes

- **Never bypass UpdateCoordinator** - Direct cache manipulation will cause inconsistencies
- **Always use `after_transaction`** - Using `after_action` causes race conditions
- **Broadcast payloads must be serializable** - No PIDs, refs, or function captures
