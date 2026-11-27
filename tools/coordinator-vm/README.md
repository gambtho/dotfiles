# Coordinator VM

One small always-on Linux VM in Azure that runs project coordinator sessions.
Everything needed to build it again is in this folder.

| File | What it is |
|---|---|
| `azuredeploy.json` | The Azure resources, as one subscription-level template |
| `deploy.sh` | Previews the template (`what-if`, the default) or creates it (`create`) |
| `cloud-init.yaml` | First boot: basic packages, a clone of this repository, `provision.sh` |
| `provision.sh` | Runs bootstrap and `dot-install` with the `server` profile, then enables the Herdr service |
| `coordinator-herdr.service` | User service that starts one Herdr session at boot |
| `dotfiles-keyring-unlock.service` | Template for the system service that unlocks the keyring at boot; `make keyring-seal` installs it |

## What gets created

- A resource group (`rg-coordinator`, or `--resource-group NAME`) holding everything below.
- An Ubuntu 24.04 LTS VM, `Standard_D4as_v5` (4 vCPU, 16 GB), with a 128 GB
  Premium SSD, Trusted Launch and encryption at host.
- A network interface with **no public IP**, and a security group whose only
  rule denies all inbound traffic.
- A NAT gateway with one public IP, for outbound traffic only. New Azure
  networks no longer give a VM outbound access by default, and the box needs to
  reach package mirrors, GitHub, Azure Relay and Tailscale. Nothing can connect
  inward through it.
- A system-assigned identity with no role assignments. The template contains
  none, and nothing here adds any.

There is no backup or snapshot. The VM is rebuilt from this folder, and the
state worth keeping (each project's coordinator folder) is pushed to Git.
Sign-ins, pairings and the lanes registry are redone on a rebuild.

A plain JSON template rather than Bicep or a script of `az` commands: `what-if`
can preview a template before the resource group exists, a script cannot, and
JSON needs no extra compiler on the machine that deploys. `az bicep decompile`
turns it into Bicep if you prefer that later.

## Before you create it

1. Sign in with `az login` to the tenant that owns the subscription.
2. Register encryption at host once per subscription, and wait for `Registered`:

   ```sh
   az feature register --subscription SUBSCRIPTION_ID --namespace Microsoft.Compute --name EncryptionAtHost
   az feature show --subscription SUBSCRIPTION_ID --namespace Microsoft.Compute --name EncryptionAtHost --query properties.state
   ```

3. Check the VM size is offered to your subscription in the region you want
   (`az vm list-skus --subscription SUBSCRIPTION_ID -l REGION --size Standard_D4as_v5 --all`). The default
   region is `eastus2`.
4. Make a new SSH key pair for the admin account and pass its **public** half
   to `deploy.sh`. The private key stays on your own machine; commit neither.

## Preview and create

```sh
bash tools/coordinator-vm/deploy.sh what-if --subscription SUBSCRIPTION_ID --ssh-key ~/.ssh/KEY.pub
bash tools/coordinator-vm/deploy.sh create  --subscription SUBSCRIPTION_ID --ssh-key ~/.ssh/KEY.pub
```

`what-if` changes nothing. The admin account is `tng`; `--admin-user NAME`
picks another, and then replaces `tng` in the SSH commands below.
`--resource-group NAME` (default `rg-coordinator`) and `--vm-name NAME`
(default `coordinator`) name the group and the VM; the commands below use the
defaults. Both modes first check, read-only, whether the group already exists,
and stop if it is in a region other than `--location`. Both read your global Git name and email and write
them into cloud-init, because bootstrap needs a Git identity. cloud-init is
stored with the VM and readable by anyone who can read the VM, so it holds no
secrets.

The VM checks out the commit your checkout is on, so `create` fetches the
public repository's `main` and refuses a commit that is not on it. On the VM, `~/.dotfiles` starts detached at that
commit; `git -C ~/.dotfiles switch main` when you want it to follow main.

## First boot

cloud-init takes a while (it builds language runtimes). Its log is
`/var/log/coordinator-provision.log`; `cloud-init status --long` shows the
result. Nothing below is automatic. **Lanes** marks a `lane` command; **Manual**
marks everything else.

### 1. Get a first shell (Manual)

The VM has no inbound path, so the first sign-in goes through Azure:

```sh
az vm run-command invoke --subscription SUBSCRIPTION_ID -g rg-coordinator -n coordinator --command-id RunShellScript \
  --scripts 'cloud-init status --long; tail -n 5 /var/log/coordinator-provision.log'
```

Repeat until it reports `status: done` and the log ends with "Provisioning
finished". Only then ask Tailscale for a sign-in link:

```sh
az vm run-command invoke --subscription SUBSCRIPTION_ID -g rg-coordinator -n coordinator --command-id RunShellScript \
  --scripts 'tailscale up --timeout 20s; tailscale status'
```

The output contains a Tailscale sign-in link. Open it, approve the machine,
then `ssh -i ~/.ssh/KEY tng@coordinator` over Tailscale, naming the private
half of the key you deployed. If the link
does not appear, use the Azure serial console instead; it needs a password on
the account first (portal: **Reset password**).

### 2. Sign in (Manual)

| Sign-in | Command |
|---|---|
| Tailscale | done in step 1 |
| GitHub | `make -C ~/.dotfiles keyring-init` in a human terminal if the login keyring is absent (`make -C ~/.dotfiles keyring-check`), then `gh auth login --hostname github.com --web --scopes read:public_key`, swapping `read:public_key` for a read-only scope no other machine uses (see "Signing in on more than one machine" in the top-level README) |
| Azure | `az login --use-device-code`, as yourself. Azure Relay needs a user sign-in; the VM's own identity has no roles |
| Claude Code | install it the way its documentation says, then run `claude` and sign in |

Your tenant may block device-code sign-in. If `az login --use-device-code` is
refused, sign in with the browser on your own machine through a forwarded port:

1. On the VM, run `BROWSER=echo az login`. With no browser to open, it prints
   the sign-in address instead and waits.
2. Find `redirect_uri=http%3A%2F%2Flocalhost%3APORT` in that address. The port
   changes every time.
3. In a second terminal on your own machine, forward that port:
   `ssh -i ~/.ssh/KEY -N -L PORT:localhost:PORT tng@coordinator`.
4. Open the printed address in your own browser and sign in. The last
   redirect, to `localhost:PORT`, now reaches `az` on the VM.

### 3. Install lanes and start a fresh registry

- **Manual:** install `developerlanes` from its main branch with its documented
  installer, including the Relay extra.
- **Lanes:** `lane doctor`. The registry is the default `~/.developerlanes`;
  do not copy one from another machine.
- **Manual:** clone the first project's coordinator folder from its private
  repository. Coordinator folders only: no code clones or worktrees on this box.
- **Lanes:** `lane init` in that folder.

### 4. Let your own machine reach the VM over Azure Relay

- **Manual:** create two Hybrid Connections in your Relay namespace, both with
  client authorization required: `coordinator-owner-ssh` and
  `coordinator-task-status`. Give your user Azure Relay Listener and Azure
  Relay Sender on each connection, not on the namespace.
- **Lanes**, on the VM, inside the Herdr session: preview, read it, then repeat
  with `--yes`.

  ```sh
  lane machine setup coordinator --relay-id OWNER_SSH_CONNECTION_ARM_ID --tenant TENANT_ID \
    --status-relay sb://NAMESPACE.servicebus.windows.net/coordinator-task-status \
    --subscription SUBSCRIPTION_ID --project PROJECT
  ```

- **Manual:** make a new client key on your own machine, copy its public half
  to the VM, and compare fingerprints over a channel you trust.
- **Lanes**, on the VM: `lane machine pair --client-key client-key.pub --fingerprint SHA256:...`
  writes an offer. **Manual:** copy the offer back.
- **Lanes**, on your machine: `lane machine pair coordinator --from worker-offer.json --identity /path/to/client-key --fingerprint SHA256:...`,
  then `lane connect coordinator --check`, then `lane connect coordinator`.

### 5. Save your workers on the VM

For each worker the coordinators will use:

- **Lanes:** `lane host add WORKER --relay sb://.../STATUS_CONNECTION --tenant TENANT_ID --subscription SUBSCRIPTION_ID`,
  and again with `--start` and with `--answer --owner-identity /path/to/key`
  for the grants you want this box to hold.
- **Manual:** the answer key is a new key made on the VM. Its public half must
  be trusted on each worker (`lane machine pair --client-key ... --answer` there).
  Never copy a private key between machines.
- **Lanes:** `lane --host WORKER status PROJECT` to check.

### 6. Herdr

`provision.sh` already enabled `coordinator-herdr.service`, and cloud-init
enabled lingering, so the session starts at boot without a login.
**Manual:** `systemctl --user status coordinator-herdr.service` to confirm.
Its panes start with `DOTFILES_KEYRING_PROMPT=0`, so they never stop at the keyring prompt after a restart.

**Manual, once:** after `gh auth login`, run `make -C ~/.dotfiles keyring-seal`
(types the keyring password once, uses sudo), then `sudo reboot` and check
`make -C ~/.dotfiles keyring-check` and `gh api user --jq .login` without
unlocking. From then on the keyring unlocks itself at every boot; see "Unattended
unlock at boot" in the top-level README for what it protects and how to undo it.
If it fails, `systemctl status dotfiles-keyring-unlock` says why and
`make -C ~/.dotfiles keyring-unlock` still works by hand.
The unlock runs alongside the user services, so Herdr can restore panes a few
seconds before it finishes. A `gh` or `git push` in that window exits with the
locked-keyring error; run it again once `make -C ~/.dotfiles keyring-check` passes.
Use one workspace per project coordinator.

### 7. Move projects one at a time

Move one project first and run it for a few days before the next. A project
moves only when every machine it uses is a lanes worker. Its coordinator folder
keeps pushing to its private repository; that push is the only off-box copy.

## Rebuild or remove

- **Rebuild:** delete the VM and run `deploy.sh create` again; the template is
  incremental. The OS disk goes with the VM, so the registry, pairings and
  every sign-in and the sealed keyring password are gone: redo "First boot" from step 1. Push each coordinator
  folder first. Before signing the new VM in to Tailscale, remove the old
  `coordinator` device in the Tailscale admin console, or the new one is named
  `coordinator-1`. The new VM also has a new SSH host key: run
  `ssh-keygen -R coordinator` on your own machine, and compare the fingerprint
  SSH then offers with `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` run
  through `az vm run-command invoke`.
- **Removal:** delete the resource group.

### Build a replacement beside the old one

To move the coordinator to another region, build the new VM first and keep the
old one until the new one works. Give the new one its own resource group:
group names ignore case, so the default `rg-coordinator` is the old VM's group,
and `deploy.sh` refuses it in another region.

```sh
bash tools/coordinator-vm/deploy.sh what-if --subscription SUBSCRIPTION_ID --ssh-key ~/.ssh/KEY.pub \
  --location westus3 --resource-group rg-coordinator-westus3
bash tools/coordinator-vm/deploy.sh create  --subscription SUBSCRIPTION_ID --ssh-key ~/.ssh/KEY.pub \
  --location westus3 --resource-group rg-coordinator-westus3
```

The preview should list only new resources in `rg-coordinator-westus3`. Then
follow "First boot" with `-g rg-coordinator-westus3` in the `run-command`
lines. The new VM is a separate machine: it needs its own sign-ins, registry
and pairings.

The VM name can stay `coordinator`, but the old VM keeps that name in Tailscale
until you remove it, so the new one joins under another name, usually
`coordinator-1`: use the name the Tailscale admin console shows for SSH meanwhile. Once the old VM is gone, delete its resource group
and its Tailscale device, then rename the new device to `coordinator` in the
Tailscale admin console. `--vm-name` gives the new VM a different name instead,
for good.

## Not tested yet

No VM has been created from this. cloud-init passes `cloud-init schema`, and
`what-if` accepts the template, but first boot, `dot-install` on a clean
Ubuntu server, the Tailscale sign-in link through run-command and the
forwarded-port sign-in have not run for real. Expect to fix something on the first build.
