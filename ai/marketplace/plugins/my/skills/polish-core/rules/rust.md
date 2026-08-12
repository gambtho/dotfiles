# Rust Simplification Rules

## Language-Specific Simplifications

### Error Handling
- Use `?` operator for error propagation instead of manual `match` on `Result`/`Option`
- Use `anyhow` or `thiserror` for application/library error types instead of manual `From` impls everywhere
- Use `.context()` / `.with_context()` (anyhow) for error context instead of `.map_err()` with string formatting
- Replace `unwrap()` / `expect()` with proper error handling in library code
- Use `if let` / `let else` for single-pattern matches instead of full `match`

### Ownership and Borrowing
- Pass `&str` instead of `&String`, `&[T]` instead of `&Vec<T>` in function parameters
- Use `impl Into<String>` / `impl AsRef<str>` for flexible function signatures
- Don't `.clone()` unnecessarily -- borrow when possible
- Use `Cow<str>` when a function sometimes needs to allocate and sometimes doesn't
- Prefer moving over cloning when the original value is no longer needed

### Iterators
- Use iterator chains (`.map()`, `.filter()`, `.collect()`) over manual `for` loops with `push`
- Use `.iter()` / `.into_iter()` appropriately (borrowing vs. consuming)
- Use `Iterator::flatten()` instead of nested loops for flat iteration
- Use `.enumerate()` instead of manual counter variables
- Use `.zip()` for parallel iteration
- Collect into the target type directly: `let v: Vec<_> = iter.collect()`

### Pattern Matching
- Use `matches!()` macro for boolean pattern checks
- Use `if let` for single-arm matches with a fallthrough
- Use `let ... else` (Rust 1.65+) for irrefutable-or-diverge patterns
- Combine match arms with `|` for shared behavior
- Use `@` bindings to name matched values when needed

### Types and Traits
- Use `derive` macros for common traits (`Debug`, `Clone`, `PartialEq`, etc.)
- Implement `Display` for user-facing output, `Debug` for developer output
- Use `From`/`Into` for type conversions instead of custom conversion methods
- Prefer generics with trait bounds over `dyn Trait` when the type is known at compile time
- Use associated types over generic parameters when there's only one valid type per implementation
- Use newtypes to enforce type safety for domain concepts

### Modern Syntax
- Use `let-else` instead of match-and-return for early exits
- Use `then()` / `then_some()` on `bool` for conditional `Option` creation
- Replace `if option.is_some() { option.unwrap() }` with `if let Some(v) = option`
- Use `todo!()` for unfinished code instead of `unimplemented!()`

### Structure
- Keep functions short -- extract named functions for logical sections
- Use modules to group related functionality
- Put `pub` items first, then private items
- Minimize `unsafe` blocks -- extract the minimum unsafe operation and wrap with a safe API
