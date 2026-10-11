# Writing rules

For PR titles and bodies, GitHub issues, comments and reviews, commit messages, and chat
messages written in the user's voice. COORDINATION.md records the user's confirmed
preferences, flagged phrases and per-person tone; follow those first.

## Voice

- Short sentences, plain words. Lead with the point. Stop when it's made.
- No stock AI phrasing: "great question", "delve", "leverage", "it's worth noting",
  "happy to", "is the right shape", "holds up", plus the user's flagged phrases.
- Chat messages are shorter than GitHub comments. Non-native readers get simpler words.
- Senior readers get offers and questions ("let me know when…", "or if you want me to…"),
  not instructions.
- Uncertainty stated as a fact is fine ("not verified", "I didn't run the live suite").
- No emoji unless the user uses them there.

## Publishing

- Show the exact text and where it goes. Post only after the user approves that text.
- Changed text or destination needs a new OK. Standing grants in COORDINATION.md are the
  only exception.
- Implementation approval, passing CI, or "go ahead and contribute" aren't approval to post.
- Follow each repo's contribution policy (DCO, AI disclosure, who replies to reviews).
  If it conflicts with the user's preference, ask.

## PR body shape

```markdown
<What changes and why, 1–3 sentences.>

- <meaningful change>

<Compatibility or upgrade note, if any.>

Verification: <checks actually run and their results; say what wasn't run.>

<Fixes #N / Refs #N>
```

Keep bot-generated blocks when editing a body. No process notes ("held files",
"approved exception", "polish found") in public text.

## Privacy

Never name customers, private events or internal projects in public repos, including
labels, milestones, branches and commit messages. No lane numbers or local paths in
public text. Don't publish local coordination files or transcripts.
