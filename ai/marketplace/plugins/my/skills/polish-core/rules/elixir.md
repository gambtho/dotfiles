# Elixir Simplification Rules

## Language-Specific Simplifications

### Pattern Matching
- Use pattern matching in function heads instead of `case`/`cond` inside function bodies
- Use multi-clause functions over `if/else` or `cond` for distinct cases
- Destructure in function parameters directly instead of inside the body
- Use `_` for ignored values, named `_prefix` when the name aids readability
- Use pin operator `^` to match against existing values instead of guard comparisons

### Pipe Operator
- Use `|>` pipelines for sequential data transformations
- Don't pipe into single function calls (no benefit: `x |> foo()` → `foo(x)`)
- Break long pipelines into named intermediate variables when the pipeline exceeds 5-6 steps
- First argument should flow naturally through the pipe -- restructure functions to accept the "data" as first arg

### Control Flow
- Use `with` for chains of pattern matches that can fail, instead of nested `case`
- Replace `if nil_check` with pattern matching
- Use guard clauses (`when`) in function heads for type/value constraints
- Use `cond` for multiple boolean conditions, `case` for pattern matching on a single value
- Avoid deeply nested `case` -- extract to named functions

### Enum and Stream
- Use `Enum.map/filter/reduce` over manual recursion for collection operations
- Use `Stream` for lazy evaluation of large/infinite collections
- Use `Enum.into()` with a target collectable instead of `Enum.map() |> Map.new()`
- Replace `Enum.filter() |> Enum.map()` with `Enum.flat_map()` or comprehension `for` when clearer
- Use `Enum.any?/all?/find` instead of manual flag-and-loop patterns

### Functions and Modules
- Use `def` for public API, `defp` for internal helpers -- don't leave everything public
- Keep modules focused on a single responsibility
- Use `@moduledoc` and `@doc` for public functions
- Use `@spec` typespec annotations for public function signatures
- Replace anonymous functions wrapping named functions with capture: `&Module.fun/arity`

### OTP Patterns (when applicable)
- Use `GenServer` for stateful processes, not raw `spawn`/`receive`
- Handle unexpected messages in `handle_info` with a catch-all clause (log + ignore)
- Use `Supervisor` with appropriate restart strategies
- Keep `init/1` fast -- defer expensive work to `handle_continue`
- Use `Registry` or named processes over passing PIDs

### Data
- Use structs with `@enforce_keys` for domain entities instead of bare maps
- Use `Map.get/3` with a default instead of `Map.get/2 || default` (avoids falsy issues)
- Use `Keyword` lists for options, maps for data
- Prefer `Map.update!/3` over `Map.get` + `Map.put` for atomic updates

### Error Handling
- Use `{:ok, result}` / `{:error, reason}` tuples consistently
- Use `with` to chain operations that return ok/error tuples
- Use `raise` / `rescue` only for truly exceptional situations, not for flow control
- Bang functions (`!`) for operations that should crash on failure
