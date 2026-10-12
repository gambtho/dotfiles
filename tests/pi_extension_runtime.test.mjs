import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { copyFileSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const hostRoot = process.env.PI_TEST_HOST_ROOT;
const permissionRoot = process.env.PI_TEST_PERMISSION_ROOT;
const subagentsRoot = process.env.PI_TEST_SUBAGENTS_ROOT;
const lspRoot = process.env.PI_TEST_LSP_ROOT;
assert.ok(hostRoot, "PI_TEST_HOST_ROOT must select an installed host; no download/fallback");
assert.ok(permissionRoot, "PI_TEST_PERMISSION_ROOT must select the candidate permission package");

// Every launched runtime gets an allowlisted environment, never production auth,
// settings, sessions, caches, or credentials copied from the agent process.
function isolatedRun(command, args) {
  const root = mkdtempSync(`${tmpdir()}/pi-native-test-`);
  try {
    return spawnSync(command, typeof args === "function" ? args(root) : args, {
      cwd: root,
      encoding: "utf8",
      timeout: 120000,
      env: {
        HOME: root,
        XDG_CONFIG_HOME: `${root}/config`,
        XDG_CACHE_HOME: `${root}/cache`,
        PI_CODING_AGENT_DIR: `${root}/agent`,
        PATH: `${dirname(process.execPath)}:/usr/bin:/bin`,
        NODE_DISABLE_COMPILE_CACHE: "1",
        JITI_FS_CACHE: "false",
        npm_config_cache: `${root}/npm-cache`,
        npm_config_userconfig: `${root}/npmrc`,
        npm_config_globalconfig: `${root}/global-npmrc`,
        npm_config_update_notifier: "false",
      },
    });
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

test("candidate installed schema and full permission pipeline retain all approved boundaries", () => {
  const result = isolatedRun("/bin/bash", [
    `${repoRoot}/libexec/validate-pi-security-runtime`,
    "--package-root", permissionRoot,
    "--pi-package-root", hostRoot,
    "--python", "/usr/bin/python3",
  ]);
  assert.equal(result.status, 0, result.error?.message ?? result.stdout + result.stderr);
  assert.match(result.stdout, /deterministic engine validation passed/);
});

test("native Codemode sessions and installed child forwarding enforce policy and worktree boundaries", t => {
  assert.ok(subagentsRoot, "PI_TEST_SUBAGENTS_ROOT is required; no mock child runtime");
  assert.ok(lspRoot, "PI_TEST_LSP_ROOT is required; the real installed LSP extension is loaded");
  const result = isolatedRun(process.execPath, [
    "--experimental-import-meta-resolve",
    `${repoRoot}/libexec/pi-extension-runtime-checks.ts`,
    "--pi-package-root", hostRoot,
    "--package-root", permissionRoot,
    "--subagents-root", subagentsRoot,
    "--lsp-root", lspRoot,
    "--repo-root", repoRoot,
  ]);
  assert.equal(result.status, 0, result.error?.message ?? result.stdout + result.stderr);
  assert.equal(result.stderr, "", "native loading must have no compatibility warnings");
  const evidence = JSON.parse(result.stdout.trim());
  assert.ok(evidence.nestedCalls >= 12, result.stdout);
  assert.deepEqual(evidence.children, ["rush", "smart", "deep", "review"]);
  assert.ok(evidence.forwardedDenials >= 8, result.stdout);
  t.diagnostic(result.stdout.trim());
});

test("current evaluator layout fails closed rather than borrowing a stale legacy manager", () => {
  const result = isolatedRun(process.execPath, root => {
    mkdirSync(`${root}/damaged/src/policy`, { recursive: true });
    copyFileSync(`${permissionRoot}/package.json`, `${root}/damaged/package.json`);
    writeFileSync(`${root}/damaged/src/permission-manager.ts`, "export class PermissionManager {}\n");
    return [`${repoRoot}/libexec/validate-pi-security-runtime.ts`, "--package-root", `${root}/damaged`, "--repo-root", repoRoot];
  });
  assert.equal(result.status, 1, result.stdout + result.stderr);
  assert.match(result.stderr, /incompatible permission evaluator/);
  assert.match(result.stderr, /selected evaluator behavior failed/);
  assert.match(result.stderr, /Cannot find module .*src\/policy\/permission-manager\.ts/);
});

test("latest-layout healthy cached permission bootstrap retains its resolution without npm installation", () => {
  const result = isolatedRun("/bin/bash", root => {
    const installed = `${root}/agent/npm/node_modules/@gotgenes/pi-permission-system`;
    mkdirSync(`${installed}/schemas`, { recursive: true });
    mkdirSync(`${installed}/src/policy`, { recursive: true });
    for (const file of ["package.json", "schemas/permissions.schema.json", "src/policy/permission-manager.ts"]) {
      copyFileSync(`${permissionRoot}/${file}`, `${installed}/${file}`);
    }
    mkdirSync(`${root}/reviewed/ai/pi`, { recursive: true });
    const declarations = JSON.stringify({ packages: ["npm:@gotgenes/pi-permission-system"] });
    writeFileSync(`${root}/agent/settings.json`, declarations);
    writeFileSync(`${root}/reviewed/ai/pi/settings.json`, declarations);
    // If health misclassifies the verified current layout, fail at transport
    // rather than installing an older package or touching a healthy cache.
    mkdirSync(`${root}/bin`);
    writeFileSync(`${root}/bin/npm`, "#!/bin/sh\nexit 89\n", { mode: 0o755 });
    return ["-c", 'PATH="$HOME/bin:$PATH" exec bash "$@"', "_",
      `${repoRoot}/libexec/pi-package-lifecycle`, "bootstrap",
      "--agent-dir", `${root}/agent`, "--repo-root", `${root}/reviewed`, "--pi-package-root", hostRoot];
  });
  assert.equal(result.status, 0, result.error?.message ?? result.stdout + result.stderr);
  const inventory = JSON.parse(result.stdout);
  assert.equal(inventory.packages[0].state, "installed");
  assert.deepEqual(inventory.packages[0].missingArtifacts, []);
});
