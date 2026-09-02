#!/usr/bin/env bats

load test_helper

setup() {
  setup_dotfiles_test
  REPO="$TEST_ROOT/repo"
  WORKTREE="$TEST_ROOT/worktree"
  mkdir -p "$REPO"
  git -C "$REPO" init -q
  git -C "$REPO" config user.email test@example.com
  git -C "$REPO" config user.name Test
  printf 'initial\n' >"$REPO/file.txt"
  git -C "$REPO" add file.txt
  git -C "$REPO" commit -qm initial
  git -C "$REPO" worktree add -q -b feature "$WORKTREE"
}

check_root() {
  node - "$REPO_ROOT/ai/pi/extensions/worktree-guard.ts" "$1" "$2" "$HOME" <<'NODE'
const [modulePath, target, cwd, home] = process.argv.slice(2);
const { primaryCheckoutRoot } = await import(modulePath);
console.log(primaryCheckoutRoot(target, cwd, home) ?? "allowed");
NODE
}

check_tool_call() {
  node - "$REPO_ROOT/ai/pi/extensions/worktree-guard.ts" "$1" "$2" "$3" "$4" <<'NODE'
const [modulePath, toolName, inputJson, contextCwd, processCwd] = process.argv.slice(2);
process.chdir(processCwd);
const loaded = await import(modulePath);
const handlers = new Map();
loaded.default({
  on(name, handler) {
    handlers.set(name, handler);
  },
  events: {
    on() {},
  },
});
const result = await handlers.get("tool_call")(
  { toolName, input: JSON.parse(inputJson) },
  { cwd: contextCwd },
);
console.log(JSON.stringify(result ?? { block: false }));
NODE
}

@test "worktree guard identifies writes in a primary checkout" {
  run check_root file.txt "$REPO"
  [ "$status" -eq 0 ]
  [ "$output" = "$REPO" ]
}

@test "worktree guard allows writes in a linked worktree" {
  run check_root file.txt "$WORKTREE"
  [ "$status" -eq 0 ]
  [ "$output" = allowed ]
}

@test "worktree guard attributes new files to their nearest repository" {
  run check_root new/missing/file.txt "$REPO"
  [ "$status" -eq 0 ]
  [ "$output" = "$REPO" ]
}

@test "worktree guard follows file symlinks into a primary checkout" {
  ln -s "$REPO/file.txt" "$WORKTREE/primary-file.txt"

  run check_root primary-file.txt "$WORKTREE"
  [ "$status" -eq 0 ]
  [ "$output" = "$REPO" ]
}

@test "worktree guard resolves LSP paths using pi-lsp root semantics" {
  run node - "$REPO_ROOT/ai/pi/extensions/worktree-guard.ts" "$REPO" "$WORKTREE" <<'NODE'
const [modulePath, primary, worktree] = process.argv.slice(2);
const { lspFixPath, mutationPath } = await import(modulePath);
const expectedPrimary = `${primary}/file.txt`;
if (lspFixPath({ root: primary, path: "file.txt" }, worktree) !== expectedPrimary) process.exit(1);
if (lspFixPath({ path: "file.txt" }, worktree) !== `${worktree}/file.txt`) process.exit(2);
if (lspFixPath({ root: "relative", path: "file.txt" }, worktree) !== `${worktree}/relative/file.txt`) process.exit(3);
if (lspFixPath({ root: primary }, worktree) !== undefined) process.exit(4);
if (mutationPath("lsp_fix", { root: primary, path: "file.txt", write: false }, worktree, worktree) !== undefined) process.exit(5);
if (mutationPath("lsp_fix", { root: primary, path: "file.txt", write: true }, worktree, worktree) !== expectedPrimary) process.exit(6);
if (mutationPath("edit", { path: "file.txt" }, worktree, primary) !== `${worktree}/file.txt`) process.exit(7);
NODE
  [ "$status" -eq 0 ]
}

@test "worktree guard blocks mutating LSP fixes in a primary checkout" {
  run check_tool_call lsp_fix '{"path":"file.txt","write":true}' "$REPO" "$REPO"
  [ "$status" -eq 0 ]
  run jq -e --arg root "$REPO" '.block == true and (.reason | contains($root))' <<<"$output"
  [ "$status" -eq 0 ]
}

@test "worktree guard cannot bypass the primary checkout through LSP root" {
  run check_tool_call lsp_fix "{\"root\":\"$REPO\",\"path\":\"file.txt\",\"write\":true}" \
    "$WORKTREE" "$WORKTREE"
  [ "$status" -eq 0 ]
  run jq -e --arg root "$REPO" '.block == true and (.reason | contains($root))' <<<"$output"
  [ "$status" -eq 0 ]

  run check_tool_call lsp_fix "{\"path\":\"$REPO/file.txt\",\"write\":true}" \
    "$WORKTREE" "$WORKTREE"
  [ "$status" -eq 0 ]
  run jq -e '.block == true' <<<"$output"
  [ "$status" -eq 0 ]
}

@test "worktree guard allows linked-worktree and preview LSP fixes" {
  run check_tool_call lsp_fix "{\"root\":\"$WORKTREE\",\"path\":\"file.txt\",\"write\":true}" \
    "$WORKTREE" "$WORKTREE"
  [ "$status" -eq 0 ]
  run jq -e '.block == false' <<<"$output"
  [ "$status" -eq 0 ]

  run check_tool_call lsp_fix "{\"root\":\"$REPO\",\"path\":\"file.txt\",\"write\":false}" \
    "$REPO" "$REPO"
  [ "$status" -eq 0 ]
  run jq -e '.block == false' <<<"$output"
  [ "$status" -eq 0 ]

  run check_tool_call lsp_fix "{\"root\":\"$REPO\",\"path\":\"file.txt\"}" "$REPO" "$REPO"
  [ "$status" -eq 0 ]
  run jq -e '.block == false' <<<"$output"
  [ "$status" -eq 0 ]
}

@test "worktree guard retains built-in edit blocking" {
  run check_tool_call edit '{"path":"file.txt"}' "$REPO" "$WORKTREE"
  [ "$status" -eq 0 ]
  run jq -e '.block == true' <<<"$output"
  [ "$status" -eq 0 ]
}

@test "worktree guard resolves the installed permission service by absolute path" {
  local agent_dir="$TEST_ROOT/custom-agent"
  run node - "$REPO_ROOT/ai/pi/extensions/worktree-guard.ts" "$agent_dir" <<'NODE'
const [modulePath, agentDir] = process.argv.slice(2);
const { permissionServiceModulePath } = await import(modulePath);
console.log(permissionServiceModulePath(agentDir));
NODE
  [ "$status" -eq 0 ]
  [ "$output" = "$agent_dir/npm/node_modules/@gotgenes/pi-permission-system/src/service.ts" ]
}

@test "worktree guard registers the rooted LSP extractor and propagates disposal" {
  run node - "$REPO_ROOT/ai/pi/extensions/worktree-guard.ts" "$REPO" "$WORKTREE" <<'NODE'
const [modulePath, primary, worktree] = process.argv.slice(2);
const { registerLspFixExtractor } = await import(modulePath);
let toolName;
let extractor;
let disposed = false;
const service = {
  registerToolAccessExtractor(name, value) {
    toolName = name;
    extractor = value;
    return () => { disposed = true; };
  },
};
const dispose = registerLspFixExtractor(service, worktree);
if (toolName !== "lsp_fix") process.exit(1);
if (extractor({ root: primary, path: "file.txt" }) !== `${primary}/file.txt`) process.exit(2);
dispose();
if (!disposed) process.exit(3);
NODE
  [ "$status" -eq 0 ]
}

@test "worktree guard honors the Pi allow file" {
  mkdir -p "$HOME/.pi"
  printf '%s # intentional exception\n' "$REPO" >"$HOME/.pi/worktree-guard-allow"

  run check_root file.txt "$REPO"
  [ "$status" -eq 0 ]
  [ "$output" = allowed ]
}
