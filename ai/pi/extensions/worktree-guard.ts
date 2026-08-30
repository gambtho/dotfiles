import { existsSync, readFileSync, realpathSync, statSync } from "node:fs";
import { dirname, isAbsolute, join, resolve } from "node:path";
import { execFileSync } from "node:child_process";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

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
  pi.on("tool_call", (event, ctx) => {
    if (process.env.PI_WORKTREE_GUARD === "off") return;
    if (event.toolName !== "write" && event.toolName !== "edit") return;

    const path = (event.input as { path?: unknown }).path;
    if (typeof path !== "string") return;

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
