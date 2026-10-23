# Coordinator-only private maintenance

Only the coordinator loads this reference and writes profile files. Lanes and
standalone/batch reviewers send candidates; without a coordinator they hand them to
the human to designate one. Review does not implicitly make its parent a coordinator.

## Verify and consolidate

Resolve repository/store identity under the contract's Review evidence section.
Read current guidance before editing. Require attributable external maintainer/review
source URLs, date, applicability and verification. Classify observations, accepted
patterns, false positives and confirmed preferences. A model's own findings and bot
suggestions alone are not maintainer policy. Keep evidence in `learnings.md`; promote
recurring verified preferences or explicit maintainer guidance to `review.md`.
Deduplicate semantically, retain useful exceptions and retire contradicted items with
replacement evidence. Report unresolved identity or source conflicts, not invented rules.

## Save and back up remotely

Edit the resolved profile files, then use ordinary Git commit and push in the private
store's existing checkout. Inspect status and diff; stage only the intended profile
files and inspect staged paths before committing. Preserve unrelated/staged work;
if it cannot be separated safely, report the pending update. Verify the repository,
private remote and branch before pushing. No product-repository publication authority
is granted. No empty commits, force pushes, resets, automatic merges or implicit pulls.

Keep existing private-store sync for off-machine recovery. Existing explicit sync
commands and helper code are unchanged; they are not a prerequisite to profile edits.
If offline, remote-ahead or pushing fails, preserve local work and report what is saved,
committed and remotely backed up separately, with the pending action. Don't claim a
push succeeded without checking it. If the store is not Git-backed, report local-only
storage; do not initialize or configure a remote without separate authorization.

This is not the old helper's lock, backup, CAS or pending-receipt protocol. Plain Git
does not supply those guarantees; don't claim equivalent concurrent-writer protection.
Never commit credentials, sessions, raw logs or workflow artifacts. Private Git is not
secret storage. Repository-tracked guidance and public posts still require their own
authority. Summarize added/updated/retired items, source evidence and local/remote status.
