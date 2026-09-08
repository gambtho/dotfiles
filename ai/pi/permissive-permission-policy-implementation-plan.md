# Permissive Pi Permission Policy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make routine Pi and subagent shell workflows silent while preserving explicit tripwire prompts and denials, protected-path rules, runtime UI controls, and reliable policy rollout.

**Architecture:** Treat `@gotgenes/pi-permission-system` as an attention filter rather than containment. First add an installed-package gate-pipeline harness, then relax external-directory and generic command policy, repair named-agent composition, and make the repository-owned permission map authoritative without overwriting the runtime-owned YOLO/logging controls.

**Tech Stack:** Bash, Bats, jq, TypeScript executed through Pi's bundled jiti, `@gotgenes/pi-permission-system` 29.2.0, Python `jsonschema` already used by the runtime validator.

**Spec:** `ai/pi/permissive-permission-policy-design.md`

## Global Constraints

- Do not add or integrate a sandbox.
- Keep `permission["*"]` at `ask`; newly introduced extension tools remain untrusted by default.
- Allowed Bash programs retain the invoking user's ambient filesystem, environment, network, and subprocess authority; documentation must say so.
- Preserve explicit credential-path, force-push, hard-reset/clean, root-deletion, privilege-escalation, destructive GitHub API, Git command-execution, and subprocess-capable-search denials.
- Preserve runtime-owned `yoloMode`, `debugLog`, and `permissionReviewLog` values during policy publication.
- Refuse policy publication while runtime YOLO is active and abort on concurrent runtime-config modification.
- Rules are ordered and last-match-wins; broad defaults precede specific asks and denials.
- Curl guarantees cover only the lexical forms enumerated in the spec; do not broaden the shell parser.
- Never use `--no-verify`.

---

## File map

- Create `bin/pi-permission-pipeline-checks.ts`: installed-package full gate-pipeline regression harness and typed case assertions.
- Modify `bin/validate-pi-security-runtime.ts`: load and invoke the pipeline harness in addition to existing manager-level adversarial checks.
- Modify `ai/pi/config/permission-system.json`: permissive external-directory, Git/GitHub, and curl defaults with ordered tripwire overrides.
- Modify `tests/pi_permissions.bats`: configuration invariants and exact rule-order assertions for the new posture.
- Modify `ai/pi/agents/{rush,deep,review}.md`: preserve global protected-path maps and allow unmatched routine Bash while retaining child-specific mutation denials.
- Modify `tests/pi_modes.bats`: frontmatter-shape and read-oriented agent policy assertions.
- Create `bin/validate-pi-permission-config`: shared exact-schema validator used by installation and runtime validation.
- Modify `bin/validate-pi-security-runtime`: delegate schema validation to the shared validator.
- Modify `ai/pi/install.sh`: authoritative permission-map reconciliation with runtime-control preservation, YOLO refusal, backup, and compare-before-publish behavior.
- Modify `tests/ai_installers.bats`: policy publication, runtime-control preservation, active-YOLO refusal, concurrent-change refusal, validation, backup, and idempotence.
- Modify `ai/README.md`: active attention-policy boundary and permission runtime ownership.
- Modify `ai/pi/plugin-security-stack-design.md`: label the superseded mutable-whole-file behavior and point to the current design.
- Create `implementation-notes.md`: RED/GREEN evidence, approved deviations, isolated-smoke results, and final verification record.

---

### Task 1: Add a real permission gate-pipeline harness

**Files:**
- Create: `bin/pi-permission-pipeline-checks.ts`
- Modify: `bin/validate-pi-security-runtime.ts:95-205`
- Test: `tests/pi_permissions.bats`

**Interfaces:**
- Produces: `runPermissionPipelineChecks(options: PipelineCheckOptions): Promise<void>`.
- Consumes: the installed package root, rendered temporary agent directory, repository root, and the existing `PermissionManager`-compatible runtime created by `validate-pi-security-runtime.ts`.
- Later tasks add cases to `BASELINE_PIPELINE_CASES` and `RELAXED_PIPELINE_CASES`; the harness owns prompt/report capture and stage-aware assertions.

- [ ] **Step 1: Create the structural test harness with current-policy passing cases**

Create `bin/pi-permission-pipeline-checks.ts` with structural interfaces so the repository does not compile against unexported package types:

```ts
import { pathToFileURL } from "node:url";

type ExpectedDecision = "allow" | "ask" | "deny";

type PipelineCase = {
  label: string;
  command: string;
  expected: ExpectedDecision;
  agentName?: "rush" | "smart" | "deep" | "review";
  surface?: string;
  pattern?: string;
};

export type PipelineCheckOptions = {
  packageRoot: string;
  agentDir: string;
  repoRoot: string;
};

const BASELINE_PIPELINE_CASES: PipelineCase[] = [
  { label: "ordinary reader", command: "pwd", expected: "allow" },
  {
    label: "recursive deletion asks",
    command: "rm -rf /tmp/pi-permission-example",
    expected: "ask",
    surface: "bash",
    pattern: "rm *",
  },
  {
    label: "privilege escalation denies",
    command: "sudo true",
    expected: "deny",
    surface: "bash",
    pattern: "*sudo *",
  },
];

const url = (root: string, path: string) =>
  pathToFileURL(`${root}/src/${path}`).href;
```

Dynamically import these installed-package modules:

```ts
const [
  { PermissionManager },
  { PermissionResolver },
  { SessionRules },
  { ToolCallGatePipeline },
  { GateRunner },
  { PathNormalizer },
  { posixPathFlavor },
  { resolveToolPreviewLimits },
] = await Promise.all([
  import(url(packageRoot, "permission-manager.ts")),
  import(url(packageRoot, "permission-resolver.ts")),
  import(url(packageRoot, "session-rules.ts")),
  import(url(packageRoot, "handlers/gates/tool-call-gate-pipeline.ts")),
  import(url(packageRoot, "handlers/gates/runner.ts")),
  import(url(packageRoot, "path-normalizer.ts")),
  import(url(packageRoot, "path/path-flavor.ts")),
  import(url(packageRoot, "tool-preview-formatter.ts")),
]);
```

For each case, create a fresh manager, resolver, session rules, path normalizer, pipeline, and runner. Capture prompts and decision events; make the prompter deny asks so terminal behavior is deterministic:

```ts
const prompts: Array<Record<string, unknown>> = [];
const decisions: Array<Record<string, unknown>> = [];
const logs: Array<{ event: string; details: Record<string, unknown> }> = [];

const prompter = {
  async escalate(details: Record<string, unknown>) {
    prompts.push(details);
    return {
      approved: false,
      state: "denied" as const,
      decidedBy: { kind: "user" as const, via: "dialog" as const },
    };
  },
};
const reporter = {
  writeReviewLog(event: string, details: Record<string, unknown>) {
    logs.push({ event, details });
  },
  emitDecision(event: Record<string, unknown>) {
    decisions.push(event);
  },
};
```

Build `ToolCallGateInputs` structurally:

```ts
const inputs = {
  getActiveSkillEntries: () => [],
  getInfrastructureReadDirs: () => [],
  getToolPreviewLimits: () => resolveToolPreviewLimits(),
  getPathNormalizer: () => normalizer,
  getShellToolAliases: () => undefined,
};
```

Assert the two-stage contract:

- expected `allow`: terminal `outcome.action === "allow"`, no prompt;
- expected `ask`: terminal block after the denying prompt spy, exactly one prompt;
- expected `deny`: terminal block without a prompt;
- `surface`/`pattern`: read from the prompt payload for asks and from the policy-denied review/decision evidence for denies.

Throw errors prefixed with `pipeline <label>:` so Bats output identifies the exact case.

- [ ] **Step 2: Call the harness from the runtime validator**

Add the import near the top of `bin/validate-pi-security-runtime.ts`:

```ts
import { runPermissionPipelineChecks } from "./pi-permission-pipeline-checks.ts";
```

After `manager.configureForCwd(repoRoot)` and the existing config-issue check, call:

```ts
await runPermissionPipelineChecks({ packageRoot, agentDir, repoRoot });
```

Keep the existing direct manager checks; they remain useful for exhaustive rule-level adversarial cases.

- [ ] **Step 3: Run the focused validator and Bats wrapper**

Run:

```bash
bin/validate-pi-security-runtime
bats tests/pi_permissions.bats
```

Expected: `Pi permission schema and deterministic engine validation passed.` and 10 passing Bats tests. If a structural package interface differs, correct the harness against the installed 29.2.0 source rather than weakening assertions.

- [ ] **Step 4: Commit the harness**

```bash
git add bin/pi-permission-pipeline-checks.ts bin/validate-pi-security-runtime.ts
git commit -m "test: exercise Pi permission gate pipeline"
```

---

### Task 2: Add failing regressions for the approved permissive behavior

**Files:**
- Modify: `bin/pi-permission-pipeline-checks.ts`
- Modify: `bin/validate-pi-security-runtime.ts:219-460`

**Interfaces:**
- Consumes: `runPermissionPipelineChecks` from Task 1.
- Produces: failing behavioral cases that Tasks 3 and 4 make green.

- [ ] **Step 1: Add global false-prompt and curl cases**

Add `RELAXED_PIPELINE_CASES`:

```ts
const RELAXED_PIPELINE_CASES: PipelineCase[] = [
  {
    label: "referenced skill script",
    command: "node ~/.agents/skills/impeccable/scripts/load-context.mjs",
    expected: "allow",
  },
  {
    label: "Pi metadata jq read",
    command:
      "jq -r '.version' ~/.pi/agent/npm/node_modules/@gotgenes/pi-permission-system/package.json",
    expected: "allow",
  },
  {
    label: "external git diff",
    command:
      "git diff --no-index ai/pi/config/permission-system.json ~/.pi/agent/extensions/pi-permission-system/config.json",
    expected: "allow",
  },
  {
    label: "ordinary curl GET",
    command: "curl https://example.com/data.json",
    expected: "allow",
  },
  {
    label: "slash-qualified curl GET",
    command: "/usr/bin/curl https://example.com/data.json",
    expected: "allow",
  },
  {
    label: "curl data asks",
    command: "curl --data payload https://example.com/items",
    expected: "ask",
    surface: "bash",
  },
  {
    label: "curl upload asks",
    command: "curl https://example.com/items -T artifact.zip",
    expected: "ask",
    surface: "bash",
  },
  {
    label: "curl mutating method asks",
    command: "curl -X DELETE https://example.com/items/1",
    expected: "ask",
    surface: "bash",
  },
  {
    label: "curl authorization asks",
    command: "curl -H 'Authorization: Bearer example' https://example.com/private",
    expected: "ask",
    surface: "bash",
  },
];
```

Create the skill-script and Pi metadata fixture paths under the validator's temporary agent/home layout before running the cases, so Bash path projection sees existing files where relevant. Do not execute the commands; only the permission pipeline parses them.

- [ ] **Step 2: Add the Git `-c` collision regression**

Add the configurable policy collision that this repository can resolve without weakening protected `.env` paths:

```ts
{
  label: "git switch subcommand c is not global config",
  command: "git switch -c feature/example",
  expected: "allow",
},
```

Do not add an allow override for arbitrary inline source containing `process.env`: package 29.2.0 may classify such source as a path matching `*.env.*`, and weakening that deny would conflict with the approved protected-path priority. Record the observed package behavior in `implementation-notes.md` as an upstream parser limitation; this implementation does not claim to solve it.

- [ ] **Step 3: Verify RED**

Run:

```bash
bin/validate-pi-security-runtime
```

Expected: FAIL on the first newly expected allow under the old policy, with a message prefixed `pipeline referenced skill script:`. Record all failing labels in `implementation-notes.md` before changing policy.

- [ ] **Step 4: Record RED and continue directly to Task 3**

Create `implementation-notes.md` with the exact command, failing label, deciding surface, and matched rule. Leave the failing regression changes uncommitted and proceed directly to Task 3; do not create a commit whose focused validation is known to fail.

---

### Task 3: Relax the global policy while retaining ordered tripwires

**Files:**
- Modify: `ai/pi/config/permission-system.json:71-114,144-460`
- Modify: `tests/pi_permissions.bats:70-194`
- Modify: `bin/validate-pi-security-runtime.ts:230-460`

**Interfaces:**
- Consumes: pipeline cases from Task 2.
- Produces: repository-owned global policy with permissive external access, unmatched Git/GitHub/curl behavior, and explicit later asks/denies.

- [ ] **Step 1: Update Bats invariants first**

Change the external-directory assertions to require both catch-alls to be `allow` while retaining explicit path denies:

```jq
.permission.external_directory_read["*"] == "allow"
and .permission.external_directory_write["*"] == "allow"
```

Change Bash assertions to require:

```jq
$bash["*"] == "allow"
and ($bash | has("git *") | not)
and ($bash | has("*/git *") | not)
and ($bash | has("gh *") | not)
and ($bash | has("*/gh *") | not)
and $bash["curl *"] == "allow"
and $bash["*/curl *"] == "allow"
```

Add ordered-rule assertions using `keys_unsorted | index(...)` so every curl ask/deny pattern appears after both broad curl allows.

- [ ] **Step 2: Verify the configuration test is RED**

Run:

```bash
bats tests/pi_permissions.bats
```

Expected: failure in the path-policy and Bash-policy tests because the tracked baseline still asks.

- [ ] **Step 3: Change external-directory defaults**

In `ai/pi/config/permission-system.json`, set both directional external catch-alls to `allow`. Keep the existing explicit root entries temporarily; they are harmless documentation under an allow catch-all and can be removed only in a later simplification after behavior is stable.

- [ ] **Step 4: Remove broad Git and GitHub asks**

Delete these four entries:

```json
"git *": "ask",
"*/git *": "ask",
"gh *": "ask",
"*/gh *": "ask"
```

Retain every later Git/GitHub ask and deny. Keep ordinary `git`, slash-qualified Git, `gh`, and slash-qualified `gh` governed by Bash `"*": "allow"` unless a specific later pattern matches.

- [ ] **Step 5: Narrow the Git global `-c` deny without matching subcommand flags**

Remove the broad pattern that matches a subcommand's own `-c` option:

```json
"*git * -c *": "deny"
```

Retain leading global-option denials such as:

```json
"*git -c *": "deny",
"*git --config-env=*": "deny"
```

and their slash-qualified coverage. Add direct manager cases for `git -c core.sshCommand=false fetch origin` and slash-qualified leading `-c` forms so the policy-bypass deny remains proven while `git switch -c feature/example` allows.

- [ ] **Step 6: Allow curl and add bounded later asks**

Change the broad rules to:

```json
"curl *": "allow",
"*/curl *": "allow"
```

After all broad curl/local-host allows, add conventional lexical asks. Use explicit entries rather than a generated parser, for example:

```json
"*curl *--data *": "ask",
"*curl *--data=*": "ask",
"*curl *--data-raw *": "ask",
"*curl *--data-binary *": "ask",
"*curl *--data-urlencode *": "ask",
"*curl *-d *": "ask",
"*curl *--form *": "ask",
"*curl *-F *": "ask",
"*curl *--upload-file *": "ask",
"*curl *-T *": "ask",
"*curl *--request POST*": "ask",
"*curl *--request PUT*": "ask",
"*curl *--request PATCH*": "ask",
"*curl *--request DELETE*": "ask",
"*curl *-X POST*": "ask",
"*curl *-X PUT*": "ask",
"*curl *-X PATCH*": "ask",
"*curl *-X DELETE*": "ask",
"*curl *Authorization:*": "ask",
"*curl *--user *": "ask",
"*curl *-u *": "ask",
"*curl *--cookie *": "ask",
"*curl *--cert *": "ask",
"*curl *--key *": "ask",
"*curl *--netrc*": "ask"
```

Add lower-case method variants explicitly. Add only forms covered by the approved spec and tests; do not attempt shell-token normalization in JSON patterns. Keep existing destructive API denials later than these asks.

Add explicit asks for bare receiving shells (`sh`, `bash`, `zsh`, `dash`, `ksh`) if the package's command-unit text exposes them without matching ordinary `bash path/to/script`; prove this distinction in the pipeline cases before retaining the rules.

- [ ] **Step 7: Update direct manager expectations**

In `bin/validate-pi-security-runtime.ts`, update direct checks for ordinary curl, slash-qualified curl, external read/write, and unmatched Git/GitHub commands. Add all guaranteed curl ask forms and retain the explicit tripwire matrix:

```ts
await checkBashGate("rm -rf ./build", "ask");
await checkBashGate("rm -rf /", "deny");
await checkBashGate("sudo true", "deny");
await checkBashGate("doas true", "deny");
await checkBashGate("git reset --hard HEAD~1", "deny");
await checkBashGate("git clean -ffdx", "deny");
await checkBashGate("git push --force origin main", "deny");
await checkBashGate("gh repo delete owner/name --yes", "deny");
```

Keep the existing Git external-command (`--ext-diff`, `--textconv`), search subprocess (`grep -O`, `--open-files-in-pager`), credential-path, and mutating GitHub API cases alongside this matrix.

- [ ] **Step 8: Run focused GREEN verification**

Run:

```bash
bats tests/pi_permissions.bats
bin/validate-pi-security-runtime
```

Expected: all Bats tests pass and every pipeline case introduced so far is green. Named-agent routine cases are introduced only in Task 4, so this task must not end with known focused failures.

- [ ] **Step 9: Commit global policy behavior**

```bash
git add ai/pi/config/permission-system.json tests/pi_permissions.bats bin/validate-pi-security-runtime.ts bin/pi-permission-pipeline-checks.ts implementation-notes.md
git commit -m "fix: make routine Pi shell access permissive"
```

---

### Task 4: Repair named-agent composition and routine command behavior

**Files:**
- Modify: `ai/pi/agents/rush.md:1-89`
- Modify: `ai/pi/agents/deep.md:1-88`
- Modify: `ai/pi/agents/review.md:1-88`
- Modify: `tests/pi_modes.bats:60-122`
- Test: `bin/pi-permission-pipeline-checks.ts`

**Interfaces:**
- Consumes: global protected-path maps and permissive Bash defaults from Task 3.
- Produces: read-oriented agent frontmatter that preserves global path denials and blocks recognizable mutations without forwarding routine prompts.

- [ ] **Step 1: Change frontmatter tests and add named-agent pipeline regressions first**

For `rush`, `deep`, and `review`, update `tests/pi_modes.bats` to assert:

```jq
(.permission | has("path_write") | not)
and .permission.write == "deny"
and .permission.edit == "deny"
and .permission.bash["*"] == "allow"
and .permission.bash["*git *"] == "deny"
and .permission.bash["*$*"] == "deny"
```

Retain the complete existing lists of Git/GitHub read allows and mutation/bypass denies. Update the test name and prose expectation from secure read-only enforcement to direct-tool and recognizable-mutation restriction.

In `bin/pi-permission-pipeline-checks.ts`, add for each of `rush`, `deep`, and `review`:

```ts
RELAXED_PIPELINE_CASES.push(
  { label: `${agentName} nl inspection`, command: "nl -ba ai/pi/install.sh", agentName, expected: "allow" },
  { label: `${agentName} ai check`, command: "make ai-check", agentName, expected: "allow" },
  { label: `${agentName} validator`, command: "bash bin/validate-ai --verbose", agentName, expected: "allow" },
  {
    label: `${agentName} protected redirect`,
    command: "printf x > ~/.ssh/config",
    agentName,
    expected: "deny",
    surface: "path_write",
    pattern: "~/.ssh/*",
  },
);
```

Add direct manager checks for `path_write` under every named-agent scope to prove the global protected maps survive composition.

- [ ] **Step 2: Verify RED**

Run:

```bash
bats tests/pi_modes.bats
```

Expected: the read-oriented agent policy test fails on `path_write` and Bash `"*"`.

- [ ] **Step 3: Update all three agent definitions consistently**

In `rush.md`, `deep.md`, and `review.md`:

- remove `path_write: allow`;
- change the Bash catch-all from `ask` to `allow`;
- retain `write: deny`, `edit: deny`, `*git *: deny`, the narrow Git/GitHub read allows, command-execution denies, remote mutation denies, and `*$*: deny`;
- replace absolute “read-only” prose with:

```md
Use built-in read/search tools first. Direct mutation tools and recognizable
repository or remote mutations are denied. Routine inspection and verification
commands run without parent approval, but allowed Bash programs are not OS-contained
and may have effects this lexical policy cannot observe.
```

Keep each agent's role-specific opening sentence.

- [ ] **Step 4: Run named-agent and pipeline verification**

Run:

```bash
bats tests/pi_modes.bats
bin/validate-pi-security-runtime
```

Expected: named-agent `nl`, `make ai-check`, and `bash bin/validate-ai --verbose` cases allow; protected redirects deny without prompting; direct write/edit remain denied.

- [ ] **Step 5: Commit named-agent policy**

```bash
git add ai/pi/agents/rush.md ai/pi/agents/deep.md ai/pi/agents/review.md tests/pi_modes.bats bin/pi-permission-pipeline-checks.ts
git commit -m "fix: stop routine subagent permission prompts"
```

---

### Task 5: Extract exact permission-schema validation

**Files:**
- Create: `bin/validate-pi-permission-config`
- Modify: `bin/validate-pi-security-runtime:37-89`
- Modify: `tests/pi_permissions.bats:258-280`

**Interfaces:**
- Produces CLI: `bin/validate-pi-permission-config --schema PATH --config PATH`.
- Returns 0 for a valid config; returns nonzero with `error: permission schema <path>: <message>` for schema/config errors or a clear missing-`jsonschema` dependency error.
- Task 6's installer calls this CLI on a staged effective candidate before publication.

- [ ] **Step 1: Add failing CLI tests**

Extend `tests/pi_permissions.bats` with temporary schema/config fixtures:

```bash
@test "Pi permission config validator accepts valid config and rejects invalid config" {
  local schema="$TEST_ROOT/schema.json" valid="$TEST_ROOT/valid.json" invalid="$TEST_ROOT/invalid.json"
  printf '%s\n' '{"$schema":"https://json-schema.org/draft/2020-12/schema","type":"object","required":["permission"],"properties":{"permission":{"type":"object"}}}' >"$schema"
  printf '%s\n' '{"permission":{}}' >"$valid"
  printf '%s\n' '[]' >"$invalid"

  run "$REPO_ROOT/bin/validate-pi-permission-config" --schema "$schema" --config "$valid"
  [ "$status" -eq 0 ]
  run "$REPO_ROOT/bin/validate-pi-permission-config" --schema "$schema" --config "$invalid"
  [ "$status" -ne 0 ]
  [[ "$output" == *"permission schema"* ]]
}
```

- [ ] **Step 2: Verify RED**

Run:

```bash
bats tests/pi_permissions.bats
```

Expected: failure because `bin/validate-pi-permission-config` does not exist.

- [ ] **Step 3: Extract the existing Python validator**

Create executable `bin/validate-pi-permission-config` with strict option parsing and the existing Draft 2020-12 validation logic from `bin/validate-pi-security-runtime`:

```python
#!/usr/bin/env python3
import argparse
import json
import sys

try:
    from jsonschema import Draft202012Validator
except ImportError:
    print("error: Python jsonschema is required for Pi permission validation", file=sys.stderr)
    raise SystemExit(1)

parser = argparse.ArgumentParser()
parser.add_argument("--schema", required=True)
parser.add_argument("--config", required=True)
args = parser.parse_args()

with open(args.schema, encoding="utf-8") as stream:
    schema = json.load(stream)
with open(args.config, encoding="utf-8") as stream:
    config = json.load(stream)

Draft202012Validator.check_schema(schema)
errors = sorted(
    Draft202012Validator(schema).iter_errors(config),
    key=lambda item: list(item.path),
)
for error in errors:
    location = ".".join(str(part) for part in error.path) or "<root>"
    print(f"error: permission schema {location}: {error.message}", file=sys.stderr)
if errors:
    raise SystemExit(1)
```

Wrap schema/config loading and schema checking in an explicit expected-error boundary:

```python
try:
    with open(args.schema, encoding="utf-8") as stream:
        schema = json.load(stream)
    with open(args.config, encoding="utf-8") as stream:
        config = json.load(stream)
    Draft202012Validator.check_schema(schema)
except (OSError, json.JSONDecodeError, ValueError) as error:
    print(f"error: {error}", file=sys.stderr)
    raise SystemExit(1)
```

Do not emit Python tracebacks for expected missing or invalid inputs.

- [ ] **Step 4: Reuse the CLI from the runtime validator**

Replace the inline Python heredoc in `bin/validate-pi-security-runtime` with:

```bash
"$ROOT/bin/validate-pi-permission-config" \
  --schema "$schema_file" \
  --config "$config_file"
```

Keep the package-presence and bundled-jiti checks before it.

- [ ] **Step 5: Run focused verification**

```bash
bats tests/pi_permissions.bats
bin/validate-pi-security-runtime
```

Expected: all tests pass and runtime validation still prints its success line.

- [ ] **Step 6: Commit shared schema validation**

```bash
git add bin/validate-pi-permission-config bin/validate-pi-security-runtime tests/pi_permissions.bats
git commit -m "refactor: share Pi permission schema validation"
```

---

### Task 6: Make the tracked permission map authoritative without losing runtime controls

**Files:**
- Modify: `ai/pi/install.sh:132-231,537-609`
- Modify: `tests/ai_installers.bats:18-70,321-420,475-540`
- Test: `bin/validate-pi-permission-config`

**Interfaces:**
- Produces shell function `reconcile_permission_policy SOURCE DESTINATION PACKAGE_ROOT`.
- Preserves exactly `yoloMode`, `debugLog`, and `permissionReviewLog` from a valid existing runtime config.
- Refuses replacement when runtime `yoloMode` is true.
- Uses SHA-256 compare-before-publish to reject concurrent runtime mutation.
- Validates the staged effective candidate against `PACKAGE_ROOT/schemas/permissions.schema.json` before backup/publication.

- [ ] **Step 1: Update installer fixtures and write RED tests**

Change `seed_mutable_pi_drift` to create a schema-valid runtime policy with distinctive UI controls:

```bash
jq '
  .debugLog = true
  | .permissionReviewLog = true
  | .yoloMode = false
  | .permission.bash["*"] = "ask"
  | .custom = "permission"
' "$REPO_ROOT/ai/pi/config/permission-system.json" \
  >"$agent_dir/extensions/pi-permission-system/config.json"
```

Add tests asserting normal installation:

- replaces `.permission` with the rendered tracked map;
- preserves all three runtime UI booleans;
- removes the unowned `.custom` drift;
- creates exactly one permission backup;
- leaves other mutable files preserved;
- is idempotent on a second run.

Add separate tests for:

```text
active yoloMode=true                 → nonzero, actionable "disable YOLO" message, no mutation
invalid tracked candidate            → nonzero, runtime unchanged, no backup
runtime changes before publication   → nonzero, "changed during reconciliation", runtime change preserved
foreign symlink / invalid type       → existing refusal behavior unchanged
```

Extend `stub_existing_pi` so installing the permission package creates a test schema at `schemas/permissions.schema.json`; use a Draft 2020-12 schema that validates the fixture shape. Do not copy the developer machine's installed package into tests.

- [ ] **Step 2: Verify RED**

Run only the new installer tests by name:

```bash
bats --filter 'permission policy|YOLO|concurrent runtime' tests/ai_installers.bats
```

Expected: failures because the installer still preserves whole-file drift.

- [ ] **Step 3: Add effective-candidate rendering helpers**

In `ai/pi/install.sh`, add:

```bash
permission_candidate_contents() {
  local source=$1 destination=$2 rendered
  rendered=$(rendered_baseline_contents "$source")
  if [[ ! -f "$destination" ]]; then
    printf '%s\n' "$rendered"
    return
  fi
  jq -s '
    .[0] as $baseline | .[1] as $runtime
    | $baseline + {
        debugLog: $runtime.debugLog,
        permissionReviewLog: $runtime.permissionReviewLog,
        yoloMode: $runtime.yoloMode
      }
  ' <(printf '%s\n' "$rendered") "$destination"
}
```

Before using runtime values, require all three fields to be booleans. Treat an invalid existing runtime file as a migration case: back it up and publish the tracked baseline with its non-YOLO controls rather than attempting to preserve malformed values. Keep the existing sandbox-retirement reset behavior for legacy installations.

- [ ] **Step 4: Implement dedicated reconciliation**

Implement `reconcile_permission_policy` by following the existing foreign-symlink/type checks and atomic publication helpers, but with this sequence:

1. inspect or migrate recognized legacy links;
2. refuse a valid runtime file whose `yoloMode` is true;
3. record `sha256sum` of the valid runtime snapshot;
4. render the effective candidate into a sibling temporary file;
5. validate it with `bin/validate-pi-permission-config` and the exact installed schema;
6. immediately re-hash the runtime path and abort if it changed;
7. if candidate equals runtime, report already current and remove the candidate;
8. otherwise back up runtime once and atomically publish candidate mode `0644`;
9. report the backup path.

Expose a Bats-only hook immediately before the re-hash, guarded by `PI_AI_TEST_PERMISSION_BEFORE_PUBLISH`, so the concurrent-change test can replace the file deterministically. Reject this variable outside the test environment using the repository's existing test-hook conventions.

- [ ] **Step 5: Reorder installer operations safely**

The exact installed package schema must exist before authoritative publication. Preserve the legacy sandbox-retirement safety sequence, then:

1. create the private permission runtime directory;
2. run `reset_permission_policy_for_sandbox_retirement` before removing an old sandbox package inventory;
3. reconcile tracked `settings.json` packages;
4. run `ensure_pinned_npm_packages`;
5. call `reconcile_permission_policy` with the installed permission package root;
6. reconcile the remaining mutable files;
7. run `pi update --extensions`.

Remove the earlier generic `reconcile_mutable_file` call for permission config. Ensure check mode reports the authoritative policy action without installing packages or mutating files; it may validate against the installed schema when present and should fail clearly when apply mode cannot obtain the pinned package.

- [ ] **Step 6: Make the full installer suite GREEN**

Run:

```bash
bats tests/ai_installers.bats
bats tests/pi_permissions.bats
bash ai/pi/install.sh --check
```

Expected: all Bats tests pass; check mode reports whether permission policy would be published and performs no writes.

- [ ] **Step 7: Commit policy reconciliation**

```bash
git add ai/pi/install.sh tests/ai_installers.bats implementation-notes.md
git commit -m "fix: publish tracked Pi permission policy safely"
```

---

### Task 7: Update active documentation and perform isolated rollout verification

**Files:**
- Modify: `ai/README.md:45-80,89-125`
- Modify: `ai/pi/plugin-security-stack-design.md:1-20,260-280`
- Modify: `ai/pi/permissive-permission-policy-design.md` only if implementation evidence required an approved deviation
- Modify: `implementation-notes.md`

**Interfaces:**
- Consumes: final policy and installer behavior from Tasks 3-6.
- Produces: accurate operator documentation, isolated installed-runtime proof, and final verification record.

- [ ] **Step 1: Update active security-boundary documentation**

In `ai/README.md`, describe the policy as an attention/tripwire layer and state explicitly:

```md
Allowed Bash processes are not OS-contained. They retain the invoking user's
ambient filesystem, environment, network, and subprocess authority. Path and
command rules reduce accidental access and route attention; they do not contain
hostile or interpreter-generated behavior.
```

Update the mutable-runtime table so permission policy says:

```text
repository-owned permission map is republished on make ai; valid runtime yoloMode,
debugLog, and permissionReviewLog values are preserved; publication refuses active YOLO
```

Document ordinary curl allowance and the bounded upload/auth/mutation tripwires. Document rollback through the generated permission-config backup.

In `ai/pi/plugin-security-stack-design.md`, keep the historical account but point its superseded mutable-policy decision to the current spec and implementation behavior.

- [ ] **Step 2: Run repository validation**

Run:

```bash
bash bin/validate-ai --verbose
bats tests/pi_permissions.bats
bats tests/pi_modes.bats
bats tests/ai_installers.bats
bin/validate-pi-security-runtime
make ai-check
make check
```

Expected: all commands exit 0. Record exact test counts and any intentionally skipped platform checks in `implementation-notes.md`.

- [ ] **Step 3: Perform isolated installation**

Create an isolated test root outside the primary checkout and use the documented pre-integration pattern:

```bash
SMOKE_HOME=$(mktemp -d /tmp/pi-permission-smoke.XXXXXX)
PI_CODING_AGENT_DIR="$SMOKE_HOME/.pi/agent" \
HOME="$SMOKE_HOME" \
XDG_CONFIG_HOME="$SMOKE_HOME/.config" \
DOTFILES="$PWD" \
bash ai/pi/install.sh
```

Agents must not read or copy production authentication into the isolated root. Run the isolated installation and installed-package gate pipeline without credentials. Defer interactive model-facing main and named-agent smoke to the canonical rollout, where the operator provisions authentication outside agent-issued commands. Do not point apply mode at the production agent directory from the worktree.

Verify:

```bash
PI_CODING_AGENT_DIR="$SMOKE_HOME/.pi/agent" bin/validate-pi-security-runtime
```

Compare the installed runtime `.permission` object with the rendered tracked policy and assert the three runtime controls have expected values.

- [ ] **Step 4: Defer model-facing calls to the canonical rollout**

After the operator provisions authentication outside agent-issued commands, start canonical Pi with the pinned package set and run the regression corpus through real main and named-agent sessions without YOLO. Confirm no approval appears for:

```text
node referenced-skill script
jq Pi metadata read
git diff external runtime file
nl under deep
make ai-check under deep
bash bin/validate-ai under deep
ordinary curl GET
```

Confirm prompts/denials still appear for the explicit tripwire matrix. Record observed surface and rule for any unexpected prompt; do not add an exception without root-cause analysis. The credential-free isolated installed-package pipeline remains the pre-integration proof; model-facing UX is not claimed until this operator-provisioned canonical smoke completes.

- [ ] **Step 5: Clean up smoke state and inspect final diff**

```bash
rm -rf -- "$SMOKE_HOME"
git status --short
git diff --check
git diff origin/main...HEAD --stat
git diff origin/main...HEAD
```

Confirm there are no credentials, generated package caches, debug logs, smoke artifacts, placeholders, or unrelated edits.

- [ ] **Step 6: Commit documentation and verification notes**

```bash
git add ai/README.md ai/pi/plugin-security-stack-design.md implementation-notes.md
git commit -m "docs: explain permissive Pi permission boundary"
```

- [ ] **Step 7: Run final fresh verification**

After the final commit, rerun:

```bash
bash bin/validate-ai --verbose
bats tests/pi_permissions.bats tests/pi_modes.bats tests/ai_installers.bats
bin/validate-pi-security-runtime
make check
git status --short
```

Expected: all validation exits 0 and `git status --short` is empty.
