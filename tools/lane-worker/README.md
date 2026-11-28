# Lanes worker box

A lanes worker runs lanes with Claude Code but is not a full dotfiles machine. For a
lane's review round it needs the `gambtho-skills` plugin and the review CLIs those
skills call; lanes also use `kubectl` and the Azure CLI. `install.sh` installs only
those, on Linux or macOS, x86_64 or arm64, without `sudo`:

| What | Why | Where |
|---|---|---|
| `gambtho-skills` plugin at the pinned tag | the review skills (`pr-closeout`, `adversarial-review`, `codex-review.sh`) | `ai/claude/install.sh`, user scope |
| `codex` (pinned, whole release package) | cross-family review through `codex-review.sh` | `~/.local/bin/codex` |
| `coderabbit` (pinned) | the local CodeRabbit review round in `pr-closeout` | `~/.local/bin/coderabbit` |
| `jq` (pinned), only if lanes find none | the plugin installer and `pr_snapshot.sh` | `~/.local/bin/jq` |
| `git-lfs` (pinned, same version as the mise pin), only if lanes find none | repositories with Git LFS hooks warn on every commit without it | `~/.local/bin/git-lfs` |
| `kubectl` (pinned, the `KUBERNETES_CHANNEL` minor) | lanes that work with Kubernetes clusters | `~/.local/bin/kubectl` |
| Azure CLI `az` (pinned on Linux) | lanes that work with Azure | Linux: `uv tool install azure-cli==<pin>`, in `~/.local/share/uv/tools/azure-cli`, linked as `~/.local/bin/az`. macOS: Homebrew's `azure-cli`, linked as `~/.local/bin/az` when lanes do not see Homebrew's folder |
| `python`, only if lanes find none | lanes run `python`; Ubuntu and macOS ship only `python3` | `~/.local/bin/python`, a link to the system `python3` (what `python-is-python3` does, without sudo) |
| `go` and `gofmt`, only if mise has Go installed and lanes find none | lanes do not see mise's shims | `~/.local/bin/go`, `~/.local/bin/gofmt`, links into mise's Go (`mise where go`, run from `~`) |

Each tool unpacks into `~/.local/share/lane-worker/<tool>-<version>/`, and
`~/.local/bin/<tool>` links to it. Codex keeps its whole package there, including the
`bwrap` helper its read-only sandbox uses. Versions and SHA-256 digests live in
`config/versions.env`, one per OS and architecture; `make pins-check` reports newer
releases. Every download is checked against its digest before anything is unpacked.
On macOS the same pinned versions come from the releases' macOS builds. The script
avoids Bash 4 features, so the `bash` 3.2 that macOS ships can run it.

The Azure CLI is a Python application with many dependencies, so it has no single
file to pin. On Linux the script runs `uv tool install azure-cli==<AZURE_CLI_VERSION>`,
which pins `azure-cli` itself and resolves its dependencies from PyPI, using the
system `python3` (3.10 or newer). It uses a `uv` lanes already find, or else
the pinned, digest-checked `uv` release, unpacked under `~/.local/share/lane-worker`
and not linked onto PATH. uv keeps its download cache in `~/.cache/uv`. A new pin
replaces the installed version. On macOS it runs `brew install azure-cli` when
Homebrew is installed and says so when it is not; Homebrew picks the version.

## First run on a box without dotfiles

The box needs `git`, `curl`, `tar`, `python3` and Claude Code (`claude`), which a
worker already has. No `make` or `sudo` is needed. Run it from a plain login shell
as the user the lanes run as, not from inside a lane (a lane may set
`CLAUDE_CONFIG_DIR`, and the plugin would go there).

```bash
git clone https://github.com/gambtho/dotfiles ~/.dotfiles
bash ~/.dotfiles/tools/lane-worker/install.sh --check   # dry run: says what it would do
bash ~/.dotfiles/tools/lane-worker/install.sh --apply
```

With `make` installed, `make lane-worker-check` and `make lane-worker` do the same. A
second run with the same pins downloads and changes nothing. Later,
`git -C ~/.dotfiles pull --ff-only` and `--apply` again move to new pins.

Do not run `make install`, `make bootstrap` or `make ai` on a worker. They set up a
whole machine.

A full dotfiles machine can also run lanes. There, `dot-install` (and so `dot-update`)
ends by printing `make -C ~/.dotfiles lane-worker` as the next step when `lane` is
installed and lanes cannot find `codex` or `coderabbit`. It does not run it, because
`--apply` may re-pin the skills plugin while a lane is in a review.

## Sign-in afterwards

The script never signs in or copies credentials. Once per box, as the user the lanes
run as:

```bash
gh auth status              # GitHub CLI; lanes already need it
codex login --device-auth   # Codex, for codex-review.sh (works without a browser on the box)
coderabbit auth login       # CodeRabbit, for the local review round
az login --use-device-code  # Azure CLI, only if the lanes need Azure
```

Running Claude Code sessions keep the skills they loaded; a new lane started after
the run loads `gambtho-skills`.

Only the `git-lfs` binary is installed. That is enough for LFS hooks. This script
does not run `git lfs install`, because that writes the LFS filters to `~/.gitconfig`.

### CodeRabbit inside a lane

A lane runs CodeRabbit without a terminal. If CodeRabbit finds no sign-in there,
it cannot open a browser, so it stops with
`Non-interactive environment. Use --api-key for authentication.`
(`coderabbit review --agent` says `environment_unsupported`). So check from
inside a lane, not only from your SSH shell: ask a lane to run
`coderabbit auth status`, which should show your account.

If the lane is not signed in although your shell is, sign in with an API key,
which needs no browser. Make an Agentic API key in the CodeRabbit web app, then
in your own terminal on the box, as the lane user:

```bash
read -rs CR_KEY && coderabbit auth login --api-key "$CR_KEY"; unset CR_KEY
```

CodeRabbit 0.9.7 takes the key only as an argument (it has no
`--api-key-file` or stdin option), so while that command runs, any user on the
box who can list processes can see it. Run it only on a worker where you are
the only ordinary user, and in your own terminal, not in a lane. Then run
`coderabbit auth status` from a lane again. Do not pass `--api-key` to `coderabbit review`: the key would show up in
the lane's transcript.

### Codex sandbox

On macOS, Codex uses the system Seatbelt sandbox and needs nothing more. On Linux,
Codex runs review commands in a `bwrap` sandbox. Ubuntu 24.04 restricts
unprivileged user namespaces through AppArmor, and when that is on, the bundled
`bwrap` cannot start. Then every command Codex runs fails, so it reports that it
cannot read the worktree. `install.sh` prints a note when the restriction is on.
To check it, run this in a lane's worktree:

```bash
sysctl kernel.apparmor_restrict_unprivileged_userns   # 1 means restricted
codex sandbox -- ls                                  # should list the worktree
```

With the restriction on, the second command fails, for example with
`bwrap: setting up uid map: Permission denied` or
`bwrap: loopback: Failed RTM_NEWADDR: Operation not permitted`, and the kernel
log shows `apparmor="DENIED" ... profile="unprivileged_userns" comm="bwrap"`.
`install.sh` makes no system change. The opt-in `codex-sandbox.sh` does, with
`sudo`; nothing runs it unless you do:

```bash
make -C ~/.dotfiles codex-sandbox-check   # reads only: says whether the sandbox runs, and what it would change
make -C ~/.dotfiles codex-sandbox         # fixes it; a second run changes nothing
```

It follows Ubuntu's approach for one program that needs user namespaces, an
AppArmor profile for that program, and leaves
`kernel.apparmor_restrict_unprivileged_userns` on:

- installs `bubblewrap` from the distribution, so Codex uses `/usr/bin/bwrap`
  instead of the copy bundled with it, which lives in a folder you can write to;
- installs `bwrap-userns-restrict.apparmor` as
  `/etc/apparmor.d/bwrap-userns-restrict` and loads it with `apparmor_parser -r`.
  The file is a verbatim copy of the profile Ubuntu ships in
  `/usr/share/apparmor/extra-profiles/` (package `apparmor-profiles`). It lets
  `/usr/bin/bwrap` create user namespaces and strips capabilities from the
  programs bwrap runs, so other programs stay restricted. The script does not
  install `apparmor-profiles`, which would also turn on about 20 unrelated
  profiles. AppArmor loads the file again at every boot.

If `/usr/bin/bwrap` can already set up its sandbox, for example through
another profile, it installs no profile. It stops without changing the file if
`/etc/apparmor.d/bwrap-userns-restrict` is already there with other content. On a box without the restriction, or on
macOS, it says there is nothing to do. At the end it runs
`codex sandbox -- true` and says whether that works.

To undo it:

```bash
sudo apparmor_parser -R /etc/apparmor.d/bwrap-userns-restrict
sudo rm /etc/apparmor.d/bwrap-userns-restrict
sudo apt-get purge bubblewrap   # if nothing else needs it (Flatpak does)
```

## What it changes, and what it leaves alone

It writes the tool folders, their links in `~/.local/bin` (and the `python`, `go` and `gofmt` links), what
`uv tool install` or `brew install` writes for the Azure CLI, and what `ai/claude/install.sh`
and the `claude` CLI write. On a box where the plugin is already at the pinned tag,
that, plus attribution already turned off, is nothing. Otherwise `ai/claude/install.sh`:

- sets `attribution` in `~/.claude/settings.json` so Claude Code adds no commit trailer
  or pull request line, keeping every other setting;
- adds the marketplace and installs the plugin at user scope;
- when the marketplace points at another ref (a later pin bump), removes it, which
  uninstalls the plugin, then adds and installs it again. Run a pin bump when no lane is
  in the middle of a review;
- removes `~/.claude/skills` links that point into `~/.dotfiles`, recording their names
  in `~/.local/state/dotfiles/claude-legacy-links.txt`. A worker set up this way has none.

The `claude` CLI itself may rewrite `~/.claude.json` when queried, even under `--check`.

It does not change the login shell, shell profiles, `environment.d` or any other PATH
file, systemd user units, Herdr, lanes or `~/.developerlanes`, and it runs no `sudo`,
`systemctl`, `chsh`, `herdr` or `lane` command. It does not use CodeRabbit's own
`install.sh`, which may edit shell profiles to put `~/.local/bin` on PATH.
`tests/lane_worker_install.bats` checks this against a sandboxed home.

A tool counts as present when lanes would find it: in `~/.local/bin` or the system
directories a systemd user service has on PATH (`/usr/local/bin`, `/usr/bin`, `/bin`).
One found only through an interactive shell (mise shims, npm or bun folders, Homebrew's
`/opt/homebrew/bin` on Apple silicon) does not count, so the pinned build is installed. A file in `~/.local/bin` that is not a link
this script made is left alone; move it aside and rerun to get the pinned build. If
`~/.local/bin` is not on the shell's PATH, the script says so and does not fix it.

Old version folders stay after a pin bump, because a running lane may still use them.
Delete them once no lane does. To undo everything, first remove the Azure CLI: on
Linux `uv tool uninstall azure-cli` (with no other `uv`, use
`~/.local/share/lane-worker/uv-<version>/uv`). On macOS, run `brew uninstall azure-cli`
only if the script installed it (it said "Installed azure-cli with Homebrew"), and
remove `~/.local/bin/az` only if it links into Homebrew's `bin` folder. Then remove the links in `~/.local/bin` that point
into `~/.local/share/lane-worker`, the `~/.local/bin/python`, `go` and `gofmt` links it made, that
folder, and run `claude plugin marketplace remove gambtho-skills`.

## Cluster tools (opt-in)

Some lanes build container images and run kind clusters, some of them with
gVisor. A worker that takes those lanes needs Docker, kind and Go besides what
`install.sh` gives every worker (including `kubectl` and the Azure CLI); run
`make lane-worker` first. `cluster-tools.sh` installs them, on Ubuntu or Debian
(amd64 or arm64) only. It uses `sudo`, so it is separate from `install.sh`, and
nothing runs it unless you do; `dot-install` and `make lane-worker` never do.

| What | From | Where |
|---|---|---|
| Docker Engine (`docker-ce`, CLI, `containerd.io`, buildx and compose plugins) | Docker's apt repository | apt |
| gVisor `runsc`, registered as the Docker runtime `runsc` | gVisor's apt repository | apt; `/etc/docker/daemon.json` |
| `kind` (pinned) | kind release | `~/.local/bin/kind` |
| Go (pinned, the minor of the `go` pin in `config/mise/config.toml`) | go.dev | `~/.local/bin/go`, `~/.local/bin/gofmt` |

Docker's apt repository is the one the work profile adds, in the same file; gVisor's
is set up the same way. Each key goes to `/etc/apt/keyrings` and its source names it
with `signed-by`. If another source file already lists one of them, that one is used
instead. The apt packages follow their repositories, and the normal `apt upgrade`
moves them. `kind` and Go are pinned and digest-checked in
`config/versions.env` and unpack under `~/.local/share/lane-worker`, like the
review CLIs. Lanes do not see mise's shims; `make lane-worker` links mise's Go
when mise has one, and otherwise Go comes from here.

```bash
make -C ~/.dotfiles cluster-tools-check   # reads only: says what is present and what it would do
make -C ~/.dotfiles cluster-tools         # installs; a second run changes nothing
```

It adds `runsc` to the `runtimes` in `/etc/docker/daemon.json` and keeps every
other setting there, then reloads Docker, which leaves running containers alone.
A `runsc` entry that is already there is left as it is, and the file keeps its
owner and mode. If the file is not valid JSON, it stops and changes nothing
there. If the reload fails, the next run tries it again.

### The docker group needs a new login

The script adds you to the `docker` group, but only sessions that start after
that have it. Until then `docker` needs `sudo`. Lanes run under Herdr, which can
outlive a login as a user service, so the simplest step is a reboot. Then check,
from a lane or a new login:

```bash
docker run --rm hello-world
docker run --rm --runtime=runsc hello-world
kind create cluster && kubectl get nodes && kind delete cluster
az version
go version
```

Membership of the `docker` group is the same as root on that machine. Use this
only on a worker whose lanes you trust with that.

### Undo

```bash
sudo apt-get purge docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin runsc
sudo rm /etc/apt/sources.list.d/gvisor.list /etc/apt/keyrings/gvisor-archive-keyring.gpg
sudo gpasswd -d "$USER" docker
for tool in kind go gofmt; do   # only the links this script made
  [[ "$(readlink ~/.local/bin/$tool)" == ~/.local/share/lane-worker/* ]] && rm ~/.local/bin/$tool
done
rm -rf ~/.local/share/lane-worker/{kind,go}-*
```

Except on a work-profile machine, which uses it, also remove the Docker source
with its key:

```bash
sudo rm /etc/apt/sources.list.d/docker.list /etc/apt/keyrings/docker.gpg
```

Purging Docker keeps images and volumes in `/var/lib/docker` and
`/var/lib/containerd`; remove those too to free the space.
