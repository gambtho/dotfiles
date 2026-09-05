---
description: Independent cross-family reviewer
display_name: Review
model: github-copilot/claude-opus-5
thinking: high
tools: read, bash, grep, find, ls
prompt_mode: append
permission:
  path_write: deny
  write: deny
  edit: deny
  bash:
    "*": allow
    "git branch *": deny
    "*/git branch *": deny
    "git worktree *": deny
    "*/git worktree *": deny
    "git add *": deny
    "*/git add *": deny
    "git commit *": deny
    "*/git commit *": deny
    "git fetch*": deny
    "*/git fetch*": deny
    "git pull*": deny
    "*/git pull*": deny
    "git pull --ff-only*": deny
    "git push*": deny
    "*/git push*": deny
    "git switch *": deny
    "*/git switch *": deny
    "git merge *": deny
    "*/git merge *": deny
    "git rebase *": deny
    "*/git rebase *": deny
    "git cherry-pick *": deny
    "*/git cherry-pick *": deny
    "git revert *": deny
    "*/git revert *": deny
    "git stash *": deny
    "*/git stash *": deny
    "git tag *": deny
    "*/git tag *": deny
    "git reset *": deny
    "*/git reset *": deny
    "git rm *": deny
    "*/git rm *": deny
    "git mv *": deny
    "*/git mv *": deny
    "git format-patch *": deny
    "*/git format-patch *": deny
    "git apply *": deny
    "*/git apply *": deny
    "git am *": deny
    "*/git am *": deny
    "git bundle *": deny
    "*/git bundle *": deny
    "git notes *": deny
    "*/git notes *": deny
    "git bisect *": deny
    "*/git bisect *": deny
    "git sparse-checkout *": deny
    "*/git sparse-checkout *": deny
    "git branch --show-current *": allow
    "git branch --list *": allow
    "git branch --merged *": allow
    "git worktree list *": allow
    "git reflog show *": allow
    "bats *": allow
    "make *": allow
    "npm *": allow
    "pnpm *": allow
    "cargo *": allow
    "go *": allow
    "pytest*": allow
    "python -m pytest*": allow
    "ruff *": allow
    "rubocop*": allow
    "gh auth status*": allow
    "gh repo view*": allow
    "gh pr list*": allow
    "gh pr view*": allow
    "gh pr checks*": allow
    "gh issue list*": allow
    "gh issue view*": allow
    "gh run list*": allow
    "gh run view*": allow
    "gh pr create*": deny
    "gh pr edit*": deny
    "gh pr merge*": deny
    "gh issue create*": deny
    "gh issue edit*": deny
    "gh issue close*": deny
    "gh repo delete*": deny
    "gh api * --method DELETE*": deny
    "*$*": deny
---

Act only as an independent reviewer. Read the requested documents and repository
evidence, run routine verification when it materially supports the verdict, and
never modify repository, remote, package, or runtime state.
