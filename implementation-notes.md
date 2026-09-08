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
ok 2 Pi permission policy uses permissive defaults with safety tripwires
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

Publication waits until tracked package inventory reconciliation and pinned npm package installation have made the exact permission-system schema and manager artifacts available. The effective candidate is staged beside the destination, checked through `bin/validate-pi-permission-config`, compared with the runtime's snapshotted SHA-256 identity before backup and again after backup immediately before publication, and atomically installed as mode `0644` beneath the existing mode-`0700` runtime directory. This is best-effort compare-before-publish: the UI writer shares no lock, so an unavoidable race remains between the final identity check and rename. Recognized tracked links are migrated; foreign links and invalid destination types fail without being followed or replaced. The earlier sandbox-retirement reset remains ahead of package-inventory removal.

The deterministic concurrency tests use only Bats-confined directories containing data-only phase marker files. The hook is rejected before installer mutation unless Bats runtime markers are present, both test `HOME` and hook resolve below `BATS_TEST_TMPDIR`, and none of the marker contents are executed.

TDD evidence:

- The first focused run (`bats --filter 'permission policy|YOLO|concurrent runtime' tests/ai_installers.bats`) exited `1`: authoritative publication, active-YOLO refusal, schema-invalid candidate refusal, and concurrent-change preservation all failed against the old installer; the pre-existing foreign-destination refusal characterization passed.
- A strengthened hook-confinement test then failed because hook validation occurred after unrelated installer mutation; validation was moved before all installer operations and the test passed.
- Focused tests subsequently passed with eight cases covering publication/controls/idempotence, YOLO, candidate validation, invalid-runtime migration, concurrency, hook confinement, recognized-link migration, and foreign/invalid destinations.

Local polish removed duplicated schema JSON from the two Pi stubs by generating one Bats fixture and copying it when the permission package is installed. No subagent or external reviewer was used, as required for this task.

## Task 7 documentation and rollout verification

Active guidance now describes permission-system as an attention/tripwire layer rather than containment, gives ordinary `curl` and bounded upload/authentication/mutation behavior, and distinguishes the authoritative permission map from mutable baselines that preserve drift. It also documents generated-backup rollback, the three controls that survive `PI_AI_RESET_MUTABLE_CONFIG=1`, and the bounded legacy `pi-sandbox` retirement exception. The current design records that approved exception; the historical design points its superseded preserve-drift decision to current behavior.

### Repository gates

The required repository gates produced these results:

- `bash bin/validate-ai --verbose`: exit `0`; 5 prompts, 7 skills, 0 errors, 0 warnings, `PASSED`.
- `bats tests/pi_permissions.bats`: exit `0`; `1..13`, all 13 tests passed.
- `bats tests/pi_modes.bats`: exit `0`; `1..11`, all 11 tests passed.
- `bats tests/ai_installers.bats`: exit `0`; `1..43`, all 43 tests passed.
- `bin/validate-pi-security-runtime`: exit `0`; exact installed package schema, deterministic manager, and gate pipeline passed.
- `make ai-check`: exit `0`; dry-run reported authoritative permission publication and performed no apply.
- The first `make check` exposed a branch-caused syntax-discovery defect: the newly added extensionless Python validator was sent to `bash -n` because `bin/list-check-files` treated every extensionless `bin/` entry as Bash. A focused test failed RED (`1..1`, 1 failure), shebang-aware discovery fixed the classification, and the focused test plus the complete discovery suite passed GREEN (`1..1` and `1..12`).
- The repeated `make check`: exit `0`; all 513 Bats tests and all 8 Python unit tests passed, followed by AI validation with 5 prompts, 7 skills, 0 errors, and 0 warnings. Syntax, ShellCheck, and shfmt gates also exited `0`.

No Bats skip was reported and no platform-specific repository gate from the brief was omitted. Verification ran on the configured Linux host.

### Isolated installed-runtime evidence

Both isolated attempts used a `/tmp/pi-permission-smoke.XXXXXX` root, an absolute temporary `PI_CODING_AGENT_DIR`, temporary HOME/XDG paths, `DOTFILES` pointing to this reviewed worktree, and an EXIT/signal cleanup trap. No apply targeted the production agent directory. The first attempt stopped after Pi installation when mise's npm wrapper tried to reshim against an untrusted production mise config under the overridden HOME; the trap removed the complete temporary root. The successful rerun set the wrapper's documented `MISE_SKIP_RESHIM=1` control and otherwise used the required installation pattern.

The successful isolated run established:

- Pi `0.85.1` and `@gotgenes/pi-permission-system` `29.2.0` were installed into the temporary root.
- No `auth.json` was read, copied, or installed.
- `bin/validate-pi-security-runtime`, using the isolated Pi binary and permission package, exited `0`.
- The installed runtime `.permission` object exactly matched the tracked policy rendered with the isolated agent path.
- Runtime controls were `yoloMode=false`, `debugLog=false`, and `permissionReviewLog=false`.
- The private permission runtime directory was mode `0700`; `config.json` was mode `0644`.
- The exact package gate pipeline exercised 41 tool-call cases: 17 silent allows, 20 intentional asks that reached the prompt spy and terminated blocked after denial, and 4 hard denies that blocked without prompting. These include the representative skill-script, Pi-metadata, external Git diff, named-agent validation, ordinary `curl`, curl authority/mutation, protected redirect, deletion, and privilege cases.
- npm reported 5 dependency audit findings (3 moderate, 2 high) and install-script allowlist notices in the temporary pinned package graph. Pin changes or audit remediation are outside this policy rollout; all temporary package state was removed.
- The trap confirmed cleanup of the failed and successful smoke roots, and no repository package cache, permission log, debug log, or credential artifact was created.

Interactive model-facing main/named-agent smoke is intentionally deferred to the canonical rollout. Direct lexical path checks deny obvious `auth.json` operands, and no agent command read or copied production `auth.json`; those tripwires were not weakened or bypassed, and YOLO was never enabled. The exact installed-package pipeline provides the pre-integration policy evidence without credentials, while post-integration operator smoke remains necessary to prove Copilot-backed session UX.

## Consolidated final polish fix wave

The final polish wave made only the evidence-backed corrections requested after rollout review:

- Pi installation now reuses `bin/lib/artifacts.sh` for portable SHA-256 selection, including the `shasum -a 256` fallback used on macOS.
- Authoritative policy publication checks the snapshotted destination identity before backup and again after backup immediately before the atomic rename. The Bats-only data marker hook exposes both phases without executing marker contents. This remains best-effort because the UI writer shares no lock; a final check/rename race is unavoidable and documented.
- A matching permission-system package version is accepted only when regular schema and manager artifacts exist. An incomplete package is installed once and rejected with both expected paths if it remains incomplete.
- The shared schema validator reports invalid UTF-8 as a controlled, path-prefixed error and sorts validation failures through stringified path components.
- The installed 29.2.0 pipeline harness now asserts the observed exact patterns for primary curl data, upload, method, and authorization asks. Named-agent allow evidence asserts `agentName` plus `origin: agent`; protected-path deny evidence asserts the named scope plus `origin: global`.
- CI installs `python3-jsonschema`, then installs the repository-pinned Pi and permission-system versions beneath `$RUNNER_TEMP` and runs the full validator with explicit absolute package roots. The cache and install prefix are temporary and no Pi runtime directory is selected.
- Active guidance now uses attention/permission-layer terminology, scopes normal active-YOLO refusal separately from legacy retirement, restores rush's mutation-stop instruction, accurately describes selected named-agent mutation rules, and states what the runtime validator actually validates.
- The broad restore ask was replaced by direct and slash-qualified `git restore` and `git -C … restore` tripwires. Later `git -C … commit` allows prevent ordinary commit messages containing “restore” from prompting, while later `git -C … commit --amend` asks preserve the existing history-rewrite tripwire.

### RED evidence

The focused installer run initially exited `1` with all four new regressions failing: a matching partial permission package was accepted, a still-partial reinstall did not fail, the no-`sha256sum` installation failed, and no post-backup test phase existed. The focused permission tests exited `1` because the broad restore key was still present and invalid UTF-8 produced a traceback. The new Python unit test failed with a missing `validation_error_sort_key`, and the installed pipeline failed because a commit message containing “restore” terminated blocked. Each focused suite passed after its minimal implementation.

### Final verification

All final commands exited `0`:

- `make check`: all 522 Bats cases and all 9 Python unit tests passed; syntax, ShellCheck, shfmt, and AI validation gates also passed.
- `bats tests/ai_installers.bats tests/pi_permissions.bats tests/pi_modes.bats tests/check_file_discovery.bats`: `1..88`, all 88 cases passed.
- `bin/validate-pi-security-runtime`: exact schema, deterministic manager, reporter evidence, and full gate pipeline passed.
- `bash bin/validate-ai --verbose`: 5 prompts, 7 skills, 0 errors, 0 warnings, `PASSED`.
- Focused `shellcheck -x -S warning -e SC1091 ai/pi/install.sh` and `shfmt -d -i 2 -ci ai/pi/install.sh tests/ai_installers.bats tests/pi_permissions.bats`: no output.
- A CI-equivalent temporary-prefix install added the exact Pi `0.85.1` and permission-system `29.2.0` packages with scripts disabled; validation with both absolute package roots passed. The temporary package tree and npm cache were removed afterward.
- `git diff --check`: no output.

The local polish-core fix pass removed repeated package-root derivation and found no unresolved correctness issue. No subagent or external reviewer was used. No production Pi runtime, authentication, permission controls, or package inventory was changed.
