#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"
# Accurately identify the non-root NVMe block device to benchmark
ROOT_DISK=$(lsblk -no pkname $(findmnt -no SOURCE /) | head -n1 2>/dev/null || echo "nvme0n1")
D=$(lsblk -d -no NAME | grep "^nvme[0-9]*n1$" | grep -v "$ROOT_DISK" | head -n 1)

if [ -n "$D" ]; then
    D="/dev/$D"
else
    D="/dev/nvme1n1"
fi

# 1. Identify the BDF (Bus:Device:Function) of the root EBS/OS volume
# Extract the true PCI BDF (e.g., 0000:00:04.0) instead of the NVMe namespace
ROOT_NVME_BDF=$(basename $(readlink /sys/class/block/${ROOT_DISK}/device/device 2>/dev/null) 2>/dev/null)
if [ -z "$ROOT_NVME_BDF" ] || [ "$ROOT_NVME_BDF" = "." ]; then
    ROOT_NVME_BDF=$(basename $(readlink /sys/class/block/${ROOT_DISK}/device 2>/dev/null) 2>/dev/null)
fi

# 2. Explicitly block SPDK from hijacking the OS drive
export PCI_BLOCKED="$ROOT_NVME_BDF nvme0"

X="/mnt/nvme_xfs"
C="/tmp/cobalt"

mkdir -p $C
DISK_MN=$(cat /sys/block/$(basename $D)/device/model 2>/dev/null | xargs)
if [ -n "$DISK_MN" ]; then
    echo "$DISK_MN" > /tmp/disk_model.txt
fi

# 1. Clean up everything silently
sudo killall -9 dataplane-emu fio 2>/dev/null || true
sudo umount -l $C $X 2>/dev/null || true
sudo mkdir -p $C $X

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
sudo wipefs -a $D > /dev/null 2>&1
# 3. Safely run the SPDK setup, preserving the environment variable
sudo -E ./spdk/scripts/setup.sh reset > /dev/null 2>&1
sleep 2
) &
spinner $! "⚙️ Sanitizing Hardware..."

(
# Try mounting silently; if it fails (as expected), format silently and mount.
sudo mount $D $X > /dev/null 2>&1 || (sudo mkfs.xfs -f $D > /dev/null 2>&1 && sudo mount $D $X > /dev/null 2>&1)

sudo chown $USER:$USER $X
sudo fio --name=base --directory=$X --rw=randrw --bs=4k --size=2G --direct=1 --iodepth=256 --runtime=20 --time_based --group_reporting --output-format=json --output=x.json > /dev/null 2>&1
sudo umount -l $X > /dev/null 2>&1
sleep 2
) &
progress_bar $! "⚙️ Running Legacy Baseline (20s)..." 23

(
# Safely run the SPDK setup, preserving the environment variable
HUGEMEM=2048 sudo -E ./spdk/scripts/setup.sh > /dev/null 2>&1
sleep 3
) &
spinner $! "⚙️ Allocating Hugepages & Binding NVMe..."

echo "🚀 Launching Resilient Dashboard..."
tmux kill-session -t d 2>/dev/null || true
sleep 1

# Pane 0: Engine (Left) - Silences the harmless FUSE thread warning
tmux new-session -d -s d "bash -c \"cd \\\"$SCRIPT_DIR\\\" && sudo ./build/dataplane-emu -m $C -b -k 2>&1 | grep --line-buffered -v 'Ignoring invalid max threads' ; sleep 15\""

# Pane 1: Worker (Right)
tmux split-window -h -t d:0.0 "sleep 5 && cd \"$SCRIPT_DIR\" && ./cobalt_worker.sh; echo ''; echo '--- Demo Complete. Press any key to Exit ---'; read -n 1 -s; tmux kill-session -t d"

tmux set-option -g mouse on
tmux attach-session -t d
