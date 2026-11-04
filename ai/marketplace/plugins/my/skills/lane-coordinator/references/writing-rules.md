# Writing rules

For PR titles and bodies, GitHub issues, comments and reviews, commit messages, and chat
messages written in the user's voice. Follow the project's AGENTS.md and
COORDINATION.md for confirmed preferences and flagged phrases. Look for per-person
tone in PEOPLE.md, falling back to the people section in COORDINATION.md.

For PR bodies, review comments/replies and issues, load
[pr-text](../../pr-text/SKILL.md) for shared voice, shape and the read-back check.

## Chat and commit voice

These defaults remain for chat and commit messages; repository conventions win.
- Short sentences, plain words. Lead with the point. Stop when it's made.
- Draft the shortest version first; offer a longer one only if something is missing.
  Team-chat messages are two to four sentences, shorter than GitHub comments.
- Keep stated uncertainty ("didn't run live e2e") rather than smoothing it away.
- No stock AI phrasing: "great question", "delve", "leverage", "it's worth noting",
  "happy to", "is the right shape", "holds up", plus the user's flagged phrases.
- Non-native readers get simpler words. Senior readers get offers and questions
  ("let me know when…", "or if you want me to…"), not instructions.
- No emoji unless the user uses them there.

## Publishing

- PR bodies and other public posts follow the project's authority table in
  COORDINATION.md, including actor, destination and limits. Lanes write short PR bodies
  and open PRs directly where authorized; do not invent a draft-only requirement.
- Without permission in the authority table, show the exact text and destination;
  post only after the user approves that text. Changed text or destination needs a new OK.
- Implementation approval, passing CI, or "go ahead and contribute" aren't approval to post.
- Follow each repo's contribution policy (DCO, AI disclosure, who replies to reviews).
  If it conflicts with the user's preference, ask.

## Privacy

Never name customers, private events or internal projects in public repos, including
labels, milestones, branches and commit messages. No lane numbers or local paths in
public text. Don't publish local coordination files or transcripts.
