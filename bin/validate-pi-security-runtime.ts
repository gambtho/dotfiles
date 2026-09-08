import {
  cpSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { runPermissionPipelineChecks } from "./pi-permission-pipeline-checks.ts";

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
  surface: "path_read" | "path_write" | "external_directory_read" | "external_directory_write",
  value: string,
  expected: PermissionState,
  agentName?: string,
): void {
  expectState(
    `${agentName ?? "global"} ${surface} ${value}`,
    manager.check({ kind: "path-values", surface, values: [value], agentName }).state,
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

const temporaryRoot = mkdtempSync(join(homedir(), ".pi-permission-validation-"));
const homeDir = join(temporaryRoot, "home");
const agentDir = join(homeDir, ".pi", "agent");
const configDir = join(agentDir, "extensions", "pi-permission-system");
const agentsDir = join(agentDir, "agents");
const originalHome = process.env.HOME;
process.env.HOME = homeDir;

try {
  mkdirSync(configDir, { recursive: true });
  mkdirSync(agentsDir, { recursive: true });
  const skillScriptDir = join(
    homeDir,
    ".agents",
    "skills",
    "impeccable",
    "scripts",
  );
  mkdirSync(skillScriptDir, { recursive: true });
  writeFileSync(join(skillScriptDir, "load-context.mjs"), "");
  const permissionMetadataDir = join(
    agentDir,
    "npm",
    "node_modules",
    "@gotgenes",
    "pi-permission-system",
  );
  mkdirSync(permissionMetadataDir, { recursive: true });
  writeFileSync(join(permissionMetadataDir, "package.json"), '{"version":"29.2.0"}\n');

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

  await runPermissionPipelineChecks({ packageRoot, agentDir, repoRoot });

  expectState(
    "read tool",
    manager.check({ kind: "tool", surface: "read", input: { path: "README.md" } }).state,
    "allow",
  );
  expectState(
    "lsp_fix tool",
    manager.check({ kind: "tool", surface: "lsp_fix", input: { path: "README.md" } }).state,
    "allow",
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
  checkBash(manager, "/tmp/git status", "allow");
  checkBash(manager, "/tmp/git branch --show-current", "allow");
  checkBash(manager, "/tmp/git worktree list --porcelain", "allow");
  checkBash(manager, "git branch --show-current", "allow");
  checkBash(manager, "git branch feature/example", "allow");
  checkBash(manager, "git worktree add /tmp/example -b feature/example", "allow");
  checkBash(manager, "/usr/bin/git worktree list", "allow");
  checkBash(manager, "git worktree remove /tmp/example", "allow");
  checkBash(manager, "git add README.md", "allow");
  checkBash(manager, "git commit -am message", "allow");
  checkBash(manager, "/usr/bin/git commit -am message", "allow");
  checkBash(manager, "git fetch", "allow");
  checkBash(manager, "git fetch origin", "allow");
  checkBash(manager, "git fetch upstream", "allow");
  checkBash(manager, "git fetch origin main", "allow");
  checkBash(manager, "git fetch origin --prune", "allow");
  checkBash(manager, "git pull origin main", "ask");
  checkBash(manager, "git pull --rebase origin main", "ask");
  checkBash(manager, "git pull --ff-only", "allow");
  checkBash(manager, "git pull --ff-only origin main", "allow");
  checkBash(manager, "git pull --ff-only --no-ff origin main", "ask");
  checkBash(manager, "git pull --ff-only --ff origin main", "ask");
  checkBash(manager, "git pull --ff-only --re''base origin main", "ask");
  checkBash(manager, "git pull --ff-only -qr origin main", "ask");
  await checkBashGate("cd docs/private && git pull --ff-only", "allow");
  checkBash(manager, "git -C . fetch origin", "allow");
  checkBash(manager, "git -C . pull --ff-only origin main", "allow");
  checkBash(manager, "git push origin main", "allow");
  checkBash(manager, "git push origin --delete old-branch", "ask");
  checkBash(manager, "git push origin :old-branch", "ask");
  checkBash(manager, "git push --all origin", "ask");
  checkBash(manager, "git clone https://example.com/repo.git", "ask");
  checkBash(manager, "git --git-dir=.git push origin main", "allow");
  checkBash(manager, "git -C . fetch origin status", "allow");
  checkBash(manager, "git -C . -c 'alias.x=!printf bypass' x status", "deny");
  checkBash(manager, "git -C . -c core.sshCommand=false fetch origin", "deny");
  checkBash(manager, "git --no-pager -c 'credential.helper=!printf helper' credential fill", "deny");
  checkBash(manager, "/usr/bin/git --no-pager -c core.pager=less log -1", "deny");
  checkBash(manager, "git --git-dir=.git -c core.pager=less log -1", "deny");
  checkBash(manager, "/usr/bin/git --git-dir .git -c credential.helper=store credential fill", "deny");
  checkBash(manager, "git --work-tree=. -c 'alias.x=!printf bypass' x", "deny");
  checkBash(manager, "/usr/bin/git --work-tree . -c clean.requireForce=false clean -d", "deny");
  checkBash(manager, "git -C . -c user.name=example status", "deny");
  checkBash(manager, "/usr/bin/git -C . -c color.ui=false status", "deny");
  checkBash(manager, "git switch -c feature/example", "allow");
  checkBash(manager, "git -C . switch -c feature/example", "allow");
  checkBash(manager, "git -C . --config-env=alias.x=GIT_ALIAS x", "deny");
  checkBash(manager, "git -c core.sshCommand=false fetch origin", "deny");
  checkBash(manager, "/usr/bin/git -c core.sshCommand=false fetch origin", "deny");
  checkBash(manager, "git --config-env=alias.x=GIT_ALIAS x", "deny");
  checkBash(manager, "/usr/bin/git --config-env=alias.x=GIT_ALIAS x", "deny");
  checkBash(manager, "git send-pack origin HEAD:main", "ask");
  checkBash(manager, "/usr/bin/git send-pack origin HEAD:main", "ask");
  checkBash(manager, "git send-pack --force origin HEAD:main", "deny");
  checkBash(manager, "git send-pack origin +HEAD:main", "deny");
  const gitAttentionCommands = [
    "git checkout feature/example",
    "git checkout -B feature/example HEAD",
    "git checkout -f feature/example",
    "git checkout -- README.md",
    "/usr/bin/git checkout feature/example",
    "git -C . checkout -B feature/example HEAD",
    "/usr/bin/git -C . checkout -f feature/example",
    "git filter-branch -- --all",
    "/usr/bin/git filter-repo --force",
    "git -C . filter-repo --force",
    "git daemon --reuseaddr",
    "git fast-import <export.stream",
    "git svn fetch",
    "git p4 sync",
    "git gc --prune=now",
    "git -C . gc --aggressive --prune now",
    "git prune",
    "/usr/bin/git -C . prune --expire now",
    "git replace HEAD HEAD~1",
    "git replace --graft HEAD HEAD~1",
    "git submodule add https://example.com/repo.git vendor/repo",
    "/usr/bin/git -C . submodule add https://example.com/repo.git vendor/repo",
  ];
  for (const command of gitAttentionCommands) checkBash(manager, command, "ask");
  checkBash(manager, "git checkout-index --all", "allow");
  checkBash(manager, "git gc", "allow");
  checkBash(manager, "git maintenance run --task=prefetch", "allow");
  checkBash(manager, "git credential fill", "ask");
  checkBash(manager, "/usr/bin/git credential approve", "ask");
  checkBash(manager, "git -C . credential reject", "ask");
  checkBash(manager, "git --git-dir=.git credential fill", "ask");
  checkBash(manager, "git config --get user.name", "allow");
  checkBash(manager, "git config --get alias.x", "allow");
  checkBash(manager, "git config --get core.sshCommand", "allow");
  checkBash(manager, "git config --get-regexp '^user\\.'", "allow");
  checkBash(manager, "git config --list", "allow");
  checkBash(manager, "git config -l", "allow");
  checkBash(manager, "git config --get-all credential.helper", "allow");
  checkBash(manager, "git config --get-urlmatch credential.https://example.com", "allow");
  checkBash(manager, "git config --global --get credential.helper", "allow");
  checkBash(manager, "git config --local --list", "allow");
  checkBash(manager, "git config --show-origin --get-all remote.origin.fetch", "allow");
  checkBash(manager, "/usr/bin/git config --get user.email", "allow");
  checkBash(manager, "git -C . config --get user.email", "allow");
  checkBash(manager, "git --no-pager config --list", "allow");
  checkBash(manager, "git --git-dir=.git config --get user.name", "allow");
  checkBash(manager, "git --git-dir .git config --get user.name", "allow");
  checkBash(manager, "git --work-tree=. config --get user.name", "allow");
  checkBash(manager, "git --work-tree . config --get user.name", "allow");
  const scopedConfigPrefixes = [
    "git -C .",
    "/usr/bin/git -C .",
    "git --no-pager",
    "/usr/bin/git --no-pager",
    "git --git-dir=.git",
    "/usr/bin/git --git-dir=.git",
    "git --git-dir .git",
    "/usr/bin/git --git-dir .git",
    "git --work-tree=.",
    "/usr/bin/git --work-tree=.",
    "git --work-tree .",
    "/usr/bin/git --work-tree .",
  ];
  const scopedConfigReads = [
    "config --global --get credential.helper",
    "config --local --list",
    "config --show-origin --get-all remote.origin.fetch",
  ];
  for (const prefix of scopedConfigPrefixes) {
    for (const read of scopedConfigReads) checkBash(manager, `${prefix} ${read}`, "allow");
  }
  checkBash(manager, "git commit -m 'update config docs'", "allow");
  checkBash(manager, "git log --grep 'credential handling'", "allow");
  checkBash(manager, "git diff -- config ai/pi/config/permission-system.json", "allow");
  checkBash(manager, "git config user.name Example", "deny");
  checkBash(manager, "git -C . config user.email example@example.com", "deny");
  checkBash(manager, "/usr/bin/git --no-pager config user.name Example", "deny");
  checkBash(manager, "git --git-dir .git config user.name Example", "deny");
  checkBash(manager, "git --work-tree=. config user.name Example", "deny");
  const gitConfigWriteCommands = [
    "git config credential.helper '!printf helper'",
    "git config --global credential.helper '!printf helper'",
    "git config clean.requireForce false",
    "git config --unset credential.helper",
    "git -C . config credential.helper '!printf helper'",
    "git --git-dir=.git config credential.helper '!printf helper'",
    "git --work-tree=. config credential.helper '!printf helper'",
    "/usr/bin/git config credential.helper '!printf helper'",
  ];
  for (const command of gitConfigWriteCommands) checkBash(manager, command, "deny");
  checkBash(manager, "git config alias.x '!printf bypass'", "deny");
  checkBash(manager, "git config alias.x='!printf bypass'", "deny");
  checkBash(manager, "git -C . config alias.x '!printf bypass'", "deny");
  checkBash(manager, "git config core.sshCommand 'printf bypass'", "deny");
  checkBash(manager, "git config --global core.sshCommand 'printf bypass'", "deny");
  checkBash(manager, "git -c 'credential.helper=!printf helper' credential fill", "deny");
  checkBash(manager, "git --config-env=credential.helper=GIT_HELPER credential fill", "deny");
  checkBash(manager, "git -c diff.external=tool diff", "deny");
  checkBash(manager, "git -c diff.example.command=tool diff", "deny");
  checkBash(manager, "git -c diff.example.textconv=tool show HEAD:file", "deny");
  checkBash(manager, "git -c filter.example.clean=tool checkout -- file", "deny");
  checkBash(manager, "git --config-env=filter.example.process=GIT_FILTER checkout -- file", "deny");
  checkBash(manager, "git -c 'Credential.Helper=!printf helper' credential fill", "deny");
  checkBash(manager, "git --config-env=Core.Sshcommand=GIT_SSH_COMMAND fetch origin", "deny");
  checkBash(manager, "git -c 'alias.x=!printf bypass' x", "deny");
  checkBash(manager, "git statusx", "allow");
  checkBash(manager, "git branchx feature/example", "allow");
  checkBash(manager, "git commitx -am message", "allow");
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
  checkBash(manager, "git rebase -i -x 'printf example' HEAD~2", "deny");
  checkBash(manager, "git rebase --exec 'printf example' HEAD~2", "deny");
  checkBash(manager, "git rebase fix-xyz", "allow");
  checkBash(manager, "git archive --rem=origin HEAD", "deny");
  checkBash(manager, "git grep -n TODO", "allow");
  checkBash(manager, "git grep TODO", "allow");
  checkBash(manager, "git grep ordinary-query-containing-O", "allow");
  checkBash(manager, "git grep -Oless pattern", "deny");
  checkBash(manager, "git grep -nOless pattern", "deny");
  checkBash(manager, "git grep -inOless pattern", "deny");
  checkBash(manager, "git grep pattern -Oless", "deny");
  checkBash(manager, "git grep pattern -nOless", "deny");
  checkBash(manager, "git grep --open-files-in-pager=less pattern", "deny");
  checkBash(manager, "git grep pattern --open-files-in-pager=less", "deny");
  checkBash(manager, "git grep --op=less pattern", "deny");
  checkBash(manager, "git branch --format='%(refname)'", "allow");
  checkBash(manager, "git tag --format='%(refname)'", "allow");
  checkBash(manager, "git push --follow-tags origin main", "ask");
  checkBash(manager, "git push --no-verify origin main", "ask");
  checkBash(manager, "git push --repo=foo main", "ask");
  checkBash(manager, "git diff --ext-d HEAD", "deny");
  checkBash(manager, "git log --textc -p -1", "deny");
  checkBash(manager, "git update-ref -d refs/heads/feature/example", "ask");
  checkBash(manager, "git worktree remove --force /tmp/example", "ask");
  checkBash(manager, "git -C . worktree remove --force /tmp/example", "ask");
  checkBash(manager, "git commit --amend --no-edit", "ask");
  checkBash(manager, "/usr/bin/git commit --amend --no-edit", "ask");
  checkBash(manager, "git -C . commit --amend --no-edit", "ask");
  checkBash(manager, "git commit -m 'restore README wording'", "allow");
  checkBash(manager, "/usr/bin/git commit -m 'restore README wording'", "allow");
  checkBash(manager, "git -C . commit -m 'restore README wording'", "allow");
  checkBash(manager, "git restore README.md", "ask");
  checkBash(manager, "/usr/bin/git restore README.md", "ask");
  checkBash(manager, "git -C . restore README.md", "ask");
  checkBash(manager, "/usr/bin/git -C . restore README.md", "ask");
  checkBash(manager, "git --no-pager restore README.md", "ask");
  checkBash(manager, "/usr/bin/git --no-pager restore README.md", "ask");
  checkBash(manager, "git --git-dir=.git restore README.md", "ask");
  checkBash(manager, "/usr/bin/git --git-dir=.git restore README.md", "ask");
  checkBash(manager, "git --work-tree=. restore README.md", "ask");
  checkBash(manager, "/usr/bin/git --work-tree=. restore README.md", "ask");
  checkBash(manager, "git -c user.name=example restore README.md", "deny");
  checkBash(manager, "/usr/bin/git -c user.name=example restore README.md", "deny");
  checkBash(manager, "git --git-dir .git restore README.md", "ask");
  checkBash(manager, "/usr/bin/git --git-dir .git restore README.md", "ask");
  checkBash(manager, "git --work-tree . restore README.md", "ask");
  checkBash(manager, "/usr/bin/git --work-tree . restore README.md", "ask");
  checkBash(manager, "git --git-dir .git commit -m 'restore README wording'", "allow");
  checkBash(manager, "/usr/bin/git --work-tree . commit -m 'restore README wording'", "allow");
  checkBash(manager, "git --git-dir=.git commit -m 'restore README wording'", "allow");
  checkBash(manager, "git --work-tree=. commit -m 'restore README wording'", "allow");
  checkBash(manager, "git --git-dir .git commit --amend --no-edit", "ask");
  checkBash(manager, "/usr/bin/git --work-tree . commit --amend --no-edit", "ask");
  checkBash(manager, "git --git-dir=.git commit --amend --no-edit", "ask");
  checkBash(manager, "git --work-tree=. commit --amend --no-edit", "ask");
  checkBash(manager, "git --config-env=user.name=GIT_USER restore README.md", "deny");
  checkBash(manager, "/usr/bin/git --config-env=user.name=GIT_USER restore README.md", "deny");
  checkBash(manager, "gh auth status", "allow");
  checkBash(manager, "gh auth token", "ask");
  checkBash(manager, "/usr/bin/gh auth token --hostname github.com", "ask");
  checkBash(manager, "gh pr create --title example", "allow");
  checkBash(manager, "gh pr edit 42 --add-label ready", "allow");
  checkBash(manager, "gh issue create --title example", "allow");
  checkBash(manager, "gh issue edit 42 --add-label ready", "allow");
  checkBash(manager, "gh issue edit 42 --state closed", "ask");
  checkBash(manager, "gh pr merge 42", "ask");
  checkBash(manager, "gh issue close 42", "ask");
  checkBash(manager, "/usr/bin/gh pr create --title example", "allow");
  const ghAttentionCommands = [
    "gh api repos/o/r --method POST",
    "gh api repos/o/r --method PUT",
    "gh api repos/o/r --method PATCH",
    "gh api repos/o/r --method=post",
    "gh api repos/o/r -X POST",
    "gh api repos/o/r -X PUT",
    "gh api repos/o/r -X PATCH",
    "/usr/bin/gh api repos/o/r -X GET",
    "gh api repos/o/r -f name=value",
    "gh api repos/o/r -F name=@value.txt",
    "gh api repos/o/r --field name=value",
    "gh api repos/o/r --field=name=value",
    "gh api repos/o/r --raw-field name=value",
    "gh api repos/o/r --raw-field=name=value",
    "gh api repos/o/r --input payload.json",
    "gh api repos/o/r --input=payload.json",
    "gh secret set EXAMPLE",
    "/usr/bin/gh secret delete EXAMPLE",
    "gh release create v1.0.0",
    "gh release upload v1.0.0 artifact.tgz",
    "/usr/bin/gh release delete v1.0.0 --yes",
    "gh release edit v1.0.0 --title stable",
    "gh pr checkout 42",
    "gh pr close 42",
    "gh pr comment 42 --body example",
    "gh pr ready 42",
    "gh pr reopen 42",
    "gh pr review 42 --approve",
    "gh pr update-branch 42",
    "gh issue comment 42 --body example",
    "gh issue delete 42 --yes",
    "gh issue develop 42 --checkout",
    "gh issue lock 42",
    "gh issue pin 42",
    "gh issue reopen 42",
    "gh issue transfer 42 owner/other",
    "gh issue unlock 42",
    "gh issue unpin 42",
    "gh workflow run checks.yml",
    "gh workflow disable checks.yml",
    "gh workflow enable checks.yml",
    "gh repo create example",
    "gh repo fork owner/repo",
    "gh repo edit owner/repo --visibility private",
    "gh repo archive owner/repo --yes",
    "gh repo autolink create --key-prefix EXAMPLE- --url-template https://example.com/num",
    "gh repo autolink delete 123",
    "gh repo clone owner/repo",
    "gh repo deploy-key add key.pub --title example",
    "gh repo deploy-key delete 123 --yes",
    "gh repo rename renamed",
    "gh repo set-default owner/repo",
    "gh repo sync owner/repo",
    "gh repo unarchive owner/repo --yes",
    "gh gist clone abc123",
    "gh gist create notes.txt --public",
    "gh gist edit abc123 --add notes.txt",
    "/usr/bin/gh gist delete abc123",
    "gh gist rename abc123 renamed.md",
    "gh extension exec owner/extension",
    "gh extension install owner/extension",
    "gh extension remove owner/extension",
    "/usr/bin/gh extension upgrade owner/extension",
    "gh alias set example 'pr view'",
    "gh alias delete example",
    "gh alias import aliases.yml",
    "gh ssh-key add key.pub --title example",
    "gh ssh-key delete 123 --yes",
    "gh gpg-key add key.gpg",
    "gh gpg-key delete 123 --yes",
    "gh variable set EXAMPLE --body value",
    "gh variable delete EXAMPLE",
    "gh codespace code --codespace example",
    "gh codespace create --repo owner/repo",
    "gh codespace delete --codespace example",
    "gh codespace edit --codespace example --display-name renamed",
    "gh codespace rebuild --codespace example",
    "gh codespace jupyter --codespace example",
    "gh codespace stop --codespace example",
    "gh codespace ssh --codespace example",
    "gh codespace cp local.txt remote:/workspaces/repo/",
    "gh codespace ports visibility 3000:public --codespace example",
    "gh run cancel 123",
    "gh run delete 123",
    "gh run rerun 123",
    "gh label clone owner/source --repo owner/destination",
    "gh label create bug --color ff0000",
    "gh label delete bug --yes",
    "gh label edit bug --name defect",
    "gh project close 1 --owner example",
    "gh project copy 1 --owner example --title copy",
    "gh project create --owner example --title example",
    "gh project delete 1 --owner example",
    "gh project edit --id PVT_example --title renamed",
    "gh project field-create 1 --owner example --name Field --data-type TEXT",
    "gh project field-delete --id PVTF_example",
    "gh project item-add 1 --owner example --url https://github.com/owner/repo/issues/1",
    "gh project item-archive 1 --owner example --id PVTI_example",
    "gh project item-create 1 --owner example --title draft",
    "gh project item-delete 1 --owner example --id PVTI_example",
    "gh project item-edit --id PVTI_example --project-id PVT_example --body example",
    "gh project link 1 --owner example --repo owner/repo",
    "gh project mark-template 1 --owner example",
    "gh project reopen 1 --owner example",
    "gh project unlink 1 --owner example --repo owner/repo",
    "gh config set git_protocol ssh",
    "gh config clear-cache",
    "gh cache delete 123",
    "gh auth login",
    "gh auth refresh",
    "gh auth logout",
    "gh auth setup-git",
    "gh auth switch --user example",
  ];
  for (const command of ghAttentionCommands) checkBash(manager, command, "ask");
  const ghReadCommands = [
    "gh gist list",
    "gh gist view abc123",
    "gh extension list",
    "gh alias list",
    "gh ssh-key list",
    "gh gpg-key list",
    "gh variable list",
    "gh variable get EXAMPLE",
    "gh release list",
    "gh release view v1.0.0",
    "gh codespace list",
    "gh codespace logs --codespace example",
    "gh codespace ports --codespace example",
    "gh project list --owner example",
    "gh project view 1 --owner example",
    "gh project field-list 1 --owner example",
    "gh project item-list 1 --owner example",
    "gh repo autolink get 123",
    "gh repo autolink list",
    "gh repo deploy-key list",
    "gh run list",
    "gh run view 123",
    "gh label list",
    "gh workflow list",
    "gh workflow view checks.yml",
    "gh config get git_protocol",
    "gh config list",
  ];
  for (const command of ghReadCommands) checkBash(manager, command, "allow");
  checkBash(manager, "gh api repos/o/r/pulls/1/comments", "allow");
  checkBash(manager, "gh api repos/o/r/issues -XGET", "ask");
  checkBash(manager, "gh api repos/o/r/issues -X=GET", "ask");
  checkBash(manager, "gh api repos/o/r/issues --method GET", "ask");
  checkBash(manager, "gh api repos/o/r/issues --method=GET", "ask");
  checkBash(manager, "gh api repos/o/r/issues -XPOST", "ask");
  checkBash(manager, "gh api repos/o/r/issues -ftitle=example", "ask");
  checkBash(manager, "gh api repos/o/r/issues -Ftitle=example", "ask");
  checkBash(manager, "curl https://example.com", "allow");
  checkBash(manager, "/usr/bin/curl https://example.com", "allow");
  checkBash(manager, "curl -fsS http://127.0.0.1:9222/json/version", "allow");
  checkBash(manager, "curl --max-time 2 http://localhost:8765/health", "allow");
  checkBash(manager, "curl https://example.com http://127.0.0.1:9222", "allow");
  checkBash(manager, "curl http://127.0.0.1:9222 http://example.com", "allow");
  checkBash(manager, "curl http://localhost.evil.example/", "allow");
  checkBash(manager, "curl http://localhost@evil.example/", "allow");
  checkBash(manager, "curl ftp://example.com/pub/archive.tar.gz", "ask");
  checkBash(manager, "/usr/bin/curl ftps://example.com/private/archive.tar.gz", "ask");
  checkBash(manager, "curl ftp://user:password@example.com/private/archive.tar.gz", "ask");
  const curlAskCommands = [
    "curl --data payload https://example.com/items",
    "curl --data=payload https://example.com/items",
    "curl --data-raw payload https://example.com/items",
    "curl --data-binary @payload https://example.com/items",
    "curl --data-urlencode name=value https://example.com/items",
    "curl -d payload https://example.com/items",
    "curl --form artifact=@file https://example.com/items",
    "curl -F artifact=@file https://example.com/items",
    "curl --upload-file artifact.zip https://example.com/items",
    "curl -T artifact.zip https://example.com/items",
    "curl --request POST https://example.com/items",
    "curl --request PUT https://example.com/items",
    "curl --request PATCH https://example.com/items",
    "curl --request DELETE https://example.com/items/1",
    "curl --request post https://example.com/items",
    "curl --request put https://example.com/items",
    "curl --request patch https://example.com/items",
    "curl --request delete https://example.com/items/1",
    "curl --request=POST https://example.com/items",
    "curl --request=PUT https://example.com/items",
    "curl --request=PATCH https://example.com/items",
    "curl --request=DELETE https://example.com/items/1",
    "curl --request=post https://example.com/items",
    "curl --request=put https://example.com/items",
    "curl --request=patch https://example.com/items",
    "curl --request=delete https://example.com/items/1",
    "curl -X POST https://example.com/items",
    "curl -X PUT https://example.com/items",
    "curl -X PATCH https://example.com/items",
    "curl -X DELETE https://example.com/items/1",
    "curl -X post https://example.com/items",
    "curl -X put https://example.com/items",
    "curl -X patch https://example.com/items",
    "curl -X delete https://example.com/items/1",
    "curl -H 'Authorization: Bearer example' https://example.com/private",
    "curl --header 'Authorization: Bearer example' https://example.com/private",
    "curl -H 'authorization: Bearer example' https://example.com/private",
    "curl --user name:password https://example.com/private",
    "curl -u name:password https://example.com/private",
    "curl --cookie session=example https://example.com/private",
    "curl -b session=example https://example.com/private",
    "curl --cert client.pem https://example.com/private",
    "curl -E client.pem https://example.com/private",
    "curl --key client.key https://example.com/private",
    "curl --netrc https://example.com/private",
  ];
  for (const command of curlAskCommands) checkBash(manager, command, "ask");
  await checkBashGate(
    "/usr/bin/curl https://example.com/items --data payload",
    "ask",
  );
  await checkBashGate(
    "curl https://example.com/one https://example.com/two -T artifact.zip",
    "ask",
  );
  await checkBashGate(
    "printf ready && curl https://example.com/items -X DELETE",
    "ask",
  );
  checkBash(manager, "rm -f /tmp/example", "ask");
  checkBash(manager, "rm -rf /tmp/example", "ask");
  checkBash(manager, "rm -rf important /tmp/example", "ask");
  checkBash(manager, "rm -rf /tmp/example important", "ask");
  checkBash(manager, "rm -rf /tmp/../important", "ask");
  checkBash(manager, "/bin/rm -rf .", "ask");
  checkBash(manager, "nc example.com 443", "ask");
  checkBash(manager, '/bin/cat "$SECRET_PATH"', "ask");
  checkBash(manager, "command -v direnv", "allow");
  await checkBashGate("cd . && curl https://example.com", "allow");
  await checkBashGate("env gh pr create --title example", "ask");
  await checkBashGate("sh -c 'git push origin main'", "ask");
  await checkBashGate("git -C . -c user.name=example status", "deny");
  await checkBashGate("git switch -c feature/example", "allow");
  await checkBashGate("git -C . switch -c feature/example", "allow");
  await checkBashGate("git send-pack origin HEAD:main", "ask");
  await checkBashGate("git send-pack --force origin HEAD:main", "deny");
  await checkBashGate("git send-pack origin +HEAD:main", "deny");
  await checkBashGate("git credential fill", "ask");
  await checkBashGate("gh auth token", "ask");
  await checkBashGate("git checkout -B feature/example HEAD", "ask");
  await checkBashGate("git filter-repo --force", "ask");
  await checkBashGate("gh api repos/o/r --method PATCH", "ask");
  await checkBashGate("git config user.name Example", "deny");
  await checkBashGate(
    "git config credential.helper '!printf helper'; git config --get user.name",
    "deny",
  );
  await checkBashGate(
    "git config --get user.name; git config credential.helper '!printf helper'",
    "deny",
  );
  await checkBashGate("git config --get user.name", "allow");
  await checkBashGate("git commit -m 'update config docs'", "allow");
  await checkBashGate("git log --grep 'credential handling'", "allow");
  await checkBashGate("git diff -- config ai/pi/config/permission-system.json", "allow");
  await checkBashGate("git config alias.x '!printf bypass'", "deny");
  checkBash(manager, "git show --ext-diff HEAD", "deny");
  checkBash(manager, "git show --textconv HEAD:file", "deny");
  checkBash(manager, "git diff --ext-diff HEAD", "deny");
  checkBash(manager, "git diff --textconv HEAD", "deny");
  checkBash(manager, "git log --ext-diff -1", "deny");
  checkBash(manager, "git log --textconv -p -1", "deny");
  checkBash(manager, "rg --pre cat pattern .", "deny");
  checkBash(manager, "fd --exec rm {}", "deny");
  checkBash(manager, "yq -i '.x = 1' config.yaml", "ask");
  checkBash(manager, 'cat "$SECRET_PATH"', "ask");
  checkBash(manager, "sudo true", "deny");
  await checkBashGate("rm -rf ./build", "ask");
  await checkBashGate("rm -rf /", "deny");
  await checkBashGate("sudo true", "deny");
  await checkBashGate("doas true", "deny");
  await checkBashGate("git reset --hard HEAD~1", "deny");
  await checkBashGate("git clean -ffdx", "deny");
  await checkBashGate("git push --force origin main", "deny");
  await checkBashGate("gh repo delete owner/name --yes", "deny");
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
  for (const command of destructiveCommands) await checkBashGate(command, "deny");

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
  const trustedSkillPath = join(homedir(), ".agents", "skills", "impeccable", "SKILL.md");
  checkPath(manager, "external_directory_read", trustedSkillPath, "allow");
  checkPath(manager, "external_directory_write", trustedSkillPath, "allow");
  const wingmanWorktreePath = "/mnt/c/dev/flygd-wingman-worktrees/example/README.md";
  checkPath(manager, "external_directory_read", wingmanWorktreePath, "allow");
  checkPath(manager, "external_directory_write", wingmanWorktreePath, "allow");
  checkPath(manager, "external_directory_read", "/opt/pi-security-test/file", "allow");
  checkPath(manager, "external_directory_write", "/opt/pi-security-test/file", "allow");

  for (const agentName of ["rush", "deep", "review"] as const) {
    expectState(`${agentName} write tool`, manager.getToolPermission("write", agentName), "deny");
    expectState(`${agentName} edit tool`, manager.getToolPermission("edit", agentName), "deny");
    checkPath(manager, "path_read", join(homedir(), ".ssh", "config"), "deny", agentName);
    checkPath(manager, "path_write", join(homedir(), ".ssh", "config"), "deny", agentName);
    checkPath(manager, "path_write", join(repoRoot, "README.md"), "allow", agentName);
    checkBash(manager, "git status", "allow", agentName);
    checkBash(manager, "git -C . status --short", "allow", agentName);
    checkBash(manager, "git -C . diff --stat", "allow", agentName);
    checkBash(manager, "git -C . log -1", "allow", agentName);
    checkBash(manager, "git -C . grep -n TODO", "allow", agentName);
    checkBash(manager, "git -C . config --get user.name", "allow", agentName);
    checkBash(manager, "git show --ext-diff HEAD", "deny", agentName);
    checkBash(manager, "git diff --textconv HEAD", "deny", agentName);
    checkBash(manager, "git log --ext-diff -1", "deny", agentName);
    checkBash(manager, "git -C . show --textconv HEAD:file", "deny", agentName);
    checkBash(manager, "git -C . diff --ext-diff HEAD", "deny", agentName);
    checkBash(manager, "git -C . log --textconv -p -1", "deny", agentName);
    checkBash(manager, "git -C . grep -nOless TODO", "deny", agentName);
    checkBash(manager, "git -C . add README.md", "deny", agentName);
    checkBash(manager, "git grep -n TODO", "allow", agentName);
    checkBash(manager, "git grep TODO", "allow", agentName);
    checkBash(manager, "git grep -nOless TODO", "deny", agentName);
    checkBash(manager, "git grep --open-files-in-pager=less TODO", "deny", agentName);
    checkBash(manager, "git branch --show-current", "allow", agentName);
    checkBash(manager, "git worktree list --porcelain", "allow", agentName);
    checkBash(manager, "git branch feature/example", "deny", agentName);
    checkBash(manager, "git worktree add /tmp/example -b feature/example", "deny", agentName);
    checkBash(manager, "git add README.md", "deny", agentName);
    checkBash(manager, "git commit -am message", "deny", agentName);
    checkBash(manager, "git fetch origin", "deny", agentName);
    checkBash(manager, "git pull --ff-only", "deny", agentName);
    checkBash(manager, "git push origin main", "deny", agentName);
    checkBash(manager, "git reset --hard HEAD", "deny", agentName);
    checkBash(manager, "unknown-reader --version", "allow", agentName);
    checkBash(manager, "gh pr view 1", "allow", agentName);
    checkBash(manager, "make check", "allow", agentName);
    checkBash(manager, "gh repo delete owner/repo", "deny", agentName);
    checkBash(manager, "gh api repos/o/r --method DELETE", "deny", agentName);
    checkBash(manager, "gh api repos/o/r -X DELETE", "deny", agentName);
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
    checkBash(yolo, "git branch -D feature/example", "deny", agentName);
    checkBash(yolo, "git worktree remove --force /tmp/example", "deny", agentName);
    checkBash(yolo, "git commit --amend --no-edit", "deny", agentName);
    checkBash(yolo, "git restore README.md", "deny", agentName);
    checkBash(yolo, "git push -qf origin main", "deny", agentName);
    checkBash(yolo, "gh repo delete owner/repo", "deny", agentName);
    checkBash(yolo, "gh api repos/o/r --method DELETE", "deny", agentName);
  }
  for (const agentName of ["rush", "smart", "deep", "review"] as const) {
    checkBash(yolo, 'cat "$SECRET_PATH"', "deny", agentName);
  }

  console.log("Pi permission schema and deterministic engine validation passed.");
} finally {
  if (originalHome === undefined) delete process.env.HOME;
  else process.env.HOME = originalHome;
  rmSync(temporaryRoot, { recursive: true, force: true });
}
