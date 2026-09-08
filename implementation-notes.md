# Permissive Pi permission policy implementation notes

## Tasks 2-3 RED evidence

The Task 2 pipeline regressions were added before changing the policy.

Command:

```bash
bin/validate-pi-security-runtime
```

Exit: `1`

Observed first failure:

```text
Error: pipeline referenced skill script: expected terminal allow, received block
```

The complete failing-label check temporarily characterized each newly expected allow against the old policy, then restored the approved expectations before implementation:

| Label | Old decision | Deciding surface | Matched rule |
|---|---|---|---|
| `referenced skill script` | ask | `external_directory` | `*` |
| `Pi metadata jq read` | ask | `external_directory` | `*` |
| `external git diff` | ask | `external_directory` | `*` |
| `ordinary curl GET` | ask | `bash` | `curl *https://*` |
| `slash-qualified curl GET` | ask | `bash` | `*/curl *` |

The Git subcommand regression `git switch -c feature/example` already resolved to `allow` because the tracked baseline did not contain the over-broad `*git * -c *` rule described by the plan. It remains as a regression proving that the new leading Git configuration-option denies do not collide with the `switch` subcommand's own `-c` flag.

Task 3 configuration invariants were then changed before the policy:

```bash
bats tests/pi_permissions.bats
```

Exit: `1`

Observed failures:

```text
not ok 4 Pi permission path policy protects secrets without blocking env examples
not ok 5 Pi permission Bash policy allows local Git while guarding risky operations
```

These failures were caused by the old external-directory `ask` catch-alls, broad Git/GitHub asks, broad curl asks, and absence of the ordered curl tripwire matrix.

The optional bare-receiving-shell behavior was also proved RED before adding exact shell-name asks:

```text
Error: pipeline bare sh receiving shell asks: expected terminal block, received allow
```

The same pipeline table proves that `bash bin/validate-ai --verbose` remains allowed while bare `sh`, `bash`, `zsh`, `dash`, and `ksh` command units ask.

## Upstream parser limitation

`@gotgenes/pi-permission-system` 29.2.0 may classify arbitrary inline source containing `process.env` as a path matching the protected `*.env.*` rule. This implementation deliberately preserves the `.env`/`.env.*` denials and does not add a `process.env` allow override. Inline interpreter diagnostics affected by that lexical collision must be rewritten or addressed upstream; this policy does not claim to solve it.

## Tasks 2-3 GREEN evidence

Focused configuration verification:

```bash
bats tests/pi_permissions.bats
```

Exit: `0`

```text
1..10
ok 1 Pi runtime baselines are valid JSON
ok 2 Pi permission policy starts balanced without unredacted review logging
ok 3 Pi permission policy allows known workflow tools
ok 4 Pi permission path policy protects secrets without blocking env examples
ok 5 Pi permission Bash policy allows local Git while guarding risky operations
ok 6 Pi web access uses keyless ordered search and local extraction
ok 7 Pi subagent child exclusions exactly match installed package sources
ok 8 tracked Pi runtime baselines contain no credential fields
ok 9 Pi runtime validator fails clearly when permission package is absent
ok 10 Pi runtime validator fails clearly when bundled jiti is absent
```

Installed-package manager and full pipeline verification:

```bash
bin/validate-pi-security-runtime
```

Exit: `0`

```text
Pi permission schema and deterministic engine validation passed.
```

Repository AI-resource validation:

```bash
bash bin/validate-ai
```

Exit: `0`

```text
=== Summary ===
  Prompts:  5
  Skills:   7
  Errors:   0
  Warnings: 0

PASSED
```

Whitespace verification:

```bash
git diff --check
```

Exit: `0`, no output.

## Implementation decisions and self-review

- Kept `permission["*"]` at `ask` and Bash `"*"` at `allow`.
- Changed only the two global external-directory catch-alls; all protected path-map denials and their ordering remain intact.
- Removed only the four broad Git/GitHub asks. Existing operation-specific asks and hard denials remain after the permissive default; explicit asks were added for `update-ref -d`, `restore`, PR merge, and issue close because those checks had previously depended on the removed catch-alls.
- Added leading Git `-c` and `--config-env` hard-deny patterns plus targeted post-`-C` alias, `core.sshCommand`, and `--config-env` coverage. Direct checks prove these execution-capable forms deny while both `git switch -c` and `git -C . switch -c` allow.
- Made broad curl rules allow, removed URL-only asks, and placed every approved lexical body/upload/authentication/mutating-method ask after both broad allows. Upper- and lower-case conventional methods are explicit. The policy intentionally does not claim token-aware matching.
- Added exact bare-shell asks only after the pipeline proved that command-unit matching distinguishes a bare receiving shell from `bash bin/validate-ai --verbose`.
- Preserved force-push, reset/clean, Git external-command, search subprocess, privilege, destructive GitHub, protected credential path, and root-deletion checks in the installed-package validator, including the requested gate-level tripwire matrix.
- Added isolated skill-script and Pi-metadata fixtures under a temporary HOME and restored the caller's HOME in `finally`; no fixture command is executed.
- Kept `RELAXED_PIPELINE_CASES` separate from baseline ownership and replaced index-derived tool-call IDs with stable label-derived IDs.
- Did not modify named-agent definitions, sandbox code, upstream packages, or dependencies.
- The required polish pass found no safe auto-fixes or unresolved correctness findings. Review was performed locally because this unit explicitly forbids subagents and external reviewers.

## Tasks 2-3 fix round 1 evidence

The inherited four-file fix diff was retained and reviewed in place. Its first focused Bats run exited `1` with 9/10 passing; only `tracked Pi runtime baselines contain no credential fields` failed because the new `*git *credential *` Bash command-pattern key matched the generic sensitive-field-name scan. Since `.permission.bash` is a schema-constrained pattern-to-action map rather than a credential store, the scan now excludes only that map while continuing to inspect all actual runtime configuration fields.

The completed fix round:

- asks for decomposed `sh`, `bash`, `zsh`, `dash`, and `ksh` stdin modes (`-s...` and `-`) while the full pipeline continues to allow `bash bin/validate-ai --verbose`;
- denies key-agnostic post-`-C` Git `-c key=value` forms without reinstating the broad `*git * -c *=*` collision, and verifies both ordinary and post-`-C` `switch -c` forms remain allowed;
- asks ordinary `git send-pack` and denies its `--force` and `+refspec` forms;
- asks `git credential` and `gh auth token` while allowing `gh auth status`;
- asks non-read `git config`, allows the retained read forms, and keeps later alias and `core.sshCommand` executable-value denials. The `core.sshCommand` deny requires an actual value so `git config --get core.sshCommand` remains allowed.

Final commands all exited `0`:

```bash
bats tests/pi_permissions.bats
bin/validate-pi-security-runtime
bash bin/validate-ai
git diff --check
```

Exact result summary:

- Bats: `1..10`, all 10 cases `ok`.
- Runtime: `Pi permission schema and deterministic engine validation passed.`
- AI validation: 5 prompts, 7 skills, 0 errors, 0 warnings, `PASSED`.
- Diff check: no output.

The final local polish/self-review found no additional safe fix or unresolved correctness issue. No subagent or external reviewer was used, and the ruled-out curl syntax expansion and deferred minor findings were not changed.

## Task 6 authoritative permission publication

The installer now gives the repository ownership of the rendered permission map and stable permission-system fields while preserving only the three UI-owned runtime booleans: `yoloMode`, `debugLog`, and `permissionReviewLog`. A valid active `yoloMode: true` fails with deliberate disable guidance even when mutable reset is requested. Invalid runtime controls are treated as migration input: the original is backed up and the validated non-YOLO tracked baseline is published without preserving malformed values.

Publication waits until tracked package inventory reconciliation and pinned npm package installation have made the exact permission-system schema available. The effective candidate is staged beside the destination, checked through `bin/validate-pi-permission-config`, compared with the runtime's snapshotted SHA-256 identity immediately before publication, backed up once when needed, and atomically installed as mode `0644` beneath the existing mode-`0700` runtime directory. Recognized tracked links are migrated; foreign links and invalid destination types fail without being followed or replaced. The earlier sandbox-retirement reset remains ahead of package-inventory removal.

The deterministic concurrency test uses only a Bats-confined directory containing `ready` and `continue` marker files. The hook is rejected before installer mutation unless Bats runtime markers are present, both test `HOME` and hook resolve below `BATS_TEST_TMPDIR`, and none of the marker contents are executed.

TDD evidence:

- The first focused run (`bats --filter 'permission policy|YOLO|concurrent runtime' tests/ai_installers.bats`) exited `1`: authoritative publication, active-YOLO refusal, schema-invalid candidate refusal, and concurrent-change preservation all failed against the old installer; the pre-existing foreign-destination refusal characterization passed.
- A strengthened hook-confinement test then failed because hook validation occurred after unrelated installer mutation; validation was moved before all installer operations and the test passed.
- Focused tests subsequently passed with eight cases covering publication/controls/idempotence, YOLO, candidate validation, invalid-runtime migration, concurrency, hook confinement, recognized-link migration, and foreign/invalid destinations.

Local polish removed duplicated schema JSON from the two Pi stubs by generating one Bats fixture and copying it when the permission package is installed. No subagent or external reviewer was used, as required for this task.
