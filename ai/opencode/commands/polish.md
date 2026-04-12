---
description: Analyze code changes, auto-fix high-confidence issues, and report remaining findings
---

# Polish — Review & Fix

You are performing a thorough analysis of all changes since a specified commit, auto-fixing high-confidence issues and reporting the rest. This combines code review with automated simplification.

**Arguments**: $ARGUMENTS (default: `HEAD~1` if not specified)

Parse arguments:
- If `--dry-run` is present, set DRY_RUN=true and remove it from the commit reference.
- Remaining argument is the commit reference (default: `HEAD~1`).

---

## Phase 0: Validate Environment

1. Run `git rev-parse --is-inside-work-tree` to confirm we're in a git repo. If not, print an error and **STOP**.
2. Resolve the target commit (use `HEAD~1` if not specified). If resolution fails, **STOP**.
3. Run `git log --oneline BASE_COMMIT..HEAD` and `git diff --stat BASE_COMMIT..HEAD`.
4. If there are no changes, print "No changes found since {BASE_COMMIT}" and **STOP**.
5. Print mode: "Mode: **polish** (analyze + fix)" or "Mode: **dry-run** (analyze only)" based on the flag.

---

## Phase 1: Detect Stack & Conventions

Scan for language markers in the project root to determine the tech stack:

| Marker File | Language/Framework |
|---|---|
| `package.json`, `tsconfig.json` | JavaScript/TypeScript |
| `go.mod`, `go.sum` | Go |
| `Cargo.toml` | Rust |
| `Gemfile`, `*.gemspec` | Ruby |
| `pyproject.toml`, `setup.py`, `requirements.txt` | Python |
| `mix.exs` | Elixir |
| `pom.xml`, `build.gradle` | Java |
| `Makefile`, `CMakeLists.txt` | C/C++ |

Convention sources (in priority order):
1. `AGENTS.md` or `CLAUDE.md` at project root (highest priority)
2. Linter/formatter configs (`.eslintrc*`, `golangci.yml`, `.rubocop.yml`, `ruff.toml`, etc.)
3. `CONTRIBUTING.md`, `STYLE.md`, or similar docs
4. Patterns sampled from surrounding (unchanged) files

**Load language rules** from the code-simplifier skill. Use the `skill` tool to load the `code-simplifier` skill. Map file extensions from the diff to language rule files:

- `.ts`, `.tsx`, `.js`, `.jsx`, `.mjs`, `.cjs` → `rules/typescript.md`
- `.py`, `.pyi` → `rules/python.md`
- `.rb`, `.erb`, `.rake` → `rules/ruby.md`
- `.go` → `rules/go.md`
- `.ex`, `.exs`, `.heex` → `rules/elixir.md`
- `.rs` → `rules/rust.md`
- `.java` → `rules/java.md`

Only load rules for languages actually present in the changed files. Read each matching rule file from `~/.config/opencode/skills/code-simplifier/rules/`.

Print detected stack summary:
```
Stack: Go, TypeScript
Conventions: AGENTS.md, .eslintrc.json, golangci.yml, codebase patterns
Language rules loaded: go.md, typescript.md
```

---

## Phase 2: Gather the Diff

1. Run `git diff BASE_COMMIT..HEAD` to get the full diff.
2. Run `git diff --name-status BASE_COMMIT..HEAD` to get the file list with status (A/M/D/R).
3. For each added or modified file, read the full current file contents (not just the diff hunks) — context is essential for dead code analysis and pattern detection.
4. For large diffs (>50 files), prioritize source code files. Skip generated files (`*.lock`, `*.min.*`, `dist/`, `build/`, `vendor/`, `node_modules/`).

---

## Phase 3: Analyze

All analysis in this phase is **read-only** — no edits. Each finding is classified with:
- **Confidence:** HIGH or MEDIUM
- **Action type:** `auto-fix` (will be applied in Phase 4), `report` (needs human review), or `info` (observation only)

### 3a: Bugs & Security

Look for:
- Off-by-one errors, incorrect boundary conditions
- Null/undefined dereferences in non-trivial paths
- Race conditions in concurrent code
- Incorrect boolean logic (De Morgan violations, inverted conditions)
- Missing return statements, incorrect error propagation
- Injection vulnerabilities (SQL, command, XSS, path traversal)
- Hardcoded secrets, API keys, tokens
- Missing input validation on external data
- Insecure cryptographic usage
- Improper authentication/authorization checks
- SSRF, open redirects, unsafe URL construction

All bugs/security findings: action `report` at MEDIUM+ confidence. These require human verification.

### 3b: Idiomatic Code

Check changed code against language-specific idioms. Use both the general idiom knowledge and the loaded language rules from Phase 1.

Per-language checks (apply those relevant to the detected stack):

**JavaScript/TypeScript:** `===` over `==`, optional chaining, nullish coalescing, `async/await` over `.then()`, `const`/`let` over `var`, destructuring, template literals, unnecessary `async` on non-awaiting functions.

**Python:** f-strings over `.format()`, context managers, list/dict/set comprehensions, `pathlib` over `os.path`, type hints, walrus operator where clearer, `enumerate` over manual indexing.

**Go:** Error wrapping with `%w`, `errors.Is`/`errors.As`, `any` over `interface{}`, named return values only when useful, table-driven tests, `slices`/`maps` package over manual loops, struct literals with field names.

**Rust:** `?` over explicit match on Result, iterator chains over manual loops, `impl Into<T>` for flexible APIs, derive macros, `clippy` lint compliance.

**Ruby:** `&:method` shorthand, `each_with_object` over `inject` with mutation, guard clauses, `freeze` on string constants, specific exception classes, safe navigation operator.

**Elixir:** Pipeline operator, pattern matching over conditional logic, `with` for sequential operations, proper supervision trees, `@doc`/`@spec` annotations.

**Java:** Try-with-resources, `Optional` over null, streams over manual loops, `var` for local type inference, records for data classes.

Idiom fixes at HIGH confidence: action `auto-fix`. At MEDIUM confidence: action `report`.

### 3c: Codebase Pattern Adherence

Compare the changed code against patterns established in surrounding (unchanged) files:
- Naming conventions (casing, prefixes, suffixes)
- File/directory organization
- Error handling style (custom error types, wrapping conventions)
- Import organization
- Test structure and naming
- API patterns (request/response shapes, middleware usage)
- Logging patterns (levels, structured fields)

Pattern deviations: action `report` (these require understanding intent).

### 3d: Duplication Detection

Search for:
- Existing utility functions that overlap with newly written code (use Grep to search the codebase)
- Standard library functions that could replace custom implementations
- Near-duplicate logic across changed files
- Copy-pasted blocks with minor variations

Duplication findings: action `report`.

### 3e: Over-Engineering Detection

Look for:
- **Over-abstraction** — unnecessary interfaces, wrappers, or indirection layers that add no value
- **Premature generalization** — generic solutions for problems that only exist in one form
- **Gold plating** — features or options beyond what the code's current callers require
- **Unnecessary indirection** — wrapper functions whose body is a single call to another function with the same or fewer parameters
- **Speculative generality** — type parameters, config options, or extension points with exactly one user; a generic type instantiated with only one concrete type
- **Premature DRY** — shared functions extracted from only 2-3 lines of code called from exactly 2 places, where the abstraction obscures intent
- **Deep abstraction stacks** — chains of 3+ delegation layers where intermediate layers add no meaningful logic
- **Config-driven complexity** — config/env vars for behavior that never varies across environments
- **Defensive copies that aren't needed** — deep cloning or copying when consumers never mutate the data

All over-engineering findings: action `report` (these require understanding intent). Never auto-fix.

### 3f: Comment Quality

Flag:
- Tautological comments that repeat what the code says (`// increment i` above `i++`)
- Stale comments that don't match the current code
- Journal-style comments (changelogs in code)
- Noise comments (commented-out code blocks, `// TODO` with no context)

Preserve:
- Comments explaining **why** (business rules, non-obvious decisions)
- Warning comments (`// WARNING:`, `// HACK:`, `// NOTE:`)
- Legal/license headers
- API documentation comments

Tautological comments at HIGH confidence: action `auto-fix`. All others: action `report`.

### 3g: Dead Code & Dead Abstractions

Perform call-chain analysis beyond simple reachability. For each category, use Grep/Glob to search the full codebase — not just the diff — to verify liveness.

- **Dead exports** — functions, types, or constants exported but never imported anywhere in the codebase. Use `grep` to search for import references across the project. Action: `report` (might be part of a public API).
- **Dead parameters** — function parameters that are never read within the function body. Action: `auto-fix` at HIGH confidence.
- **Dead branches** — conditional branches where the condition is always true or always false based on surrounding code or control flow. Action: `auto-fix` at HIGH confidence.
- **Orphaned abstractions** — interfaces, traits, or protocols implemented by exactly one type with no indication of testing or extension intent. Action: `report`.
- **Stale feature flags** — feature flags that are always on or always off with no toggle path in the codebase. Action: `report`.
- **Dead error handling** — catch/rescue blocks for error types that the called function never throws. Common after refactors where the error type changes but the handler remains. Action: `report` (complements silent-failure-hunter, which detects *missing* error handling).
- **Vestigial TODO/FIXME comments** — referencing closed issues, shipped features, or already-refactored code. If the TODO references an issue number, check if it's verifiable as closed. Action: `auto-fix` at HIGH confidence if verified closed, otherwise `report`.

### 3h: Dispatch Subagents

Dispatch the following specialized subagents **in parallel** using the `task` tool:

1. **code-reviewer** (`subagent_type: "code-reviewer"`) — read-only, confidence-filtered general review
2. **silent-failure-hunter** (`subagent_type: "silent-failure-hunter"`) — finds swallowed errors and silent fallbacks
3. **comment-analyzer** (`subagent_type: "comment-analyzer"`) — validates comment accuracy and finds comment rot
4. **type-design-analyzer** (`subagent_type: "type-design-analyzer"`) — reviews type/interface/struct design

Each subagent receives:
- The full diff from Phase 2
- The detected stack and conventions from Phase 1
- Instructions to format findings as: `[Severity|Confidence] file:line — description`

Only dispatch agents relevant to the changes (e.g., skip type-design-analyzer if no new types/interfaces are introduced).

**Deduplication:** After collecting subagent findings, merge them into the main findings list by file location. If a subagent finding duplicates a Phase 3 finding (same file, same line range, same issue category), keep the Phase 3 finding and drop the duplicate. If a subagent finding adds new context to an existing Phase 3 finding, append the context to the existing finding rather than creating a duplicate entry.

Wait for all dispatched subagents to complete before proceeding to Phase 4.

---

## Phase 4: Fix

**Skip this phase entirely if DRY_RUN is true.**

Apply all findings from Phase 3 that are classified as `auto-fix`. Use the Edit tool for each change. Process files one at a time, top-to-bottom within each file to avoid offset drift.

Auto-fix categories:
- Dead imports, unused variables, unreachable code → remove
- Dead parameters → remove from function signature and all call sites
- Dead branches (always-true/always-false conditions) → simplify to the live branch
- Early returns to reduce nesting → restructure with guard clauses
- Language-specific idiom fixes → apply per loaded language rules
- Tautological comments → remove
- Verified vestigial TODOs → remove
- Naming improvements (unambiguous, single-use-site renames) → rename
- Standard library replacements → swap in standard library equivalent
- **Import cleanup pass** — after all fixes above, scan each modified file for imports that became orphaned due to this phase's own changes. Remove them. This is a second-order cleanup to prevent leaving behind stale imports from removed code.

Log every change:

```
Fixing: src/handler.go:42 — Removing dead parameter `ctx`
Fixing: src/handler.go:58 — Early return to reduce nesting
Fixing: src/utils.go:12-18 — Removing unreachable code
Fixing: src/utils.go:1 — Removing orphaned import `fmt`
```

---

## Phase 5: Report

Generate the final report. Format depends on mode:

### Normal mode (after fixes applied):

```
POLISH REPORT — {BASE_COMMIT}..HEAD ({N} files, {N} languages)
═══════════════════════════════════════════════════════════════

FIXED ({N} items):
  ✓ file:line — Short description of what was fixed

NEEDS REVIEW ({N} items):
  ⚠ [Severity|Confidence] file:line — Description of the finding.
    Context: why this matters and what to verify.

SUMMARY:
  {N} items auto-fixed. {N} items need your review.
  Overall: {2-3 sentence assessment}.
```

### Dry-run mode (no fixes applied):

Same format, but:
- "FIXED" becomes "WOULD FIX"
- "✓" becomes "→"
- Add note at top: "**Dry-run mode** — no changes were made."

### Report rules:

- Fixed items: one line each (file:line + short description).
- Review items: include context — what was found, why it matters, what to verify.
- Subagent findings are merged into the main report by file location (not listed in separate blocks).
- Use severity/confidence tags from the code-reviewer format: `[Critical|HIGH]`, `[Warning|MEDIUM]`, etc.
- If there are zero fixed items, omit the FIXED section.
- If there are zero review items, omit the NEEDS REVIEW section and congratulate briefly.
- Include the subagent attribution in parentheses for findings that originated from a subagent: `(via code-reviewer)`, `(via silent-failure-hunter)`, etc.
