---
name: prereq-checker
description: >-
  Check tool availability for the current session. Auto-detects required tools
  from project context or accepts an explicit list. Groups results by status
  and suggests install commands for missing tools.
---

# Prerequisite Checker

Check whether required CLI tools are available in the current environment.

## Step 1: Determine Required Tools

If the user provided specific tool names as arguments, check those.

Otherwise, auto-detect from project context by checking for these files:

| File | Tools to check |
|------|----------------|
| `package.json` | `node`, `npm` (or `yarn`, `pnpm`, `bun` if referenced in packageManager field) |
| `go.mod` | `go` |
| `Cargo.toml` | `cargo`, `rustc` |
| `pyproject.toml` / `requirements.txt` | `python3`, `pip` (or `uv`, `poetry` if referenced) |
| `Gemfile` | `ruby`, `bundle` |
| `mix.exs` | `elixir`, `mix` |
| `Dockerfile` / `docker-compose.yml` | `docker`, `docker-compose` |
| `.github/` directory | `gh` |
| `Makefile` / `justfile` | `make` / `just` |
| `Taskfile.yml` | `task` |

Always check these baseline tools regardless: `git`, `gh`.

## Step 2: Check Availability

For each tool, run:

```bash
command -v <tool> 2>/dev/null && <tool> --version 2>/dev/null | head -1
```

If `--version` fails, try `-v`, `-V`, or `version` subcommand. Record:
- Tool name
- Whether it exists (`command -v` exit code)
- Version string (if available)

## Step 3: Detect Environment

Check for devcontainer / remote environment:

```bash
# Devcontainer indicators
[ -f /.dockerenv ] && echo "Docker container detected"
[ -n "$REMOTE_CONTAINERS" ] && echo "VS Code devcontainer detected"
[ -d "/workspaces" ] && echo "Codespaces/devcontainer workspace detected"
[ -n "$CODESPACES" ] && echo "GitHub Codespaces detected"
```

Store the environment type — it affects install command suggestions.

## Step 4: Report Results

Group tools into three categories and present:

### Installed
List each tool with its version.

### Missing (Optional)
Tools that would be useful but aren't strictly required. No action needed.

### Missing (Required)
Tools that the project needs to build/run/test. Suggest install commands based on the detected environment:

| Environment | Package manager |
|-------------|----------------|
| Debian/Ubuntu container | `apt-get install -y <package>` |
| Alpine container | `apk add <package>` |
| macOS | `brew install <package>` |
| Generic Linux | `curl`/`wget` install commands or distro-agnostic methods |

## Step 5: Summary

Print a one-line summary:
```
Prerequisites: N/M installed (K required tools missing)
```

If all required tools are present: "All prerequisites satisfied."
