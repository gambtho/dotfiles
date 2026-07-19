# TypeScript / JavaScript Simplification Rules

## Language-Specific Simplifications

### Type Narrowing
- Replace manual type checks with TypeScript narrowing (`in`, `instanceof`, discriminated unions)
- Replace `as` type assertions with type guards when possible
- Use `satisfies` instead of `as` for compile-time validation without widening

### Modern Syntax
- Replace `var` with `const` / `let`
- Use optional chaining (`?.`) instead of manual null checks
- Use nullish coalescing (`??`) instead of `||` for defaults (avoids falsy bugs with `0`, `""`)
- Use template literals instead of string concatenation
- Destructure objects/arrays when it improves clarity (but not excessively)
- Use `Object.entries()`, `Object.fromEntries()` instead of manual key iteration

### Functions
- Prefer named `function` declarations over arrow function expressions for top-level functions (hoisting, stack traces)
- Use arrow functions for callbacks and inline lambdas
- Replace `arguments` with rest parameters (`...args`)
- Replace `.bind(this)` with arrow functions
- Remove unnecessary `async` on functions that don't `await`

### Control Flow
- Replace `promise.then().catch()` chains with `async/await`
- Use `for...of` instead of `for (let i = 0; ...)` when index isn't needed
- Replace `arr.forEach()` with `for...of` when `break`/`return`/`await` is needed
- Use `Array.from()` or spread instead of `Array.prototype.slice.call()`
- Replace nested `.then()` chains with sequential `await`

### Modules
- Use ES module `import/export` over CommonJS `require/module.exports`
- Sort imports: external deps, then internal modules, then relative paths
- Remove unused imports
- Use named exports over default exports for better refactoring support

### Error Handling
- Avoid wrapping entire function bodies in try/catch; catch at the appropriate boundary
- Use specific error types over generic `Error`
- Don't catch errors just to rethrow them unchanged

### React (when applicable)
- Extract complex inline JSX expressions into named variables
- Replace `useMemo`/`useCallback` that don't actually prevent re-renders
- Use explicit `Props` type interfaces, not inline types
- Move static data outside component bodies
