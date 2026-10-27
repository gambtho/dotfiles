# my — personal Pi package

Personal prompt templates and skills loaded directly from this dotfiles repository.

## Prompt templates

- `/fix-pr` — collect unresolved PR feedback and failing CI, then write an implementation plan.
- `/polish` — review the diff and project-specific expectations; use `--fix` for high-confidence cleanups.
- `/polish-pr` — run the conservative polish workflow in an isolated PR worktree.
- `/review-prs` — batch-review open PRs and retain repository-specific learnings.
- `/second-opinion` — ask a different GitHub Copilot model to review a spec or plan against the repository.

## Skills

- `blindspot-pass` — pre-implementation risk and uncertainty pass.
- `change-explainer` — reviewer-facing explanation of a completed change.
- `cli-ergonomics` — evidence-backed CLI audits and command design, with help, errors, output and scripting checks.
- `implementation-plan` — evidence-based implementation planning.
- `improve` — holistic codebase audit with ranked findings.
- `jekyll-media-gallery` — Jekyll media-gallery workflow.
- `overnight-improve` — iterative improvement loop using Pi Ralph tooling.
- `pr-closeout` — drive a PR to merge-ready in any repo: conflicts, CI (with flake discipline), review threads (bots answered, human replies follow project authority), project review profiles, size check.
- `polish-core` — shared diff review, maintainer checklist, project profiles, and conservative auto-fix engine.
- `product-owner` — project-specific product strategy conversation and outcome-focused feature briefs.

## Project-aware polish

Every `/polish` review includes a small maintainer checklist: one change per PR,
compatibility notes, specific error assertions, behavioral docs, and stable
contracts. It also reads every existing profile in this order:

1. `.agents/review.md` in the repository
2. `~/.pi/pr-reviews/{OWNER}/{REPO}/review.md`
3. `~/.pi/pr-reviews/{OWNER}/{REPO}/learnings.md` from `/review-prs`

For fork branches, OWNER/REPO identifies the PR's base repository; without PR
metadata, `upstream` takes precedence over `origin`. Local overlays use verified
GitHub identities only; other hosts still get repository-owned profiles and the
built-in checklist. Loaded sources are printed.
One fresh read-oriented whole-change reviewer checks profiles, correctness, silent failures and relevant language/type concerns together, in both standalone polish and closeout. Extra specialists require a named risk uncovered by that review or an explicit request; repository-required review methods still take precedence. Closeout reuses matching base/scope/profile/working-content review evidence (HEAD is provenance) rather than dispatching another automatic pass.
The **Project review** report groups findings by source and checklist item;
these findings are never auto-fixed, even with `--fix`. `/polish-pr` carries them
into its deferred summary and preserves the worktree when project coverage is
incomplete rather than claiming a clean review.

Polish reports how many commits the branch is behind the default branch. If the
branch is behind and a profile requests testing against that branch, polish runs
the profile's test command (or the repository's documented suite command) on a
temporary merge in a disposable
worktree. Conflicts and test failures are reported as `branch-stale`; unavailable
refs, blocked commands, and missing test instructions are reported explicitly.
The reviewed worktree is never merged, rebased, or reset, and polish never pushes.

The shared [project-review contract](skills/pr-closeout/references/project-review-contract.md)
defines profile aliases and reusable evidence. Polish loads only its Review evidence
section. Only the coordinator reads the separate maintenance reference and writes
profiles, committing/pushing with plain Git while retaining existing private-store
sync. Closeout, standalone polish and batch reviewers return candidates; without a
coordinator they hand them to the human to designate one. Private aliases redirect
lookup without moving evidence. Tracked guidance and public posts need separate
authority. Independent P1 findings get disposition/verification records before merge;
closeout posts where authorized, otherwise supplies a draft for the human.

## Installation

From the dotfiles root:

```bash
make ai
```

`ai/pi/settings.json` loads this directory as a local Pi package. Edits take effect after `/reload` or in the next Pi session; no package publication or marketplace registration is needed.
