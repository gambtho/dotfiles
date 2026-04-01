---
description: Review code changes since a specified commit for quality, idiomacy, patterns, and unnecessary complexity
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
- `AGENTS.md` — project-specific coding guidelines for AI agents (authoritative)
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

### 3d: Duplication Detection

Actively search the existing codebase for functionality that overlaps with newly added code:

- **Utility functions**: For any new helper or utility function, search the codebase for existing functions that do the same or substantially similar thing. Check common locations: `utils/`, `helpers/`, `lib/`, `common/`, `shared/`, and language-specific equivalents.
- **Standard library / framework builtins**: Flag cases where new code reimplements something available in the language's standard library or the project's existing framework (e.g. writing a custom `debounce` when lodash is already a dependency, hand-rolling a retry loop when the HTTP client supports retries, reimplementing `os.path.join` behavior manually).
- **Near-duplicate logic**: Look for existing code blocks that perform the same transformation, validation, API call pattern, or data processing — even if variable names differ. Pay attention to similar control flow structures in the same module or neighboring files.
- **Constants and configuration**: Check if newly defined constants, magic numbers, or config values already exist elsewhere under different names.
- **Type definitions**: For new types, interfaces, or structs, search for existing types that represent the same concept or have substantially overlapping fields.

For each duplication found:
- Reference the existing code location (`file_path:line_number`)
- Explain what it already provides
- Suggest whether to reuse the existing code, consolidate into a shared abstraction, or justify why the duplication is warranted

### 3e: Unnecessary Complexity

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

### 3f: Comment Quality

Flag comments that add no value beyond what the code already communicates:

- **Tautological comments**: Comments that restate the code in English (`// increment counter` above `counter++`, `// set name` above `self.name = name`, `# loop through items` above `for item in items`)
- **Obvious type/parameter comments**: Docstrings or JSDoc that merely repeat the type signature without adding context (`@param name string - the name`, `Returns: bool — returns a boolean`)
- **Noise comments**: Section dividers, `// end of function`, `// constructor`, file-header boilerplate that restates the filename, or auto-generated comments that weren't cleaned up
- **Stale comments**: Comments that no longer match the code they describe — the code was changed but the comment wasn't updated
- **Commented-out code**: Dead code left behind in comments without explanation (note: `TODO`/`FIXME` with issue references are fine)
- **Journal comments**: Comments tracking what changed and when, which belong in git history, not in the source (`// Added 2024-01-15`, `// Modified by John`)

Comments that ARE valuable and should NOT be flagged:
- **Why comments**: Explaining non-obvious intent, business rules, or constraints (`// We retry 3x here because the upstream API is flaky during deployments`)
- **Warning comments**: Flagging gotchas, edge cases, or non-obvious consequences (`// ORDER MATTERS: auth middleware must run before rate limiting`)
- **Context comments**: Linking to external resources, specs, or tickets that explain the reasoning
- **Complexity comments**: Explaining algorithms, workarounds, or domain-specific logic that isn't self-evident

For each flagged comment, suggest either removal or a rewrite that adds genuine value.

---

## Phase 3.5: Leverage Specialized Agents

After completing your own analysis in Phase 3, dispatch specialized agents in parallel to deepen the review. Use the Task tool to launch these — they run concurrently and return findings you should incorporate into the final report.

**Launch these agents in parallel on the changed files:**

| Agent | Purpose |
|-------|---------|
| @silent-failure-hunter | Finds swallowed errors, empty catch blocks, fallbacks that hide failures |
| @comment-analyzer | Validates comment accuracy and identifies comment rot |
| @type-design-analyzer | Reviews new types/interfaces for encapsulation and invariant quality |
| @code-reviewer | Catches bugs, logic errors, and security issues with confidence filtering |

For each agent, provide:
- The list of changed files and their paths
- The base commit and branch context
- A brief description of what the changes do (from your Phase 3 analysis)

**Important:**
- Only dispatch agents that are relevant to the changes (e.g. skip type-design-analyzer if no new types were introduced, skip silent-failure-hunter if there's no error handling code)
- Launch all relevant agents in a single parallel call — do not wait for one before starting another
- Merge agent findings into the appropriate sections of your Phase 4 report (Critical, Improvements, etc.), crediting the agent source
- If an agent finds something you missed, include it. If an agent flags something you already covered, deduplicate — keep the more detailed version.
- If agents are unavailable or fail, proceed with your own analysis — agent findings are supplementary, not required

---

## Phase 4: Compile the Review

Present the review in the following format:

```markdown
# Code Review: {BASE_COMMIT_SHORT}..HEAD

**Commits reviewed**: {count}
**Files changed**: {count} ({additions} additions, {deletions} deletions)
**Languages**: {detected languages}
**Conventions applied**: {sources — e.g. "AGENTS.md, .eslintrc, codebase patterns"}

---

## Summary

{2-4 sentence high-level assessment of the changes. What do they do? Are they in good shape overall?}

---

## Findings

### Critical
{Issues that are likely bugs, security problems, or will cause failures. Each with file:line reference.}

### Improvements
{Issues related to code quality, idiomacy, or pattern violations that should be fixed. Each with file:line reference and a concrete suggestion.}

### Duplication
{New code that duplicates existing functionality in the codebase, standard library, or project dependencies. Each with a reference to the existing code and a recommendation to reuse or consolidate.}

### Simplifications
{Places where complexity can be reduced. Each with a concrete simpler alternative.}

### Noisy Comments
{Comments that restate the code, are stale, or add no value. Each with a suggestion to remove or rewrite.}

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
