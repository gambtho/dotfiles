# Permissive Pi Permission Policy Design

**Date:** 2026-09-07
**Status:** Approved design

## Summary

Replace the current increasingly detailed shell-effect policy with an explicitly permissive attention policy. The policy will silently allow routine Pi, shell, validation, skill, and network workflows while preserving deterministic prompts or denials for recognizable high-risk operations.

This is not a sandbox and must not be described as one. Allowed programs execute with the invoking user's authority and can perform effects the permission parser cannot observe. The purpose of the policy is to reduce accidental damage and reserve human attention for recognizable dangerous operations, not to contain hostile code.

No new sandbox integration or upstream permission-system implementation is part of this change. A maintained, integrated sandbox may replace this posture later when one is available for Pi and WSL2 without private security-critical adapter code.

## Context

The repository has repeatedly expanded `ai/pi/config/permission-system.json` to suppress routine approval prompts. The remaining prompts are structural rather than missing one-off command exceptions:

- `jq -r` reading Pi package metadata prompts because `jq` is not in the permission package's frozen pure-reader core. Its external path is treated as both read and write, and the external-write `ask` wins.
- `node ~/.agents/skills/impeccable/scripts/load-context.mjs` prompts even though the referenced skill root is allowed for reads. The interpreter's script path is classified as potentially writable.
- `git diff` against an external runtime file prompts because Git is not classified as a pure reader for path effects, even when the Bash command rule allows `git diff`.
- named child agents prompt for `nl`, `make ai-check`, and `bash bin/validate-ai` because their agent-level Bash catch-all is `ask` and the command spellings have no narrower allow.

A review of 1,733 Bash calls from 30 recent local sessions found 233 commands with at least one non-allow gate. The largest prompt groups came from external-directory path inference, followed by deliberate command asks such as deletion, environment inspection, uploads, and remote access.

Upstream issue [gotgenes/pi-packages#892](https://github.com/gotgenes/pi-packages/issues/892) reaches the same architectural conclusion: shell path projection should not be the security boundary. Existing sandbox options were evaluated but none currently provides a maintained, out-of-the-box Pi integration with acceptable WSL2 UX. The user selected continued Pi use without custom sandbox code and accepted the resulting residual risk.

## Goals

1. Eliminate routine approval prompts caused by ambiguous shell path-effect inference.
2. Preserve prompts for recognizable operations where user attention remains useful.
3. Preserve hard denials for catastrophic, privilege-escalating, credential-targeting, or policy-bypass operations.
4. Make ordinary `curl` downloads and GET requests silent while retaining prompts for recognizable uploads, credentials, and mutating requests.
5. Make named-agent behavior match its documented operating contract for routine inspection and verification.
6. Ensure repository permission-policy changes reach the active runtime policy instead of being silently hidden by preserved drift.
7. Validate final decisions through the installed permission package's real gate pipeline, including named-agent composition and deciding surfaces.
8. Document the absence of process containment plainly.

## Non-goals

- Implementing or integrating a sandbox.
- Proving that allowed shell commands are read-only or safe.
- Preventing an allowed interpreter or binary from constructing paths internally.
- Containing extension-internal subprocesses, LSP servers, or web tools.
- Persisting individual interactive approvals as policy.
- Building a model-based permission judge.
- Guaranteeing that named agents are read-only when they retain Bash.
- Replacing Pi project trust.

## Security model

### What remains enforced

The permission system continues to enforce model-facing tool decisions and command/path rules it can recognize. The worktree guard continues to block direct `write`, `edit`, and mutating `lsp_fix` calls against primary checkouts.

The policy retains:

- explicit secret and credential path denials;
- force-push and mirror-push denials;
- hard-reset and forced-clean denials;
- root-recursive deletion denials;
- `sudo` and `doas` denials;
- repository deletion and destructive GitHub API denials;
- Git alias/config command-execution bypass denials;
- subprocess-capable search-option denials;
- prompts for recognizable deletion, history rewriting, remote shell/transfer, merge/closure, upload, authentication, and mutating HTTP operations.

### Explicit residual risk

An allowed Bash process is not contained. It may:

- read or write any path available to the invoking user;
- construct sensitive paths internally and bypass lexical path extraction;
- mutate a primary checkout;
- inspect inherited environment variables;
- access arbitrary network destinations through an unrecognized program;
- spawn descendants with the same user authority;
- change behavior after command classification;
- execute package hooks, downloaded binaries, project scripts, or interpreters with transitive effects the policy cannot infer.

Direct path denials remain useful tripwires for built-in file tools and obvious Bash operands, but they are not a confidentiality boundary against an allowed program.

## Policy behavior

### Universal and tool defaults

- Keep `permission["*"]` as `ask` so newly introduced extension tools do not become silently trusted.
- Keep known Pi workflow tools explicitly allowed.
- Keep built-in read/write/edit tools explicitly allowed, subject to path denials and worktree guard behavior.
- Keep MCP targets at `ask` unless separately reviewed.
- Keep skills allowed.

### Path surfaces

Both `external_directory_read["*"]` and `external_directory_write["*"]` become `allow`. This is the deliberate compatibility change that prevents an ambiguous path from becoming a false prompt merely because the command is not in the pure-reader core.

The cross-cutting `path_read` and `path_write` maps retain explicit denials for:

- `.env` and `.env.*`, with `.env.example` allowed;
- private keys and certificates where currently protected;
- SSH, AWS, Azure, GCP, Kubernetes, and Docker credential roots;
- browser profile roots;
- Pi authentication data.

Rule order remains catch-all first and specific overrides later because the permission package uses last-match-wins.

The scalar `path_write: allow` overrides in `rush`, `deep`, and `review` must be removed. A scalar agent override replaces the global protected-path map instead of merely overriding its catch-all, which would otherwise make obvious protected writes such as `printf x > ~/.ssh/config` silent once external writes and Bash default to `allow`. Named-agent tests must exercise protected reads and writes through Bash redirects as well as through direct tools.

### Bash default

The main Bash surface keeps `"*": "allow"`. Existing specific asks and denies remain later in the ordered map so they override the permissive fallback.

The implementation should remove redundant allow entries only when behavioral tests prove they are unnecessary. Simplification must not reorder security-sensitive asks or denies accidentally.

### Deletion

Recognizable `rm` operations continue to ask. Catastrophic root-recursive forms remain denied. Force variants and multi-path forms must be covered by behavioral tests rather than key-presence assertions alone.

### Git and GitHub

Routine local Git inspection, worktree use, staging, commits, synchronization, and ordinary pushes remain allowed according to current policy intent.

Continue asking or denying, according to existing severity, for:

- branch/tag force, deletion, or replacement;
- worktree force removal;
- commit amendment;
- destructive stash/reflog/notes operations;
- executable rebase and archive forms;
- force, mirror, delete, all-ref, tag-wide, or no-verify pushes;
- Git configuration forms that can alter behavior or execute commands;
- PR merges, issue closure, repository deletion, and destructive API methods.

Read-only GitHub API requests should remain allowed. Mutating API requests should be classified by method and data-bearing flags where practical, without claiming complete HTTP semantic analysis.

### Curl

Ordinary `curl` requests, including HTTPS downloads and GETs, are allowed.

Later rules continue to ask for recognizable authority-bearing or mutating forms:

- `--data`, `--data-*`, and `-d`;
- `--form` and `-F`;
- `--upload-file` and `-T`;
- explicit `POST`, `PUT`, `PATCH`, or `DELETE` through `-X` or `--request`;
- explicit authorization, cookie, client-certificate, private-key, or credential arguments.

Known destructive API operations remain denied where an exact policy already exists.

The guaranteed lexical coverage is intentionally bounded to bare or slash-qualified `curl` command names, ordinary ASCII-space token separation, exact long-option spellings (`--data`, `--data-raw`, `--data-binary`, `--data-urlencode`, `--form`, `--upload-file`, `--request`, `--user`, `--cookie`, `--cert`, `--key`, and `--netrc`), and separate-token short forms (`-d`, `-F`, `-T`, `-X`, `-u`, `-b`, `-E`). Authorization-header coverage comes from literal `Authorization:` payload matching; the policy does not classify every `-H` or `--header` argument. Explicit request methods cover conventional upper- and lower-case `POST`, `PUT`, `PATCH`, and `DELETE`. Tests must cover these forms before and after URLs, multiple URLs, slash-qualified executables, and command chains.

Arbitrary header flags, attached short values, short-option clusters, tabs, escaped or concatenated option names, variable-expanded options or methods, aliases/functions, config/response files, mixed-case method spellings, and semantically equivalent interpreter or library requests are residual risk unless an exact behavioral test says otherwise. Broad wildcard patterns must not be presented as token-aware. A bare receiving shell (`curl … | sh`, `bash`, or equivalent) should retain an explicit ask where command decomposition exposes it, without making ordinary `bash path/to/script` validation prompt again.

### Other network and remote commands

SSH, SCP, SFTP, rsync, netcat-family tools, socat, Telnet, FTP, and similar direct remote mechanisms continue to ask unless a separately reviewed rule already denies them.

The policy does not claim to detect equivalent networking performed by Node, Python, project binaries, or package scripts.

## Named-agent policy

The current `rush`, `deep`, and `review` definitions describe routine inspection as non-interactive but use a Bash catch-all of `ask`. Their effective policies must be changed so ordinary inspection and validation no longer forward prompts solely because of command spelling.

Direct `write` and `edit` tools remain denied for read-oriented agents. The scalar `path_write: allow` entry must also be removed so the full global protected-path write map survives agent-scope composition. Their recognizable mutating Git/GitHub operations and unresolved policy-bypass forms remain denied. Bash itself cannot be made securely read-only without containment; documentation must replace the absolute “operate read-only” claim with an accurate statement that direct mutation tools, obvious protected paths, and recognized mutation commands are blocked, while arbitrary allowed Bash programs are not contained.

The `smart` agent remains an implementation-capable child and follows the permissive parent baseline plus the repository's worktree rules. Its effective path composition must be covered separately rather than inferred from the read-oriented agents.

Agent frontmatter should share a generated or clearly single-sourced policy fragment if the package format supports it. If not, keep definitions structurally parallel and add a test that compares their intended common rule subset to prevent drift.

## Runtime policy ownership

The tracked permission policy is a repository-owned operational and security baseline, not an ordinary user preference file. A successful permission-policy PR must affect the runtime policy after the normal installer runs.

Revise reconciliation for this file only, with an explicit ownership split:

- the repository owns `permission` and stable operational fields;
- the runtime owns the three fields the `/permission-system` UI writes: `yoloMode`, `debugLog`, and `permissionReviewLog`.

Publication must:

1. Render the active Pi agent path token.
2. Validate the tracked candidate against the exact installed package schema.
3. Load a valid existing runtime file and preserve its three runtime-owned booleans in the candidate.
4. Refuse policy replacement while the existing runtime has `yoloMode: true`; an active unattended relaxation must be disabled deliberately before its policy changes.
5. Record the existing runtime file identity, check it before backup, then check it again after backup and immediately before atomic publication; abort on detected concurrent modification rather than losing a UI toggle.
6. If the effective candidate differs, create one timestamped backup and publish atomically.
7. Preserve owner-safe directory and file modes.
8. Report the old and new policy identities without logging sensitive command payloads.
9. Leave authentication, sessions, trust, logs, grants, model selection, and unrelated mutable settings untouched.

This is best-effort compare-before-publish rather than locking: the permission-system UI writer shares no lock with the installer, so a runtime write can still race between the final identity check and the atomic rename. The second check narrows that unavoidable final race but cannot eliminate it.

The approved implementation has one bounded transitional exception: when positively identified legacy `pi-sandbox` state is being retired, the installer backs up and resets even an active-YOLO permission file to the tracked non-YOLO baseline before package-schema availability. This preserves a permission layer before removing the old containment package. It is not used by normal authoritative reconciliation, which refuses active YOLO and validates first.

Runtime permission-map edits are temporary machine-local overrides until the next `make ai`; the three UI-owned runtime controls survive reconciliation, including when `PI_AI_RESET_MUTABLE_CONFIG=1` is set. Documentation must state both behaviors. If further durable machine-local overlays are needed later, they require an explicit supported merge design rather than silent whole-file drift.

Check mode should report drift. Whether drift makes `make ai-check` nonzero should follow existing repository check-mode conventions; at minimum, CI and tests must compare the tracked rendered policy with an isolated installed runtime result.

## Validation strategy

### Configuration tests

Keep schema validation and invariant checks for:

- universal fallback;
- protected paths;
- explicit catastrophic denies;
- allowed workflow tools;
- named-agent direct-tool restrictions;
- ordered catch-all/specific override placement.

Avoid using literal key-presence assertions as the primary evidence of effective behavior.

### Deterministic manager tests

Continue testing policy resolution for individual surfaces, including global and named-agent scopes. Generate related command cases from categorized fixtures where practical to reduce duplication between JSON assertions and TypeScript examples.

### Full gate-pipeline tests

Exercise the installed package's actual tool-call pipeline with a prompt spy. The test model must reflect the package's two stages rather than expecting `ask` as a terminal pipeline result:

- assert the pre-escalation policy state and whether the prompt path is invoked;
- assert the terminal pipeline action (`allow` or `block`) after the prompt spy's decision;
- collect reporter/decision evidence for deciding surface, matched rule or synthetic sentinel, origin, and named-agent scope;
- assert whether a child request would be forwarded.

Required regression cases include:

| Command | Expected |
|---|---|
| `node ~/.agents/skills/impeccable/scripts/load-context.mjs` | allow |
| `jq -r '.version' ~/.pi/agent/npm/node_modules/.../package.json` | allow |
| `git diff --no-index local-file ~/.pi/.../config.json` | allow |
| `nl -ba ai/pi/install.sh` under `deep` | allow |
| `make ai-check` under `deep` | allow |
| `bash bin/validate-ai --verbose` under `deep` | allow |
| `printf x > ~/.ssh/config` under `rush`, `deep`, and `review` | deny |
| direct protected read and write tools under every named-agent scope | deny |
| ordinary HTTPS `curl` GET/download | allow |
| guaranteed `curl` data, form, upload, credential, or mutating-method forms | ask |
| `curl` with explicit credentials/private keys | ask or deny according to the specific rule |
| recursive `rm` | ask |
| root-recursive `rm` | deny |
| force-push | deny |
| `sudo`/`doas` | deny |
| direct protected credential path | deny |

Include negative parser regressions already observed in the corpus, such as Git's subcommand `-c` being mistaken for the global configuration option and inline source containing `process.env` being mistaken for a path.

### Runtime installation tests

Verify that:

- normal installation publishes a changed tracked permission policy;
- a differing runtime policy is backed up once;
- valid runtime `debugLog` and `permissionReviewLog` choices survive policy publication;
- active runtime YOLO blocks policy replacement with actionable guidance;
- a concurrent runtime-config change aborts publication rather than being overwritten;
- malformed tracked policy aborts before replacing the runtime policy;
- foreign symlinks and invalid destination types remain refused;
- isolated custom `PI_CODING_AGENT_DIR` rendering protects its own `auth.json`;
- unrelated runtime state is preserved;
- repeated installation is idempotent.

### Repository gates

At minimum:

```bash
bats tests/pi_permissions.bats
bats tests/ai_installers.bats
bin/validate-pi-security-runtime
bash bin/validate-ai --verbose
make ai-check
make check
```

Run the runtime validator against both the tracked candidate and the isolated installed runtime policy.

## Rollout

1. Implement and test in a linked worktree.
2. Validate against the exact pinned permission-system package.
3. Perform an isolated installation into a temporary `PI_CODING_AGENT_DIR`.
4. Start an isolated Pi session and exercise the regression corpus without YOLO.
5. Review every remaining prompt and confirm it belongs to an intentional ask.
6. Merge the change.
7. Run `make ai` from the canonical checkout, creating a backup of the prior runtime policy.
8. Restart Pi so all sessions load the new policy.
9. Confirm the representative main and subagent workflows no longer prompt.
10. Retain the backup and rollback instructions until the new policy has survived normal interactive use.

## Rollback

Rollback restores the backed-up runtime permission config and restarts Pi. Reverting the repository change alone is insufficient until `make ai` republishes the reverted tracked policy.

If the permissive policy causes unacceptable behavior, restore the prior runtime config first, then revert or amend the tracked policy. Do not enable permanent YOLO as a rollback shortcut.

## Acceptance criteria

- All listed false-prompt regressions resolve to `allow` through the real gate pipeline.
- Intentional asks and hard denies remain effective through that same pipeline.
- Ordinary `curl` downloads do not prompt; recognizable uploads, credentials, and mutating methods do.
- Named routine inspection and validation workflows do not forward prompts.
- Normal installer execution makes the tracked permission map active, preserves the three UI-owned runtime controls, refuses replacement during active YOLO, and backs up the replaced runtime file.
- Direct protected-path access remains denied.
- No sandbox, containment, or secure-read-only claim remains in active documentation.
- Validation passes against both candidate and installed runtime policies.
- The final review explicitly acknowledges that allowed Bash programs retain the user's ambient authority.
