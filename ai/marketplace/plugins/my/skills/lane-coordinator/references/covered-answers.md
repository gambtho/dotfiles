# Covered answers

To stop a lane waiting on the human for an answer already given, the coordinator may
answer a lane's question card itself when an existing decision or standing rule already
covers the answer. This applies a recorded answer; it grants nothing new and is never a
`tom-decision`.

Covered, when the cited rule or decision says so:

- publish within the repository's PR rules, where the project's authority table lets lanes publish;
- continue within approved scope;
- fix in-scope review findings;
- routine sandbox approvals inside the project's grant.

For each covered answer:

1. Cite the rule or decision, with its source, in the answer note.
2. Log the card, answer and cited rule in STATE.
3. Tell the human in one line.

The human always answers:

- design approvals;
- merges, deploys and live cloud changes;
- deletions beyond the cleanup rule;
- text addressed to people;
- scope or cost changes;
- credentials and sign-ins.

Anything unclear goes to the human: no publication grant, a rule that only nearly fits, an inferred decision,
or a card that mixes a covered part with one of the items above. Tool-permission, trust
and sign-in dialogs are not question cards; nobody answers them through the lane API.

For a `Worker: lane` host, refresh the card first: see
[developerlanes worker](remote-lanes.md#developerlanes-worker-opt-in).
