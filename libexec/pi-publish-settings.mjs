// Conditional settings replacement using the selected Pi runtime's native lock.
// Caller validates ownership/legacy links and supplies its pre-render snapshot.
import { createHash } from "node:crypto";
import { createRequire } from "node:module";
import { basename, dirname, join, relative, isAbsolute } from "node:path";
import { readFileSync, writeFileSync, lstatSync, readlinkSync, realpathSync, mkdtempSync, chmodSync, renameSync, rmSync } from "node:fs";

const [host, candidate, destination, mode, kind, link, hash, identity] = process.argv.slice(2);
let directory;
let release;
try {
  if (process.argv.length !== 10 || !["file", "symlink", "absent"].includes(kind) || !["0600", "0644"].includes(mode)) throw new Error("invalid publication arguments");
  const selected = realpathSync(host);
  const hostRequire = createRequire(join(selected, "dist/index.js"));
  let boundary = selected;
  while (basename(boundary) !== "node_modules" && dirname(boundary) !== boundary) boundary = dirname(boundary);
  if (basename(boundary) !== "node_modules") boundary = selected;
  const manifest = realpathSync(hostRequire.resolve("proper-lockfile/package.json"));
  const location = relative(boundary, manifest);
  if (location.startsWith(`..${process.platform === "win32" ? "\\" : "/"}`) || location === ".." || isAbsolute(location)) throw new Error("native settings lock dependency is outside selected runtime");
  if (!JSON.parse(readFileSync(manifest, "utf8")).version.startsWith("4.")) throw new Error("unsupported native settings lock protocol; expected proper-lockfile 4");
  const lockfile = hostRequire("proper-lockfile");
  const content = readFileSync(candidate);
  const value = JSON.parse(content.toString("utf8"));
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("settings candidate must be a JSON object");
  directory = mkdtempSync(join(dirname(destination), ".pi-settings-publish-"));
  const staged = join(directory, "settings.json");
  writeFileSync(staged, content, { mode: Number.parseInt(mode, 8), flag: "wx" });
  chmodSync(staged, Number.parseInt(mode, 8));
  let compromised;
  release = lockfile.lockSync(destination, { realpath: false, onCompromised: error => { compromised = error; } });
  let currentKind = "absent";
  let currentIdentity = "absent";
  let currentLink = "";
  let currentHash = "absent";
  try {
    const stat = lstatSync(destination, { bigint: true });
    currentKind = stat.isSymbolicLink() ? "symlink" : stat.isFile() ? "file" : "other";
    currentIdentity = `${stat.dev}:${stat.ino}`;
    if (currentKind === "symlink") currentLink = readlinkSync(destination);
    if (currentKind === "file" || currentKind === "symlink") {
      try { currentHash = createHash("sha256").update(readFileSync(destination)).digest("hex"); }
      catch (error) { if (error.code !== "ENOENT") throw error; }
    }
  } catch (error) { if (error.code !== "ENOENT") throw error; }
  if (currentKind !== kind || currentIdentity !== identity || currentLink !== link || currentHash !== hash) {
    const error = new Error("settings changed before publication; re-read and retry");
    error.code = "ESTALE";
    throw error;
  }
  if (compromised) throw compromised;
  // No awaits: keep the shared critical section short, including final rename.
  renameSync(staged, destination);
} catch (error) {
  // Do not echo JSON.parse errors: modern Node can include candidate bytes.
  const message = error instanceof SyntaxError ? "invalid settings candidate JSON" : error.message;
  console.error(`Pi settings publication: ${message}`);
  process.exitCode = error.code === "ELOCKED" ? 3 : error.code === "ESTALE" ? 4 : 2;
} finally {
  try { release?.(); }
  finally { if (directory) rmSync(directory, { recursive: true, force: true }); }
}
