#!/usr/bin/env bash
# tools/coordinator-vm/deploy.sh -- preview or create the coordinator VM.
#
# Usage: deploy.sh [what-if|create] --subscription ID --admin-user NAME --ssh-key FILE.pub [--location REGION]
#
# The default is what-if, which changes nothing in Azure. The Git name and
# email written into cloud-init come from this machine's global Git config.

set -euo pipefail

usage() {
  sed -n '4p' "${BASH_SOURCE[0]}" | cut -c3- >&2
}

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
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

ssh_key=$(<"$ssh_key_file")
if [[ ! "$ssh_key" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp[0-9]+)\ [A-Za-z0-9+/=]+(\ [^[:cntrl:]]*)?$ ]]; then
  printf 'deploy.sh: %s is not a single SSH public key.\n' "$ssh_key_file" >&2
  exit 1
fi

# cloud-init text is not secret, but these two values land inside YAML, so
# accept only characters that cannot change its structure.
git_name=$(git config --global --includes --get user.name || true)
git_email=$(git config --global --includes --get user.email || true)
safe='^[A-Za-z0-9][A-Za-z0-9 ._@+-]*$'
if [[ ! "$git_name" =~ $safe || ! "$git_email" =~ $safe ]]; then
  printf '%s\n' 'deploy.sh: set a plain global Git user.name and user.email first.' >&2
  exit 1
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
jq -n \
  --rawfile cloud_init "$here/cloud-init.yaml" \
  --arg git_name "$git_name" \
  --arg git_email "$git_email" \
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
      cloudInit: {value: ($cloud_init | sub("@GIT_NAME@"; $git_name) | sub("@GIT_EMAIL@"; $git_email))}
    }
  }' >"$work/parameters.json"

az deployment sub "$mode" \
  --subscription "$subscription" \
  --location "$location" \
  --name coordinator-vm \
  --template-file "$here/azuredeploy.json" \
  --parameters "@$work/parameters.json"
