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
    and .permission.lsp_fix == "allow"
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
    and .permission.external_directory_read["*"] == "allow"
    and .permission.external_directory_write["*"] == "allow"
    and .permission.external_directory_read["~/.agents/skills/*"] == "allow"
    and (.permission.external_directory_write | has("~/.agents/skills/*") | not)
    and .permission.external_directory_read["/mnt/c/dev/flygd-wingman-*"] == "allow"
    and .permission.external_directory_write["/mnt/c/dev/flygd-wingman-*"] == "allow"
  ' "$PERMISSION_CONFIG"
  [ "$status" -eq 0 ]
}

@test "Pi permission Bash policy allows local Git while guarding risky operations" {
  run jq -e '
    .permission.bash as $bash
    | ($bash | keys_unsorted) as $keys
    | $bash["*"] == "allow"
    and ($bash | has("git *") | not)
    and ($bash | has("*/git *") | not)
    and $bash["git branch *"] == "allow"
    and ($bash | has("*/git branch *") | not)
    and $bash["git worktree *"] == "allow"
    and ($bash | has("*/git worktree *") | not)
    and $bash["git commit *"] == "allow"
    and ($bash | has("git -C * worktree *") | not)
    and $bash["git fetch*"] == "allow"
    and $bash["*/git fetch*"] == "ask"
    and $bash["git pull*"] == "ask"
    and $bash["git pull --ff-only*"] == "allow"
    and $bash["*/git pull*"] == "ask"
    and ($bash | has("git -C * pull --ff-only *") | not)
    and $bash["git push*"] == "allow"
    and $bash["*git *push *--delete*"] == "ask"
    and $bash["*git *push *--all*"] == "ask"
    and $bash["git clone*"] == "ask"
    and $bash["*git *branch * -D*"] == "ask"
    and $bash["*git *worktree remove * -f*"] == "ask"
    and $bash["*git *commit * --am*"] == "ask"
    and ($bash | has("gh *") | not)
    and ($bash | has("*/gh *") | not)
    and $bash["curl *"] == "allow"
    and $bash["*/curl *"] == "allow"
    and $bash["curl *http://127.0.0.1:*"] == "allow"
    and $bash["curl *http://localhost:*"] == "allow"
    and $bash.sh == "ask"
    and $bash["sh -s*"] == "ask"
    and $bash["sh -"] == "ask"
    and $bash.bash == "ask"
    and $bash["bash -s*"] == "ask"
    and $bash["bash -"] == "ask"
    and $bash.zsh == "ask"
    and $bash["zsh -s*"] == "ask"
    and $bash["zsh -"] == "ask"
    and $bash.dash == "ask"
    and $bash["dash -s*"] == "ask"
    and $bash["dash -"] == "ask"
    and $bash.ksh == "ask"
    and $bash["ksh -s*"] == "ask"
    and $bash["ksh -"] == "ask"
    and (
      [
        "*curl *--data *",
        "*curl *--data=*",
        "*curl *--data-raw *",
        "*curl *--data-binary *",
        "*curl *--data-urlencode *",
        "*curl *-d *",
        "*curl *--form *",
        "*curl *-F *",
        "*curl *--upload-file *",
        "*curl *-T *",
        "*curl *--request POST*",
        "*curl *--request PUT*",
        "*curl *--request PATCH*",
        "*curl *--request DELETE*",
        "*curl *--request post*",
        "*curl *--request put*",
        "*curl *--request patch*",
        "*curl *--request delete*",
        "*curl *-X POST*",
        "*curl *-X PUT*",
        "*curl *-X PATCH*",
        "*curl *-X DELETE*",
        "*curl *-X post*",
        "*curl *-X put*",
        "*curl *-X patch*",
        "*curl *-X delete*",
        "*curl *Authorization:*",
        "*curl *--user *",
        "*curl *-u *",
        "*curl *--cookie *",
        "*curl *-b *",
        "*curl *--cert *",
        "*curl *-E *",
        "*curl *--key *",
        "*curl *--netrc*"
      ]
      | all(.[];
          . as $pattern
          | $bash[$pattern] == "ask"
          and (($keys | index($pattern)) > ($keys | index("curl *")))
          and (($keys | index($pattern)) > ($keys | index("*/curl *")))
        )
    )
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
    and $bash["git status *"] == "allow"
    and $bash["*git *config *"] == "ask"
    and $bash["*git *config --get*"] == "allow"
    and $bash["*git *config --get-regexp*"] == "allow"
    and $bash["*git *config --list*"] == "allow"
    and $bash["*git *config -l*"] == "allow"
    and (($keys | index("*git *config --get*")) > ($keys | index("*git *config *")))
    and (($keys | index("*git *config --get-regexp*")) > ($keys | index("*git *config *")))
    and (($keys | index("*git *config --list*")) > ($keys | index("*git *config *")))
    and (($keys | index("*git *config -l*")) > ($keys | index("*git *config *")))
    and $bash["*git *credential *"] == "ask"
    and $bash["*git *send-pack *"] == "ask"
    and $bash["*gh *auth token*"] == "ask"
    and $bash["git show *--ext-d*"] == "ask"
    and $bash["git show *--textc*"] == "ask"
    and $bash["git diff *--ext-d*"] == "ask"
    and $bash["git diff *--textc*"] == "ask"
    and $bash["git log *--ext-d*"] == "ask"
    and $bash["git log *--textc*"] == "ask"
    and $bash["*rg *--pre*"] == "deny"
    and $bash["*fd *--exec*"] == "deny"
    and $bash["*fd *-x*"] == "deny"
    and $bash["*fd *-X*"] == "deny"
    and $bash["yq -i*"] == "ask"
    and $bash["yq --inplace*"] == "ask"
    and ($bash | has("*$*") | not)
    and $bash["*cat *$*"] == "ask"
    and $bash["*rg *$*"] == "ask"
    and ($bash | has("*git * -c *=*") | not)
    and $bash["*git -C * -c *=*"] == "deny"
    and $bash["*git *config *alias.* *!*"] == "deny"
    and $bash["*git *config *core.sshCommand ?*"] == "deny"
    and (($keys | index("*git *config *alias.* *!*")) > ($keys | index("*git *config --get*")))
    and (($keys | index("*git *config *core.sshCommand ?*")) > ($keys | index("*git *config --get*")))
    and $bash["*git *send-pack *--for*"] == "deny"
    and $bash["*git *send-pack * +*"] == "deny"
    and (($keys | index("*git *send-pack *--for*")) > ($keys | index("*git *send-pack *")))
    and (($keys | index("*git *send-pack * +*")) > ($keys | index("*git *send-pack *")))
    and $bash["*git *push *--for*"] == "deny"
    and $bash["*git *push -f*"] == "deny"
    and $bash["*git *push -qf*"] == "deny"
    and $bash["*git *push * +*"] == "deny"
    and $bash["*git *push *--mir*"] == "deny"
    and $bash["*git *reset *--har*"] == "deny"
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
    map(del(.permission.bash))
    | [paths(objects) as $path
      | (getpath($path) | keys[]) as $key
      | select($key | test("(api[_-]?key|token|secret|password|credential)"; "i"))]
    | length == 0
  ' "$PERMISSION_CONFIG" "$SUBAGENT_CONFIG" "$WEB_CONFIG"
  [ "$status" -eq 0 ]
}

@test "Pi permission config validator accepts valid config and rejects invalid config" {
  local schema="$TEST_ROOT/schema.json" valid="$TEST_ROOT/valid.json" invalid="$TEST_ROOT/invalid.json"
  printf '%s\n' '{"$schema":"https://json-schema.org/draft/2020-12/schema","type":"object","required":["permission"],"properties":{"permission":{"type":"object"}}}' >"$schema"
  printf '%s\n' '{"permission":{}}' >"$valid"
  printf '%s\n' '[]' >"$invalid"

  run "$REPO_ROOT/bin/validate-pi-permission-config" --schema "$schema" --config "$valid"
  [ "$status" -eq 0 ]

  run "$REPO_ROOT/bin/validate-pi-permission-config" --schema "$schema" --config "$invalid"
  [ "$status" -ne 0 ]
  [[ "$output" == *"permission schema"* ]]
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
