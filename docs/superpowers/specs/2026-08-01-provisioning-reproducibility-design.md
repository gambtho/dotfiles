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

Linux packages will be composed from two layers:

1. A platform base containing packages required on every supported Linux
   installation, such as certificates, curl, Git, zsh, mise, build tools, and
   repository verification tools.
2. Exactly one existing profile overlay: `personal`, `work`, or `server`.

The existing single profile value remains the public interface. This change
does not introduce composable profile dimensions or new bootstrap prompts.
Ubuntu and WSL may have separate platform bases where the operating environments
genuinely differ.

The migration will curate package intent rather than preserving every current
entry. Kernel packages, EFI/GRUB state, NVIDIA modules, automatically installed
desktop dependencies, language packs, and similar machine observations will not
be managed. Work-only vendor tools such as Azure CLI, Microsoft applications,
Docker, and Kubernetes tooling belong in the work overlay. The server overlay
remains headless and minimal.

Package files remain sorted, comment-free input suitable for `mapfile`. The
installer will compose and deduplicate the relevant files before one `apt
install` call. Third-party repositories must be configured before their
packages are requested. Package auditing will compare `apt-mark showmanual`
against the same composed intentional manifest, so installation and drift
reporting share one source of truth.

## Remote artifact policy

All repository-managed remote downloads will use shared bounded curl defaults:
a connection timeout, an overall timeout, and limited retries. Executing a
downloaded script remains opt-in through `ALLOW_REMOTE_INSTALLERS=1`.

Versioned binary downloads must verify a pinned SHA-256 digest when the
repository owns the installation path. Versions and digests live with other
managed pins, not inline in installers. If an upstream does not publish a
stable digest, the implementation must either derive one from a reviewed
release artifact and pin it or retain an explicit, documented exception; it
must not silently claim verification.

The Nerd Fonts installer will no longer clone moving `HEAD` and execute its
repository installer outside the remote-execution policy. It will install a
pinned release/artifact through the shared policy and retain idempotent
directory detection.

## Neovim reproducibility

`config/nvim/lazy-lock.json` becomes tracked and is the canonical plugin graph.
The lazy.nvim bootstrap itself will use a reviewed immutable revision rather
than the moving `stable` branch. `Lazy! sync` remains part of convergence, now
constrained by the lockfile. Dependency updates remain deliberate repository
changes reviewable through Git.

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
