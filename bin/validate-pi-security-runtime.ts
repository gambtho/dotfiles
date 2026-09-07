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
    "allow",
  );
  expectState(
    "unknown tool",
    manager.check({ kind: "tool", surface: "unknown_extension_tool", input: {} }).state,
    "ask",
  );

  checkBash(manager, "printf hello", "allow");
  checkBash(manager, 'printf "$HOME"', "allow");
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
  checkBash(manager, "git pull origin main", "allow");
  checkBash(manager, "git pull --rebase origin main", "allow");
  checkBash(manager, "git pull --ff-only", "allow");
  checkBash(manager, "git pull --ff-only origin main", "allow");
  checkBash(manager, "git pull --ff-only --no-ff origin main", "allow");
  checkBash(manager, "git pull --ff-only --ff origin main", "allow");
  checkBash(manager, "git pull --ff-only --re''base origin main", "allow");
  checkBash(manager, "git pull --ff-only -qr origin main", "allow");
  await checkBashGate("cd docs/private && git pull --ff-only", "allow");
  checkBash(manager, "git -C . fetch origin", "allow");
  checkBash(manager, "git -C . pull --ff-only origin main", "allow");
  checkBash(manager, "git push origin main", "allow");
  checkBash(manager, "git push origin --delete old-branch", "allow");
  checkBash(manager, "git push origin :old-branch", "allow");
  checkBash(manager, "git push --all origin", "allow");
  checkBash(manager, "git clone https://example.com/repo.git", "allow");
  checkBash(manager, "git --git-dir=.git push origin main", "allow");
  checkBash(manager, "git -C . fetch origin status", "allow");
  checkBash(manager, "git -C . -c 'alias.x=!printf bypass' x status", "deny");
  checkBash(manager, "git --config-env=alias.x=GIT_ALIAS x", "deny");
  await checkBashGate("git -c 'credential.helper=!printf helper' credential fill", "deny");
  checkBash(manager, "git --config-env=credential.helper=GIT_HELPER credential fill", "deny");
  checkBash(manager, "git -c core.sshCommand=false fetch origin", "deny");
  checkBash(manager, "git --config-env=core.sshCommand=GIT_SSH_COMMAND fetch origin", "deny");
  checkBash(manager, "git -c diff.external=tool diff", "deny");
  checkBash(manager, "git -c diff.example.command=tool diff", "deny");
  checkBash(manager, "git -c diff.example.textconv=tool show HEAD:file", "deny");
  checkBash(manager, "git -c filter.example.clean=tool checkout -- file", "deny");
  checkBash(manager, "git -c filter.example.smudge=tool checkout -- file", "deny");
  checkBash(manager, "git --config-env=filter.example.process=GIT_FILTER checkout -- file", "deny");
  checkBash(manager, "git -c 'Credential.Helper=!printf helper' credential fill", "deny");
  checkBash(manager, "git --config-env=Core.Sshcommand=GIT_SSH_COMMAND fetch origin", "deny");
  checkBash(manager, "git config credential.helper '!printf helper'", "deny");
  checkBash(manager, "git config --global credential.helper '!printf helper'", "deny");
  checkBash(manager, "git config clean.requireForce false", "deny");
  checkBash(manager, "git config --unset credential.helper", "deny");
  checkBash(manager, "git -C . config credential.helper '!printf helper'", "deny");
  checkBash(manager, "git --git-dir=.git config credential.helper '!printf helper'", "deny");
  checkBash(manager, "git --work-tree=. config credential.helper '!printf helper'", "deny");
  checkBash(manager, "/usr/bin/git config credential.helper '!printf helper'", "deny");
  checkBash(manager, "git config --get credential.helper", "allow");
  checkBash(manager, "git config --get-all credential.helper", "allow");
  checkBash(manager, "git config --get-regexp '^credential\\.'", "allow");
  checkBash(manager, "git config --get-urlmatch credential.https://example.com", "allow");
  checkBash(manager, "git config --list", "allow");
  checkBash(manager, "git config -l", "allow");
  checkBash(manager, "git config --global --get credential.helper", "allow");
  checkBash(manager, "git config --local --list", "allow");
  checkBash(manager, "git config --show-origin --get-all remote.origin.fetch", "allow");
  checkBash(manager, "git -C . config --get credential.helper", "allow");
  await checkBashGate(
    "git config credential.helper '!printf helper'; git config --get user.name",
    "deny",
  );
  await checkBashGate(
    "git config --get user.name; git config credential.helper '!printf helper'",
    "deny",
  );
  checkBash(manager, "/usr/bin/git config --get credential.helper", "allow");
  checkBash(manager, "git add ai/pi/config/permission-system.json", "allow");
  checkBash(manager, "git diff -- ai/pi/config/permission-system.json", "allow");
  checkBash(manager, "git log --grep=diff.external", "allow");
  checkBash(manager, "git show --check HEAD", "allow");
  checkBash(manager, 'git commit -m "fix: block persistent Git config writes"', "allow");
  checkBash(manager, "git send-pack origin HEAD:main", "allow");
  checkBash(manager, "git submodule add https://example.com/repo.git vendor/repo", "allow");
  checkBash(manager, "git maintenance run --task=prefetch", "allow");
  checkBash(manager, "git credential fill", "allow");
  checkBash(manager, "git -c 'alias.x=!printf bypass' x", "deny");
  checkBash(manager, "git statusx", "allow");
  checkBash(manager, "git branchx feature/example", "allow");
  checkBash(manager, "git commitx -am message", "allow");
  checkBash(manager, "git switch my-feature", "allow");
  checkBash(manager, "git rm docs/my-file.md", "allow");
  checkBash(manager, "git worktree remove /tmp/my-feature", "allow");
  checkBash(manager, "git branch -D feature/example", "allow");
  checkBash(manager, "git branch -f feature/example HEAD", "allow");
  checkBash(manager, "git branch --del feature/example", "allow");
  checkBash(manager, "git branch -M feature/example", "allow");
  checkBash(manager, "git tag -a -f example HEAD", "allow");
  checkBash(manager, "git switch -q -f feature/example", "allow");
  checkBash(manager, "git switch -C feature/example", "allow");
  checkBash(manager, "git reset --keep HEAD~1", "allow");
  checkBash(manager, "git rm -f README.md", "allow");
  checkBash(manager, "git rebase -i -x 'printf example' HEAD~2", "deny");
  checkBash(manager, "git archive --rem=origin HEAD", "deny");
  checkBash(manager, "git grep -Oless pattern", "deny");
  checkBash(manager, "git grep -nOless pattern", "deny");
  checkBash(manager, "git grep --open=less pattern", "deny");
  checkBash(manager, "git grep --op=less pattern", "deny");
  checkBash(manager, "git branch --format='%(refname)'", "allow");
  checkBash(manager, "git tag --format='%(refname)'", "allow");
  checkBash(manager, "git push --follow-tags origin main", "allow");
  checkBash(manager, "git push --no-verify origin main", "allow");
  checkBash(manager, "git push --repo=foo main", "allow");
  checkBash(manager, "git diff --ext-d HEAD", "deny");
  checkBash(manager, "git log --textc -p -1", "deny");
  checkBash(manager, "git update-ref -d refs/heads/feature/example", "allow");
  checkBash(manager, "git worktree remove --force /tmp/example", "allow");
  checkBash(manager, "git -C . worktree remove --force /tmp/example", "allow");
  checkBash(manager, "git commit --amend --no-edit", "allow");
  checkBash(manager, "git -C . commit --amend --no-edit", "allow");
  checkBash(manager, "git restore README.md", "allow");
  checkBash(manager, "gh pr create --title example", "allow");
  checkBash(manager, "gh pr edit 42 --add-label ready", "allow");
  checkBash(manager, "gh issue create --title example", "allow");
  checkBash(manager, "gh issue edit 42 --add-label ready", "allow");
  checkBash(manager, "gh issue edit 42 --state closed", "ask");
  checkBash(manager, "gh pr merge 42", "ask");
  checkBash(manager, "gh issue close 42", "ask");
  checkBash(manager, "gh api repos/o/r/pulls/1/comments", "allow");
  checkBash(manager, "gh api repos/o/r/issues -X GET", "ask");
  checkBash(manager, "gh api repos/o/r/issues -XGET", "ask");
  checkBash(manager, "gh api repos/o/r/issues -X=GET", "ask");
  checkBash(manager, "gh api repos/o/r/issues --method GET", "ask");
  checkBash(manager, "gh api repos/o/r/issues --method=GET", "ask");
  checkBash(manager, "gh api repos/o/r/issues -X POST", "ask");
  checkBash(manager, "gh api repos/o/r/issues -XPOST", "ask");
  checkBash(manager, "gh api repos/o/r/issues --method PATCH", "ask");
  checkBash(manager, "gh api repos/o/r/issues --method PUT", "ask");
  checkBash(manager, "gh api repos/o/r/issues -f title=example", "ask");
  checkBash(manager, "gh api repos/o/r/issues -ftitle=example", "ask");
  checkBash(manager, "gh api repos/o/r/issues --raw-field title=example", "ask");
  checkBash(manager, "gh api repos/o/r/issues -F title=example", "ask");
  checkBash(manager, "gh api repos/o/r/issues -Ftitle=example", "ask");
  checkBash(manager, "gh api repos/o/r/issues --field title=example", "ask");
  checkBash(manager, "gh api repos/o/r/issues --input payload.json", "ask");
  checkBash(manager, "gh api repos/o/r/issues -f per_page=100 --method GET", "ask");
  checkBash(manager, "gh api repos/o/r/issues --method GET --method POST", "ask");
  checkBash(manager, "gh api repos/o/r/issues -XGET -XPOST", "ask");
  checkBash(manager, "/usr/bin/gh pr create --title example", "ask");
  checkBash(manager, "curl https://example.com", "ask");
  checkBash(manager, "/usr/bin/curl https://example.com", "ask");
  checkBash(manager, "curl -fsS http://127.0.0.1:9222/json/version", "allow");
  checkBash(manager, "curl --max-time 2 http://localhost:8765/health", "allow");
  checkBash(manager, "curl https://example.com http://127.0.0.1:9222", "ask");
  checkBash(manager, "curl http://127.0.0.1:9222 http://example.com", "ask");
  checkBash(manager, "curl http://localhost.evil.example/", "ask");
  checkBash(manager, "curl http://localhost@evil.example/", "ask");
  checkBash(manager, "rm -f /tmp/example", "ask");
  checkBash(manager, "rm -rf /tmp/example", "ask");
  checkBash(manager, "rm -rf important /tmp/example", "ask");
  checkBash(manager, "rm -rf /tmp/example important", "ask");
  checkBash(manager, "rm -rf /tmp/../important", "ask");
  checkBash(manager, "/bin/rm -rf .", "ask");
  checkBash(manager, "nc example.com 443", "ask");
  checkBash(manager, '/bin/cat "$SECRET_PATH"', "allow");
  checkBash(manager, 'printf \'shell=%s\\n\' "$SHELL"', "allow");
  checkBash(manager, "command -v direnv", "allow");
  await checkBashGate(
    'printf \'shell=%s\\n\' "$SHELL"; for f in .envrc mise.toml .mise.toml .tool-versions; do [ -e "$f" ] && echo "$f"; done; command -v direnv >/dev/null && echo direnv=installed || echo direnv=missing; command -v mise >/dev/null && echo mise=installed || echo mise=missing',
    "allow",
  );
  await checkBashGate("cd . && curl https://example.com", "ask");
  await checkBashGate("env gh pr create --title example", "ask");
  await checkBashGate("sh -c 'git push origin main'", "ask");
  checkBash(manager, "git show --ext-diff HEAD", "deny");
  checkBash(manager, "git show --textconv HEAD:file", "deny");
  checkBash(manager, "git diff --ext-diff HEAD", "deny");
  checkBash(manager, "git diff --textconv HEAD", "deny");
  checkBash(manager, "git log --ext-diff -1", "deny");
  checkBash(manager, "git log --textconv -p -1", "deny");
  checkBash(manager, "rg --pre cat pattern .", "deny");
  checkBash(manager, "fd --exec rm {}", "deny");
  checkBash(manager, "yq -i '.x = 1' config.yaml", "ask");
  checkBash(manager, 'cat "$SECRET_PATH"', "allow");
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
  const trustedReadPaths = [
    join(homedir(), ".pi", "sessions", "example.jsonl"),
    join(homedir(), ".pi", "agent", "skills", "example", "SKILL.md"),
    join(homedir(), ".pi", "agent", "git", "example", "skills", "example", "SKILL.md"),
    join(homedir(), ".agents", "skills", "impeccable", "SKILL.md"),
    join(homedir(), ".dotfiles", "ai", "marketplace", "plugins", "other", "skills", "example", "SKILL.md"),
  ];
  for (const trustedReadPath of trustedReadPaths) {
    checkPath(manager, "external_directory_read", trustedReadPath, "allow");
    checkPath(manager, "external_directory_write", trustedReadPath, "ask");
  }
  const wingmanWorktreePath = "/mnt/c/dev/flygd-wingman-worktrees/example/README.md";
  checkPath(manager, "external_directory_read", wingmanWorktreePath, "allow");
  checkPath(manager, "external_directory_write", wingmanWorktreePath, "allow");
  checkPath(manager, "external_directory_read", "/opt/pi-security-test/file", "ask");
  checkPath(manager, "external_directory_write", "/opt/pi-security-test/file", "ask");

  for (const agentName of ["rush", "deep", "review"] as const) {
    expectState(`${agentName} write tool`, manager.getToolPermission("write", agentName), "deny");
    checkPath(manager, "path_write", join(repoRoot, "README.md"), "allow", agentName);
    checkBash(manager, "git status", "allow", agentName);
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
    checkBash(manager, "unknown-reader --version", "ask", agentName);
    checkBash(manager, "gh pr view 1", "allow", agentName);
    checkBash(manager, "make check", "allow", agentName);
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
  rmSync(temporaryRoot, { recursive: true, force: true });
}
