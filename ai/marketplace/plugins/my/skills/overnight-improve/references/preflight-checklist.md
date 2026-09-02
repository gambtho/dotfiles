# Preflight checklist

Run these before kicking off the loop. If any check fails, fix it or abort.

## 0. Verify unattended permission state

1. Open `/permission-system`, enable YOLO temporarily, and verify the status reports YOLO on. YOLO converts asks to allows but preserves explicit denies.
2. Review every configured gate before approving unattended execution. Parent and child commands are not OS-contained, so use only trusted code and reviewed commands.
3. Keep the worktree guard enabled. Child agents inherit permission-system and worktree-guard; limit their tools and prompts accordingly.
4. Exit plan mode before starting; plan mode intentionally blocks writes.

When the loop ends, return to `/permission-system`, disable YOLO, and verify the status reports YOLO off.

## 1. Verify the base branch

From the primary checkout:

```bash
git status                                    # must be clean
git fetch origin && git log HEAD..origin/main # must be empty
```

## 2. Create a linked worktree and overnight branch

Load and follow the `using-git-worktrees` skill. Read the configured prefix and create a new linked worktree rather than switching the primary checkout:

```bash
BRANCH_PREFIX=$(awk '/^branch_prefix:/ {print $2}' .pi/overnight-config.yaml)
BRANCH="${BRANCH_PREFIX}-$(date +%Y-%m-%d)"
# Choose the worktree path according to the using-git-worktrees skill.
git worktree add -b "$BRANCH" <worktree-path> main
```

Continue all remaining steps from `<worktree-path>`. Copy or create `.pi/overnight-config.yaml` there if it is intentionally untracked.

## 3. Seed the state file

```bash
mkdir -p .pi
MAX_ITER=$(awk '/^max_iterations:/ {print $2}' .pi/overnight-config.yaml)
MAX_WRAP=$(awk '/^max_wrap_iterations:/ {print $2}' .pi/overnight-config.yaml)
BRANCH=$(git branch --show-current)

cat > .pi/overnight-run-state.md <<EOF
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

## 4. Verify all gates

Read each gate from `.pi/overnight-config.yaml` and run it. Every gate must pass on the baseline before starting the loop. Run at least one representative build/test command through the configured permission layer, not only a read-only probe.

Treat any prompt timeout or permission deny as **blocked**. Record the blocked command, stop the preflight, and either revise the gate or ask the user whether the explicit policy should change; never claim the gate or unattended run succeeded.

## 5. Recommended dry run

Run two iterations with `ralph_start` before committing a whole night. Verify:

1. The first iteration produced a commit that passes the gates.
2. The state file recorded the commit and iteration counter.
3. The second iteration saw the first iteration's change and did not repeat it.
4. Each iteration ended with a clean worktree.

PHASE 2 uses `max_iterations` in the state file, not only the Ralph runtime limit. A two-iteration dry run normally will not open a PR, but exhausting eligible findings can still trigger wrap-up. For a zero-push dry run, use a test remote or temporarily configure a wrap-up constraint that forbids pushing.
