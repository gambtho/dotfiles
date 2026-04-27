#!/usr/bin/env bash

set -e

source "$(dirname "$0")/../../bin/common.sh"

DOTFILES_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"

install_claude() {
    log_info "Installing Claude Code (native)..."
    curl -fsSL https://claude.ai/install.sh | bash
    log_success "Claude Code installed."
}

update_claude() {
    log_info "Updating Claude Code..."
    claude update
    log_success "Claude Code updated."
}

# Rewrite stale paths in ~/.claude/plugins/{installed_plugins,known_marketplaces}.json
# that point into another user's home (e.g. /home/node, /home/vscode, /Users/foo)
# after the dotfiles repo has been moved between machines. The plugin/marketplace
# cache gets re-fetched locally but the JSON still references the old paths,
# causing /plugins to show everything as broken.
#
# Must run BEFORE `claude update` — otherwise claude reads the stale paths,
# fails to find plugins/marketplaces, and rewrites entries with version="unknown"
# and orphaned cache directories that the regex-based fixup can no longer recover.
fixup_stale_plugin_paths() {
    local plugins_file="$HOME/.claude/plugins/installed_plugins.json"
    local markets_file="$HOME/.claude/plugins/known_marketplaces.json"
    [ -f "$plugins_file" ] || [ -f "$markets_file" ] || return 0
    if ! command_exists python3; then
        log_info "python3 not available; skipping plugin path fixup."
        return 0
    fi

    local changed
    changed=$(python3 - "$plugins_file" "$markets_file" <<'PY'
import json, os, re, sys
home = os.path.expanduser("~")
pattern = re.compile(r"^(/home|/Users)/[^/]+/")

def rewrite(value):
    if not isinstance(value, str) or not value or value.startswith(home + "/"):
        return value, False
    m = pattern.match(value)
    if not m:
        return value, False
    return home + "/" + value[m.end():], True

def fix_file(path, walk):
    if not os.path.exists(path):
        return 0
    with open(path) as fh:
        data = json.load(fh)
    n = walk(data)
    if n:
        with open(path, "w") as fh:
            json.dump(data, fh, indent=2)
    return n

def walk_plugins(data):
    n = 0
    for entries in data.get("plugins", {}).values():
        for e in entries:
            new, ok = rewrite(e.get("installPath", ""))
            if ok:
                e["installPath"] = new
                n += 1
    return n

def walk_markets(data):
    n = 0
    for entry in data.values():
        if not isinstance(entry, dict):
            continue
        new, ok = rewrite(entry.get("installLocation", ""))
        if ok:
            entry["installLocation"] = new
            n += 1
    return n

total = fix_file(sys.argv[1], walk_plugins) + fix_file(sys.argv[2], walk_markets)
print(total)
PY
)
    if [ "${changed:-0}" -gt 0 ]; then
        log_success "Rewrote $changed stale plugin/marketplace path(s) to \$HOME."
    fi
}

link_file() {
    local src="$1"
    local dst="$2"
    local label="$3"

    if [ -L "$dst" ]; then
        local current
        current=$(readlink "$dst")
        if [ "$current" == "$src" ]; then
            log_info "Claude $label already linked."
            return
        fi
        log_info "Removing existing $label symlink -> $current"
        rm "$dst"
    elif [ -f "$dst" ]; then
        log_info "Backing up existing $label to ${dst}.backup"
        mv "$dst" "${dst}.backup"
    fi

    ln -s "$src" "$dst"
    log_success "Linked $src to $dst"
}

main() {
    # Fixup must run before any `claude` invocation — see comment on the function.
    fixup_stale_plugin_paths

    if command_exists claude; then
        log_info "Claude Code is already installed. Version: $(claude --version)"
        update_claude
    else
        if command_exists curl; then
            install_claude
        else
            log_warning "curl not found. Install curl first, then re-run."
            return 1
        fi
    fi

    link_file "$DOTFILES_ROOT/claude/settings.json" "$HOME/.claude/settings.json" "settings"
}

main "$@"
