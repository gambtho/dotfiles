---
name: upstream-pr-review
description: Use when preparing a PR for wanderer-industries/wanderer, before pushing - checks for recurring review issues from upstream maintainers (DanSylvest, DmitryPopov, dedo1911)
---

# Upstream PR Pre-Submit Review

## Overview

Checklist derived from **actual review feedback** on 80+ PRs to wanderer-industries/wanderer. These are the patterns that repeatedly trigger review comments. Run this before pushing any upstream PR branch.

**Who reviews what:** DanSylvest and DmitryPopov review frontend/UX and codestyle (sections 1–9). dedo1911 reviews backend, migrations, and CI (sections 11–14) and reproduces claims against the tree before responding — so verify yours first.

## When to Use

- Before pushing a branch intended for upstream PR
- Before requesting review on an existing upstream PR
- When preparing zoo-fork features for upstream submission

## The Checklist

Run each check against your diff (`git diff $BASE..HEAD`).

### 1. Debug Artifacts

**Search and destroy** — this is the #1 repeat offender.

```bash
# In your diff, search for:
git diff $BASE..HEAD | grep -E "console\.(log|info|debug|warn)|\.backup$|TODO|FIXME|debugger"
```

- No `console.log`, `console.info`, `console.debug` in committed code
- No `.backup` files or temp files
- No `TODO`/`FIXME` comments in new code
- No `debugger` statements
- No commented-out code blocks

> **PR #366:** DmitryPopov flagged `console.info` three separate times in one PR: "if it's for debug here only, better to get rid of it"
> **PR #446:** A `.backup` file was committed: "What do we really need backup for?"

### 2. Follow Existing Codestyle

**Match the patterns already in the file you're modifying.** Don't introduce new patterns.

- If the file uses helper functions, use them (don't inline equivalent logic)
- If the file uses early returns, use early returns (not nested ifs)
- If the file uses pattern matching on structs, do the same (not dot access)
- Check naming: if similar components are named `FooAction`, don't name yours `FooIcon`

> **PR #591:** "All of this code should be reworked. Please do not ignore codestyle - if we here use special functions. Please use it too."
> **PR #513:** "Better if we change condition to `if (isWH !== undefined) return false;` and rest of code will not need be in block-scope"

**Elixir-specific:**
```elixir
# BAD: dot access on conn.assigns
owner_id = conn.assigns.owner_character_id

# GOOD: pattern match (PR #365 feedback)
def action(%{assigns: %{owner_character_id: owner_id}} = conn, params)
```

### 3. Named Constants, Not Magic Numbers

**Every literal number or string that has domain meaning needs a module attribute or constant.**

```elixir
# BAD (PR #467 — flagged 3 times)
ship_size_type: 0
ship_size_type: 2

# GOOD
@frigate_ship_size 0
@large_ship_size 2
ship_size_type: @frigate_ship_size
```

```elixir
# BAD (PR #366)
DateTime.add(-30, :minute)

# GOOD
@delete_after_minutes 30
DateTime.add(-1 * @delete_after_minutes, :minute)
```

### 4. Use Existing Helpers

**Before writing inline logic, grep for existing helper functions that do the same thing.**

```bash
# Check what helpers exist in the module/file you're modifying
grep -n "defp\|def " lib/path/to/module.ex | head -30
```

- Use `broadcast_acl_updated(acl_id)` not inline PubSub calls (PR #509)
- Use existing Ash actions not raw Ecto queries
- Use existing UI components not reimplementations
- Move module attributes to module level, not inside functions (PR #441)

> **PR #509:** DmitryPopov pointed to the same function twice: "use broadcast_acl_updated(acl_id) here" ... "same, use broadcast_acl_updated(acl_id)"

### 5. React Hooks & Component Rules

- **Don't add callbacks to effect dependencies** (PR #417 — flagged twice)
- **Use provider hooks, not prop drilling** — if `useMapRootState()` or `useMapState()` gives you what you need, don't accept it as a prop
- **Don't put state in the dependency array of the effect that sets it** (causes re-trigger loops)
- **Don't use `useRef` to avoid dependency arrays** — if `outCommand` is used in a `useEffect`, put it in the dependency array directly (match the pattern in ServerSettings/AdminSettings)
- **Memoize computed props** — never create new arrays/objects inline in JSX (e.g., `options={list.map(...)}`) — use `useMemo`
- **Disable/enable, don't show/hide** — prefer `disabled={!condition}` over `{condition && <Button />}` for action buttons; avoids layout shifts and broken padding
- **Use CSS grid for aligned layouts** — when a container has a stretching input + fixed-width button, use `grid` with `gridTemplateColumns: '1fr auto'` instead of `flex` to prevent padding/alignment issues
- **Match heights of adjacent elements** — don't use `size="small"` on a Button next to a default-sized Dropdown; both must use the same sizing so heights align

> **PR #591:** "Why you put there outCommand as props if you can use provider hook?"
> **PR #417:** "Better don't add callbacks to effect dependencies" (x2)
> **PR #590:** "this options should be memoized" / "Instead of show/hide Cancel button - better disable/enable this. And for partent container give grid props with column template 1fr_auto"

### 6. Config Location

- **Environment variables** go in `config/runtime.exs` only
- **Never** put env vars in `config/dev.exs` — it triggers dependency recompilation on every run
- Static config (compile-time constants) goes in `config/config.exs`

> **PR #551:** "Please use env in runtime.exs only, cause for dev environment it trigger re-compile dependencies on each run."

### 7. Right Layer for the Work

**Ask: should this computation happen on the backend or frontend?**

- If the backend already has the data cached, compute there (don't make N client-side lookups)
- If it's a filter/flag, set it server-side before sending to client
- Global cleanup jobs belong in Manager/Supervisor modules, not per-map/per-request

> **PR #513:** "Better to have isWH flag filled on BE side for every kill in list, before sending it to client. Will be much less work on client to fetch every system static data. On BE we already have all static data cached."
> **PR #366:** "Move the logic to MapManager to run cleanup on all deleted signatures, not for specific maps only."

### 8. Settings Tab Placement

**Admin-only settings go in the Admin Settings tab, not in a separate tab.**

- If a setting requires `ADMIN_MAP` permission, it belongs inside the existing Admin Settings tab
- Don't create a new top-level tab for settings that are only visible to admins
- User-facing settings go in the appropriate existing tab (Common, Systems, etc.)

> **PR #590:** DanSylvest: "Is this settings able only for admin or for each user?" → "only admin" → "Then please move it into this tab [Admin Settings]"

### 9. UI PRs Need Screenshots

**Every PR that changes UI must include screenshots** in the PR description or as a comment.

- Show each new/modified UI element
- Show different states (enabled/disabled, empty/populated, admin/user view)
- Use the format DanSylvest uses: inline images in markdown

> **PR #591:** "Could you please attach some screenshots of all UI elements which u did implement"
> **PR #477:** DanSylvest provided annotated screenshots showing expected layout

### 10. Check the Base Branch — Don't Assume

The upstream default branch is now **`main`**, and all PRs since ~#615 (mid-2026) target `main`. `develop` still exists but has been stale since Feb 2026. Older entries in this checklist that reference `develop` predate that switch.

```bash
# Confirm before opening the PR — don't hardcode either name:
gh repo view wanderer-industries/wanderer --json defaultBranchRef
gh pr list --repo wanderer-industries/wanderer --state merged --limit 5 --json number,baseRefName

gh pr create --base main --repo wanderer-industries/wanderer
```

Substitute the confirmed base for `develop` in every `git diff $BASE..HEAD` command below.

### 11. Regenerate Ash Resource Snapshots

**Any change to an Ash resource attribute must be accompanied by a regenerated snapshot under `priv/resource_snapshots/`.** A hand-written corrective migration is not enough — if the snapshot still holds the old value, the next `mix ash_postgres.generate_migrations` emits a duplicate migration on top of yours.

```bash
mix ash.codegen <name>     # regenerates snapshots + migration together
git status priv/resource_snapshots/   # must be non-empty if you touched an attribute
```

> **PR #642:** dedo1911: "The Ash resource snapshot wasn't regenerated. `priv/resource_snapshots/repo/maps_v1/20260406213852.json` still has `"default": "'{wormholes}'"` while `map.ex` now says `["wormholes"]`, so the next `mix ash_postgres.generate_migrations` will emit a duplicate migration on top of your corrective one."

### 12. Data-Repair Migrations

- **Derive the literal you're matching on, don't transcribe it.** A hand-copied byte list in a `WHERE` clause that's one character off matches zero rows and repairs nothing — silently.
  ```elixir
  # BAD: transcribed; a typo silently repairs nothing
  @bad_default ~w(123 119 ...)
  # GOOD: derived from the offending literal itself
  @bad_default ~c"{wormholes}"
  ```
- **`down/0` does not have to mirror `up/0`** — restoring a buggy default would reintroduce the bug. Drop the default instead, leave repaired rows repaired, and **write a comment saying why** the rollback is deliberately asymmetric.
- Verify the migration rolls back and re-applies cleanly before pushing.

> **PR #640 (self-review):** the transcribed-constant version would have had an invisible failure mode.

### 13. CI Changes

- **`--only integration`, never `--include integration`.** `--include` re-runs the entire suite (~926 tests, ~10 extra minutes) and re-reports failures the main test job already covers. `--only` runs just the tagged ~64.
- **Don't turn a currently-red job into a hard gate.** If a job is failing for reasons your PR doesn't fix, keep `continue-on-error: true` and drop it in a follow-up once the fixing PR lands.
- **Attribute failures correctly.** Before claiming a failure is yours (or isn't), run it on the base commit. Pre-existing failures on `main` — e.g. `mix format --check-formatted` — should be called out as pre-existing, not silently fixed or silently blamed.
- Duplicated setup steps across workflow jobs match existing convention (the repo has no `.github/actions/`); extracting a composite action is out of scope — say so rather than doing it.

> **PR #642:** "keep `continue-on-error` here, let #637 land, then drop the line in a follow-up" / "`--only integration` runs just the ~64 tagged ones."

### 14. Verify Cross-PR Dependency Claims

When a PR depends on, is blocked by, or conflicts with another PR, **grep the tree for the symbol before asserting it**. Maintainers reproduce these claims and will correct a wrong one.

```bash
gh pr diff <other-pr> --repo wanderer-industries/wanderer | grep -n "<symbol>"
git grep -n "<symbol>" origin/main
```

State the file the dependency actually lives in, not just the PR number.

> **PR #642:** dedo1911: "the prerequisite is #639, not #635. #635 doesn't touch the duplication path at all, and `acceptable_attrs` doesn't exist in it (or anywhere in the tree yet)."

## Quick Pre-Push Script

Run this before pushing any upstream PR branch:

```bash
Run this before pushing any upstream PR branch. Set `BASE` to the confirmed base branch (section 10).

```bash
BASE=${BASE:-origin/main}

# 1. Debug artifacts
echo "=== DEBUG ARTIFACTS ==="
git diff $BASE..HEAD -- '*.ts' '*.tsx' '*.ex' '*.exs' | grep -n "console\.\(log\|info\|debug\)" | head -20

# 2. Magic numbers in new Elixir code
echo "=== POTENTIAL MAGIC NUMBERS ==="
git diff $BASE..HEAD -- '*.ex' '*.exs' | grep -E "^\+.*[^@]: [0-9]+" | grep -v "test\|spec\|migration" | head -20

# 3. Raw Ecto in non-repo files
echo "=== RAW ECTO OUTSIDE REPOS ==="
git diff $BASE..HEAD -- '*.ex' | grep -E "^\+.*import Ecto\.Query" | grep -v repo | head -10

# 4. Config in dev.exs
echo "=== ENV IN DEV.EXS ==="
git diff $BASE..HEAD -- config/dev.exs | grep -E "^\+.*System\.get_env" | head -10

# 5. Props that should be hooks
echo "=== OUTCOMMAND AS PROP ==="
git diff $BASE..HEAD -- '*.tsx' | grep -E "^\+.*outCommand.*Props|^\+.*outCommand\?:" | head -10

# 6. Unmemoized inline computations in JSX
echo "=== UNMEMOIZED INLINE COMPUTATIONS ==="
git diff $BASE..HEAD -- '*.tsx' | grep -E "^\+.*options=\{.*\.map\(|^\+.*items=\{.*\.filter\(|^\+.*data=\{.*\.reduce\(" | head -10

# 7. Conditional show/hide of action buttons (should be disable/enable)
echo "=== SHOW/HIDE BUTTONS (should be disabled) ==="
git diff $BASE..HEAD -- '*.tsx' | grep -E "^\+.*\{.*&&.*<(Wd)?Button|^\+.*\{.*&&.*<button" | head -10

# 8. Ash resource attribute changed without a regenerated snapshot
echo "=== ASH SNAPSHOT DRIFT ==="
if git diff --name-only $BASE..HEAD -- 'lib/wanderer_app/api/*.ex' | grep -q .; then
  git diff --name-only $BASE..HEAD -- priv/resource_snapshots | grep -q . \
    || echo "!! api/ resource changed but no snapshot regenerated — run mix ash.codegen"
fi

# 9. Integration tests run with --include instead of --only
echo "=== CI: --include integration ==="
git diff $BASE..HEAD -- '.github/**' | grep -E "^\+.*--include integration" | head -5

# 10. New hard gate on a job that is red on base
echo "=== CI: continue-on-error removed ==="
git diff $BASE..HEAD -- '.github/**' | grep -E "^-.*continue-on-error" | head -5
```

## Common Mistakes

| Mistake | Fix |
|---------|-----|
| "I'll clean up console.logs later" | Clean them NOW. They always slip through. |
| Inline PubSub broadcast | Grep for existing `broadcast_*` helper first |
| Number literal in logic | Create `@constant_name` module attribute |
| New component takes outCommand prop | Use `useMapState()` or `useMapRootState()` inside |
| Complex client-side data lookup | Check if backend can provide it pre-computed |
| PR description is just a title | Add summary bullets + screenshots for UI changes |
| Inline `.map()` / `.filter()` in JSX props | Wrap in `useMemo` with proper deps |
| `{condition && <Button />}` for actions | Use `disabled={!condition}` instead — avoids layout shifts |
| `flex` for input + button row | Use `grid` with `gridTemplateColumns: '1fr auto'` |
| Admin-only setting in its own tab | Put it inside Admin Settings tab |
| `useRef` to avoid effect dependencies | Put `outCommand` in the dep array directly |
| `console.error` in catch blocks | Use silent catch (`// do nothing`) like other settings components |
| Assuming the PR base is `develop` | Confirm the default branch — it's `main` now |
| Hand-written migration, stale snapshot | Run `mix ash.codegen` so `priv/resource_snapshots/` matches the resource |
| Transcribed literal in a repair migration's `WHERE` | Derive it from the offending literal — a typo repairs zero rows silently |
| `down/0` mirrors `up/0` and restores the bug | Make it asymmetric and comment why |
| `mix test --include integration` in CI | `--only integration` — `--include` re-runs the whole suite |
| Removing `continue-on-error` from a red job | Leave it; drop it in a follow-up after the fixing PR lands |
| Blaming/claiming a CI failure without checking base | Run it on the base commit first; label pre-existing failures as such |
| "This depends on PR #N" from memory | `gh pr diff #N \| grep <symbol>` before saying it |
