# Zoo-Specific Extensions

This documents features and modifications specific to the zoo fork (branch: `guarzo/zoo`).

## Database Schema

The zoo fork adds several columns to support extended functionality:

| Table | Column | Type | Purpose |
|-------|--------|------|---------|
| `map_system_v1` | `custom_flags` | text | Arbitrary flags for zoo features |
| `map_system_v1` | `owner_id` | text | Corporation or Alliance EVE ID |
| `map_system_v1` | `owner_type` | text | Entity type: 'corp' or 'alliance' |
| `map_system_v1` | `owner_ticker` | text | Display ticker [TICKER] |
| `map_user_settings_v1` | `ready_characters` | text[] | Fleet-ready character EVE IDs |

## Theme System

Zoo adds a `zoo` theme alongside `default` and `pathfinder`:

- **Node Component:** `SolarSystemNodeZoo.tsx`
- **Styles:** `assets/js/hooks/Mapper/components/map/styles/zoo-theme.scss`
- **Labels:** Repurposed with EVE-specific meanings (see `labelIconMap.tsx`)
- **Connection Mode:** Strict (vs Loose for other themes)

## Label Semantics

The zoo fork repurposes upstream's generic labels with EVE Online wormhole-specific meanings:

| Key | Upstream | Zoo Meaning | Use Case |
|-----|----------|-------------|----------|
| `la`/`de` | Label A | Dead End | System with no exit wormholes |
| `lb`/`gas` | Label B | Gas Site | System has harvestable gas sites |
| `lc`/`eol` | Label C | End of Life | Wormhole about to collapse (<4h) |
| `l1`/`crit` | Label 1 | Critical Mass | Wormhole at mass verge |
| `l2`/`structure` | Label 2 | Structure | System has attackable structure |
| `l3`/`steve` | Label 3 | Steve/Danger | High danger (historic: player named Steve) |

Labels are stored using original keys (`la`, `lb`, etc.) but displayed with zoo-specific names and icons.

## Signature Cleanup

Zoo implements on-demand signature cleanup in addition to upstream's daily batch cleanup:

**Zoo On-Demand Cleanup:**
- **Location:** `lib/wanderer_app_web/live/map/event_handlers/map_signatures_event_handler.ex`
- **Trigger:** When user views or updates signatures
- **Scope:** Per-system

**Configuration (environment variables):**
- `SIGNATURE_WORMHOLE_EXPIRATION_HOURS` (default: 24)
- `SIGNATURE_DEFAULT_EXPIRATION_HOURS` (default: 72)

For detailed documentation, see `lib/wanderer_app/map/README.md`.

## Zoo-Specific Files

**Frontend:**
- `assets/js/hooks/Mapper/components/map/styles/zoo-theme.scss` - Zoo theme styles
- `assets/js/hooks/Mapper/components/map/constants.ts` - Extended bookmark styles
- `assets/js/hooks/Mapper/components/map/labelIconMap.tsx` - Label icon mappings

**Backend:**
- `priv/repo/migrations/20250122214138_add_zoo_flags.exs` - Custom flags column
- `priv/repo/migrations/20250307165740_add_owner_ticker.exs` - Owner ticker column
- `priv/repo/migrations/20250625024813_add_fleet_readiness_ready_characters.exs` - Ready characters

**Configuration:**
- Signature expiration settings in `config/config.exs`
