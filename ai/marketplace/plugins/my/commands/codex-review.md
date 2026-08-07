---
name: codex-review
description: Get a second opinion from Codex on a spec or implementation plan — reviews the doc you have been working on, against the actual code
argument-hint: "[path — defaults to the doc most recently discussed in this session] [--with-spec | --with-plan]"
allowed-tools: Bash(codex --version), Bash(codex exec:*), Bash(git rev-parse:*), Bash(git branch:*), Bash(git status:*), Bash(ls:*), Bash(test:*), Bash(bwrap --ro-bind / / --dev /dev true), Bash(sha256sum:*), Bash(mktemp:*), Bash(rm -rf /tmp/codex-review-*), Read, Write, Edit, Glob, Grep
---

# Codex Review — Second Opinion on a Spec or Plan

You are handing a design doc or implementation plan to Codex for an independent review, then bringing its findings back for the user to act on. Codex reads the repository itself, so it reviews the doc **against the actual code**, not just as prose.

**Default target**: the document this session has been working on. **One doc, reviewed on its own rubric** — reviewing a spec should never wait on a plan existing.

**Arguments**: $ARGUMENTS (all optional — a path, two paths, or `--with-spec` / `--with-plan`)

---

## Phase 0: Preflight

### 0a: Verify Codex Is Available

Run: `codex --version`

If it fails, print this and **STOP**:

```
ERROR: Codex CLI not found. Install it first (see ~/.dotfiles/ai/codex/install.sh).
```

### 0b: Never Prefix the `codex` Invocation

`codex` is a **zsh function**, not just a binary. It injects `-c openai_base_url=...` when the vekil proxy is running. Any wrapper that execs the binary directly — `timeout codex ...`, `env codex ...`, `xargs codex ...`, a `#!/bin/sh` script — bypasses the function and fails with `401 Unauthorized` against `api.openai.com`.

Call `codex` as the **first word** of the command. If you need a timeout, let the Bash tool's own `timeout` parameter handle it.

### 0c: Resolve the Repository Root

Run: `git rev-parse --show-toplevel` and store as `ROOT`. All paths below are relative to it, and `ROOT` is what gets passed to `codex -C`.

### 0d: Worktrees

This repo's workflow puts feature work in linked worktrees under `.claude/worktrees/<name>/`, so the spec and plan under review usually live in a worktree, not the main checkout. Passing `-C "$ROOT"` handles this — verified behavior when `ROOT` is a linked worktree:

- Codex resolves `git rev-parse --show-toplevel` to the **worktree** path and `git branch --show-current` to the **worktree's branch**, not `main`.
- Codex reads the **working tree**, including uncommitted files. You can review a plan before it is committed.
- Git works inside the worktree even under `--sandbox read-only`, despite `.git` being a file pointing into the main checkout's `.git/worktrees/`.

Two things follow:

1. **Never hardcode the main checkout.** Always derive `ROOT` from `git rev-parse --show-toplevel` in the session's current directory. A review run against the wrong tree reads stale docs and stale code, and every finding it produces is suspect.
2. **State which tree you reviewed.** If `ROOT` is under `.claude/worktrees/`, include the worktree name and branch in the Phase 1c confirmation, so the user can tell at a glance that Codex looked at the right copy.

To review a doc in a *different* worktree than the session's, pass its path explicitly and set `ROOT` to that worktree's root — not the session's. Reviewing a plan from tree A against the code in tree B is the one failure mode here that produces confidently wrong findings.

### 0e: Select the Sandbox Mode

Decide the sandbox **before** building the prompt. Codex's Linux sandbox is
bubblewrap, which needs an unprivileged user namespace; many containers forbid
`clone(CLONE_NEWUSER)`. Discovering that by running a full review wastes minutes
and tokens and returns nothing usable, so determine it up front.

**First, is this a container?** Run these exact checks and stop at the first hit:

1. `test -n "$REMOTE_CONTAINERS"` or `test -n "$CODESPACES"` — VS Code Dev
   Containers and Codespaces respectively. Checked first because they name a
   devcontainer specifically.
2. `test -f /.dockerenv` — Docker.
3. `test -f /run/.containerenv` — Podman.

Use those forms. `env | grep`, `printenv`, and `echo` are not covered by this
command's `Bash(test:*)` grant and stall an otherwise silent preflight on a
permission prompt.

A plain `docker run` also trips markers 2 and 3. That is correct: the same
namespace policy applies, so the same decision follows.

**If and only if it is a container, probe bubblewrap:**

```
bwrap --ro-bind / / --dev /dev true
```

This returns in milliseconds and costs no tokens. A missing `bwrap` binary counts as a failed probe, not an error. Codex bundles its own copy, so the system binary's absence tells you about the environment rather than blocking the run.

Set `SANDBOX_MODE`:

| Container | `bwrap` probe | `SANDBOX_MODE` |
|-----------|---------------|----------------|
| no        | not run       | `read-only` |
| yes       | exit 0        | `read-only` |
| yes       | non-zero or absent | `danger-full-access` |

Outside a container the probe never runs and `SANDBOX_MODE` is `read-only`.

The `{why}` in the Phase 1c confirmation names the row that fired, one string per
row, top to bottom: `no container`, `container detected; bwrap probe succeeded`,
`container detected; bwrap probe failed`. A run always prints one of the three.

Do **not** prompt before escalating. In a container the escalation is automatic
by design: the container is the external isolation boundary, which is the case
Codex's unsandboxed mode exists for. Announce the mode in Phase 1c so the choice
is visible, and run the Phase 2e integrity guard so a write cannot pass
unnoticed.

---

## Phase 1: Resolve the Target

**Default to one document.** Reviewing a spec early — before any plan exists — is the common case, not a degraded one. Do not go looking for a plan to pair with unless asked.

Docs usually live at `docs/superpowers/specs/{date}-{slug}-design.md` and `docs/superpowers/plans/{date}-{slug}.md`, sharing a `{date}-{slug}` stem, but any markdown path is a valid target.

### 1a: Pick the Document

Work down this list and stop at the first that resolves:

1. **A path in the arguments.** Two paths → PAIR mode, first is the spec. Verify each exists; **STOP** with the path that failed if not.
2. **The document this session has been working on** — the spec or plan most recently written, edited, or discussed in this conversation. This is the default and it is almost always right: you know which doc is live, and the filesystem does not. If several are in play, pick the most recently touched and name it in the confirmation so a wrong guess is visible immediately.
3. **Newest on disk**, only if the session gives you nothing to go on: `ls docs/superpowers/specs/ docs/superpowers/plans/`, take the newest by the leading `{date}` (ties: prefer the spec). Say explicitly that you fell back to date order — that is a guess, and the user should see it as one.
4. Nothing found → **STOP**:
   ```
   No spec or plan identified. Pass a path explicitly:
     /my:codex-review path/to/doc.md
   ```

Classify the resolved doc: under `specs/` or ending in `-design.md` → **SPEC**; otherwise → **PLAN**.

### 1b: Pairing Is Opt-In

Cross-check the plan against its spec **only** when the user asks, via either:

- two paths in the arguments, or
- `--with-spec` / `--with-plan` — find the sibling by stem: from `specs/{stem}-design.md` look for `plans/{stem}.md`, and vice versa. If the exact stem misses, retry on the slug alone, ignoring the date prefix — the two docs are often written on different days.

If the flag is given and no sibling is found, say so and review the single doc rather than stopping. If no flag is given, **do not** pull in a sibling even when one exists on disk — a stale plan from an earlier iteration produces confident, wrong traceability findings.

| Target | Mode | What Codex checks |
|--------|------|-------------------|
| One spec | **SPEC** | Design rubric |
| One plan | **PLAN** | Plan rubric |
| Both (opt-in) | **PAIR** | Both rubrics, **plus** traceability between them |

### 1c: Confirm Before Spending Tokens

```
Codex review — {MODE}
  tree:    {ROOT}  {"(worktree {name}, branch {branch})" if under .claude/worktrees/}
  sandbox: {SANDBOX_MODE} ({why})
  doc:     {path}   {"— picked from this session" | "— newest on disk (guess)"}
  {"spec:/plan:" lines instead, in PAIR mode}
```

---

## Phase 2: Build the Review Prompt

Create a private directory for this run and keep both temp files inside it:

```
WORKDIR=$(mktemp -d /tmp/codex-review-XXXXXX)
```

Store `WORKDIR`, then write the prompt to `"$WORKDIR/prompt.md"` as `PROMPT_FILE`. Phase 5 removes the whole directory.

Use `mktemp -d`, not a `$(date +%s)` suffix. Second resolution is not enough: you routinely have several worktrees open, and two reviews started in the same second would share a prompt and an output file — one run reading another's prompt, or deleting its result.

Pass the docs to Codex **by path, not by content**. Codex has read-only repo access and reviews far better when it can open the files, follow references, and check claims against real code.

The prompt has four parts:

### 2a: Role

```
You are reviewing a design document / implementation plan for this repository.
You are a REVIEWER, not an implementer. Do not write, edit, or create any files.
Read whatever you need from the repo to check the document's claims against the
actual code — that cross-check is the point of this review.

Documents under review:
  SPEC: {spec_path}   (omit this line if none)
  PLAN: {plan_path}   (omit this line if none)
```

### 2b: Rubric

Include the section(s) matching the mode.

**SPEC rubric** (include in SPEC and PAIR modes):

- Does the design actually solve the stated problem? Any requirement it silently drops?
- Are the alternatives considered, and are the stated reasons for rejecting them sound?
- Architecture and ownership boundaries — does this put logic in the right component?
- Data model, persistence, migration, and backward compatibility.
- Security and privacy implications.
- Failure modes, concurrency, and partial-failure behavior.
- Observability — will anyone be able to tell when this breaks?
- **Anything in the repository that contradicts the design.** Cite `file:line`.
- Scope creep: parts of the design that solve a problem nobody has.

A spec is usually reviewed **early**, before any of it is built. Tell Codex explicitly: files, symbols, and commands the spec *proposes creating* are not defects — do not report them as missing. Only flag a conflict when the design contradicts something that already exists.

**PLAN rubric** (include in PLAN and PAIR modes):

- Step ordering and hidden dependencies — does any step need something a later step provides?
- Can each step land independently, or does the tree break in the middle?
- Does every step carry real verification, or does it hand-wave "add tests"?
- **Do the files, paths, symbols, and commands the plan cites as *already existing* actually exist?** Check them. This is the single most valuable thing you can do here.
- Missing steps: migration, rollback, docs, config, cleanup of the thing being replaced.
- Steps that are under-specified to the point of ambiguity, and steps so over-specified they'll be wrong on contact.
- Blast radius: what else in the repo does this touch that the plan doesn't mention?

The same exemption applies as for specs, and it matters more here: a plan's job is to list artifacts it will **create**. Tell Codex that files, paths, symbols, and commands a step proposes creating are not defects — the check is for references the plan treats as pre-existing ground truth. When it's ambiguous whether a step creates or consumes something, say so as a `[Nit|LOW]` ambiguity finding rather than asserting the file is missing.

**PAIR rubric** (PAIR mode only — this is the highest-value section, put it first):

- **Traceability**: list every requirement in the spec that has no corresponding step in the plan.
- **Scope creep**: list every plan step with no basis in the spec.
- **Contradictions**: places where the plan's approach diverges from the design without saying so.

### 2c: Repository Conventions

If `CLAUDE.md` or `AGENTS.md` exists at `ROOT`, tell Codex to read it and treat it as authoritative for this repo's conventions.

### 2d: Output Contract

```
Return your review in exactly this format and nothing else:

VERDICT: SHIP | REVISE | RETHINK

FINDINGS:
- [Blocking|HIGH] {doc}:{section} — {what is wrong and why it matters}
- [Concern|MEDIUM] {doc}:{section} — {...}
- [Nit|LOW] {doc}:{section} — {...}

COVERAGE GAPS:            (PAIR mode only; omit the section otherwise)
- {spec requirement} — not addressed by any plan step
- {plan step} — no basis in the spec

SUMMARY:
{3-5 sentences: is this doc ready to build from, and what is the biggest risk}

If you cannot read the repository — sandbox failure, missing files, any
environmental block — do NOT return a VERDICT line. Return exactly:

STATUS: INCOMPLETE
REASON: {what blocked you}

A verdict you cannot support by reading the code is worse than no verdict.
```

Severity is `Blocking` (would produce wrong or broken work), `Concern` (worth resolving before starting), or `Nit` (author's discretion). Confidence is `HIGH` / `MEDIUM` / `LOW`. Tell Codex to **prefer few high-confidence findings over many speculative ones**, and to cite `file:line` for every claim about existing code.

---

## Phase 2e: Integrity Guard (danger-full-access only)

Skip this phase entirely when `SANDBOX_MODE` is `read-only` — a read-only
sandbox cannot write, so there is nothing to guard.

Under `danger-full-access` the prompt is the only thing telling Codex not to
write. That is probably enough; this phase makes "probably" checkable.

**Before running Codex**, capture both:

```
git status --short
sha256sum {absolute path of each document resolved in Phase 1, quoted}
```

Run this Bash call with `ROOT` as its working directory, and give `sha256sum` absolute quoted paths — never bare relative ones. Phase 0d supports reviewing a doc in a *different* worktree than the session's, and there a bare `git status` in the session's directory reports on the wrong checkout, and the guard reports clean no matter what Codex wrote. Do **not** reach for `git -C` instead: this command's frontmatter grants `Bash(git status:*)`, which `git -C ...` does not match, so it would prompt.

Store them as `PRE_STATUS` and `PRE_HASHES`.

**After the run**, capture the same two the same way — same working directory,
same absolute paths — into `POST_STATUS` and `POST_HASHES` and compare.

Why hashes and not `git checkout`: Phase 0d has Codex read the **working tree**,
so reviewing a document before it is committed is the normal path here. `git
checkout --` cannot restore an uncommitted document, and in a devcontainer the
workspace is usually a bind mount from the host, so a write is not confined by
the container boundary either. The container bounds what Codex reaches *outside*
the repo — the smaller half of the exposure.

A mismatch in either capture is reported in Phase 4a. Do not repair, revert, or
stage anything: report it and let the user decide.

---

## Phase 3: Run Codex

```
codex exec --sandbox "$SANDBOX_MODE" -C "$ROOT" --color never -o "$WORKDIR/review.md" - < "$PROMPT_FILE"
```

Store `"$WORKDIR/review.md"` as `OUT_FILE`.

**Quote every path substitution**, as above. `ROOT` is a worktree path and can contain spaces; unquoted it breaks `-C`, `-o`, and the input redirect — and unquoted cleanup in Phase 5 then targets the wrong thing.

- `--sandbox "$SANDBOX_MODE"` — `read-only` unless Phase 0e determined that this
  container cannot initialize bubblewrap. Do **not** hand-edit this to
  `danger-full-access`; let Phase 0e decide, so the integrity guard runs with it.
  If the run fails because detection missed, the re-entry procedure below
  re-decides `SANDBOX_MODE` and re-enters Phase 2e — the flag on this line still
  stays as written.
- `-C "$ROOT"` — pins the working root to the current checkout/worktree.
- `-o` — writes only the final message, so you get the review without the reasoning transcript.
- `-` — reads the prompt from stdin, avoiding shell-quoting problems with a long prompt.

This takes a few minutes on a substantial plan. If the Bash call times out, say so and offer to re-run — do **not** silently report a partial review.

**If Codex errors:**

| Error | Meaning | Action |
|-------|---------|--------|
| `401 Unauthorized` on `api.openai.com` | The zsh wrapper was bypassed (Phase 0b) | Re-run with `codex` as the first word |
| Connection refused to `172.17.0.1:1337` | Vekil proxy is down | Tell the user; do not fall back to a direct API call |
| Codex reports `main` as the branch, or can't find the doc | `-C` pointed at the main checkout, not the worktree (Phase 0d) | Re-derive `ROOT` and re-run |
| Git commands fail inside Codex, in a worktree only | Sandbox can't reach `.git/worktrees/` in the main checkout | Re-run with `--add-dir {main checkout}/.git`; report if that's needed, it's a regression |
| `bwrap: No permissions to create a new namespace`, or `bwrap: Creating new namespace failed` | The container forbids user namespaces; Codex's Linux sandbox cannot initialize | Detection missed the container. Follow **Re-entry after a missed container** below |
| Non-zero exit | Run failed | Report the stderr tail verbatim; do not fabricate a review |

bwrap's wording varies by build, so both observed forms are listed. Phase 0e keys off the probe's **exit status**, never the message text.

Match the specific rows before the general one: `Non-zero exit` is the fallback for a failure none of the rows above describe. A non-zero exit means the output is not a review, whether or not `review.md` exists. A run that fails partway can leave a partial or stale `review.md` behind; do not read it as findings, do not group it by severity, and do not add a verdict to it.

**Re-entry after a missed container.** The bwrap rows fire exactly when Phase 0e chose `read-only` for a container that cannot initialize bubblewrap — so Phase 2e was skipped and no `PRE_STATUS`/`PRE_HASHES` exist. Do **not** re-run with a hand-edited `--sandbox` flag: that runs Codex unsandboxed against a bind-mounted working tree with no integrity guard, which is the one case the guard exists for. Instead:

1. Report that detection missed the container, and say which markers you checked.
2. Set `SANDBOX_MODE` to `danger-full-access`.
3. Re-enter at **Phase 2e** and capture `PRE_STATUS` and `PRE_HASHES`.
4. Re-run the Phase 3 command **unchanged** — `--sandbox "$SANDBOX_MODE"` now
   resolves to `danger-full-access` on its own.
5. Capture `POST_STATUS` and `POST_HASHES`, and report any difference through
   Phase 4a like any other unsandboxed run.

Re-decide `SANDBOX_MODE` once. If the same error recurs under
`danger-full-access`, stop and report it — that is a different failure.

Then read `OUT_FILE` with the Read tool.

---

## Phase 4: Report and Offer to Apply

### 4a: Report

**If the Phase 2e integrity guard found a difference**, lead the report with it — above the verdict, above the findings — naming every path whose status or hash changed:

```
WARNING: files changed during an unsandboxed review run.
  {path}  {status change or hash mismatch}
Codex was asked to review, not modify. Inspect these before trusting the review.
```

Then continue with the report. A clean guard needs no mention.

**If the review begins `STATUS: INCOMPLETE`**, it is not a review. Report it as an environment failure, quote the `REASON:` verbatim, and state that no design conclusion follows:

```
Codex could not complete this review: {REASON}
Nothing was inspected, so no design conclusion follows — this is not a signal
either way about the document.
```

Skip Phase 4b entirely; there are no findings to apply. Do not group it by
severity, do not add "My take", and never present it as a verdict.

Otherwise, for a normal (non-INCOMPLETE) review, present Codex's review in the conversation, grouped by severity, Blocking first. Keep its wording for the findings themselves — the value here is an independent voice, not your paraphrase.

Then add your own short assessment, clearly separated:

```
## My take
{Where you agree, where you don't, and why. Flag any finding you believe is
a false positive — you have the conversation context Codex lacks.}
```

Be honest when Codex is right about something you missed. Be equally direct when it's wrong: a finding that misreads the repo is worth saying so, with the `file:line` that disproves it.

### 4b: Offer to Apply

Ask which findings the user wants folded into the doc. Then:

- Edit **only** the spec/plan markdown files. Never touch source code from this command — if a finding implies a code change, it belongs in a plan step, not an edit here.
- Apply only the findings the user accepted. Do not sneak in the rest.
- Preserve the doc's existing structure and voice; you are amending it, not rewriting it.
- After editing, show a summary of what changed in each doc.

If the user wants none applied, that is a complete and correct outcome — stop cleanly.

### 4c: Check the Target Before Editing

Two checks before the first `Edit`, in this order.

**1. The target must live inside the tree you reviewed.** Canonicalize it — resolve symlinks and make it absolute — and confirm the result is under `ROOT`. A relative path that climbs out, an absolute path, or a symlink can all land an edit in a *different* checkout while `ROOT` itself still looks fine. That is the tree-A-plan-against-tree-B-code failure from Phase 0d arriving through the back door: you would be applying findings to a copy Codex never read.

Only the spec/plan files resolved in Phase 1 are eligible. If a target fails this check, **STOP** and report both paths:

```text
Refusing to edit {canonical target}: it resolves outside the reviewed tree
({ROOT}). Codex reviewed a different copy of this document.
```

This one is a hard stop, not a prompt. There is no reading of it where editing an unreviewed file is what the user meant.

**2. Warn if `ROOT` is not a linked worktree.** Applying findings **writes to a spec or plan**, which this repo's working agreement counts as feature work — and feature work belongs in a linked worktree.

If `ROOT` is not under `.claude/worktrees/`, say so and get explicit confirmation:

```text
Heads up: applying these findings edits {doc} in the main checkout ({ROOT}),
not a linked worktree. The working agreement puts spec and plan writes in a
worktree. Apply here anyway, or move to a worktree first?
```

Warn and confirm — do **not** hard-stop here. Reviewing is read-only and legitimately useful from any checkout, and a hard gate would also block the ordinary case of amending a doc that has already merged to `main`. The user decides; a static rule cannot tell "starting feature work" apart from "fixing a stale line in a merged plan."

Once confirmed, proceed. Do not re-ask on subsequent edits in the same run.

---

## Phase 5: Clean Up

Remove the run directory:

```
rm -rf "$WORKDIR"
```

Quote the path, and use `-f`/`-rf` — plain `rm` silently no-ops in this shell. Because `WORKDIR` came from `mktemp -d`, this cannot collide with another in-flight review's files.

---

## Important Notes

- **Codex reviews, Claude decides.** This command produces a second opinion, not a verdict. Conflicting findings are useful information, not a problem to resolve by deferring.
- Never report a review you did not actually receive. If the run failed, say it failed.
- Do not run builds, tests, or linters — Codex is reading, not verifying.
- One target per run. Reviewing a spec early, before a plan exists, is the normal path — not a reduced one.
- This command is intentionally **not** symlinked into `prompts/` — that surface is for Codex, and pointing Codex at a command that calls Codex is a loop with no upside.
