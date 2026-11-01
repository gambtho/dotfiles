// Tool policy for sandboxed review runs. Bubblewrap hides the machine; this also
// hides the throwaway agent directory, which must exist inside the sandbox because
// it holds the credential copy Pi uses to reach the model.
import { existsSync, realpathSync } from "node:fs";
import { dirname, isAbsolute, relative, resolve, sep } from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const READ_TOOLS = new Set(["read", "grep", "find", "ls"]);
const WRITE_TOOLS = new Set(["write", "edit"]);
// Pi strips a leading @, expands ~, follows file: URLs and normalizes these spaces
// after this check, so such a path could be approved here and open somewhere else.
const REINTERPRETED_PATH = /^(?:[@~]|file:)|[\u00A0\u2000-\u200A\u202F\u205F\u3000]/i;

function canonical(target: string): string {
  let current = target;
  const missing: string[] = [];
  while (!existsSync(current)) {
    const parent = dirname(current);
    if (parent === current) break;
    missing.unshift(current.slice(parent.length + 1));
    current = parent;
  }
  return resolve(realpathSync(current), ...missing);
}

function within(target: string, root: string): boolean {
  const path = relative(canonical(root), target);
  return path === "" || (!path.startsWith(`..${sep}`) && path !== ".." && !isAbsolute(path));
}

export function blockReason(
  toolName: string,
  input: unknown,
  cwd: string,
  readRoots: string[],
  writeRoots: string[],
): string | undefined {
  const isRead = READ_TOOLS.has(toolName);
  if (!isRead && !WRITE_TOOLS.has(toolName)) return `tool ${toolName} is not allowed in review runs`;
  const requested = (input as { path?: unknown } | undefined)?.path;
  if (typeof requested === "string" && REINTERPRETED_PATH.test(requested)) {
    return `path form ${JSON.stringify(requested)} is not allowed in review runs`;
  }
  const target = canonical(resolve(cwd, typeof requested === "string" && requested ? requested : "."));
  const roots = isRead ? readRoots : writeRoots;
  if (!roots.some((root) => within(target, root))) return `${target} is outside this review's allowed paths`;
  if (!isRead && target.split(sep).includes(".git")) return "writing under .git is not allowed";
  return undefined;
}

function roots(name: string): string[] {
  return (process.env[name] ?? "").split(":").filter(Boolean);
}

export default function automationGuard(pi: ExtensionAPI) {
  pi.on("tool_call", async (event, ctx) => {
    const reason = blockReason(
      event.toolName,
      event.input,
      ctx.cwd,
      roots("AUTOMATION_READ_ROOTS"),
      roots("AUTOMATION_WRITE_ROOTS"),
    );
    return reason ? { block: true, reason } : undefined;
  });
}
