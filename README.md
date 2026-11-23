# clone-vm.sh

Clone a KVM/QEMU virtual machine and give the copy its own identity.

## What it is for# clone-vm.sh

Clone a KVM/QEMU virtual machine and give the copy its own identity.

## What it is for

Anywhere you set one guest up properly and then want several of it.

- **General use — a template and its copies.** Prepare one VM the way you like
  it, with your packages, users and SSH keys, then stamp out copies that each
  boot as a machine of their own. Nothing to configure: a template name and a
  clone name is the whole command.
- **Lab and test fleets.** `-p client` numbers the clones `client1`,
  `client2`, and so on, taking the first free number, so another machine is one
  command away.
- **Fleets that report to a server.** Inventory and monitoring agents — GLPI,
  OCS Inventory, Zabbix — keep an identifier on disk. Clone them as they are
  and the whole fleet shows up as a single machine. `-d` wipes that state, and
  `-c` runs whatever registration the agent needs on first boot. See
  [Recipes](#recipes).
- **A single named server.** `-n web-02` plus a few `-c` commands: a static
  address, a patched config file, a service enabled, all applied the first time
  it boots.

Its job ends once the clone is on the network with an identity of its own;
how you configure it from there is up to you.

## The problem it solves

`virt-clone` copies the disk byte for byte, including `/etc/machine-id` and the
SSH host keys. Two clones of the same template are then indistinguishable on the
network:

- the DHCP server hands them the **same lease**, because many clients identify
  themselves by `machine-id` rather than by MAC address;
- SSH warns that the host key changed when you reach a different clone on the
  same address;
- inventory and monitoring agents report both machines under **one identity**.

This script runs `virt-sysprep` right after the clone, so every copy boots with
its own machine ID, its own SSH host keys and its own hostname.

## Requirements

| Tool | Debian / Ubuntu package |
|---|---|
| `virsh` | `libvirt-clients` |
| `virt-clone` | `virtinst` |
| `virt-sysprep` | `libguestfs-tools` |

```sh
sudo apt install libvirt-clients virtinst libguestfs-tools
```

The script must run as root, and **the VM you clone from must be shut off**.
It is read only as far as that VM is concerned: nothing is written to the
template, only to the new copy.

## Install

```sh
curl -O https://raw.githubusercontent.com/versidd/clone-vm/main/clone-vm.sh
chmod +x clone-vm.sh
```

## Usage

You always tell the script **which VM to clone** with `-t`. The name is the one
`virsh list --all` shows, not the label in a graphical tool.

```text
sudo ./clone-vm.sh -t TEMPLATE [-n NAME | -p PREFIX] [options]
```

### Naming the clone

You choose the names; nothing is hard-coded.

```sh
# Pick the exact name yourself
sudo ./clone-vm.sh -t debian-template -n db-replica-02

# Or auto-number from a prefix of your own:
# creates client1, then client2, then client3...
sudo ./clone-vm.sh -t debian-template -p client
```

With `-p`, the script takes the first free number, so deleting `client2` and
running it again fills that gap rather than jumping to `client4`. With neither
option, the clone is named after the template plus a number.

The name also becomes the clone's hostname, so it must be a valid host label:
letters, digits and hyphens, no leading or trailing hyphen.

### Options

| Option | Effect |
|---|---|
| `-t, --template NAME` | VM to clone from. Required, and must be shut off. |
| `-n, --name NAME` | Exact name for the clone. |
| `-p, --prefix PREFIX` | Auto-number from this prefix. |
| `-m, --max N` | Highest number tried when auto-numbering (default 50). |
| `-d, --delete PATH` | Extra file or glob to remove inside the clone. Repeatable. |
| `-k, --keep-user-keys` | Keep `~/.ssh`, so `authorized_keys` from the template still works. |
| `-c, --firstboot-command CMD` | Run CMD inside the clone on first boot. Repeatable. |
| `--no-ssh-keys` | Don't regenerate the SSH host keys. |
| `--no-sysprep` | Clone only, leave the identity duplicated. Not recommended. |
| `--no-start` | Leave the clone powered off. |
| `-y, --yes` | Skip the confirmation prompt. |
| `--dry-run` | Print the commands without running them. |
| `-h, --help` | Full help. |

### Agent state

Monitoring and inventory agents keep an identifier on disk. If you clone a
template that already has one installed, wipe that state too, or both machines
report as one:

```sh
sudo ./clone-vm.sh -t ubuntu-base -p node \
  -d '/var/lib/glpi-agent/*' \
  -d '/var/lib/zabbix/*'
```

## Recipes

Every lab needs something slightly different once the clone is up: an
inventory agent to register, a monitoring agent to rename, an address to pin.
Rather than ship a pile of variant scripts to download and splice together,
`clone-vm.sh` stays **one file** with one hook.

`-c, --firstboot-command` runs a command as root **inside the clone** on its
first boot, after the network is up. Repeat it for each step; they run in
order, and their output lands in `/var/log/virt-sysprep-firstboot.log` inside
the guest.

**GLPI inventory.** The agent stores a device id under `/var/lib/glpi-agent`;
leave it in place and every clone reports as the same asset. Wipe it, then
send the first inventory rather than waiting out the agent's random start
delay, which can be an hour:

```sh
sudo ./clone-vm.sh -t base -p client \
  -d '/var/lib/glpi-agent/*' \
  -c 'glpi-agent --force'
```

**Zabbix monitoring.** Name the monitored host after the clone:

```sh
sudo ./clone-vm.sh -t base -n web-02 \
  -c 'sed -i "s/^Hostname=.*/Hostname=$(hostname)/" /etc/zabbix/zabbix_agentd.conf' \
  -c 'systemctl restart zabbix-agent'
```

`$(hostname)` is evaluated in the guest, not on your host, so it picks up the
clone's own name.

**A static address** instead of DHCP, on a netplan guest:

```sh
sudo ./clone-vm.sh -t base -n srv-05 \
  -c 'sed -i "s|10.0.0.9/24|10.0.0.5/24|" /etc/netplan/01-lab.yaml' \
  -c 'netplan apply'
```

Anything else works the same way: install a package, patch a config, enable a
service.

## Config file

Once a recipe works, put it in `~/.config/clone-vm.conf` and you never type it
again — `sudo clone-vm.sh` on its own does the whole thing:

```sh
TEMPLATE="debian-template"
PREFIX="client"
EXTRA_DELETE=('/var/lib/glpi-agent/*')
FIRSTBOOT_COMMANDS=('glpi-agent --force')
```

Command-line options always win over the file, so a saved default never gets in
your way. Point `CLONE_VM_CONFIG` at another path to keep several profiles:

```sh
CLONE_VM_CONFIG=~/labs/web.conf sudo -E ./clone-vm.sh
```

## What the clone gets

- a new `machine-id`, so DHCP treats it as a new client
- fresh SSH host keys, regenerated on first boot
- its own hostname, written to `/etc/hostname` and to the `127.0.1.1` line of
  `/etc/hosts`
- cleared logs, shell history and stale DHCP leases
- anything passed with `--delete`

User accounts, installed packages and configuration are **kept**: that is the
point of a template.

### About SSH

`virt-sysprep` deletes the host keys in `/etc/ssh`, which is what you want:
two machines sharing a host key defeat the point of the key. But Debian and
Ubuntu do **not** regenerate them on their own. `sshd` fails its pre-start
check with no host key, the service stays down, and the clone answers
`Connection refused`.

The script therefore regenerates them on first boot (`ssh-keygen -A`), so SSH
is up without anything to do by hand on each clone.

User keys are a separate matter. By default `virt-sysprep` also clears the
`~/.ssh` directories, so an `authorized_keys` you set up on the template is
gone from the clone and you are back to a password. Pass `-k` to keep it:

```sh
sudo ./clone-vm.sh -t debian-template -p client -k
```

## Notes

- Tested with libvirt on Debian and Ubuntu guests. `virt-sysprep` supports many
  other guest types; see `virt-sysprep --list-operations`.
- `--auto-clone` lets libvirt place the new disk image next to the original, so
  make sure the storage pool has room for a full copy.
- If `virt-sysprep` fails with a permission error on `/boot/vmlinuz-*`, run
  `sudo chmod +r /boot/vmlinuz-*` on the host and try again.

## License

MIT


Anywhere you set one guest up properly and then want several of it.

- **General use — a template and its copies.** Prepare one VM the way you like
  it, with your packages, users and SSH keys, then stamp out copies that each
  boot as a machine of their own. Nothing to configure: a template name and a
  clone name is the whole command.
- **Lab and test fleets.** `-p client` numbers the clones `client1`,
  `client2`, and so on, taking the first free number, so another machine is one
  command away.
- **Fleets that report to a server.** Inventory and monitoring agents — GLPI,
  OCS Inventory, Zabbix — keep an identifier on disk. Clone them as they are
  and the whole fleet shows up as a single machine. `-d` wipes that state, and
  `-c` runs whatever registration the agent needs on first boot. See
  [Recipes](#recipes).
- **A single named server.** `-n web-02` plus a few `-c` commands: a static
  address, a patched config file, a service enabled, all applied the first time
  it boots.

It does not replace Ansible, Terraform or cloud-init. It is the step before
those: getting a usable, distinct machine onto the network.

## The problem it solves

`virt-clone` copies the disk byte for byte, including `/etc/machine-id` and the
SSH host keys. Two clones of the same template are then indistinguishable on the
network:

- the DHCP server hands them the **same lease**, because many clients identify
  themselves by `machine-id` rather than by MAC address;
- SSH warns that the host key changed when you reach a different clone on the
  same address;
- inventory and monitoring agents report both machines under **one identity**.

This script runs `virt-sysprep` right after the clone, so every copy boots with
its own machine ID, its own SSH host keys and its own hostname.

## Requirements

| Tool | Debian / Ubuntu package |
|---|---|
| `virsh` | `libvirt-clients` |
| `virt-clone` | `virtinst` |
| `virt-sysprep` | `libguestfs-tools` |

```sh
sudo apt install libvirt-clients virtinst libguestfs-tools
```

The script must run as root, and **the VM you clone from must be shut off**.
It is read only as far as that VM is concerned: nothing is written to the
template, only to the new copy.

## Install

```sh
curl -O https://raw.githubusercontent.com/versidd/clone-vm/main/clone-vm.sh
chmod +x clone-vm.sh
```

## Usage

You always tell the script **which VM to clone** with `-t`. The name is the one
`virsh list --all` shows, not the label in a graphical tool.

```sh
sudo ./clone-vm.sh -t TEMPLATE [-n NAME | -p PREFIX] [options]
```

### Naming the clone

You choose the names; nothing is hard-coded.

```sh
# Pick the exact name yourself
sudo ./clone-vm.sh -t debian-template -n db-replica-02

# Or auto-number from a prefix of your own:
# creates client1, then client2, then client3...
sudo ./clone-vm.sh -t debian-template -p client
```

With `-p`, the script takes the first free number, so deleting `client2` and
running it again fills that gap rather than jumping to `client4`. With neither
option, the clone is named after the template plus a number.

The name also becomes the clone's hostname, so it must be a valid host label:
letters, digits and hyphens, no leading or trailing hyphen.

### Options

| Option | Effect |
|---|---|
| `-t, --template NAME` | VM to clone from. Required, and must be shut off. |
| `-n, --name NAME` | Exact name for the clone. |
| `-p, --prefix PREFIX` | Auto-number from this prefix. |
| `-m, --max N` | Highest number tried when auto-numbering (default 50). |
| `-d, --delete PATH` | Extra file or glob to remove inside the clone. Repeatable. |
| `-k, --keep-user-keys` | Keep `~/.ssh`, so `authorized_keys` from the template still works. |
| `-c, --firstboot-command CMD` | Run CMD inside the clone on first boot. Repeatable. |
| `--no-ssh-keys` | Don't regenerate the SSH host keys. |
| `--no-sysprep` | Clone only, leave the identity duplicated. Not recommended. |
| `--no-start` | Leave the clone powered off. |
| `-y, --yes` | Skip the confirmation prompt. |
| `--dry-run` | Print the commands without running them. |
| `-h, --help` | Full help. |

### Agent state

Monitoring and inventory agents keep an identifier on disk. If you clone a
template that already has one installed, wipe that state too, or both machines
report as one:

```sh
sudo ./clone-vm.sh -t ubuntu-base -p node \
  -d '/var/lib/glpi-agent/*' \
  -d '/var/lib/zabbix/*'
```

## Recipes

Every lab needs something slightly different once the clone is up: an
inventory agent to register, a monitoring agent to rename, an address to pin.
Rather than ship a pile of variant scripts to download and splice together,
`clone-vm.sh` stays **one file** with one hook.

`-c, --firstboot-command` runs a command as root **inside the clone** on its
first boot, after the network is up. Repeat it for each step; they run in
order, and their output lands in `/var/log/virt-sysprep-firstboot.log` inside
the guest.

**GLPI inventory.** The agent stores a device id under `/var/lib/glpi-agent`;
leave it in place and every clone reports as the same asset. Wipe it, then
send the first inventory rather than waiting out the agent's random start
delay, which can be an hour:

```sh
sudo ./clone-vm.sh -t base -p client \
  -d '/var/lib/glpi-agent/*' \
  -c 'glpi-agent --force'
```

**Zabbix monitoring.** Name the monitored host after the clone:

```sh
sudo ./clone-vm.sh -t base -n web-02 \
  -c 'sed -i "s/^Hostname=.*/Hostname=$(hostname)/" /etc/zabbix/zabbix_agentd.conf' \
  -c 'systemctl restart zabbix-agent'
```

`$(hostname)` is evaluated in the guest, not on your host, so it picks up the
clone's own name.

**A static address** instead of DHCP, on a netplan guest:

```sh
sudo ./clone-vm.sh -t base -n srv-05 \
  -c 'sed -i "s|10.0.0.9/24|10.0.0.5/24|" /etc/netplan/01-lab.yaml' \
  -c 'netplan apply'
```

Anything else works the same way: install a package, patch a config, enable a
service.

## Config file

Once a recipe works, put it in `~/.config/clone-vm.conf` and you never type it
again — `sudo clone-vm.sh` on its own does the whole thing:

```sh
TEMPLATE="debian-template"
PREFIX="client"
EXTRA_DELETE=('/var/lib/glpi-agent/*')
FIRSTBOOT_COMMANDS=('glpi-agent --force')
```

Command-line options always win over the file, so a saved default never gets in
your way. Point `CLONE_VM_CONFIG` at another path to keep several profiles:

```sh
CLONE_VM_CONFIG=~/labs/web.conf sudo -E ./clone-vm.sh
```

## What the clone gets

- a new `machine-id`, so DHCP treats it as a new client
- fresh SSH host keys, regenerated on first boot
- its own hostname, written to `/etc/hostname` and to the `127.0.1.1` line of
  `/etc/hosts`
- cleared logs, shell history and stale DHCP leases
- anything passed with `--delete`

User accounts, installed packages and configuration are **kept**: that is the
point of a template.

### About SSH

`virt-sysprep` deletes the host keys in `/etc/ssh`, which is what you want:
two machines sharing a host key defeat the point of the key. But Debian and
Ubuntu do **not** regenerate them on their own. `sshd` fails its pre-start
check with no host key, the service stays down, and the clone answers
`Connection refused`.

The script therefore regenerates them on first boot (`ssh-keygen -A`), so SSH
is up without anything to do by hand on each clone.

User keys are a separate matter. By default `virt-sysprep` also clears the
`~/.ssh` directories, so an `authorized_keys` you set up on the template is
gone from the clone and you are back to a password. Pass `-k` to keep it:

```sh
sudo ./clone-vm.sh -t debian-template -p client -k
```

## Notes

- Tested with libvirt on Debian and Ubuntu guests. `virt-sysprep` supports many
  other guest types; see `virt-sysprep --list-operations`.
- `--auto-clone` lets libvirt place the new disk image next to the original, so
  make sure the storage pool has room for a full copy.
- If `virt-sysprep` fails with a permission error on `/boot/vmlinuz-*`, run
  `sudo chmod +r /boot/vmlinuz-*` on the host and try again.

## License

MIT
