---
name: improve
description: Holistic codebase review focused on architecture drift, duplicate logic across packages, code smells, quality, tests, and UX — returns up to 10 high-impact improvements (sharp over padded). Reads project conventions from CLAUDE.md/AGENTS.md before the review. Use when the user asks about tech debt, what to refactor, code audit, codebase health, what needs fixing, improvement opportunities, or general code quality review.
argument-hint: "[backend | frontend | diff | since:<date> | <package-or-path>]"
---

# Codebase Improvement Review

Perform a holistic codebase review and produce a ranked list (up to 10) of the highest-impact improvements. **Before running, read the project's `CLAUDE.md` or `AGENTS.md`** to learn its architecture rules, language stack, and project-specific conventions — these inform what counts as architectural drift in Phase 2.

This skill runs on Claude Code, OpenCode, and Pi. For per-platform substitutions (memory paths, agent dispatch, supporting-skill paths), see `references/platforms.md` — read it before the steps that touch memory or spawn agents.

## What this skill is for (read before every run)

The value of this skill is finding what linters can't. `golangci-lint`, `make check`, `npm run lint`, and `tsc` already catch formatting, simple error handling, unused imports, and basic type errors — those results feed Phase 1 as *inputs*, they are not the output. The goal of Phase 2 and the top-10 synthesis is to surface things a thoughtful reviewer would flag:

- **Architectural drift** — business logic leaked into HTTP handlers or persistence queries; domain packages depending on concrete adapters; responsibilities that have slid to the wrong layer
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
| `backend` | Backend only | Backend only | Categories 1-6, 8-10 |
| `frontend` | Frontend only | Frontend only | Categories 1-4, 7-8 |
| `diff` | Files changed since last `/improve` run | Scoped to changed files | All applicable |
| `since:<date>` | Files changed since date (e.g. `since:2026-04-10`) | Scoped to changed files | All applicable |
| `<package>` | Specific package deep dive | Backend scoped to package | All applicable, deep dive |

**Diff-aware mode:** for `diff` or `since:<date>`, scope both Phase 1 and Phase 2 to the files changed in that window. This is useful as a lightweight post-work check rather than a full sweep.

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

**Package argument validation:** the `<package>` scope is **backend only**. If the argument is not a recognized keyword (`backend`, `frontend`, `diff`, or `since:*`), verify it matches an existing directory under the project's backend source tree (e.g. `internal/`, `pkg/`, `src/`). If no match, list available backend packages and ask the user to pick one. To review a frontend area, use the `frontend` scope.

## Step 1: Check for previous findings

Read the memory file for this project (path varies per platform — see `references/platforms.md`). Note what was found last time so you can compare — which issues persist, which improved, which are new. If no previous findings exist, this is the first run.

## Step 2: Phase 1 — Quantitative Sweep

Run all available tooling to establish a factual baseline. Execute commands in parallel where possible. **Failures are findings, not blockers** — capture all output and continue.

### Backend commands (skip if scope is `frontend`)

**Parallelism:** issue these as parallel Bash tool calls in a single message — do not use shell `&` backgrounding, and do not run them serially. Capture each command's output; failures are findings, not blockers.

Read `CLAUDE.md` or the project's Makefile to discover the right commands. Common patterns:

```bash
# Go projects: typically a 'make check' target plus race-tested coverage
make check                                     # if defined
go test -race -timeout 10m -coverprofile=coverage.out ./...
```

If the project lacks a quality-gate target, fall back to running its linter, type checker, and test suite individually. Skip what isn't applicable (e.g. don't run `go test` on a Python project).

After those complete, run sequentially (they depend on `coverage.out`):

```bash
# Total coverage — last line of output
go tool cover -func=coverage.out | tail -1

# Per-function coverage, sorted by coverage ascending (top of list = least covered)
go tool cover -func=coverage.out | sort -k3 -n | head -40
```

**Integration tests are intentionally out of scope** — they typically require credentials and would fail during a routine review. If the project gates them behind a build tag (e.g. `integration`), don't enable it.

For package-scoped runs, restrict tests to the package, e.g.:
```bash
go test -race -coverprofile=coverage.out ./internal/<path-to-package>/...
```

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

1. **File sizes** — find source files (excluding tests and generated mocks) and count lines. Flag files that exceed the project's size guideline (commonly 500 lines for Go, but read CLAUDE.md to check).
2. **Coverage by package** — use the `tail -1` total from above and the `sort -k3 -n | head -40` slice for least-covered functions. Flag any 0%-coverage functions in packages CLAUDE.md identifies as critical (auth, payments, core domain logic). If CLAUDE.md doesn't list critical packages, treat any package containing money math, auth, persistence, or scheduled jobs as critical.
3. **Test file gaps** — list packages with no `_test.go` files at all.
4. **LOC distribution** — count lines per top-level package.
5. **Silent-failure pattern** (Go projects) — grep for `return nil, nil` in non-test Go files. Each match is a potential silent failure (a function hands back a nil result with no error context). Capture file:line list and count; Phase 2 Category 4 triages which are legitimate (e.g. cache miss) vs. bugs.
   ```bash
   grep -rn "return nil, nil" --include="*.go" . | grep -v _test.go | grep -v /testutil/
   ```

For package-scoped or diff-scoped runs, restrict structural analysis to the relevant files.

## Step 3: Phase 2 — Qualitative Analysis

Using Phase 1 data as a guide, do targeted code reading. Phase 1 points at *where* to look; Phase 2 decides *what matters*. Remember the ranking rule above — the goal is findings a linter couldn't have produced.

**Read `references/categories.md` first** — it defines the 10 review categories and which agent owns which subset. The agent-role split is intentional: Agent 1 is the high-value "senior reviewer" agent and its findings should dominate the final top 10; Agents 2 and 3 are the floor — they catch the boring-but-real issues.

### Parallelize with sub-agents (full and backend scope)

Spawn 3 explore agents in parallel in a single message — see `references/platforms.md` for the per-platform tool name. For narrow scopes (single package, diff, frontend-only), run in the main context — sub-agents add overhead that isn't worth it for small reviews.

### Agent roles and targets

- **Agent 1 — Semantic & architectural (the one that matters most)**: Categories 1, 3, 6. **Prime this agent** by having it read the project's architecture docs first (look for `docs/ARCHITECTURE.md`, `ARCHITECTURE.md` at repo root, or the architecture section of `CLAUDE.md`) so it has a mental model of the intended layering before it looks for drift. **Target 3 findings by default**, up to 5 if all 5 would independently earn a top-10 slot. Returning 2 excellent findings beats 5 mixed ones; the orchestrator backfills Low-severity spots from other agents if needed.
- **Agent 2 — Correctness & quality**: Categories 2, 4, 5, 9. **Target 3 findings**, up to 5 if warranted. **Prime this agent** by reading the language idiom rules that match the scope (the `code-simplifier` rule files — paths in `references/platforms.md`). If unavailable, proceed without — the agent's value is what linters miss regardless. **Don't re-surface findings that `make check`/`golangci-lint` already flagged.** **Evidence-verification rule**: before reporting anything as dead code or "unused export", grep for the identifier across the whole repo (including `cmd/`, `internal/`, and `*_test.go`) and confirm no callers exist. Coverage gaps for wiring code are expected — they are not evidence of dead code. Dead-code claims require grep evidence, not intuition.
- **Agent 3 — Surface & dependencies**: Categories 7, 8, 10. **Target 2 findings, max 3** — this category often produces low-impact noise, so keep the budget tight. Return 0 if nothing warrants a top-10 slot.

### Structuring each agent's prompt

**The strict output contract must be the FIRST block of the agent prompt — before role, before Phase 1 data, before anything else.** Observed failure mode: when the contract is buried mid-prompt or placed at the end, sub-agents ignore it and produce prose preambles ("Now I have enough data...", "Here are my findings...", "Based on my analysis..."). Putting it first, as the first thing the agent reads, fixes this.

Order each agent prompt as 5 blocks:

**Block 1 — Strict output contract (FIRST):**

```
STRICT OUTPUT CONTRACT — read this before anything else:
- Your response MUST begin with the literal characters `### #1:` — no prose preamble, no acknowledgement sentence, no "Now I have enough data", no "Here are my findings", no "Based on my analysis". The orchestrator discards everything before the first `###`.
- Your response MUST end with the last finding's fields — no concluding summary, no "Let me know if you need more detail".
- If nothing warrants a top-10 slot, your response is the single line `No findings worth top-10 consideration.` and nothing else.
- Padding is a failure mode. Returning fewer findings than your target is valid and expected when the code doesn't warrant more — a two-finding return from Agent 1 tells the orchestrator something real.
```

**Block 2 — Role, categories, and priming reads.** Inline the role bullet from above and the *category descriptions for that agent's owned categories only* — pull them from `references/categories.md` so the agent has the relevant subset without seeing the others. Include the priming reads (architecture docs for Agent 1, code-simplifier rules for Agent 2).

**Block 3 — Phase 1 data summary:**

```
Scope: <full | backend | frontend | diff | package>
Coverage total: <N%>
Least-covered functions (top 20): <list>
Zero-test packages: <list>
Files over the size guideline: <list with line counts>
return nil, nil occurrences: <count, plus file:line list>
Lint/check failures: <summary>
npm audit findings: <summary>
Previous findings (from memory): <titles + status, so the agent can annotate new/persists/regression>
```

**Block 4 — Finding format** (the template from Step 4).

**Block 5 — Kickoff sentence**, literally: `Now begin. First character of your response must be '#'.` This re-asserts the contract at the moment generation starts.

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

If Agent 1 returned fewer than 3 findings worthy of the top 10, that's a signal to look harder before synthesizing — not to fill with linter-catchable noise. It's explicitly fine to return 7 strong findings rather than pad to 10. A surfaced "we didn't find much this run" is a valid outcome and tells the reader something real.

### Field definitions

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

Write the summary to the platform-appropriate memory location — see `references/platforms.md` for the path and any platform-specific size constraints. When updating an existing file, **preserve the metrics history table** — append a new row and keep the last 5 rows. For findings, update the status of resolved items (add the PR number if known) and add new items.

Memory file structure:

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
| Date | Scope | Coverage | Lint | Large files | Zero-test pkgs | nil,nil | npm audit |
|------|-------|----------|------|-------------|----------------|---------|-----------|
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
- Files over size guideline: [N] ([list them])
- Packages with zero tests: [N]
- Frontend TS type errors: [N]
- Frontend lint warnings: [N]
- Test failures: [N]
- return nil, nil in production: [N]
- npm audit vulnerabilities: [N]
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
