---
description: Independent cross-family reviewer
display_name: Review
model: github-copilot/claude-opus-5
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
    "git -C ?* status*": allow
    "git -C ?* show*": allow
    "git -C ?* diff*": allow
    "git -C ?* log*": allow
    "git -C ?* grep*": allow
    "git -C ?* rev-parse*": allow
    "git -C ?* merge-base*": allow
    "git -C ?* branch --show-current*": allow
    "git -C ?* branch --list*": allow
    "git -C ?* branch --merged*": allow
    "git -C ?* worktree list*": allow
    "git -C ?* blame*": allow
    "git -C ?* describe*": allow
    "git -C ?* shortlog*": allow
    "git -C ?* name-rev*": allow
    "git -C ?* ls-files*": allow
    "git -C ?* ls-tree*": allow
    "git -C ?* cat-file*": allow
    "git -C ?* for-each-ref*": allow
    "git -C ?* check-ignore*": allow
    "git -C ?* check-attr*": allow
    "git -C ?* range-diff*": allow
    "git -C ?* fsck*": allow
    "git -C ?* count-objects*": allow
    "git -C ?* reflog show*": allow
    "git -C ?* submodule status*": allow
    "git -C ?* remote -v": allow
    "git -C ?* remote get-url*": allow
    "git -C ?* config --get*": allow
    "git -C ?* config --get-regexp*": allow
    "git -C ?* config --list*": allow
    "git -C ?* config -l*": allow
    "git show *--ext-d*": deny
    "git show *--textc*": deny
    "git diff *--ext-d*": deny
    "git diff *--textc*": deny
    "git log *--ext-d*": deny
    "git log *--textc*": deny
    "git -C ?* show *--ext-d*": deny
    "git -C ?* show *--textc*": deny
    "git -C ?* diff *--ext-d*": deny
    "git -C ?* diff *--textc*": deny
    "git -C ?* log *--ext-d*": deny
    "git -C ?* log *--textc*": deny
    "*git *show *--ext-d*": deny
    "*git *show *--textc*": deny
    "*git *diff *--ext-d*": deny
    "*git *diff *--textc*": deny
    "*git *log *--ext-d*": deny
    "*git *log *--textc*": deny
    "git grep -O*": deny
    "git grep -nO*": deny
    "git grep -inO*": deny
    "git grep -nHO*": deny
    "git grep * -O*": deny
    "git grep * -nO*": deny
    "git grep * -inO*": deny
    "git grep * -nHO*": deny
    "git grep --open*": deny
    "git grep * --open*": deny
    "git grep --op=*": deny
    "git grep * --op=*": deny
    "git -C ?* grep -O*": deny
    "git -C ?* grep -nO*": deny
    "git -C ?* grep -inO*": deny
    "git -C ?* grep -nHO*": deny
    "git -C ?* grep * -O*": deny
    "git -C ?* grep * -nO*": deny
    "git -C ?* grep * -inO*": deny
    "git -C ?* grep * -nHO*": deny
    "git -C ?* grep --open*": deny
    "git -C ?* grep * --open*": deny
    "git -C ?* grep --op=*": deny
    "git -C ?* grep * --op=*": deny
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

Act only as an independent reviewer. Read the requested documents and repository
evidence, run routine verification when it materially supports the verdict. Use
built-in read/search tools first. Explicit rules deny selected repository and remote
mutations; other recognized risky operations follow the composed policy. Routine
inspection and verification commands run without parent approval, but allowed Bash
programs are not OS-contained and may have effects this lexical policy cannot observe.
