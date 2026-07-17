# Vekil Proxy Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the two LiteLLM-backed Codex and Claude proxy processes with one repository-installed Vekil process that is reachable from the host and devcontainers.

**Architecture:** `ai/vekil/install.sh` installs a pinned, checksum-verified native release and delegates startup to `bin/vekil-proxy`. The lifecycle script binds Vekil to the local Docker bridge when available, records that listener under `~/.local/state/vekil`, and exposes lifecycle and diagnostics commands. `ai/vekil/env.zsh` is sourced automatically by the existing shell loader and points Codex and Claude Code at either the recorded host listener or `host.docker.internal` inside containers.

**Tech Stack:** Bash, zsh, curl, jq, Docker CLI, native Vekil binary, GitHub Copilot OAuth, Codex CLI, Claude Code

---

## File Map

### Create

- `ai/vekil/install.sh` — pinned Vekil download, checksum verification, integrated authentication, and startup.
- `ai/vekil/env.zsh` — automatically sourced host/container client environment.
- `bin/vekil-proxy` — process lifecycle, bridge detection, diagnostics, environment output, and model listing.

### Modify

- `ai/codex/config.toml` — remove the LiteLLM provider and allow the standard OpenAI-compatible environment variables to select Vekil.
- `Makefile` — rename the AI target description from LiteLLM to Vekil.
- `README.md` — document Vekil in the AI tool layout and setup flow.
- `AGENTS.md` — document the new `ai/vekil` ownership and remove LiteLLM-specific guidance.

### Delete After Live Validation

- `bin/codex-proxy`
- `bin/copilot-proxy`
- `ai/litellm/install.sh`
- `ai/litellm/config.yaml`

### Preserve as Machine-Local Rollback State

- `~/.config/litellm/github_copilot/`
- The installed LiteLLM executable, until Vekil has passed both client smoke tests.

Do not commit during implementation unless the user explicitly requests commits.

---

### Task 1: Add the Repository-Managed Vekil Installer

**Files:**
- Create: `ai/vekil/install.sh`

- [ ] **Step 1: Verify the installer does not exist yet**

Run:

```bash
cd ~/.dotfiles
test ! -e ai/vekil/install.sh
```

Expected: exits `0`. If the file already exists, inspect it and reconcile this plan rather than overwriting unrelated work.

- [ ] **Step 2: Create the pinned installer**

Create `ai/vekil/install.sh` with this implementation:

```bash
#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../../bin/common.sh"

DOTFILES_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
VEKIL_VERSION="${VEKIL_VERSION:-v0.13.3}"
INSTALL_DIR="${VEKIL_INSTALL_DIR:-$HOME/.local/bin}"
STATE_DIR="${VEKIL_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/vekil}"
VEKIL_BIN="${VEKIL_BIN:-$INSTALL_DIR/vekil}"
VERSION_FILE="$STATE_DIR/installed-version"
RELEASE_BASE="https://github.com/sozercan/vekil/releases/download/$VEKIL_VERSION"
TOKEN_DIR="${VEKIL_TOKEN_DIR:-$HOME/.config/vekil}"
DOWNLOAD_DIR=""

cleanup() {
  [[ -z "$DOWNLOAD_DIR" ]] || rm -rf "$DOWNLOAD_DIR"
}

trap cleanup EXIT

detect_platform() {
  local os arch
  os="${VEKIL_OS:-$(uname -s)}"
  arch="${VEKIL_ARCH:-$(uname -m)}"

  case "$os" in
    Linux)  os="linux" ;;
    Darwin) os="darwin" ;;
    *) log_error "Unsupported Vekil operating system: $os"; return 1 ;;
  esac

  case "$arch" in
    x86_64|amd64) arch="amd64" ;;
    arm64|aarch64) arch="arm64" ;;
    *) log_error "Unsupported Vekil architecture: $arch"; return 1 ;;
  esac

  printf '%s %s\n' "$os" "$arch"
}

checksum_command() {
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s\n' sha256sum
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s\n' 'shasum -a 256'
  else
    log_error "Neither sha256sum nor shasum is available."
    return 1
  fi
}

installed_version() {
  [[ -x "$VEKIL_BIN" && -f "$VERSION_FILE" ]] || return 1
  tr -d '[:space:]' < "$VERSION_FILE"
}

install_vekil() {
  if [[ "$(installed_version 2>/dev/null || true)" == "$VEKIL_VERSION" ]]; then
    log_info "Vekil $VEKIL_VERSION is already installed at $VEKIL_BIN."
    return 0
  fi

  command -v curl >/dev/null 2>&1 || {
    log_error "curl is required to install Vekil."
    return 1
  }

  local platform os arch asset tmpdir expected actual checksum_cmd
  platform=$(detect_platform)
  read -r os arch <<<"$platform"
  asset="vekil-${os}-${arch}"
  tmpdir=$(mktemp -d)
  DOWNLOAD_DIR="$tmpdir"

  log_info "Downloading Vekil $VEKIL_VERSION for $os/$arch..."
  curl -fsSL --retry 3 "$RELEASE_BASE/$asset" -o "$tmpdir/$asset"
  curl -fsSL --retry 3 "$RELEASE_BASE/checksums.txt" -o "$tmpdir/checksums.txt"

  expected=$(awk -v asset="$asset" '$2 == asset { print $1; exit }' "$tmpdir/checksums.txt")
  [[ -n "$expected" ]] || {
    log_error "No checksum was published for $asset."
    return 1
  }

  checksum_cmd=$(checksum_command)
  actual=$(eval "$checksum_cmd \"$tmpdir/$asset\"" | awk '{print $1}')
  [[ "$actual" == "$expected" ]] || {
    log_error "Checksum mismatch for $asset."
    log_error "Expected: $expected"
    log_error "Actual:   $actual"
    return 1
  }

  mkdir -p "$INSTALL_DIR" "$STATE_DIR"
  install -m 0755 "$tmpdir/$asset" "$VEKIL_BIN"
  printf '%s\n' "$VEKIL_VERSION" > "$VERSION_FILE"
  rm -rf "$tmpdir"
  DOWNLOAD_DIR=""
  log_success "Installed Vekil $VEKIL_VERSION at $VEKIL_BIN."
}

authenticate_vekil() {
  [[ "${VEKIL_SKIP_AUTH:-0}" == "1" ]] && return 0

  if command -v gh >/dev/null 2>&1 && gh auth status --hostname github.com >/dev/null 2>&1; then
    log_info "Trying Vekil login with the authenticated GitHub CLI account..."
    if "$VEKIL_BIN" login --token-dir "$TOKEN_DIR" --github-cli; then
      return 0
    fi
    log_warning "GitHub CLI login could not access Copilot; falling back to device login."
  fi

  "$VEKIL_BIN" login --token-dir "$TOKEN_DIR"
}

start_vekil() {
  [[ "${VEKIL_SKIP_START:-0}" == "1" ]] && return 0
  "$DOTFILES_ROOT/bin/vekil-proxy" start
}

main() {
  if [[ "${1:-}" == "--check" ]]; then
    local platform os arch
    platform=$(detect_platform)
    read -r os arch <<<"$platform"
    log_info "[dry-run] Would install $VEKIL_VERSION asset vekil-${os}-${arch} to $VEKIL_BIN"
    log_info "[dry-run] Would authenticate Vekil and start it through bin/vekil-proxy"
    return 0
  fi

  log_info "Setting up Vekil..."
  install_vekil
  authenticate_vekil
  start_vekil
  log_success "Vekil setup complete."
}

main "$@"
```

- [ ] **Step 3: Make the installer executable and check syntax**

Run:

```bash
chmod +x ai/vekil/install.sh
bash -n ai/vekil/install.sh
```

Expected: no output and exit `0`.

- [ ] **Step 4: Exercise platform mapping without downloading**

Run:

```bash
VEKIL_OS=Linux VEKIL_ARCH=x86_64 ai/vekil/install.sh --check
VEKIL_OS=Darwin VEKIL_ARCH=arm64 ai/vekil/install.sh --check
```

Expected: the first reports `vekil-linux-amd64`; the second reports `vekil-darwin-arm64`.

- [ ] **Step 5: Verify unsupported platforms fail clearly**

Run:

```bash
if VEKIL_OS=FreeBSD VEKIL_ARCH=amd64 ai/vekil/install.sh --check; then
  echo "unexpected success" >&2
  exit 1
fi
```

Expected: nonzero exit with `Unsupported Vekil operating system: FreeBSD`.

- [ ] **Step 6: Test checksum verification in an isolated HOME**

Create a temporary fake release and fake `curl` command:

```bash
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/fakebin" "$tmp/release" "$tmp/home"
printf '#!/usr/bin/env bash\necho fake-vekil\n' > "$tmp/release/vekil-linux-amd64"
chmod +x "$tmp/release/vekil-linux-amd64"
sha256sum "$tmp/release/vekil-linux-amd64" | awk '{print $1 "  vekil-linux-amd64"}' > "$tmp/release/checksums.txt"
cat > "$tmp/fakebin/curl" <<EOF
#!/usr/bin/env bash
set -e
url=""
out=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -o) out="\$2"; shift 2 ;;
    -*) shift ;;
    *) url="\$1"; shift ;;
  esac
done
cp "$tmp/release/\${url##*/}" "\$out"
EOF
chmod +x "$tmp/fakebin/curl"
HOME="$tmp/home" PATH="$tmp/fakebin:$PATH" \
  VEKIL_OS=Linux VEKIL_ARCH=amd64 \
  VEKIL_SKIP_AUTH=1 VEKIL_SKIP_START=1 \
  ai/vekil/install.sh
test -x "$tmp/home/.local/bin/vekil"
test "$(cat "$tmp/home/.local/state/vekil/installed-version")" = "v0.13.3"
```

Expected: installation succeeds and both assertions pass.

- [ ] **Step 7: Verify checksum mismatch fails without installing**

Run in the same isolated setup after replacing the checksum:

```bash
printf '%064d  vekil-linux-amd64\n' 0 > "$tmp/release/checksums.txt"
rm -rf "$tmp/home/.local"
if HOME="$tmp/home" PATH="$tmp/fakebin:$PATH" \
  VEKIL_OS=Linux VEKIL_ARCH=amd64 \
  VEKIL_SKIP_AUTH=1 VEKIL_SKIP_START=1 \
  ai/vekil/install.sh; then
  echo "unexpected checksum success" >&2
  exit 1
fi
test ! -e "$tmp/home/.local/bin/vekil"
```

Expected: nonzero exit with `Checksum mismatch`; no binary is installed.

- [ ] **Step 8: Inspect the installer diff**

Run:

```bash
git diff --check -- ai/vekil/install.sh
git diff -- ai/vekil/install.sh
```

Expected: no whitespace errors; installer changes are limited to the new file.

---

### Task 2: Add the Bridge-Aware Vekil Lifecycle Command

**Files:**
- Create: `bin/vekil-proxy`

- [ ] **Step 1: Verify the lifecycle command does not exist yet**

Run:

```bash
cd ~/.dotfiles
test ! -e bin/vekil-proxy
```

Expected: exits `0`.

- [ ] **Step 2: Create the lifecycle command**

Create `bin/vekil-proxy` with this implementation:

```bash
#!/usr/bin/env bash

set -euo pipefail

DOTFILES_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
VEKIL_BIN="${VEKIL_BIN:-$HOME/.local/bin/vekil}"
STATE_DIR="${VEKIL_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/vekil}"
TOKEN_DIR="${VEKIL_TOKEN_DIR:-$HOME/.config/vekil}"
PORT="${VEKIL_PORT:-1337}"
PIDFILE="$STATE_DIR/proxy.pid"
LOG="$STATE_DIR/proxy.log"
HOSTFILE="$STATE_DIR/proxy-host"

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "required command not found: $1" >&2
    return 127
  }
}

require_vekil() {
  [[ -x "$VEKIL_BIN" ]] || {
    echo "Vekil is not installed at $VEKIL_BIN" >&2
    echo "run: $DOTFILES_ROOT/ai/vekil/install.sh" >&2
    return 127
  }
}

is_container() {
  [[ -f /.dockerenv || -n "${REMOTE_CONTAINERS:-}" || -n "${CODESPACES:-}" ]]
}

is_wildcard_host() {
  [[ "$1" == "0.0.0.0" || "$1" == "::" || "$1" == "[::]" ]]
}

is_local_address() {
  local candidate="$1"
  command -v ip >/dev/null 2>&1 || return 0
  ip -o addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -Fxq "$candidate"
}

docker_bridge_host() {
  command -v docker >/dev/null 2>&1 || return 1
  local candidate
  candidate=$(docker network inspect bridge --format '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null || true)
  [[ -n "$candidate" ]] || return 1
  is_local_address "$candidate" || return 1
  printf '%s\n' "$candidate"
}

detect_host() {
  if [[ -n "${VEKIL_HOST:-}" ]]; then
    if is_wildcard_host "$VEKIL_HOST"; then
      echo "warning: VEKIL_HOST=$VEKIL_HOST exposes Vekil's unauthenticated API on every interface" >&2
    fi
    printf '%s\n' "$VEKIL_HOST"
    return 0
  fi

  if [[ "$(uname -s)" != "Darwin" ]]; then
    local bridge
    bridge=$(docker_bridge_host || true)
    if [[ -n "$bridge" ]]; then
      printf '%s\n' "$bridge"
      return 0
    fi
  fi

  echo "warning: Docker bridge unavailable; binding Vekil to loopback only" >&2
  echo "warning: restart vekil-proxy after Docker starts to enable devcontainer access" >&2
  printf '%s\n' "127.0.0.1"
}

runtime_host() {
  if [[ -f "$HOSTFILE" ]]; then
    tr -d '[:space:]' < "$HOSTFILE"
  else
    detect_host
  fi
}

health_url() {
  printf 'http://%s:%s/healthz\n' "$(runtime_host)" "$PORT"
}

ready_url() {
  printf 'http://%s:%s/readyz\n' "$(runtime_host)" "$PORT"
}

is_healthy() {
  curl -fsS --max-time 2 "$(health_url)" >/dev/null 2>&1
}

is_ready() {
  curl -fsS --max-time 3 "$(ready_url)" >/dev/null 2>&1
}

process_is_vekil() {
  local pid="$1" command_line
  command_line=$(ps -p "$pid" -o command= 2>/dev/null || true)
  [[ "$command_line" == *"$VEKIL_BIN"* || "$command_line" == *"/vekil "* ]]
}

pid_of() {
  [[ -f "$PIDFILE" ]] || return 1
  local pid
  pid=$(tr -d '[:space:]' < "$PIDFILE")
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  process_is_vekil "$pid" || return 1
  printf '%s\n' "$pid"
}

spawn_vekil() {
  local host="$1"
  if command -v setsid >/dev/null 2>&1; then
    setsid "$VEKIL_BIN" --host "$host" --port "$PORT" --token-dir "$TOKEN_DIR" </dev/null >"$LOG" 2>&1 &
  else
    nohup "$VEKIL_BIN" --host "$host" --port "$PORT" --token-dir "$TOKEN_DIR" </dev/null >"$LOG" 2>&1 &
  fi
}

start() {
  require_command curl
  require_vekil
  mkdir -p "$STATE_DIR" "$TOKEN_DIR"

  if is_healthy; then
    echo "Vekil already running on $(runtime_host):$PORT (pid $(pid_of || echo unknown))"
    return 0
  fi

  local host pid deadline
  host=$(detect_host)
  printf '%s\n' "$host" > "$HOSTFILE"
  : > "$LOG"
  echo -n "starting Vekil on $host:$PORT "
  spawn_vekil "$host"
  pid=$!
  printf '%s\n' "$pid" > "$PIDFILE"
  disown "$pid" 2>/dev/null || true

  deadline=$((SECONDS + 90))
  until is_ready; do
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "DIED"
      tail -n 50 "$LOG" >&2 || true
      rm -f "$PIDFILE"
      return 1
    fi
    if (( SECONDS >= deadline )); then
      echo "TIMEOUT"
      tail -n 50 "$LOG" >&2 || true
      return 1
    fi
    echo -n "."
    sleep 2
  done

  echo " READY (pid $pid)"
}

stop() {
  local pid deadline
  pid=$(pid_of || true)
  if [[ -z "$pid" ]]; then
    rm -f "$PIDFILE"
    echo "Vekil is not running"
    return 0
  fi

  echo -n "stopping Vekil pid $pid "
  kill "$pid"
  deadline=$((SECONDS + 15))
  while kill -0 "$pid" 2>/dev/null; do
    if (( SECONDS >= deadline )); then
      echo -n "force "
      kill -9 "$pid" 2>/dev/null || true
      break
    fi
    echo -n "."
    sleep 1
  done
  rm -f "$PIDFILE"
  echo " STOPPED"
}

status() {
  local host pid
  host=$(runtime_host)
  pid=$(pid_of || true)
  if is_ready; then
    echo "READY host=$host port=$PORT pid=${pid:-unknown}"
    return 0
  fi
  if is_healthy; then
    echo "STARTING host=$host port=$PORT pid=${pid:-unknown}"
    return 1
  fi
  echo "DOWN host=$host port=$PORT"
  return 1
}

print_env() {
  local host
  host=$(runtime_host)
  cat <<EOF
# Host shell
export OPENAI_BASE_URL="http://${host}:${PORT}/v1"
export OPENAI_API_KEY="dummy"
export ANTHROPIC_BASE_URL="http://${host}:${PORT}"
export ANTHROPIC_API_KEY="dummy"
export ANTHROPIC_MODEL="claude-opus-4.8"

# Devcontainer shell
export OPENAI_BASE_URL="http://host.docker.internal:${PORT}/v1"
export OPENAI_API_KEY="dummy"
export ANTHROPIC_BASE_URL="http://host.docker.internal:${PORT}"
export ANTHROPIC_API_KEY="dummy"
export ANTHROPIC_MODEL="claude-opus-4.8"
EOF
}

models() {
  require_command curl
  require_command jq
  is_ready || {
    echo "Vekil is not ready; run: vekil-proxy start" >&2
    return 1
  }
  curl -fsS "http://$(runtime_host):$PORT/v1/models" | jq -r '.data[].id' | sort
}

login() {
  require_vekil
  "$VEKIL_BIN" login --token-dir "$TOKEN_DIR" "${@:1}"
}

logout() {
  require_vekil
  "$VEKIL_BIN" logout --token-dir "$TOKEN_DIR"
}

case "${1:-default}" in
  install) exec "$DOTFILES_ROOT/ai/vekil/install.sh" "${@:2}" ;;
  login) login "${@:2}" ;;
  logout) logout ;;
  start) start ;;
  stop) stop ;;
  restart) stop; start ;;
  status) status ;;
  env) print_env ;;
  logs) tail -n "${2:-50}" -f "$LOG" ;;
  models) models ;;
  default) start; echo; print_env ;;
  *)
    echo "usage: vekil-proxy [install|login|logout|start|stop|restart|status|env|logs [lines]|models]" >&2
    exit 2
    ;;
esac
```

- [ ] **Step 3: Make the command executable and check syntax**

Run:

```bash
chmod +x bin/vekil-proxy
bash -n bin/vekil-proxy
```

Expected: no output and exit `0`.

- [ ] **Step 4: Test loopback fallback without a Vekil binary**

Run:

```bash
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
VEKIL_STATE_DIR="$tmp/state" VEKIL_BIN="$tmp/missing-vekil" \
  bin/vekil-proxy env 2>"$tmp/stderr" >"$tmp/env"
grep -F 'OPENAI_BASE_URL="http://127.0.0.1:1337/v1"' "$tmp/env"
grep -F 'Docker bridge unavailable' "$tmp/stderr"
```

Expected: both `grep` commands succeed.

- [ ] **Step 5: Test explicit wildcard warning**

Run:

```bash
tmp=$(mktemp -d)
VEKIL_STATE_DIR="$tmp/state" VEKIL_HOST=0.0.0.0 \
  bin/vekil-proxy env 2>"$tmp/stderr" >/dev/null
grep -F "exposes Vekil's unauthenticated API" "$tmp/stderr"
rm -rf "$tmp"
```

Expected: warning is present.

- [ ] **Step 6: Test Docker bridge detection with fake commands**

Run:

```bash
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/fakebin"
cat > "$tmp/fakebin/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '172.19.0.1'
EOF
cat > "$tmp/fakebin/ip" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '7: docker0    inet 172.19.0.1/16 scope global docker0'
EOF
chmod +x "$tmp/fakebin/docker" "$tmp/fakebin/ip"
PATH="$tmp/fakebin:$PATH" VEKIL_STATE_DIR="$tmp/state" \
  bin/vekil-proxy env > "$tmp/env"
grep -F 'OPENAI_BASE_URL="http://172.19.0.1:1337/v1"' "$tmp/env"
```

Expected: bridge address appears in the host block.

- [ ] **Step 7: Test PID safety with an unrelated process**

Run:

```bash
tmp=$(mktemp -d)
trap 'kill "$sleep_pid" 2>/dev/null || true; rm -rf "$tmp"' EXIT
mkdir -p "$tmp/state"
sleep 60 &
sleep_pid=$!
printf '%s\n' "$sleep_pid" > "$tmp/state/proxy.pid"
VEKIL_STATE_DIR="$tmp/state" bin/vekil-proxy stop
kill -0 "$sleep_pid"
```

Expected: the command reports Vekil is not running and the unrelated `sleep` process remains alive.

- [ ] **Step 8: Inspect the lifecycle diff**

Run:

```bash
git diff --check -- bin/vekil-proxy
git diff -- bin/vekil-proxy
```

Expected: no whitespace errors and no broad `pkill` fallback.

---

### Task 3: Add Automatically Sourced Client Environment

**Files:**
- Create: `ai/vekil/env.zsh`
- Modify: `ai/codex/config.toml`

- [ ] **Step 1: Capture the current Codex provider block**

Run:

```bash
sed -n '1,20p' ai/codex/config.toml
```

Expected: output includes `model_provider = "litellm"` and `[model_providers.litellm]`.

- [ ] **Step 2: Create the automatically sourced environment file**

Create `ai/vekil/env.zsh`:

```zsh
typeset vekil_state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/vekil"
typeset vekil_host=""
typeset vekil_port="${VEKIL_PORT:-1337}"

if [[ -f /.dockerenv || -n "${REMOTE_CONTAINERS:-}" || -n "${CODESPACES:-}" ]]; then
  vekil_host="host.docker.internal"
elif [[ -r "$vekil_state_dir/proxy-host" ]]; then
  vekil_host="${$(<"$vekil_state_dir/proxy-host")//[[:space:]]/}"
fi

if [[ -n "$vekil_host" ]]; then
  if [[ -z "${OPENAI_BASE_URL:-}" ]]; then
    export OPENAI_BASE_URL="http://${vekil_host}:${vekil_port}/v1"
    export OPENAI_API_KEY="${OPENAI_API_KEY:-dummy}"
  fi

  if [[ -z "${ANTHROPIC_BASE_URL:-}" ]]; then
    export ANTHROPIC_BASE_URL="http://${vekil_host}:${vekil_port}"
    export ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-dummy}"
    unset ANTHROPIC_AUTH_TOKEN
  fi

  export ANTHROPIC_MODEL="${ANTHROPIC_MODEL:-claude-opus-4.8}"
fi

unset vekil_state_dir vekil_host vekil_port
```

- [ ] **Step 3: Remove LiteLLM selection from Codex config**

Change the beginning of `ai/codex/config.toml` from:

```toml
model = "gpt-5-6-sol"
model_provider = "litellm"
model_reasoning_effort = "medium"
personality = "pragmatic"

[model_providers.litellm]
name = "LiteLLM"
base_url = "http://127.0.0.1:4001/v1"
wire_api = "responses"
env_key = "LITELLM_CODEX_API_KEY"
```

to:

```toml
model = "gpt-5-6-sol"
model_reasoning_effort = "medium"
personality = "pragmatic"
```

Leave all project trust, marketplace, plugin, and TUI settings unchanged.

- [ ] **Step 4: Check zsh syntax and host selection**

Run:

```bash
tmp=$(mktemp -d)
mkdir -p "$tmp/state/vekil"
printf '%s\n' '172.18.0.1' > "$tmp/state/vekil/proxy-host"
XDG_STATE_HOME="$tmp/state" zsh -fc 'source ai/vekil/env.zsh; print -r -- "$OPENAI_BASE_URL|$ANTHROPIC_BASE_URL|$ANTHROPIC_MODEL"'
rm -rf "$tmp"
```

Expected:

```text
http://172.18.0.1:1337/v1|http://172.18.0.1:1337|claude-opus-4.8
```

- [ ] **Step 5: Verify explicit user configuration wins**

Run:

```bash
tmp=$(mktemp -d)
mkdir -p "$tmp/state/vekil"
printf '%s\n' '172.18.0.1' > "$tmp/state/vekil/proxy-host"
XDG_STATE_HOME="$tmp/state" \
OPENAI_BASE_URL=https://example.openai.invalid/v1 \
ANTHROPIC_BASE_URL=https://example.anthropic.invalid \
zsh -fc 'source ai/vekil/env.zsh; print -r -- "$OPENAI_BASE_URL|$ANTHROPIC_BASE_URL"'
rm -rf "$tmp"
```

Expected:

```text
https://example.openai.invalid/v1|https://example.anthropic.invalid
```

- [ ] **Step 6: Verify container selection**

Because the real `/.dockerenv` cannot be safely created or removed, test the equivalent branch with `REMOTE_CONTAINERS=1`:

```bash
env -u OPENAI_BASE_URL -u ANTHROPIC_BASE_URL \
  REMOTE_CONTAINERS=1 \
  zsh -fc 'source ai/vekil/env.zsh; print -r -- "$OPENAI_BASE_URL|$ANTHROPIC_BASE_URL"'
```

Expected:

```text
http://host.docker.internal:1337/v1|http://host.docker.internal:1337
```

- [ ] **Step 7: Validate the static Codex configuration**

Run:

```bash
rg -n 'litellm|LITELLM|model_provider' ai/codex/config.toml && exit 1 || true
git diff --check -- ai/vekil/env.zsh ai/codex/config.toml
```

Expected: no LiteLLM references and no whitespace errors.

---

### Task 4: Install and Validate Vekil Before Removing LiteLLM

**Files:**
- Runtime only: `~/.local/bin/vekil`
- Runtime only: `~/.config/vekil/`
- Runtime only: `~/.local/state/vekil/`

- [ ] **Step 1: Run the repository installer**

Run:

```bash
cd ~/.dotfiles
ai/vekil/install.sh
```

Expected:

- Downloads and verifies the pinned release, or reports it already installed.
- Reuses the authenticated GitHub CLI account when possible; otherwise shows the GitHub device code flow.
- Starts Vekil through `bin/vekil-proxy`.
- Finishes with `Vekil setup complete.`

- [ ] **Step 2: Verify process health and bridge binding**

Run:

```bash
bin/vekil-proxy status
cat "${XDG_STATE_HOME:-$HOME/.local/state}/vekil/proxy-host"
docker network inspect bridge --format '{{(index .IPAM.Config 0).Gateway}}'
```

Expected: status is `READY`; on Linux/WSL the recorded host equals the local Docker bridge gateway. On macOS the recorded host is `127.0.0.1`.

- [ ] **Step 3: Verify the live model catalog**

Run:

```bash
bin/vekil-proxy models | tee /tmp/vekil-models.txt
rg '^gpt-5-6-sol$' /tmp/vekil-models.txt
rg '^claude-opus-4\.8$' /tmp/vekil-models.txt
```

Expected: both configured default model IDs are available. If either is absent, choose an available upstream ID and update `ai/codex/config.toml`, `ai/vekil/env.zsh`, and the design documentation before continuing.

- [ ] **Step 4: Verify environment from a fresh host shell**

Run:

```bash
zsh -lic 'printf "%s\n%s\n" "$OPENAI_BASE_URL" "$ANTHROPIC_BASE_URL"'
```

Expected: both URLs use the listener recorded in `proxy-host`.

- [ ] **Step 5: Verify devcontainer networking**

From a running compose-based devcontainer that declares `host.docker.internal:host-gateway`, run:

```bash
curl -fsS http://host.docker.internal:1337/readyz
curl -fsS http://host.docker.internal:1337/v1/models | jq -e '.data | length > 0'
```

Expected: both commands exit `0`.

- [ ] **Step 6: Smoke-test Claude Code**

Run from a fresh host shell:

```bash
claude --model claude-opus-4.8 --print --output-format text \
  'Reply with exactly VEKIL_CLAUDE_OK'
```

Expected: output is exactly `VEKIL_CLAUDE_OK` apart from surrounding whitespace.

- [ ] **Step 7: Smoke-test Codex Responses API**

Run from a fresh host shell:

```bash
codex exec --skip-git-repo-check -m gpt-5.6-sol \
  'Reply with exactly VEKIL_CODEX_OK'
```

Expected: final model output contains `VEKIL_CODEX_OK` and Vekil remains `READY`.

- [ ] **Step 8: Confirm the installer is idempotent**

Run:

```bash
ai/vekil/install.sh
```

Expected: reports Vekil `v0.13.3` already installed, confirms or reuses authentication, and leaves one healthy Vekil process.

- [ ] **Step 9: Stop if either client smoke test fails**

Do not delete LiteLLM files when either live request fails. Capture:

```bash
bin/vekil-proxy status || true
tail -n 100 "${XDG_STATE_HOME:-$HOME/.local/state}/vekil/proxy.log"
git diff -- ai/codex/config.toml ai/vekil/env.zsh
```

Expected: enough evidence to diagnose Vekil without disturbing the existing LiteLLM installation or credential cache.

---

### Task 5: Retire LiteLLM and Update Repository Documentation

**Files:**
- Delete: `bin/codex-proxy`
- Delete: `bin/copilot-proxy`
- Delete: `ai/litellm/install.sh`
- Delete: `ai/litellm/config.yaml`
- Modify: `Makefile`
- Modify: `README.md`
- Modify: `AGENTS.md`

Prerequisite: every step in Task 4 through both live client smoke tests passed.

- [ ] **Step 1: Delete obsolete proxy and LiteLLM files**

Use `apply_patch` to delete exactly these tracked files:

```text
bin/codex-proxy
bin/copilot-proxy
ai/litellm/install.sh
ai/litellm/config.yaml
```

Do not uninstall the machine-local LiteLLM executable or delete
`~/.config/litellm/github_copilot/` during this task.

- [ ] **Step 2: Update the Makefile AI description**

Change:

```make
ai: ## Install/update all AI tool configs (opencode, claude, codex, copilot, litellm)
```

to:

```make
ai: ## Install/update all AI tool configs (opencode, claude, codex, copilot, vekil)
```

- [ ] **Step 3: Update the README AI layout**

Replace the LiteLLM entry in the `ai/` tree with:

```text
  vekil/        # Native Copilot proxy installer + auto-sourced client environment
```

Replace the individual installer list so it names `ai/vekil/install.sh` instead of `ai/litellm/install.sh`.

Add this concise paragraph after the setup commands:

```markdown
`ai/vekil/install.sh` installs a pinned native Vekil release, authenticates it
with GitHub Copilot, and starts `bin/vekil-proxy`. The proxy binds to the local
Docker bridge when available so host tools and devcontainers share one endpoint.
Client environment variables are loaded automatically from `ai/vekil/env.zsh`.
```

- [ ] **Step 4: Update AGENTS.md ownership guidance**

Under the `ai/` tree, add:

```text
  vekil/
    install.sh               # Installs pinned native proxy and ensures it is running
    env.zsh                  # Auto-selects host or devcontainer proxy endpoint
```

Change the Codex description from `default model + LiteLLM provider` to `default model; Vekil endpoint comes from ai/vekil/env.zsh`.

Add this convention under `## Conventions`:

```markdown
- **Vekil is the canonical local model proxy.** Install and start it through
  `ai/vekil/install.sh` or `bin/vekil-proxy`; do not add unmanaged proxy
  binaries, copied client configs, or manual per-machine endpoint edits.
```

- [ ] **Step 5: Confirm no active LiteLLM references remain**

Run:

```bash
rg -n 'litellm|LiteLLM|codex-proxy|copilot-proxy|LITELLM_' \
  Makefile README.md AGENTS.md ai bin \
  --glob '!marketplace/plugins/my/skills/**'
```

Expected: no matches. If historical documentation intentionally mentions the old system, identify it explicitly instead of silently leaving an active-looking instruction.

- [ ] **Step 6: Verify standard installer discovery**

Run:

```bash
find ai -mindepth 2 -maxdepth 2 -name install.sh -print | sort
make ai-check
ai/vekil/install.sh --check
```

Expected: `ai/vekil/install.sh` appears in normal installer discovery; dry runs succeed.

---

### Task 6: Final Repository and Runtime Verification

**Files:**
- Verify all changed files.

- [ ] **Step 1: Run syntax checks**

Run:

```bash
bash -n ai/vekil/install.sh
bash -n bin/vekil-proxy
zsh -n ai/vekil/env.zsh
```

Expected: all commands exit `0` without output.

- [ ] **Step 2: Run repository formatting checks**

Run:

```bash
git diff --check
```

Expected: no whitespace errors.

- [ ] **Step 3: Review the complete migration diff**

Run:

```bash
git status --short
git diff --stat
git diff -- \
  ai/vekil/install.sh \
  ai/vekil/env.zsh \
  ai/codex/config.toml \
  bin/vekil-proxy \
  Makefile README.md AGENTS.md
```

Expected: only the planned installer, environment, lifecycle, client config, documentation, and LiteLLM removals are present.

- [ ] **Step 4: Re-run standard AI installation**

Run:

```bash
make ai
```

Expected: every AI installer completes or emits only known unrelated warnings; Vekil remains `READY` and no LiteLLM installer runs.

- [ ] **Step 5: Re-run host and devcontainer checks**

Run on the host:

```bash
bin/vekil-proxy status
bin/vekil-proxy models | head
zsh -lic 'printf "%s\n%s\n" "$OPENAI_BASE_URL" "$ANTHROPIC_BASE_URL"'
```

Run in a devcontainer:

```bash
curl -fsS http://host.docker.internal:1337/readyz
zsh -lic 'printf "%s\n%s\n" "$OPENAI_BASE_URL" "$ANTHROPIC_BASE_URL"'
```

Expected: host uses the recorded bridge listener, container uses `host.docker.internal`, and both reach the same Vekil instance.

- [ ] **Step 6: Re-run minimal client smoke tests**

Run:

```bash
claude --model claude-opus-4.8 --print --output-format text \
  'Reply with exactly VEKIL_CLAUDE_FINAL_OK'
codex exec --skip-git-repo-check -m gpt-5-6-sol \
  'Reply with exactly VEKIL_CODEX_FINAL_OK'
```

Expected: both markers are returned and `bin/vekil-proxy status` remains `READY`.

- [ ] **Step 7: Document the deferred cache decision in the handoff**

In the final implementation summary, state:

```text
Full inference-response caching remains intentionally deferred. The previous
LiteLLM configuration did not enable it, and exact-response replay is unsafe
for stateful coding-agent and tool-call traffic without stricter exclusions.
```

- [ ] **Step 8: Do not commit unless requested**

Leave the verified working tree ready for user review. If the user later asks
for a commit, stage only the planned files and use a migration-focused commit
message.
