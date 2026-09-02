import { execFileSync } from "node:child_process";
import { existsSync, readFileSync, realpathSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, isAbsolute, join, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

type AccessExtractor = (input: Record<string, unknown>) => string | undefined;

type PermissionsService = {
  registerToolAccessExtractor(toolName: string, extractor: AccessExtractor): () => void;
};

function git(cwd: string, ...args: string[]): string {
  return execFileSync("git", ["-C", cwd, ...args], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "ignore"],
  }).trim();
}

function nearestExistingDirectory(target: string): string | undefined {
  let current = target;
  while (!existsSync(current)) {
    const parent = dirname(current);
    if (parent === current) return undefined;
    current = parent;
  }
  const resolved = realpathSync(current);
  return statSync(resolved).isDirectory() ? resolved : dirname(resolved);
}

function allowedRoots(home: string): Set<string> {
  const allowFile = join(home, ".pi", "worktree-guard-allow");
  if (!existsSync(allowFile)) return new Set();

  const roots = readFileSync(allowFile, "utf8")
    .split("\n")
    .map((line) => line.replace(/#.*/, "").trim())
    .filter(Boolean)
    .map((line) => (line === "~" || line.startsWith("~/") ? join(home, line.slice(2)) : line))
    .filter(existsSync)
    .map(realpathSync);
  return new Set(roots);
}

export function lspFixPath(input: unknown, processCwd = process.cwd()): string | undefined {
  if (!input || typeof input !== "object") return undefined;
  const values = input as { path?: unknown; root?: unknown };
  if (typeof values.path !== "string") return undefined;
  const requestedRoot = typeof values.root === "string" ? values.root.trim() : "";
  const effectiveRoot = resolve(processCwd, requestedRoot || ".");
  return resolve(effectiveRoot, values.path);
}

export function mutationPath(
  toolName: string,
  input: unknown,
  ctxCwd: string,
  processCwd = process.cwd(),
): string | undefined {
  if (!input || typeof input !== "object") return undefined;
  const values = input as { path?: unknown; write?: unknown };
  if (toolName === "write" || toolName === "edit") {
    return typeof values.path === "string" ? resolve(ctxCwd, values.path) : undefined;
  }
  if (toolName !== "lsp_fix" || values.write !== true) return undefined;
  return lspFixPath(input, processCwd);
}

export function permissionServiceModulePath(agentDir: string): string {
  return join(
    resolve(agentDir),
    "npm",
    "node_modules",
    "@gotgenes",
    "pi-permission-system",
    "src",
    "service.ts",
  );
}

export function registerLspFixExtractor(
  service: PermissionsService,
  processCwd = process.cwd(),
): () => void {
  return service.registerToolAccessExtractor("lsp_fix", (input) =>
    lspFixPath(input, processCwd),
  );
}

export function primaryCheckoutRoot(
  target: string,
  cwd: string,
  home: string,
): string | undefined {
  const absolute = isAbsolute(target) ? target : resolve(cwd, target);
  const directory = nearestExistingDirectory(absolute);
  if (!directory) return undefined;

  try {
    const repoRoot = realpathSync(git(directory, "rev-parse", "--show-toplevel"));
    if (allowedRoots(home).has(repoRoot)) return undefined;

    const gitDir = realpathSync(git(directory, "rev-parse", "--absolute-git-dir"));
    const commonOutput = git(directory, "rev-parse", "--git-common-dir");
    const commonDir = realpathSync(
      isAbsolute(commonOutput) ? commonOutput : resolve(directory, commonOutput),
    );

    return gitDir === commonDir ? repoRoot : undefined;
  } catch {
    return undefined;
  }
}

export default function worktreeGuard(pi: ExtensionAPI) {
  let disposeExtractor: (() => void) | undefined;
  let pendingGeneration: number | undefined;
  let generation = 0;

  pi.events.on("permissions:ready", (raw) => {
    const sessionId = (raw as { sessionId?: unknown }).sessionId;
    if (disposeExtractor || pendingGeneration !== undefined || typeof sessionId !== "string") return;

    const requestGeneration = generation;
    pendingGeneration = requestGeneration;
    void (async () => {
      try {
        const agentDir = process.env.PI_CODING_AGENT_DIR || join(homedir(), ".pi", "agent");
        const moduleUrl = pathToFileURL(permissionServiceModulePath(agentDir)).href;
        const loaded = (await import(moduleUrl)) as {
          getPermissionsService(sessionId: string): PermissionsService | undefined;
        };
        if (requestGeneration !== generation || disposeExtractor) return;
        const service = loaded.getPermissionsService(sessionId);
        if (!service) {
          throw new Error(`permission service is unavailable for session ${sessionId}`);
        }
        disposeExtractor = registerLspFixExtractor(service, process.cwd());
      } catch (error) {
        console.warn(
          `[worktree-guard] Failed to register the lsp_fix permission extractor: ${
            error instanceof Error ? error.message : String(error)
          }`,
        );
      } finally {
        if (pendingGeneration === requestGeneration) pendingGeneration = undefined;
      }
    })();
  });

  pi.on("session_shutdown", () => {
    generation += 1;
    pendingGeneration = undefined;
    disposeExtractor?.();
    disposeExtractor = undefined;
  });

  pi.on("tool_call", (event, ctx) => {
    if (process.env.PI_WORKTREE_GUARD === "off") return;

    const path = mutationPath(event.toolName, event.input, ctx.cwd);
    if (!path) return;

    const root = primaryCheckoutRoot(path, ctx.cwd, process.env.HOME ?? "");
    if (!root) return;

    return {
      block: true,
      reason:
        `Edits are blocked in the primary checkout of ${root}. ` +
        "Create or reuse a linked worktree first. For an exceptional in-place edit, " +
        "add the repository root to ~/.pi/worktree-guard-allow or set PI_WORKTREE_GUARD=off.",
    };
  });
}
