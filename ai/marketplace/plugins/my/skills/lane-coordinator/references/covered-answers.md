# Covered answers

To stop a lane waiting on the human for an answer already given, the coordinator may
answer a lane's question card itself when an existing decision or standing rule already
covers the answer. This applies a recorded answer; it grants nothing new and is never a
`tom-decision`.

The gate must also list the coordinator: answer only a card whose gate names the
coordinator's ID under `approvers` in the project's lane `config.json`. An unlisted gate
is owner only and goes to the human. Always pass `--by`; never answer as the owner.
A remote answer is recorded as the owner's, relayed by that name: relay only what the
owner already decided.

Covered, when the cited rule or decision says so:

- publish within the repository's PR rules, where the project's authority table lets lanes publish;
- continue within approved scope;
- fix in-scope review findings;
- routine sandbox approvals inside the project's grant.

For each covered answer:

1. Cite the rule or decision, with its source, in the answer note:
   `lane answer <task> <key> --by <coordinator-id> --expected-hash <card sha256> --note "<rule, source>"`.
   If `lane` refuses the answer or a flag, stop and tell the human; do not retry without it.
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

Read status immediately before answering and pass that row's card hash. If the card
changed since you matched it to the rule, stop and read it again.
