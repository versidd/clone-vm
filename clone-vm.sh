#!/usr/bin/env bash

set -euo pipefail

VERSION="1.2.2"

# ---------------------------------------------------------------------
# Defaults — override on the command line or in the config file below.
# ---------------------------------------------------------------------

CONFIG_FILE="${CLONE_VM_CONFIG:-$HOME/.config/clone-vm.conf}"

TEMPLATE=""        # VM to clone from
CLONE_NAME=""      # exact name for the clone (skips auto-numbering)
PREFIX=""          # prefix for auto-numbered names, e.g. "client" -> client1
MAX_INDEX=50       # highest number tried when auto-numbering
DO_START=1         # start the clone when it is ready
DO_SYSPREP=1       # reset the clone's identity
ASSUME_YES=0       # skip the confirmation prompt
DRY_RUN=0          # print what would happen, change nothing
KEEP_USER_KEYS=0   # keep ~/.ssh (authorized_keys) inside the clone
REGEN_HOST_KEYS=1  # regenerate SSH host keys on first boot
EXTRA_DELETE=()    # extra paths to wipe inside the clone
FIRSTBOOT_COMMANDS=()  # commands to run inside the clone on first boot

CLI_NAME=0         # set when -n comes from the command line
CLI_PREFIX=0       # set when -p comes from the command line

# ---------------------------------------------------------------------

usage() {
    cat <<EOF
clone-vm.sh $VERSION — clone a KVM/QEMU VM and give the copy its own identity

USAGE
    sudo ./clone-vm.sh -t TEMPLATE [-n NAME | -p PREFIX] [options]

REQUIRED
    -t, --template NAME   Name of the VM to clone, as shown by
                          'virsh list --all'. This VM must be SHUT OFF.

NAMING (pick one)
    -n, --name NAME       Exact name for the clone, e.g. "web-02".
    -p, --prefix PREFIX   Auto-number from a prefix: with "client" the
                          script creates client1, then client2, and so on,
                          taking the first free number.

    With neither, the clone is named after the template plus a number.
    The name is also used as the clone's hostname, so it must contain
    only letters, digits and hyphens.

OPTIONS
    -m, --max N           Highest number to try when auto-numbering (default: $MAX_INDEX).
    -d, --delete PATH     Extra file or glob to remove inside the clone.
                          Repeatable. Useful for agent state that would
                          otherwise be duplicated, for example:
                            -d '/var/lib/glpi-agent/*'
                            -d '/etc/zabbix/zabbix_agentd.d/*'
    -k, --keep-user-keys  Keep the ~/.ssh directories, so authorized_keys
                          set up on the template still lets you log in
                          without a password. Host keys are regenerated
                          either way.
    -c, --firstboot-command CMD
                          Run CMD inside the clone on its first boot, once
                          the network is up. Repeatable, run in order. This
                          is the hook for whatever your own setup needs —
                          see RECIPES below.
        --no-ssh-keys     Do not regenerate the SSH host keys. Only for
                          guests that recreate them on their own; on Debian
                          and Ubuntu this leaves sshd dead.
        --no-sysprep      Clone only, do not reset identity. Not recommended.
        --no-start        Leave the clone powered off.
    -y, --yes             Do not ask for confirmation.
        --dry-run         Show the commands without running them.
    -h, --help            Show this help.
    -V, --version         Show the version.

CONFIG FILE
    Everything above can be preset in $CONFIG_FILE, so a
    setup you use often becomes a bare 'sudo clone-vm.sh':

        TEMPLATE="debian-template"
        PREFIX="client"
        EXTRA_DELETE=('/var/lib/glpi-agent/*')
        FIRSTBOOT_COMMANDS=('glpi-agent --force')

    Command-line options always win over the config file. Point
    CLONE_VM_CONFIG at another path to keep several profiles.

RECIPES
    The script stays one file; --firstboot-command is how you bolt your
    own setup onto it. Each command runs as root inside the clone, after
    the network is up, in the order given, and its output is kept in
    /var/log/virt-sysprep-firstboot.log.

    GLPI inventory — wipe the agent's device id so the clone is a new
    asset, then send the first inventory instead of waiting out the
    agent's random start delay:

        sudo ./clone-vm.sh -t base -p client \\
          -d '/var/lib/glpi-agent/*' \\
          -c 'glpi-agent --force'

    Zabbix monitoring — point the agent at the server and name the host
    after the clone:

        sudo ./clone-vm.sh -t base -n web-02 \\
          -c 'sed -i "s/^Hostname=.*/Hostname=\$(hostname)/" /etc/zabbix/zabbix_agentd.conf' \\
          -c 'systemctl restart zabbix-agent'

    Static address instead of DHCP, on a netplan guest:

        sudo ./clone-vm.sh -t base -n srv-05 \\
          -c 'sed -i "s|10.0.0.9/24|10.0.0.5/24|" /etc/netplan/01-lab.yaml' \\
          -c 'netplan apply'

    Anything else — a package to install, a config to patch, a service to
    enable — goes in the same way, or into FIRSTBOOT_COMMANDS in the
    config file so you never type it again.

EXAMPLES
    sudo ./clone-vm.sh -t debian-template -p client
    sudo ./clone-vm.sh -t debian-template -n db-replica-02
    sudo ./clone-vm.sh -t ubuntu-base -p node -d '/var/lib/glpi-agent/*'
    sudo ./clone-vm.sh -t ubuntu-base -p node --no-start --dry-run

WHAT THE CLONE GETS
    * a new machine-id, so DHCP treats it as a new client
    * fresh SSH host keys, regenerated on first boot, so sshd starts
      and the clone is reachable straight away
    * its own hostname, in /etc/hostname and in /etc/hosts
    * cleared logs, shell history and stale DHCP leases
    * any extra paths passed with --delete
EOF
}

die() { echo "Error: $*" >&2; exit 1; }
info() { echo "==> $*"; }

run() {
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '   [dry-run]'
        printf ' %q' "$@"
        printf '\n'
    else
        "$@"
    fi
}

# --- Config file ------------------------------------------------------

if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

# --- Arguments --------------------------------------------------------

while [ $# -gt 0 ]; do
    case "$1" in
        -t|--template) TEMPLATE="${2:-}"; shift 2 ;;
        -n|--name)     CLONE_NAME="${2:-}"; CLI_NAME=1; shift 2 ;;
        -p|--prefix)   PREFIX="${2:-}"; CLI_PREFIX=1; shift 2 ;;
        -m|--max)      MAX_INDEX="${2:-}"; shift 2 ;;
        -d|--delete)   EXTRA_DELETE+=("${2:-}"); shift 2 ;;
        -k|--keep-user-keys) KEEP_USER_KEYS=1; shift ;;
        -c|--firstboot-command) FIRSTBOOT_COMMANDS+=("${2:-}"); shift 2 ;;
        --no-ssh-keys) REGEN_HOST_KEYS=0; shift ;;
        --no-sysprep)  DO_SYSPREP=0; shift ;;
        --no-start)    DO_START=0; shift ;;
        -y|--yes)      ASSUME_YES=1; shift ;;
        --dry-run)     DRY_RUN=1; shift ;;
        -h|--help)     usage; exit 0 ;;
        -V|--version)  echo "clone-vm.sh $VERSION"; exit 0 ;;
        *)             die "unknown option '$1' (try --help)" ;;
    esac
done

# --- Preflight checks -------------------------------------------------

[ "$(id -u)" -eq 0 ] || die "run this script as root: sudo $0 ..."

command -v virsh      >/dev/null || die "virsh not found. Install it: apt install libvirt-clients"
command -v virt-clone >/dev/null || die "virt-clone not found. Install it: apt install virtinst"

if [ "$DO_SYSPREP" -eq 1 ]; then
    command -v virt-sysprep >/dev/null \
        || die "virt-sysprep not found. Install it: apt install libguestfs-tools (or use --no-sysprep)"
fi

[ -n "$TEMPLATE" ] || die "no template VM given. Use -t NAME (try --help)"

if ! virsh dominfo "$TEMPLATE" >/dev/null 2>&1; then
    echo "Template VM '$TEMPLATE' not found. Available VMs:" >&2
    virsh list --all >&2
    exit 1
fi

STATE=$(virsh domstate "$TEMPLATE")
if [ "$STATE" != "shut off" ]; then
    die "template VM '$TEMPLATE' is '$STATE'. Shut it down first: virsh shutdown $TEMPLATE"
fi

[[ "$MAX_INDEX" =~ ^[0-9]+$ ]] || die "--max must be a number"

# --- Work out the clone name -----------------------------------------

if [ "$CLI_NAME" -eq 1 ] && [ "$CLI_PREFIX" -eq 1 ]; then
    die "use either --name or --prefix, not both"
fi

# A name or prefix typed on the command line replaces the other one
# from the config file, so a saved PREFIX never blocks a one-off -n.
[ "$CLI_NAME" -eq 1 ] && PREFIX=""
[ "$CLI_PREFIX" -eq 1 ] && CLONE_NAME=""

if [ -n "$CLONE_NAME" ] && [ -n "$PREFIX" ]; then
    die "the config file sets both CLONE_NAME and PREFIX; keep only one"
fi

if [ -n "$CLONE_NAME" ]; then
    virsh dominfo "$CLONE_NAME" >/dev/null 2>&1 \
        && die "a VM named '$CLONE_NAME' already exists"
else
    base="${PREFIX:-$TEMPLATE}"
    CLONE_NAME=""
    for i in $(seq 1 "$MAX_INDEX"); do
        if ! virsh dominfo "${base}${i}" >/dev/null 2>&1; then
            CLONE_NAME="${base}${i}"
            break
        fi
    done
    [ -n "$CLONE_NAME" ] || die "no free name between ${base}1 and ${base}${MAX_INDEX}"
fi

# The name becomes the hostname, so keep it to a valid label.
if ! [[ "$CLONE_NAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; then
    die "'$CLONE_NAME' is not a valid hostname (letters, digits and hyphens only, no leading or trailing hyphen)"
fi

# --- Summary and confirmation ----------------------------------------

echo
echo "  Template : $TEMPLATE"
echo "  Clone    : $CLONE_NAME"
echo "  Sysprep  : $([ "$DO_SYSPREP" -eq 1 ] && echo yes || echo 'no (identity will be duplicated)')"
echo "  Start    : $([ "$DO_START" -eq 1 ] && echo yes || echo no)"
if [ "$DO_SYSPREP" -eq 1 ] && [ "$KEEP_USER_KEYS" -eq 1 ]; then
    echo "  Keeping  : ~/.ssh (authorized_keys)"
fi
if [ "$DO_SYSPREP" -eq 1 ] && [ "${#FIRSTBOOT_COMMANDS[@]}" -gt 0 ]; then
    echo "  On boot  :"
    for cmd in "${FIRSTBOOT_COMMANDS[@]}"; do
        echo "             $cmd"
    done
fi
if [ "${#EXTRA_DELETE[@]}" -gt 0 ]; then
    echo "  Delete   : ${EXTRA_DELETE[*]}"
fi
[ "$DRY_RUN" -eq 1 ] && echo "  Mode     : dry run, nothing will change"
echo

if [ "$ASSUME_YES" -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then
    # No terminal to answer (cron, a pipe): treat it as a no, not a crash.
    read -r -p "Proceed? [y/N] " answer || answer=""
    case "$answer" in
        [yY]|[yY][eE][sS]) ;;
        *) echo "Cancelled."; exit 0 ;;
    esac
fi

# --- 1. Clone ---------------------------------------------------------

info "Cloning '$TEMPLATE' into '$CLONE_NAME'"
run virt-clone --original "$TEMPLATE" --name "$CLONE_NAME" --auto-clone

# --- 2. Reset the clone's identity -----------------------------------

if [ "$DO_SYSPREP" -eq 1 ]; then
    info "Resetting identity (machine-id, SSH host keys, hostname, logs)"

    # virt-sysprep sets /etc/hostname, but some images keep the old name
    # on the 127.0.1.1 line of /etc/hosts. Fix it on first boot.
    FIRSTBOOT=$(mktemp)
    trap 'rm -f "$FIRSTBOOT"' EXIT
    cat > "$FIRSTBOOT" <<EOF
#!/bin/sh
# written by clone-vm.sh

# 1. Align /etc/hosts with the new hostname.
if grep -q '^127\.0\.1\.1' /etc/hosts; then
    sed -i "s/^127\.0\.1\.1.*/127.0.1.1 $CLONE_NAME/" /etc/hosts
else
    echo "127.0.1.1 $CLONE_NAME" >> /etc/hosts
fi

EOF

    if [ "$REGEN_HOST_KEYS" -eq 1 ]; then
        cat >> "$FIRSTBOOT" <<'EOF'

# 2. Regenerate the SSH host keys that virt-sysprep removed.
#    Debian and Ubuntu do not recreate them on their own: sshd fails its
#    pre-start check with no host key and the service stays down, which
#    leaves the clone unreachable over SSH. Without this the keys have to
#    be made by hand on every clone.
if [ -d /etc/ssh ] && ! ls /etc/ssh/ssh_host_*_key >/dev/null 2>&1; then
    ssh-keygen -A
    systemctl restart ssh 2>/dev/null \
        || systemctl restart sshd 2>/dev/null \
        || true
fi
EOF
    fi

    if [ "${#FIRSTBOOT_COMMANDS[@]}" -gt 0 ]; then
        # Wait for the network before running anything of the user's:
        # a first boot reaches this point before DHCP has answered.
        cat >> "$FIRSTBOOT" <<'EOF'

# 3. Wait for the network, then run the commands passed with
#    --firstboot-command, in order.
_wait=0
while [ $_wait -lt 30 ] && ! ip route 2>/dev/null | grep -q '^default'; do
    sleep 2
    _wait=$((_wait + 1))
done
sleep 5
EOF
        for cmd in "${FIRSTBOOT_COMMANDS[@]}"; do
            printf '%s\n' "$cmd" >> "$FIRSTBOOT"
        done
    fi

    chmod +x "$FIRSTBOOT"

    sysprep_args=(-d "$CLONE_NAME" --hostname "$CLONE_NAME" --firstboot "$FIRSTBOOT")
    if [ "$KEEP_USER_KEYS" -eq 1 ]; then
        # Keep ~/.ssh so authorized_keys from the template survives.
        sysprep_args+=(--operations 'defaults,-ssh-userdir')
    fi
    for path in "${EXTRA_DELETE[@]}"; do
        sysprep_args+=(--delete "$path")
    done

    run virt-sysprep "${sysprep_args[@]}"
else
    info "Skipping virt-sysprep (--no-sysprep)"
fi

# --- 3. Start ---------------------------------------------------------

if [ "$DO_START" -eq 1 ]; then
    info "Starting '$CLONE_NAME'"
    run virsh start "$CLONE_NAME"
fi

# --- Done -------------------------------------------------------------

echo
if [ "$DRY_RUN" -eq 1 ]; then
    echo "Dry run finished: nothing was changed."
    exit 0
fi
echo "Done. '$CLONE_NAME' is ready."
if [ "$DO_START" -eq 1 ] && [ "$DRY_RUN" -eq 0 ]; then
    echo
    echo "Give it a moment to boot, then find its address with:"
    echo "    virsh domifaddr $CLONE_NAME"
    if [ "${#FIRSTBOOT_COMMANDS[@]}" -gt 0 ]; then
        echo
        echo "First-boot commands log inside the guest to:"
        echo "    /var/log/virt-sysprep-firstboot.log"
    fi
fi
