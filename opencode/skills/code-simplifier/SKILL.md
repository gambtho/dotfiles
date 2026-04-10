---
name: code-simplifier
description: >-
  Simplify recently modified code for clarity, consistency, and maintainability
  without changing behavior. Detects languages from changed files and applies
  language-specific simplification rules alongside general principles.
---

# Code Simplifier

Simplify recently modified code for clarity, consistency, and maintainability -- without changing behavior.

## Step 1: Identify Modified Files

Look at the git context provided by the command (unstaged, staged, untracked). Filter to source files only -- ignore images, configs, lockfiles, generated files, etc.

If the user provided arguments (e.g. a commit range or file list), use those instead.

## Step 2: Detect Languages and Load Rules

Map file extensions to languages and read the matching rule files from this skill's `rules/` directory:

- `.ts`, `.tsx`, `.js`, `.jsx`, `.mjs`, `.cjs` -> `rules/typescript.md`
- `.py`, `.pyi` -> `rules/python.md`
- `.rb`, `.erb`, `.rake` -> `rules/ruby.md`
- `.go` -> `rules/go.md`
- `.ex`, `.exs`, `.heex` -> `rules/elixir.md`
- `.rs` -> `rules/rust.md`
- `.java` -> `rules/java.md`

Only read rule files for languages actually present in the modified files. If no rule file exists for a language, use only the general principles below.

## Step 3: Check for Project Standards

If `AGENTS.md` or `CLAUDE.md` exists at the project root, read it. Project-specific coding standards take **highest priority** over bundled language rules.

## Step 4: Simplify

Read each modified source file and apply these principles:

- **Preserve functionality.** Never change what the code does -- only how it does it.
- **Reduce nesting.** Use early returns and guard clauses to flatten deeply nested code.
- **Eliminate dead code.** Remove unreachable code, unused variables, unused imports, and redundant abstractions.
- **Improve naming.** Use descriptive names for variables, functions, and parameters.
- **Simplify comments.** Remove comments that describe obvious code. Keep comments that explain WHY.
- **Avoid nested ternaries.** Prefer `if/else` or `switch`/`match` for multiple conditions.
- **Choose clarity over brevity.** Explicit code is better than clever one-liners.
- **Don't combine unrelated concerns.** Each function should do one thing.
- **Don't over-simplify.** Removing a useful abstraction is a regression, not a simplification.
- **Consolidate duplication.** Extract repeated logic -- but only if the extraction is clearer.
- **Prefer standard library.** Replace custom reimplementations with well-known standard library equivalents.
- **Minimize scope.** Move variable declarations closer to their usage.

Also apply any language-specific rules loaded in Step 2.

## Step 5: Verify

Ensure all changes are behavior-preserving. If unsure whether a change alters behavior, do not make it.
