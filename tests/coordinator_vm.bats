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
  printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeKeyForTestsOnly000000000000000000000000 test\n' >"$TEST_ROOT/key.pub"
}

stub_deploy_tools() {
  # Keep the rendered parameters: deploy.sh removes its own copy on exit.
  stub_command az '
printf "%s\n" "$*" >>"$CALLS"
for arg in "$@"; do
  case "$arg" in @*) cp "${arg#@}" "$TEST_ROOT/parameters.json" ;; esac
done'
  stub_command git '
case "$*" in
  *user.name*) printf "%s\n" "${GIT_NAME-Test Person}" ;;
  *user.email*) printf "%s\n" "${GIT_EMAIL-test@example.com}" ;;
esac'
}

@test "the VM has no public IP and the only security rule denies all inbound" {
  run jq -e '
    (map(select(.type == "Microsoft.Network/networkInterfaces")) | length == 1
      and all(.[].properties.ipConfigurations[]; .properties | has("publicIPAddress") | not))
    and (map(select(.type == "Microsoft.Network/networkSecurityGroups")) | length == 1
      and (.[0].properties.securityRules | length == 1
        and .[0].properties.direction == "Inbound"
        and .[0].properties.access == "Deny"
        and .[0].properties.sourceAddressPrefix == "*"
        and .[0].properties.destinationPortRange == "*"))
  ' <<<"$(resources)"
  [ "$status" -eq 0 ]
}

@test "the one public IP belongs to the outbound NAT gateway" {
  run jq -e '
    (map(select(.type == "Microsoft.Network/publicIPAddresses")) | length == 1)
    and (map(select(.type == "Microsoft.Network/natGateways"))[0].properties.publicIpAddresses | length == 1)
    and (map(select(.type == "Microsoft.Network/virtualNetworks"))[0].properties.subnets
      | all(.properties.defaultOutboundAccess == false and (.properties.natGateway.id | length > 0)))
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

@test "the identity gets no role grants and the template takes no secrets" {
  run jq -e 'all(.[]; .type | test("roleAssignments|roleDefinitions"; "i") | not)' <<<"$(resources)"
  [ "$status" -eq 0 ]
  run jq -e '[.. | objects | select(.type? == "securestring" or .type? == "secureObject")] | length == 0' "$TEMPLATE"
  [ "$status" -eq 0 ]
}

@test "the VM is backed up weekly" {
  run jq -e '
    (map(select(.type == "Microsoft.RecoveryServices/vaults/backupPolicies"))[0].properties
      | .schedulePolicy.scheduleRunFrequency == "Weekly"
        and (.schedulePolicy.weeklySchedule.scheduleRunDays | length == 1))
    and (map(select(.type | endswith("/protectedItems"))) | length == 1)
  ' <<<"$(resources)"
  [ "$status" -eq 0 ]
}

@test "cloud-init carries no secrets and hands off to the provision script" {
  # The only match allowed is the comment that says there are none.
  run bash -c 'rg -i "password|passwd|token|authkey|secret|private key" "$1" | rg -v "No secrets here"' _ "$SRC/cloud-init.yaml"
  [ -z "$output" ]
  run rg -c 'tools/coordinator-vm/provision.sh' "$SRC/cloud-init.yaml"
  [ "$output" = 1 ]
  [ "$(head -n 1 "$SRC/cloud-init.yaml")" = "#cloud-config" ]
  # deploy.sh fills exactly these two values.
  [ "$(rg -o '@[A-Z_]+@' "$SRC/cloud-init.yaml" | sort | tr '\n' ' ')" = "@GIT_EMAIL@ @GIT_NAME@ " ]
}

@test "deploy previews by default and never creates unless asked" {
  stub_deploy_tools
  write_public_key
  run bash "$SRC/deploy.sh" --subscription sub-id --admin-user admin --ssh-key "$TEST_ROOT/key.pub"
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$CALLS")" -eq 1 ]
  grep -q '^deployment sub what-if --subscription sub-id --location eastus2 ' "$CALLS"
  run jq -r '.parameters | .adminUsername.value, .location.value, (.adminSshPublicKey.value | split(" ")[0])' "$TEST_ROOT/parameters.json"
  [ "$output" = $'admin\neastus2\nssh-ed25519' ]
  run jq -r '.parameters.cloudInit.value' "$TEST_ROOT/parameters.json"
  [[ "$output" == *"name = Test Person"* ]]
  [[ "$output" == *"email = test@example.com"* ]]
  [[ "$output" != *"@GIT_"* ]]
}

@test "deploy creates only when the mode says create" {
  stub_deploy_tools
  write_public_key
  run bash "$SRC/deploy.sh" create --subscription sub-id --admin-user admin --ssh-key "$TEST_ROOT/key.pub" --location westus3
  [ "$status" -eq 0 ]
  grep -q '^deployment sub create --subscription sub-id --location westus3 ' "$CALLS"
}

@test "deploy refuses a private key, an unsafe Git identity and missing options" {
  stub_deploy_tools
  write_public_key
  printf '%s\n' '-----BEGIN OPENSSH PRIVATE KEY-----' 'AAAA' '-----END OPENSSH PRIVATE KEY-----' >"$TEST_ROOT/key"
  run bash "$SRC/deploy.sh" --subscription sub-id --admin-user admin --ssh-key "$TEST_ROOT/key"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not a single SSH public key"* ]]

  GIT_NAME='Bad: "name"' run bash "$SRC/deploy.sh" --subscription sub-id --admin-user admin --ssh-key "$TEST_ROOT/key.pub"
  [ "$status" -eq 1 ]
  GIT_EMAIL='' run bash "$SRC/deploy.sh" --subscription sub-id --admin-user admin --ssh-key "$TEST_ROOT/key.pub"
  [ "$status" -eq 1 ]

  run bash "$SRC/deploy.sh" create --admin-user admin --ssh-key "$TEST_ROOT/key.pub"
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

  run bash "$checkout/tools/coordinator-vm/provision.sh" "$TEST_ROOT/identity"
  [ "$status" -eq 0 ]
  [ "$(cat "$CALLS")" = "bootstrap --non-interactive --profile server global=$TEST_ROOT/identity
dot-install
systemctl --user daemon-reload
systemctl --user enable --now coordinator-herdr.service" ]
  cmp "$SRC/coordinator-herdr.service" "$XDG_CONFIG_HOME/systemd/user/coordinator-herdr.service"

  # A rerun after bootstrap wrote the local identity no longer needs the file.
  : >"$CALLS"
  touch "$checkout/core/git/gitconfig.local.symlink"
  run bash "$checkout/tools/coordinator-vm/provision.sh" "$TEST_ROOT/identity"
  [ "$status" -eq 0 ]
  grep -Fxq 'bootstrap --non-interactive --profile server global=' "$CALLS"
}
