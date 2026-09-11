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

@test "Pi permission policy uses permissive defaults with safety tripwires" {
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

@test "Pi permission Bash policy allows Git while retaining hard denies" {
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
    and ($bash | has("*/git commit *") | not)
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
    and $bash["git clone*"] == "allow"
    and $bash["*/git clone*"] == "allow"
    and $bash["*git *branch * -D*"] == "ask"
    and $bash["*git *worktree remove * -f*"] == "ask"
    and $bash["*git *commit * --am*"] == "ask"
    and ($bash | has("*git *restore *") | not)
    and (
      [
        "git restore *",
        "*/git restore *",
        "git -C * restore *",
        "*/git -C * restore *",
        "git --no-pager restore *",
        "*/git --no-pager restore *",
        "git --git-dir=* restore *",
        "*/git --git-dir=* restore *",
        "git --git-dir * restore *",
        "*/git --git-dir * restore *",
        "git --work-tree=* restore *",
        "*/git --work-tree=* restore *",
        "git --work-tree * restore *",
        "*/git --work-tree * restore *"
      ]
      | all(.[]; . as $pattern | $bash[$pattern] == "ask")
    )
    and (
      [
        "git -C * commit *",
        "*/git -C * commit *",
        "git --git-dir=* commit *",
        "*/git --git-dir=* commit *",
        "git --git-dir * commit *",
        "*/git --git-dir * commit *",
        "git --work-tree=* commit *",
        "*/git --work-tree=* commit *",
        "git --work-tree * commit *",
        "*/git --work-tree * commit *"
      ]
      | all(.[]; . as $pattern | $bash[$pattern] == "allow")
    )
    and (
      [
        "git -C * commit --am*",
        "git -C * commit * --am*",
        "*/git -C * commit --am*",
        "*/git -C * commit * --am*",
        "git --git-dir=* commit --am*",
        "git --git-dir=* commit * --am*",
        "*/git --git-dir=* commit --am*",
        "*/git --git-dir=* commit * --am*",
        "git --git-dir * commit --am*",
        "git --git-dir * commit * --am*",
        "*/git --git-dir * commit --am*",
        "*/git --git-dir * commit * --am*",
        "git --work-tree=* commit --am*",
        "git --work-tree=* commit * --am*",
        "*/git --work-tree=* commit --am*",
        "*/git --work-tree=* commit * --am*",
        "git --work-tree * commit --am*",
        "git --work-tree * commit * --am*",
        "*/git --work-tree * commit --am*",
        "*/git --work-tree * commit * --am*"
      ]
      | all(.[]; . as $pattern | $bash[$pattern] == "ask")
    )
    and ($bash | has("gh *") | not)
    and ($bash | has("*/gh *") | not)
    and $bash["gh api *"] == "allow"
    and $bash["*/gh api *"] == "allow"
    and $bash["*gh *api *-X*"] == "ask"
    and $bash["*gh *api *--method*"] == "ask"
    and $bash["*gh *api *-f*"] == "ask"
    and $bash["*gh *api *--raw-field*"] == "ask"
    and $bash["*gh *api *-F*"] == "ask"
    and $bash["*gh *api *--field*"] == "ask"
    and $bash["*gh *api *--input*"] == "ask"
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
        "*curl *--request=POST*",
        "*curl *--request=PUT*",
        "*curl *--request=PATCH*",
        "*curl *--request=DELETE*",
        "*curl *--request=post*",
        "*curl *--request=put*",
        "*curl *--request=patch*",
        "*curl *--request=delete*",
        "*curl *-X POST*",
        "*curl *-X PUT*",
        "*curl *-X PATCH*",
        "*curl *-X DELETE*",
        "*curl *-X post*",
        "*curl *-X put*",
        "*curl *-X patch*",
        "*curl *-X delete*",
        "*curl *Authorization:*",
        "*curl *authorization:*",
        "*curl *--user *",
        "*curl *-u *",
        "*curl *--cookie *",
        "*curl *-b *",
        "*curl *--cert *",
        "*curl *-E *",
        "*curl *--key *",
        "*curl *--netrc*",
        "*curl *ftp://*",
        "*curl *ftps://*"
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
    and $bash["command -v *"] == "allow"
    and $bash.env == "ask"
    and $bash.printenv == "ask"
    and $bash.export == "ask"
    and $bash["declare *-x*"] == "ask"
    and $bash["git status *"] == "allow"
    and ($bash | has("*git *config *") | not)
    and ($bash | has("*git *credential *") | not)
    and (
      [
        "git config ",
        "*/git config ",
        "git -C * config ",
        "*/git -C * config ",
        "git --no-pager config ",
        "*/git --no-pager config ",
        "git --git-dir=* config ",
        "*/git --git-dir=* config ",
        "git --git-dir * config ",
        "*/git --git-dir * config ",
        "git --work-tree=* config ",
        "*/git --work-tree=* config ",
        "git --work-tree * config ",
        "*/git --work-tree * config "
      ]
      | all(.[];
          . as $prefix
          | $bash["\($prefix)*"] == "deny"
          and $bash["\($prefix)--get*"] == "allow"
          and $bash["\($prefix)--get-regexp*"] == "allow"
          and $bash["\($prefix)--list*"] == "allow"
          and $bash["\($prefix)-l*"] == "allow"
          and $bash["\($prefix)--global --get*"] == "allow"
          and $bash["\($prefix)--local --list*"] == "allow"
          and $bash["\($prefix)--show-origin --get-all*"] == "allow"
          and (($keys | index("\($prefix)--get*")) > ($keys | index("\($prefix)*")))
          and (($keys | index("\($prefix)--global --get*")) > ($keys | index("\($prefix)*")))
        )
    )
    and $bash["git config --global --get*"] == "allow"
    and $bash["git config --local --list*"] == "allow"
    and $bash["git config --show-origin --get-all*"] == "allow"
    and (($keys | index("git config --global --get*")) > ($keys | index("git config *")))
    and (
      [
        "git credential *",
        "*/git credential *",
        "git -C * credential *",
        "*/git -C * credential *",
        "git --no-pager credential *",
        "*/git --no-pager credential *",
        "git --git-dir=* credential *",
        "*/git --git-dir=* credential *",
        "git --git-dir * credential *",
        "*/git --git-dir * credential *",
        "git --work-tree=* credential *",
        "*/git --work-tree=* credential *",
        "git --work-tree * credential *",
        "*/git --work-tree * credential *"
      ]
      | all(.[]; . as $pattern | $bash[$pattern] == "ask")
    )
    and (
      [
        "git checkout *",
        "*/git checkout *",
        "git -C * checkout *",
        "*/git -C * checkout *",
        "git filter-branch *",
        "*/git filter-branch *",
        "git -C * filter-branch *",
        "*/git -C * filter-branch *",
        "git filter-repo *",
        "*/git filter-repo *",
        "git -C * filter-repo *",
        "*/git -C * filter-repo *",
        "git daemon *",
        "*/git daemon *",
        "git -C * daemon *",
        "*/git -C * daemon *",
        "git fast-import *",
        "*/git fast-import *",
        "git -C * fast-import *",
        "*/git -C * fast-import *",
        "git svn *",
        "*/git svn *",
        "git -C * svn *",
        "*/git -C * svn *",
        "git p4 *",
        "*/git p4 *",
        "git -C * p4 *",
        "*/git -C * p4 *",
        "git gc *--prune*",
        "*/git gc *--prune*",
        "git -C * gc *--prune*",
        "*/git -C * gc *--prune*",
        "git prune *",
        "*/git prune *",
        "git -C * prune *",
        "*/git -C * prune *",
        "git replace *",
        "*/git replace *",
        "git -C * replace *",
        "*/git -C * replace *",
        "git submodule add *",
        "*/git submodule add *",
        "git -C * submodule add *",
        "*/git -C * submodule add *"
      ]
      | all(.[]; . as $pattern | $bash[$pattern] == "ask")
    )
    and $bash["*git *send-pack *"] == "ask"
    and $bash["*gh *auth token*"] == "ask"
    and (
      [
        "gh secret *",
        "*/gh secret *",
        "gh release create*",
        "*/gh release create*",
        "gh release upload*",
        "*/gh release upload*",
        "gh release delete*",
        "*/gh release delete*",
        "gh release edit*",
        "*/gh release edit*",
        "gh pr checkout*",
        "*/gh pr checkout*",
        "gh pr close*",
        "*/gh pr close*",
        "gh pr comment*",
        "*/gh pr comment*",
        "gh pr ready*",
        "*/gh pr ready*",
        "gh pr reopen*",
        "*/gh pr reopen*",
        "gh pr review*",
        "*/gh pr review*",
        "gh pr update-branch*",
        "*/gh pr update-branch*",
        "gh issue comment*",
        "*/gh issue comment*",
        "gh issue delete*",
        "*/gh issue delete*",
        "gh issue develop*",
        "*/gh issue develop*",
        "gh issue lock*",
        "*/gh issue lock*",
        "gh issue pin*",
        "*/gh issue pin*",
        "gh issue reopen*",
        "*/gh issue reopen*",
        "gh issue transfer*",
        "*/gh issue transfer*",
        "gh issue unlock*",
        "*/gh issue unlock*",
        "gh issue unpin*",
        "*/gh issue unpin*",
        "gh workflow run*",
        "*/gh workflow run*",
        "gh workflow disable*",
        "*/gh workflow disable*",
        "gh workflow enable*",
        "*/gh workflow enable*",
        "gh repo create*",
        "*/gh repo create*",
        "gh repo fork*",
        "*/gh repo fork*",
        "gh repo edit*",
        "*/gh repo edit*",
        "gh repo archive*",
        "*/gh repo archive*",
        "gh repo autolink create*",
        "*/gh repo autolink create*",
        "gh repo autolink delete*",
        "*/gh repo autolink delete*",
        "gh repo clone*",
        "*/gh repo clone*",
        "gh repo deploy-key add*",
        "*/gh repo deploy-key add*",
        "gh repo deploy-key delete*",
        "*/gh repo deploy-key delete*",
        "gh repo rename*",
        "*/gh repo rename*",
        "gh repo set-default*",
        "*/gh repo set-default*",
        "gh repo sync*",
        "*/gh repo sync*",
        "gh repo unarchive*",
        "*/gh repo unarchive*",
        "gh gist clone*",
        "*/gh gist clone*",
        "gh gist create*",
        "*/gh gist create*",
        "gh gist edit*",
        "*/gh gist edit*",
        "gh gist delete*",
        "*/gh gist delete*",
        "gh gist rename*",
        "*/gh gist rename*",
        "gh extension exec*",
        "*/gh extension exec*",
        "gh extension install*",
        "*/gh extension install*",
        "gh extension remove*",
        "*/gh extension remove*",
        "gh extension upgrade*",
        "*/gh extension upgrade*",
        "gh alias set*",
        "*/gh alias set*",
        "gh alias delete*",
        "*/gh alias delete*",
        "gh alias import*",
        "*/gh alias import*",
        "gh ssh-key add*",
        "*/gh ssh-key add*",
        "gh ssh-key delete*",
        "*/gh ssh-key delete*",
        "gh gpg-key add*",
        "*/gh gpg-key add*",
        "gh gpg-key delete*",
        "*/gh gpg-key delete*",
        "gh variable set*",
        "*/gh variable set*",
        "gh variable delete*",
        "*/gh variable delete*",
        "gh codespace code*",
        "*/gh codespace code*",
        "gh codespace create*",
        "*/gh codespace create*",
        "gh codespace delete*",
        "*/gh codespace delete*",
        "gh codespace edit*",
        "*/gh codespace edit*",
        "gh codespace rebuild*",
        "*/gh codespace rebuild*",
        "gh codespace jupyter*",
        "*/gh codespace jupyter*",
        "gh codespace stop*",
        "*/gh codespace stop*",
        "gh codespace ssh*",
        "*/gh codespace ssh*",
        "gh codespace cp*",
        "*/gh codespace cp*",
        "gh codespace ports visibility*",
        "*/gh codespace ports visibility*",
        "gh run cancel*",
        "*/gh run cancel*",
        "gh run delete*",
        "*/gh run delete*",
        "gh run rerun*",
        "*/gh run rerun*",
        "gh label clone*",
        "*/gh label clone*",
        "gh label create*",
        "*/gh label create*",
        "gh label delete*",
        "*/gh label delete*",
        "gh label edit*",
        "*/gh label edit*",
        "gh project close*",
        "*/gh project close*",
        "gh project copy*",
        "*/gh project copy*",
        "gh project create*",
        "*/gh project create*",
        "gh project delete*",
        "*/gh project delete*",
        "gh project edit*",
        "*/gh project edit*",
        "gh project field-create*",
        "*/gh project field-create*",
        "gh project field-delete*",
        "*/gh project field-delete*",
        "gh project item-add*",
        "*/gh project item-add*",
        "gh project item-archive*",
        "*/gh project item-archive*",
        "gh project item-create*",
        "*/gh project item-create*",
        "gh project item-delete*",
        "*/gh project item-delete*",
        "gh project item-edit*",
        "*/gh project item-edit*",
        "gh project link*",
        "*/gh project link*",
        "gh project mark-template*",
        "*/gh project mark-template*",
        "gh project reopen*",
        "*/gh project reopen*",
        "gh project unlink*",
        "*/gh project unlink*",
        "gh auth login*",
        "*/gh auth login*",
        "gh auth refresh*",
        "*/gh auth refresh*",
        "gh auth logout*",
        "*/gh auth logout*",
        "gh auth setup-git*",
        "*/gh auth setup-git*",
        "gh auth switch*",
        "*/gh auth switch*",
        "gh config set*",
        "*/gh config set*",
        "gh config clear-cache*",
        "*/gh config clear-cache*",
        "gh cache delete*",
        "*/gh cache delete*"
      ]
      | all(.[]; . as $pattern | $bash[$pattern] == "ask")
    )
    and $bash["*git *show *--ext-d*"] == "deny"
    and $bash["*git *show *--textc*"] == "deny"
    and $bash["*git *diff *--ext-d*"] == "deny"
    and $bash["*git *diff *--textc*"] == "deny"
    and $bash["*git *log *--ext-d*"] == "deny"
    and $bash["*git *log *--textc*"] == "deny"
    and $bash["*git *grep -O*"] == "deny"
    and $bash["*git *grep -nO*"] == "deny"
    and $bash["*git *grep -inO*"] == "deny"
    and $bash["*git *grep -nHO*"] == "deny"
    and $bash["*git *grep * -O*"] == "deny"
    and $bash["*git *grep * -nO*"] == "deny"
    and $bash["*git *grep * -inO*"] == "deny"
    and $bash["*git *grep * -nHO*"] == "deny"
    and $bash["*git *grep --open*"] == "deny"
    and $bash["*git *grep * --open*"] == "deny"
    and $bash["*git *grep --op=*"] == "deny"
    and $bash["*git *grep * --op=*"] == "deny"
    and ($bash | has("*git *grep -*O*") | not)
    and ($bash | has("*git *grep * -*O*") | not)
    and ($bash | has("*git *grep *--op*") | not)
    and $bash["*rg *--pre*"] == "deny"
    and $bash["*fd *--exec*"] == "deny"
    and $bash["*fd *-x*"] == "deny"
    and $bash["*fd *-X*"] == "deny"
    and $bash["yq -i*"] == "ask"
    and $bash["yq --inplace*"] == "ask"
    and ($bash | has("*$*") | not)
    and ($bash | has("*git * -c *=*") | not)
    and $bash["*git -c *"] == "deny"
    and $bash["*git -C * -c *=*"] == "deny"
    and $bash["*git --no-pager -c *=*"] == "deny"
    and $bash["*git --git-dir=* -c *=*"] == "deny"
    and $bash["*git --git-dir * -c *=*"] == "deny"
    and $bash["*git --work-tree=* -c *=*"] == "deny"
    and $bash["*git --work-tree * -c *=*"] == "deny"
    and $bash["*git --config-env=*"] == "deny"
    and $bash["*git * --config-env=*"] == "deny"
    and $bash["*git *alias.*=!*"] == "deny"
    and $bash["*git *clean.requireForce=false*"] == "deny"
    and $bash["*git *config *alias.* *!*"] == "deny"
    and $bash["*git *config *core.sshCommand ?*"] == "deny"
    and (($keys | index("*git *config *alias.* *!*")) > ($keys | index("git config --get*")))
    and (($keys | index("*git *config *alias.* *!*")) > ($keys | index("*/git config --get*")))
    and (($keys | index("*git *config *core.sshCommand ?*")) > ($keys | index("git config --get*")))
    and (($keys | index("*git *config *core.sshCommand ?*")) > ($keys | index("*/git config --get*")))
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
    and $bash["*git *bisect *run*"] == "deny"
    and $bash["*git *rebase -x*"] == "deny"
    and $bash["*git *rebase * -x*"] == "deny"
    and ($bash | has("*git *rebase *-x*") | not)
    and $bash["*git *archive *--rem*"] == "deny"
    and $bash["*gh *repo delete*"] == "deny"
    and $bash["*gh *api *DELETE*"] == "deny"
    and (($keys | index("*gh *api *DELETE*")) > ($keys | index("gh codespace ssh*")))
    and (($keys | index("*gh *api *delete*")) > ($keys | index("*/gh codespace ssh*")))
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

  run "$REPO_ROOT/libexec/validate-pi-permission-config" --schema "$schema" --config "$valid"
  [ "$status" -eq 0 ]

  run "$REPO_ROOT/libexec/validate-pi-permission-config" --schema "$schema" --config "$invalid"
  [ "$status" -ne 0 ]
  [[ "$output" == *"permission schema"* ]]
}

@test "Pi permission config validator reports schema path for missing and malformed schema" {
  local schema="$TEST_ROOT/missing-schema.json" malformed="$TEST_ROOT/malformed-schema.json" config="$TEST_ROOT/config.json"
  printf '%s\n' '{"permission":{}}' >"$config"

  run "$REPO_ROOT/libexec/validate-pi-permission-config" --schema "$schema" --config "$config"
  [ "$status" -ne 0 ]
  [[ "$output" == "error: permission schema $schema:"* ]]
  [[ "$output" != *"Traceback"* ]]

  printf '%s\n' '{' >"$malformed"
  run "$REPO_ROOT/libexec/validate-pi-permission-config" --schema "$malformed" --config "$config"
  [ "$status" -ne 0 ]
  [[ "$output" == "error: permission schema $malformed:"* ]]
  [[ "$output" != *"Traceback"* ]]
}

@test "Pi permission config validator reports config path for missing and malformed config" {
  local schema="$TEST_ROOT/schema.json" missing="$TEST_ROOT/missing-config.json" malformed="$TEST_ROOT/malformed-config.json"
  printf '%s\n' '{"$schema":"https://json-schema.org/draft/2020-12/schema","type":"object","required":["permission"],"properties":{"permission":{"type":"object"}}}' >"$schema"

  run "$REPO_ROOT/libexec/validate-pi-permission-config" --schema "$schema" --config "$missing"
  [ "$status" -ne 0 ]
  [[ "$output" == "error: permission schema $missing:"* ]]
  [[ "$output" != *"Traceback"* ]]

  printf '%s\n' '{' >"$malformed"
  run "$REPO_ROOT/libexec/validate-pi-permission-config" --schema "$schema" --config "$malformed"
  [ "$status" -ne 0 ]
  [[ "$output" == "error: permission schema $malformed:"* ]]
  [[ "$output" != *"Traceback"* ]]
}

@test "Pi permission config validator reports invalid UTF-8 without a traceback" {
  local schema="$TEST_ROOT/schema.json" config="$TEST_ROOT/config.json"
  printf '%s\n' '{"$schema":"https://json-schema.org/draft/2020-12/schema","type":"object"}' >"$schema"
  printf '\xff' >"$config"

  run "$REPO_ROOT/libexec/validate-pi-permission-config" --schema "$schema" --config "$config"
  [ "$status" -ne 0 ]
  [[ "$output" == "error: permission schema $config:"* ]]
  [[ "$output" != *"Traceback"* ]]

  printf '\xff' >"$schema"
  printf '{}\n' >"$config"
  run "$REPO_ROOT/libexec/validate-pi-permission-config" --schema "$schema" --config "$config"
  [ "$status" -ne 0 ]
  [[ "$output" == "error: permission schema $schema:"* ]]
  [[ "$output" != *"Traceback"* ]]
}

@test "Pi runtime validator fails clearly when permission package is absent" {
  run "$REPO_ROOT/libexec/validate-pi-security-runtime" \
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

  run "$REPO_ROOT/libexec/validate-pi-security-runtime" \
    --package-root "$package_root" \
    --pi-package-root "$pi_root"

  [ "$status" -ne 0 ]
  [[ "$output" == *"Pi bundled jiti not installed"* ]]
}
