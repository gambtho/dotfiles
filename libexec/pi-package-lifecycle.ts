import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { closeSync, lstatSync, mkdirSync, openSync, readFileSync, readlinkSync, rmdirSync, rmSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, isAbsolute, join, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { DefaultPackageManager, type PackageSource, SettingsManager } from "@earendil-works/pi-coding-agent";
import { assertManagedPath as noLinks, managedPhysicalPath } from "./pi-managed-paths.mjs";

type Declaration = string | { source: string; [key: string]: unknown };
type Source = { identity: string; kind: "npm" | "git" | "local"; name: string; source: string };
type Inventory = Source & {
  state: "installed" | "absent" | "incomplete";
  installedPath?: string;
  resolution?: string;
  exactSource?: string;
  missingArtifacts: string[];
};
type Resolution = {
  identity: string;
  declaredSource: string;
  exactSource: string;
  kind: "npm" | "git";
  resolution: string;
};
type ResolutionManifest = {
  schemaVersion: 1;
  hostVersion: string;
  declarationDigest: string;
  packages: Resolution[];
};

function options(): { action: string; agentDir: string; repoRoot: string; hostRoot: string; manifest?: string } {
  const [action, ...args] = process.argv.slice(2);
  if (!["inspect", "bootstrap", "snapshot", "capture-recovery", "verify", "preflight", "update", "promote"].includes(action ?? "")) {
    throw new Error("unsupported lifecycle action");
  }
  const values = new Map<string, string>();
  for (let index = 0; index < args.length; index += 2) {
    const name = args[index]!;
    const value = args[index + 1];
    if (!["--agent-dir", "--repo-root", "--pi-package-root", "--manifest"].includes(name) ||
        values.has(name) || !value || !isAbsolute(value)) {
      throw new Error("lifecycle options require unique names and absolute paths");
    }
    values.set(name, resolve(value));
  }
  const agentDir = values.get("--agent-dir");
  const repoRoot = values.get("--repo-root");
  const hostRoot = values.get("--pi-package-root");
  const manifest = values.get("--manifest");
  if (!agentDir || !repoRoot || !hostRoot ||
      (["snapshot", "capture-recovery", "verify", "promote"].includes(action!) && !manifest)) {
    throw new Error("required lifecycle option missing");
  }
  return { action: action!, agentDir, repoRoot, hostRoot, manifest };
}

function object(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function jsonFile(path: string): Record<string, unknown> {
  try {
    const value: unknown = JSON.parse(readFileSync(path, "utf8"));
    if (object(value)) return value;
  } catch { /* Never echo file contents or JSON parser excerpts. */ }
  throw new Error(`malformed JSON config or metadata at ${path}`);
}

function present(path: string): boolean {
  try { lstatSync(path); return true; } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return false;
    throw error;
  }
}

function inside(root: string, path: string): boolean {
  const rel = relative(root, path);
  return rel === "" || (!rel.startsWith(`..${sep}`) && rel !== ".." && !isAbsolute(rel));
}

function validVersion(value: unknown): value is string {
  if (typeof value !== "string") return false;
  const match = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$/.exec(value);
  return !!match && (!match[4] || match[4].split(".").every(part => !/^0\d+$/.test(part)));
}

function sourceInfo(source: string, repoRoot: string, agentDir: string): Source {
  const npm = /^npm:((?:@[a-z0-9][a-z0-9._-]*\/)?[a-z0-9][a-z0-9._-]*)(?:@([^\s]+))?$/.exec(source);
  if (npm && (!npm[2] || validVersion(npm[2]))) {
    return { source, identity: `npm:${npm[1]}`, kind: "npm", name: npm[1]! };
  }
  const git = /^git:github\.com\/([A-Za-z0-9_-]+)\/([A-Za-z0-9_-][A-Za-z0-9._-]*)(?:@([A-Za-z0-9_./-]+))?$/.exec(source);
  if (git && !git[3]?.includes("..")) {
    const name = `${git[1]}/${git[2]}`;
    return { source, identity: `git:github.com/${name.toLowerCase().replace(/\.git$/, "")}`, kind: "git", name };
  }
  if (source.startsWith("/") || source.startsWith("./") || source.startsWith("../") || source.startsWith("~/")) {
    const path = source.startsWith("~/") ? join(homedir(), source.slice(2)) : resolve(agentDir, source);
    const suffix = "ai/marketplace/plugins/my";
    const isMy = path === join(repoRoot, suffix) || path === join(homedir(), ".dotfiles", suffix);
    return { source, identity: isMy ? "local:my" : `local:${path}`, kind: "local", name: path };
  }
  throw new Error("unsupported package source (value redacted)");
}

function declarations(settings: Record<string, unknown>, repoRoot: string, agentDir: string): Declaration[] {
  const packages = settings.packages ?? [];
  if (!Array.isArray(packages)) throw new Error("malformed package declarations");
  const identities = new Set<string>();
  for (const entry of packages) {
    const source = typeof entry === "string" ? entry : object(entry) ? entry.source : undefined;
    if (typeof source !== "string" || !source) throw new Error("malformed package declarations");
    const parsed = sourceInfo(source, repoRoot, agentDir);
    if (identities.has(parsed.identity)) throw new Error("duplicate package declarations");
    identities.add(parsed.identity);
    if (object(entry)) {
      for (const key of ["extensions", "skills", "prompts", "themes"]) {
        if (key in entry && (!Array.isArray(entry[key]) || !(entry[key] as unknown[]).every(value => typeof value === "string"))) {
          throw new Error("malformed package resource filters");
        }
      }
    }
  }
  return packages as Declaration[];
}

function declaredSource(entry: Declaration): string {
  return typeof entry === "string" ? entry : entry.source;
}

function stable(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(stable).join(",")}]`;
  if (object(value)) return `{${Object.keys(value).sort().map(key => `${JSON.stringify(key)}:${stable(value[key])}`).join(",")}}`;
  return JSON.stringify(value);
}

function digest(entries: Declaration[], repoRoot: string, agentDir: string): string {
  const normalized = entries.map(entry => {
    const parsed = sourceInfo(declaredSource(entry), repoRoot, agentDir);
    const source = parsed.kind === "local" ? parsed.identity : parsed.source;
    return typeof entry === "string" ? source : { ...entry, source };
  });
  return createHash("sha256").update(stable(normalized)).digest("hex");
}

function readonlyLookup<T>(settings: SettingsManager, lookup: () => T): T {
  const configured: unknown = settings.getSettings().npmCommand;
  const command = configured === undefined || (Array.isArray(configured) && configured.length === 0) ? ["npm"] : configured;
  const unsupported = () => new Error("unsupported-readonly-transport: use stock npm with optional --prefix ABS for lifecycle inventory; wrappers, pnpm/Bun and other options are not established readonly");
  if (!Array.isArray(command) || !command.every(value => typeof value === "string") ||
      !(command[0] === "npm" || (isAbsolute(command[0]) && basename(command[0]) === "npm")) || process.platform === "win32") {
    throw unsupported();
  }
  for (let index = 1; index < command.length; index++) {
    const arg = command[index]!;
    if (/^--(?:cache|logs-dir|logs-max|timing|update-notifier)(?:=|$)/i.test(arg)) {
      throw new Error("readonly lookup rejects explicit npm side-effect flags; remove cache/log/timing/update-notifier CLI overrides for inventory");
    }
    const prefix = arg === "--prefix" ? command[++index] : arg.startsWith("--prefix=") ? arg.slice(9) : undefined;
    if (!prefix || !isAbsolute(prefix)) throw unsupported();
  }
  // npm creates its cache unconditionally, and logs-max=0 still cleans old logs.
  // Both destinations must be sinks; timing and the network notifier are disabled.
  // Scope this only to synchronous SDK lookups, never to targeted installations.
  const controls = {
    npm_config_cache: "/dev/null", npm_config_logs_dir: "/dev/null",
    npm_config_logs_max: "0", npm_config_timing: "false", npm_config_update_notifier: "false",
  };
  const saved = new Map<string, string>();
  for (const key of Object.keys(process.env)) {
    if (/^npm_config_(cache|logs[-_]dir|logs[-_]max|timing|update[-_]notifier)$/i.test(key)) {
      saved.set(key, process.env[key]!);
      delete process.env[key];
    }
  }
  try {
    Object.assign(process.env, controls);
    return lookup();
  } finally {
    for (const key of Object.keys(controls)) delete process.env[key];
    for (const [key, value] of saved) process.env[key] = value;
  }
}

function inspectPackage(manager: DefaultPackageManager, settings: SettingsManager, parsed: Source, agentDir: string): Inventory {
  // These paths bound SDK installation destinations; they do not discover packages.
  const managed = parsed.kind === "npm" ? join(agentDir, "npm", "node_modules", parsed.name) :
    parsed.kind === "git" ? join(agentDir, "git", "github.com", parsed.name) : parsed.name;
  if (parsed.kind !== "local") noLinks(managed);
  const installedPath = readonlyLookup(settings, () => manager.getInstalledPath(parsed.source, "user"));
  if (parsed.kind !== "local" && installedPath) {
    noLinks(installedPath);
    if (!inside(managedPhysicalPath(agentDir), managedPhysicalPath(installedPath))) {
      throw new Error(`foreign package root for ${parsed.identity}`);
    }
  }
  const item: Inventory = { ...parsed, state: installedPath ? "installed" : "absent", installedPath, missingArtifacts: [] };
  if (!installedPath || parsed.kind === "local") return item;
  if (!lstatSync(installedPath).isDirectory()) throw new Error(`foreign package root for ${parsed.identity}`);
  if (parsed.kind === "npm") {
    const path = join(installedPath, "package.json");
    noLinks(path);
    if (!present(path)) item.missingArtifacts.push("package.json");
    else {
      const metadata = jsonFile(path);
      if (metadata.name !== parsed.name || !validVersion(metadata.version)) {
        throw new Error(`package metadata mismatch for ${parsed.identity}`);
      }
      item.resolution = metadata.version;
    }
    if (parsed.identity === "npm:@gotgenes/pi-permission-system") {
      const managerArtifact = present(join(installedPath, "src/policy"))
        ? "src/policy/permission-manager.ts" : "src/permission-manager.ts";
      for (const artifact of ["schemas/permissions.schema.json", managerArtifact]) {
        const path = join(installedPath, artifact);
        noLinks(path);
        if (!present(path) || !lstatSync(path).isFile()) item.missingArtifacts.push(artifact);
      }
    }
  } else {
    // Do not let rev-parse accidentally use an enclosing repository.
    noLinks(join(installedPath, ".git"));
    if (!present(join(installedPath, ".git")) || !lstatSync(join(installedPath, ".git")).isDirectory()) {
      item.missingArtifacts.push(".git");
    } else {
      try {
        const head = execFileSync("git", ["-C", installedPath, "rev-parse", "--verify", "HEAD^{commit}"], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim();
        if (!/^[0-9a-f]{40}$/.test(head)) throw new Error("invalid HEAD");
        item.resolution = head;
      } catch { item.missingArtifacts.push("HEAD"); }
    }
  }
  if (item.resolution) item.exactSource = `${parsed.identity}@${item.resolution}`;
  if (item.missingArtifacts.length) item.state = "incomplete";
  return item;
}

function requireHealthy(items: Inventory[]): Resolution[] {
  if (items.some(item => item.kind === "local" && item.state !== "installed")) {
    throw new Error("unresolved local package in reviewed inventory");
  }
  return items.filter(item => item.kind !== "local").map(item => {
    if (item.state !== "installed" || !item.resolution || !item.exactSource) {
      throw new Error(`unresolved ${item.state} package ${item.identity}: ${item.missingArtifacts.join(", ")}`);
    }
    return { identity: item.identity, declaredSource: item.source, exactSource: item.exactSource,
      kind: item.kind as "npm" | "git", resolution: item.resolution };
  });
}

function privateDestination(path: string, writing: boolean): void {
  noLinks(path);
  const dir = dirname(path);
  if (present(dir)) {
    const stat = lstatSync(dir);
    if (!stat.isDirectory() || (stat.mode & 0o777) !== 0o700 || stat.uid !== process.getuid?.()) {
      throw new Error("unsafe manifest destination directory (requires owned 0700)");
    }
  } else if (!writing) throw new Error("manifest destination does not exist");
  if (present(path)) {
    const stat = lstatSync(path);
    if (writing || !stat.isFile() || (stat.mode & 0o777) !== 0o600 || stat.uid !== process.getuid?.()) {
      throw new Error("unsafe or already existing manifest destination");
    }
  } else if (!writing) throw new Error("manifest destination does not exist");
}

function writePrivate(path: string, value: unknown): void {
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
  const fd = openSync(path, "wx", 0o600);
  try {
    writeFileSync(fd, `${JSON.stringify(value, null, 2)}\n`);
  } catch (error) {
    rmSync(path, { force: true });
    throw error;
  } finally {
    closeSync(fd);
  }
}

function validateManifest(value: Record<string, unknown>, repoRoot: string, agentDir: string): ResolutionManifest {
  if (Object.keys(value).sort().join(",") !== "declarationDigest,hostVersion,packages,schemaVersion" ||
      value.schemaVersion !== 1 || !validVersion(value.hostVersion) ||
      typeof value.declarationDigest !== "string" || !/^[0-9a-f]{64}$/.test(value.declarationDigest) || !Array.isArray(value.packages)) {
    throw new Error("invalid resolution manifest schema");
  }
  const identities = new Set<string>();
  for (const item of value.packages) {
    if (!object(item) || Object.keys(item).sort().join(",") !== "declaredSource,exactSource,identity,kind,resolution" ||
        typeof item.declaredSource !== "string" || typeof item.exactSource !== "string") {
      throw new Error("invalid resolution manifest package");
    }
    const source = sourceInfo(item.declaredSource, repoRoot, agentDir);
    if (source.kind === "local" || source.kind !== item.kind || source.identity !== item.identity || identities.has(source.identity) ||
        !(source.kind === "npm" ? validVersion(item.resolution) : typeof item.resolution === "string" && /^[0-9a-f]{40}$/.test(item.resolution)) ||
        item.exactSource !== `${source.identity}@${item.resolution}`) {
      throw new Error("invalid resolution manifest identity or exact resolution");
    }
    identities.add(source.identity);
  }
  return value as ResolutionManifest;
}

function reviewedManifest(path: string, reviewed: Declaration[], hostVersion: string, repoRoot: string, agentDir: string): ResolutionManifest {
  privateDestination(path, false);
  const saved = validateManifest(jsonFile(path), repoRoot, agentDir);
  if (saved.hostVersion !== hostVersion) throw new Error("resolution manifest host version mismatch");
  if (saved.declarationDigest !== digest(reviewed, repoRoot, agentDir)) {
    throw new Error("resolution manifest declaration/filter digest mismatch");
  }
  const remotes = reviewed.map(entry => sourceInfo(declaredSource(entry), repoRoot, agentDir)).filter(item => item.kind !== "local");
  if (saved.packages.length !== remotes.length || saved.packages.some((item, index) =>
    item.identity !== remotes[index]!.identity || item.declaredSource !== remotes[index]!.source)) {
    throw new Error("resolution manifest differs from reviewed package declarations");
  }
  return saved;
}

function gitCommand(path: string, args: string[]): string {
  return execFileSync("git", ["-C", path, ...args], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim();
}

function cleanGit(item: Inventory): void {
  if (item.kind !== "git" || !item.installedPath) return;
  if (item.state !== "installed") throw new Error(`incomplete Git checkout ${item.identity}`);
  if (gitCommand(item.installedPath, ["status", "--porcelain", "--untracked-files=all"])) {
    throw new Error(`dirty Git checkout ${item.identity}; preserve user edits before updating`);
  }
  if (gitCommand(item.installedPath, ["remote", "get-url", "--all", "origin"]) !== `https://${item.identity.slice(4)}`) {
    throw new Error(`unreviewed Git origin for ${item.identity}`);
  }
}

function defaultGitHead(item: Inventory): { branch: string; sha: string } {
  const remote = `https://${item.identity.slice(4)}`;
  const output = execFileSync("git", ["ls-remote", "--symref", remote, "HEAD"], {
    encoding: "utf8", stdio: ["ignore", "pipe", "pipe"],
  }).trim();
  const lines = output.split("\n");
  const target = /^ref: refs\/heads\/([^\s]+)\tHEAD$/.exec(lines[0] ?? "");
  const commit = /^([0-9a-f]{40})\tHEAD$/.exec(lines[1] ?? "");
  if (lines.length !== 2 || !target || !commit) throw new Error(`malformed or missing Git default HEAD for ${item.identity}`);
  try {
    execFileSync("git", ["check-ref-format", `refs/heads/${target[1]}`], { stdio: "ignore" });
  } catch { throw new Error(`invalid Git default branch for ${item.identity}`); }
  return { branch: target[1]!, sha: commit[1]! };
}

function refuseYolo(agentDir: string): void {
  const policy = join(agentDir, "extensions/pi-permission-system/config.json");
  if (present(policy) && jsonFile(policy).yoloMode === true) throw new Error("refusing update while YOLO is active; disable YOLO first");
}

function recoveryConfigs(agentDir: string, repoRoot: string): Array<{
  destination: string; state: "absent" | "regular-file" | "owned-link"; linkTarget?: string; missingTarget?: true; content?: Buffer;
}> {
  const files = [
    ["settings.json", "ai/pi/settings.json"],
    ["modes.json", "ai/pi/config/modes.json"],
    ["models.json", "ai/pi/config/models.json"],
    ["subagents.json", "ai/pi/config/subagents.json"],
    ["extensions/pi-permission-system/config.json", "ai/pi/config/permission-system.json"],
    ["pi-file-context.json", "ai/pi/config/file-context.json"],
    ["dotfiles-migrations.json", undefined],
  ];
  return files.map(([name, authored]) => {
    const destination = join(agentDir, name!);
    noLinks(dirname(destination));
    if (!present(destination)) return { destination, state: "absent" };
    const stat = lstatSync(destination);
    if (stat.uid !== process.getuid?.()) throw new Error(`foreign config destination ${destination}`);
    let linkTarget: string | undefined;
    if (stat.isSymbolicLink()) {
      linkTarget = readlinkSync(destination);
      const target = resolve(dirname(destination), linkTarget);
      const legacyModes = name === "modes.json" &&
        [join(repoRoot, "ai/pi/modes.json"), join(homedir(), ".dotfiles/ai/pi/modes.json")].includes(target);
      if (!legacyModes && (!authored || ![join(repoRoot, authored), join(homedir(), ".dotfiles", authored)].includes(target))) {
        throw new Error(`foreign config link ${destination}`);
      }
      noLinks(target);
      // Retired model and historical modes targets can be missing. Capture
      // their owned link identities before conversion; other dangling links fail.
      if ((name === "models.json" || legacyModes) && !present(target)) {
        return { destination, state: "owned-link", linkTarget, missingTarget: true };
      }
    } else if (!stat.isFile()) throw new Error(`foreign config destination ${destination}`);
    jsonFile(destination);
    return { destination, state: linkTarget === undefined ? "regular-file" : "owned-link", linkTarget, content: readFileSync(destination) };
  });
}

async function main(): Promise<void> {
  const { action, agentDir, repoRoot, hostRoot, manifest } = options();
  noLinks(agentDir);
  if (manifest) {
    const reserved = ["settings.json", "modes.json", "models.json", "subagents.json", "pi-file-context.json", "dotfiles-migrations.json", "auth.json", "trust.json"];
    const trees = [hostRoot, join(repoRoot, "ai"), ...["npm", "git", "extensions", "sessions"].map(name => join(agentDir, name))];
    const destination = managedPhysicalPath(manifest);
    const physicalAgentDir = managedPhysicalPath(agentDir);
    if (!manifest.endsWith(".json") || reserved.some(name => destination === join(physicalAgentDir, name)) ||
        trees.some(root => inside(managedPhysicalPath(root), destination))) {
      throw new Error("unsafe manifest destination in configuration, package, or protected store");
    }
  }
  // Validate link ownership before even reading prior settings or backup data.
  const explicit = ["preflight", "capture-recovery", "update", "promote"].includes(action);
  const configs = explicit ? recoveryConfigs(agentDir, repoRoot) : undefined;
  if (explicit) refuseYolo(agentDir);
  const settingsPath = join(agentDir, "settings.json");
  if (!configs) noLinks(settingsPath);
  const runtimeSettings = present(settingsPath) ? jsonFile(settingsPath) : {};
  const prior = declarations(runtimeSettings, repoRoot, agentDir);
  const projectPath = join(repoRoot, ".pi", "settings.json");
  noLinks(projectPath);
  if (present(projectPath) && declarations(jsonFile(projectPath), repoRoot, agentDir).length) {
    throw new Error("unexpected project scope package contamination");
  }
  const reviewedPath = join(repoRoot, "ai", "pi", "settings.json");
  noLinks(reviewedPath);
  const reviewed = declarations(jsonFile(reviewedPath), repoRoot, agentDir);
  const declarationDigest = digest(prior, repoRoot, agentDir);
  if (["bootstrap", "snapshot", "verify", "update", "promote"].includes(action) && declarationDigest !== digest(reviewed, repoRoot, agentDir)) {
    throw new Error("runtime declarations differ from reviewed authored inventory");
  }
  const hostVersion = jsonFile(join(hostRoot, "package.json")).version;
  if (!validVersion(hostVersion)) throw new Error("invalid selected host version");
  const promotion = manifest && ["preflight", "promote"].includes(action) ?
    reviewedManifest(manifest, reviewed, hostVersion, repoRoot, agentDir) : undefined;
  // create() takes filesystem locks even when reading. The public in-memory
  // loader retains host semantics without transient writes or trust-store access.
  const settingsManager = SettingsManager.inMemory(
    { ...runtimeSettings, packages: prior as PackageSource[] }, { projectTrusted: false },
  );
  const manager = new DefaultPackageManager({ cwd: repoRoot, agentDir, settingsManager });
  // Keep inventory on the stock readonly transport. Only Git installs use the
  // scoped subprocess wrapper, after clone/reset exposes that revision's locks.
  const installPackage = async (item: Inventory, source: string): Promise<void> => {
    if (item.kind !== "git") return manager.install(source);
    const command = runtimeSettings.npmCommand as string[] | undefined;
    const npmCommand = command?.length ? command : ["npm"];
    const installSettings = SettingsManager.inMemory({
      ...runtimeSettings, packages: prior as PackageSource[],
      npmCommand: [process.execPath, join(dirname(fileURLToPath(import.meta.url)), "pi-git-npm-install.mjs"), hostRoot, repoRoot, agentDir, source, "--", ...npmCommand],
    }, { projectTrusted: false });
    const installer = new DefaultPackageManager({ cwd: repoRoot, agentDir, settingsManager: installSettings });
    await installer.install(source);
  };
  const configured = readonlyLookup(settingsManager, () => manager.listConfiguredPackages());
  if (configured.some(item => item.scope !== "user")) throw new Error("unexpected project scope package contamination");
  if (stable(configured.map(item => item.source)) !== stable(prior.map(declaredSource))) {
    throw new Error("host package inventory disagrees with declarations");
  }
  const entries = ["capture-recovery", "preflight"].includes(action) ? [...prior, ...reviewed.filter(entry =>
    !prior.some(old => sourceInfo(declaredSource(old), repoRoot, agentDir).identity === sourceInfo(declaredSource(entry), repoRoot, agentDir).identity))] : prior;
  let items = entries.map(entry => inspectPackage(manager, settingsManager, sourceInfo(declaredSource(entry), repoRoot, agentDir), agentDir));
  if (["preflight", "update", "promote"].includes(action)) {
    // Inspect every prior/incoming destination before any network refresh or install.
    for (const item of items) cleanGit(item);
    for (const entry of reviewed) {
      const item = sourceInfo(declaredSource(entry), repoRoot, agentDir);
      if (item.kind === "local" && !present(item.name)) throw new Error("unresolved local package in reviewed inventory");
    }
  }
  if (action === "update" || action === "promote") {
    const candidates = new Map<string, { branch: string; sha: string }>();
    if (action === "update") {
      for (const item of items.filter(item => item.kind === "git")) candidates.set(item.identity, defaultGitHead(item));
    }
    for (const item of items) {
      if (item.kind === "local") continue;
      if (action === "promote") {
        const selected = promotion!.packages.find(entry => entry.identity === item.identity)!;
        await installPackage(item, selected.exactSource);
        const checked = inspectPackage(manager, settingsManager, item, agentDir);
        if (checked.state !== "installed" || checked.exactSource !== selected.exactSource) {
          throw new Error(`promoted resolution differs from manifest for ${item.identity}`);
        }
      } else if (item.kind === "npm") {
        await installPackage(item, item.identity);
      } else {
        let selected = candidates.get(item.identity)!;
        let installed = false;
        // A moving default branch is rediscovered, never mislabeled as a sealed candidate.
        for (let attempt = 0; attempt < 3; attempt++) {
          cleanGit(inspectPackage(manager, settingsManager, item, agentDir));
          if (item.installedPath) {
            gitCommand(item.installedPath, ["fetch", "--no-tags", `https://${item.identity.slice(4)}`, `refs/heads/${selected.branch}`]);
            const fetched = gitCommand(item.installedPath, ["rev-parse", "--verify", "FETCH_HEAD^{commit}"]);
            if (fetched !== selected.sha) { selected = defaultGitHead(item); continue; }
          }
          await installPackage(item, `${item.identity}@${selected.sha}`);
          const checked = inspectPackage(manager, settingsManager, item, agentDir);
          const current = defaultGitHead(item);
          if (checked.state === "installed" && checked.resolution === selected.sha && current.sha === selected.sha && current.branch === selected.branch) {
            installed = true;
            break;
          }
          selected = current;
        }
        if (!installed) throw new Error(`Git default HEAD advanced during candidate installation for ${item.identity}`);
      }
      if (digest(declarations(jsonFile(settingsPath), repoRoot, agentDir), repoRoot, agentDir) !== declarationDigest) {
        throw new Error("install API mutated package declarations");
      }
    }
    items = entries.map(entry => inspectPackage(manager, settingsManager, sourceInfo(declaredSource(entry), repoRoot, agentDir), agentDir));
    for (const item of items) cleanGit(item);
    const packages = requireHealthy(items);
    if (promotion && stable(packages) !== stable(promotion.packages)) throw new Error("installed package resolution differs from manifest");
  }
  if (action === "bootstrap") {
    if (items.some(item => item.kind === "local" && item.state !== "installed")) {
      throw new Error("unresolved local package in reviewed inventory");
    }
    for (const item of items) {
      if (item.state === "incomplete" && (item.identity !== "npm:@gotgenes/pi-permission-system" || !item.exactSource)) {
        throw new Error(`incomplete package metadata for ${item.identity}`);
      }
    }
    const cached = items.filter(item => item.kind !== "local" && item.resolution !== undefined);
    const healthRequired = new Set(cached.filter(item => item.state === "installed").map(item => item.identity));
    for (const item of items) {
      if (item.kind === "local" || item.state === "installed") continue;
      await installPackage(item, item.state === "incomplete" ? item.exactSource! : item.source);
      const after = declarations(jsonFile(settingsPath), repoRoot, agentDir);
      if (digest(after, repoRoot, agentDir) !== declarationDigest) throw new Error("install API mutated package declarations");
      const checked = inspectPackage(manager, settingsManager, item, agentDir);
      if (checked.state !== "installed") throw new Error(`incomplete package ${item.identity}: ${checked.missingArtifacts.join(", ")}`);
      if (item.state === "incomplete") healthRequired.add(item.identity);
      // Pending repairs may remain incomplete until their own successful install.
      // Initially healthy and repaired caches must retain both health and resolution.
      if (cached.some(old => {
        const current = inspectPackage(manager, settingsManager, old, agentDir);
        return current.resolution !== old.resolution || (healthRequired.has(old.identity) && current.state !== "installed");
      })) {
        throw new Error("install API changed a healthy or incomplete cached resolution or required package health");
      }
    }
    items = entries.map(entry => inspectPackage(manager, settingsManager, sourceInfo(declaredSource(entry), repoRoot, agentDir), agentDir));
    requireHealthy(items);
  }
  if (action === "snapshot" || action === "verify") {
    for (const item of items) cleanGit(item);
    const packages = requireHealthy(items);
    const expected: ResolutionManifest = { schemaVersion: 1, hostVersion, declarationDigest, packages };
    privateDestination(manifest!, action === "snapshot");
    if (action === "snapshot") writePrivate(manifest!, expected);
    else {
      const saved = validateManifest(jsonFile(manifest!), repoRoot, agentDir);
      if (saved.declarationDigest !== declarationDigest) throw new Error("resolution manifest declaration/filter digest mismatch");
      if (saved.hostVersion !== hostVersion) throw new Error("resolution manifest host version mismatch");
      if (stable(saved.packages) !== stable(packages)) throw new Error("installed package resolution differs from manifest");
    }
    console.log(JSON.stringify({ action, packages: packages.length, manifest }));
  } else if (action === "capture-recovery") {
    // Every destination and all inputs were preflighted before any backup write.
    privateDestination(manifest!, true);
    const backupDir = join(dirname(manifest!), `${manifest!.split(sep).pop()}.backups`);
    noLinks(backupDir);
    if (present(backupDir)) throw new Error("recovery backup destination already exists");
    let parentCreated = false;
    let backupsCreated = false;
    try {
      if (!present(dirname(manifest!))) {
        mkdirSync(dirname(manifest!), { recursive: true, mode: 0o700 });
        parentCreated = true;
      }
      if (configs!.some(config => config.content)) {
        mkdirSync(backupDir, { mode: 0o700 });
        backupsCreated = true;
      }
      const configBackups = configs!.map((config, index) => {
        const { content, ...entry } = config;
        if (!content) return entry;
        const backupPath = join(backupDir, `${index}.json`);
        writeFileSync(backupPath, content, { mode: 0o600, flag: "wx" });
        return { ...entry, backupPath };
      });
      const packages = items.filter(item => item.kind !== "local").map(item => ({
        identity: item.identity, declaredSource: item.source, state: item.state,
        exactSource: item.exactSource, resolution: item.resolution,
        ...(item.missingArtifacts.length ? { missingArtifacts: item.missingArtifacts } : {}),
      }));
      writePrivate(manifest!, { schemaVersion: 1, kind: "pre-update-recovery", hostVersion, priorDeclarations: prior, packages, configBackups });
      console.log(JSON.stringify({ action, packages: packages.length, manifest }));
    } catch (error) {
      // Remove only scratch successfully created by this capture, never siblings.
      if (backupsCreated) rmSync(backupDir, { recursive: true, force: true });
      if (parentCreated) {
        try { rmdirSync(dirname(manifest!)); } catch (cleanupError) {
          throw new Error(`recovery capture failed; scratch cleanup also failed at ${dirname(manifest!)}`, { cause: cleanupError });
        }
      }
      throw error;
    }
  } else if (action === "preflight") {
    console.log(JSON.stringify({ action, packages: items.length, promotion: !!promotion }));
  } else {
    console.log(JSON.stringify({ schemaVersion: 1, hostVersion, declarationDigest, packages: items }));
  }
  const after = declarations(present(settingsPath) ? jsonFile(settingsPath) : {}, repoRoot, agentDir);
  const inMemory = declarations({ ...settingsManager.getGlobalSettings() }, repoRoot, agentDir);
  if (digest(after, repoRoot, agentDir) !== declarationDigest || digest(inMemory, repoRoot, agentDir) !== declarationDigest) {
    throw new Error("API mutated package declarations");
  }
}

main().catch(error => {
  console.error(`error: ${error instanceof Error ? error.message : "package lifecycle failed"}`);
  process.exitCode = 1;
});
