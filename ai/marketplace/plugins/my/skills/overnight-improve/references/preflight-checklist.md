# Preflight checklist

Run these before kicking off the loop. If any check fails, fix it or abort — do not start the loop on a broken baseline.

## 0. Verify session is in bypass-permissions mode

The skill body checks this; the runtime check is also visible in the startup banner or `/status`. If the session is in plan mode (the default), the loop will stall on the first Bash call. Exit and relaunch with:

```bash
claude --permission-mode bypassPermissions
# equivalent: claude --dangerously-skip-permissions
```

## 1. Verify main is clean and up to date

```bash
git status                                    # must be clean
git fetch origin && git log HEAD..origin/main # must be empty
```

## 2. Create the overnight branch

```bash
BRANCH_PREFIX=$(awk '/^branch_prefix:/ {print $2}' .claude/overnight-config.yaml)
git checkout -b "${BRANCH_PREFIX}-$(date +%Y-%m-%d)"
```

## 3. Seed the state file

```bash
mkdir -p .claude
MAX_ITER=$(awk '/^max_iterations:/ {print $2}' .claude/overnight-config.yaml)
MAX_WRAP=$(awk '/^max_wrap_iterations:/ {print $2}' .claude/overnight-config.yaml)
BRANCH=$(git branch --show-current)

cat > .claude/overnight-run-state.md <<EOF
---
started: $(date -u +%Y-%m-%dT%H:%M:%SZ)
branch: ${BRANCH}
max_iterations: ${MAX_ITER}
iteration: 0
max_wrap_iterations: ${MAX_WRAP}
---

== Attempted findings ==
(none yet)

== Wrap-up ==
(pending)
EOF
```

## 4. Verify all gates pass on baseline

Read each gate from `.claude/overnight-config.yaml` and run it. ALL must exit 0 before the loop starts. If any fails, fix the underlying problem on `main` (or abort) — never start the loop on a broken baseline.

## 5. Recommended: do a 2-iteration dry run first

Before committing a whole night to the loop, do a small dry run:

```bash
# In the skill, this means invoking ralph-loop with --max-iterations 2 instead of the configured value.
```

After the dry run, verify all 4:
1. Iteration 1 produced a commit that passes gates.
2. The state file got updated correctly (one `succeeded: <sha>` entry, `iteration: 2` after the second fire).
3. Iteration 2 saw iteration 1's fix in the tree (didn't re-flag the same finding).
4. `git status` ended clean after each iteration.

**Caveat:** PHASE 2 fires when `iteration == max_iterations` *as written in the state file* (the configured value, e.g. 15), not the `--max-iterations` CLI flag. So a 2-iter dry run normally won't push or open a PR — UNLESS both iterations exhaust eligible findings, which triggers PHASE 2 via the no-findings path. To dry-run with zero PR risk, delete the seeded state file before each dry run.
