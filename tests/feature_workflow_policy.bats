#!/usr/bin/env bats

load test_helper

setup() {
  setup_dotfiles_test
  PI_GUIDANCE="$REPO_ROOT/ai/pi/AGENTS.md"
  BLINDSPOT_SKILL="$REPO_ROOT/ai/marketplace/plugins/my/skills/blindspot-pass/SKILL.md"
  POLISH_SKILL="$REPO_ROOT/ai/marketplace/plugins/my/skills/polish-core/SKILL.md"
  EXPLAINER_SKILL="$REPO_ROOT/ai/marketplace/plugins/my/skills/change-explainer/SKILL.md"
}

@test "Pi configuration publishes individual guarded extension links" {
  [ -f "$REPO_ROOT/ai/pi/extensions/worktree-guard.ts" ]
  [ -f "$REPO_ROOT/ai/pi/extensions/herdr-agent-state.ts" ]
  run rg -n 'managed_extensions=.*herdr-agent-state\.ts.*worktree-guard\.ts|managed_extensions=\(' \
    "$REPO_ROOT/ai/pi/install.sh"
  [ "$status" -eq 0 ]
  run grep -F 'reconcile_authored_extensions "$PI_AGENT_DIR/extensions"' \
    "$REPO_ROOT/ai/pi/install.sh"
  [ "$status" -eq 0 ]
  run grep -F '"$ROOT/ai/pi/extensions" "$HOME/.pi/agent/extensions"' \
    "$REPO_ROOT/ai/pi/install.sh"
  [ "$status" -eq 1 ]
}

@test "personal skills advertise their automatic workflow phases" {
  run grep -F "Use proactively during discovery for non-trivial work" "$BLINDSPOT_SKILL"
  [ "$status" -eq 0 ]

  run grep -F "Run proactively with --fix after non-trivial implementation" "$POLISH_SKILL"
  [ "$status" -eq 0 ]

  run grep -F "Use proactively after polish and fresh verification" "$EXPLAINER_SKILL"
  [ "$status" -eq 0 ]
}

@test "blindspot workflow pauses only for material unresolved decisions" {
  run grep -F "Automatic workflow mode" "$BLINDSPOT_SKILL"
  [ "$status" -eq 0 ]
  run grep -F "findings and continue into design for routine work. Pause only when an" "$BLINDSPOT_SKILL"
  [ "$status" -eq 0 ]
}

@test "change explainer limits knowledge checks to substantial changes" {
  run grep -F "For substantial changes, include exactly five questions" "$EXPLAINER_SKILL"
  [ "$status" -eq 0 ]
  run grep -F "about the change, without answers. For routine non-trivial changes, omit the" "$EXPLAINER_SKILL"
  [ "$status" -eq 0 ]
}

@test "overnight runtime state is globally ignored" {
  run grep -Fx '.pi/overnight-run-state.md' "$REPO_ROOT/core/git/gitignore.symlink"
  [ "$status" -eq 0 ]
}

@test "active AI guidance no longer invokes the Amp permissions command" {
  run rg -n '/permissions(`|[[:space:]])' "$REPO_ROOT/ai" \
    --glob '!**/plugin-security-stack-design.md'
  [ "$status" -eq 1 ]
}

@test "root guidance documents the new Pi configuration ownership" {
  local guidance="$REPO_ROOT/AGENTS.md"
  run grep -F 'ai/pi/config/modes.json' "$guidance"
  [ "$status" -eq 0 ]
  run grep -F 'ai/pi/config/permission-system.json' "$guidance"
  [ "$status" -eq 0 ]
  run grep -F 'regular machine-local files' "$guidance"
  [ "$status" -eq 0 ]
  run grep -F 'ai/pi/permissions.json' "$guidance"
  [ "$status" -eq 1 ]
}

@test "overnight workflow requires permission and sandbox preflight and restoration" {
  local skill="$REPO_ROOT/ai/marketplace/plugins/my/skills/overnight-improve/SKILL.md"
  local preflight="$REPO_ROOT/ai/marketplace/plugins/my/skills/overnight-improve/references/preflight-checklist.md"
  run rg -n '/permission-system|YOLO' "$skill" "$preflight"
  [ "$status" -eq 0 ]
  run grep -F '/sandbox' "$preflight"
  [ "$status" -eq 0 ]
  run grep -F 'representative' "$preflight"
  [ "$status" -eq 0 ]
  run grep -F 'linked worktree' "$preflight"
  [ "$status" -eq 0 ]
  run rg -n 'blocked|prompt timeout|permission deny' "$skill" "$preflight"
  [ "$status" -eq 0 ]
  run rg -n 'disable.*YOLO|YOLO.*off' "$skill" "$preflight"
  [ "$status" -eq 0 ]
}

@test "Pi README documents packages mutable ownership and containment boundaries" {
  local readme="$REPO_ROOT/ai/README.md"
  local package
  for package in \
    pi-queue-steer \
    pi-web-access \
    code-actions \
    @narumitw/pi-lsp \
    @gotgenes/pi-subagents \
    @gotgenes/pi-permission-system \
    pi-sandbox; do
    run grep -F "$package" "$readme"
    [ "$status" -eq 0 ]
  done
  run grep -F 'six mutable runtime files' "$readme"
  [ "$status" -eq 0 ]
  run grep -F 'merges only `.packages`' "$readme"
  [ "$status" -eq 0 ]
  run grep -F 'PI_AI_RESET_MUTABLE_CONFIG=1' "$readme"
  [ "$status" -eq 0 ]
  run grep -F 'parent-only' "$readme"
  [ "$status" -eq 0 ]
  run grep -F 'children inherit permission-system and worktree-guard' "$readme"
  [ "$status" -eq 0 ]
}

@test "Pi README documents internal bypasses rollout cleanup validation and rollback" {
  local readme="$REPO_ROOT/ai/README.md"
  run grep -F '/code run' "$readme"
  [ "$status" -eq 0 ]
  run grep -F 'pi.exec()' "$readme"
  [ "$status" -eq 0 ]
  run grep -F 'LSP server subprocesses' "$readme"
  [ "$status" -eq 0 ]
  run grep -F 'pi-web-access network calls' "$readme"
  [ "$status" -eq 0 ]
  run grep -F 'Amp' "$readme"
  [ "$status" -eq 0 ]
  run grep -F 'Brave' "$readme"
  [ "$status" -eq 0 ]
  run grep -F 'bin/validate-pi-security-runtime' "$readme"
  [ "$status" -eq 0 ]
  run grep -F 'isolated pre-integration smoke' "$readme"
  [ "$status" -eq 0 ]
  run grep -F 'canonical checkout' "$readme"
  [ "$status" -eq 0 ]
  run grep -F 'permissions.mode: enabled' "$readme"
  [ "$status" -eq 0 ]
  run grep -F 'must be restored together' "$readme"
  [ "$status" -eq 0 ]
}

@test "Pi global guidance defines the automatic worktree workflow" {
  run grep -F "create or reuse a linked worktree before the first repository write" "$PI_GUIDANCE"
  [ "$status" -eq 0 ]
  run grep -F "load \`blindspot-pass\` before implementation" "$PI_GUIDANCE"
  [ "$status" -eq 0 ]
  run grep -F "run \`polish-core --fix\` after implementation" "$PI_GUIDANCE"
  [ "$status" -eq 0 ]
  run grep -F "use \`change-explainer\`" "$PI_GUIDANCE"
  [ "$status" -eq 0 ]
}
