# Provisioning and Reproducibility Design

## Goal

Make a fresh installation express intentional, profile-specific machine state
without replaying a snapshot of one workstation, and make downloaded tools and
Neovim plugins reproducible enough to audit and recover.

## Scope

This wave covers Linux package composition, remote artifact policy, Neovim
dependency locking, and work-profile Agency configuration. It deliberately
preserves `bin/install` and `bin/dot-update` as idempotent full-convergence
commands.

## Package model

Linux packages will be composed from three concrete files:

1. `platforms/linux/packages/base_apt`, containing packages required on every
   supported Linux installation, such as certificates, curl, Git, zsh, build
   tools, and repository verification tools.
2. Exactly one platform delta: `platforms/linux/packages/ubuntu_apt` or
   `platforms/linux/packages/wsl_apt`.
3. Exactly one profile overlay: `profiles/packages/personal_apt`,
   `profiles/packages/work_apt`, or `profiles/packages/server_apt`.

The existing single profile value remains the public interface. This change
does not introduce composable profile dimensions or new bootstrap prompts.
Every existing profile is legal on Ubuntu and WSL, including server-on-WSL.
The common base and both platform deltas are intentionally minimal; desktop and
workstation software lives only in the `personal` or `work` overlay, so the
`server` composition remains headless on either platform. macOS package-profile
composition is outside this wave and retains its existing behavior.

The migration will curate package intent rather than preserving every current
entry. Kernel packages, EFI/GRUB state, NVIDIA modules, automatically installed
desktop dependencies, language packs, and similar machine observations will not
be managed. Work-only vendor tools such as Azure CLI, Microsoft applications,
Docker, and Kubernetes tooling belong in the work overlay. The server overlay
remains headless and minimal.

`mise` and mikefarah/yq are managed pinned binaries, not APT package entries.
Bootstrap currently calls an undefined `install_mise_ubuntu`; this wave replaces
that dead call with the shared verified-artifact path before runtime convergence
needs mise. It also makes the same pinned yq installation reusable outside the
one-off agent-teams setup.

Package files remain sorted, comment-free input suitable for `mapfile`. The
installer will compose and deduplicate the relevant files before one `apt
install` call. Third-party repositories must be configured before their
packages are requested. Package auditing will compare `apt-mark showmanual`
against the same composed intentional manifest, so installation and drift
reporting share one source of truth.

Packages installed manually but absent from the composed manifest are
**unmanaged extras**, not failures. The audit prints their count and writes the
sorted details under the existing ignored `tmp/` directory; it does not emit
one warning per package or make the optional audit phase fail. This keeps the
large one-time migration diff informative without making it permanent console
noise. Missing managed packages remain actionable because convergence should
have installed them.

## Remote artifact policy

All repository-managed remote downloads will use shared bounded curl defaults:
a 10-second connection timeout, a 120-second overall timeout, and three retries
for transient failures. Executing a downloaded script remains opt-in through
`ALLOW_REMOTE_INSTALLERS=1`.

Versioned binary downloads must verify a pinned SHA-256 digest when the
repository owns the installation path. `config/versions.env` is the canonical
manifest. Each artifact uses explicit shell variables for its version, URL
template or release base, and SHA-256 digest; architecture-specific artifacts
use distinct digest variables. `bin/versions list/check/update` must expose
these pins alongside the existing mise, Git, and Kubernetes pins. If an
upstream does not publish a stable digest, the implementation must derive one
from a reviewed release artifact and pin it or retain an explicit, documented
exception; it must not silently claim verification.

Variable names follow `TOOL_VERSION`, `TOOL_RELEASE_BASE`, and
`TOOL_OS_ARCH_SHA256`; font assets use
`NERD_FONT_<NORMALIZED_ASSET_NAME>_SHA256`. Upstream bootstrap scripts that do
not offer immutable artifacts—currently Homebrew, Rustup, Claude, and Azure
CLI—remain documented exceptions: they are bounded and explicitly opted into,
but are not described as checksum-verified.

The Nerd Fonts installer will no longer clone moving `HEAD` and execute its
repository installer outside the remote-execution policy. It will install the
`CascadiaMono.zip`, `Hack.zip`, and `Meslo.zip` assets from one pinned Nerd Fonts
release. Each archive has its own digest in `config/versions.env`; the installer
stages and verifies all three before replacing installed font files. A local
installed-version record makes unchanged convergence a no-op and causes a
reviewed version bump to replace the managed font directory. These fonts cover
the configured Linux default, the Windows convention in this repo, and the
common Powerlevel10k glyph set without downloading the entire font repository.

## Neovim reproducibility

The `config/nvim/lazy-lock.json` ignore rule will be removed and the current
generated lockfile will be added and reviewed as the initial canonical plugin
graph. The lazy.nvim bootstrap itself will use the immutable revision recorded
in that lockfile rather than the moving `stable` branch.

Routine `bin/install` and `bin/dot-update` convergence will run Lazy's restore
operation, installing exactly the tracked revisions without rewriting the
lockfile or dirtying the worktree. Plugin upgrades remain an explicit
maintainer action (`:Lazy update` followed by review and commit of the lockfile),
not an effect of routine convergence.

## Agency configuration

The globally loaded absolute Agency path will move from `.zshrc` to
`work/agency.zsh`. It will derive the location from `$HOME`, avoid duplicate
PATH entries, and therefore load on every work-profile machine and no personal
or server machine.

## Failure behavior

- Package repository setup failure stops the required package phase before
  installation begins.
- A failed download, timeout, or checksum mismatch leaves the destination
  unchanged and returns nonzero.
- An unavailable optional profile tool remains an optional phase warning only
  where the existing installer already classifies that phase as optional.
- Neovim bootstrap failure remains an optional phase failure reported by the
  phase summary.

Recovery is rerunnable: package and artifact operations remain idempotent. A
bad curated manifest or dependency pin is recovered by reverting or correcting
the repository change and rerunning `bin/install`; staged downloads do not
replace the last working installation until every required digest verifies.

## Testing

Tests will prove package composition and deduplication for Ubuntu/WSL and each
profile, repository setup ordering, exclusion of hardware-state packages,
bounded remote downloads, checksum rejection, remote-script opt-in, tracked
Neovim locking, immutable lazy.nvim bootstrap, and work-only Agency loading.

## Compatibility and exclusions

The profile file format and accepted values do not change. This wave does not
add a dry-run mode, selective update phases, hardware autodetection, package
removal, or automatic cleanup of packages that disappear from the curated
manifest.
