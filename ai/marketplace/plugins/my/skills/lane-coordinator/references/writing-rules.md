# Outward writing rules

Applies to PR titles/bodies, GitHub issues/comments/reviews/replies, commit messages,
and messages written in the user's voice. Read confirmed writing preferences and
privacy rules in the local COORDINATION.md; update that record when the user settles
new preferences. Do not claim to remember preferences absent from available records.

## Voice

- Concise, informal, plain words and short sentences.
- Remove filler and stock AI phrases: “great question”, “delve”, “leverage”,
  “it's worth noting”, “happy to”, and the user's recorded flagged phrases.
- No emoji unless the user uses them in that channel.
- Be direct without hiding uncertainty: “not verified”, “unknown”, and “observed
  at SHA …” are useful facts, not hedging. Label inference and review limitations.

## Publication gate

1. Show the exact proposed action, destination, and title/body/text in a code block.
2. Publish only after the user approves that exact draft for that destination/action.
   This includes creating/editing PRs and posting comments, reviews, or replies.
3. Changed text, destination, or action requires fresh approval. Record approved
   drafts and approval evidence locally. If approval is ambiguous or missing, stop.

Implementation approval is not push permission or publication approval. A lane's
“ready” report, passing CI, permission to contribute, or skill invocation grants none
of these. Push needs separate permission for the remote/branch. Never push to
protected/default branches. Never merge; the user merges. No force push without
explicit approval. Lanes must carry these same gates in their prompts.

## PR body shape

```markdown
<Problem or change in 1–2 sentences.>

- <meaningful change>

## Compatibility
<Breaking changes/migration, or accurate compatibility note.>

## Tests
<Actual commands/results and limits; distinguish lane evidence from checks personally run.>

<Fixes #N or Refs #N only for a verified relevant issue.>
```

Follow repository contribution policy, including DCO, AI disclosure, and who replies
to reviews. Ask when policy conflicts with user preferences. Preserve bot-generated
blocks when editing existing bodies. Do not invent tests or compatibility claims.

## Privacy

No secrets in logs or command-line arguments. Never name customers, private events
or internal projects in public repos, including issues, labels, milestones, commits,
branches, and PR text. No lane numbers or internal coordination names in public text.
Do not publish local coordination files, private transcripts, or handoffs by default.
