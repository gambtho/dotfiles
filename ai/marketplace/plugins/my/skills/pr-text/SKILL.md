---
name: pr-text
description: Use when drafting or editing PR bodies, review comments, review replies or GitHub issues, especially when text sounds like a report, commit log or generated summary.
---

# PR text

Write for a teammate who has not read the author's report. Give them the change,
its consequence and what they need to act on, not a narration of the work.

## Before drafting

Read the repository template and contribution policy, then the project's writing
preferences and publication authority. Those rules win over these defaults.
Follow DCO, AI disclosure and any prohibition on co-author lines. This skill
grants no permission to post, assign issues, approve reviews or resolve threads.
Keep bot-generated blocks when editing an existing body.

## Shared voice

- Use plain sentences, one idea each, with natural contractions. Lead with the point.
  Start with the shortest draft that conveys the needed facts. Keep PR titles factual
  and concise, using the repository's title convention. No emoji unless the user uses
  them in that context.
- Describe the change, not the author. In PR bodies, never open with “I” or write
  “I added”; “I” is for verification performed, such as “I ran the reload tests.”
  In replies, use “I” for the author's actions. Under a person's account, never
  speak as “we” or refer to the account holder in the third person.
- Name internal mechanisms only when they help the reader. Skip formula openers
  such as “you can now”, canned praise, ceremonial thanks and inflated adjectives.
  Cut stock phrases: “ensure robustness”, “enhance maintainability”, “it's worth
  noting”, “great work overall” and “happy to”.
- State uncertainty as a fact: “The live suite wasn't run.” Don't soften a
  confirmed bug into speculation, or turn an uncertain concern into a fact.
- Keep routine process out: no audit labels, coordination vocabulary, review steps,
  “CI pending”, “I kept this as one slice” or unexplained report words such as
  “receipt”, “qualification”, “identity” and “closure”.
- Include hashes, counts or detailed evidence only when needed to understand or act
  on the change. Put the rest in the private report, not a compressed evidence line.

Required disposition records are separate from routine body/reply prose. When
another workflow requires an authorized public record, preserve its labels, hashes
and verification facts; this includes closeout's P1 record. Do not strip required
records to satisfy these voice defaults or infer permission to publish them.

## PR bodies

Default to three to six short paragraphs of plain sentences, not a ten-line cap.
Don't pad a small change to reach a count. Repository templates and explicit local
shape preferences still win.

1. Open with what changed and why it matters, in a sentence or two.
2. Explain meaningful behavior and compatibility or upgrade effects. Mention only
   limits a reader could otherwise misunderstand. A short list is useful for
   distinct limits; say what a person would see, and merge items with the same result.
3. Optionally add a “worth a close look” paragraph: what only the author knows about
   uncertainty, irreversible behavior or material safe to skim. Omit empty review prompts.
4. Say what checks actually ran and their results in a line or two. Include relevant
   live-run limits, not routine execution locations or tool workarounds.

Avoid slash lists, “X is not claimed” lists, labelled evidence blocks and restating
review requests already sent by GitHub. Give size one plain sentence only when the
PR exceeds the applicable limit. Use `Refs #N` for partial work; `Fixes #N` only when
it finishes the issue. For one item in a larger issue, name the item and use Refs.

Read back before posting: would a teammate reading only this know what changed,
why, and what to watch for? If it reads like a report or commit log, rewrite it.

### Good body — invented example

> Reloading a malformed settings file now leaves the last valid settings active,
> so a typo no longer interrupts a running session.
>
> Startup still fails when there is no valid settings file. Existing sessions keep
> their current credentials until a valid reload; that behavior deserves a close look.
>
> The reload and startup unit tests passed. The live desktop flow wasn't run.

### Bad, then fixed — invented example

Bad: “I added cache identity/closure; 14 files, P1 clear, CI pending.
Qualification receipt: unit 31/31. Eviction not claimed.”

Fixed:

> Cached search results now expire after five minutes, so reopened searches don't
> keep showing old results.
>
> Already open results stay unchanged until the next search.
>
> The cache-expiry unit test passed. The browser flow wasn't run.

## Review comments and replies

- Default to 1–3 short sentences: concrete problem, consequence and a direct
  question or request. Longer is useful for a tricky bug, not a review summary.
- Add only useful, non-duplicate feedback. Don't summarize the author's change,
  state the obvious or repeat a verification caveat already clear in the body.
- For a reply, answer the point first, then give the fix or reason it stands and
  the relevant verification. Mention what was checked only when it adds confidence
  the reader cannot already see. No canned praise or repeated status summaries.
- Use questions for proposals and respect recipient-specific tone; a confirmed bug
  still needs a direct statement of what breaks.
- When an approval is authorized, leave its body empty. Put a line nit on that line,
  not in the review body, and keep it to one sentence.

## Issues

Follow the repository's issue template. Give exact versions, reproducible steps,
expected and actual behavior, and relevant evidence in its fields. Pin source links
to the version or commit observed, not a moving branch. Never invent versions, links,
logs or verification; state missing evidence briefly when it affects the report.

When authorized to announce taking an issue, the entire comment is “Picking this up.”
That wording does not authorize assignment or posting, or override project-specific
exceptions. Don't tick boxes on someone else's issue. Apply the same Refs/Fixes
completion rule when linking work to an issue.
