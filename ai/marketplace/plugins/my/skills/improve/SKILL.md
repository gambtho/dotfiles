---
name: improve
description: Holistic codebase review focused on architecture drift, duplicate logic across packages, code smells, quality, tests, and UX — returns up to 10 high-impact improvements (sharp over padded). Reads project conventions from CLAUDE.md/AGENTS.md before the review. Use when the user asks about tech debt, what to refactor, code audit, codebase health, what needs fixing, improvement opportunities, or general code quality review.
argument-hint: "[backend | frontend | diff | since:<date> | <package-or-path>]"
---

# Codebase Improvement Review

## Platform Compatibility

This skill is portable across Claude Code and OpenCode. Adapt instructions based on your environment:

| Concept | Claude Code | OpenCode |
|---------|-------------|----------|
| **Config file** | `CLAUDE.md` | `CLAUDE.md` or `AGENTS.md` |
| **Parallel agents** | Use `Agent` tool with `explore` | Use `task` tool with `subagent_type: "explore"` |
| **Memory path** | `~/.claude/projects/<project>/memory/` | Use `memory_set` tool (scope: `project`) |
| **Code-simplifier rules** | `~/.claude/plugins/cache/.../code-simplifier/*/rules/` | `~/.config/opencode/skills/code-simplifier/rules/` or `~/.dotfiles/ai/opencode/skills/code-simplifier/rules/` |

**Platform detection**: If your system prompt mentions "OpenCode", use OpenCode conventions. Otherwise use Claude Code conventions.

Perform a holistic codebase review and produce a ranked list (up to 10) of the highest-impact improvements. Use this skill to continuously improve any codebase. **Before running, read the project's `CLAUDE.md` or `AGENTS.md`** to learn its architecture rules, language stack, and project-specific conventions — these inform what counts as architectural drift in Phase 2.

## What this skill is for (read before every run)

The value of this skill is finding what linters can't. `golangci-lint`, `make check`, `npm run lint`, and `tsc` already catch formatting, simple error handling, unused imports, and basic type errors — those results feed Phase 1 as *inputs*, they are not the output. The goal of Phase 2 and the top-10 synthesis is to surface things a thoughtful reviewer would flag:

- **Architectural drift** — business logic leaked into HTTP handlers or SQLite queries; domain packages depending on concrete adapters; responsibilities that have slid to the wrong layer
- **Duplicate logic, not duplicate code** — two packages computing the same business concept with different implementations (e.g. fee math, price scoring, campaign health done two ways)
- **Misplaced responsibilities** — one service doing four jobs; god-objects; handlers calculating things they should delegate
- **Dead abstractions** — interfaces with one implementation and no test substitutes; wrapper types that add nothing; config options no caller uses
- **Code smells** — parallel if/switch chains dispatching on the same type; stringly-typed APIs; boolean flag parameters; primitive obsession; feature envy; round-trip transformations

**Ranking rule:** if a finding could have been produced by a linter, `make check`, or a basic grep for `TODO`, it does not belong in the top 10 unless it is a genuine correctness or security issue. Every high-ranked finding should be something that required reading code and reasoning — not just tool output. See Step 4 for the reserved-slots rule.

**Better to return 6 sharp findings than 10 mediocre ones.** Do not pad.

## Step 0: Parse argument and determine scope

Parse the argument to determine review scope:

| Argument | Scope | Phase 1 Commands | Phase 2 Categories |
|----------|-------|-----------------|-------------------|
| *(empty)* | Full codebase | All backend + frontend | All 10 categories |
| `backend` | Go backend only | Backend only | Categories 1-6, 8-10 |
| `frontend` | React frontend only | Frontend only | Categories 1-4, 7-8 |
| `diff` | Files changed since last `/improve` run | Scoped to changed files | All applicable |
| `since:<date>` | Files changed since date (e.g. `since:2026-04-10`) | Scoped to changed files | All applicable |
| `<package>` | Specific package deep dive | Backend scoped to package | All applicable, deep dive |

**Diff-aware mode:** For `diff` or `since:<date>`, scope both Phase 1 and Phase 2 to the files changed in that window. This is useful as a lightweight post-work check rather than a full sweep.

- For `diff`: read `Last Run Commit` from the memory file (Step 5 writes it). Then:
  ```bash
  git diff --name-only "<last_run_commit>"..HEAD
  ```
  If no `Last Run Commit` is stored (first run, or older memory format), fall back to using the memory's `Last Run` date via the `since:<date>` path below.
- For `since:<date>`: dates are ISO 8601 (`YYYY-MM-DD`). Run:
  ```bash
  git log --since="<date>" --name-only --pretty=format: | sort -u | grep -v '^$'
  ```

Pass the resulting file list as the scope for Phase 1 (run tests/lint scoped to packages touched) and Phase 2 (read only those files). If the file list is empty, print "No changes since last run" and stop — do not run a full sweep.

**Package argument validation:** The `<package>` scope is **backend only**. If the argument is not a recognized keyword (`backend`, `frontend`, `diff`, or `since:*`), verify it matches an existing directory under `internal/` (any level — `domain/`, `adapters/httpserver/`, `adapters/storage/sqlite/`, `adapters/scheduler/`, `platform/`, etc.). If no match, list available backend packages and ask the user to pick one. To review a frontend area, use the `frontend` scope (there is no per-package frontend deep dive — the web tree is small enough that `frontend` is the appropriate granularity).

## Step 1: Check for previous findings

**Claude Code:** Read the memory file at `~/.claude/projects/<current-project>/memory/improve_findings.md` if it exists. Determine `<current-project>` from the current working directory (Claude Code maps each project dir to a memory subdir under `~/.claude/projects/`).

**OpenCode:** Use `memory_list` to check if a `project`-scoped block named `improve-findings` exists. If it does, read its contents.

Note what was found last time so you can compare — which issues persist, which improved, which are new. If no previous findings exist, this is the first run.

## Step 2: Phase 1 — Quantitative Sweep

Run all available tooling to establish a factual baseline. Execute commands in parallel where possible. **Failures are findings, not blockers** — capture all output and continue.

### Backend commands (skip if scope is `frontend`)

**Parallelism:** issue these as parallel Bash tool calls in a single message — do not use shell `&` backgrounding, and do not run them serially. Capture each command's output; failures are findings, not blockers.

Run the project's quality gate and tests. Read CLAUDE.md or the project's Makefile to discover the right commands. Common patterns:

```bash
# Go projects: typically a 'make check' target plus race-tested coverage
make check                                     # if defined
go test -race -timeout 10m -coverprofile=coverage.out ./...
```

If the project lacks a quality-gate target, fall back to running its linter, type checker, and test suite individually. Skip what isn't applicable (e.g. don't run `go test` on a Python project).

After those complete, run (sequentially, since they depend on `coverage.out`):

```bash
# Total coverage — last line of output
go tool cover -func=coverage.out | tail -1

# Per-function coverage, sorted by coverage ascending (top of list = least covered)
# Only keep the tail; don't dump the whole thing into context.
go tool cover -func=coverage.out | sort -k3 -n | head -40
```

**Integration tests are intentionally out of scope.** `internal/integration/` uses the `integration` build tag and requires API keys in `.env`; running them during `/improve` would fail on missing creds.

For package-scoped runs, restrict tests to the package:
```bash
go test -race -coverprofile=coverage.out ./internal/<path-to-package>/...
```
`make check` always runs the full repo — that's fine for package scope too, since the architecture and file-size checks are cheap.

### Frontend commands (skip if scope is `backend` or a specific package)

Run these in parallel:

```bash
# Adjust the dir and script names to match the project's package.json.
# Common dirs: 'web/', 'frontend/', 'app/', or repo root.
cd <web-dir> && npm run lint    # or lint:strict, lint:fix --check, etc.
cd <web-dir> && npm run typecheck
cd <web-dir> && npm test
```

### Dependency health (all scopes)

```bash
# Check for unused Go modules
go mod tidy -diff 2>&1 || true

# Check for known npm vulnerabilities
cd web && npm audit --audit-level=moderate 2>&1 || true
```

Capture any findings — unused modules or vulnerabilities are findings, not blockers.

### Structural analysis (all scopes)

Use Glob and Grep to gather:

1. **File sizes** — Find all `.go` files (excluding `*_test.go` and `testutil/mocks/`) and count lines. Flag files approaching or exceeding the 500-line guideline.
2. **Coverage by package** — Use the `go tool cover -func=coverage.out | tail -1` total from Phase 1, and the `| sort -k3 -n | head -40` slice for the least-covered functions. Flag any functions at 0% in packages CLAUDE.md identifies as critical (auth, payments, core domain logic). If CLAUDE.md doesn't list critical packages, treat any package containing money math, auth, persistence, or scheduled jobs as critical.
3. **Test file gaps** — List packages that have no `_test.go` files at all.
4. **LOC distribution** — Count lines per top-level package (`internal/domain/*`, `internal/adapters/*`, `internal/platform/*`, `cmd/*`, `web/src/*`).
5. **Silent-failure pattern** — Grep for `return nil, nil` in non-test Go files. Each match is a potential silent failure (a function hands back a nil result with no error context). Capture the file:line list and the count; Phase 2 Category 4 triages which are legitimate (e.g. cache miss) vs. bugs.
   ```bash
   grep -rn "return nil, nil" --include="*.go" . | grep -v _test.go | grep -v /testutil/
   ```

For package-scoped or diff-scoped runs, restrict structural analysis to the relevant files.

## Step 3: Phase 2 — Qualitative Analysis

Using Phase 1 data as a guide, do targeted code reading. Phase 1 points at *where* to look; Phase 2 decides *what matters*. Remember the ranking rule at the top — the goal is findings a linter couldn't have produced.

**Parallelize with sub-agents.** For full-codebase or backend scope, spawn 3 explore agents in parallel in a single message:
- **Claude Code:** Use 3 `Agent` tool calls with `explore` type in one message.
- **OpenCode:** Use 3 `task` tool calls with `subagent_type: "explore"` in one message.

For narrow scopes (single package, diff, frontend-only), run in the main context — sub-agents add overhead that isn't worth it for small reviews.

### Agent roles

The split is deliberate: Agent 1 is the high-value "senior reviewer" agent, and its findings should dominate the final top 10. Agents 2 and 3 are the floor — they catch the boring-but-real issues.

- **Agent 1 — Semantic & architectural (the one that matters most)**: Categories 1 (Maintainability at the service/package level), 3 (Duplicate logic across packages), 6 (Architecture & code smells). **Prime this agent** by having it read the project's architecture docs first (look for `docs/ARCHITECTURE.md`, `ARCHITECTURE.md` at repo root, or the architecture section of `CLAUDE.md`) so it has a mental model of the intended layering before it looks for drift. **Target 3 findings by default.** Return up to 5 only if all 5 would independently earn a top-10 slot — no borderline Low-severity picks to hit a quota. Returning 2 excellent findings is a better outcome than 5 mixed ones; the orchestrator backfills Low-severity spots from other agents if needed.
- **Agent 2 — Correctness & quality**: Categories 2 (Dead Code), 4 (Code Quality / swallowed errors), 5 (Tests), 9 (Performance & Concurrency). **Target 3 findings by default**, up to 5 if warranted. **Prime this agent** by reading the language idiom rules that match the scope. Look for code-simplifier rule files:
  - **Claude Code:** `~/.dotfiles/ai/opencode/skills/code-simplifier/rules/<lang>.md`
  - **OpenCode:** `~/.config/opencode/skills/code-simplifier/rules/<lang>.md` or `~/.dotfiles/ai/opencode/skills/code-simplifier/rules/<lang>.md`
  
  If the plugin/skill is not installed, proceed without it; the agent's value is what linters miss regardless. **Don't re-surface findings that `make check`/`golangci-lint` already flagged** — Agent 2's value is what linters miss (deviations from idiom rules, swallowed errors lint can't see because they're technically handled, test assertions that never fail). **Evidence-verification rule: before reporting anything as dead code or "unused export", run a grep for the identifier across the whole repo (including `cmd/`, `internal/`, and `*_test.go`) and confirm no callers exist. Coverage gaps for wiring code are expected — they are not evidence of dead code. Dead-code and unused-export claims require grep evidence, not intuition or zero-coverage inference. If you haven't grepped, don't flag.**
- **Agent 3 — Surface & dependencies**: Categories 7 (UX), 8 (Docs), 10 (Deps). **Target 2 findings, max 3** — this category often produces low-impact noise, so keep the budget tight. Return 0 if nothing warrants a top-10 slot.

### How to structure each agent's prompt

**The strict output contract must be the FIRST block of the agent prompt — before role, before Phase 1 data, before anything else.** Observed failure mode: when the contract is buried mid-prompt or placed at the end, sub-agents ignore it and produce prose preambles ("Now I have enough data...", "Here are my findings...", "Based on my analysis..."). Putting it first, as the first thing the agent reads, fixes this.

Order each agent prompt as 5 blocks:

**Block 1 — Strict output contract (the FIRST block):**

```
STRICT OUTPUT CONTRACT — read this before anything else:
- Your response MUST begin with the literal characters `### #1:` — no prose preamble, no acknowledgement sentence, no "Now I have enough data", no "Here are my findings", no "Based on my analysis". The orchestrator discards everything before the first `###`.
- Your response MUST end with the last finding's fields — no concluding summary, no "Let me know if you need more detail".
- If nothing warrants a top-10 slot, your response is the single line `No findings worth top-10 consideration.` and nothing else.
- Padding is a failure mode. Returning fewer findings than your target is valid and expected when the code doesn't warrant more — a two-finding return from Agent 1 tells the orchestrator something real.
```

**Block 2 — Role, categories, and priming reads** (copy the bullet for this agent from the Agent-roles list above, and include the specific priming reads: architecture docs for Agent 1 per the priming instruction above; the `code-simplifier` rule files for Agent 2).

**Block 3 — Phase 1 data summary:**

```
Scope: <full | backend | frontend | diff | package>
Coverage total: <N%>
Least-covered functions (top 20): <list>
Zero-test packages: <list>
Files over 500 LOC: <list with line counts>
return nil, nil occurrences: <count, plus file:line list>
Lint/check failures from `make check`: <summary>
npm audit findings: <summary>
Previous findings (from memory): <titles + status, so the agent can annotate new/persists/regression>
```

**Block 4 — Finding format** (the template from Step 4).

**Block 5 — Kickoff sentence**, literally: `Now begin. First character of your response must be '#'.` This re-asserts the contract at the moment generation starts.

Review across these categories (skip categories not applicable to the current scope per the table in Step 0):

### Category 1: Maintainability
- Read files flagged as large in Phase 1 — identify natural split points (separate strategies, separate concerns, utilities)
- Look for functions with high cyclomatic complexity, deep nesting, long parameter lists
- Identify god-objects or services doing too much

### Category 2: Dead Code & Unused Dependencies
- Search for exported functions/types with no callers outside their own package
- Check for unused struct fields, constants, or interface methods
- Look for stale imports in `go.mod` or unused dependencies in `package.json`

### Category 3: Duplication

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

### Category 4: Code Quality
- Triage lint warnings from Phase 1 by severity
- Look for swallowed errors (bare `_` on error returns) or errors missing context wrapping
- Identify inconsistent patterns (some places use one approach, others use another)

### Category 5: Test Quality
- Focus on packages with low or zero coverage from Phase 1
- Look for tests that don't assert anything meaningful (happy-path only)
- Check for missing edge case coverage on the critical business logic CLAUDE.md identifies (e.g. money math, auth, parsing, scheduled jobs)

### Category 6: Architecture & code smells

`check-imports.sh` catches the mechanical hexagonal violations. This category is about the ones it can't catch — the ones that require reading code and asking "does this belong here?"

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

### Category 7: UX Friction (full codebase and frontend scope only)
- Run the Playwright screenshot suite to capture current UI state:
  ```bash
  # If the project has a Playwright screenshot suite, run it. Adjust dir + spec path:
  cd <web-dir> && npx playwright test <screenshot-spec-path> --project=chromium
  ```
- Read screenshots from the project's screenshot output dir (commonly `<web-dir>/screenshots/`). If there is no screenshot suite, skip this and rely on Category 8 for UI/docs-related findings.
- Check for accessibility gaps (missing aria labels, keyboard navigation issues)
- Identify inconsistent UI patterns across pages

### Category 8: Documentation & API
- Spot-check that docs match current code (look for `docs/API.md`, `docs/SCHEMA.md`, OpenAPI specs, or whatever convention the project uses)
- For full-stack projects: check that backend type/serialization tags (e.g. Go JSON tags, Python Pydantic models) match the corresponding frontend type definitions
- Identify undocumented endpoints or misleading comments

### Category 9: Performance & Concurrency
- Look for unbounded goroutines or missing context cancellation in long-running operations
- Check for N+1 query patterns in the SQLite layer (queries inside loops)
- Identify unbounded slice growth or missing pagination in list endpoints
- Look for blocking operations in hot paths that should be async

### Category 10: Dependency Health
- Review `go mod tidy -diff` output from Phase 1 for unused modules
- Review `npm audit` output from Phase 1 for known vulnerabilities
- Check for pinned vs floating dependency versions that could cause supply chain risk

## Step 4: Synthesize and rank — up to 10

From all Phase 1 and Phase 2 findings, select **up to 10** of the highest-impact items. Don't pad: if only 6 findings deserve a spot, return 6. If only 3, return 3. Seven sharp findings beats ten diluted ones — dilution trains the reader to ignore the list.

### Ranking logic

Severity weighted against effort. High-severity / small-effort items rank highest; low-severity / large-effort items rank lowest. The rough matrix:

| | Small effort | Medium effort | Large effort |
|---|---|---|---|
| **High severity** | top of list | middle | bottom, but still include |
| **Medium severity** | upper middle | middle | only if impact is large |
| **Low severity** | lower middle | usually cut | cut |

### Reserve for semantic findings

At least **3 of the top 10 slots** should be semantic/architectural findings from Agent 1 (logic duplication, architecture drift, code smells) — things that required reading code and reasoning, not just reading tool output.

If Agent 1 returned fewer than 3 findings worthy of the top 10, that's a signal to look harder before synthesizing — not to fill with linter-catchable noise. It's explicitly fine to return 7 strong findings rather than pad to 10 with weak items. A surfaced "we didn't find much this run" is a valid outcome and tells the reader something real.

### Field definitions (read before using the template)

- **Type**
  - **Issue**: objectively verifiable — failing test, missing test, architecture-check violation, dead code, security flaw.
  - **Observation**: judgment call — code smell, UX friction, API ergonomics, naming.
- **Category**: Maintainability | Dead Code | Duplication | Quality | Tests | Architecture | UX | Docs | Performance | Dependencies
- **Severity**
  - **High**: correctness, security, data loss, or widely felt drag on daily development
  - **Medium**: real pain for some workflows, but not a blocker
  - **Low**: polish, ergonomics, minor inconsistency
- **Effort**
  - **Small**: < 1hr, usually one file
  - **Medium**: 1–4hr, coordinated change across a few files
  - **Large**: 4hr+, likely needs design discussion

### Finding format

Present each finding in this exact shape:

```
### #N: [Short title]
**Category**: [see categories above]
**Type**: Issue | Observation
**Severity**: High | Medium | Low
**Effort**: Small | Medium | Large
**Location**: file_path:line_number (or package name for broad issues)

[2-3 sentence description. State what's wrong AND why it matters — the cost of leaving it alone. For semantic findings, include the specific evidence: the two places doing the same thing, the god-service's method list, the interface with its one impl.]

**Suggested approach**: [1-2 sentences on how to fix it]
```

If there are previous findings from Step 1, note for each item whether it is **new**, **persists** from last run, or represents a **regression**.

## Step 5: Save findings to memory and clean up

**Claude Code:** Write the summary to the same memory path used in Step 1 (`~/.claude/projects/<current-project>/memory/improve_findings.md`). When updating an existing file, **preserve the metrics history table** — append a new row and keep the last 5 rows. For findings, update the status of resolved items (add the PR number if known) and add new items.

**OpenCode:** Use `memory_set` with `scope: "project"` and `label: "improve-findings"` to store the summary. Include the description field: `"Latest codebase review findings from /improve skill"`. OpenCode's memory blocks have size limits (~5000 chars), so keep the format concise — store only the current metrics row plus the last 2 rows of history, and summarize findings to title + status only.

```markdown
---
name: improve-findings
description: Latest codebase review findings from /improve skill — used for tracking improvement over time
type: project
---

## Last Run: [YYYY-MM-DD, ISO 8601]
**Scope**: [full | backend | frontend | diff | <package>]
**Last Run Commit**: `[output of git rev-parse HEAD at run time]`

### Metrics History
| Date | Scope | Coverage | Lint | 500+ LOC | Zero-test pkgs | nil,nil | npm audit |
|------|-------|----------|------|----------|----------------|---------|-----------|
| [today] | [scope] | [N%] | [N] | [N] | [N] | [N] | [N] |
| [prev] | [scope] | [N%] | [N] | [N] | [N] | [N] | [N] |

### Top Findings
1. [Title] — opened [date], status: open
2. [Title] — opened [date], status: open
3. [Title] — opened [prev date], status: resolved (PR #NNN)
...

### Key Metrics (current run)
- Go test coverage: [N%]
- Go lint warnings: [N]
- Files over 500 LOC: [N] ([list them])
- Packages with zero tests: [N]
- Frontend TS type errors: [N]
- Frontend lint warnings: [N]
- Test failures: [N]
- return nil, nil in production: [N]
- npm audit vulnerabilities: [N]
```

If `MEMORY.md` exists in the memory directory, ensure it has a pointer to this file. If `MEMORY.md` does not exist, create it:

```markdown
- [Improve Findings](improve_findings.md) — Latest /improve skill review results and metrics
```

**Clean up artifacts:**

```bash
rm -f coverage.out
```

## Step 6: Interactive follow-up

After presenting the top 10, offer these options:

> "What next? You can:
> - **Pick a number** to dig deeper into a specific finding
> - **'go'** to start working on #1
> - **'quick wins'** to tackle all Small-effort items in sequence
> - **'compare'** to see how metrics changed over time
> - **'changed'** to see what code changed since the last run (different from the `diff` scope mode — this is a summary, not a fresh review)"

From there, be conversational:
- If the user picks a number, provide deeper analysis of that finding — show the specific code, explain the trade-offs, discuss approach options
- If the user says "go" or picks a number to work on, help implement the fix
- If the user says "quick wins", filter to Small-effort items and work through them in order
- If the user says "compare", show the metrics history table with trend arrows
- If the user says "changed", summarize what's changed in the codebase since the last run (use `Last Run Commit` from memory: `git diff --stat "<last_run_commit>"..HEAD` for a file-level overview, and `git log "<last_run_commit>"..HEAD --oneline` for the commit list). This is a conversational summary, not a re-run of the review — if they want a scoped re-review, they should invoke `/improve diff` instead
- If the user wants to reorder priorities, adjust and re-present
- If the user is done, wrap up
