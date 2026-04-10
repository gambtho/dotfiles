# Python Simplification Rules

## Language-Specific Simplifications

### Pythonic Idioms
- Replace manual loops building lists with list/dict/set comprehensions (when the comprehension is clearer)
- Use `enumerate()` instead of manual counter variables
- Use `zip()` instead of parallel index iteration
- Replace `dict.get(key, None)` with `dict.get(key)` (None is the default)
- Use `in` for membership testing instead of manual iteration
- Replace `if x == True` / `if x == False` with `if x` / `if not x`
- Use `any()` / `all()` instead of loop-with-flag patterns
- Use f-strings over `.format()` or `%` formatting (Python 3.6+)

### Data Structures
- Use `defaultdict`, `Counter`, `namedtuple` / `dataclass` from stdlib instead of manual equivalents
- Replace manual class boilerplate with `@dataclass` (Python 3.7+)
- Use `pathlib.Path` instead of `os.path` string manipulation
- Use tuple unpacking: `a, b = b, a` instead of temp variables

### Control Flow
- Use guard clauses (early return) to reduce nesting
- Replace `if/elif/elif` chains on a single value with `match/case` (Python 3.10+) or dict dispatch
- Use `contextmanager` for setup/teardown patterns instead of try/finally
- Replace bare `except:` with `except Exception:` at minimum
- Use `else` clause on `for`/`while` loops only when it genuinely clarifies intent (often it's confusing -- remove if so)

### Functions
- Use `*args` and `**kwargs` only when truly needed, not as lazy parameter passing
- Replace mutable default arguments (`def f(x=[])`) with `None` + initialization
- Use `functools.lru_cache` / `cache` for pure function memoization instead of manual caches
- Remove unnecessary `pass` in non-empty blocks
- Use keyword-only arguments (`*,`) to prevent positional misuse

### Imports
- Use absolute imports over relative imports
- Sort imports: stdlib, third-party, local (follow `isort` conventions)
- Remove unused imports
- Import specific names (`from x import y`) rather than entire modules when only one or two names are used

### Type Hints
- Add type hints to function signatures when they clarify intent
- Use `X | Y` union syntax (Python 3.10+) over `Union[X, Y]`
- Use `list[str]` (Python 3.9+) over `List[str]`
