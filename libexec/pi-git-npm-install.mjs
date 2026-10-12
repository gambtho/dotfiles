// Called only by the lifecycle's public SDK npmCommand installation boundary.
import { spawnSync } from "node:child_process";
import { lstatSync, realpathSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const [hostRoot, repoRoot, agentDir, source, separator, command, ...args] = process.argv.slice(2);
if (!hostRoot || !repoRoot || !agentDir || !source || separator !== "--" || !command) {
  throw new Error("Git dependency installation requires the selected checkout cwd");
}
// The checkout exists now; let the selected SDK resolve the exact install source.
// In particular, its Git checkout spelling can differ from the declaration.
const { DefaultPackageManager, SettingsManager } = await import(pathToFileURL(join(hostRoot, "dist/index.js")).href);
const manager = new DefaultPackageManager({
  cwd: repoRoot, agentDir, settingsManager: SettingsManager.inMemory({}, { projectTrusted: false }),
});
const target = manager.getInstalledPath(source, "user");
// Compare the same directory, including OS aliases such as /var -> /private/var.
if (!target || realpathSync(target) !== realpathSync(process.cwd())) {
  throw new Error("Git dependency installation requires the selected checkout cwd");
}
function present(name) {
  try { lstatSync(join(target, name)); return true; } catch (error) {
    if (error.code === "ENOENT") return false;
    throw error;
  }
}
// Check after the SDK clone/reset, when the selected revision is on disk.
// Never remove a lock or disable an existing lock/shrinkwrap. The CLI override
// affects this child only; caller environment and configured npm args survive.
if (!present("package-lock.json") && !present("npm-shrinkwrap.json")) {
  args.push("--package-lock=false");
}
const result = spawnSync(command, args, { stdio: "inherit" });
if (result.error) throw result.error;
if (result.signal) process.kill(process.pid, result.signal);
else process.exitCode = result.status ?? 1;
