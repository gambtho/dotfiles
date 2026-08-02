---
name: new-ash-resource
description: "Step-by-step guide for adding a new Ash Framework resource with migration"
---

# Add a New Ash Resource

## Steps

1. **Create the resource file** in `lib/wanderer_app/api/`
   - Define `attributes`, `relationships`, and `actions`
   - Use `AshPostgres.DataLayer` for the data layer
   - Add a `code_interface` block with `define(:action_name, action: :action_name)` for every action you want callable via `WandererApp.Api.Resource.action_name/n`
   - Important: `destroy` actions need an explicit `define` if called via `Resource.destroy/1`

2. **Register the resource** in the domain at `lib/wanderer_app/api.ex`
   - Add the resource to the `resources` block

3. **Generate the migration**
   ```bash
   mix ash.codegen add_<resource_name>
   ```

4. **Run the migration**
   ```bash
   mix ash.migrate
   ```

5. **Verify** by running the validation script:
   ```bash
   bash .claude/skills/new-ash-resource/scripts/validate.sh <ResourceModuleName>
   ```

6. **Add tests** in the appropriate test directory (`test/unit/` or `test/integration/`)

## Key Patterns
- Use Ash actions (create/read/update/destroy) instead of direct Ecto queries
- Custom repository modules in `lib/wanderer_app/repositories/` handle complex queries
- Resources use `AshPostgres.DataLayer` for PostgreSQL integration

## References
- Existing resources in `lib/wanderer_app/api/` for examples
- Domain registration in `lib/wanderer_app/api.ex`
