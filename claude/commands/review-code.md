---
name: review-code
description: Review code changes since a specified commit for quality, idiomacy, patterns, and unnecessary complexity
argument-hint: "[commit ref — defaults to HEAD~1]"
allowed-tools: Bash(git log:*), Bash(git diff:*), Bash(git rev-parse:*), Bash(git show:*), Bash(git status:*), Bash(git remote:*), Bash(git branch:*), Read, Glob, Grep, Task
---

# Code Review Since Commit

You are performing a thorough code review of all changes since a specified commit in the current repository. Your review focuses on: code quality, idiomatic usage for the language(s) involved, adherence to existing codebase patterns and conventions, and elimination of unnecessary complexity.

**Commit reference**: $ARGUMENTS (default: `HEAD~1` if not specified — i.e. review the most recent commit)

---

## Phase 0: Validate Environment

1. Run `git rev-parse --is-inside-work-tree` to confirm we're in a git repo. If not, print an error and **STOP**.
2. Resolve the target commit:
   - If `$ARGUMENTS` is provided, run `git rev-parse --verify $ARGUMENTS` to validate it.
   - If not provided, use `HEAD~1`.
   - If resolution fails, print the error and **STOP**.
3. Store the resolved commit as `BASE_COMMIT`.
4. Run `git log --oneline BASE_COMMIT..HEAD` to show the user the commits being reviewed.
5. Run `git diff --stat BASE_COMMIT..HEAD` to show a summary of files changed.
6. If there are no changes (empty diff), print "No changes found since {BASE_COMMIT}" and **STOP**.

---

## Phase 1: Detect Project Stack & Conventions

**Goal**: Understand the languages, frameworks, and conventions in use so the review is contextually relevant.

### 1a: Language & Framework Detection

Scan the repository root for markers:

| File | Language/Platform |
|------|-------------------|
| `package.json` | Node.js / JavaScript / TypeScript |
| `tsconfig.json` | TypeScript |
| `go.mod` | Go |
| `Cargo.toml` | Rust |
| `pyproject.toml` / `requirements.txt` / `setup.py` | Python |
| `pom.xml` / `build.gradle` / `build.gradle.kts` | Java / Kotlin |
| `Gemfile` | Ruby |
| `mix.exs` | Elixir |
| `*.csproj` / `*.sln` | C# / .NET |
| `CMakeLists.txt` / `Makefile` (with `.c`/`.cpp` files) | C / C++ |
| `pubspec.yaml` | Dart / Flutter |
| `Package.swift` | Swift |

Also examine the changed files themselves to detect languages (by extension) that may not have top-level markers.

### 1b: Convention Detection

Check for these convention sources and read them if they exist:
- `CLAUDE.md` — project-specific coding guidelines (authoritative)
- `CONTRIBUTING.md` — contribution guidelines
- `.editorconfig` — formatting conventions
- Linter configs (`.eslintrc*`, `eslint.config.*`, `.prettierrc*`, `.rubocop.yml`, `.golangci.yml`, `pyproject.toml [tool.ruff]`, `rustfmt.toml`, `.clang-format`, etc.)

### 1c: Codebase Pattern Sampling

For each file that was modified (not newly created), read the surrounding code context — the full file or at minimum 50-100 lines around each change. This gives you a baseline for the patterns, naming conventions, error handling style, and structure used in the existing codebase.

For newly created files, find 1-2 similar existing files (same directory, same type) and read them to understand the expected patterns.

Print a brief summary of the detected stack and conventions.

---

## Phase 2: Gather the Diff

1. Get the full diff:
   ```
   git diff BASE_COMMIT..HEAD
   ```

2. Get the list of changed files with status (added/modified/deleted/renamed):
   ```
   git diff --name-status BASE_COMMIT..HEAD
   ```

3. For each modified or added file, read the full current version of the file to have complete context (not just the diff hunks).

4. If the diff is very large (>3000 lines), prioritize:
   - Source code over generated files, lockfiles, vendored code
   - Modified files over purely added files
   - Note which files were deprioritized

---

## Phase 3: Perform the Review

Review every changed file against the criteria below. Use the codebase context gathered in Phase 1 to calibrate your findings — flag deviations from established patterns, not personal preferences.

### 3a: Code Quality

- No obvious bugs or logic errors
- Correct error handling (appropriate for the language — e.g. Go error checks, Rust `Result` handling, try/catch in JS/Python where needed)
- No security vulnerabilities (injection, XSS, path traversal, hardcoded secrets, etc.)
- No debug statements or temporary code left behind (`console.log`, `print()`, `TODO`/`FIXME`/`HACK` without issue references, commented-out code)
- Proper resource cleanup (file handles, connections, subscriptions, etc.)
- Race conditions or concurrency issues considered where relevant

### 3b: Idiomatic Code

Apply language-specific idiom checks based on the detected languages:

**JavaScript/TypeScript:**
- Modern syntax used (const/let over var, arrow functions where appropriate, optional chaining, nullish coalescing)
- TypeScript types are meaningful (no unnecessary `any`, proper use of generics, discriminated unions where applicable)
- Async/await used correctly (no unhandled promises, proper error propagation)
- Functional patterns where appropriate (map/filter/reduce over imperative loops for transforms)

**Python:**
- Pythonic idioms (list comprehensions over map/filter where clearer, context managers, f-strings over format/%)
- Type hints on function signatures
- No bare `except:` — specific exceptions caught
- Proper use of standard library (pathlib over os.path, dataclasses/attrs where appropriate)

**Go:**
- All errors checked and handled (no ignored error returns)
- Short variable declarations where appropriate
- Proper use of interfaces (small, focused)
- No unnecessary pointer usage
- Goroutines have lifecycle management

**Rust:**
- Proper ownership and borrowing (no unnecessary cloning)
- `Result`/`Option` used idiomatically (combinators over match where cleaner, `?` operator)
- No `unwrap()`/`expect()` in library/production code without justification
- Derive macros used appropriately

**Java/Kotlin:**
- Modern language features used (streams, records, sealed classes, pattern matching where available)
- Null safety handled properly (Optional in Java, null safety in Kotlin)
- Resources closed properly (try-with-resources)

**Ruby:**
- Idiomatic Ruby (blocks, proper enumerable usage, guard clauses)
- Convention over configuration followed

**C/C++:**
- RAII and smart pointers over raw `new`/`delete` (C++)
- No buffer overflows, use-after-free, or memory leaks
- Const correctness

**(Add similar checks for other detected languages as appropriate.)**

### 3c: Codebase Pattern Adherence

This is a critical section — compare the changes against the actual patterns found in Phase 1c:

- **Naming conventions**: Do new variables, functions, types, files follow the same naming patterns as the rest of the codebase? (e.g. camelCase vs snake_case, file naming patterns, test file naming)
- **Code organization**: Do new files live in the right directories? Do new functions/methods fit the existing module structure?
- **Error handling patterns**: Does new error handling match the existing style? (e.g. if the codebase wraps errors with context, new code should too)
- **Import/dependency patterns**: Are imports ordered the same way? Are the same utility libraries used?
- **Testing patterns**: Do new tests follow the existing test structure, assertion style, and naming?
- **API patterns**: Do new endpoints/functions follow the same request/response patterns, parameter conventions, etc.?
- **Logging patterns**: Does new logging match the existing format, levels, and structured fields?

### 3d: Unnecessary Complexity

Flag any of these anti-patterns:

- **Over-abstraction**: Creating helpers, utilities, base classes, or interfaces for something used only once
- **Premature generalization**: Making things configurable or extensible beyond current requirements
- **Over-engineering**: Adding design patterns (factory, strategy, observer) where a simple function call would suffice
- **Unnecessary indirection**: Wrapping things in layers that add no value (wrapper functions that just call another function, unnecessary delegation)
- **Overly clever code**: Code that prioritizes cleverness over readability (obscure one-liners, complex ternaries, unnecessary bitwise operations)
- **Gold plating**: Features, error handling, or edge cases beyond what was needed
- **Redundant validation**: Re-validating data that's already validated upstream
- **Unnecessary async**: Making things async when they don't need to be
- **Complex data transformations**: Chained operations that could be simplified
- **Premature optimization**: Caching, memoization, or performance tricks without evidence they're needed

When flagging complexity, always suggest the simpler alternative.

---

## Phase 4: Compile the Review

Present the review in the following format:

```markdown
# Code Review: {BASE_COMMIT_SHORT}..HEAD

**Commits reviewed**: {count}
**Files changed**: {count} ({additions} additions, {deletions} deletions)
**Languages**: {detected languages}
**Conventions applied**: {sources — e.g. "CLAUDE.md, .eslintrc, codebase patterns"}

---

## Summary

{2-4 sentence high-level assessment of the changes. What do they do? Are they in good shape overall?}

---

## Findings

### Critical
{Issues that are likely bugs, security problems, or will cause failures. Each with file:line reference.}

### Improvements
{Issues related to code quality, idiomacy, or pattern violations that should be fixed. Each with file:line reference and a concrete suggestion.}

### Simplifications
{Places where complexity can be reduced. Each with a concrete simpler alternative.}

### Nits
{Minor style or convention issues. Keep this section short — only include things a linter wouldn't catch.}

### Positive
{Things done well — good patterns, clean implementations, thoughtful design choices.}

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
- Group related findings together (e.g. "the same pattern issue appears in 3 files")
- If no findings exist for a severity level, omit that section entirely
- Keep the review actionable — every finding should have a clear next step

---

## Important Notes

- Do NOT make any changes to the code. This is a read-only review.
- Focus on issues a senior engineer would flag during code review. Skip pedantic nitpicks that formatters and linters handle.
- Always ground your feedback in the actual codebase patterns — "the rest of the codebase does X, but this code does Y" is much more useful than "best practice is X."
- Be balanced — include positive findings where warranted.
- If the changes are trivially correct (e.g. fixing a typo, updating a version), say so briefly and don't force findings where there are none.
- When flagging complexity, be specific about the simpler alternative — don't just say "this is too complex."
