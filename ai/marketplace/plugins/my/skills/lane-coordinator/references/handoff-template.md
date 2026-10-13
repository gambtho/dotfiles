# W<n> handoff

Written by the lane before it closes or pauses for long, under the project folder
(`~/<project>-local/…`), never `/tmp`. Local only; never commit it.

- Repo / worktree / branch: <owner/repo>, <path>, <branch>
- Base and HEAD: <base ref and SHA>, <local HEAD>; pushed? <yes/no>
- PRs: <number, state, head SHA, CI on that head>
- Done: <what landed or is ready>
- Not done: <remaining scope, uncommitted or unpushed work and where it is>
- Decisions and approvals so far: <what the user approved, with dates>
- Next step: <the first thing a resumed lane should do>
- Gotchas: <hooks, flaky checks, files other PRs touch, anything surprising>

On resume, re-check git and GitHub state before trusting any of this.
