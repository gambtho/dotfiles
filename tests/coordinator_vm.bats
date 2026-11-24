#!/usr/bin/env bats

load test_helper

setup() {
  setup_dotfiles_test
  SRC="$REPO_ROOT/tools/coordinator-vm"
  TEMPLATE="$SRC/azuredeploy.json"
  export CALLS="$TEST_ROOT/calls"
  : >"$CALLS"
}

# Every resource in the template, at both scopes.
resources() {
  jq -c '[.resources[], (.resources[] | .properties.template.resources // [] | .[])]' "$TEMPLATE"
}

write_public_key() {
  ssh-keygen -q -t ed25519 -N '' -C test -f "$TEST_ROOT/key"
}

# A checkout cloned from a stand-in for the public repository.
make_checkout() {
  export PUBLISHED="$TEST_ROOT/published"
  CHECKOUT="$TEST_ROOT/checkout"
  git init -q -b main "$PUBLISHED"
  git -C "$PUBLISHED" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m base
  git clone -q "$PUBLISHED" "$CHECKOUT"
  mkdir -p "$CHECKOUT/tools"
  cp -R "$SRC" "$CHECKOUT/tools/coordinator-vm"
  DEPLOY="$CHECKOUT/tools/coordinator-vm/deploy.sh"
}

stub_deploy_tools() {
  # Keep the rendered parameters: deploy.sh removes its own copy on exit.
  stub_command az '
printf "%s\n" "$*" >>"$CALLS"
for arg in "$@"; do
  case "$arg" in @*) cp "${arg#@}" "$TEST_ROOT/parameters.json" ;; esac
done'
  # The identity lookups are stubbed, and a fetch of the public URL reads the
  # local stand-in instead. Everything else is real Git.
  stub_command git '
case "$*" in
  *"--get user.name") printf "%s\n" "${GIT_NAME-Test Person}" ;;
  *"--get user.email") printf "%s\n" "${GIT_EMAIL-test@example.com}" ;;
  *" ls-remote https://github.com/gambtho/dotfiles.git refs/heads/main")
    printf "ls-remote\n" >>"$CALLS"
    exec /usr/bin/git "$1" "$2" ls-remote "$PUBLISHED" refs/heads/main
    ;;
  *" fetch --quiet --no-write-fetch-head https://github.com/gambtho/dotfiles.git main")
    exec /usr/bin/git "$1" "$2" fetch --quiet --no-write-fetch-head "$PUBLISHED" main
    ;;
  # Anything else that would reach a network fails the test.
  *" fetch "* | *" ls-remote "* | *" clone "* | *" pull "* | *" push "*) exit 97 ;;
  *) exec /usr/bin/git "$@" ;;
esac'
  make_checkout
}

@test "the VM has no public IP and the only security rule denies all inbound" {
  run jq -e '
    (map(select(.type == "Microsoft.Network/networkInterfaces")) | length == 1
      and (.[0].properties.ipConfigurations | length == 1
        and (.[0].properties | has("publicIPAddress") | not)))
    and (map(select(.type == "Microsoft.Network/networkSecurityGroups")) | length == 1
      and (.[0].properties.securityRules | length == 1 and (.[0].properties
        | .direction == "Inbound" and .access == "Deny" and .protocol == "*"
          and .sourceAddressPrefix == "*" and .sourcePortRange == "*"
          and .destinationAddressPrefix == "*" and .destinationPortRange == "*")))
    and (map(select(.type == "Microsoft.Network/virtualNetworks"))[0].properties.subnets
      | length == 1 and (.[0].properties.networkSecurityGroup.id | contains("variables(\u0027nsgName\u0027)")))
  ' <<<"$(resources)"
  [ "$status" -eq 0 ]
}

@test "the one public IP belongs to the outbound NAT gateway" {
  run jq -e '
    (map(select(.type == "Microsoft.Network/publicIPAddresses")) | length == 1
      and .[0].name == "[variables(\u0027natIpName\u0027)]")
    and (map(select(.type == "Microsoft.Network/natGateways"))[0].properties.publicIpAddresses
      | length == 1 and (.[0].id | contains("variables(\u0027natIpName\u0027)")))
    and (map(select(.type == "Microsoft.Network/virtualNetworks"))[0].properties.subnets
      | length == 1 and (.[0].properties
        | .defaultOutboundAccess == false and (.natGateway.id | contains("variables(\u0027natName\u0027)"))))
  ' <<<"$(resources)"
  [ "$status" -eq 0 ]
}

@test "the VM matches the agreed shape" {
  run jq -e '
    map(select(.type == "Microsoft.Compute/virtualMachines")) | length == 1 and (.[0]
      | .identity.type == "SystemAssigned"
        and .properties.securityProfile.encryptionAtHost == true
        and .properties.storageProfile.imageReference.offer == "ubuntu-24_04-lts"
        and .properties.osProfile.linuxConfiguration.disablePasswordAuthentication == true)
  ' <<<"$(resources)"
  [ "$status" -eq 0 ]
  run jq -e '.parameters | .vmSize.defaultValue == "Standard_D4as_v5" and .osDiskSizeGB.defaultValue == 128' "$TEMPLATE"
  [ "$status" -eq 0 ]
}

@test "the template declares no role grants and no secret parameters" {
  run jq -e 'all(.[]; .type | test("roleAssignments|roleDefinitions"; "i") | not)' <<<"$(resources)"
  [ "$status" -eq 0 ]
  run jq -e '[.. | objects | select(.type? == "securestring" or .type? == "secureObject")] | length == 0' "$TEMPLATE"
  [ "$status" -eq 0 ]
}

@test "the VM is backed up weekly" {
  run jq -e '
    (map(select(.type == "Microsoft.RecoveryServices/vaults/backupPolicies"))[0].properties
      | .policyType == "V2"
        and .schedulePolicy.scheduleRunFrequency == "Weekly"
        and (.schedulePolicy.weeklySchedule.scheduleRunDays | length == 1))
    and (map(select(.type | endswith("/protectedItems"))) | length == 1 and (.[0].properties
      | (.sourceResourceId | contains("Microsoft.Compute/virtualMachines\u0027, parameters(\u0027vmName\u0027)"))
        and (.policyId | contains("variables(\u0027policyName\u0027)"))))
  ' <<<"$(resources)"
  [ "$status" -eq 0 ]
}

@test "cloud-init names no credential and hands off to the provision script" {
  # A keyword scan, not proof. The one allowed match is the comment saying so.
  run grep -ciE 'password|passwd|token|authkey|secret|private key' "$SRC/cloud-init.yaml"
  [ "$status" -eq 0 ]
  [ "$output" = 1 ]
  grep -q 'No secrets here' "$SRC/cloud-init.yaml"
  run grep -c 'tools/coordinator-vm/provision.sh' "$SRC/cloud-init.yaml"
  [ "$output" = 1 ]
  [ "$(head -n 1 "$SRC/cloud-init.yaml")" = "#cloud-config" ]
  # deploy.sh fills exactly these values.
  [ "$(grep -oE '@[A-Z_]+@' "$SRC/cloud-init.yaml" | sort | tr '\n' ' ')" = "@DOTFILES_REVISION@ @GIT_EMAIL@ @GIT_NAME@ " ]
}

@test "deploy previews by default and never creates unless asked" {
  stub_deploy_tools
  write_public_key
  run bash "$DEPLOY" --subscription sub-id --admin-user coordinatoradmin --ssh-key "$TEST_ROOT/key.pub"
  [ "$status" -eq 0 ]
  # No fetch and no second az call: a preview touches nothing.
  [ "$(wc -l <"$CALLS")" -eq 1 ]
  grep -q '^deployment sub what-if --subscription sub-id --location eastus2 ' "$CALLS"
  run jq -r '.parameters | .adminUsername.value, .location.value, (.adminSshPublicKey.value | split(" ")[0])' "$TEST_ROOT/parameters.json"
  [ "$output" = $'coordinatoradmin\neastus2\nssh-ed25519' ]
  run jq -r '.parameters.cloudInit.value' "$TEST_ROOT/parameters.json"
  [[ "$output" == *"name = Test Person"* ]]
  [[ "$output" == *"email = test@example.com"* ]]
  [[ "$output" == *"checkout --detach $(git -C "$CHECKOUT" rev-parse HEAD) &&"* ]]
  [ -z "$(grep -oE '@[A-Z_]+@' <<<"$output")" ]
}

@test "deploy creates only when the mode says create" {
  stub_deploy_tools
  write_public_key
  run bash "$DEPLOY" create --subscription sub-id --admin-user coordinatoradmin --ssh-key "$TEST_ROOT/key.pub" --location westus3
  [ "$status" -eq 0 ]
  [ "$(head -n 1 "$CALLS")" = ls-remote ]
  grep -q '^deployment sub create --subscription sub-id --location westus3 ' "$CALLS"
  # The script and cloud-init must name the same repository.
  grep -Fq 'git clone https://github.com/gambtho/dotfiles.git ' "$SRC/cloud-init.yaml"
}

@test "deploy refuses to create from a commit the public main does not have" {
  stub_deploy_tools
  write_public_key
  # On the checkout's own origin/main, as in a fork, but not on the public main.
  git -C "$CHECKOUT" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m unpublished
  git -C "$CHECKOUT" update-ref refs/remotes/origin/main HEAD
  run bash "$DEPLOY" create --subscription sub-id --admin-user coordinatoradmin --ssh-key "$TEST_ROOT/key.pub"
  [ "$status" -eq 1 ]
  [[ "$output" == *"on main of https://github.com/gambtho/dotfiles.git"* ]]
  [ "$(cat "$CALLS")" = ls-remote ]
  # A preview from the same commit is still allowed.
  run bash "$DEPLOY" what-if --subscription sub-id --admin-user coordinatoradmin --ssh-key "$TEST_ROOT/key.pub"
  [ "$status" -eq 0 ]
}

@test "deploy refuses unusable keys, an unsafe Git identity and missing options" {
  stub_deploy_tools
  write_public_key
  local key
  # The private half, a truncated key, an ECDSA key and a short RSA key.
  printf 'ssh-ed25519 AAAA test\n' >"$TEST_ROOT/truncated.pub"
  ssh-keygen -q -t ecdsa -N '' -f "$TEST_ROOT/ecdsa"
  ssh-keygen -q -t rsa -b 1024 -N '' -f "$TEST_ROOT/short"
  for key in key truncated.pub ecdsa.pub short.pub; do
    run bash "$DEPLOY" --subscription sub-id --admin-user coordinatoradmin --ssh-key "$TEST_ROOT/$key"
    [ "$status" -eq 1 ]
    [[ "$output" == *"is not one ED25519 or RSA"* ]]
  done

  GIT_NAME='Bad: "name"' run bash "$DEPLOY" --subscription sub-id --admin-user coordinatoradmin --ssh-key "$TEST_ROOT/key.pub"
  [ "$status" -eq 1 ]
  GIT_NAME='Alice @GIT_EMAIL@' run bash "$DEPLOY" --subscription sub-id --admin-user coordinatoradmin --ssh-key "$TEST_ROOT/key.pub"
  [ "$status" -eq 1 ]
  GIT_EMAIL='' run bash "$DEPLOY" --subscription sub-id --admin-user coordinatoradmin --ssh-key "$TEST_ROOT/key.pub"
  [ "$status" -eq 1 ]

  run bash "$DEPLOY" create --admin-user coordinatoradmin --ssh-key "$TEST_ROOT/key.pub"
  [ "$status" -eq 2 ]
  [ ! -s "$CALLS" ]
}

@test "provision bootstraps the server profile, installs, then enables the Herdr service" {
  local checkout="$HOME/.dotfiles"
  mkdir -p "$checkout/tools/coordinator-vm" "$checkout/libexec" "$checkout/bin" "$checkout/core/git"
  cp "$SRC/provision.sh" "$SRC/coordinator-herdr.service" "$checkout/tools/coordinator-vm/"
  printf '#!/usr/bin/env bash\nprintf "bootstrap %%s global=%%s\\n" "$*" "${GIT_CONFIG_GLOBAL:-}" >>"$CALLS"\n' >"$checkout/libexec/bootstrap"
  printf '#!/usr/bin/env bash\nprintf "dot-install\\n" >>"$CALLS"\n' >"$checkout/bin/dot-install"
  stub_command systemctl 'printf "systemctl %s\n" "$*" >>"$CALLS"'
  stub_command sleep ':'

  # dot-install can succeed without Herdr; provisioning must not.
  run bash "$checkout/tools/coordinator-vm/provision.sh" "$TEST_ROOT/identity"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Herdr was not installed"* ]]
  [ "$(tail -n 1 "$CALLS")" = dot-install ]

  : >"$CALLS"
  mkdir -p "$HOME/.local/bin"
  printf '#!/bin/sh\n[ "${HERDR_DOWN:-0}" != 1 ]\n' >"$HOME/.local/bin/herdr"
  chmod +x "$HOME/.local/bin/herdr"
  run bash "$checkout/tools/coordinator-vm/provision.sh" "$TEST_ROOT/identity"
  [ "$status" -eq 0 ]
  [ "$(cat "$CALLS")" = "bootstrap --non-interactive --profile server global=$TEST_ROOT/identity
dot-install
systemctl --user daemon-reload
systemctl --user enable --now coordinator-herdr.service" ]
  cmp "$SRC/coordinator-herdr.service" "$XDG_CONFIG_HOME/systemd/user/coordinator-herdr.service"

  HERDR_DOWN=1 run bash "$checkout/tools/coordinator-vm/provision.sh" "$TEST_ROOT/identity"
  [ "$status" -eq 1 ]
  [[ "$output" == *"did not answer"* ]]

  # A rerun after bootstrap wrote the local identity no longer needs the file.
  : >"$CALLS"
  touch "$checkout/core/git/gitconfig.local.symlink"
  run bash "$checkout/tools/coordinator-vm/provision.sh" "$TEST_ROOT/identity"
  [ "$status" -eq 0 ]
  grep -Fxq 'bootstrap --non-interactive --profile server global=' "$CALLS"
}
