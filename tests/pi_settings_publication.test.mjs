// Selected-host exercise of the real native settings lock; never production state.
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, lstatSync, existsSync, readdirSync, readlinkSync, symlinkSync, unlinkSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync, spawn } from "node:child_process";
import { fileURLToPath, pathToFileURL } from "node:url";
import test from "node:test";
import { setTimeout as delay } from "node:timers/promises";

const host = process.env.PI_TEST_HOST_ROOT;
const repo = fileURLToPath(new URL("../", import.meta.url));
const publisher = join(repo, "libexec/pi-publish-settings.mjs");
const migrationScript = [
  "set -euo pipefail", 'installer=$(<"$0")',
  "installer=${installer%$'\\nmain \"$@\"'}", 'eval "$installer"',
  'PI_HOST_ROOT=$1; PI_AGENT_DIR=$2; MODE=apply',
  'apply_pi_efficiency_preferences "$PI_AGENT_DIR/settings.json"',
].join("\n");

if (!host) {
  test("settings publication requires a selected SDK", { skip: "PI_TEST_HOST_ROOT not set" }, () => {});
} else {
  // Test-only access to the implementation that the selected SDK actually uses.
  const { FileSettingsStorage } = await import(pathToFileURL(join(host, "dist/core/settings-manager.js")));
  function fixture(t) {
    const root = mkdtempSync(join(tmpdir(), "pi-settings-publication-"));
    t.after(() => rmSync(root, { recursive: true, force: true }));
    const agent = join(root, "agent");
    mkdirSync(agent);
    const destination = join(agent, "settings.json");
    writeFileSync(destination, '{"theme":"old"}\n');
    const candidate = join(root, "candidate.json");
    writeFileSync(candidate, '{"theme":"old","newPreference":true}\n');
    const env = { PATH: process.env.PATH, HOME: root, PI_CODING_AGENT_DIR: agent,
      NODE_DISABLE_COMPILE_CACHE: "1", JITI_FS_CACHE: "false", PI_AI_APPLY_EFFICIENCY_PREFERENCES: "1" };
    return { root, agent, destination, candidate, env, storage: new FileSettingsStorage(root, agent) };
  }
  function args(f) {
    if (!existsSync(f.destination)) return [publisher, host, f.candidate, f.destination, "0644", "absent", "", "absent", "absent"];
    const stat = lstatSync(f.destination, { bigint: true });
    return [publisher, host, f.candidate, f.destination, "0644", stat.isSymbolicLink() ? "symlink" : "file", stat.isSymbolicLink() ? readlinkSync(f.destination) : "", createHash("sha256").update(readFileSync(f.destination)).digest("hex"), `${stat.dev}:${stat.ino}`];
  }
  function publish(f, argv = args(f)) { return spawnSync(process.execPath, argv, { env: f.env, encoding: "utf8" }); }

  test("native-held lock prevents the actual efficiency migration from overwriting settings", t => {
    const f = fixture(t);
    f.storage.withLock("global", current => {
      const baseline = join(f.root, "baseline.json");
      writeFileSync(baseline, '{"packages":[]}');
      const reconciliation = migrationScript.replace('apply_pi_efficiency_preferences "$PI_AGENT_DIR/settings.json"', 'reconcile_pi_settings "$3" "$PI_AGENT_DIR/settings.json"');
      for (const script of [migrationScript, reconciliation]) {
        const result = spawnSync("bash", ["-c", script, join(repo, "ai/pi/install.sh"), host, f.agent, baseline], { env: f.env, encoding: "utf8" });
        assert.notEqual(result.status, 0, result.stdout + result.stderr);
        assert.match(result.stderr + result.stdout, /ELOCKED|already being held/);
      }
      assert.equal(readFileSync(f.destination, "utf8"), current);
      assert.ok(existsSync(`${f.destination}.lock`), "must not delete the native writer's lock");
      assert.ok(!readdirSync(f.agent).some(name => name.startsWith(".pi-settings-publish-")));
      return undefined;
    });
  });

  test("native in-place edit completed before acquisition refuses stale content", t => {
    const f = fixture(t);
    const argv = args(f);
    const inode = lstatSync(f.destination).ino;
    f.storage.withLock("global", () => '{"theme":"native-change"}\n');
    assert.equal(lstatSync(f.destination).ino, inode);
    const result = publish(f, argv);
    assert.equal(result.status, 4, result.stderr);
    assert.match(result.stderr, /changed before publication/);
    assert.equal(JSON.parse(readFileSync(f.destination)).theme, "native-change");
    assert.ok(!readdirSync(f.agent).some(name => name.startsWith(".pi-settings-publish-")));
  });

  test("publication preserves mode and permits a later native merge", t => {
    const f = fixture(t);
    const result = publish(f);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(lstatSync(f.destination).mode & 0o777, 0o644);
    f.storage.withLock("global", current => JSON.stringify({ ...JSON.parse(current), theme: "later-native" }));
    assert.deepEqual(JSON.parse(readFileSync(f.destination)), { theme: "later-native", newPreference: true });
    assert.ok(!existsSync(`${f.destination}.lock`));
  });

  test("legacy link replacement never modifies its authored target", t => {
    const f = fixture(t);
    const authored = join(f.root, "authored.json");
    writeFileSync(authored, readFileSync(f.destination));
    unlinkSync(f.destination);
    symlinkSync(authored, f.destination);
    const result = publish(f);
    assert.equal(result.status, 0, result.stderr);
    assert.ok(!lstatSync(f.destination).isSymbolicLink());
    assert.deepEqual(JSON.parse(readFileSync(authored)), { theme: "old" });
    assert.equal(JSON.parse(readFileSync(f.destination)).newPreference, true);
  });

  test("absent bootstrap rechecks absence and refuses a newly present file", t => {
    const f = fixture(t);
    unlinkSync(f.destination);
    const absent = args(f);
    writeFileSync(f.destination, '{"theme":"new-owner"}\n');
    const stale = publish(f, absent);
    assert.equal(stale.status, 4, stale.stderr);
    assert.equal(JSON.parse(readFileSync(f.destination)).theme, "new-owner");
    unlinkSync(f.destination);
    const created = publish(f, absent);
    assert.equal(created.status, 0, created.stderr);
    assert.equal(JSON.parse(readFileSync(f.destination)).newPreference, true);
  });

  test("invalid candidate refuses without modifying settings", t => {
    const f = fixture(t);
    writeFileSync(f.candidate, "private-decoy-not-JSON");
    const result = publish(f);
    assert.notEqual(result.status, 0);
    assert.doesNotMatch(result.stderr, /private-decoy/);
    assert.deepEqual(JSON.parse(readFileSync(f.destination)), { theme: "old" });
    assert.ok(!existsSync(`${f.destination}.lock`));
  });

  test("missing selected lock dependency has no unlocked or ambient fallback", t => {
    const f = fixture(t);
    const fakeHost = join(f.root, "missing-host");
    mkdirSync(fakeHost);
    const argv = args(f);
    argv[1] = fakeHost;
    const result = publish(f, argv);
    assert.equal(result.status, 2, result.stderr);
    assert.deepEqual(JSON.parse(readFileSync(f.destination)), { theme: "old" });
    assert.ok(!existsSync(`${f.destination}.lock`));
    assert.ok(!readdirSync(f.agent).some(name => name.startsWith(".pi-settings-publish-")));
  });

  test("native writer cannot enter the final check-to-rename gap", async t => {
    const f = fixture(t);
    const ready = join(f.root, "ready");
    const release = join(f.root, "release");
    const hook = join(f.root, "pause.cjs");
    writeFileSync(hook, `const fs = require("node:fs");
const rename = fs.renameSync;
fs.renameSync = (from, to) => {
  if (to === process.env.TEST_DESTINATION) {
    fs.writeFileSync(process.env.TEST_READY, "ready");
    const deadline = Date.now() + 3000;
    while (!fs.existsSync(process.env.TEST_RELEASE)) {
      if (Date.now() > deadline) throw new Error("fixture pause exceeded heartbeat-safe bound");
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 5);
    }
  }
  return rename(from, to);
};\n`);
    const child = spawn(process.execPath, ["--require", hook, ...args(f)], { env: { ...f.env, TEST_DESTINATION: f.destination, TEST_READY: ready, TEST_RELEASE: release }, stdio: ["ignore", "ignore", "pipe"] });
    let error = "";
    child.stderr.on("data", chunk => { error += chunk; });
    const completed = new Promise(resolve => child.on("exit", resolve));
    try {
      for (let n = 0; n < 100 && !existsSync(ready) && child.exitCode === null; n++) await delay(10);
      assert.ok(existsSync(ready), error || "publisher did not reach rename barrier");
      assert.throws(() => f.storage.withLock("global", () => '{"theme":"would-clobber"}'), { code: "ELOCKED" });
      writeFileSync(release, "release");
      assert.equal(await completed, 0, error);
      f.storage.withLock("global", current => JSON.stringify({ ...JSON.parse(current), theme: "after-release" }));
      assert.deepEqual(JSON.parse(readFileSync(f.destination)), { theme: "after-release", newPreference: true });
    } finally {
      if (child.exitCode === null) child.kill();
      await completed;
    }
  });
}
