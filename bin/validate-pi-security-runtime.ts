import {
  cpSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { homedir, tmpdir } from "node:os";
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
  const bashProgramUrl = pathToFileURL(
    join(packageRoot, "src", "access-intent", "bash", "program.ts"),
  ).href;
  const pathNormalizerUrl = pathToFileURL(join(packageRoot, "src", "path-normalizer.ts")).href;
  const pathFlavorUrl = pathToFileURL(
    join(packageRoot, "src", "path", "path-flavor.ts"),
  ).href;
  const gateUrl = pathToFileURL(
    join(packageRoot, "src", "handlers", "gates", "bash-command.ts"),
  ).href;
  const [loaded, bashLoaded, normalizerLoaded, flavorLoaded, gateLoaded] = await Promise.all([
    import(moduleUrl) as Promise<{
      PermissionManager: new (options: {
        agentDir: string;
        isYoloEnabled?: () => boolean;
      }) => PermissionManagerLike;
    }>,
    import(bashProgramUrl) as Promise<{
      BashProgram: {
        parse(
          command: string,
          normalizer: unknown,
        ): Promise<{
          commands(): Array<{
            text: string;
            wrapperKind?: string;
            executedUnit?: string;
            floorExemption?: string;
          }>;
          pathRuleCandidates(): Array<{
            token: string;
            path: { matchValues(): string[] };
            effect: { effect: "read" | "write" | "unknown" };
          }>;
        }>;
      };
    }>,
    import(pathNormalizerUrl) as Promise<{
      PathNormalizer: new (flavor: unknown, cwd: string) => unknown;
    }>,
    import(pathFlavorUrl) as Promise<{ posixPathFlavor: unknown }>,
    import(gateUrl) as Promise<{
      resolveBashCommandCheck(
        command: string,
        commands: Array<{
          text: string;
          wrapperKind?: string;
          executedUnit?: string;
          floorExemption?: string;
        }>,
        agentName: string | undefined,
        resolver: {
          resolve(intent: Record<string, unknown>): { state: PermissionState };
          getToolPermission(toolName: string, agentName?: string): PermissionState;
        },
      ): { state: PermissionState };
    }>,
  ]);
  const manager = new loaded.PermissionManager({ agentDir });
  const pathNormalizer = new normalizerLoaded.PathNormalizer(flavorLoaded.posixPathFlavor, repoRoot);

  async function checkBashGate(command: string, expected: PermissionState): Promise<void> {
    const program = await bashLoaded.BashProgram.parse(command, pathNormalizer);
    const actual = gateLoaded.resolveBashCommandCheck(command, program.commands(), undefined, {
      resolve: (intent) => manager.check(intent),
      getToolPermission: (toolName, agentName) => manager.getToolPermission(toolName, agentName),
    }).state;
    expectState(`global bash gate ${JSON.stringify(command)}`, actual, expected);
  }

  async function checkBashPath(
    scopedManager: PermissionManagerLike,
    command: string,
    expected: PermissionState,
    agentName?: string,
  ): Promise<void> {
    const program = await bashLoaded.BashProgram.parse(command, pathNormalizer);
    let actual: PermissionState = "allow";
    for (const candidate of program.pathRuleCandidates()) {
      const surface =
        candidate.effect.effect === "read"
          ? "path_read"
          : candidate.effect.effect === "write"
            ? "path_write"
            : "path";
      const state = scopedManager.check({
        kind: "path-values",
        surface,
        values: candidate.path.matchValues(),
        agentName,
      }).state;
      if (state === "deny") {
        actual = "deny";
        break;
      }
      if (state === "ask") actual = "ask";
    }
    expectState(`${agentName ?? "global"} bash path ${JSON.stringify(command)}`, actual, expected);
  }
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

  checkBash(manager, "printf hello", "allow");
  checkBash(manager, 'printf "$HOME"', "ask");
  checkBash(manager, "node --version", "allow");
  checkBash(manager, "env", "ask");
  checkBash(manager, "/usr/bin/env", "ask");
  checkBash(manager, "printenv", "ask");
  checkBash(manager, "export -p", "ask");
  checkBash(manager, "declare -x", "ask");
  checkBash(manager, "typeset -x", "ask");
  checkBash(manager, "command env", "ask");
  checkBash(manager, "git status", "allow");
  checkBash(manager, "/tmp/git status", "ask");
  checkBash(manager, "/tmp/git branch --show-current", "ask");
  checkBash(manager, "/tmp/git worktree list --porcelain", "ask");
  checkBash(manager, "git branch --show-current", "allow");
  checkBash(manager, "git branch feature/example", "allow");
  checkBash(manager, "git worktree add /tmp/example -b feature/example", "allow");
  checkBash(manager, "/usr/bin/git worktree list", "ask");
  checkBash(manager, "git worktree remove /tmp/example", "allow");
  checkBash(manager, "git add README.md", "allow");
  checkBash(manager, "git commit -am message", "allow");
  checkBash(manager, "/usr/bin/git commit -am message", "ask");
  checkBash(manager, "git fetch", "allow");
  checkBash(manager, "git fetch origin", "allow");
  checkBash(manager, "git fetch upstream", "ask");
  checkBash(manager, "git fetch origin main", "ask");
  checkBash(manager, "git pull origin main", "ask");
  checkBash(manager, "git pull --rebase origin main", "ask");
  checkBash(manager, "git pull --ff-only", "allow");
  checkBash(manager, "git pull --ff-only origin main", "ask");
  checkBash(manager, "git pull --ff-only --no-ff origin main", "ask");
  checkBash(manager, "git pull --ff-only --ff origin main", "ask");
  checkBash(manager, "git pull --ff-only --re''base origin main", "ask");
  checkBash(manager, "git pull --ff-only -qr origin main", "ask");
  await checkBashGate("cd docs/private && git pull --ff-only", "allow");
  checkBash(manager, "git -C . fetch origin", "ask");
  checkBash(manager, "git -C . pull --ff-only origin main", "ask");
  checkBash(manager, "git push origin main", "ask");
  checkBash(manager, "git clone https://example.com/repo.git", "ask");
  checkBash(manager, "git --git-dir=.git push origin main", "ask");
  checkBash(manager, "git -C . fetch origin status", "ask");
  checkBash(manager, "git -C . -c 'alias.x=!printf bypass' x status", "ask");
  checkBash(manager, "git -c core.sshCommand=false fetch origin", "ask");
  checkBash(manager, "git send-pack origin HEAD:main", "ask");
  checkBash(manager, "git submodule add https://example.com/repo.git vendor/repo", "ask");
  checkBash(manager, "git maintenance run --task=prefetch", "ask");
  checkBash(manager, "git credential fill", "ask");
  checkBash(manager, "git -c 'alias.x=!printf bypass' x", "ask");
  checkBash(manager, "git statusx", "ask");
  checkBash(manager, "git branchx feature/example", "ask");
  checkBash(manager, "git commitx -am message", "ask");
  checkBash(manager, "git switch my-feature", "allow");
  checkBash(manager, "git rm docs/my-file.md", "allow");
  checkBash(manager, "git worktree remove /tmp/my-feature", "allow");
  checkBash(manager, "git branch -D feature/example", "ask");
  checkBash(manager, "git branch -f feature/example HEAD", "ask");
  checkBash(manager, "git branch --del feature/example", "ask");
  checkBash(manager, "git branch -M feature/example", "ask");
  checkBash(manager, "git tag -a -f example HEAD", "ask");
  checkBash(manager, "git switch -q -f feature/example", "ask");
  checkBash(manager, "git switch -C feature/example", "ask");
  checkBash(manager, "git reset --keep HEAD~1", "ask");
  checkBash(manager, "git rm -f README.md", "ask");
  checkBash(manager, "git rebase -i -x 'printf example' HEAD~2", "ask");
  checkBash(manager, "git archive --rem=origin HEAD", "ask");
  checkBash(manager, "git grep -Oless pattern", "ask");
  checkBash(manager, "git grep -nOless pattern", "ask");
  checkBash(manager, "git grep --open=less pattern", "ask");
  checkBash(manager, "git grep --op=less pattern", "ask");
  checkBash(manager, "git branch --format='%(refname)'", "allow");
  checkBash(manager, "git tag --format='%(refname)'", "allow");
  checkBash(manager, "git push --follow-tags origin main", "ask");
  checkBash(manager, "git push --no-verify origin main", "ask");
  checkBash(manager, "git push --repo=foo main", "ask");
  checkBash(manager, "git diff --ext-d HEAD", "ask");
  checkBash(manager, "git log --textc -p -1", "ask");
  checkBash(manager, "git update-ref -d refs/heads/feature/example", "ask");
  checkBash(manager, "git worktree remove --force /tmp/example", "ask");
  checkBash(manager, "git -C . worktree remove --force /tmp/example", "ask");
  checkBash(manager, "git commit --amend --no-edit", "ask");
  checkBash(manager, "git -C . commit --amend --no-edit", "ask");
  checkBash(manager, "git restore README.md", "ask");
  checkBash(manager, "gh pr create --title example", "ask");
  checkBash(manager, "/usr/bin/gh pr create --title example", "ask");
  checkBash(manager, "curl https://example.com", "ask");
  checkBash(manager, "/usr/bin/curl https://example.com", "ask");
  checkBash(manager, "rm -f /tmp/example", "ask");
  checkBash(manager, "rm -rf /tmp/example", "ask");
  checkBash(manager, "/bin/rm -rf .", "ask");
  checkBash(manager, "nc example.com 443", "ask");
  checkBash(manager, '/bin/cat "$SECRET_PATH"', "ask");
  await checkBashGate("cd . && curl https://example.com", "ask");
  await checkBashGate("env gh pr create --title example", "ask");
  await checkBashGate("sh -c 'git push origin main'", "ask");
  checkBash(manager, "git show --ext-diff HEAD", "ask");
  checkBash(manager, "git show --textconv HEAD:file", "ask");
  checkBash(manager, "git diff --ext-diff HEAD", "ask");
  checkBash(manager, "git diff --textconv HEAD", "ask");
  checkBash(manager, "git log --ext-diff -1", "ask");
  checkBash(manager, "git log --textconv -p -1", "ask");
  checkBash(manager, "rg --pre cat pattern .", "deny");
  checkBash(manager, "fd --exec rm {}", "deny");
  checkBash(manager, "yq -i '.x = 1' config.yaml", "ask");
  checkBash(manager, 'cat "$SECRET_PATH"', "ask");
  checkBash(manager, "sudo true", "deny");
  const destructiveCommands = [
    "git push origin main --force",
    "git push -f origin main",
    "git push -qf origin main",
    "git push -fq origin main",
    "git push +HEAD:main",
    "git push origin +HEAD:main",
    "git push --mirror origin",
    "git -C . push origin main --force",
    "/usr/bin/git -C . push origin main --force",
    "git reset -q --hard HEAD",
    "git reset --har HEAD",
    "git --git-dir=.git reset -q --hard HEAD",
    "git clean -df",
    "git -C . clean -df",
    "gh api repos/o/r -X DELETE",
    "gh api repos/o/r --method=delete",
    "rm -r -f /",
    "rm -rf /*",
    "rm --recursive --force /",
    "rm --force --recursive /*",
    "rm --recursive /* --force",
    "rm --force /* --recursive",
    "rm --force --no-preserve-root / --recursive",
    "/bin/rm -fR /",
    "rm / -rf",
  ];
  for (const command of destructiveCommands) checkBash(manager, command, "deny");

  const authPath = join(agentDir, "auth.json");
  writeFileSync(authPath, "permission validator decoy\n", { mode: 0o600 });
  const sensitiveReadCommands = [
    `cat ${authPath}`,
    "cat .env",
    "head ~/.ssh/id_rsa",
    "tail ~/.aws/credentials",
    "cat ~/.config/gcloud/application_default_credentials.json",
    "cat ~/.config/google-chrome/Default/Cookies",
    "ls ~/.docker",
    "cat ~/.docker/contexts/meta/example/meta.json",
  ];
  for (const command of sensitiveReadCommands) await checkBashPath(manager, command, "deny");
  await checkBashPath(manager, "ls ~/.ssh", "deny", "smart");
  checkPath(manager, "path_read", authPath, "deny");
  checkPath(manager, "path_write", authPath, "deny");
  for (const path of [
    join(homedir(), ".ssh"),
    join(homedir(), ".aws"),
    join(homedir(), ".config", "google-chrome"),
    join(homedir(), ".docker"),
    join(homedir(), ".docker", "contexts", "meta", "example", "meta.json"),
  ]) {
    checkPath(manager, "path_read", path, "deny");
    checkPath(manager, "path_write", path, "deny");
  }
  checkPath(manager, "external_directory_read", "/opt/pi-security-test/file", "ask");

  for (const agentName of ["rush", "deep", "review"] as const) {
    expectState(`${agentName} write tool`, manager.getToolPermission("write", agentName), "deny");
    checkBash(manager, "git status", "allow", agentName);
    checkBash(manager, "git branch --show-current", "allow", agentName);
    checkBash(manager, "git worktree list --porcelain", "allow", agentName);
    checkBash(manager, "git branch feature/example", "ask", agentName);
    checkBash(manager, "git worktree add /tmp/example -b feature/example", "ask", agentName);
    checkBash(manager, "git add README.md", "ask", agentName);
    checkBash(manager, "git commit -am message", "ask", agentName);
    checkBash(manager, "git fetch origin", "ask", agentName);
    checkBash(manager, "git pull --ff-only", "ask", agentName);
    checkBash(manager, "git reset --hard HEAD", "deny", agentName);
    checkBash(manager, "unknown-reader --version", "ask", agentName);
    checkBash(manager, "gh pr view 1", "ask", agentName);
    checkBash(manager, "make check", "ask", agentName);
    checkBash(manager, "gh repo delete owner/repo", "deny", agentName);
    checkBash(manager, "gh api repos/o/r --method DELETE", "deny", agentName);
  }
  checkBash(manager, "unknown-tool --version", "allow", "smart");
  for (const agentName of ["rush", "smart", "deep", "review"] as const) {
    checkBash(manager, 'cat "$SECRET_PATH"', "deny", agentName);
  }

  const yolo = new loaded.PermissionManager({ agentDir, isYoloEnabled: () => true });
  yolo.configureForCwd(repoRoot);
  checkBash(yolo, "git push origin main", "allow");
  checkBash(yolo, 'cat "$SECRET_PATH"', "allow");
  checkBash(yolo, "sudo true", "deny");
  checkBash(yolo, "rg --pre cat pattern .", "deny");
  for (const command of destructiveCommands) checkBash(yolo, command, "deny");
  for (const command of sensitiveReadCommands) await checkBashPath(yolo, command, "deny");
  await checkBashPath(yolo, "ls ~/.ssh", "deny", "smart");
  checkPath(yolo, "path_read", authPath, "deny");
  for (const agentName of ["rush", "deep", "review"] as const) {
    checkBash(yolo, "git reset --hard HEAD", "deny", agentName);
    checkBash(yolo, "git push -qf origin main", "deny", agentName);
    checkBash(yolo, "gh repo delete owner/repo", "deny", agentName);
    checkBash(yolo, "gh api repos/o/r --method DELETE", "deny", agentName);
  }
  for (const agentName of ["rush", "smart", "deep", "review"] as const) {
    checkBash(yolo, 'cat "$SECRET_PATH"', "deny", agentName);
  }

  console.log("Pi permission schema and deterministic engine validation passed.");
} finally {
  rmSync(temporaryRoot, { recursive: true, force: true });
}
