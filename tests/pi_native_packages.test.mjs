import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const hostRoot = process.env.PI_TEST_HOST_ROOT;
assert.ok(hostRoot, "PI_TEST_HOST_ROOT must select the read-only public SDK");

function fixture(callback) {
  const root = mkdtempSync(`${tmpdir()}/pi-package-test-`);
  const env = {
    HOME: root, TMPDIR: root, PI_CODING_AGENT_DIR: `${root}/agent`,
    XDG_CONFIG_HOME: `${root}/config`, XDG_CACHE_HOME: `${root}/cache`,
    XDG_DATA_HOME: `${root}/data`, XDG_STATE_HOME: `${root}/state`,
    PATH: `${root}/bin:${dirname(process.execPath)}:/usr/bin:/bin`,
    NODE_DISABLE_COMPILE_CACHE: "1", JITI_FS_CACHE: "false",
    npm_config_cache: `${root}/npm-cache`, npm_config_prefix: `${root}/npm-prefix`,
    npm_config_userconfig: `${root}/npmrc`, npm_config_globalconfig: `${root}/global-npmrc`,
    npm_config_update_notifier: "false", GIT_CONFIG_NOSYSTEM: "1", GIT_TERMINAL_PROMPT: "0",
  };
  function write(path, content, mode) {
    mkdirSync(dirname(path), { recursive: true });
    writeFileSync(path, content, mode ? { mode } : undefined);
  }
  function run(command, args, cwd = root) {
    const result = spawnSync(command, args, { cwd, env, encoding: "utf8", timeout: 120000 });
    assert.equal(result.status, 0, result.error?.message ?? result.stdout + result.stderr);
    return result.stdout;
  }
  try { callback({ root, env, write, run }); }
  finally { rmSync(root, { recursive: true, force: true }); }
}

test("native CLI installs missing npm and Git entries, accepts advancement, and ignores project packages", () => fixture(({ root, write, run }) => {
  // Only registry/remote transport is replaced; stock CLI, settings and Git
  // reconciliation execute unchanged. No offline switch (it skips updates).
  write(`${root}/bin/npm`, `#!/bin/bash
set -eu
printf '%s\\n' "$*" >>"$HOME/npm-events"
[[ "$1" == install ]] || exit 81
shift
spec=$1; shift
[[ "$spec" == fixture-tools@latest && "$1" == --prefix ]] || exit 82
mkdir -p "$2/node_modules/fixture-tools"
printf '{"name":"fixture-tools","version":"%s"}\\n' "$(<"$HOME/version")" >"$2/node_modules/fixture-tools/package.json"
`, 0o755);
  write(`${root}/version`, "1.0.0");
  run("/usr/bin/git", ["init", "-q", `${root}/seed`]);
  write(`${root}/seed/README.md`, "local transport\n");
  run("/usr/bin/git", ["-C", `${root}/seed`, "add", "."]);
  run("/usr/bin/git", ["-C", `${root}/seed`, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "fixture"]);
  write(`${root}/bin/git`, `#!/bin/bash
set -eu
if [[ "$1" == clone ]]; then
  [[ "$2" == https://github.com/example/fixture ]] || exit 83
  exec /usr/bin/git clone "$HOME/seed" "$3"
fi
exec /usr/bin/git "$@"
`, 0o755);
  const declarations = JSON.stringify({ packages: [{ source: "npm:fixture-tools", extensions: [], skills: [] }, { source: "git:github.com/example/fixture", extensions: [] }] });
  write(`${root}/agent/settings.json`, declarations);
  write(`${root}/project/.pi/settings.json`, '{"packages":["npm:forbidden-project"]}');
  const cli = [`${hostRoot}/dist/cli.js`, "update", "--extensions", "--no-approve"];
  const help = run(process.execPath, [`${hostRoot}/dist/cli.js`, "update", "--help"], `${root}/project`);
  assert.match(help, /--extensions/);
  assert.match(help, /--no-approve/);
  run(process.execPath, cli, `${root}/project`);
  assert.equal(JSON.parse(readFileSync(`${root}/agent/npm/node_modules/fixture-tools/package.json`)).version, "1.0.0");
  assert.ok(existsSync(`${root}/agent/git/github.com/example/fixture/.git`));
  write(`${root}/version`, "2.0.0");
  run(process.execPath, cli, `${root}/project`);
  assert.equal(JSON.parse(readFileSync(`${root}/agent/npm/node_modules/fixture-tools/package.json`)).version, "2.0.0");
  assert.equal(readFileSync(`${root}/agent/settings.json`, "utf8"), declarations);
  assert.doesNotMatch(readFileSync(`${root}/npm-events`, "utf8"), /forbidden-project/);
}));

test("public SDK retains exact authored filters, local my and retired-source exclusion", () => fixture(({ root, run }) => {
  const result = run(process.execPath, ["--input-type=module", "-e", `
import assert from "node:assert/strict";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { pathToFileURL } from "node:url";
const { DefaultPackageManager, SettingsManager } = await import(pathToFileURL(${JSON.stringify(`${hostRoot}/dist/index.js`)}));
const authored = JSON.parse(readFileSync(${JSON.stringify(`${repoRoot}/ai/pi/settings.json`)}, "utf8"));
const selected = {
  "git:github.com/tmustier/pi-extensions": { extensions: ["raw-paste/index.ts", "session-recap/index.ts", "tab-status/tab-status.ts", "usage-extension/index.ts", "pi-ralph-wiggum/index.ts", "code-actions/index.ts"], skills: ["pi-ralph-wiggum/SKILL.md"], prompts: [], themes: [] },
  "npm:pi-amplike": { extensions: ["extensions/btw.ts", "extensions/handoff.ts", "extensions/modes.ts", "extensions/session-query.ts"], skills: ["skills/session-query/SKILL.md"], prompts: [], themes: [] },
  "git:github.com/gambtho/pi-file-editor@v0.1.0": { extensions: ["extensions/file-editor.ts"], skills: [], prompts: [], themes: [] },
  "git:github.com/addyosmani/agent-skills": { extensions: [], skills: ["skills/security-and-hardening/SKILL.md", "skills/performance-optimization/SKILL.md"], prompts: [], themes: [] },
};
const extra = { extensions: ["extensions/unselected.ts"], skills: ["skills/unselected/SKILL.md"], prompts: ["prompts/unselected.md"], themes: ["themes/unselected.json"] };
const agent = process.env.PI_CODING_AGENT_DIR;
function write(path, content) { mkdirSync(dirname(path), { recursive: true }); writeFileSync(path, content); }
for (const entry of [...authored.packages, "npm:shitty-extensions", "npm:@narumitw/pi-caffeinate"]) {
  const source = typeof entry === "string" ? entry : entry.source;
  const packageRoot = source.startsWith("npm:") ? join(agent, "npm/node_modules", source.slice(4)) : source.startsWith("git:") ? join(agent, "git", source.slice(4).replace(/@[^@]+$/, "")) : join(process.env.HOME, ".dotfiles/ai/marketplace/plugins/my");
  const resources = selected[source] ? Object.fromEntries(Object.keys(extra).map(kind => [kind, [...selected[source][kind], ...extra[kind]]])) : extra;
  write(join(packageRoot, "package.json"), JSON.stringify({ name: "fixture", version: "1.0.0", pi: resources }));
  for (const paths of Object.values(resources)) for (const path of paths) write(join(packageRoot, path), "");
}
const manager = new DefaultPackageManager({ cwd: process.cwd(), agentDir: agent, settingsManager: SettingsManager.inMemory(authored) });
const resolved = await manager.resolve(async source => { throw new Error("unexpected missing source " + source); });
for (const source of ["shitty-extensions", "@narumitw/pi-caffeinate"]) {
  assert.ok(!manager.listConfiguredPackages().some(pkg => pkg.source === "npm:" + source));
  for (const kind of Object.keys(extra)) assert.ok(!resolved[kind].some(resource => resource.enabled && resource.path.startsWith(join(agent, "npm/node_modules", source) + "/")));
}
for (const [source, expected] of Object.entries(selected)) for (const [kind, paths] of Object.entries(expected)) {
  const enabled = resolved[kind].filter(resource => resource.enabled && resource.metadata.source === source);
  assert.deepEqual(enabled.map(resource => relative(resource.metadata.packageRoot, resource.path)).sort(), [...paths].sort(), source + ": " + kind);
}
for (const source of ["npm:@narumitw/pi-worktree", "npm:@narumitw/pi-file-context"]) assert.ok(resolved.extensions.some(resource => resource.enabled && resource.metadata.source === source));
for (const kind of Object.keys(extra)) assert.ok(resolved[kind].some(resource => resource.enabled && resource.metadata.source === "git:github.com/obra/superpowers"));
assert.equal(manager.listConfiguredPackages().find(pkg => pkg.source === "~/.dotfiles/ai/marketplace/plugins/my").installedPath, join(process.env.HOME, ".dotfiles/ai/marketplace/plugins/my"));
console.log("exact filters/local my/retired exclusion passed");
`]);
  assert.match(result, /exact filters\/local my\/retired exclusion passed/);
}));
