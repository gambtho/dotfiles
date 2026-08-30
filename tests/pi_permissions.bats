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
    'yq . config.yaml' \
    'git rev-parse HEAD' \
    'git worktree list --porcelain' \
    'gh pr view 4 --json title' \
    'realpath ai/pi/settings.json'; do
    run resolve_custom_action "$command"
    [ "$status" -eq 0 ]
    [ "$output" = allow ]
  done
}

@test "Pi permission settings do not auto-allow mutating or compound variants" {
  local command
  for command in \
    'rg --pre "rm -rf /tmp/x" pattern .' \
    'fd --exec rm {}' \
    'jq . package.json > output.json' \
    'yq -i . config.yaml' \
    'git push origin main' \
    'gh api --method DELETE repos/o/r' \
    'realpath path; rm -rf path'; do
    run resolve_custom_action "$command"
    [ "$status" -eq 0 ]
    [ "$output" = none ]
  done
}
