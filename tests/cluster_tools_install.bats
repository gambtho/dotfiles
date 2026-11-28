#!/usr/bin/env bats

load test_helper

# The installer runs from a fixture copy whose pins point at local payloads, so
# a fake curl can serve them with digests that match. sudo runs the command
# without privileges and logs it; apt-get, dpkg-query, usermod, id and
# systemctl are fakes that keep their state under $STATE. APT_ETC and the
# daemon.json path point into the test root.
setup() {
  setup_dotfiles_test
  export USER=tester
  FIXTURE="$TEST_ROOT/repo"
  PAYLOADS="$TEST_ROOT/payloads"
  STATE="$TEST_ROOT/state"
  SHARE="$XDG_DATA_HOME/lane-worker"
  SYSTEM_BIN="$TEST_ROOT/system-bin"
  export PAYLOADS STATE LANE_WORKER_SYSTEM_PATH="$SYSTEM_BIN"
  export APT_ETC="$TEST_ROOT/etc/apt"
  export CLUSTER_TOOLS_DAEMON_JSON="$TEST_ROOT/etc/docker/daemon.json"
  export OS_RELEASE_FILE="$TEST_ROOT/os-release"
  export FAKE_ARCH=amd64 FAKE_UNAME=Linux
  mkdir -p "$FIXTURE"/{tools/lane-worker,libexec/lib,config} "$PAYLOADS" "$STATE" "$SYSTEM_BIN" \
    "$APT_ETC/sources.list.d" "$HOME/.local/bin"
  cp "$REPO_ROOT/tools/lane-worker/cluster-tools.sh" "$FIXTURE/tools/lane-worker/"
  cp "$REPO_ROOT/libexec/lib/artifacts.sh" "$REPO_ROOT/libexec/lib/apt.sh" \
    "$REPO_ROOT/libexec/lib/apt-repositories.sh" "$FIXTURE/libexec/lib/"
  cp "$REPO_ROOT/libexec/log-helper" "$FIXTURE/libexec/"
  INSTALLER="$FIXTURE/tools/lane-worker/cluster-tools.sh"
  printf 'ID=ubuntu\nVERSION_CODENAME=noble\n' >"$OS_RELEASE_FILE"

  local arch
  for arch in amd64 arm64; do
    printf '#!/bin/sh\necho kind %s\n' "$arch" >"$PAYLOADS/kind-linux-$arch"
    mkdir -p "$TEST_ROOT/go-$arch/go/bin"
    printf '#!/bin/sh\necho go %s\n' "$arch" >"$TEST_ROOT/go-$arch/go/bin/go"
    printf '#!/bin/sh\necho gofmt %s\n' "$arch" >"$TEST_ROOT/go-$arch/go/bin/gofmt"
    chmod +x "$TEST_ROOT/go-$arch/go/bin/"*
    tar -czf "$PAYLOADS/go$(sed -n 's/^GO_VERSION=//p' "$REPO_ROOT/config/versions.env").linux-$arch.tar.gz" \
      -C "$TEST_ROOT/go-$arch" go
  done
  for key in gpg archive.key; do
    printf -- '-----BEGIN PGP PUBLIC KEY BLOCK-----\n%s\n' "$key" >"$PAYLOADS/$key"
  done
  write_pins

  stub_command uname 'echo "$FAKE_UNAME"'
  stub_command curl '
    out="" url=""
    while (($#)); do
      case "$1" in
        --output) out=$2; shift ;;
        https://*) url=$1 ;;
      esac
      shift
    done
    echo "$url" >>"$STATE/downloads"
    cp "$PAYLOADS/${url##*/}" "$out"
  '
  # Unprivileged here, so install cannot set an owner; the call is logged.
  stub_command sudo '
    echo "$*" >>"$STATE/sudo"
    if [[ "$1" == install ]]; then
      args=()
      while (($#)); do
        case "$1" in
          -o | -g) shift ;;
          *) args+=("$1") ;;
        esac
        shift
      done
      set -- "${args[@]}"
    fi
    exec "$@"
  '
  stub_command gpg '
    [[ ! -f "$STATE/gpg-fails" ]] || exit 2
    out="" src=""
    while (($#)); do
      case "$1" in
        --output) out=$2; shift ;;
        --homedir) shift ;;
        --*) ;;
        *) src=$1 ;;
      esac
      shift
    done
    cp "$src" "$out"
  '
  stub_command dpkg '[[ "$1" == --print-architecture ]] && echo "$FAKE_ARCH"'
  stub_command dpkg-query '
    package=${*: -1}
    grep -qx "$package" "$STATE/installed" 2>/dev/null || exit 1
    printf "install ok installed"
  '
  stub_command apt-get '
    echo "apt-get $*" >>"$STATE/apt"
    [[ "$1" == install ]] || exit 0
    shift
    while (($#)); do
      case "$1" in
        -o) shift ;;
        -*) ;;
        *) echo "$1" >>"$STATE/installed" ;;
      esac
      shift
    done
  '
  stub_command usermod 'echo "${*: -1} docker" >>"$STATE/groups"'
  stub_command id '
    case "$*" in
      -un) echo tester ;;
      "-nG tester") printf "tester"; grep -q "^tester docker$" "$STATE/groups" 2>/dev/null && printf " docker"; echo ;;
      -nG) printf "tester"; [[ -f "$STATE/session-docker" ]] && printf " docker"; echo ;;
      *) exit 1 ;;
    esac
  '
  stub_command systemctl '
    echo "systemctl $*" >>"$STATE/systemctl"
    case "$*" in
      "is-active --quiet docker") [[ -f "$STATE/docker-active" ]] ;;
      *) exit 0 ;;
    esac
  '
}

digest() { sha256sum "$1" | awk '{print $1}'; }

write_pins() {
  local go_version
  go_version=$(sed -n 's/^GO_VERSION=//p' "$REPO_ROOT/config/versions.env")
  cp "$REPO_ROOT/config/versions.env" "$FIXTURE/config/versions.env"
  cat >>"$FIXTURE/config/versions.env" <<EOF
KIND_RELEASE_BASE=https://example.test/kind
KIND_LINUX_AMD64_SHA256=$(digest "$PAYLOADS/kind-linux-amd64")
KIND_LINUX_ARM64_SHA256=$(digest "$PAYLOADS/kind-linux-arm64")
GO_RELEASE_BASE=https://example.test/go
GO_LINUX_AMD64_SHA256=$(digest "$PAYLOADS/go$go_version.linux-amd64.tar.gz")
GO_LINUX_ARM64_SHA256=$(digest "$PAYLOADS/go$go_version.linux-arm64.tar.gz")
EOF
  source "$FIXTURE/config/versions.env"
}

snapshot() {
  (cd "$TEST_ROOT" && find home etc -printf '%p %y %l\n' | sort)
}

@test "usage: exactly one of --check or --apply" {
  run bash "$INSTALLER"
  [ "$status" -eq 2 ]
  run bash "$INSTALLER" --apply --check
  [ "$status" -eq 2 ]
  run bash "$INSTALLER" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--check | --apply"* ]]
}

@test "another OS, distribution or architecture stops before any change" {
  snapshot >"$TEST_ROOT/before"
  FAKE_UNAME=Darwin run bash "$INSTALLER" --apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"Linux only (Ubuntu or Debian); this is Darwin. Nothing was changed."* ]]

  printf 'ID=fedora\n' >"$OS_RELEASE_FILE"
  run bash "$INSTALLER" --apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"Ubuntu or Debian only; this is fedora."* ]]

  printf 'ID=ubuntu\nVERSION_CODENAME=noble\n' >"$OS_RELEASE_FILE"
  FAKE_ARCH=riscv64 run bash "$INSTALLER" --apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"unsupported architecture: riscv64"* ]]

  [ ! -e "$STATE/sudo" ]
  [ ! -e "$STATE/downloads" ]
  diff "$TEST_ROOT/before" <(snapshot)
}

@test "--check reports what is missing and changes nothing" {
  snapshot >"$TEST_ROOT/before"

  run bash "$INSTALLER" --check

  [ "$status" -eq 0 ]
  [[ "$output" == *"[dry-run] Would install Docker Engine (docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin); adding its repository."* ]]
  [[ "$output" == *"[dry-run] Would install gVisor runsc (runsc); adding its repository."* ]]
  [[ "$output" == *"[dry-run] Would add tester to the docker group"* ]]
  [[ "$output" == *"[dry-run] Would add runsc (/usr/bin/runsc) to the runtimes in $CLUSTER_TOOLS_DAEMON_JSON"* ]]
  [[ "$output" == *"[dry-run] Would install kind $KIND_VERSION."* ]]
  [[ "$output" == *"[dry-run] Would install go $GO_VERSION."* ]]
  [ ! -e "$STATE/sudo" ]
  [ ! -e "$STATE/downloads" ]
  [ ! -e "$STATE/apt" ]
  diff "$TEST_ROOT/before" <(snapshot)
}

@test "--apply installs everything, and a second run changes nothing" {
  touch "$STATE/docker-active"

  run bash "$INSTALLER" --apply

  [ "$status" -eq 0 ]
  # Signed vendor repositories, in the files the work profile uses.
  [ "$(cat "$APT_ETC/sources.list.d/docker.list")" = \
    "deb [arch=amd64 signed-by=$APT_ETC/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu noble stable" ]
  [ "$(cat "$APT_ETC/sources.list.d/gvisor.list")" = \
    "deb [arch=amd64 signed-by=$APT_ETC/keyrings/gvisor-archive-keyring.gpg] https://storage.googleapis.com/gvisor/releases release main" ]
  [ -s "$APT_ETC/keyrings/docker.gpg" ]
  [ -s "$APT_ETC/keyrings/gvisor-archive-keyring.gpg" ]
  # One update and one install, after the sources.
  [ "$(grep -c '^apt-get update' "$STATE/apt")" -eq 1 ]
  grep -q '^apt-get install .*-y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin runsc$' "$STATE/apt"
  [ ! -e "$APT_ETC/sources.list.d/azure-cli.sources" ]
  grep -qx 'tester docker' "$STATE/groups"
  python3 -I -c 'import json, sys; assert json.load(open(sys.argv[1])) == {"runtimes": {"runsc": {"path": "/usr/bin/runsc"}}}' \
    "$CLUSTER_TOOLS_DAEMON_JSON"
  grep -qx 'systemctl reload docker' "$STATE/systemctl"
  [ "$("$HOME/.local/bin/kind")" = "kind amd64" ]
  [ ! -e "$HOME/.local/bin/kubectl" ]
  [ "$("$HOME/.local/bin/go")" = "go amd64" ]
  [ "$("$HOME/.local/bin/gofmt")" = "gofmt amd64" ]
  assert_symlink_target "$HOME/.local/bin/kind" "$SHARE/kind-$KIND_VERSION/kind"
  assert_symlink_target "$HOME/.local/bin/go" "$SHARE/go-$GO_VERSION/go/bin/go"
  [[ "$output" == *"The docker group takes effect only in sessions that start after this run."* ]]
  [[ "$output" == *"docker run --rm --runtime=runsc hello-world"* ]]

  # The user logs in again; nothing is left to do.
  touch "$STATE/session-docker"
  rm -f "$STATE/sudo" "$STATE/downloads" "$STATE/apt" "$STATE/systemctl"
  snapshot >"$TEST_ROOT/before"

  run bash "$INSTALLER" --apply

  [ "$status" -eq 0 ]
  [ ! -e "$STATE/sudo" ]
  [ ! -e "$STATE/downloads" ]
  [ ! -e "$STATE/apt" ]
  diff "$TEST_ROOT/before" <(snapshot)
  [[ "$output" == *"Docker Engine is installed."* ]]
  [[ "$output" == *"tester is in the docker group."* ]]
  [[ "$output" == *"runsc is a Docker runtime in"* ]]
  [[ "$output" == *"go $GO_VERSION is installed."* ]]
  [[ "$output" != *"takes effect only"* ]]

  run bash "$INSTALLER" --check
  [ "$status" -eq 0 ]
  [[ "$output" != *"[dry-run]"* ]]
  [ ! -e "$STATE/sudo" ]
}

@test "runsc joins the runtimes in daemon.json and every other key stays" {
  printf '%s\n' docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin runsc >"$STATE/installed"
  mkdir -p "$(dirname "$CLUSTER_TOOLS_DAEMON_JSON")"
  cat >"$CLUSTER_TOOLS_DAEMON_JSON" <<'EOF'
{
  "log-driver": "local",
  "data-root": "/srv/docker",
  "runtimes": {"nvidia": {"path": "nvidia-container-runtime", "runtimeArgs": []}},
  "default-address-pools": [{"base": "10.200.0.0/16", "size": 24}]
}
EOF

  run bash "$INSTALLER" --apply

  [ "$status" -eq 0 ]
  python3 -I -c 'import json, sys
data = json.load(open(sys.argv[1]))
assert data == {
    "log-driver": "local",
    "data-root": "/srv/docker",
    "runtimes": {
        "nvidia": {"path": "nvidia-container-runtime", "runtimeArgs": []},
        "runsc": {"path": "/usr/bin/runsc"},
    },
    "default-address-pools": [{"base": "10.200.0.0/16", "size": 24}],
}, data' "$CLUSTER_TOOLS_DAEMON_JSON"
  # Docker is not running here, so nothing is reloaded.
  ! grep -q reload "$STATE/systemctl"
  [[ "$output" == *"Docker is not running; it reads the runtime when it starts."* ]]

  # A runsc entry someone tuned is left exactly as it is.
  printf '{"runtimes": {"runsc": {"path": "/usr/bin/runsc", "runtimeArgs": ["--platform=kvm"]}}}\n' >"$CLUSTER_TOOLS_DAEMON_JSON"
  cp "$CLUSTER_TOOLS_DAEMON_JSON" "$TEST_ROOT/tuned"
  run bash "$INSTALLER" --apply
  [ "$status" -eq 0 ]
  cmp "$TEST_ROOT/tuned" "$CLUSTER_TOOLS_DAEMON_JSON"
}

@test "a daemon.json that is not a JSON object stops --apply without rewriting it" {
  printf '%s\n' docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin runsc >"$STATE/installed"
  mkdir -p "$(dirname "$CLUSTER_TOOLS_DAEMON_JSON")"
  printf '{"log-driver": "local",\n' >"$CLUSTER_TOOLS_DAEMON_JSON"
  cp "$CLUSTER_TOOLS_DAEMON_JSON" "$TEST_ROOT/broken"

  run bash "$INSTALLER" --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"is not a JSON object with a runtimes object; --apply would stop here."* ]]

  run bash "$INSTALLER" --apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"so runsc was not added. Fix it, then rerun."* ]]
  cmp "$TEST_ROOT/broken" "$CLUSTER_TOOLS_DAEMON_JSON"
}

@test "a repository another source file already lists is used, not listed twice" {
  printf 'deb [signed-by=/usr/share/keyrings/docker.asc] https://download.docker.com/linux/ubuntu noble stable\n' \
    >"$APT_ETC/sources.list.d/docker-manual.list"
  # A commented-out line does not count.
  printf '# deb https://storage.googleapis.com/gvisor/releases release main\n' >"$APT_ETC/sources.list.d/old.list"

  run bash "$INSTALLER" --apply

  [ "$status" -eq 0 ]
  [[ "$output" == *"Docker Engine (docker-ce"*"its repository is already listed in $APT_ETC/sources.list.d/docker-manual.list."* ]]
  [ ! -e "$APT_ETC/sources.list.d/docker.list" ]
  [ ! -e "$APT_ETC/keyrings/docker.gpg" ]
  [ -e "$APT_ETC/sources.list.d/gvisor.list" ]
}

@test "a source file of ours with only comments gets the repository again" {
  printf '# deb https://download.docker.com/linux/ubuntu noble stable\n' >"$APT_ETC/sources.list.d/docker.list"

  run bash "$INSTALLER" --apply

  [ "$status" -eq 0 ]
  [[ "$output" == *"Installing Docker Engine (docker-ce"*"adding its repository."* ]]
  grep -q '^deb \[arch=amd64 signed-by=' "$APT_ETC/sources.list.d/docker.list"
}

@test "a key that fails to convert leaves the existing key in place" {
  mkdir -p "$APT_ETC/keyrings"
  printf 'working key\n' >"$APT_ETC/keyrings/docker.gpg"
  touch "$STATE/gpg-fails"

  run bash -c 'source "$1"; setup_docker_repository' _ "$FIXTURE/libexec/lib/apt-repositories.sh"

  [ "$status" -ne 0 ]
  [ "$(cat "$APT_ETC/keyrings/docker.gpg")" = "working key" ]
  [ ! -e "$APT_ETC/sources.list.d/docker.list" ]
}

@test "a symlinked daemon.json is updated where it points and stays a link" {
  printf '%s\n' docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin runsc >"$STATE/installed"
  mkdir -p "$(dirname "$CLUSTER_TOOLS_DAEMON_JSON")" "$TEST_ROOT/etc/docker-config"
  printf '{"log-driver": "local"}\n' >"$TEST_ROOT/etc/docker-config/daemon.json"
  chmod 0600 "$TEST_ROOT/etc/docker-config/daemon.json"
  ln -s "$TEST_ROOT/etc/docker-config/daemon.json" "$CLUSTER_TOOLS_DAEMON_JSON"

  run bash "$INSTALLER" --apply

  [ "$status" -eq 0 ]
  [ -L "$CLUSTER_TOOLS_DAEMON_JSON" ]
  [ "$(stat -c %a "$TEST_ROOT/etc/docker-config/daemon.json")" = 600 ]
  grep -q '"runsc"' "$TEST_ROOT/etc/docker-config/daemon.json"
  grep -q '"log-driver": "local"' "$TEST_ROOT/etc/docker-config/daemon.json"
}

@test "a failed Docker reload is retried by the next run" {
  touch "$STATE/docker-active"
  stub_command systemctl '
    echo "systemctl $*" >>"$STATE/systemctl"
    case "$*" in
      "is-active --quiet docker") exit 0 ;;
      reload*) [[ -f "$STATE/reload-works" ]] ;;
    esac
  '
  run bash "$INSTALLER" --apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"Docker did not reload. Rerun this, or run: sudo systemctl reload docker"* ]]

  touch "$STATE/reload-works"
  run bash "$INSTALLER" --check
  [[ "$output" == *"[dry-run] Would reload Docker, which a previous run did not finish."* ]]
  run bash "$INSTALLER" --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"Reloaded Docker."* ]]

  rm -f "$STATE/systemctl"
  run bash "$INSTALLER" --apply
  [ "$status" -eq 0 ]
  ! grep -q reload "$STATE/systemctl"
}

@test "daemon.json keeps its owner and mode when runsc is added" {
  printf '%s\n' docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin runsc >"$STATE/installed"
  mkdir -p "$(dirname "$CLUSTER_TOOLS_DAEMON_JSON")"
  printf '{"proxies": {"http-proxy": "http://user:secret@proxy:3128"}}\n' >"$CLUSTER_TOOLS_DAEMON_JSON"
  chmod 0640 "$CLUSTER_TOOLS_DAEMON_JSON"

  run bash "$INSTALLER" --apply

  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$CLUSTER_TOOLS_DAEMON_JSON")" = 640 ]
  grep -q "^install -D -m 640 -o $(stat -c %u "$CLUSTER_TOOLS_DAEMON_JSON") -g $(stat -c %g "$CLUSTER_TOOLS_DAEMON_JSON") " "$STATE/sudo"
}

@test "debian gets Docker's debian repository" {
  printf 'ID=debian\nVERSION_CODENAME=bookworm\n' >"$OS_RELEASE_FILE"

  run bash "$INSTALLER" --apply

  [ "$status" -eq 0 ]
  [ "$(cat "$APT_ETC/sources.list.d/docker.list")" = \
    "deb [arch=amd64 signed-by=$APT_ETC/keyrings/docker.gpg] https://download.docker.com/linux/debian bookworm stable" ]
  grep -qx 'https://download.docker.com/linux/debian/gpg' "$STATE/downloads"
}

@test "arm64 boxes get the arm64 builds" {
  FAKE_ARCH=arm64 run bash "$INSTALLER" --apply

  [ "$status" -eq 0 ]
  [ "$("$HOME/.local/bin/kind")" = "kind arm64" ]
  [ "$("$HOME/.local/bin/go")" = "go arm64" ]
  grep -q '^deb \[arch=arm64 ' "$APT_ETC/sources.list.d/docker.list"
}

@test "a file it did not link, or a tool lanes already find, is left alone" {
  printf '#!/bin/sh\necho own kind\n' >"$HOME/.local/bin/kind"
  chmod +x "$HOME/.local/bin/kind"
  printf '#!/bin/sh\necho system go\n' >"$SYSTEM_BIN/go"
  chmod +x "$SYSTEM_BIN/go"

  run bash "$INSTALLER" --apply

  [ "$status" -eq 0 ]
  [[ "$output" == *"$HOME/.local/bin/kind was not installed by this script; leaving kind alone."* ]]
  [[ "$output" == *"go is already at $SYSTEM_BIN/go; leaving it."* ]]
  [ "$("$HOME/.local/bin/kind")" = "own kind" ]
  [ ! -e "$HOME/.local/bin/go" ]
  [ ! -e "$HOME/.local/bin/gofmt" ]
}

@test "a digest mismatch fails and links nothing" {
  printf 'tampered\n' >>"$PAYLOADS/kind-linux-amd64"

  run bash "$INSTALLER" --apply

  [ "$status" -ne 0 ]
  [[ "$output" == *"checksum mismatch"* ]]
  [ ! -e "$HOME/.local/bin/kind" ]
  [ ! -e "$SHARE/kind-$KIND_VERSION" ]
}

@test "a new pin relinks a build it installed and keeps the old folder" {
  run bash "$INSTALLER" --apply
  [ "$status" -eq 0 ]
  local old="$SHARE/kind-$KIND_VERSION"
  sed -i 's/^KIND_VERSION=.*/KIND_VERSION=v9.9.9/' "$FIXTURE/config/versions.env"

  run bash "$INSTALLER" --check
  [[ "$output" == *"[dry-run] Would replace kind v9.9.9."* ]]
  run bash "$INSTALLER" --apply

  [ "$status" -eq 0 ]
  assert_symlink_target "$HOME/.local/bin/kind" "$SHARE/kind-v9.9.9/kind"
  [ -x "$old/kind" ]
}

@test "Go follows the mise pin" {
  source "$REPO_ROOT/config/versions.env"
  [[ "$KIND_RELEASE_BASE" == */"$KIND_VERSION" ]]
  local mise_go
  mise_go=$(sed -n 's/^go = "\(.*\)"$/\1/p' "$REPO_ROOT/config/mise/config.toml")
  [ -n "$mise_go" ]
  [[ "$GO_VERSION" == "$mise_go".* ]]
}

@test "only an explicit make target runs it" {
  run grep -rl --exclude-dir=.git -e 'cluster-tools\.sh' -e 'make cluster-tools' "$REPO_ROOT"
  [ "$status" -eq 0 ]
  # Its own files, its pins and its library name it; nothing else does.
  [ "$(sed "s|^$REPO_ROOT/||" <<<"$output" | LC_ALL=C sort | tr '\n' ' ')" = \
    "AGENTS.md Makefile config/versions.env libexec/lib/apt-repositories.sh tests/cluster_tools_install.bats tools/lane-worker/README.md tools/lane-worker/cluster-tools.sh " ]
  run grep -n 'cluster-tools' "$REPO_ROOT/Makefile"
  [[ "$output" == *"cluster-tools: ##"* ]]
  [[ "$output" != *"install: "*"cluster-tools"* ]]
}
