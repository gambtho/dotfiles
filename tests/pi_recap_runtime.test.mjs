// Opt-in characterization of the selected installed recap package. No real auth,
// model catalog or provider request is used. Run with both selected roots below.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createRequire, findPackageJSON } from "node:module";
import { dirname, join, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import test from "node:test";

const host = process.env.PI_TEST_HOST_ROOT;
const recap = process.env.PI_TEST_RECAP_ROOT;
assert.ok(host && recap, "Select PI_TEST_HOST_ROOT and PI_TEST_RECAP_ROOT explicitly");
const hostRequire = createRequire(join(host, "dist/index.js"));
const { createJiti } = hostRequire("jiti");
const aiManifest = findPackageJSON("@earendil-works/pi-ai", pathToFileURL(join(host, "dist/index.js")));
const aiPackage = JSON.parse(readFileSync(aiManifest, "utf8"));
const jiti = createJiti(import.meta.url, {
  fsCache: false,
  alias: {
    "@earendil-works/pi-coding-agent": join(host, "dist/index.js"),
    "@earendil-works/pi-ai/compat": resolve(dirname(aiManifest), aiPackage.exports["./compat"].import),
    "@earendil-works/pi-tui": hostRequire.resolve("@earendil-works/pi-tui"),
  },
});
const installed = await jiti.import(join(recap, "index.ts"));
const active = { provider: "github-copilot", id: "gpt-6.1-sol" };
const old = { provider: "github-copilot", id: "gpt-5.6-luna" };
const chosen = { provider: "github-copilot", id: "gpt-6-luna" };
const registry = {
  find: (provider, id) => [active, old, chosen].find(model => model.provider === provider && model.id === id),
  getAvailable: () => [active, old],
};

test("explicit recap model wins even when not in available list; malformed/missing falls back", () => {
  assert.equal(installed.selectRecapModel(active, "github-copilot/gpt-6-luna", registry), chosen);
  for (const spec of ["missing/model", "missing-slash", "/missing-provider"]) {
    assert.equal(installed.selectRecapModel(active, spec, registry), active);
  }
});

test("automatic old Luna preference applies only to an active GPT model on its provider", () => {
  assert.equal(installed.selectRecapModel(active, undefined, registry), old);
  assert.equal(installed.selectRecapModel(active, undefined, { ...registry, getAvailable: () => [active] }), active);
  const nonGPT = { provider: "github-copilot", id: "claude-opus-5.5" };
  assert.equal(installed.selectRecapModel(nonGPT, undefined, registry), nonGPT);
});

test("manual recap with a found model but no auth stops before provider generation", async () => {
  const flags = new Map();
  const commands = new Map();
  installed.default({
    registerFlag: (name, options) => flags.set(name, options.default),
    getFlag: name => flags.get(name),
    on: () => () => {},
    registerCommand: (name, command) => commands.set(name, command),
  });
  flags.set("recap-model", "github-copilot/gpt-6-luna");
  let authenticated;
  let displays = 0;
  const entries = [{ type: "message", id: "user", parentId: null, timestamp: "2026-01-01T00:00:00Z", message: { role: "user", content: "Review this change", timestamp: 0 } }];
  await commands.get("recap").handler("", {
    model: active, hasUI: true,
    modelRegistry: { ...registry, getApiKeyAndHeaders: async model => { authenticated = model; return { ok: false }; } },
    sessionManager: { buildSessionProjection: () => ({ entries: entries.map(sourceEntry => ({ sourceEntry, messages: [sourceEntry.message] })) }), getBranch: () => entries },
    ui: { theme: { fg: (_color, text) => text }, setStatus: () => {}, setWidget: () => { displays++; } },
  });
  assert.equal(authenticated, chosen);
  assert.equal(displays, 0);
});
