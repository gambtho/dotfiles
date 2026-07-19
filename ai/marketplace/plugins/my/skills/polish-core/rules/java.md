# Java Simplification Rules

## Language-Specific Simplifications

### Modern Java
- Use `var` for local variable type inference when the type is obvious from the right side (Java 10+)
- Use text blocks (`"""`) for multiline strings (Java 13+)
- Use records for immutable data carriers instead of boilerplate POJOs (Java 16+)
- Use sealed classes/interfaces for closed type hierarchies (Java 17+)
- Use pattern matching in `instanceof` checks: `if (obj instanceof String s)` (Java 16+)
- Use switch expressions with `->` syntax and `yield` instead of fall-through switch statements (Java 14+)

### Collections and Streams
- Use `List.of()`, `Map.of()`, `Set.of()` for immutable collections instead of `Collections.unmodifiable*`
- Use Stream API for collection transformations instead of manual loops (when clearer)
- Don't overuse streams -- a simple `for` loop is often more readable for side-effect-heavy operations
- Use `Optional` for return types that may be absent, not for fields or parameters
- Replace `Optional.isPresent()` + `Optional.get()` with `ifPresent()`, `map()`, `orElse()`
- Use `Collectors.toUnmodifiableList()` instead of `Collectors.toList()` when immutability is desired

### Null Safety
- Return `Optional<T>` instead of nullable types for methods that might not return a value
- Use `Objects.requireNonNull()` for fail-fast null checking at boundaries
- Replace null checks with `Optional` chains: `map()`, `flatMap()`, `orElse()`
- Annotate with `@Nullable` / `@NonNull` at API boundaries

### Error Handling
- Catch specific exceptions, never bare `Exception` or `Throwable` unless re-throwing
- Don't catch exceptions just to log and rethrow -- let them propagate
- Use try-with-resources for all `AutoCloseable` resources
- Prefer unchecked exceptions for programming errors, checked for recoverable conditions
- Don't use exceptions for flow control

### Classes and Methods
- Prefer composition over inheritance
- Keep classes focused on a single responsibility
- Use method references (`Class::method`) instead of trivial lambdas
- Extract complex lambda expressions into named methods
- Make fields `final` when they don't change after construction
- Use `static` factory methods instead of complex constructor overloading

### Naming and Structure
- Follow standard conventions: `camelCase` methods/fields, `PascalCase` classes, `UPPER_SNAKE` constants
- Remove unnecessary getters/setters -- consider records or direct field access for internal classes
- Remove dead code: unused methods, unreachable branches, commented-out code
- Minimize field scope: prefer local variables over instance fields when possible
- Use `enum` for fixed sets of constants instead of `int`/`String` constants

### Concurrency
- Use `ExecutorService` / `CompletableFuture` over raw `Thread` creation
- Use `ConcurrentHashMap` over `Collections.synchronizedMap()`
- Minimize synchronized blocks -- lock only what needs protection
- Use `AtomicInteger` / `AtomicReference` for simple atomic operations instead of synchronized
