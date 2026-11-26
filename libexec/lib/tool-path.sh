#!/usr/bin/env bash
# Find the managed tools without a login shell, and refuse to go on when a tool
# a configured AI harness needs is missing. Sourced, never executed; must not
# change the caller's shell options.
#
# A plain `ssh host cmd` starts a non-login, non-interactive shell that never
# reads ~/.zprofile or ~/.bash_profile, so mise shims, ~/.local/bin (mise,
# claude, copilot) and ~/.pi/agent/bin are not on PATH. This adds the ones that
# exist, in the order the login profiles use, without reading any rc file.

# Put each existing managed tool directory on PATH, in front, unless it is
# already there. As in the login profiles, ~/.pi/agent/bin ends up first, and a
# ~/.dotfiles/bin already on PATH stays ahead of the rest, so its gh identity
# shim keeps winning.
prepend_managed_tool_path() {
  local mise_data=${MISE_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/mise}
  local dotfiles_bin="$HOME/.dotfiles/bin" dir
  for dir in "$mise_data/shims" "$HOME/.local/bin"; do
    [[ -d "$dir" && ":$PATH:" != *":$dir:"* ]] || continue
    PATH="$dir${PATH:+:$PATH}"
  done
  if [[ ":$PATH:" == *":$dotfiles_bin:"* ]]; then
    PATH=":$PATH:"
    PATH=${PATH//":$dotfiles_bin:"/:}
    PATH=${PATH#:}
    PATH=${PATH%:}
    PATH="$dotfiles_bin${PATH:+:$PATH}"
  fi
  dir="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/bin"
  if [[ -d "$dir" && ":$PATH:" != *":$dir:"* ]]; then
    PATH="$dir${PATH:+:$PATH}"
  fi
  export PATH
}

# A harness counts as set up on this machine when its config exists. There,
# a missing tool is an error with a fix; elsewhere the installers may skip.
claude_was_set_up() {
  [[ -d "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" ]]
}

pi_was_set_up() {
  [[ -f "${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/settings.json" ]]
}

# Each check prints an error with the command that fixes it, and fails, when
# the harness was set up here but its tool is missing. Call them after
# prepend_managed_tool_path.
check_claude_tool() {
  claude_was_set_up || return 0
  command -v claude >/dev/null 2>&1 && return 0
  printf '%s\n' \
    "ERROR: Claude Code is set up here (${CLAUDE_CONFIG_DIR:-$HOME/.claude} exists), but no claude command was found on PATH or in ~/.local/bin." \
    "  Fix: reinstall Claude Code into ~/.local/bin with its native installer (https://claude.ai/install.sh), then rerun." \
    "  If this machine no longer uses Claude Code, move ${CLAUDE_CONFIG_DIR:-$HOME/.claude} aside instead." >&2
  return 1
}

check_pi_tool() {
  pi_was_set_up || return 0
  command -v node >/dev/null 2>&1 && return 0
  printf '%s\n' \
    "ERROR: Pi is set up here (${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/settings.json exists), but no node command was found on PATH or in mise's shims." \
    "  Fix: run 'mise install node' (mise is usually ~/.local/bin/mise), then rerun." >&2
  return 1
}

check_ai_tools() {
  local missing=0
  check_claude_tool || missing=1
  check_pi_tool || missing=1
  return "$missing"
}
