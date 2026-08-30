#!/usr/bin/env bats

load test_helper

setup() {
  setup_dotfiles_test
  PI_GUIDANCE="$REPO_ROOT/ai/pi/AGENTS.md"
  BLINDSPOT_SKILL="$REPO_ROOT/ai/marketplace/plugins/my/skills/blindspot-pass/SKILL.md"
  POLISH_SKILL="$REPO_ROOT/ai/marketplace/plugins/my/skills/polish-core/SKILL.md"
  EXPLAINER_SKILL="$REPO_ROOT/ai/marketplace/plugins/my/skills/change-explainer/SKILL.md"
}

@test "Pi configuration ships the linked-worktree edit guard" {
  [ -f "$REPO_ROOT/ai/pi/extensions/worktree-guard.ts" ]
  run grep -F '"$ROOT/ai/pi/extensions" "$HOME/.pi/agent/extensions"' "$REPO_ROOT/ai/pi/install.sh"
  [ "$status" -eq 0 ]
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
