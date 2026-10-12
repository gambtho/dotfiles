#!/usr/bin/env bats

load test_helper

setup() {
  # Keep the actual host SDK; only package installation/network is replaced.
  local real_pi real_npm
  real_pi=$(command -v pi) || real_pi=""
  real_npm=$(command -v npm)
  source "$BATS_TEST_DIRNAME/../libexec/lib/pi-runtime.sh"
  resolve_pi_runtime "$real_pi" "${PI_TEST_HOST_ROOT:-}"
  export HOST_ROOT=$PI_RUNTIME_PACKAGE_ROOT
  setup_dotfiles_test
  export REAL_NPM="$real_npm"
  # Real npm lookup stays inside fixture configuration/prefix/cache roots.
  export npm_config_prefix="$TEST_ROOT/global-prefix"
  export npm_config_userconfig="$TEST_ROOT/user.npmrc" npm_config_globalconfig="$TEST_ROOT/global.npmrc"
  export npm_config_cache="$TEST_ROOT/npm-cache" npm_config_logs_dir="$TEST_ROOT/npm-logs"
  export npm_config_update_notifier=false
  printf '' >"$npm_config_userconfig"
  printf '' >"$npm_config_globalconfig"
  export AGENT="$TEST_ROOT/agent" REVIEWED="$TEST_ROOT/reviewed"
  mkdir -p "$AGENT" "$REVIEWED/ai/pi" "$REVIEWED/ai/marketplace/plugins/my"
  printf '{"name":"my","version":"1.0.0"}\n' >"$REVIEWED/ai/marketplace/plugins/my/package.json"
  declarations '["npm:example-tools", "git:github.com/example/skills"]'
  stub_command npm '
    if [[ "${@: -2}" == "root -g" ]]; then exec "$REAL_NPM" "$@"; fi
    [[ "$1" == install && "$3" == --prefix ]] || exit 81
    if [[ "${CHECK_INSTALL_ENV:-0}" == 1 ]]; then
      [[ "$npm_config_cache" == "$TEST_ROOT/npm-cache" && "$npm_config_logs_dir" == "$TEST_ROOT/npm-logs" && "$npm_config_logs_max" == 4 && "$npm_config_timing" == true && "$npm_config_update_notifier" == false ]] || exit 84
      [[ "$NPM_CONFIG_CACHE" == "$TEST_ROOT/npm-cache" && "$Npm_Config_Logs_Dir" == "$TEST_ROOT/npm-logs" ]] || exit 85
    fi
    printf "%s\n" "$2" >>"$TEST_ROOT/installs"
    spec=$2; name=$spec; version=2.3.4
    if [[ "${spec#@}" == *@* ]]; then name=${spec%@*}; version=${spec##*@}; fi
    root="$4/node_modules/$name"
    mkdir -p "$root"
    printf "{\"name\":\"%s\",\"version\":\"%s\"}\n" "$name" "$version" >"$root/package.json"
    if [[ "$name" == @gotgenes/pi-permission-system ]]; then
      if [[ "${REPAIR_VERSION_DRIFT:-0}" == 1 ]]; then printf "{\"name\":\"%s\",\"version\":\"30.0.0\"}\n" "$name" >"$root/package.json"; fi
      mkdir -p "$root/schemas" "$root/src"
      printf "{}\n" >"$root/schemas/permissions.schema.json"
      if [[ "${OMIT_MANAGER:-0}" != 1 ]]; then printf "export class PermissionManager {}\n" >"$root/src/permission-manager.ts"; fi
    fi
    if [[ "${MUTATE_DECLARATIONS:-0}" == 1 ]]; then printf "{\"packages\":[]}\n" >"$AGENT/settings.json"; fi
    if [[ "${MUTATE_HEALTHY:-0}" == 1 ]]; then printf "{\"name\":\"cached\",\"version\":\"9.0.0\"}\n" >"$AGENT/npm/node_modules/cached/package.json"; fi
    if [[ "${LATER_REPAIR_DRIFT:-0}" == 1 && "$name" == other ]]; then printf "{\"name\":\"@gotgenes/pi-permission-system\",\"version\":\"31.0.0\"}\n" >"$AGENT/npm/node_modules/@gotgenes/pi-permission-system/package.json"; fi
    if [[ -n "${REMOVE_PERMISSION_ARTIFACT:-}" && "$name" == other ]]; then rm "$AGENT/npm/node_modules/@gotgenes/pi-permission-system/$REMOVE_PERMISSION_ARTIFACT"; fi
  '
  stub_command git '
    if [[ "$1" == clone ]]; then
      [[ "$2" == https://github.com/example/skills ]] || exit 82
      printf "git:github.com/example/skills\n" >>"$TEST_ROOT/installs"
      exec /usr/bin/git clone -q "$TEST_ROOT/git-seed" "$3"
    fi
    case "$1" in fetch|pull|reset|clean) exit 83 ;; esac
    exec /usr/bin/git "$@"
  '
  seed_npm example-tools 1.2.3
  # Git fixture objects are isolated; no repository commit/index is touched.
  /usr/bin/git init -q "$TEST_ROOT/git-seed"
  local tree sha
  tree=$(printf '' | /usr/bin/git -C "$TEST_ROOT/git-seed" hash-object -w -t tree --stdin)
  sha=$(printf 'fixture\n' | GIT_AUTHOR_NAME=Fixture GIT_AUTHOR_EMAIL=fixture@example.invalid \
    GIT_COMMITTER_NAME=Fixture GIT_COMMITTER_EMAIL=fixture@example.invalid \
    /usr/bin/git -C "$TEST_ROOT/git-seed" commit-tree "$tree")
  /usr/bin/git -C "$TEST_ROOT/git-seed" update-ref HEAD "$sha"
  export GIT_SHA=$sha
  mkdir -p "$AGENT/git/github.com/example"
  /usr/bin/git clone -q "$TEST_ROOT/git-seed" "$AGENT/git/github.com/example/skills"
  /usr/bin/git -C "$AGENT/git/github.com/example/skills" config remote.origin.url https://github.com/example/skills
}

candidate_git_boundary() {
  /usr/bin/git -C "$AGENT/git/github.com/example/skills" config remote.origin.url https://github.com/example/skills
  stub_command git '
    case "$1" in
      ls-remote)
        [[ "$2" == --symref && "$3" == https://github.com/example/skills && "$4" == HEAD ]] || exit 82
        printf "discovery\n" >>"$TEST_ROOT/discoveries"
        case "${BAD_REMOTE_HEAD:-0}" in
          1) printf "%s\tHEAD\n" "$GIT_SHA"; exit ;;
          2) printf "ref: refs/tags/trunk\tHEAD\n%s\tHEAD\n" "$GIT_SHA"; exit ;;
          3) printf "ref: refs/heads/trunk\tHEAD\nabc123\tHEAD\n"; exit ;;
          4) printf "ref: refs/heads/trunk\tHEAD\nref: refs/heads/other\tHEAD\n%s\tHEAD\n" "$GIT_SHA"; exit ;;
        esac
        if [[ "${ADVANCE_ON_FETCH:-0}" == 1 && -e "$TEST_ROOT/fetched" ]]; then /usr/bin/git -C "$TEST_ROOT/git-seed" update-ref refs/heads/trunk "$ADVANCED_SHA"; fi
        exec /usr/bin/git ls-remote --symref "$TEST_ROOT/git-seed" HEAD ;;
      clone)
        [[ "${2%.git}" == https://github.com/example/skills ]] || exit 82
        /usr/bin/git clone -q "$TEST_ROOT/git-seed" "$3" || exit
        /usr/bin/git -C "$3" config remote.origin.url "$2"
        exit ;;
      fetch)
        printf "fetched\n" >"$TEST_ROOT/fetched"
        shift
        [[ "$1" == --no-tags ]] && shift
        [[ "$1" == origin || "$1" == https://github.com/example/skills ]] || exit 82
        shift
        exec /usr/bin/git fetch --no-tags "$TEST_ROOT/git-seed" "$@" ;;
    esac
    # Runner -C calls stay real, including explicit branch fetch via this wrapper.
    if [[ "$1" == -C && "$3" == fetch ]]; then
      root=$2; shift 3; cd "$root" || exit
      exec "$0" fetch "$@"
    fi
    exec /usr/bin/git "$@"
  '
}

new_default_branch() {
  local tree sha
  tree=$(/usr/bin/git -C "$TEST_ROOT/git-seed" rev-parse 'HEAD^{tree}')
  sha=$(printf 'new default\n' | GIT_AUTHOR_NAME=Fixture GIT_AUTHOR_EMAIL=fixture@example.invalid \
    GIT_COMMITTER_NAME=Fixture GIT_COMMITTER_EMAIL=fixture@example.invalid \
    /usr/bin/git -C "$TEST_ROOT/git-seed" commit-tree "$tree" -p "$GIT_SHA")
  /usr/bin/git -C "$TEST_ROOT/git-seed" update-ref refs/heads/trunk "$sha"
  /usr/bin/git -C "$TEST_ROOT/git-seed" symbolic-ref HEAD refs/heads/trunk
  export DEFAULT_SHA=$sha
  candidate_git_boundary
}

declarations() {
  printf '{"packages":%s}\n' "$1" >"$AGENT/settings.json"
  cp "$AGENT/settings.json" "$REVIEWED/ai/pi/settings.json"
}

seed_npm() {
  mkdir -p "$AGENT/npm/node_modules/$1"
  printf '{"name":"%s","version":"%s"}\n' "$1" "$2" >"$AGENT/npm/node_modules/$1/package.json"
}

lifecycle() {
  run bash "$REPO_ROOT/libexec/pi-package-lifecycle" "$1" \
    --agent-dir "$AGENT" --repo-root "$REVIEWED" --pi-package-root "$HOST_ROOT" "${@:2}"
}

tree_state() {
  {
    find "$TEST_ROOT" -mindepth 1 -printf '%y %m %P -> %l\n'
    find "$TEST_ROOT" -type f -exec sha256sum {} +
  } | sort
}

@test "lifecycle fixture honors explicit SDK root when pi is absent from PATH" {
  mkdir -p "$TEST_ROOT/hostless-bin"
  ln -s "$REAL_NPM" "$TEST_ROOT/hostless-bin/npm"
  local hostless_path="$TEST_ROOT/hostless-bin:/usr/bin:/bin:$SANDBOX_TOOL_BIN"
  PATH="$hostless_path" run command -v pi
  [ "$status" -ne 0 ]
  PATH="$hostless_path" PI_TEST_HOST_ROOT="$HOST_ROOT" run bats --filter '^inspect reports installed concrete resolutions without writing or fetching$' "$BATS_TEST_FILENAME"
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *'ok 1 inspect reports installed concrete resolutions'* ]]
  PATH="$hostless_path" PI_TEST_HOST_ROOT="" run bats --filter '^inspect reports installed concrete resolutions without writing or fetching$' "$BATS_TEST_FILENAME"
  [ "$status" -ne 0 ]
  [[ "$output" == *'error: Pi executable not found on PATH'* ]]
}

@test "inspect reports installed concrete resolutions without writing or fetching" {
  local before
  before=$(tree_state)
  lifecycle inspect
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e --arg sha "$GIT_SHA" '.packages[0].resolution == "1.2.3" and .packages[1].resolution == $sha'
  [ "$before" = "$(tree_state)" ]
  [ ! -e "$TEST_ROOT/installs" ]
}

@test "stock npm root probe with sink controls leaves temporary roots unchanged" {
  local before
  before=$(tree_state)
  run bash -c 'npm_config_cache=/dev/null npm_config_logs_dir=/dev/null npm_config_logs_max=0 npm_config_timing=false npm_config_update_notifier=false "$REAL_NPM" --prefix "$TEST_ROOT/probe-prefix" root -g'
  [ "$status" -eq 0 ]
  [ "$output" = "$TEST_ROOT/probe-prefix/lib/node_modules" ]
  [ "$before" = "$(tree_state)" ]
}

@test "inspect missing npm uses real lookup without creating caches timing files or cleaning logs" {
  rm -rf "$AGENT/npm/node_modules/example-tools"
  export npm_config_logs_max=0 npm_config_timing=true
  export NPM_CONFIG_CACHE="$npm_config_cache" Npm_Config_Logs_Dir="$npm_config_logs_dir"
  mkdir -p "$npm_config_logs_dir"
  printf 'prior log\n' >"$npm_config_logs_dir/2000-01-01T00_00_00_000Z-debug-0.log"
  local before
  before=$(tree_state)
  lifecycle inspect
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '.packages[0].state == "absent"'
  [ "$before" = "$(tree_state)" ]
  [ ! -e "$npm_config_cache" ]
}

@test "readonly real npm lookup keeps custom prefix semantics when refusing a foreign root" {
  rm -rf "$AGENT/npm/node_modules/example-tools"
  local prefix="$TEST_ROOT/custom-prefix"
  mkdir -p "$prefix/lib/node_modules/example-tools"
  printf '{"name":"example-tools","version":"7.0.0"}\n' >"$prefix/lib/node_modules/example-tools/package.json"
  local command before
  for command in "[\"npm\", \"--prefix\", \"$prefix\"]" "[\"$REAL_NPM\", \"--prefix=$prefix\"]"; do
    jq --argjson command "$command" '.npmCommand = $command' "$AGENT/settings.json" >"$TEST_ROOT/settings-prefix"
    cp "$TEST_ROOT/settings-prefix" "$AGENT/settings.json"
    before=$(tree_state)
    lifecycle inspect
    [ "$status" -eq 1 ]
    [[ "$output" == *foreign*root* ]]
    [ "$before" = "$(tree_state)" ]
  done
}

@test "readonly lookup rejects explicit side effect flags before running npm" {
  rm -rf "$AGENT/npm/node_modules/example-tools"
  local args before
  for args in '["--cache=/tmp/unsafe"]' '["--logs-dir", "/tmp/unsafe"]' '["--logs-max=3"]' '["--timing"]' '["--update-notifier=true"]'; do
    jq --argjson args "$args" '.npmCommand = ["npm"] + $args' "$AGENT/settings.json" >"$TEST_ROOT/unsafe-options"
    cp "$TEST_ROOT/unsafe-options" "$AGENT/settings.json"
    stub_command npm 'printf "ran\n" >"$TEST_ROOT/lookup-executed"; exit 81'
    before=$(tree_state)
    lifecycle inspect
    [ "$status" -eq 1 ]
    [[ "$output" == *readonly*flags* ]]
    [ "$before" = "$(tree_state)" ]
    [ ! -e "$TEST_ROOT/lookup-executed" ]
  done
}

@test "readonly lookup rejects opaque wrappers and unestablished transports before execution" {
  rm -rf "$AGENT/npm/node_modules/example-tools"
  local command before
  for command in '["pnpm"]' '["bun"]' '["opaque", "--", "npm"]' '["npm", "--prefix"]' '42'; do
    jq --argjson command "$command" '.npmCommand = $command' "$AGENT/settings.json" >"$TEST_ROOT/unsafe-transport"
    cp "$TEST_ROOT/unsafe-transport" "$AGENT/settings.json"
    stub_command pnpm 'printf "ran\n" >"$TEST_ROOT/lookup-executed"; exit 81'
    stub_command bun 'printf "ran\n" >"$TEST_ROOT/lookup-executed"; exit 81'
    stub_command opaque 'printf "ran\n" >"$TEST_ROOT/lookup-executed"; exit 81'
    stub_command npm 'printf "ran\n" >"$TEST_ROOT/lookup-executed"; exit 81'
    before=$(tree_state)
    lifecycle inspect
    [ "$status" -eq 1 ]
    [[ "$output" == *unsupported-readonly-transport* ]]
    [ "$before" = "$(tree_state)" ]
    [ ! -e "$TEST_ROOT/lookup-executed" ]
  done
}

@test "readonly lookup restores npm side effect controls before the targeted install" {
  declarations '["npm:example-tools"]'
  rm -rf "$AGENT/npm/node_modules/example-tools"
  export npm_config_logs_max=4 npm_config_timing=true
  export NPM_CONFIG_CACHE="$npm_config_cache" Npm_Config_Logs_Dir="$npm_config_logs_dir"
  export CHECK_INSTALL_ENV=1
  lifecycle bootstrap
  [ "$status" -eq 0 ]
  [ "$(jq -r .version "$AGENT/npm/node_modules/example-tools/package.json")" = 2.3.4 ]
  [ ! -e "$npm_config_cache" ]
}

@test "inspect creates no transient settings locks in the config directory" {
  local before
  before=$(stat -c %y "$AGENT")
  lifecycle inspect
  [ "$status" -eq 0 ]
  [ "$before" = "$(stat -c %y "$AGENT")" ]
}

@test "bootstrap detects an install that changes a different healthy cached resolution" {
  declarations '["npm:missing", "npm:cached"]'
  seed_npm cached 1.0.0
  export MUTATE_HEALTHY=1
  lifecycle bootstrap
  [ "$status" -eq 1 ]
  [[ "$output" == *healthy*resolution* ]]
}

@test "bootstrap preflights incomplete metadata before installing missing packages" {
  declarations '["npm:missing", "npm:example-tools"]'
  rm "$AGENT/npm/node_modules/example-tools/package.json"
  lifecycle bootstrap
  [ "$status" -eq 1 ]
  [[ "$output" == *incomplete* ]]
  [ ! -e "$TEST_ROOT/installs" ]
}

@test "promotion requires the reviewed local package to exist without installing it" {
  declarations "[\"npm:example-tools\", \"$REVIEWED/ai/marketplace/plugins/my\"]"
  rm -rf "$REVIEWED/ai/marketplace/plugins/my"
  lifecycle snapshot --manifest "$TEST_ROOT/private/resolution.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *local* ]]
  [ ! -e "$TEST_ROOT/private" ]
}

@test "bootstrap rejects missing reviewed local before any remote installation" {
  declarations "[\"npm:missing\", \"$REVIEWED/ai/marketplace/plugins/my\"]"
  rm -rf "$REVIEWED/ai/marketplace/plugins/my"
  local before
  before=$(tree_state)
  lifecycle bootstrap
  [ "$status" -eq 1 ]
  [[ "$output" == *unresolved*local* ]]
  [ ! -e "$TEST_ROOT/installs" ]
  [ "$before" = "$(tree_state)" ]
}

@test "snapshot and verify reject same HEAD modified staged and untracked Git bytes" {
  real_git_package
  lifecycle bootstrap
  [ "$status" -eq 0 ]
  lifecycle snapshot --manifest "$TEST_ROOT/private/resolution.json"
  [ "$status" -eq 0 ]
  local root="$AGENT/git/github.com/example/skills" dirty action before
  for dirty in modified staged untracked; do
    printf 'user bytes\n' >>"$root/package.json"
    if [[ "$dirty" == staged ]]; then /usr/bin/git -C "$root" add package.json; fi
    if [[ "$dirty" == untracked ]]; then
      /usr/bin/git -C "$root" restore package.json
      printf 'user bytes\n' >"$root/user.txt"
    fi
    before=$(tree_state)
    for action in snapshot verify; do
      local manifest="$TEST_ROOT/private/snapshot.json"
      [[ "$action" != verify ]] || manifest="$TEST_ROOT/private/resolution.json"
      lifecycle "$action" --manifest "$manifest"
      [ "$status" -eq 1 ]
      [[ "$output" == *dirty*Git* ]]
      [ "$before" = "$(tree_state)" ]
      [ "$(/usr/bin/git -C "$root" rev-parse HEAD)" = "$GIT_SHA" ]
    done
    # Readonly inspection/recovery still describe and preserve dirty state.
    lifecycle inspect
    [ "$status" -eq 0 ]
    lifecycle capture-recovery --manifest "$TEST_ROOT/recovery-$dirty/snapshot.json"
    [ "$status" -eq 0 ]
    /usr/bin/git -C "$root" restore --staged --worktree package.json
    rm -f "$root/user.txt"
  done
}

@test "update and promotion reject Git dirtied by final installation with unchanged HEAD" {
  real_git_package
  lifecycle bootstrap
  [ "$status" -eq 0 ]
  lifecycle snapshot --manifest "$TEST_ROOT/private/resolution.json"
  [ "$status" -eq 0 ]
  stub_command npm '
    if [[ "$PWD" == "$AGENT/git/github.com/example/skills" ]]; then printf "postinstall edit\n" >>package.json; exit; fi
    exec "$REAL_NPM" "$@"
  '
  local action
  for action in update promote; do
    rm -rf "$AGENT/git/github.com/example/skills"
    if [[ "$action" == promote ]]; then
      lifecycle promote --manifest "$TEST_ROOT/private/resolution.json"
    else
      lifecycle update
    fi
    [ "$status" -eq 1 ]
    [[ "$output" == *dirty*Git* ]]
    [ "$(/usr/bin/git -C "$AGENT/git/github.com/example/skills" rev-parse HEAD)" = "$GIT_SHA" ]
    /usr/bin/git -C "$AGENT/git/github.com/example/skills" restore package.json
  done
}

@test "bootstrap preserves healthy cached versions behind floating declarations" {
  cp "$AGENT/settings.json" "$TEST_ROOT/settings-before"
  lifecycle bootstrap
  [ "$status" -eq 0 ]
  cmp "$AGENT/settings.json" "$TEST_ROOT/settings-before"
  [ "$(jq -r .version "$AGENT/npm/node_modules/example-tools/package.json")" = 1.2.3 ]
  [ ! -e "$TEST_ROOT/installs" ]
}

@test "retired cached package remains untouched while authored SDK inventory selects no retired resources" {
  seed_npm @narumitw/pi-caffeinate 0.49.11
  local caffeine="$AGENT/npm/node_modules/@narumitw/pi-caffeinate"
  mkdir -p "$caffeine/extensions"
  printf '%s\n' '{"name":"@narumitw/pi-caffeinate","version":"0.49.11","pi":{"extensions":["extensions/caffeinate.ts"]}}' >"$caffeine/package.json"
  printf 'cached caffeinate\n' >"$caffeine/extensions/caffeinate.ts"
  local caffeine_before
  caffeine_before=$(sha256sum "$caffeine/package.json" "$caffeine/extensions/caffeinate.ts")
  seed_npm shitty-extensions 1.0.9
  local retired="$AGENT/npm/node_modules/shitty-extensions" before
  mkdir -p "$retired/extensions"
  printf '%s\n' '{"name":"shitty-extensions","version":"1.0.9","pi":{"extensions":["extensions/clipboard.ts","extensions/memory-mode.ts","extensions/plan-mode.ts"]}}' >"$retired/package.json"
  printf 'cached clipboard\n' >"$retired/extensions/clipboard.ts"
  printf 'cached memory\n' >"$retired/extensions/memory-mode.ts"
  printf 'cached planner\n' >"$retired/extensions/plan-mode.ts"
  before=$(sha256sum "$retired/package.json" "$retired"/extensions/*.ts)
  run node --input-type=module - "$HOST_ROOT" "$REPO_ROOT/ai/pi/settings.json" "$AGENT" "$REVIEWED" <<'JS'
import assert from "node:assert/strict";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { pathToFileURL } from "node:url";
const { DefaultPackageManager, SettingsManager } = await import(pathToFileURL(`${process.argv[2]}/dist/index.js`).href);
const authored = JSON.parse(readFileSync(process.argv[3], "utf8"));
const sources = [
  "git:github.com/tmustier/pi-extensions", "npm:pi-powerline-footer", "npm:pi-amplike",
  "git:github.com/tmustier/pi-queue-steer", "npm:pi-web-access", "npm:@narumitw/pi-lsp",
  "npm:@gotgenes/pi-permission-system", "npm:@gotgenes/pi-subagents",
  "git:github.com/obra/superpowers", "git:github.com/addyosmani/agent-skills",
  "npm:@narumitw/pi-worktree", "npm:@narumitw/pi-file-context", "~/.dotfiles/ai/marketplace/plugins/my",
];
assert.deepEqual(authored.packages.map(pkg => typeof pkg === "string" ? pkg : pkg.source).sort(), [...sources].sort());
const selected = {
  "git:github.com/tmustier/pi-extensions": {
    extensions: ["raw-paste/index.ts", "session-recap/index.ts", "tab-status/tab-status.ts", "usage-extension/index.ts", "pi-ralph-wiggum/index.ts", "code-actions/index.ts"],
    skills: ["pi-ralph-wiggum/SKILL.md"], prompts: [], themes: [],
  },
  "npm:pi-amplike": {
    extensions: ["extensions/btw.ts", "extensions/handoff.ts", "extensions/modes.ts", "extensions/session-query.ts"],
    skills: ["skills/session-query/SKILL.md"], prompts: [], themes: [],
  },
  "git:github.com/addyosmani/agent-skills": {
    extensions: [], skills: ["skills/security-and-hardening/SKILL.md", "skills/performance-optimization/SKILL.md"], prompts: [], themes: [],
  },
};
const extra = { extensions: ["extensions/unselected.ts"], skills: ["skills/unselected/SKILL.md"], prompts: ["prompts/unselected.md"], themes: ["themes/unselected.json"] };
function write(path, content) {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, content);
}
for (const entry of authored.packages) {
  const source = typeof entry === "string" ? entry : entry.source;
  if (["npm:shitty-extensions", "npm:@narumitw/pi-caffeinate"].includes(source)) continue; // Intact caches seeded by Bash.
  const packageRoot = source.startsWith("npm:") ? join(process.argv[4], "npm/node_modules", source.slice(4))
    : source.startsWith("git:") ? join(process.argv[4], "git", source.slice(4))
    : join(process.env.HOME, ".dotfiles/ai/marketplace/plugins/my");
  const resources = selected[source] ? Object.fromEntries(Object.keys(extra).map(kind => [kind, [...selected[source][kind], ...extra[kind]]])) : extra;
  write(join(packageRoot, "package.json"), JSON.stringify({ name: source.slice(4), version: "2.3.4", pi: resources }));
  for (const paths of Object.values(resources)) for (const path of paths) write(join(packageRoot, path), path.endsWith("SKILL.md") ? "---\nname: fixture\ndescription: fixture\n---\n" : "");
}
const manager = new DefaultPackageManager({ cwd: process.argv[5], agentDir: process.argv[4], settingsManager: SettingsManager.inMemory(authored) });
const resolved = await manager.resolve(async source => { throw new Error(`unexpected missing source ${source}`); });
for (const source of ["shitty-extensions", "@narumitw/pi-caffeinate"]) {
  const retiredRoot = `${process.argv[4]}/npm/node_modules/${source}/`;
  for (const kind of ["extensions", "skills", "prompts", "themes"]) {
    assert.equal(resolved[kind].filter(resource => resource.enabled && resource.path.startsWith(retiredRoot)).length, 0, `retired ${source} ${kind} must not load from cache`);
  }
  assert.ok(!manager.listConfiguredPackages().some(pkg => pkg.source === `npm:${source}`), "retired source must not remain configured");
}
for (const [source, expected] of Object.entries(selected)) {
  for (const [kind, paths] of Object.entries(expected)) {
    const enabled = resolved[kind].filter(resource => resource.enabled && resource.metadata.source === source);
    assert.deepEqual(enabled.map(resource => relative(resource.metadata.packageRoot, resource.path)).sort(), [...paths].sort(), `${source}: ${kind}`);
  }
}
for (const kind of Object.keys(extra)) assert.ok(resolved[kind].some(resource => resource.enabled && resource.metadata.source === "git:github.com/obra/superpowers"));
for (const source of ["npm:@narumitw/pi-worktree", "npm:@narumitw/pi-file-context"]) {
  assert.ok(resolved.extensions.some(resource => resource.enabled && resource.metadata.source === source));
}
const my = manager.listConfiguredPackages().find(pkg => pkg.source === "~/.dotfiles/ai/marketplace/plugins/my");
assert.equal(my.installedPath, join(process.env.HOME, ".dotfiles/ai/marketplace/plugins/my"));
console.log("actual SDK selects exact authored sources and local my, no retired resources despite intact caches; enabled filters retained");
JS
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
  [ "$before" = "$(sha256sum "$retired/package.json" "$retired"/extensions/*.ts)" ]
  [ "$caffeine_before" = "$(sha256sum "$caffeine/package.json" "$caffeine/extensions/caffeinate.ts")" ]
  # Ordinary reconciliation follows declarations only, never uninstalls a cache.
  before=$(tree_state)
  lifecycle bootstrap
  [ "$status" -eq 0 ]
  [ "$before" = "$(tree_state)" ]
  [ ! -e "$TEST_ROOT/installs" ]
}

@test "bootstrap installs only the missing npm package and leaves declarations floating" {
  rm -rf "$AGENT/npm/node_modules/example-tools"
  lifecycle bootstrap
  [ "$status" -eq 0 ]
  [ "$(jq -r .version "$AGENT/npm/node_modules/example-tools/package.json")" = 2.3.4 ]
  [ "$(<"$TEST_ROOT/installs")" = example-tools ]
  [ "$(jq -r '.packages[0]' "$AGENT/settings.json")" = npm:example-tools ]
  [ "$(/usr/bin/git -C "$AGENT/git/github.com/example/skills" rev-parse HEAD)" = "$GIT_SHA" ]
}

@test "bootstrap installs a missing floating scoped npm package without changing its declaration" {
  declarations '["npm:@scope/tools"]'
  lifecycle bootstrap
  [ "$status" -eq 0 ]
  [ "$(jq -r .name "$AGENT/npm/node_modules/@scope/tools/package.json")" = @scope/tools ]
  [ "$(jq -r .version "$AGENT/npm/node_modules/@scope/tools/package.json")" = 2.3.4 ]
  [ "$(<"$TEST_ROOT/installs")" = @scope/tools ]
  [ "$(jq -r '.packages[0]' "$AGENT/settings.json")" = npm:@scope/tools ]
  [ ! -e "$AGENT/npm/node_modules/package.json" ]
}

@test "bootstrap installs only the missing Git package" {
  rm -rf "$AGENT/git/github.com/example/skills"
  lifecycle bootstrap
  [ "$status" -eq 0 ]
  [ "$(/usr/bin/git -C "$AGENT/git/github.com/example/skills" rev-parse HEAD)" = "$GIT_SHA" ]
  [ "$(<"$TEST_ROOT/installs")" = git:github.com/example/skills ]
  [ "$(jq -r '.packages[1]' "$AGENT/settings.json")" = git:github.com/example/skills ]
}

real_git_package() {
  declarations '["git:github.com/example/skills"]'
  # Real SDK + offline npm; only the Git transport is a fixture.
  local blob tree lock_entry=''
  blob=$(printf '{"name":"fixture-skills","version":"1.0.0"}\n' |
    /usr/bin/git -C "$TEST_ROOT/git-seed" hash-object -w --stdin)
  if [[ "${1:-}" == lock || "${1:-}" == shrinkwrap ]]; then
    local lock_blob lock_name=package-lock.json
    [[ "${1:-}" != shrinkwrap ]] || lock_name=npm-shrinkwrap.json
    lock_blob=$(printf '%s\n' '{"name":"fixture-skills","version":"1.0.0","lockfileVersion":3,"requires":true,"packages":{"":{"name":"fixture-skills","version":"1.0.0"}}}' | jq . |
      /usr/bin/git -C "$TEST_ROOT/git-seed" hash-object -w --stdin)
    lock_entry=$(printf '100644 blob %s\t%s\n' "$lock_blob" "$lock_name")
  fi
  tree=$({
    printf '100644 blob %s\tpackage.json\n' "$blob"
    [[ -z "$lock_entry" ]] || printf '%s\n' "$lock_entry"
  } |
    /usr/bin/git -C "$TEST_ROOT/git-seed" mktree)
  GIT_SHA=$(printf 'Git package fixture\n' | GIT_AUTHOR_NAME=Fixture GIT_AUTHOR_EMAIL=fixture@example.invalid \
    GIT_COMMITTER_NAME=Fixture GIT_COMMITTER_EMAIL=fixture@example.invalid \
    /usr/bin/git -C "$TEST_ROOT/git-seed" commit-tree "$tree")
  export GIT_SHA npm_config_offline=true
  /usr/bin/git -C "$TEST_ROOT/git-seed" update-ref HEAD "$GIT_SHA"
  candidate_git_boundary
  rm -rf "$AGENT/git/github.com/example/skills"
  stub_command npm 'exec "$REAL_NPM" "$@"'
}

@test "real SDK Git bootstrap and default update do not generate new locks" {
  real_git_package
  lifecycle bootstrap
  [ "$status" -eq 0 ]
  local root="$AGENT/git/github.com/example/skills"
  [ ! -e "$root/package-lock.json" ]
  [ "$(/usr/bin/git -C "$root" status --porcelain --untracked-files=all)" = '' ]
  lifecycle preflight
  [ "$status" -eq 0 ]
  new_default_branch
  lifecycle update
  [ "$status" -eq 0 ]
  [ "$(/usr/bin/git -C "$root" rev-parse HEAD)" = "$DEFAULT_SHA" ]
  [ ! -e "$root/package-lock.json" ]
  [ "$(/usr/bin/git -C "$root" status --porcelain --untracked-files=all)" = '' ]
}

@test "real SDK Git dot-git spellings bootstrap without new locks" {
  real_git_package
  local source root="$AGENT/git/github.com/example/skills"
  for source in git:github.com/example/skills.git "git:github.com/example/skills.git@$GIT_SHA"; do
    rm -rf "$root"
    declarations "[\"$source\"]"
    lifecycle bootstrap
    printf '%s\n' "$output"
    [ "$status" -eq 0 ]
    [ -f "$root/package.json" ]
    [ ! -e "$root/package-lock.json" ]
    [ ! -e "$root.git" ]
    [ "$(jq -r '.packages[0]' "$AGENT/settings.json")" = "$source" ]
    [ "$(/usr/bin/git -C "$root" status --porcelain --untracked-files=all)" = '' ]
  done
}

@test "Git npm wrapper accepts only the SDK checkout including a canonical directory alias" {
  local root="$AGENT/git/github.com/example/skills" alias="$TEST_ROOT/agent-alias" selected
  ln -s "$AGENT" "$alias"
  for selected in "$AGENT" "$alias"; do
    run bash -c 'cd "$1" && shift && exec node "$@"' wrapper "$root" \
      "$REPO_ROOT/libexec/pi-git-npm-install.mjs" "$HOST_ROOT" "$REVIEWED" "$selected" \
      git:github.com/example/skills.git -- bash -c 'printf "%s\n" "$@" >"$TEST_ROOT/wrapper-args"' _
    printf '%s\n' "$output"
    [ "$status" -eq 0 ]
    [ "$(<"$TEST_ROOT/wrapper-args")" = --package-lock=false ]
    rm "$TEST_ROOT/wrapper-args"
  done
  run bash -c 'cd "$1" && shift && exec node "$@"' wrapper "$REVIEWED" \
    "$REPO_ROOT/libexec/pi-git-npm-install.mjs" "$HOST_ROOT" "$REVIEWED" "$AGENT" \
    git:github.com/example/skills.git -- bash -c 'printf "ran\n" >"$TEST_ROOT/wrapper-args"'
  [ "$status" -eq 1 ]
  [[ "$output" == *'requires the selected checkout cwd'* ]]
  [ ! -e "$TEST_ROOT/wrapper-args" ]
  [ ! -e "$root/package-lock.json" ]
}

@test "real SDK Git installs preserve tracked locks and caller npm controls" {
  real_git_package lock
  export NPM_CONFIG_PACKAGE_LOCK=true npm_config_package_lock=true
  stub_command npm '
    if [[ "$PWD" == "$AGENT/git/github.com/example/skills" ]]; then
      [[ " $* " != *"--package-lock=false"* ]] || exit 86
      [[ "$NPM_CONFIG_PACKAGE_LOCK" == true && "$npm_config_package_lock" == true ]] || exit 87
      printf "tracked-lock\n" >>"$TEST_ROOT/lock-policy"
    fi
    exec "$REAL_NPM" "$@"
  '
  lifecycle bootstrap
  [ "$status" -eq 0 ]
  local root="$AGENT/git/github.com/example/skills" before
  before=$(sha256sum "$root/package-lock.json")
  [ "$(/usr/bin/git -C "$root" ls-files package-lock.json)" = package-lock.json ]
  [ "$(/usr/bin/git -C "$root" status --porcelain --untracked-files=all)" = '' ]
  new_default_branch
  lifecycle update
  [ "$status" -eq 0 ]
  [ "$before" = "$(sha256sum "$root/package-lock.json")" ]
  [ "$(wc -l <"$TEST_ROOT/lock-policy")" -eq 2 ]
  [ "$NPM_CONFIG_PACKAGE_LOCK" = true ]
  [ "$npm_config_package_lock" = true ]
}

@test "real SDK Git installs retain tracked shrinkwrap without suppressing caller npm controls" {
  real_git_package shrinkwrap
  export NPM_CONFIG_PACKAGE_LOCK=true npm_config_package_lock=true
  stub_command npm '
    if [[ "$PWD" == "$AGENT/git/github.com/example/skills" ]]; then
      [[ " $* " != *"--package-lock=false"* ]] || exit 86
      [[ "$NPM_CONFIG_PACKAGE_LOCK" == true && "$npm_config_package_lock" == true ]] || exit 87
      printf "shrinkwrap\n" >>"$TEST_ROOT/lock-policy"
    fi
    exec "$REAL_NPM" "$@"
  '
  lifecycle bootstrap
  [ "$status" -eq 0 ]
  local root="$AGENT/git/github.com/example/skills" before
  before=$(sha256sum "$root/npm-shrinkwrap.json")
  [ "$(/usr/bin/git -C "$root" ls-files npm-shrinkwrap.json)" = npm-shrinkwrap.json ]
  [ "$(/usr/bin/git -C "$root" status --porcelain --untracked-files=all)" = '' ]
  new_default_branch
  lifecycle update
  [ "$status" -eq 0 ]
  [ "$before" = "$(sha256sum "$root/npm-shrinkwrap.json")" ]
  [ "$(wc -l <"$TEST_ROOT/lock-policy")" -eq 2 ]
  [ ! -e "$root/package-lock.json" ]
  [ "$(/usr/bin/git -C "$root" status --porcelain --untracked-files=all)" = '' ]
  [ "$NPM_CONFIG_PACKAGE_LOCK" = true ]
  [ "$npm_config_package_lock" = true ]
}

@test "failed real SDK Git installation leaves caller environment and registry installs unchanged" {
  real_git_package
  export NPM_CONFIG_PACKAGE_LOCK=true npm_config_package_lock=true
  stub_command npm '
    if [[ "$PWD" == "$AGENT/git/github.com/example/skills" ]]; then
      [[ " $* " == *"--package-lock=false"* ]] || exit 86
      [[ "$NPM_CONFIG_PACKAGE_LOCK" == true && "$npm_config_package_lock" == true ]] || exit 87
      printf "intentional-install-failure\n" >&2
      exit 88
    fi
    if [[ "$1" == install ]]; then
      [[ " $* " != *"--package-lock=false"* ]] || exit 89
      [[ "$NPM_CONFIG_PACKAGE_LOCK" == true && "$npm_config_package_lock" == true ]] || exit 90
      mkdir -p "$AGENT/npm/node_modules/example-tools"
      printf "{\"name\":\"example-tools\",\"version\":\"2.3.4\"}\n" >"$AGENT/npm/node_modules/example-tools/package.json"
      exit
    fi
    exec "$REAL_NPM" "$@"
  '
  lifecycle bootstrap
  [ "$status" -eq 1 ]
  [[ "$output" == *intentional-install-failure* ]]
  [ ! -e "$AGENT/git/github.com/example/skills" ]
  [ "$NPM_CONFIG_PACKAGE_LOCK" = true ]
  [ "$npm_config_package_lock" = true ]
  declarations '["npm:example-tools"]'
  lifecycle update
  [ "$status" -eq 0 ]
  [ "$(jq -r .version "$AGENT/npm/node_modules/example-tools/package.json")" = 2.3.4 ]
}

@test "real SDK generated legacy lockfile still blocks preflight without cleanup or resolution" {
  real_git_package
  # Reproduce the unfixed upstream behavior independently of our installer.
  run node --input-type=module - "$HOST_ROOT" "$REVIEWED" "$AGENT" <<'JS'
import { pathToFileURL } from "node:url";
const sdk = await import(pathToFileURL(`${process.argv[2]}/dist/index.js`).href);
const manager = new sdk.DefaultPackageManager({ cwd: process.argv[3], agentDir: process.argv[4], settingsManager: sdk.SettingsManager.inMemory({packages:["git:github.com/example/skills"]}) });
await manager.install("git:github.com/example/skills");
JS
  [ "$status" -eq 0 ]
  local root="$AGENT/git/github.com/example/skills" before action
  [ -f "$root/package-lock.json" ]
  [ "$(/usr/bin/git -C "$root" status --porcelain --untracked-files=all)" = '?? package-lock.json' ]
  [ "$(/usr/bin/git -C "$root" rev-parse HEAD)" = "$GIT_SHA" ]
  before=$(tree_state)
  for action in preflight update; do
    lifecycle "$action"
    [ "$status" -eq 1 ]
    [[ "$output" == *'dirty Git checkout git:github.com/example/skills'* ]]
    [ "$before" = "$(tree_state)" ]
    [ ! -e "$TEST_ROOT/discoveries" ]
    [ ! -e "$TEST_ROOT/fetched" ]
    [ ! -e "$TEST_ROOT/recovery" ]
    [ ! -e "$TEST_ROOT/private" ]
    [ ! -e "$TEST_ROOT/installs" ]
  done
}

@test "bootstrap repairs each missing permission artifact with its cached exact version" {
  declarations '["npm:@gotgenes/pi-permission-system"]'
  seed_npm @gotgenes/pi-permission-system 29.2.0
  local root="$AGENT/npm/node_modules/@gotgenes/pi-permission-system" missing
  mkdir -p "$root/schemas" "$root/src"
  for missing in schemas/permissions.schema.json src/permission-manager.ts; do
    printf '{}\n' >"$root/schemas/permissions.schema.json"
    printf 'export class PermissionManager {}\n' >"$root/src/permission-manager.ts"
    rm "$root/$missing"
    rm -f "$TEST_ROOT/installs"
    lifecycle bootstrap
    [ "$status" -eq 0 ]
    [ -f "$root/$missing" ]
    [ "$(<"$TEST_ROOT/installs")" = @gotgenes/pi-permission-system@29.2.0 ]
    [ "$(jq -r '.packages[0]' "$AGENT/settings.json")" = npm:@gotgenes/pi-permission-system ]
  done
}

@test "bootstrap rejects healthy permission repair at a changed cached version before later installs" {
  declarations '["npm:@gotgenes/pi-permission-system", "npm:other"]'
  seed_npm @gotgenes/pi-permission-system 29.2.0
  export REPAIR_VERSION_DRIFT=1
  lifecycle bootstrap
  [ "$status" -eq 1 ]
  [[ "$output" == *cached*resolution* ]]
  [ "$(<"$TEST_ROOT/installs")" = @gotgenes/pi-permission-system@29.2.0 ]
  [ ! -e "$AGENT/npm/node_modules/other" ]
}

@test "bootstrap rejects later targeted installs changing the repaired cached permission version" {
  declarations '["npm:@gotgenes/pi-permission-system", "npm:other"]'
  seed_npm @gotgenes/pi-permission-system 29.2.0
  export LATER_REPAIR_DRIFT=1
  lifecycle bootstrap
  [ "$status" -eq 1 ]
  [[ "$output" == *cached*resolution* ]]
  [ "$(<"$TEST_ROOT/installs")" = $'@gotgenes/pi-permission-system@29.2.0\nother' ]
  [ "$(jq -r .version "$AGENT/npm/node_modules/@gotgenes/pi-permission-system/package.json")" = 31.0.0 ]
}

@test "bootstrap rejects same-version artifact removal from initially healthy permissions" {
  declarations '["npm:@gotgenes/pi-permission-system", "npm:other", "npm:after-damage"]'
  seed_npm @gotgenes/pi-permission-system 29.2.0
  local root="$AGENT/npm/node_modules/@gotgenes/pi-permission-system" artifact
  mkdir -p "$root/schemas" "$root/src"
  for artifact in schemas/permissions.schema.json src/permission-manager.ts; do
    printf '{}\n' >"$root/schemas/permissions.schema.json"
    printf 'export class PermissionManager {}\n' >"$root/src/permission-manager.ts"
    rm -rf "$AGENT/npm/node_modules/other" "$AGENT/npm/node_modules/after-damage"
    rm -f "$TEST_ROOT/installs"
    export REMOVE_PERMISSION_ARTIFACT="$artifact"
    lifecycle bootstrap
    [ "$status" -eq 1 ]
    [[ "$output" == *required*health* ]]
    [ "$(jq -r .version "$root/package.json")" = 29.2.0 ]
    [ ! -e "$root/$artifact" ]
    [ "$(<"$TEST_ROOT/installs")" = other ]
    [ ! -e "$AGENT/npm/node_modules/after-damage" ]
  done
}

@test "bootstrap rejects same-version artifact removal after permission repair" {
  declarations '["npm:@gotgenes/pi-permission-system", "npm:other", "npm:after-damage"]'
  seed_npm @gotgenes/pi-permission-system 29.2.0
  local root="$AGENT/npm/node_modules/@gotgenes/pi-permission-system" artifact
  mkdir -p "$root/schemas" "$root/src"
  for artifact in schemas/permissions.schema.json src/permission-manager.ts; do
    printf '{}\n' >"$root/schemas/permissions.schema.json"
    printf 'export class PermissionManager {}\n' >"$root/src/permission-manager.ts"
    rm "$root/$artifact"
    rm -rf "$AGENT/npm/node_modules/other" "$AGENT/npm/node_modules/after-damage"
    rm -f "$TEST_ROOT/installs"
    export REMOVE_PERMISSION_ARTIFACT="$artifact"
    lifecycle bootstrap
    [ "$status" -eq 1 ]
    [[ "$output" == *required*health* ]]
    [ "$(jq -r .version "$root/package.json")" = 29.2.0 ]
    [ ! -e "$root/$artifact" ]
    [ "$(<"$TEST_ROOT/installs")" = $'@gotgenes/pi-permission-system@29.2.0\nother' ]
    [ ! -e "$AGENT/npm/node_modules/after-damage" ]
  done
}

@test "bootstrap allows a still-pending permission repair until its own install" {
  declarations '["npm:other", "npm:@gotgenes/pi-permission-system"]'
  seed_npm @gotgenes/pi-permission-system 29.2.0
  lifecycle bootstrap
  [ "$status" -eq 0 ]
  [ "$(<"$TEST_ROOT/installs")" = $'other\n@gotgenes/pi-permission-system@29.2.0' ]
  local root="$AGENT/npm/node_modules/@gotgenes/pi-permission-system"
  [ "$(jq -r .version "$root/package.json")" = 29.2.0 ]
  [ -f "$root/schemas/permissions.schema.json" ]
  [ -f "$root/src/permission-manager.ts" ]
}

@test "bootstrap fails if targeted permission repair remains incomplete" {
  declarations '["npm:@gotgenes/pi-permission-system"]'
  seed_npm @gotgenes/pi-permission-system 29.2.0
  export OMIT_MANAGER=1
  lifecycle bootstrap
  [ "$status" -ne 0 ]
  [[ "$output" == *incomplete* ]]
  [[ "$output" == *src/permission-manager.ts* ]]
}

@test "bootstrap refuses metadata mismatch instead of updating an untrusted package" {
  printf '{"name":"foreign","version":"1.2.3"}\n' >"$AGENT/npm/node_modules/example-tools/package.json"
  lifecycle bootstrap
  [ "$status" -ne 0 ]
  [[ "$output" == *metadata* ]]
  [ ! -e "$TEST_ROOT/installs" ]
}

@test "lifecycle accepts symlink HOME and trusted ancestor but refuses managed and custom aliases" {
  local physical="$TEST_ROOT/physical-home" alias="$TEST_ROOT/home-alias" ancestor="$TEST_ROOT/ancestor" selected before
  mkdir -p "$physical"
  mv "$AGENT" "$physical/agent"
  ln -s "$physical" "$alias"
  ln -s "$TEST_ROOT" "$ancestor"
  export HOME="$alias" AGENT="$alias/agent"
  for selected in "$alias" "$ancestor/physical-home" "$physical"; do
    export HOME="$selected" AGENT="$selected/agent"
    lifecycle inspect
    printf '%s\n' "$output"
    [ "$status" -eq 0 ]
  done
  export HOME="$alias" AGENT="$alias/agent"
  chmod 700 "$physical/agent"
  chmod 600 "$physical/agent/settings.json"
  before=$(tree_state)
  lifecycle verify --manifest "$physical/agent/settings.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *'unsafe manifest destination'* ]]
  [ "$before" = "$(tree_state)" ]
  mv "$physical/agent/npm" "$TEST_ROOT/foreign-npm"
  ln -s "$TEST_ROOT/foreign-npm" "$physical/agent/npm"
  before=$(tree_state)
  lifecycle bootstrap
  [ "$status" -eq 1 ]
  [[ "$output" == *symlink* ]]
  [ "$before" = "$(tree_state)" ]
  # A lexical same-prefix sibling is not HOME, nor is an explicit custom root.
  for selected in "$physical-other" "$TEST_ROOT/custom-agent"; do
    ln -s "$physical/agent" "$selected"
    export AGENT="$selected"
    lifecycle inspect
    [ "$status" -eq 1 ]
    [[ "$output" == *symlink* ]]
  done
  [ ! -e "$TEST_ROOT/installs" ]
}

@test "managed path OS alias predicate fixtures accept only exact standard targets" {
  run node --input-type=module - "$REPO_ROOT/libexec/pi-managed-paths.mjs" "$TEST_ROOT" <<'JS'
import assert from "node:assert/strict";
import { mkdirSync, symlinkSync } from "node:fs";
import { pathToFileURL } from "node:url";
const { isStandardAlias, assertManagedPath, managedPhysicalPath } = await import(pathToFileURL(process.argv[2]));
for (const path of ["/tmp", "/var", "/etc"]) {
  assert.equal(isStandardAlias(path, `/private${path}`), true);
  for (const target of ["/foreign", `/private${path}-other`, `${process.argv[3]}/private${path}`]) {
    assert.equal(isStandardAlias(path, target), false, `${path} -> ${target}`);
  }
}
assert.equal(isStandardAlias("/tmp-other", "/private/tmp"), false);
const missing = `${process.env.HOME}/absent/agent`;
assertManagedPath(missing, true);
assert.equal(managedPhysicalPath(missing), missing);
// Filesystem alias names alone never confer standard-OS trust.
mkdirSync(`${process.argv[3]}/os-fixture/private`, { recursive: true });
symlinkSync(`${process.argv[3]}/os-fixture/private`, `${process.argv[3]}/os-fixture/tmp`);
assert.throws(() => assertManagedPath(`${process.argv[3]}/os-fixture/tmp/absent`), /symlink/);
console.log("exact OS alias predicate and foreign filesystem fixture; not macOS certification");
JS
  [ "$status" -eq 0 ]
}

@test "runner refuses a foreign package root symlink before installing anything" {
  mv "$AGENT/npm" "$TEST_ROOT/foreign-npm"
  ln -s "$TEST_ROOT/foreign-npm" "$AGENT/npm"
  lifecycle bootstrap
  [ "$status" -ne 0 ]
  [[ "$output" == *symlink* ]]
  [ ! -e "$TEST_ROOT/installs" ]
}

@test "runner refuses project scope package contamination without changing trust" {
  mkdir -p "$REVIEWED/.pi"
  printf '{"packages":["npm:foreign"]}\n' >"$REVIEWED/.pi/settings.json"
  local before
  before=$(tree_state)
  lifecycle inspect
  [ "$status" -ne 0 ]
  [[ "$output" == *project* ]]
  [ "$before" = "$(tree_state)" ]
}

@test "runner refuses credential-bearing sources without printing their value" {
  declarations '["git:https://user:private-token@github.com/example/skills"]'
  lifecycle inspect
  [ "$status" -eq 1 ]
  [[ "$output" == *unsupported* ]]
  [[ "$output" != *private-token* ]]
  [ ! -e "$TEST_ROOT/installs" ]
}

@test "bootstrap detects semantic declaration mutation by the install API" {
  rm -rf "$AGENT/npm/node_modules/example-tools"
  export MUTATE_DECLARATIONS=1
  lifecycle bootstrap
  [ "$status" -ne 0 ]
  [[ "$output" == *declarations* ]]
}

@test "snapshot records exact remotes privately and verify rejects npm resolution drift" {
  lifecycle snapshot --manifest "$TEST_ROOT/private/resolution.json"
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$TEST_ROOT/private")" = 700 ]
  [ "$(stat -c %a "$TEST_ROOT/private/resolution.json")" = 600 ]
  jq -e --arg sha "$GIT_SHA" '.schemaVersion == 1 and .packages[0].exactSource == "npm:example-tools@1.2.3" and .packages[1].exactSource == ("git:github.com/example/skills@" + $sha)' "$TEST_ROOT/private/resolution.json"
  lifecycle verify --manifest "$TEST_ROOT/private/resolution.json"
  [ "$status" -eq 0 ]
  seed_npm example-tools 8.0.0
  lifecycle verify --manifest "$TEST_ROOT/private/resolution.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *resolution* ]]
}

@test "verify rejects changed full Git HEAD without fetching" {
  lifecycle snapshot --manifest "$TEST_ROOT/private/resolution.json"
  [ "$status" -eq 0 ]
  local root="$AGENT/git/github.com/example/skills" tree sha
  tree=$(/usr/bin/git -C "$root" rev-parse 'HEAD^{tree}')
  sha=$(printf 'changed fixture\n' | GIT_AUTHOR_NAME=Fixture GIT_AUTHOR_EMAIL=fixture@example.invalid \
    GIT_COMMITTER_NAME=Fixture GIT_COMMITTER_EMAIL=fixture@example.invalid \
    /usr/bin/git -C "$root" commit-tree "$tree" -p "$GIT_SHA")
  /usr/bin/git -C "$root" update-ref HEAD "$sha"
  lifecycle verify --manifest "$TEST_ROOT/private/resolution.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *resolution* ]]
  [ ! -e "$TEST_ROOT/installs" ]
}

@test "snapshot rejects missing and incomplete packages without bootstrap" {
  rm -rf "$AGENT/npm/node_modules/example-tools"
  lifecycle snapshot --manifest "$TEST_ROOT/private/missing.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *unresolved* ]]
  [ ! -e "$TEST_ROOT/private" ]
  mkdir -p "$AGENT/npm/node_modules/example-tools"
  lifecycle snapshot --manifest "$TEST_ROOT/private/incomplete.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *incomplete* ]]
  [ ! -e "$TEST_ROOT/installs" ]
}

@test "promotion rejects added declarations and changed resource filters" {
  printf '{"packages":["npm:example-tools", "git:github.com/example/skills", "npm:extra"]}\n' >"$AGENT/settings.json"
  lifecycle snapshot --manifest "$TEST_ROOT/private/resolution.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *reviewed* ]]
  declarations '[{"source":"npm:example-tools", "extensions":[]}, "git:github.com/example/skills"]'
  lifecycle snapshot --manifest "$TEST_ROOT/private/resolution.json"
  [ "$status" -eq 0 ]
  printf '{"packages":[{"source":"npm:example-tools","extensions":["extra.ts"]}, "git:github.com/example/skills"]}\n' >"$AGENT/settings.json"
  cp "$AGENT/settings.json" "$REVIEWED/ai/pi/settings.json"
  lifecycle verify --manifest "$TEST_ROOT/private/resolution.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *digest* ]]
}

@test "local my is preserved and excluded from resolution equality across checkouts" {
  declarations "[\"npm:example-tools\", \"$REVIEWED/ai/marketplace/plugins/my\"]"
  local before
  before=$(sha256sum "$REVIEWED/ai/marketplace/plugins/my/package.json")
  lifecycle bootstrap
  [ "$status" -eq 0 ]
  [ "$before" = "$(sha256sum "$REVIEWED/ai/marketplace/plugins/my/package.json")" ]
  lifecycle snapshot --manifest "$TEST_ROOT/private/resolution.json"
  [ "$status" -eq 0 ]
  jq -e '.packages | length == 1' "$TEST_ROOT/private/resolution.json"
  cp -r "$REVIEWED" "$TEST_ROOT/other-checkout"
  export REVIEWED="$TEST_ROOT/other-checkout"
  declarations "[\"npm:example-tools\", \"$REVIEWED/ai/marketplace/plugins/my\"]"
  lifecycle verify --manifest "$TEST_ROOT/private/resolution.json"
  [ "$status" -eq 0 ]
}

@test "verify rejects malformed schema duplicate identities and inconsistent exact sources" {
  lifecycle snapshot --manifest "$TEST_ROOT/private/resolution.json"
  [ "$status" -eq 0 ]
  cp "$TEST_ROOT/private/resolution.json" "$TEST_ROOT/original"
  local mutation
  for mutation in '.schemaVersion = 2' '.packages += [.packages[0]]' '.packages[0].exactSource = "npm:example-tools@9.0.0"' '.packages[0].resolution = "latest"' '.packages[1].resolution = "abc123"' '.packages[0].kind = "url"' '.unexpected = true' '.packages[0].unexpected = true'; do
    jq "$mutation" "$TEST_ROOT/original" >"$TEST_ROOT/private/resolution.json"
    lifecycle verify --manifest "$TEST_ROOT/private/resolution.json"
    [ "$status" -eq 1 ]
    [[ "$output" == *manifest* ]]
  done
}

@test "snapshot cannot target runtime configs or protected machine-local stores" {
  chmod 700 "$AGENT"
  local path
  for path in auth.json trust.json pi-file-context.json settings.json sessions/session.json; do
    lifecycle snapshot --manifest "$AGENT/$path"
    [ "$status" -eq 1 ]
    [[ "$output" == *destination* ]]
  done
  [ ! -e "$AGENT/auth.json" ]
  [ ! -e "$AGENT/sessions" ]
}

@test "snapshot refuses unsafe destinations without replacing existing files" {
  mkdir -p "$TEST_ROOT/public"
  chmod 755 "$TEST_ROOT/public"
  lifecycle snapshot --manifest "$TEST_ROOT/public/resolution.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *destination* ]]
  [ ! -e "$TEST_ROOT/public/resolution.json" ]
  mkdir -m 700 "$TEST_ROOT/private"
  printf 'sentinel\n' >"$TEST_ROOT/sentinel"
  ln -s "$TEST_ROOT/sentinel" "$TEST_ROOT/private/resolution.json"
  lifecycle snapshot --manifest "$TEST_ROOT/private/resolution.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *symlink* ]]
  [ "$(<"$TEST_ROOT/sentinel")" = sentinel ]
}

@test "capture-recovery retains retired package metadata before incoming declaration removal" {
  seed_npm shitty-extensions 1.0.9
  declarations '["npm:example-tools", "npm:shitty-extensions"]'
  printf '{"packages":["npm:example-tools"]}\n' >"$REVIEWED/ai/pi/settings.json"
  local before
  before=$(sha256sum "$AGENT/settings.json" "$AGENT/npm/node_modules/shitty-extensions/package.json")
  lifecycle capture-recovery --manifest "$TEST_ROOT/recovery/snapshot.json"
  [ "$status" -eq 0 ]
  jq -e '.schemaVersion == 1 and .kind == "pre-update-recovery" and .priorDeclarations == ["npm:example-tools","npm:shitty-extensions"] and .packages[1].exactSource == "npm:shitty-extensions@1.0.9" and .packages[1].state == "installed"' "$TEST_ROOT/recovery/snapshot.json"
  local backup
  backup=$(jq -r '.configBackups[] | select(.destination | endswith("/settings.json")) | .backupPath' "$TEST_ROOT/recovery/snapshot.json")
  cmp "$AGENT/settings.json" "$backup"
  [ "$(stat -c %a "$backup")" = 600 ]
  [ "$(stat -c %a "$TEST_ROOT/recovery/snapshot.json")" = 600 ]
  [ "$before" = "$(sha256sum "$AGENT/settings.json" "$AGENT/npm/node_modules/shitty-extensions/package.json")" ]
  [ ! -e "$TEST_ROOT/installs" ]
}

@test "capture-recovery records incoming absence and prior incomplete state with no install" {
  rm "$AGENT/npm/node_modules/example-tools/package.json"
  printf '{"packages":["npm:example-tools", "git:github.com/example/skills", "npm:incoming"]}\n' >"$REVIEWED/ai/pi/settings.json"
  printf '{"marker":"old-modes"}\n' >"$AGENT/modes.json"
  local before
  before=$(sha256sum "$AGENT/settings.json" "$AGENT/modes.json")
  lifecycle capture-recovery --manifest "$TEST_ROOT/recovery/snapshot.json"
  [ "$status" -eq 0 ]
  jq -e '.kind == "pre-update-recovery" and .packages[0].state == "incomplete" and .packages[2].state == "absent" and .priorDeclarations == ["npm:example-tools", "git:github.com/example/skills"]' "$TEST_ROOT/recovery/snapshot.json"
  printf '%s\n' "$output" >"$TEST_ROOT/capture-events"
  local backup
  backup=$(jq -r '.configBackups[] | select(.destination | endswith("/modes.json")) | .backupPath' "$TEST_ROOT/recovery/snapshot.json")
  cmp "$AGENT/modes.json" "$backup"
  [ "$(stat -c %a "$backup")" = 600 ]
  [ "$(stat -c %a "$(dirname "$backup")")" = 700 ]
  [ "$before" = "$(sha256sum "$AGENT/settings.json" "$AGENT/modes.json")" ]
  [ ! -e "$TEST_ROOT/installs" ]
  printf 'declaration-mutation\n' >>"$TEST_ROOT/capture-events"
  printf '{"packages":[]}\n' >"$AGENT/settings.json"
  printf 'config-mutation\n' >>"$TEST_ROOT/capture-events"
  printf '{"marker":"new-modes"}\n' >"$AGENT/modes.json"
  printf 'package-mutation\n' >>"$TEST_ROOT/capture-events"
  seed_npm example-tools 9.0.0
  mapfile -t events <"$TEST_ROOT/capture-events"
  printf '%s\n' "${events[0]}" | jq -e '.action == "capture-recovery"'
  [ "${events[1]}" = declaration-mutation ]
  [ "${events[2]}" = config-mutation ]
  [ "${events[3]}" = package-mutation ]
  [ "$(jq -r .marker "$backup")" = old-modes ]
  # The captured snapshot exists before any caller publishes new declarations.
  jq -e '.configBackups | length == 7' "$TEST_ROOT/recovery/snapshot.json"
}

@test "capture-recovery records owned links and receipt but no unrelated or secret files" {
  mkdir -p "$REVIEWED/ai/pi/config"
  printf '{"owned":true}\n' >"$REVIEWED/ai/pi/config/file-context.json"
  ln -s "$REVIEWED/ai/pi/config/file-context.json" "$AGENT/pi-file-context.json"
  printf '{"completed":true}\n' >"$AGENT/dotfiles-migrations.json"
  printf 'secret-sentinel\n' >"$AGENT/auth.json"
  lifecycle capture-recovery --manifest "$TEST_ROOT/recovery/snapshot.json"
  [ "$status" -eq 0 ]
  jq -e '.configBackups[] | select(.destination | endswith("/pi-file-context.json")) | .state == "owned-link" and (.linkTarget | endswith("/ai/pi/config/file-context.json"))' "$TEST_ROOT/recovery/snapshot.json"
  jq -e '.configBackups[] | select(.destination | endswith("/dotfiles-migrations.json")) | .state == "regular-file"' "$TEST_ROOT/recovery/snapshot.json"
  run grep -R -q 'secret-sentinel\|auth.json' "$TEST_ROOT/recovery"
  [ "$status" -eq 1 ]
}

@test "capture-recovery refuses foreign settings links before reading their targets" {
  printf 'not a config\n' >"$TEST_ROOT/foreign-target"
  rm "$AGENT/settings.json"
  ln -s "$TEST_ROOT/foreign-target" "$AGENT/settings.json"
  lifecycle capture-recovery --manifest "$TEST_ROOT/recovery/snapshot.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *foreign*link* ]]
  [[ "$output" != *malformed* ]]
  [ ! -e "$TEST_ROOT/recovery" ]
}

@test "explicit update upgrades floating npm but leaves settings and filters unchanged" {
  declarations '[{"source":"npm:example-tools","extensions":[]}]'
  cp "$AGENT/settings.json" "$TEST_ROOT/before-settings"
  lifecycle update
  [ "$status" -eq 0 ]
  [ "$(jq -r .version "$AGENT/npm/node_modules/example-tools/package.json")" = 2.3.4 ]
  cmp "$AGENT/settings.json" "$TEST_ROOT/before-settings"
}

@test "promotion of absent npm and Git installs only recorded exact sources without discovery" {
  lifecycle snapshot --manifest "$TEST_ROOT/private/resolution.json"
  [ "$status" -eq 0 ]
  candidate_git_boundary
  rm -rf "$AGENT/npm/node_modules/example-tools" "$AGENT/git/github.com/example/skills"
  lifecycle promote --manifest "$TEST_ROOT/private/resolution.json"
  [ "$status" -eq 0 ]
  [ "$(jq -r .version "$AGENT/npm/node_modules/example-tools/package.json")" = 1.2.3 ]
  [ "$(/usr/bin/git -C "$AGENT/git/github.com/example/skills" rev-parse HEAD)" = "$GIT_SHA" ]
  [ "$(<"$TEST_ROOT/installs")" = example-tools@1.2.3 ]
  [ ! -e "$TEST_ROOT/discoveries" ]
  lifecycle verify --manifest "$TEST_ROOT/private/resolution.json"
  [ "$status" -eq 0 ]
}

@test "promotion preflight rejects filter digest and exact-source tampering before mutation" {
  lifecycle snapshot --manifest "$TEST_ROOT/private/resolution.json"
  [ "$status" -eq 0 ]
  cp "$TEST_ROOT/private/resolution.json" "$TEST_ROOT/original"
  local mutation before
  for mutation in '.declarationDigest = ("a" * 64)' '.packages = []' '.packages[0].declaredSource = "npm:example-tools@1.2.3"' '.packages[0].exactSource = "npm:example-tools@9.0.0"'; do
    jq "$mutation" "$TEST_ROOT/original" >"$TEST_ROOT/private/resolution.json"
    before=$(tree_state)
    lifecycle promote --manifest "$TEST_ROOT/private/resolution.json"
    [ "$status" -eq 1 ]
    [[ "$output" == *manifest* ]]
    [ "$before" = "$(tree_state)" ]
  done
}

@test "latest Git update selects remote default rather than existing nondefault upstream" {
  declarations '["git:github.com/example/skills"]'
  new_default_branch
  /usr/bin/git -C "$AGENT/git/github.com/example/skills" checkout -qb feature
  /usr/bin/git -C "$AGENT/git/github.com/example/skills" config branch.feature.remote origin
  /usr/bin/git -C "$AGENT/git/github.com/example/skills" config branch.feature.merge refs/heads/master
  lifecycle update
  [ "$status" -eq 0 ]
  [ "$(/usr/bin/git -C "$AGENT/git/github.com/example/skills" rev-parse HEAD)" = "$DEFAULT_SHA" ]
  [ -f "$TEST_ROOT/discoveries" ]
  [ "$(jq -r '.packages[0]' "$AGENT/settings.json")" = git:github.com/example/skills ]
}

@test "latest Git update discovers changed default branch and installs absent checkout by full SHA" {
  declarations '["git:github.com/example/skills"]'
  new_default_branch
  rm -rf "$AGENT/git/github.com/example/skills"
  lifecycle update
  [ "$status" -eq 0 ]
  [ "$(/usr/bin/git -C "$AGENT/git/github.com/example/skills" rev-parse HEAD)" = "$DEFAULT_SHA" ]
  [ -f "$TEST_ROOT/discoveries" ]
}

@test "latest Git update refuses defaultless remote and dirty edits before any candidate install" {
  declarations '["git:github.com/example/skills", "npm:missing"]'
  new_default_branch
  local malformed
  for malformed in 1 2 3 4; do
    export BAD_REMOTE_HEAD=$malformed
    lifecycle update
    [ "$status" -eq 1 ]
    [[ "$output" == *default* ]]
    [ ! -e "$TEST_ROOT/fetched" ]
    [ ! -e "$TEST_ROOT/installs" ]
  done
  unset BAD_REMOTE_HEAD
  printf 'user edit\n' >"$AGENT/git/github.com/example/skills/user.txt"
  lifecycle update
  [ "$status" -eq 1 ]
  [[ "$output" == *dirty* ]]
  [ ! -e "$TEST_ROOT/fetched" ]
  [ "$(<"$AGENT/git/github.com/example/skills/user.txt")" = 'user edit' ]
  [ ! -e "$TEST_ROOT/installs" ]
}

@test "update refuses active YOLO before installation" {
  declarations '["npm:example-tools"]'
  mkdir -p "$AGENT/extensions/pi-permission-system"
  printf '{"yoloMode":true}\n' >"$AGENT/extensions/pi-permission-system/config.json"
  local before
  before=$(tree_state)
  lifecycle update
  [ "$status" -eq 1 ]
  [[ "$output" == *YOLO* ]]
  [ "$before" = "$(tree_state)" ]
}

@test "latest Git update rediscoveries remote advancement instead of sealing the stale SHA" {
  declarations '["git:github.com/example/skills"]'
  new_default_branch
  local tree
  tree=$(/usr/bin/git -C "$TEST_ROOT/git-seed" rev-parse 'HEAD^{tree}')
  export ADVANCED_SHA
  ADVANCED_SHA=$(printf 'advanced default\n' | GIT_AUTHOR_NAME=Fixture GIT_AUTHOR_EMAIL=fixture@example.invalid \
    GIT_COMMITTER_NAME=Fixture GIT_COMMITTER_EMAIL=fixture@example.invalid \
    /usr/bin/git -C "$TEST_ROOT/git-seed" commit-tree "$tree" -p "$DEFAULT_SHA")
  export ADVANCE_ON_FETCH=1
  lifecycle update
  [ "$status" -eq 0 ]
  [ "$(/usr/bin/git -C "$AGENT/git/github.com/example/skills" rev-parse HEAD)" = "$ADVANCED_SHA" ]
  [ "$(wc -l <"$TEST_ROOT/discoveries")" -ge 3 ]
}

@test "promotion of existing Git uses recorded SHA even when remote default changed" {
  lifecycle snapshot --manifest "$TEST_ROOT/private/resolution.json"
  [ "$status" -eq 0 ]
  new_default_branch
  lifecycle promote --manifest "$TEST_ROOT/private/resolution.json"
  [ "$status" -eq 0 ]
  [ "$(/usr/bin/git -C "$AGENT/git/github.com/example/skills" rev-parse HEAD)" = "$GIT_SHA" ]
  [ ! -e "$TEST_ROOT/discoveries" ]
}

@test "capture-recovery cleans only its newly created scratch after real file-size I/O failure" {
  jq --arg padding "$(printf '%10000s' 'x')" '.padding = $padding' "$AGENT/settings.json" >"$TEST_ROOT/padded-settings"
  cp "$TEST_ROOT/padded-settings" "$AGENT/settings.json"
  run bash -c 'ulimit -f 2; exec bash "$@"' _ "$REPO_ROOT/libexec/pi-package-lifecycle" capture-recovery \
    --agent-dir "$AGENT" --repo-root "$REVIEWED" --pi-package-root "$HOST_ROOT" --manifest "$TEST_ROOT/recovery/snapshot.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *EFBIG* ]]
  [ ! -e "$TEST_ROOT/recovery" ]
  [ -f "$AGENT/settings.json" ]
  [ ! -e "$TEST_ROOT/installs" ]
}

@test "capture-recovery I/O failure removes partial manifest but preserves existing private siblings" {
  mkdir -m 700 "$TEST_ROOT/recovery"
  printf 'keep\n' >"$TEST_ROOT/recovery/sibling"
  run bash -c 'ulimit -f 1; exec bash "$@"' _ "$REPO_ROOT/libexec/pi-package-lifecycle" capture-recovery \
    --agent-dir "$AGENT" --repo-root "$REVIEWED" --pi-package-root "$HOST_ROOT" --manifest "$TEST_ROOT/recovery/snapshot.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *EFBIG* ]]
  [ "$(<"$TEST_ROOT/recovery/sibling")" = keep ]
  [ ! -e "$TEST_ROOT/recovery/snapshot.json" ]
  [ ! -e "$TEST_ROOT/recovery/snapshot.json.backups" ]
}

@test "preflight validates a promotion against incoming reviewed declarations without publishing them" {
  lifecycle snapshot --manifest "$TEST_ROOT/private/resolution.json"
  [ "$status" -eq 0 ]
  new_default_branch
  printf '{"packages":[]}\n' >"$AGENT/settings.json"
  local before
  before=$(tree_state)
  lifecycle preflight --manifest "$TEST_ROOT/private/resolution.json"
  [ "$status" -eq 0 ]
  [ "$before" = "$(tree_state)" ]
  [ ! -e "$TEST_ROOT/discoveries" ]
  [ ! -e "$TEST_ROOT/fetched" ]
}

@test "explicit update refreshes pinned npm candidate without rewriting the declaration" {
  declarations '["npm:example-tools@1.2.3"]'
  lifecycle update
  [ "$status" -eq 0 ]
  [ "$(jq -r .version "$AGENT/npm/node_modules/example-tools/package.json")" = 2.3.4 ]
  [ "$(jq -r '.packages[0]' "$AGENT/settings.json")" = npm:example-tools@1.2.3 ]
}

@test "update refuses unreviewed credential-bearing Git origin without echoing it or installing npm" {
  declarations '["npm:missing", "git:github.com/example/skills"]'
  candidate_git_boundary
  /usr/bin/git -C "$AGENT/git/github.com/example/skills" config remote.origin.url https://user:secret-sentinel@github.com/example/skills
  local before
  before=$(tree_state)
  lifecycle update
  [ "$status" -eq 1 ]
  [[ "$output" == *unreviewed*origin* ]]
  [[ "$output" != *secret-sentinel* ]]
  [ "$before" = "$(tree_state)" ]
  [ ! -e "$TEST_ROOT/installs" ]
}

@test "capture-recovery preflights foreign links and malformed configs before any backup writes" {
  printf '{}\n' >"$TEST_ROOT/foreign-config"
  ln -s "$TEST_ROOT/foreign-config" "$AGENT/modes.json"
  lifecycle capture-recovery --manifest "$TEST_ROOT/recovery/snapshot.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *foreign* ]]
  [ ! -e "$TEST_ROOT/recovery" ]
  rm "$AGENT/modes.json"
  printf '{broken\n' >"$AGENT/models.json"
  lifecycle capture-recovery --manifest "$TEST_ROOT/recovery/snapshot.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *malformed* ]]
  [ ! -e "$TEST_ROOT/recovery" ]
}
