#!/usr/bin/env bash
# Cross-family review for Codex lanes: one read-only Claude Code run.
# Usage: claude-review.sh <prompt-file> <out-prefix>
# Writes <out-prefix>.md, .stderr and .exit, prints the exit code and exits with it.
# The prompt goes in on stdin: --disallowedTools is variadic and would swallow it.
# Optional: CLAUDE_REVIEW_MODEL selects the model; unset uses claude's default.
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: claude-review.sh <prompt-file> <out-prefix>" >&2
  exit 2
fi
prompt=$1 out=$2
if [[ ! -f "$prompt" || ! -r "$prompt" ]]; then
  echo "claude-review.sh: prompt file not readable: $prompt" >&2
  exit 2
fi
for suffix in md stderr exit; do
  if [[ "$prompt" -ef "$out.$suffix" ]]; then
    echo "claude-review.sh: output $out.$suffix would overwrite the prompt" >&2
    exit 2
  fi
done
if [[ ! -d "$(dirname -- "$out")" ]]; then
  echo "claude-review.sh: output directory missing: $(dirname -- "$out")" >&2
  exit 2
fi
if ! command -v claude >/dev/null; then
  echo "claude-review.sh: claude not found on PATH" >&2
  exit 127
fi
model_args=()
status=0
if [[ -n "${CLAUDE_REVIEW_MODEL:-}" ]]; then
  model_args=(--model "$CLAUDE_REVIEW_MODEL")
fi

claude -p ${model_args[@]+"${model_args[@]}"} --disallowedTools Edit Write Bash NotebookEdit \
  <"$prompt" >"$out.md" 2>"$out.stderr" || status=$?
echo "$status" >"$out.exit"
echo "$status"
exit "$status"
