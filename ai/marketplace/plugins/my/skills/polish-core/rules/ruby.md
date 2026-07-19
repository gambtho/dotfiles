# Ruby Simplification Rules

## Language-Specific Simplifications

### Ruby Idioms
- Remove explicit `return` at end of methods (Ruby returns last expression implicitly)
- Use `unless` instead of `if !condition` for simple negative conditionals
- Use guard clauses (early return) to reduce nesting: `return if condition` / `raise if condition`
- Use `begin/rescue` at method level instead of wrapping the entire body in `begin/rescue/end`
- Replace `for..in` with `.each`
- Use `dig` for nested hash/array access instead of chained `[]` with nil checks
- Replace manual iteration with `map`, `select`, `reject`, `reduce`, `each_with_object`
- Use symbol keys with new hash syntax (`key:` instead of `:key =>`)
- Use string interpolation with double quotes instead of concatenation
- Remove unnecessary `self.` prefix (keep only for assignment disambiguation)
- Don't `freeze` already-immutable objects (integers, symbols, `true`/`false`)
- Use `&:method_name` shorthand for simple block-to-proc conversions

### Safety
- Ensure `method_missing` always has a corresponding `respond_to_missing?`
- Prefer `public_send` over `send` when the method should be public
- Prefer `class_eval` / `instance_eval` with blocks over string evaluation
- Use refinements instead of monkey-patching core classes
- Replace mutable default arguments (`def foo(bar = [])`) with `nil` + `||=` or `.dup`
- Add `# frozen_string_literal: true` magic comment (or use `freeze` on string constants)
- Catch specific exception classes instead of bare `rescue` (which catches `StandardError`) or `rescue Exception` (which catches `SystemExit`, `SignalException`)

### Control Flow
- Replace `if/elsif` chains on a single value with `case/when`
- Use ternary only for simple, single-line assignments (never nest them)
- Use `||=` for memoization of simple values
- Use `&.` (safe navigation) instead of `x && x.method`

### Rails (when applicable)
- Move business logic out of controllers into models, services, or form objects
- Replace explicit callbacks with side effects with explicit service calls
- Use `find_each` / `in_batches` for large record iterations instead of `.each`
- Parameterize all SQL -- never interpolate user input into query strings
- Add database-level constraints, not just ActiveRecord validations
- Use `update_column` / `save(validate: false)` only with clear justification

### Scope and Structure
- Keep methods short and focused on one responsibility
- Use `private` / `protected` boundaries -- don't leave everything public
- Extract repeated logic into well-named private methods
- Prefer composition over deep inheritance hierarchies (max 2-3 levels)
- Service objects should have a single public method (conventionally `call`)
