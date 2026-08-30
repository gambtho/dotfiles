#!/usr/bin/env bats

load test_helper

setup() {
  setup_dotfiles_test
  PERMISSIONS="$REPO_ROOT/ai/pi/permissions.json"
}

resolve_custom_action() {
  node - "$PERMISSIONS" "$1" <<'NODE'
import { readFileSync } from "node:fs";
const [path, command] = process.argv.slice(2);
const settings = JSON.parse(readFileSync(path, "utf8"));

function matches(pattern, value) {
  if (Array.isArray(pattern)) return pattern.some((item) => matches(item, value));
  const literal = pattern.match(/^\/(.+)\/([gimsuy]*)$/);
  if (literal) return new RegExp(literal[1], literal[2]).test(value);
  const escaped = pattern.replace(/[.+^${}()|[\]\\]/g, "\\$&").replace(/\*/g, ".*");
  return new RegExp(`^${escaped}$`).test(value);
}

for (const rule of settings["amp.permissions"] ?? []) {
  if (matches(rule.matches?.cmd ?? "*", command)) {
    console.log(rule.action);
    process.exit(0);
  }
}
console.log("none");
NODE
}

@test "Pi permission settings contain only Bash allow rules" {
  run jq -e '
    (. ["amp.commands.allowlist"]? == null)
    and all(. ["amp.permissions"][]; .tool == "Bash" and .action == "allow")
  ' "$PERMISSIONS"
  [ "$status" -eq 0 ]
}

@test "Pi permission settings allow common read-only inspection" {
  local command
  for command in \
    'rg -n TODO .' \
    'fd package.json .' \
    'jq . package.json' \
    "jq -r '.items[] | .name' package.json" \
    "jq '.value // \"default\"' package.json" \
    'yq . config.yaml' \
    'bats tests/pi_permissions.bats' \
    'make' \
    'make check' \
    'make -C web test' \
    'make PROFILE=test validate' \
    'bats --filter permissions tests' \
    'cat package.json | jq .' \
    'head -n 20 package.json | jq .' \
    'git status --porcelain=v2 | jq -R .' \
    'git show HEAD:package.json | jq .' \
    'gh pr view 4 --json files | jq ".files[]"' \
    'gh issue list --json number | jq ".[0].number"' \
    'git rev-parse HEAD' \
    'git merge-base main HEAD' \
    'git worktree list --porcelain' \
    'git remote -v' \
    'gh auth status' \
    'gh repo view --json name' \
    'gh pr list --state open' \
    'gh pr view 4 --json title' \
    'gh pr checks 4' \
    'gh issue list --state open' \
    'gh issue view 4' \
    'gh run list --limit 1' \
    'gh run view 123' \
    'realpath ai/pi/settings.json'; do
    run resolve_custom_action "$command"
    [ "$status" -eq 0 ]
    [ "$output" = allow ]
  done
}

@test "Pi permission settings do not auto-allow mutating or compound variants" {
  local command
  for command in \
    'rgx -n TODO .' \
    'fdx package.json .' \
    'jqx . package.json' \
    'yqx . config.yaml' \
    'rg --pre "rm -rf /tmp/x" pattern .' \
    'fd --exec rm {}' \
    'fd --exec-batch rm {}' \
    'fd -x echo {}' \
    'fd -xecho {}' \
    'fd -Xecho {}' \
    'jq . package.json > output.json' \
    'jq . package.json | sh' \
    'jq $(touch /tmp/x) package.json' \
    'make check; rm -rf /tmp/x' \
    'make check | sh' \
    'make $(touch /tmp/x)' \
    'yq -i . config.yaml' \
    'yq --inplace=. config.yaml' \
    'bats tests; rm -rf /tmp/x' \
    'bats $(touch /tmp/x)' \
    'cat package.json | jq . > output.json' \
    'cat package.json | jq . | sh' \
    'cat $(touch /tmp/x) | jq .' \
    'cat package.json | jqx .' \
    'gh api --method DELETE repos/o/r | jq .' \
    'gh pr view 4; touch /tmp/x | jq .' \
    'git status; touch /tmp/x | jq .' \
    'git rev-parse HEAD; rm -rf /tmp/x' \
    'git merge-base main HEAD && touch /tmp/x' \
    'git worktree list | sh' \
    'git remote -v$(rm -rf /tmp/x)' \
    'git push origin main' \
    'gh pr view 4; rm -rf /tmp/x' \
    'gh repo view $(touch /tmp/x)' \
    'gh run list | sh' \
    'gh api --method DELETE repos/o/r' \
    'realpath path; rm -rf path'; do
    run resolve_custom_action "$command"
    [ "$status" -eq 0 ]
    [ "$output" = none ]
  done
}
