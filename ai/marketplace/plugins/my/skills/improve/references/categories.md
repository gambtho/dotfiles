# Review categories — `my:improve`

The 10 categories the qualitative analysis (Phase 2) hunts across. Each agent owns a subset; the orchestrator inlines the relevant subset into that agent's prompt rather than sending the whole list.

| Agent | Categories owned |
|---|---|
| Agent 1 — Semantic & architectural | 1 (Maintainability), 3 (Duplication), 6 (Architecture & code smells) |
| Agent 2 — Correctness & quality | 2 (Dead Code), 4 (Code Quality), 5 (Tests), 9 (Performance & Concurrency) |
| Agent 3 — Surface & dependencies | 7 (UX), 8 (Docs), 10 (Deps) |

Skip categories not applicable to the current scope (e.g. Category 7 only runs in full or `frontend` scope).

---

## Category 1: Maintainability
- Read files flagged as large in Phase 1 — identify natural split points (separate strategies, separate concerns, utilities)
- Look for functions with high cyclomatic complexity, deep nesting, long parameter lists
- Identify god-objects or services doing too much

## Category 2: Dead Code & Unused Dependencies
- Search for exported functions/types with no callers outside their own package
- Check for unused struct fields, constants, or interface methods
- Look for stale imports in `go.mod` or unused dependencies in `package.json`

## Category 3: Duplication

Three flavors, in order of importance. **Logic duplication is the payoff of this skill** — most linters can find code duplication, none can find this.

1. **Logic duplication (highest value)** — two packages computing the same business concept with different implementations. Examples: fee math done in the inventory service and again in a handler; "is this sale revocable" implemented two different ways; campaign health score computed in two places with different thresholds. Finding technique:
   ```bash
   # Hunt for common business verbs across packages — then compare implementations side by side.
   # Adjust the file extension and root dir to match the project (--include="*.ts" for TypeScript, etc.).
   grep -rn --include="*.go" -E "func [A-Za-z]*(Calculate|Compute|Apply|Derive|Score|Fee|Cost|Margin|Value|Status|Health)" .
   ```
   Cluster results by concept name. For each cluster with >1 implementation, read both and decide: are they computing the same thing? If yes, that's a finding.
2. **Conceptual duplication** — two types or interfaces that model the same domain concept. Examples: two `Sale` structs with overlapping fields, two "price" abstractions, two ways to represent money. Find via: list types per package and look for overlapping names or similar shapes in sibling packages.
3. **Code duplication (lowest value, often linter-catchable)** — identical or near-identical byte-level copies. Spot check files with similar names (e.g., `parse_<source-a>.go`, `parse_<source-b>.go` patterns) for copy-paste drift. If the drift is semantically meaningful (one branch handles a case the other doesn't), that's actually a logic duplication finding — flag it as such.

On the frontend, look for components with overlapping functionality — two badge components, two modal wrappers, two different table implementations.

## Category 4: Code Quality
- Triage lint warnings from Phase 1 by severity
- Look for swallowed errors (bare `_` on error returns) or errors missing context wrapping
- Identify inconsistent patterns (some places use one approach, others use another)

## Category 5: Test Quality
- Focus on packages with low or zero coverage from Phase 1
- Look for tests that don't assert anything meaningful (happy-path only)
- Check for missing edge case coverage on the critical business logic CLAUDE.md identifies (e.g. money math, auth, parsing, scheduled jobs)

## Category 6: Architecture & code smells

Mechanical hexagonal violations are typically caught by a project-specific check (e.g. a `check-imports.sh`). This category is about the ones such checks can't catch — the ones that require reading code and asking "does this belong here?"

**Drift patterns:**
- Business logic leaking into adapter packages — HTTP handlers doing calculations, SQLite queries embedding business rules, scheduler code making policy decisions
- Domain packages that have grown too broad and should be split (a `Service` struct with 20+ methods is a canonical warning sign)
- Interfaces defined in adapter packages but consumed by domain packages (wrong direction)
- Cross-imports between sibling sub-packages where the project's CLAUDE.md or architecture doc forbids them — and especially the subtle cases where one sub-package re-exports another's types

**Code smells to hunt for** (each of these is a reviewer judgment call, not a lint):
- **God services** — one struct with >10 methods spanning multiple responsibilities. Split by concern.
- **Parallel dispatch chains** — multiple if/switch blocks in different files branching on the same type or enum. Often refactorable to polymorphism, a dispatch table, or a single shared helper.
- **One-implementation interfaces** — interfaces with a single impl and no test double. Usually premature abstraction; inline the concrete type until a second impl appears.
- **Feature envy** — a function that calls more methods on its parameter than on its receiver. The behavior probably belongs on the parameter's type.
- **Stringly-typed APIs** — function parameters that are strings but really enumerate a small set of values (`channel string` where only "ebay"/"tcgplayer"/"local" are valid). Should be a typed constant.
- **Boolean flag parameters** — `DoThing(..., isUrgent bool)` is usually two methods smashed into one; the caller site will flip-flop the flag.
- **Primitive obsession** — money, times, IDs passed as `int` or `string` instead of typed wrappers. Especially suspicious when the same int parameter appears in many signatures.
- **Round-trip transformations** — data that goes `A→B→A` or `A→B→C→A` across layers without meaningful change. Usually means a layer isn't earning its keep.
- **Data clumps** — the same 3+ parameters passed together through many call sites. Usually wants a struct.
- **Shotgun surgery indicators** — if Phase 1 shows many files changed together in recent commits for the same feature, that's a shape-fit problem worth investigating.

When reporting an architectural or smell finding: show the evidence (two file paths with the parallel dispatch, or the god-service method list, or the interface and its single impl). Abstract claims without evidence don't make the cut.

## Category 7: UX Friction (full codebase and frontend scope only)
- Run the Playwright screenshot suite to capture current UI state:
  ```bash
  # If the project has a Playwright screenshot suite, run it. Adjust dir + spec path:
  cd <web-dir> && npx playwright test <screenshot-spec-path> --project=chromium
  ```
- Read screenshots from the project's screenshot output dir (commonly `<web-dir>/screenshots/`). If there is no screenshot suite, skip this and rely on Category 8 for UI/docs-related findings.
- Check for accessibility gaps (missing aria labels, keyboard navigation issues)
- Identify inconsistent UI patterns across pages

## Category 8: Documentation & API
- Spot-check that docs match current code (look for `docs/API.md`, `docs/SCHEMA.md`, OpenAPI specs, or whatever convention the project uses)
- For full-stack projects: check that backend type/serialization tags (e.g. Go JSON tags, Python Pydantic models) match the corresponding frontend type definitions
- Identify undocumented endpoints or misleading comments

## Category 9: Performance & Concurrency
- Look for unbounded goroutines or missing context cancellation in long-running operations
- Check for N+1 query patterns in the persistence layer (queries inside loops)
- Identify unbounded slice growth or missing pagination in list endpoints
- Look for blocking operations in hot paths that should be async

## Category 10: Dependency Health
- Review `go mod tidy -diff` output from Phase 1 for unused modules
- Review `npm audit` output from Phase 1 for known vulnerabilities
- Check for pinned vs floating dependency versions that could cause supply chain risk
