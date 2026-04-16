# overnight-improve config schema

The skill reads `.claude/overnight-config.yaml` from the repo root. All fields are required unless marked optional.

## Schema

```yaml
improve_skill: my:improve          # required — fully-qualified skill name to invoke each iteration
max_iterations: 15                 # required — total iterations before PHASE 2 wrap-up fires
max_wrap_iterations: 3             # required — max CodeRabbit autofix rounds in PHASE 2
branch_prefix: overnight-improvements  # required — the loop creates branch `<prefix>-YYYY-MM-DD`

gates:                             # required — ordered list of gates that must exit 0 to commit
  - name: <human-readable label>   # required — used in state file logs
    command: <bash command>        # required — run from repo root via `bash -c`

do_nots:                           # optional — appended to per-iteration prompt as constraints
  - <one-line constraint>
```

## Example: Go + React project

```yaml
improve_skill: my:improve
max_iterations: 15
max_wrap_iterations: 3
branch_prefix: overnight-improvements
gates:
  - name: make check
    command: make check
  - name: go tests
    command: go test -race -timeout 10m ./...
  - name: web lint
    command: cd web && npm run lint:strict
  - name: web typecheck
    command: cd web && npm run typecheck
  - name: web tests
    command: cd web && npm test
do_nots:
  - "Do not mock the database in integration tests."
  - "Do not split cmd/<app>/main.go (accepted tech debt)."
```

## Example: Python project

```yaml
improve_skill: my:improve
max_iterations: 10
max_wrap_iterations: 3
branch_prefix: overnight-improvements
gates:
  - name: ruff
    command: ruff check .
  - name: mypy
    command: mypy src/
  - name: pytest
    command: pytest -x --timeout=60
do_nots:
  - "Do not edit migrations under alembic/versions/."
```

## Notes

- `gates` run sequentially in the order listed; the loop fails on the first non-zero exit.
- Use absolute paths or `cd` prefixes when a gate runs in a subdirectory (e.g. `cd web && npm test`).
- `do_nots` are appended verbatim to the per-iteration prompt; phrase them as imperative sentences.
- The loop creates `.claude/overnight-run-state.md` automatically; ensure `.claude/` is in `.gitignore` (or commit the state file as an audit trail — your call).
