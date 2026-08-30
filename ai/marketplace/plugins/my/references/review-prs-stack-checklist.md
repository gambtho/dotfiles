# `/review-prs` — stack detection and review checklist

Read this once during Phase 2 (project stack detection). Use the **Detection** column to figure out what's in the project, then assemble the review checklist by including only the sections matching what you detected.

The checklist has two layers:
1. **Universal items** (always include) — listed at the bottom.
2. **Stack-specific items** — include only what applies.

## Stack detection table

### Languages

| Detection signal | Language/Platform | Stack-specific section |
|---|---|---|
| `package.json` | Node.js / JavaScript / TypeScript | JS/TS |
| `tsconfig.json` (often alongside `package.json`) | TypeScript | TypeScript |
| `go.mod` | Go | Go |
| `Cargo.toml` | Rust | Rust |
| `pyproject.toml`, `requirements.txt`, or `setup.py` | Python | Python |
| `pom.xml`, `build.gradle`, or `build.gradle.kts` | Java / Kotlin | Java/Kotlin |
| `Gemfile` | Ruby | (general principles only) |
| `mix.exs` | Elixir | (general principles only) |
| `*.csproj` or `*.sln` | C# / .NET | (general principles only) |

### Frameworks & tooling (check `package.json` dependencies if present)

| Marker | Stack | Section |
|---|---|---|
| `"react"` in dependencies | React frontend | React |
| `"@mui/material"` in dependencies | MUI components | MUI |
| `.storybook/` directory | Storybook | Storybook |
| `"vitest"` or `"jest"` in devDependencies | Test framework | Vitest/Jest |
| `"next"` in dependencies | Next.js | (use React + general performance) |
| `"vue"` in dependencies | Vue.js | (general principles only) |
| `angular.json` | Angular | (general principles only) |
| `tailwind.config.*` | Tailwind | (general principles only) |
| `"i18next"` or `"react-i18next"` | i18n expected | i18n |
| `"express"`, `"fastify"`, or `"koa"` | Node.js backend | (general principles only) |

### Conventions

| File | Convention to apply |
|---|---|
| `LICENSE` | Read it — determine expected license type for license-header section |
| `CONTRIBUTING.md` | Read for contribution guidelines (commit format, PR requirements) |
| `CLAUDE.md` or `AGENTS.md` | Read for project-specific coding guidelines (treat as authoritative) |
| `.eslintrc*` or `eslint.config.*` | ESLint conventions in use — flag violations |
| `.prettierrc*` | Prettier formatting in use |
| `Makefile` or `justfile` | Build/task conventions |

---

## Universal review checklist (always include)

### Code Quality
- No obvious bugs or logic errors
- No security vulnerabilities (OWASP top 10)
- No unnecessary complexity or over-engineering
- Proper error handling and edge cases considered
- No duplicated code that should be abstracted
- No debug statements left in production code

### Alignment
- Changes match the PR description
- Changes address the linked issue (if any)
- No unrelated changes mixed in
- Scope is appropriate (not too broad, not incomplete)

### Testing
- New functionality has test coverage
- Tests are meaningful (not just testing implementation details)
- Edge cases covered in tests

---

## Stack-specific checklists

### JS/TS (when `package.json` detected)
- TypeScript types are correct (no `any` unless justified)
- No `console.log` or debug statements left in production code
- Async/await error handling is correct (no unhandled promise rejections)
- Dependencies added to the correct section (dependencies vs devDependencies)

### React (when `"react"` in deps)
- Components follow existing patterns in the codebase
- Props are properly typed
- Effects have correct dependency arrays
- No unnecessary re-renders from object/function references in render

### MUI (when `"@mui/material"` in deps)
- Uses MUI components consistently (not raw HTML for styled UI elements)
- Theme-aware colors used (no hardcoded colors that break dark mode)

### Storybook (when `.storybook/` exists)
- New components have Storybook stories (`.stories.tsx` / `.stories.jsx`)
- Stories cover meaningful states (not just default rendering)

### i18n (when `"i18next"` / `"react-i18next"` detected)
- User-facing strings are internationalized (wrapped in `t()` / `useTranslation`)

### Vitest/Jest (when test framework detected)
- Tests use the project's test framework and assertion patterns
- Tests follow existing patterns (React Testing Library, etc.)

### Go (when `go.mod` detected)
- All errors are checked and handled
- Exported functions have doc comments
- No goroutine leaks (goroutines have proper lifecycle management)
- Input validation for external data (no command injection, path traversal)
- Tests use the project's assertion library (testify, standard, etc.)

### Rust (when `Cargo.toml` detected)
- Proper use of `Result` and `Option` types
- No unnecessary `unwrap()` / `expect()` in library code
- Lifetime annotations are correct

### Python (when `pyproject.toml` / `requirements.txt` / `setup.py` detected)
- Type hints present on public functions
- Proper exception handling (no bare `except:`)
- No security issues (SQL injection, command injection, path traversal)

### Java/Kotlin (when `pom.xml` / `build.gradle*` detected)
- Proper null handling
- Resources properly closed (try-with-resources)
- Thread safety considered for shared state

### License Header (when `LICENSE` detected)
- License header present on new source files matching the project's license

### Commit Message Format (when CONTRIBUTING.md specifies one or config.md defines one)
- Commit messages follow the project's required format

---

## Assembly procedure

1. Walk the detection table and note which signals are present.
2. Compose the final checklist as: **universal** + each matched stack-specific section, in the order detected.
3. Print the assembled checklist so the user sees what will be checked.
4. Pass the assembled checklist to each review agent in their prompt (Phase 6).
