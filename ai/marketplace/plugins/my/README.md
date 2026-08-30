# my — personal Pi package

Personal prompt templates and skills loaded directly from this dotfiles repository.

## Prompt templates

- `/fix-pr` — collect unresolved PR feedback and failing CI, then write an implementation plan.
- `/polish` — apply high-confidence cleanups through `polish-core` and report the rest.
- `/polish-pr` — run the conservative polish workflow in an isolated PR worktree.
- `/review-prs` — batch-review open PRs and retain repository-specific learnings.
- `/second-opinion` — ask a different GitHub Copilot model to review a spec or plan against the repository.

## Skills

- `blindspot-pass` — pre-implementation risk and uncertainty pass.
- `change-explainer` — reviewer-facing explanation of a completed change.
- `implementation-plan` — evidence-based implementation planning.
- `improve` — holistic codebase audit with ranked findings.
- `jekyll-media-gallery` — Jekyll media-gallery workflow.
- `overnight-improve` — iterative improvement loop using Pi Ralph tooling.
- `polish-core` — shared review and conservative auto-fix engine.

## Installation

From the dotfiles root:

```bash
make ai
```

`ai/pi/settings.json` loads this directory as a local Pi package. Edits take effect after `/reload` or in the next Pi session; no package publication or marketplace registration is needed.
