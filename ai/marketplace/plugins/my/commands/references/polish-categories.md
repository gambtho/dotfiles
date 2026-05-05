# `/polish` — analysis categories

Phase 3 of `/polish` runs through these categories. Each finding carries a **confidence** (HIGH or MEDIUM) and an **action** (`auto-fix` if `--fix` is set; `report` otherwise). The auto-fix bar is deliberately conservative — when in doubt between `auto-fix` and `report`, choose `report`. False positives in auto-fix erode trust.

This file is read once at Phase 3 start. Skim the whole list, then keep findings grounded in actual Grep/Glob evidence — never report a finding you can't point at a specific line for.

---

## 3a: Bugs & Security

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

For each function in the diff, trace its inputs to its outputs. Check boundary values of loops and conditionals. For each error/null check, verify the negative path is handled.

**Action**: all bugs/security findings are `report` at MEDIUM+ confidence. These require human verification — never auto-fix.

## 3b: Idiomatic Code

Check changed code against the language rules loaded in Phase 1. If no language rules were loaded for a given language, apply general idiom knowledge.

**Action**:
- Idiom fixes at HIGH confidence: `auto-fix`
- At MEDIUM confidence: `report`

**Naming improvements**: ALL naming suggestions are `report` regardless of confidence. Include the suggested new name in the finding so the user can accept it easily, but never auto-fix naming changes — naming is inherently subjective and the model may lack domain context (e.g., `k` in cryptography is standard convention, not a poor name).

## 3c: Codebase Pattern Adherence

Compare changed code against patterns established in surrounding (unchanged) files:
- Naming conventions (casing, prefixes, suffixes)
- File/directory organization
- Error handling style (custom error types, wrapping conventions)
- Import organization
- Test structure and naming
- API patterns (request/response shapes, middleware usage)
- Logging patterns (levels, structured fields)

**Action**: pattern deviations are `report` (these require understanding intent).

## 3d: Duplication Detection

Search for:
- Existing utility functions that overlap with newly written code (use Grep to search the codebase)
- Standard library functions that could replace custom implementations
- Near-duplicate logic across changed files
- Copy-pasted blocks with minor variations

**Action**:
- Standard library replacements at HIGH confidence when the replacement is semantically identical: `auto-fix`
- Standard library replacements with subtle behavioral differences (error handling, edge cases with empty input): `report`
- All other duplication findings: `report`

## 3e: Over-Engineering Detection

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

**Action**: all over-engineering findings are `report`. Never auto-fix — these require understanding intent.

When flagging, be specific about the simpler alternative — don't just say "this is too complex."

## 3f: Comment Quality

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

**Action**:
- Tautological comments at HIGH confidence: `auto-fix`
- All other comment findings: `report`

## 3g: Dead Code & Dead Abstractions

Perform call-chain analysis beyond simple reachability. For each category, use Grep/Glob to search the full codebase — not just the diff — to verify liveness.

- **Dead exports** — functions, types, or constants exported but never imported anywhere in the codebase. Use Grep to search for import references across the project. **Action**: `report` (might be part of a public API).
- **Dead parameters** — function parameters that are never read within the function body. **Action**: `report` by default. Only classify as `auto-fix` when ALL of: (1) the function is unexported/private, (2) Grep confirms a single call site in the codebase, and (3) the parameter is not part of an interface/trait/callback contract or public API surface.
- **Dead branches** — conditional branches where the condition is always true or always false based on surrounding code or control flow. **Action**: `auto-fix` at HIGH confidence.
- **Orphaned abstractions** — interfaces, traits, or protocols implemented by exactly one type with no indication of testing or extension intent. **Action**: `report`.
- **Stale feature flags** — feature flags that are always on or always off with no toggle path in the codebase. **Action**: `report`.
- **Dead error handling** — catch/rescue blocks for error types that the called function never throws. Common after refactors where the error type changes but the handler remains. **Action**: `report` (complements silent-failure-hunter, which detects *missing* error handling).
- **Vestigial TODO/FIXME comments** — referencing closed issues, shipped features, or already-refactored code. If the TODO references an issue number, check if it's verifiable as closed. **Action**: `auto-fix` at HIGH confidence if verified closed, otherwise `report`.

## 3h: Structural Simplification

Look for opportunities to reduce nesting via early returns and guard clauses.

**Action**:
- HIGH confidence + simple structure + unambiguous transformation: `auto-fix`
- Functions containing `defer`, `finally`, `ensure`, `with` (Python context manager), or any cleanup/teardown logic: `report` (the transformation can change cleanup ordering)
- When no side effects or cleanup logic follows the if-block and the transformation is straightforward: `auto-fix`

---

## Summary table — what auto-fixes by default

| Category | What auto-fixes |
|---|---|
| 3a Bugs & Security | nothing |
| 3b Idiomatic Code | HIGH-confidence idiom fixes (NOT naming) |
| 3c Pattern Adherence | nothing |
| 3d Duplication | std-lib replacements that are semantically identical |
| 3e Over-Engineering | nothing |
| 3f Comments | HIGH-confidence tautological comments |
| 3g Dead Code | dead branches; dead params (only when private + single-call-site + non-interface); verified-closed vestigial TODOs |
| 3h Structural | early-return / guard-clause simplifications, only when no `defer`/`finally`/`ensure`/`with` |

Plus the import cleanup pass at the end of Phase 4 — after fixes are applied, Grep each modified file for orphaned imports and remove only those with zero remaining references.
