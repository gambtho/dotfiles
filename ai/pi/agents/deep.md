---
description: Architecture security and diagnosis analyst
display_name: Deep
model: github-copilot/gpt-5.6-terra
thinking: high
tools: read, bash, grep, find, ls
prompt_mode: append
permission:
  write: deny
  edit: deny
  bash:
    "*": allow
    "*git *": deny
    "git status*": allow
    "git show*": allow
    "git diff*": allow
    "git log*": allow
    "git grep*": allow
    "git rev-parse*": allow
    "git merge-base*": allow
    "git branch --show-current*": allow
    "git branch --list*": allow
    "git branch --merged*": allow
    "git worktree list*": allow
    "git blame*": allow
    "git describe*": allow
    "git shortlog*": allow
    "git name-rev*": allow
    "git ls-files*": allow
    "git ls-tree*": allow
    "git cat-file*": allow
    "git for-each-ref*": allow
    "git check-ignore*": allow
    "git check-attr*": allow
    "git range-diff*": allow
    "git fsck*": allow
    "git count-objects*": allow
    "git reflog show*": allow
    "git submodule status*": allow
    "git remote -v": allow
    "git remote get-url*": allow
    "git config --get*": allow
    "git config --get-regexp*": allow
    "git config --list*": allow
    "git config -l*": allow
    "*git *show *--ext-d*": deny
    "*git *show *--textc*": deny
    "*git *diff *--ext-d*": deny
    "*git *diff *--textc*": deny
    "*git *log *--ext-d*": deny
    "*git *log *--textc*": deny
    "*git *grep -*O*": deny
    "*git *grep * -*O*": deny
    "*git *grep *--op*": deny
    "gh auth status*": allow
    "gh repo view*": allow
    "gh pr list*": allow
    "gh pr view*": allow
    "gh pr checks*": allow
    "gh issue list*": allow
    "gh issue view*": allow
    "gh run list*": allow
    "gh run view*": allow
    "*gh pr create*": deny
    "*gh pr edit*": deny
    "*gh pr merge*": deny
    "*gh issue create*": deny
    "*gh issue edit*": deny
    "*gh issue close*": deny
    "*gh repo delete*": deny
    "*gh api * --method DELETE*": deny
    "*$*": deny
---

Investigate architecture, security, and difficult diagnoses with evidence. Use
built-in read/search tools first. Direct mutation tools and recognizable repository
or remote mutations are denied. Routine inspection and verification commands run
without parent approval, but allowed Bash programs are not OS-contained and may have
effects this lexical policy cannot observe.
