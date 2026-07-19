# Go Simplification Rules

## Language-Specific Simplifications

### Error Handling
- Always handle errors -- never discard with `_` unless there's a documented reason
- Use `fmt.Errorf("context: %w", err)` to wrap errors with context (not `%v`)
- Return errors rather than using `log.Fatal` or `panic` in library code
- Use `errors.Is()` / `errors.As()` instead of string matching or type assertions on errors
- Keep error handling at the same level of abstraction as the code it guards
- Don't create custom error types when `fmt.Errorf` suffices

### Naming
- Use short variable names for short-lived variables (`i`, `r`, `w`, `ctx`)
- Use descriptive names for package-level and exported identifiers
- Receivers should be short (1-2 letter abbreviation of type), consistent across methods
- Don't stutter: `http.HTTPServer` → `http.Server`
- Package names are lowercase, single-word, no underscores

### Control Flow
- Use early returns to reduce nesting -- handle the error case first, then the happy path
- Replace `if err != nil { return err }` chains with helper functions only when they genuinely simplify
- Use `switch` instead of `if/else if` chains
- Don't use `else` after a branch that returns/breaks/continues
- Use `range` over manual index loops when index isn't needed: `for _, v := range items`

### Types and Interfaces
- Accept interfaces, return concrete types
- Keep interfaces small (1-3 methods)
- Define interfaces where they're used, not where they're implemented
- Use struct embedding for composition, not inheritance simulation
- Use `any` instead of `interface{}` (Go 1.18+)

### Concurrency
- Don't start goroutines without a clear shutdown mechanism
- Use `context.Context` for cancellation, not channels or flags
- Prefer `sync.Mutex` for simple state protection over channels
- Use `sync.Once` for one-time initialization instead of manual flags
- Close channels from the sender side, never the receiver

### Standard Library
- Use `slices` and `maps` packages (Go 1.21+) over manual sort/search/clone
- Use `strings.Builder` for concatenation in loops, not `+=`
- Use `filepath.Join()` instead of manual path construction
- Use `io.ReadAll` instead of manual buffer management for small reads
- Use `context.WithTimeout` / `context.WithCancel` over manual timer management

### Structure
- Keep functions focused -- if a function needs a comment explaining a section, extract that section
- Group related declarations together
- Put the most important function (or the constructor) first in a file
- Avoid `init()` functions when explicit initialization is possible
