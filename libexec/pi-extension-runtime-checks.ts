// No-paid-provider integration gate. Runs only with explicitly selected installed
// packages in an isolated HOME; the SDK, Codemode, hooks and child runtime are real.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, realpathSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, join, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import type { ExtensionAPI, ExtensionUIContext, ExtensionError, ProviderModelConfig, ToolCallEvent, ToolResultEvent, ToolExecutionStartEvent, ToolExecutionUpdateEvent, ToolExecutionEndEvent } from "@earendil-works/pi-coding-agent";
import type { AssistantMessage, ToolCall } from "@earendil-works/pi-ai";
import type { PermissionDecisionEvent, PermissionUiPromptEvent } from "@gotgenes/pi-permission-system";
import type { SubagentsService } from "@gotgenes/pi-subagents";

type EvidenceEntry = { sessionId: string } & (ToolCallEvent | ToolResultEvent | ToolExecutionStartEvent | ToolExecutionUpdateEvent | ToolExecutionEndEvent | { type: "loadout"; active: string[]; all: string[] } | { type: "permission_decision"; decision: PermissionDecisionEvent } | { type: "permission_prompt"; prompt: PermissionUiPromptEvent });

const metadataCommands = ["printenv PI_PROVIDER PI_MODEL", "printenv HERDR_PANE_ID HERDR_WORKSPACE_ID"];
const permissionFailure = /Denied by policy|requires approval|no interactive UI|Script failed/;

function option(name: string): string {
  const index = process.argv.indexOf(name);
  const value = process.argv[index + 1];
  assert.ok(index !== -1 && value?.startsWith("/"), `${name} requires an absolute path`);
  return resolve(value);
}

const hostRoot = option("--pi-package-root");
const permissionRoot = option("--package-root");
const subagentsRoot = option("--subagents-root");
const lspRoot = option("--lsp-root");
const repoRoot = option("--repo-root");
const home = process.env.HOME;
assert.ok(home);
assert.ok(home === resolve(home) && /^pi-native-test-[A-Za-z0-9]{6}$/.test(basename(home))
  && realpathSync(home) === join(realpathSync(tmpdir()), basename(home)),
  "launch through the isolated test wrapper");
const agentDir = join(home, "agent");
assert.equal(process.env.PI_CODING_AGENT_DIR, agentDir);
const hostEntry = join(hostRoot, "dist/index.js");
const sdk: typeof import("@earendil-works/pi-coding-agent") = await import(pathToFileURL(hostEntry).href);
const ai: typeof import("@earendil-works/pi-ai") = await import(import.meta.resolve("@earendil-works/pi-ai", pathToFileURL(hostEntry).href));
const primary = join(home, "primary");
const linked = join(home, "linked");
const evidencePath = join(home, "native-events.jsonl");
mkdirSync(primary);
mkdirSync(join(agentDir, "extensions"), { recursive: true });
mkdirSync(join(agentDir, "agents"), { recursive: true });
mkdirSync(join(agentDir, "npm/node_modules/@gotgenes"), { recursive: true });
symlinkSync(permissionRoot, join(agentDir, "npm/node_modules/@gotgenes/pi-permission-system"));
symlinkSync(subagentsRoot, join(agentDir, "npm/node_modules/@gotgenes/pi-subagents"));

function git(...args: string[]): string {
  return execFileSync("/usr/bin/git", ["-C", primary, ...args], { encoding: "utf8" }).trim();
}
git("init", "-q");
// Temporary Git objects only: never stage or commit in the product repository.
const tree = execFileSync("/usr/bin/git", ["-C", primary, "hash-object", "-w", "-t", "tree", "--stdin"], { input: "", encoding: "utf8" }).trim();
const commit = execFileSync("/usr/bin/git", ["-C", primary, "commit-tree", tree], {
  input: "native fixture\n", encoding: "utf8",
  env: { ...process.env, GIT_AUTHOR_NAME: "Fixture", GIT_COMMITTER_NAME: "Fixture", GIT_AUTHOR_EMAIL: "fixture@example.invalid", GIT_COMMITTER_EMAIL: "fixture@example.invalid" },
}).trim();
git("update-ref", "HEAD", commit);
git("worktree", "add", "-q", "-b", "native-fixture", linked);
symlinkSync(primary, join(linked, "primary"));
writeFileSync(join(linked, "README.md"), "native-readable-decoy\n");
writeFileSync(join(primary, "edit.txt"), "original\n");
writeFileSync(join(primary, "fix.ts"), "original\n");
writeFileSync(join(linked, ".env"), "FAKE_SECRET=not-for-models\n");
writeFileSync(join(primary, ".env"), "FAKE_PRIMARY_SECRET=not-for-models\n");
process.chdir(linked);

const baseline = JSON.parse(readFileSync(join(repoRoot, "ai/pi/config/permission-system.json"), "utf8"));
assert.equal(baseline.permission.codemode, "allow", "enable the authored outer tool only after native child enforcement proof");
const rendered = JSON.parse(JSON.stringify(baseline).replaceAll("__PI_AGENT_DIR__", agentDir));
mkdirSync(join(agentDir, "extensions/pi-permission-system"));
writeFileSync(join(agentDir, "extensions/pi-permission-system/config.json"), JSON.stringify(rendered));
const children = ["rush", "smart", "inspector", "deep", "review"];
for (const name of children) {
  const authored = readFileSync(join(repoRoot, `ai/pi/agents/${name}.md`), "utf8");
  writeFileSync(join(agentDir, `agents/${name}.md`), authored);
}
const subagentSettings = JSON.parse(readFileSync(join(repoRoot, "ai/pi/config/subagents.json"), "utf8"));
subagentSettings.excludedExtensionPackages.push(lspRoot);
writeFileSync(join(agentDir, "subagents.json"), JSON.stringify(subagentSettings));
writeFileSync(join(agentDir, "pi-lsp.json"), JSON.stringify({ servers: {} }));
symlinkSync(join(repoRoot, "ai/pi/extensions/worktree-guard.ts"), join(agentDir, "extensions/worktree-guard.ts"));
// An ordinary fixture extension observes the real hook stream in parent AND
// native children. It neither gates nor executes nested calls itself.
writeFileSync(join(agentDir, "extensions/00-native-observer.ts"), `
import { appendFileSync } from "node:fs";
import { Type } from "typebox";
import { getSubagentsService } from ${JSON.stringify(pathToFileURL(join(subagentsRoot, "src/service/service.ts")).href)};
export default function(pi) {
  let sessionContext;
  pi.on("session_start", (_, ctx) => {
    sessionContext = ctx;
    pi.events.emit("fixture:subagents-service", getSubagentsService());
  });
  const log = (entry, ctx) => appendFileSync(${JSON.stringify(evidencePath)}, JSON.stringify({ ...entry, sessionId: ctx.sessionManager.getSessionId() }) + "\\n");
  pi.events.on("permissions:decision", decision => { if (sessionContext) log({ type: "permission_decision", decision }, sessionContext); });
  pi.events.on("permissions:ui_prompt", prompt => { if (sessionContext) log({ type: "permission_prompt", prompt }, sessionContext); });
  pi.registerTool({ name: "unknown_child_tool", label: "Decoy", description: "Must not reach a child", parameters: Type.Object({}), execute: async () => ({ content: [{type: "text", text: "unknown-tool-executed"}], details: undefined }) });
  pi.on("before_agent_start", (_, ctx) => log({ type: "loadout", active: pi.getActiveTools(), all: pi.getAllTools().map(t => t.name) }, ctx));
  pi.on("tool_call", (event, ctx) => log(event, ctx));
  pi.on("tool_result", (event, ctx) => log(event, ctx));
  for (const name of ["tool_execution_start", "tool_execution_update", "tool_execution_end"]) pi.on(name, (event, ctx) => log(event, ctx));
}
`);

const authoredSettings = JSON.parse(readFileSync(join(repoRoot, "ai/pi/settings.json"), "utf8"));
assert.equal(authoredSettings.codemode.mode, "on");
const settings = {
  defaultProvider: "native-fixture", defaultModel: "scripted", defaultThinkingLevel: "off",
  defaultTools: authoredSettings.defaultTools, codemode: { ...authoredSettings.codemode, inlineBudget: 100 },
  compaction: { enabled: false }, retry: { enabled: false }, cacheWarming: "off",
  enableInstallTelemetry: false,
  packages: [permissionRoot, subagentsRoot, lspRoot],
} satisfies Parameters<typeof sdk.SettingsManager.inMemory>[0];
writeFileSync(join(agentDir, "settings.json"), JSON.stringify(settings));
const settingsManager = sdk.SettingsManager.inMemory(settings, { projectTrusted: false });
const modelRuntime = await sdk.ModelRuntime.create({
  credentials: new ai.InMemoryCredentialStore(), modelsPath: null,
  modelsStore: new ai.InMemoryModelsStore(), refreshOnCreate: false, allowModelNetwork: false,
});
const prompts: PermissionUiPromptEvent[] = [];
const decisions: PermissionDecisionEvent[] = [];
const childIds = new Map<string, string>();
const childModels = new Map<string, string>();
const expectedModels: Record<string, string> = { rush: "gpt-6-luna", smart: "gpt-6.1-sol", inspector: "gpt-6.1-sol", deep: "gpt-6-astra", review: "claude-opus-5.5" };
let runningChild: string | undefined;
let service: SubagentsService | undefined;
let serial = 0;
const modelDefinition = {
  id: "scripted", name: "Local deterministic fixture", api: "native-fixture-api",
  reasoning: false, input: ["text"], contextWindow: 1000000, maxTokens: 4096,
  cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
} satisfies ProviderModelConfig;
const fixtureProvider = (pi: ExtensionAPI) => {
  const provider = {
    api: "native-fixture-api", apiKey: "literal-fake-test-key", baseUrl: "http://invalid.local-never-contacted",
    models: [modelDefinition],
    streamSimple(model, context, options) {
      if (runningChild && model.provider === "github-copilot") childModels.set(runningChild, model.id);
      const stream = ai.createAssistantMessageEventStream();
      void (async () => {
        await options?.onPayload?.({ fixture: true }, model);
        await options?.onResponse?.({ status: 200, headers: {} }, model);
        await options?.onProviderStreamEvent?.({ fixture: true }, model);
        const lastUser = context.messages.findLastIndex(message => message.role === "user");
        const user = context.messages[lastUser];
        assert.ok(user?.role === "user");
        const text = typeof user.content === "string" ? user.content : user.content.map(block => block.type === "text" ? block.text : "").join("\n");
        const notification = text.includes("<task-notification>");
        assert.ok(notification || text.startsWith("NATIVE:"), "fixture accepts scripted prompts and native child notifications only");
        const source = text.slice(7);
        const hasResult = notification || context.messages.slice(lastUser + 1).some(message => message.role === "toolResult");
        const resultText = context.messages.slice(lastUser + 1).filter(message => message.role === "toolResult").map(message => message.content.map(block => block.type === "text" ? block.text : "").join("\n")).join("\n");
        const message: AssistantMessage = {
          role: "assistant", api: model.api, provider: model.provider, model: model.id,
          timestamp: Date.now(), content: [], stopReason: "pending",
          usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
        };
        stream.push({ type: "start", partial: message });
        if (!hasResult) {
          const toolCall: ToolCall = { type: "toolCall", id: `native-${++serial}`, name: "codemode", arguments: { code: source } };
          message.content.push(toolCall);
          stream.push({ type: "toolcall_start", contentIndex: 0, partial: message });
          stream.push({ type: "toolcall_delta", contentIndex: 0, delta: JSON.stringify(toolCall.arguments), partial: message });
          stream.push({ type: "toolcall_end", contentIndex: 0, toolCall, partial: message });
          message.stopReason = "toolUse";
        } else {
          const output = notification ? "Native child notification collected." : resultText;
          message.content.push({ type: "text", text: output });
          stream.push({ type: "text_start", contentIndex: 0, partial: message });
          stream.push({ type: "text_delta", contentIndex: 0, delta: output, partial: message });
          stream.push({ type: "text_end", contentIndex: 0, content: output, partial: message });
          message.stopReason = "stop";
        }
        stream.push({ type: "done", reason: message.stopReason, message });
        stream.end();
      })().catch(error => {
        const failure: AssistantMessage = { role: "assistant", api: model.api, provider: model.provider, model: model.id, timestamp: Date.now(), content: [], stopReason: "error", errorMessage: String(error), usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } } };
        stream.push({ type: "error", reason: "error", error: failure });
        stream.end();
      });
      return stream;
    },
  } satisfies Parameters<ExtensionAPI["registerProvider"]>[1];
  pi.registerProvider("native-fixture", provider);
  // Keep authored IDs/routing while substituting only transport in this isolated
  // model runtime. No production credentials or provider network is available.
  pi.registerProvider("github-copilot", { ...provider, models: [...new Set(Object.values(expectedModels))].map(id => ({ ...modelDefinition, id, reasoning: true })) });
  pi.events.on("fixture:subagents-service", value => { service = value as SubagentsService; });
  pi.events.on("permissions:ui_prompt", event => prompts.push(event as PermissionUiPromptEvent));
  pi.events.on("permissions:decision", event => decisions.push(event as PermissionDecisionEvent));
  pi.events.on("subagents:child:session-created", event => {
    if (runningChild) childIds.set(runningChild, (event as { sessionId: string }).sessionId);
  });
};
const loader = new sdk.DefaultResourceLoader({
  cwd: linked, agentDir, settingsManager, noSkills: true, noPromptTemplates: true, noThemes: true, noContextFiles: true,
  extensionFactories: [fixtureProvider, { name: "codemode", builtin: true, factory: sdk.createCodemodeExtension({ mode: "on" }) }],
});
await loader.reload();
assert.deepEqual(loader.getExtensions().errors, [], "actual extension load must succeed");
const { session } = await sdk.createAgentSession({
  cwd: linked, agentDir, modelRuntime, resourceLoader: loader, settingsManager,
  sessionManager: sdk.SessionManager.inMemory(linked),
});
const errors: ExtensionError[] = [];
const nested: ToolExecutionEndEvent[] = [];
const baseUI = session.extensionRunner.getUIContext();
const ui: ExtensionUIContext = {
  ...baseUI,
  select: async (_title, choices) => { assert.ok(choices.includes("No")); return "No"; },
  confirm: async () => false,
  input: async () => undefined,
  notify: () => {}, setStatus: () => {}, setWidget: () => {},
};
await session.bindExtensions({ uiContext: ui, mode: "rpc", onError: error => errors.push(error) });
const fixtureModel = modelRuntime.getModel("native-fixture", "scripted");
assert.ok(fixtureModel);
await session.setModel(fixtureModel);
session.subscribe(event => {
  if (event.type === "tool_execution_end" && event.parentToolCallId) nested.push(event);
});
async function parentScript(source: string): Promise<string> {
  await session.prompt(`NATIVE:${source}`);
  const text = session.getLastAssistantText() ?? "";
  assert.deepEqual(errors, []);
  return text;
}

function assertMetadataEvidence(entries: EvidenceEntry[], sessionId: string): void {
  for (const command of metadataCommands) {
    const label = `${sessionId}: ${command}`;
    const call = entries.find(entry => entry.sessionId === sessionId && entry.type === "tool_call" && entry.toolName === "bash" && entry.input.command === command);
    assert.ok(call?.type === "tool_call" && call.parentToolCallId, `${label} actually issues a nested Bash call`);
    const end = entries.find(entry => entry.sessionId === sessionId && entry.type === "tool_execution_end" && entry.toolCallId === call.toolCallId && entry.parentToolCallId === call.parentToolCallId);
    assert.ok(end?.type === "tool_execution_end", `${label} actually executes`);
    assert.doesNotMatch(JSON.stringify(end.result), permissionFailure);
    assert.ok(!entries.some(entry => entry.sessionId === sessionId && entry.type === "permission_prompt" && entry.prompt.value === command), `${label} does not prompt`);
    assert.ok(!entries.some(entry => entry.sessionId === sessionId && entry.type === "permission_decision" && entry.decision.value === command && (entry.decision.result === "deny" || entry.decision.forwarding)), `${label} is not denied or forwarded; policy_allow is valid`);
  }
}

try {
  for (const name of ["read", "bash", "edit", "write", "codemode"]) assert.ok(session.getActiveToolNames().includes(name), `${name} retains direct exposure`);
  assert.equal(settingsManager.getSettings().codemode?.inlineBudget, 100);
  assert.match(await parentScript('return await tools.read({path: "README.md"});'), /native-readable-decoy/);
  const deniedRead = await parentScript('return await tools.read({path: ".env"});');
  assert.match(deniedRead, /Script failed/);
  assert.doesNotMatch(deniedRead, /FAKE_SECRET|not-for-models/);
  const deniedPrimaryRead = await parentScript('return await tools.read({path: "primary/.env"});');
  assert.match(deniedPrimaryRead, /Script failed/);
  assert.doesNotMatch(deniedPrimaryRead, /FAKE_PRIMARY_SECRET|not-for-models/);
  assert.match(await parentScript('return await tools.write({path: ".env", content: "mutated"});'), /Script failed/);
  assert.match(await parentScript('return await tools.edit({path: ".env", oldText: "FAKE_SECRET", newText: "mutated"});'), /Script failed/);
  assert.equal(readFileSync(join(linked, ".env"), "utf8"), "FAKE_SECRET=not-for-models\n");
  assert.match(await parentScript('return await tools.write({path: "primary/blocked.txt", content: "must not be written"});'), /primary checkout/);
  assert.equal(existsSync(join(primary, "blocked.txt")), false);
  assert.match(await parentScript('return await tools.edit({path: "primary/edit.txt", oldText: "original", newText: "mutated"});'), /primary checkout/);
  assert.equal(readFileSync(join(primary, "edit.txt"), "utf8"), "original\n");
  assert.match(await parentScript(`return await tools.lsp_fix({root: ${JSON.stringify(primary)}, path: "fix.ts", write: true});`), /primary checkout/);
  assert.equal(readFileSync(join(primary, "fix.ts"), "utf8"), "original\n");
  assert.match(await parentScript('return await tools.write({path: "allowed.txt", content: "linked-write"});'), /Script completed/);
  assert.equal(readFileSync(join(linked, "allowed.txt"), "utf8"), "linked-write");
  for (const command of ["printenv PI_PROVIDER PI_MODEL PI_REASONING_LEVEL", ...metadataCommands]) {
    const before = prompts.length;
    const result = await parentScript(`return await tools.bash({command: ${JSON.stringify(command)}});`);
    assert.match(result, /Script completed/);
    assert.doesNotMatch(result, permissionFailure);
    assert.equal(prompts.length, before, `${command} does not prompt even if variables are unset`);
  }
  const asksBefore = prompts.length;
  assert.match(await parentScript('return await tools.bash({command: "printenv GH_TOKEN"});'), /Script failed/);
  assert.equal(prompts.length, asksBefore + 1, "inner ask reaches actual permission dialog");
  assert.match(await parentScript('return await tools.bash({command: "printenv PI_PROVIDER PI_MODEL PI_REASONING_LEVEL GH_TOKEN"});'), /Script failed/);
  assert.equal(prompts.length, asksBefore + 2, "a secret operand cannot ride the exact metadata approval");
  assert.match(await parentScript('return await tools.bash({command: "printenv HERDR_PANE_ID HERDR_WORKSPACE_ID GH_TOKEN"});'), /Script failed/);
  assert.equal(prompts.length, asksBefore + 3, "a secret cannot ride the Herdr metadata approval");

  assert.ok(service, "the installed parent subagents service is published through its public locator");
  for (const name of children) {
    runningChild = name;
    const source = `const out = await Promise.allSettled([
      tools.read({path: "README.md"}),
      tools.read({path: ".env"}),
      tools.bash({command: "printenv PI_PROVIDER PI_MODEL PI_REASONING_LEVEL"}),
      tools.bash({command: "printenv GH_TOKEN"}),
      tools.bash({command: "printenv PI_PROVIDER PI_MODEL PI_REASONING_LEVEL GH_TOKEN"}),
      tools.bash({command: ${JSON.stringify(name === "smart" ? "git status --short" : "git add README.md")}}),
      tools.bash({command: ${JSON.stringify(name === "smart" ? "git branch --show-current" : "git branch must-not-exist")}}),
      tools.bash({command: ${JSON.stringify(metadataCommands[0])}}),
      tools.bash({command: ${JSON.stringify(metadataCommands[1])}}),
      tools.bash({command: "grep -E 'TODO$' README.md"}),
      tools.bash({command: "printenv HERDR_PANE_ID HERDR_WORKSPACE_ID GH_TOKEN"})
    ]); text(out.map(r => r.status === "rejected" ? { status: r.status, error: r.reason.message } : r)); text("metadata-results:" + JSON.stringify(out.slice(7, 9))); text(ALL_TOOLS.map(t => t.name));
    ${name === "smart" ? 'text((await Promise.allSettled([tools.write({path:"smart.txt",content:"smart-linked"}), tools.write({path:"primary/smart-blocked.txt",content:"blocked"})])).map(r => r.status === "rejected" ? {status:r.status,error:r.reason.message} : r));' : `text({write: "write" in tools, edit: "edit" in tools}); for (const tool of ["write", "edit"]) { try { await tools[tool]({path: "${name}-blocked.txt",content:"must-not-write",oldText:"original",newText:"mutated"}); } catch (e) { text(e.message); } }`}`;
    const id = service.spawn(name, `NATIVE:${source}`, { foreground: true, maxTurns: 4 });
    await service.waitForAll();
    const record = service.getRecord(id);
    assert.ok(record?.result, "a completed native child has a result");
    assert.equal(record.status, "completed", JSON.stringify(record));
    // The aggregate also contains intentionally denied siblings; inspect fixed metadata indices only.
    const metadataLine = record.result.match(/metadata-results:(\[[^\n]+\])/);
    assert.ok(metadataLine?.[1], `${name} reports its own metadata results`);
    const metadataResults = JSON.parse(metadataLine[1]) as Array<PromiseSettledResult<unknown>>;
    assert.equal(metadataResults.length, metadataCommands.length);
    for (const result of metadataResults) {
      assert.equal(result.status, "fulfilled", `${name}: ${JSON.stringify(result)}`);
      assert.doesNotMatch(JSON.stringify(result), permissionFailure);
    }
    assert.match(record.result, /native-readable-decoy/);
    assert.doesNotMatch(record.result, /FAKE_SECRET|not-for-models|unknown_child_tool/);
    assert.ok(childIds.has(name), `${name} actually created a native child`);
    assert.equal(childModels.get(name), expectedModels[name], `${name} resolves its authored model without a caller override`);
    if (name !== "smart") {
      assert.match(record.result, /"write":false,"edit":false/);
      assert.match(record.result, /Denied by policy: 'bash'/);
      assert.match(record.result, /tools.write does not exist/);
      assert.match(record.result, /tools.edit does not exist/);
      assert.equal(existsSync(join(linked, `${name}-blocked.txt`)), false);
    } else {
      assert.match(record.result, /primary checkout/);
      assert.equal(readFileSync(join(linked, "smart.txt"), "utf8"), "smart-linked");
      assert.equal(existsSync(join(primary, "smart-blocked.txt")), false);
    }
  }
  const entries = readFileSync(evidencePath, "utf8").trim().split("\n").map(line => JSON.parse(line)) as EvidenceEntry[];
  for (const name of children) {
    const id = childIds.get(name);
    assert.ok(id);
    assertMetadataEvidence(entries, id);
    const calls = entries.filter((entry): entry is ToolCallEvent & { sessionId: string } => entry.sessionId === id && entry.type === "tool_call" && entry.parentToolCallId !== undefined);
    assert.ok(calls.some(call => call.toolName === "read"));
    assert.ok(calls.some(call => call.toolName === "bash"));
    for (const call of calls) {
      assert.ok(call.toolCallId.startsWith(`${call.parentToolCallId}/`));
      assert.ok(entries.some(entry => entry.sessionId === id && entry.type === "tool_execution_start" && entry.toolCallId === call.toolCallId && entry.parentToolCallId === call.parentToolCallId));
      assert.ok(entries.some(entry => entry.sessionId === id && entry.type === "tool_execution_end" && entry.toolCallId === call.toolCallId && entry.parentToolCallId === call.parentToolCallId));
    }
    const loadout = entries.find(entry => entry.sessionId === id && entry.type === "loadout");
    assert.ok(loadout?.type === "loadout");
    assert.ok(loadout.active.includes("codemode"));
    for (const tool of ["unknown_child_tool", "subagent", "get_subagent_result", "steer_subagent"]) assert.ok(!loadout.all.includes(tool), `${name} cannot reach ${tool}`);
    for (const command of ["printenv GH_TOKEN", "printenv PI_PROVIDER PI_MODEL PI_REASONING_LEVEL GH_TOKEN", "printenv HERDR_PANE_ID HERDR_WORKSPACE_ID GH_TOKEN"]) {
      assert.ok(decisions.some(decision => decision.forwarding?.requesterSessionId === id && decision.result === "deny" && decision.value === command && decision.resolution === "user_denied"), `${name} actual ask forwarded to parent and denied`);
    }
    assert.ok(entries.some(entry => entry.sessionId === id && entry.type === "permission_decision" && entry.decision.value === "grep -E 'TODO$' README.md" && entry.decision.result === "deny" && entry.decision.matchedPattern === "*$*"), `${name} retains its dollar denial`);
  }
  assertMetadataEvidence(entries, session.sessionManager.getSessionId());
  assert.equal(git("diff", "--cached", "--name-only"), "", "reader child Git mutations leave index unchanged");
  assert.equal(git("branch", "--list", "must-not-exist"), "");
  assert.ok(nested.some(event => event.toolName === "write" && event.isError));
  assert.ok(nested.some(event => event.toolName === "write" && !event.isError));
  assert.ok(nested.some(event => event.toolName === "lsp_fix" && event.isError));
  const parentId = session.sessionManager.getSessionId();
  const successfulRead = entries.find(entry => entry.sessionId === parentId && entry.type === "tool_result" && entry.toolName === "read" && !entry.isError && entry.parentToolCallId);
  assert.ok(successfulRead, "native inner results also carry parentToolCallId");
  // Child completion notifications may start a parent turn; waitForAll only
  // waits for children. Reload is an idle-session operation.
  await session.waitForIdle();
  await session.reload();
  for (const tool of ["read", "bash", "edit", "write", "codemode"]) assert.ok(session.getActiveToolNames().includes(tool), `${tool} survives normal reload`);
  assert.equal(settingsManager.getSettings().codemode?.inlineBudget, 100);
  assert.match(await parentScript('return await tools.read({path: "README.md"});'), /native-readable-decoy/);
  assert.deepEqual(errors, []);
  console.log(JSON.stringify({
    hostVersion: JSON.parse(readFileSync(join(hostRoot, "package.json"), "utf8")).version,
    permissionVersion: JSON.parse(readFileSync(join(permissionRoot, "package.json"), "utf8")).version,
    subagentsVersion: JSON.parse(readFileSync(join(subagentsRoot, "package.json"), "utf8")).version,
    lspVersion: JSON.parse(readFileSync(join(lspRoot, "package.json"), "utf8")).version,
    nestedCalls: entries.filter(entry => entry.type === "tool_call" && entry.parentToolCallId).length,
    children, childModels: Object.fromEntries(childModels), forwardedDenials: decisions.filter(decision => decision.forwarding && decision.resolution === "user_denied").length,
  }));
} finally {
  await session.extensionRunner.emit({ type: "session_shutdown", reason: "quit" });
  session.dispose();
}
