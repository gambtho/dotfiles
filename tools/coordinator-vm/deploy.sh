#!/usr/bin/env bash
# tools/coordinator-vm/deploy.sh -- preview or create the coordinator VM.
#
# Usage: deploy.sh [what-if|create] --subscription ID --admin-user NAME --ssh-key FILE.pub [--location REGION]
#
# The default is what-if, which changes nothing in Azure. The Git name and
# email written into cloud-init come from this machine's global Git config.
# The VM clones the public repository and checks out this checkout's HEAD, so
# create first fetches that repository's main and needs HEAD to be on it: a
# commit GitHub does not serve there would fail on first boot.

set -euo pipefail

usage() {
  sed -n '4p' "${BASH_SOURCE[0]}" | cut -c3- >&2
}

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# The same URL cloud-init.yaml clones.
repository_url=https://github.com/gambtho/dotfiles.git
mode=what-if
subscription=""
admin_user=""
ssh_key_file=""
location=eastus2

case "${1:-}" in
  what-if | create)
    mode=$1
    shift
    ;;
esac
while (($# > 0)); do
  case "$1" in
    --subscription | --admin-user | --ssh-key | --location)
      if (($# < 2)); then
        usage
        exit 2
      fi
      case "$1" in
        --subscription) subscription=$2 ;;
        --admin-user) admin_user=$2 ;;
        --ssh-key) ssh_key_file=$2 ;;
        --location) location=$2 ;;
      esac
      shift 2
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done
if [[ -z "$subscription" || -z "$admin_user" || -z "$ssh_key_file" ]]; then
  usage
  exit 2
fi

# Azure accepts ED25519 keys and RSA keys of 2048 bits or more. The text check
# keeps a private key file out; ssh-keygen proves the key itself parses.
ssh_key=$(<"$ssh_key_file")
key_bits=""
if [[ "$ssh_key" =~ ^(ssh-ed25519|ssh-rsa)\ [A-Za-z0-9+/=]+(\ [^[:cntrl:]]*)?$ ]]; then
  key_bits=$(ssh-keygen -l -f "$ssh_key_file" 2>/dev/null | awk 'NR == 1 { print $1 }') || key_bits=""
fi
if [[ ! "$key_bits" =~ ^[0-9]+$ ]] || [[ "$ssh_key" == ssh-rsa\ * && "$key_bits" -lt 2048 ]]; then
  printf 'deploy.sh: %s is not one ED25519 or RSA (2048 bits or more) public key.\n' "$ssh_key_file" >&2
  exit 1
fi

# cloud-init text is not secret, but these values land inside YAML, so accept
# only characters that cannot change its structure. A name has no "@", so it
# can never contain one of the template's own markers.
git_name=$(git config --global --includes --get user.name || true)
git_email=$(git config --global --includes --get user.email || true)
if [[ ! "$git_name" =~ ^[A-Za-z0-9][A-Za-z0-9\ ._+-]*$ || ! "$git_email" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*@[A-Za-z0-9.-]+$ ]]; then
  printf '%s\n' 'deploy.sh: set a plain global Git user.name and user.email first.' >&2
  exit 1
fi

revision=$(git -C "$here" rev-parse --verify 'HEAD^{commit}')
if [[ "$mode" == create ]]; then
  git -C "$here" fetch --quiet "$repository_url" main
  if ! git -C "$here" merge-base --is-ancestor "$revision" FETCH_HEAD; then
    printf 'deploy.sh: create from a commit that is on main of %s; the VM clones it from there.\n' "$repository_url" >&2
    exit 1
  fi
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
jq -n \
  --rawfile cloud_init "$here/cloud-init.yaml" \
  --arg git_name "$git_name" \
  --arg git_email "$git_email" \
  --arg revision "$revision" \
  --arg location "$location" \
  --arg admin_user "$admin_user" \
  --arg ssh_key "$ssh_key" \
  '{
    "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
    contentVersion: "1.0.0.0",
    parameters: {
      location: {value: $location},
      adminUsername: {value: $admin_user},
      adminSshPublicKey: {value: $ssh_key},
      cloudInit: {
        value: ($cloud_init
          | sub("@GIT_NAME@"; $git_name)
          | sub("@GIT_EMAIL@"; $git_email)
          | sub("@DOTFILES_REVISION@"; $revision))
      }
    }
  }' >"$work/parameters.json"

az deployment sub "$mode" \
  --subscription "$subscription" \
  --location "$location" \
  --name coordinator-vm \
  --template-file "$here/azuredeploy.json" \
  --parameters "@$work/parameters.json"
