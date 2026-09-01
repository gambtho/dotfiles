import {
  cpSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

type PermissionState = "allow" | "ask" | "deny";

type PermissionManagerLike = {
  configureForCwd(cwd: string): void;
  getConfigIssues(agentName?: string): string[];
  getToolPermission(toolName: string, agentName?: string): PermissionState;
  check(intent: Record<string, unknown>): { state: PermissionState };
};

function option(name: string): string {
  const index = process.argv.indexOf(name);
  if (index === -1 || !process.argv[index + 1]) {
    throw new Error(`${name} is required`);
  }
  return process.argv[index + 1]!;
}

function renderAgentDir(value: unknown, agentDir: string): unknown {
  if (typeof value === "string") return value.replaceAll("__PI_AGENT_DIR__", agentDir);
  if (Array.isArray(value)) return value.map((entry) => renderAgentDir(entry, agentDir));
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value).map(([key, entry]) => [
        key.replaceAll("__PI_AGENT_DIR__", agentDir),
        renderAgentDir(entry, agentDir),
      ]),
    );
  }
  return value;
}

function expectState(label: string, actual: PermissionState, expected: PermissionState): void {
  if (actual !== expected) {
    throw new Error(`${label}: expected ${expected}, received ${actual}`);
  }
}

function checkBash(
  manager: PermissionManagerLike,
  command: string,
  expected: PermissionState,
  agentName?: string,
): void {
  expectState(
    `${agentName ?? "global"} bash ${JSON.stringify(command)}`,
    manager.check({ kind: "tool", surface: "bash", input: { command }, agentName }).state,
    expected,
  );
}

function checkPath(
  manager: PermissionManagerLike,
  surface: "path_read" | "path_write" | "external_directory_read",
  value: string,
  expected: PermissionState,
): void {
  expectState(
    `${surface} ${value}`,
    manager.check({ kind: "path-values", surface, values: [value] }).state,
    expected,
  );
}

const packageRoot = option("--package-root");
const repoRoot = option("--repo-root");
const packageJson = JSON.parse(readFileSync(join(packageRoot, "package.json"), "utf8")) as {
  version?: string;
};
if (packageJson.version !== "29.2.0") {
  throw new Error(`expected pi-permission-system 29.2.0, received ${packageJson.version ?? "unknown"}`);
}

const temporaryRoot = mkdtempSync(join(tmpdir(), "pi-permission-validation-"));
const agentDir = join(temporaryRoot, "agent");
const configDir = join(agentDir, "extensions", "pi-permission-system");
const agentsDir = join(agentDir, "agents");

try {
  mkdirSync(configDir, { recursive: true });
  mkdirSync(agentsDir, { recursive: true });

  const baseline = JSON.parse(
    readFileSync(join(repoRoot, "ai", "pi", "config", "permission-system.json"), "utf8"),
  ) as unknown;
  writeFileSync(
    join(configDir, "config.json"),
    `${JSON.stringify(renderAgentDir(baseline, agentDir), null, 2)}\n`,
  );
  cpSync(join(repoRoot, "ai", "pi", "agents"), agentsDir, { recursive: true });

  const moduleUrl = pathToFileURL(join(packageRoot, "src", "permission-manager.ts")).href;
  const loaded = (await import(moduleUrl)) as {
    PermissionManager: new (options: {
      agentDir: string;
      isYoloEnabled?: () => boolean;
    }) => PermissionManagerLike;
  };
  const manager = new loaded.PermissionManager({ agentDir });
  manager.configureForCwd(repoRoot);

  const issueScopes = [undefined, "rush", "smart", "deep", "review"] as const;
  const issues = issueScopes.flatMap((agentName) =>
    manager.getConfigIssues(agentName).map((issue) => `${agentName ?? "global"}: ${issue}`),
  );
  if (issues.length > 0) {
    throw new Error(`permission config issues:\n${issues.map((issue) => `- ${issue}`).join("\n")}`);
  }

  expectState(
    "read tool",
    manager.check({ kind: "tool", surface: "read", input: { path: "README.md" } }).state,
    "allow",
  );
  expectState(
    "lsp_fix tool",
    manager.check({ kind: "tool", surface: "lsp_fix", input: { path: "README.md" } }).state,
    "ask",
  );
  expectState(
    "unknown tool",
    manager.check({ kind: "tool", surface: "unknown_extension_tool", input: {} }).state,
    "ask",
  );

  checkBash(manager, "git status", "allow");
  checkBash(manager, "git push origin main", "ask");
  checkBash(manager, "git diff --ext-diff HEAD", "ask");
  checkBash(manager, "git log --ext-diff -1", "ask");
  checkBash(manager, "rg --pre cat pattern .", "deny");
  checkBash(manager, "fd --exec rm {}", "deny");
  checkBash(manager, "yq -i '.x = 1' config.yaml", "ask");
  checkBash(manager, "sudo true", "deny");

  const authPath = join(agentDir, "auth.json");
  checkPath(manager, "path_read", authPath, "deny");
  checkPath(manager, "path_write", authPath, "deny");
  checkPath(manager, "external_directory_read", "/opt/pi-security-test/file", "ask");

  for (const agentName of ["rush", "deep", "review"] as const) {
    expectState(`${agentName} write tool`, manager.getToolPermission("write", agentName), "deny");
    checkBash(manager, "git status", "allow", agentName);
    checkBash(manager, "gh pr view 1", "ask", agentName);
    checkBash(manager, "make check", "ask", agentName);
    checkBash(manager, "gh repo delete owner/repo", "deny", agentName);
    checkBash(manager, "gh api repos/o/r --method DELETE", "deny", agentName);
  }

  const yolo = new loaded.PermissionManager({ agentDir, isYoloEnabled: () => true });
  yolo.configureForCwd(repoRoot);
  checkBash(yolo, "git push origin main", "allow");
  checkBash(yolo, "sudo true", "deny");
  checkBash(yolo, "rg --pre cat pattern .", "deny");
  checkPath(yolo, "path_read", authPath, "deny");
  for (const agentName of ["rush", "deep", "review"] as const) {
    checkBash(yolo, "gh repo delete owner/repo", "deny", agentName);
    checkBash(yolo, "gh api repos/o/r --method DELETE", "deny", agentName);
  }

  console.log("Pi permission schema and deterministic engine validation passed.");
} finally {
  rmSync(temporaryRoot, { recursive: true, force: true });
}
