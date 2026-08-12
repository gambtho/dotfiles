#!/usr/bin/env bats

load test_helper

setup() {
  setup_dotfiles_test
  CLAUDE_GUIDANCE="$REPO_ROOT/ai/claude/CLAUDE.md"
  CODEX_GUIDANCE="$REPO_ROOT/ai/codex/AGENTS.md"
  BLINDSPOT_SKILL="$REPO_ROOT/ai/marketplace/plugins/my/skills/blindspot-pass/SKILL.md"
  POLISH_SKILL="$REPO_ROOT/ai/marketplace/plugins/my/skills/polish-core/SKILL.md"
  EXPLAINER_SKILL="$REPO_ROOT/ai/marketplace/plugins/my/skills/change-explainer/SKILL.md"
  CLAUDE_SETTINGS="$REPO_ROOT/ai/claude/settings.json"
}

@test "Claude settings register the linked-worktree edit guard" {
  run jq -e '
    .hooks.PreToolUse[]
    | select(.matcher == "Edit|Write|NotebookEdit")
    | .hooks[]
    | select(
        .type == "command"
        and .command == "$HOME/.dotfiles/ai/claude/hooks/worktree-guard.sh"
      )
  ' "$CLAUDE_SETTINGS"
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

extract_workflow() {
  awk '
    found && /^## / { exit }
    /^## Automatic feature workflow$/ { found = 1 }
    found { print }
  ' "$1"
}

@test "Claude and Codex share the automatic feature workflow policy" {
  claude_workflow=$(extract_workflow "$CLAUDE_GUIDANCE")
  codex_workflow=$(extract_workflow "$CODEX_GUIDANCE")

  [ -n "$claude_workflow" ]
  [ "$claude_workflow" = "$codex_workflow" ]
  [[ "$claude_workflow" == *"linked worktree before the first feature-related write"* ]]
  [[ "$claude_workflow" == *"During discovery, before the design is locked in"* ]]
  [[ "$claude_workflow" == *"Pause only when unresolved high-impact decisions"* ]]
  [[ "$claude_workflow" == *'`my:polish-core --fix`'* ]]
  [[ "$claude_workflow" == *"re-run the affected verification"* ]]
  [[ "$claude_workflow" == *"knowledge-check questions only for substantial changes"* ]]
}
