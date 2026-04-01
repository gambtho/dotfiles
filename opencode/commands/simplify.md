---
description: Simplify recently modified code for clarity and maintainability
---

# Code Simplifier

Simplify recently modified code for clarity, consistency, and maintainability -- without changing behavior. $ARGUMENTS

## Context

- Modified files (unstaged): !`git diff --name-only 2>/dev/null`
- Modified files (staged): !`git diff --name-only --cached 2>/dev/null`
- Untracked files: !`git ls-files --others --exclude-standard 2>/dev/null`

## Instructions

First, try to load the `code-simplifier` skill using the skill tool. If it loads successfully, follow it exactly.

If the skill is not available, follow these instructions directly:

### Step 1: Identify Modified Files

Use the context above to identify all recently changed source code files. Filter to source files only (ignore images, configs, lockfiles, etc.).

### Step 2: Detect Languages and Load Rules

Map file extensions to languages and read the matching rule files from `~/.config/opencode/skills/code-simplifier/rules/`:

- `.ts`, `.tsx`, `.js`, `.jsx`, `.mjs`, `.cjs` → `rules/typescript.md`
- `.py`, `.pyi` → `rules/python.md`
- `.rb`, `.erb`, `.rake` → `rules/ruby.md`
- `.go` → `rules/go.md`
- `.ex`, `.exs`, `.heex` → `rules/elixir.md`
- `.rs` → `rules/rust.md`
- `.java` → `rules/java.md`

Only read rule files for languages that appear in the modified files. If a rule file doesn't exist for a language, use only the general principles below.

### Step 3: Check for Project Standards

If `AGENTS.md` or `CLAUDE.md` exists at the project root, read it. Project-specific coding standards take HIGHEST PRIORITY over bundled language rules.

### Step 4: Simplify

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

### Step 5: Verify

Ensure all changes are behavior-preserving. If unsure whether a change alters behavior, do not make it.
