---
name: review-code
description: >-
  Supplementary code review guidance for language-specific idioms, codebase
  pattern adherence, and complexity analysis. Use this alongside /review to
  provide deeper, structured feedback beyond what the built-in review covers.
---

# Enhanced Code Review Skill

This skill supplements Copilot's built-in `/review` command with deeper analysis in three areas that `/review` typically handles at a surface level: **language-specific idiom enforcement**, **codebase pattern adherence**, and **unnecessary complexity detection**.

## How to Use

1. First, run `/review` to get the baseline code review
2. Then invoke this skill to layer on the additional checks below
3. Present findings in the structured output format at the bottom

Alternatively, the user may ask you to do a full review incorporating both — in that case, apply all of these checks alongside your standard review.

---

## 1. Language-Specific Idiom Checks

Detect the languages in the changed files (by extension and project markers), then apply the relevant idiom checks. Only check languages actually present in the diff.

### JavaScript/TypeScript
- Modern syntax used (`const`/`let` over `var`, arrow functions where appropriate, optional chaining `?.`, nullish coalescing `??`)
- TypeScript types are meaningful (no unnecessary `any`, proper use of generics, discriminated unions where applicable)
- Async/await used correctly (no unhandled promises, proper error propagation, no unnecessary `.then()` chains when `await` is cleaner)
- Functional patterns where appropriate (`map`/`filter`/`reduce` over imperative loops for transforms)
- Destructuring used where it improves clarity
- Template literals over string concatenation for multi-part strings

### Python
- Pythonic idioms (list comprehensions over `map`/`filter` where clearer, context managers for resources, f-strings over `format`/`%`)
- Type hints on function signatures (parameters and return types)
- No bare `except:` — specific exceptions caught
- Proper use of standard library (`pathlib` over `os.path`, `dataclasses`/`attrs` where appropriate)
- `with` statements for file/resource handling
- Walrus operator `:=` where it eliminates redundant computation

### Go
- All errors checked and handled (no ignored error returns)
- Short variable declarations (`:=`) where appropriate
- Proper use of interfaces (small, focused)
- No unnecessary pointer usage
- Goroutines have lifecycle management (context cancellation, WaitGroups)
- `errors.Is`/`errors.As` for error comparison (not `==`)
- Table-driven tests where patterns repeat

### Rust
- Proper ownership and borrowing (no unnecessary `.clone()`)
- `Result`/`Option` used idiomatically (combinators over match where cleaner, `?` operator for propagation)
- No `unwrap()`/`expect()` in library/production code without justification
- Derive macros used appropriately
- Lifetime elision relied on where possible

### Java/Kotlin
- Modern language features used (streams, records, sealed classes, pattern matching where available)
- Null safety handled properly (`Optional` in Java, null safety in Kotlin)
- Resources closed properly (try-with-resources)
- Immutability preferred where state doesn't need to change

### Ruby
- Idiomatic Ruby (blocks, proper enumerable usage, guard clauses)
- Convention over configuration followed
- Safe navigation operator `&.` where appropriate

### C/C++
- RAII and smart pointers over raw `new`/`delete` (C++)
- No buffer overflows, use-after-free, or memory leaks
- Const correctness throughout
- Move semantics used where appropriate (C++)

---

## 2. Codebase Pattern Adherence

This is the most valuable check — it compares new code against **actual patterns in the existing codebase**, not just generic best practices.

### How to Detect Patterns

For each modified file (not newly created), read the surrounding code context — the full file or at minimum 50-100 lines around each change. This gives you a baseline for:

- **Naming conventions**: variable, function, type, file naming patterns (camelCase vs snake_case, prefixes, suffixes)
- **Error handling style**: How does the codebase handle errors? (wrapper functions? custom error types? logging patterns?)
- **Import ordering**: How are imports organized? (grouped by category? alphabetical? framework-first?)
- **Testing patterns**: What test framework, assertion style, test naming, and setup/teardown patterns are used?
- **API patterns**: What request/response conventions, parameter patterns, and middleware chains are in use?
- **Logging conventions**: What format, levels, and structured fields are used?
- **Code organization**: Where do different types of code live? (controllers, services, models, utilities)

For newly created files, find 1-2 similar existing files (same directory, same type) and compare patterns.

### What to Flag

Flag deviations from established patterns with the phrase: *"The rest of the codebase does X, but this code does Y"* — this is far more actionable than generic advice.

---

## 3. Unnecessary Complexity Detection

Flag any of these anti-patterns, and **always suggest the simpler alternative**:

| Anti-Pattern | Description | Example |
|-------------|-------------|---------|
| **Over-abstraction** | Helpers, utilities, base classes, or interfaces for something used only once | A `UserFactory` class when there's only one place users are created |
| **Premature generalization** | Making things configurable or extensible beyond current requirements | Adding a plugin system when there's only one implementation |
| **Over-engineering** | Design patterns where a simple function call would suffice | Factory + Strategy pattern for a 3-case switch |
| **Unnecessary indirection** | Wrapper functions that just call another function | `getUser()` that only calls `fetchUser()` |
| **Overly clever code** | Prioritizing cleverness over readability | Complex ternary chains, unnecessary bitwise ops |
| **Gold plating** | Features or edge cases beyond what was needed | Handling pagination when the API never returns >10 items |
| **Redundant validation** | Re-validating data already validated upstream | Checking `user != null` after a function that guarantees non-null |
| **Unnecessary async** | Making things async when they don't need to be | `async` function with no `await` calls |
| **Premature optimization** | Caching/memoization without evidence of a performance problem | Memoizing a function called once per request |

---

## Structured Output Format

Present findings using this structure. Omit empty sections.

```markdown
# Enhanced Code Review: {BASE_COMMIT_SHORT}..HEAD

**Commits reviewed**: {count}
**Files changed**: {count} ({additions} additions, {deletions} deletions)
**Languages**: {detected languages}
**Conventions applied**: {sources — e.g. "AGENTS.md, eslint.config.mjs, codebase patterns"}

---

## Summary

{2-4 sentence high-level assessment}

---

## Findings

### Critical
{Bugs, security problems, or things that will cause failures. Each with file:line reference.}

### Improvements
{Code quality, idiom violations, or pattern deviations. Each with file:line and a concrete suggestion.}

### Simplifications
{Places where complexity can be reduced. Each with a concrete simpler alternative.}

### Nits
{Minor convention issues. Keep this short — only things a linter wouldn't catch.}

### Positive
{Things done well — good patterns, clean implementations, thoughtful design.}

---

## File-by-File Notes

### `{file_path}` ({status: added/modified})
- Line {N}: {finding}
- Lines {N-M}: {finding}

(repeat for each file with findings)
```

### Formatting Rules

- Use `file_path:line_number` format for all references
- For each finding, explain **why** it's an issue and **what** to do instead
- Group related findings together
- Always ground feedback in the actual codebase patterns — not generic best practices
- Be balanced — include positive findings where warranted
- If changes are trivially correct, say so briefly and don't force findings
