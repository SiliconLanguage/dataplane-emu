#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

X="${DEMO_MOUNT_DIR:-/mnt/nvme_xfs}"
C="${DEMO_ARM_DIR:-/tmp/arm_neoverse}"
TMUX_SESSION="d"
RIGHT_PANE_PERCENT="${DEMO_RIGHT_PANE_PERCENT:-60}"

if ! [[ "$RIGHT_PANE_PERCENT" =~ ^[0-9]+$ ]] || [ "$RIGHT_PANE_PERCENT" -lt 35 ] || [ "$RIGHT_PANE_PERCENT" -gt 85 ]; then
    RIGHT_PANE_PERCENT=60
fi

require_cmd() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Missing required command: $cmd"
        exit 1
    fi
}

require_cmd sudo
require_cmd fio
require_cmd tmux
require_cmd lsblk
require_cmd findmnt
require_cmd readlink
require_cmd grep
require_cmd awk

# Accurately identify the non-root NVMe block device to benchmark.
ROOT_SRC=$(findmnt -n -o SOURCE / || true)
ROOT_DISK=$(lsblk -no PKNAME "$ROOT_SRC" 2>/dev/null | head -n 1 || true)
if [ -z "$ROOT_DISK" ]; then
    ROOT_DISK=$(basename "$ROOT_SRC" 2>/dev/null || true)
fi

DATA_DISK=$(lsblk -d -no NAME | grep -E '^nvme[0-9]+n1$' | grep -v "^${ROOT_DISK}$" | head -n 1 || true)
if [ -n "${DEMO_NVME_DEVICE:-}" ]; then
    D="$DEMO_NVME_DEVICE"
elif [ -n "$DATA_DISK" ]; then
    D="/dev/$DATA_DISK"
else
    D="/dev/nvme1n1"
fi

assert_safe_device() {
    local root_parent target_parent mounted

    if [ ! -b "$D" ]; then
        echo "Configured target device is not a block device: $D"
        exit 1
    fi

    root_parent=""
    if [[ "$ROOT_SRC" == /dev/* ]]; then
        root_parent=$(lsblk -no PKNAME "$ROOT_SRC" 2>/dev/null | head -n 1)
    fi

    target_parent=$(basename "$(readlink -f "$D")")
    if [ -n "$root_parent" ] && [ "$target_parent" = "$root_parent" ]; then
        echo "Refusing to run: target device $D appears to back the root filesystem ($ROOT_SRC)."
        exit 1
    fi

    mounted=$(lsblk -nr -o MOUNTPOINT "$D" | awk 'NF {print; exit}')
    if [ -n "$mounted" ]; then
        if [ "$mounted" = "$X" ]; then
            sudo umount -l "$X" >/dev/null 2>&1 || true
            mounted=$(lsblk -nr -o MOUNTPOINT "$D" | awk 'NF {print; exit}')
        fi

        if [ -n "$mounted" ]; then
            echo "Refusing to run: target device $D currently has mounted filesystems."
            echo "Found mountpoint: $mounted"
            exit 1
        fi
    fi
}

CONFIRM_FLAG="${ARM_NEOVERSE_DEMO_CONFIRM:-${COBALT_DEMO_CONFIRM:-}}"
if [ "$CONFIRM_FLAG" != "YES" ]; then
    echo "Safety interlock: this demo wipes and reformats $D."
    echo "If you are sure this is a disposable data disk, rerun with:"
    echo "  ARM_NEOVERSE_DEMO_CONFIRM=YES ./launch_arm_neoverse_demo.sh"
    echo "Optional overrides: DEMO_NVME_DEVICE=/dev/<data-disk> DEMO_RIGHT_PANE_PERCENT=70"
    exit 1
fi

assert_safe_device

# Identify the BDF (Bus:Device:Function) of the root OS volume.
ROOT_NVME_BDF=$(basename "$(readlink "/sys/class/block/${ROOT_DISK}/device/device" 2>/dev/null || true)" 2>/dev/null || true)
if [ -z "$ROOT_NVME_BDF" ] || [ "$ROOT_NVME_BDF" = "." ]; then
    ROOT_NVME_BDF=$(basename "$(readlink "/sys/class/block/${ROOT_DISK}/device" 2>/dev/null || true)" 2>/dev/null || true)
fi

# Explicitly block SPDK from hijacking the OS drive.
export PCI_BLOCKED="$ROOT_NVME_BDF nvme0"

# Dynamically determine the correct SPDK deployment directory for the cloud provider.
CPU_PART_HEX=$(grep -im1 "CPU part" /proc/cpuinfo | awk -F: '{print $2}' | tr -d " \t\n\r" | tr 'A-Z' 'a-z')
case "$CPU_PART_HEX" in
    "0xd49") SPDK_DIR="./spdk-azure" ;;
    *) SPDK_DIR="./spdk-aws" ;;
esac

mkdir -p "$C"
DISK_MN=$(cat "/sys/block/$(basename "$D")/device/model" 2>/dev/null | xargs)
if [ -n "$DISK_MN" ]; then
    echo "$DISK_MN" > /tmp/disk_model.txt
fi

# Clean up only demo-related processes and mounts.
sudo pkill -9 -x dataplane-emu 2>/dev/null || true
sudo pkill -f 'fio --name=base|fio --name=fuse' 2>/dev/null || true
sudo umount -l "$C" "$X" 2>/dev/null || true
sudo mkdir -p "$C" "$X"

spinner() {
    local pid=$1
    local msg="$2"
    local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0
    while kill -0 $pid 2>/dev/null; do
        i=$(( (i+1) % 10 ))
        printf "\r%s %s" "$msg" "${spin:$i:1}"
        sleep 0.1
    done
    printf "\r%s ✔ \n" "$msg"
}

progress_bar() {
    local pid=$1
    local msg="$2"
    local duration=$3
    local elapsed=0
    while kill -0 $pid 2>/dev/null; do
        local percent=$(( elapsed * 100 / duration ))
        if [ $percent -gt 99 ]; then percent=99; fi
        local filled=$(( percent / 5 ))
        local empty=$(( 20 - filled ))
        local bar=""
        [ $filled -gt 0 ] && bar=$(printf "%${filled}s" | tr ' ' '#')
        local space=""
        [ $empty -gt 0 ] && space=$(printf "%${empty}s" | tr ' ' '-')
        printf "\r%s [%s%s] %d%%" "$msg" "$bar" "$space" "$percent"
        sleep 1
        elapsed=$(( elapsed + 1 ))
    done
    local full_bar=$(printf "%20s" | tr ' ' '#')
    printf "\r%s [%s] 100%%\n" "$msg" "$full_bar"
}

(
sudo wipefs -a "$D" > /dev/null 2>&1
# 3. Safely run the SPDK setup, preserving the environment variable
sudo -E ${SPDK_DIR}/scripts/setup.sh reset > /dev/null 2>&1
sleep 2
) &
spinner $! "⚙️ Sanitizing Hardware..."

(
# Try mounting silently; if it fails (as expected), format silently and mount.
sudo mount "$D" "$X" > /dev/null 2>&1 || (sudo mkfs.xfs -f "$D" > /dev/null 2>&1 && sudo mount "$D" "$X" > /dev/null 2>&1)

sudo chown "$USER":"$USER" "$X"
sudo fio --name=base --directory="$X" --rw=randrw --bs=4k --size=2G --direct=1 --iodepth=256 --runtime=20 --time_based --group_reporting --output-format=json --output=x.json > /dev/null 2>&1
sudo umount -l "$X" > /dev/null 2>&1
sleep 2
) &
progress_bar $! "⚙️ Running Legacy Baseline (20s)..." 23

(
# Safely run the SPDK setup, preserving the environment variable
HUGEMEM=2048 sudo -E ${SPDK_DIR}/scripts/setup.sh > /dev/null 2>&1
sleep 3
) &
spinner $! "⚙️ Allocating Hugepages & Binding NVMe..."

echo "🚀 Launching Resilient Dashboard..."
tmux has-session -t "$TMUX_SESSION" 2>/dev/null && tmux kill-session -t "$TMUX_SESSION"
sleep 1

# Pane 0: Engine (Left) - Silences the harmless FUSE thread warning
tmux new-session -d -s "$TMUX_SESSION" "bash -c \"cd \\\"$SCRIPT_DIR\\\" && sudo ./build/dataplane-emu -m $C -b -k 2>&1 | grep --line-buffered -v 'Ignoring invalid max threads' ; sleep 15\""

# Pane 1: Worker (Right)
if ! tmux split-window -h -l "${RIGHT_PANE_PERCENT}%" -t "$TMUX_SESSION":0 "sleep 5 && cd \"$SCRIPT_DIR\" && ./arm_neoverse_worker.sh; echo ''; echo '--- Demo Complete. Press any key to Exit ---'; read -n 1 -s; tmux kill-session -t $TMUX_SESSION"; then
    tmux split-window -h -l "${RIGHT_PANE_PERCENT}%" -t "$TMUX_SESSION" "sleep 5 && cd \"$SCRIPT_DIR\" && ./arm_neoverse_worker.sh; echo ''; echo '--- Demo Complete. Press any key to Exit ---'; read -n 1 -s; tmux kill-session -t $TMUX_SESSION"
fi

tmux set-option -g mouse on
tmux attach-session -t "$TMUX_SESSION"
