#!/usr/bin/env bats

load test_helper

setup() {
  setup_dotfiles_test
  CONFIG_DIR="$REPO_ROOT/ai/pi/config"
  PERMISSION_CONFIG="$CONFIG_DIR/permission-system.json"
  SUBAGENT_CONFIG="$CONFIG_DIR/subagents.json"
  WEB_CONFIG="$CONFIG_DIR/web-search.json"
  SETTINGS="$REPO_ROOT/ai/pi/settings.json"
}

@test "Pi runtime baselines are valid JSON" {
  local config
  for config in \
    "$CONFIG_DIR/modes.json" \
    "$PERMISSION_CONFIG" \
    "$SUBAGENT_CONFIG" \
    "$WEB_CONFIG"; do
    run jq empty "$config"
    [ "$status" -eq 0 ]
  done
}

@test "Pi permission policy starts balanced without unredacted review logging" {
  run jq -e '
    .debugLog == false
    and .permissionReviewLog == false
    and .yoloMode == false
    and .doublePressToConfirm == false
    and .forwardingTimeoutMs == 600000
    and .permission["*"] == "ask"
    and .permission.read == "allow"
    and .permission.grep == "allow"
    and .permission.find == "allow"
    and .permission.ls == "allow"
    and .permission.write == "allow"
    and .permission.edit == "allow"
    and .permission.lsp_diagnostics == "allow"
    and .permission.lsp_fix == "ask"
    and .permission.mcp["*"] == "ask"
    and .permission.skill["*"] == "allow"
  ' "$PERMISSION_CONFIG"
  [ "$status" -eq 0 ]
}

@test "Pi permission policy allows known workflow tools" {
  local tool
  for tool in \
    subagent \
    get_subagent_result \
    steer_subagent \
    handoff \
    session_query \
    plan \
    ralph_start \
    ralph_done \
    copy_to_clipboard \
    web_search \
    source_check \
    fetch_content \
    get_search_content; do
    run jq -er --arg tool "$tool" '.permission[$tool]' "$PERMISSION_CONFIG"
    [ "$status" -eq 0 ]
    [ "$output" = allow ]
  done
}

@test "Pi permission path policy protects secrets without blocking env examples" {
  run jq -e '
    . as $config
    | all(["path_read", "path_write"][];
      . as $surface
      | $config.permission[$surface] as $rules
      | $rules["*"] == "allow"
      and $rules["*.env"] == "deny"
      and $rules["*.env.*"] == "deny"
      and $rules["*.env.example"] == "allow"
      and $rules["*.pem"] == "deny"
      and $rules["*.key"] == "deny"
      and $rules["~/.ssh"] == "deny"
      and $rules["~/.ssh/*"] == "deny"
      and $rules["~/.aws"] == "deny"
      and $rules["~/.aws/*"] == "deny"
      and $rules["~/.azure"] == "deny"
      and $rules["~/.azure/*"] == "deny"
      and $rules["~/.config/gcloud"] == "deny"
      and $rules["~/.config/gcloud/*"] == "deny"
      and $rules["~/.kube"] == "deny"
      and $rules["~/.kube/*"] == "deny"
      and $rules["~/.docker"] == "deny"
      and $rules["~/.docker/*"] == "deny"
      and $rules["~/.config/google-chrome"] == "deny"
      and $rules["~/.config/google-chrome/*"] == "deny"
      and $rules["~/.config/chromium"] == "deny"
      and $rules["~/.config/chromium/*"] == "deny"
      and $rules["~/.mozilla"] == "deny"
      and $rules["~/.mozilla/*"] == "deny"
      and $rules["__PI_AGENT_DIR__/auth.json"] == "deny"
      and (($rules | keys_unsorted | index("*.env.example"))
        > ($rules | keys_unsorted | index("*.env.*")))
    )
    and .permission.external_directory_read["*"] == "ask"
    and .permission.external_directory_write["*"] == "ask"
  ' "$PERMISSION_CONFIG"
  [ "$status" -eq 0 ]
}

@test "Pi permission Bash policy asks for unmatched commands while guarding risky operations" {
  run jq -e '
    .permission.bash as $bash
    | $bash["*"] == "ask"
    and $bash["git *"] == "ask"
    and $bash["*/git *"] == "ask"
    and $bash["gh *"] == "ask"
    and $bash["*/gh *"] == "ask"
    and $bash["curl *"] == "ask"
    and $bash["*/curl *"] == "ask"
    and $bash["wget *"] == "ask"
    and $bash["ssh *"] == "ask"
    and $bash["scp *"] == "ask"
    and $bash["rsync *"] == "ask"
    and $bash["rm *"] == "ask"
    and $bash["*/rm *"] == "ask"
    and $bash["nc *"] == "ask"
    and $bash["*/socat *"] == "ask"
    and $bash["command *"] == "ask"
    and $bash.env == "ask"
    and $bash.printenv == "ask"
    and $bash.export == "ask"
    and $bash["declare *-x*"] == "ask"
    and $bash["git status*"] == "allow"
    and $bash["git show *--ext-diff*"] == "ask"
    and $bash["git show *--textconv*"] == "ask"
    and $bash["git diff *--ext-diff*"] == "ask"
    and $bash["git diff *--textconv*"] == "ask"
    and $bash["git log *--ext-diff*"] == "ask"
    and $bash["git log *--textconv*"] == "ask"
    and $bash["*rg *--pre*"] == "deny"
    and $bash["*fd *--exec*"] == "deny"
    and $bash["*fd *-x*"] == "deny"
    and $bash["*fd *-X*"] == "deny"
    and $bash["yq -i*"] == "ask"
    and $bash["yq --inplace*"] == "ask"
    and ($bash | has("*$*") | not)
    and $bash["*cat *$*"] == "ask"
    and $bash["*rg *$*"] == "ask"
    and $bash["*git *push *--force*"] == "deny"
    and $bash["*git *push -f*"] == "deny"
    and $bash["*git *reset *--hard*"] == "deny"
    and $bash["*git *clean -*f*"] == "deny"
    and $bash["*gh *repo delete*"] == "deny"
    and $bash["*gh *api *DELETE*"] == "deny"
    and $bash["*sudo *"] == "deny"
    and $bash["*doas *"] == "deny"
    and $bash["*rm *-*r* /"] == "deny"
    and $bash["*rm *-*r* /*"] == "deny"
    and $bash["*rm / *-*r*"] == "deny"
    and $bash["*rm /* *-*r*"] == "deny"
    and $bash["*rm *-*r* /* *"] == "deny"
    and $bash["*rm * /*/*"] == "ask"
    and $bash["*rm /*/* *"] == "ask"
  ' "$PERMISSION_CONFIG"
  [ "$status" -eq 0 ]
}

@test "Pi web access uses keyless ordered search and local extraction" {
  run jq -e '
    .searchRouting.providers == ["exa", "duckduckgo"]
    and .searchRouting.useCurrentModel == false
    and .searchRouting.fallbackOn == ["transient", "quota", "network", "invalid-response"]
    and (has("provider") | not)
    and (has("searchProvider") | not)
    and (has("authFetch") | not)
    and .fetchRouting.providers == ["http"]
    and .fetchRouting.allowRemoteHostedProviders == false
    and .workflow == "none"
    and .allowBrowserCookies == false
    and .autoOpenBrowser == false
    and .commands.curator.enabled == false
    and .commands["google-account"].enabled == false
    and .image.enabled == false
    and .githubClone.enabled == false
    and .githubPrIssue.enabled == false
    and .youtube.enabled == false
    and .video.enabled == false
    and .pdf.enabled == true
    and .pdf.provider == "unpdf"
    and .ssrf.allowRanges == []
    and .ssrf.trustEnvProxy == false
  ' "$WEB_CONFIG"
  [ "$status" -eq 0 ]
}

@test "Pi subagent child exclusions exactly match installed package sources" {
  run jq -s -e '
    .[0].excludedExtensionPackages as $excluded
    | [.[1].packages[] | if type == "string" then . else .source end] as $sources
    | $excluded == [
        "git:github.com/tmustier/pi-extensions",
        "npm:pi-powerline-footer",
        "npm:shitty-extensions",
        "npm:pi-amplike",
        "git:github.com/tmustier/pi-queue-steer@v0.2.0",
        "npm:pi-web-access@0.27.0",
        "npm:@narumitw/pi-lsp@0.49.6"
      ]
    and all($excluded[]; . as $source | $sources | index($source) != null)
    and ($excluded | index("npm:@gotgenes/pi-permission-system@29.2.0") == null)
    and ($excluded | index("npm:@gotgenes/pi-subagents@21.2.0") == null)
    and ($sources | map(select(contains("pi-sandbox"))) | length == 0)
    and ($excluded | map(select(contains("pi-sandbox"))) | length == 0)
    and ($excluded | index("git:github.com/obra/superpowers@v6.3.0") == null)
  ' "$SUBAGENT_CONFIG" "$SETTINGS"
  [ "$status" -eq 0 ]
}

@test "tracked Pi runtime baselines contain no credential fields" {
  run jq -s -e '
    [paths(objects) as $path
      | (getpath($path) | keys[]) as $key
      | select($key | test("(api[_-]?key|token|secret|password|credential)"; "i"))]
    | length == 0
  ' "$PERMISSION_CONFIG" "$SUBAGENT_CONFIG" "$WEB_CONFIG"
  [ "$status" -eq 0 ]
}

@test "Pi runtime validator fails clearly when permission package is absent" {
  run "$REPO_ROOT/bin/validate-pi-security-runtime" \
    --package-root "$TEST_ROOT/missing-permission-package"

  [ "$status" -ne 0 ]
  [[ "$output" == *"permission package not installed"* ]]
}

@test "Pi runtime validator fails clearly when bundled jiti is absent" {
  local package_root="$TEST_ROOT/permission-package"
  local pi_root="$TEST_ROOT/pi-package"
  mkdir -p "$package_root/schemas" "$package_root/src" "$pi_root"
  printf '{"version":"29.2.0"}\n' >"$package_root/package.json"
  printf '{"$schema":"https://json-schema.org/draft/2020-12/schema"}\n' \
    >"$package_root/schemas/permissions.schema.json"
  printf 'export class PermissionManager {}\n' >"$package_root/src/permission-manager.ts"

  run "$REPO_ROOT/bin/validate-pi-security-runtime" \
    --package-root "$package_root" \
    --pi-package-root "$pi_root"

  [ "$status" -ne 0 ]
  [[ "$output" == *"Pi bundled jiti not installed"* ]]
}
