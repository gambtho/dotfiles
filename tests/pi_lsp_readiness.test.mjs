// Optional installed-server exercise. All writable state and executables must be
// provisioned in an owned fixture by the caller; this test downloads nothing.
import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { mkdirSync, writeFileSync, realpathSync } from "node:fs";
import { join, basename } from "node:path";
import test from "node:test";

const fixture = process.env.PI_TEST_LSP_FIXTURE;
const host = process.env.PI_TEST_HOST_ROOT;
const lsp = process.env.PI_TEST_LSP_ROOT;
assert.ok(fixture && host && lsp, "Select fixture, host and LSP roots explicitly");
assert.match(basename(realpathSync(fixture)), /^pi-lsp-fixture-[A-Za-z0-9_-]+$/);
assert.equal(process.env.HOME, join(fixture, "home"));
assert.equal(process.env.PI_CODING_AGENT_DIR, join(fixture, "agent"));
const hostRequire = createRequire(join(host, "dist/index.js"));
const { createJiti } = hostRequire("jiti");
const jiti = createJiti(import.meta.url, { fsCache: false, alias: {
  "@earendil-works/pi-coding-agent": join(host, "dist/index.js"),
  typebox: hostRequire.resolve("typebox"),
} });
const extension = await jiti.import(join(lsp, "dist/index.ts"));
const tools = new Map();
extension.default({ registerTool: tool => tools.set(tool.name, tool), registerCommand: () => {}, on: () => () => {} });

const cases = [
  ["biome", "bad.ts", "const = ;\n"],
  ["ty", "bad.py", "value: int = 'not an integer'\n"],
  ["bash-language-server", "bad.sh", "#!/bin/bash\nif then\n"],
  ["yaml-language-server", "bad.yaml", "value: [unterminated\n"],
];
for (const [server, filename, source] of cases) {
  test(`${server} starts through the installed adapter and diagnoses invalid input`, async () => {
    const workspace = join(fixture, "workspaces", server);
    mkdirSync(workspace, { recursive: true });
    writeFileSync(join(workspace, filename), source);
    if (server === "biome") writeFileSync(join(workspace, "biome.json"), JSON.stringify({ files: { includes: ["**"] } }));
    const result = await tools.get("lsp_diagnostics").execute("readiness", { paths: [filename], root: workspace, server, limit: 1 }, new AbortController().signal, undefined, {
      cwd: workspace, isProjectTrusted: () => false, sessionManager: {},
      ui: { setStatus: () => {} },
    });
    assert.equal(result.isError, undefined, JSON.stringify(result));
    assert.deepEqual(result.details.skipped, [], JSON.stringify(result));
    assert.equal(result.details.routes.length, 1);
    assert.equal(result.details.routes[0].server, server);
    assert.equal(result.details.routes[0].details.summary.files, 1);
    assert.ok(result.details.routes[0].details.summary.diagnostics > 0, JSON.stringify(result));
  });
}

test("missing default routes stay explicitly unchecked, and explicit selection fails", async () => {
  const workspace = join(fixture, "workspaces", "missing-server");
  const emptyBin = join(fixture, "empty-bin");
  mkdirSync(workspace, { recursive: true });
  mkdirSync(emptyBin, { recursive: true });
  writeFileSync(join(workspace, "bad.yaml"), "value: [unterminated\n");
  const originalPath = process.env.PATH;
  process.env.PATH = emptyBin;
  const ctx = { cwd: workspace, isProjectTrusted: () => false, sessionManager: {}, ui: { setStatus: () => {} } };
  const params = { paths: ["bad.yaml"], root: workspace, limit: 1 };
  try {
    const result = await tools.get("lsp_diagnostics").execute("missing-default", params, undefined, undefined, ctx);
    assert.deepEqual(result.details.routes, []);
    assert.ok(result.details.skipped.some(route => route.server === "yaml-language-server"));
    await assert.rejects(tools.get("lsp_diagnostics").execute("missing-explicit", { ...params, server: "yaml-language-server" }, undefined, undefined, ctx), /yaml-language-server.*(?:ENOENT|not found)|ENOENT/);
  } finally {
    process.env.PATH = originalPath;
  }
});
