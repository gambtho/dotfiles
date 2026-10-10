# <Project> coordination

Local directory: <absolute path outside repositories>
Registry owner: <single coordinator session identifier/path, if known>
Last updated: <actual observation time>

This file is authoritative local coordination state. Read and update it; do not
replace settled decisions on setup/resume. Lanes write only assigned reports/handoffs.
Resolve competing coordinators before numbering or changing shared records.

## Repositories and people

| Repo | Primary checkout | Default branch | Target/base policy | Owners/reviewers |
|------|------------------|----------------|--------------------|-----------------|
| <owner/repo> | <path> | <verified or unknown> | <policy> | <handles/areas> |

Merge/contribution policy: <user merges; required reviews, strategy, DCO, AI disclosure>
Shared rules file: <path, or none>

## Standing rules

- Coordinator does not implement product code or delegate implementation.
- User manually starts/resumes lanes, each with a distinct linked worktree/branch per repo.
- Never push to default/protected branches. Never merge; the user merges.
- No force pushes without explicit approval. Do not mutate another lane's branch/PR.
- Non-trivial work: design/audit approval first, unless scope is already approved.
- Implementation approval, push permission, and exact outward-text approval are separate.
- Creating/editing PRs, comments, reviews, and replies needs exact-draft/destination approval.
- One PR at a time per lane; blocked/failing/pending are valid reporting states.
- No secrets in logs/argv; no private names or lane identifiers in public text.
- Generated workflow artifacts stay local, outside Git, unless explicitly authorized for versioning.
- No automatic monitoring or reminders are promised.

## Lanes

| Lane / prompt | Repo | Session identifier/path | Worktree / branch | Base ref / SHA | State | Waiting on |
|---------------|------|-------------------------|-------------------|----------------|-------|------------|
| <Wn/path> | <repo> | <known or unresolved> | <path/branch> | <ref/SHA> | <planned/active/blocked/paused/closed> | <who/what> |

## Latest observations

| Lane | Local HEAD | PR URL / head SHA | PR state | CI state / required checks known? | Verified at | Report / handoff |
|------|------------|-------------------|----------|-----------------------------------|-------------|------------------|
| <Wn> | <SHA/unknown> | <URL/SHA/not opened> | <state> | <passing/failing/pending/not configured/unknown; yes/no> | <time> | <paths> |

Observations are revision-specific, not current guarantees. Reverify on return.

## Decisions and approvals

| When | Decision / exact approved action and destination | Scope / revision / draft reference | User approval evidence |
|------|-------------------------------------------------|------------------------------------|------------------------|
| <time> | <decision> | <scope; exact local draft if publication> | <session/message reference or quoted approval> |

Missing or ambiguous approval is not authorization. Keep exact approved drafts
locally; a changed draft or destination requires fresh approval.

## Writing preferences and privacy

<Confirmed voice preferences, flagged phrases, disclosure/privacy rules; unknowns labelled>

## Waiting on

- <owner: decision/action; affected lane; next check-in, not a scheduled reminder>
