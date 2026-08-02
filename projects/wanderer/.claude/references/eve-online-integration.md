# EVE Online Integration

## Authentication
- OAuth2 flow using Ueberauth with EVE Online as provider
- Characters identified by `CharacterOwnerHash` (unique per account)
- Multi-character support: users can link multiple characters
- OAuth scopes requested: location, ship, online status, wallet (optional)

## ESI API
- `WandererApp.ESI` module wraps all ESI calls
- Automatic token refresh handling
- Caches responses to reduce API load
- Character trackers poll ESI every 10-30 seconds for location updates

## External Data
- Zkillboard integration for kill/loss statistics via `WandererApp.Map.ZkbDataFetcher`
- System static data loaded from CCP's Static Data Export (SDE)

## SDE (Static Data Export)

The SDE provides EVE Online static data (solar systems, ship types, etc.). The data source is configurable:

**Configuration:**
```bash
# Environment variables
SDE_SOURCE=wanderer_assets    # or "fuzzworks" for legacy
SDE_BASE_URL=https://raw.githubusercontent.com/wanderer-industries/wanderer-assets/main/sde-files
```

**Source Modules:**
- `WandererApp.SDE.Source` - Behavior definition and source selector
- `WandererApp.SDE.WandererAssets` - Primary source (GitHub CDN)
- `WandererApp.SDE.Fuzzworks` - Legacy source (deprecated)

**Data Service:**
- `WandererApp.EveDataService` - Downloads and processes SDE data
- `WandererApp.Api.SdeVersion` - Tracks SDE version history

**Key Functions:**
```elixir
# Get current SDE info
WandererApp.EveDataService.get_sde_info()

# Check for updates
WandererApp.EveDataService.check_for_updates()

# Update EVE data (downloads all CSV files)
WandererApp.EveDataService.update_eve_data()

# Get version history
WandererApp.EveDataService.get_sde_history(limit: 10)
```

**Admin Panel:**
The admin panel (`/admin`) displays SDE status and provides update controls.

## Modifying ESI Integration
- All ESI calls go through `WandererApp.ESI`
- Token management is automatic
- Add caching for frequently-accessed data
- Handle ESI errors gracefully (rate limits, downtime)
