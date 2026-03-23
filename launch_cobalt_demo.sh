#!/bin/bash
cd ~/dataplane-emu
D="/dev/nvme0n1"; X="/mnt/nvme_xfs"; C="/tmp/cobalt"

# 1. Clean up everything silently
sudo killall -9 dataplane-emu fio 2>/dev/null || true
sudo umount -l $C $X 2>/dev/null || true
mkdir -p $C $X

echo "⚙️ Sanitizing Hardware..."
sudo wipefs -a $D > /dev/null 2>&1
sudo ./spdk/scripts/setup.sh reset > /dev/null 2>&1
sleep 2

echo "⚙️ Running Legacy Baseline (20s)..."
# Try mounting silently; if it fails (as expected), format silently and mount.
sudo mount $D $X > /dev/null 2>&1 || (sudo mkfs.xfs -f $D > /dev/null 2>&1 && sudo mount $D $X > /dev/null 2>&1)

sudo chown azureuser:azureuser $X
sudo fio --name=base --directory=$X --rw=randrw --bs=4k --size=2G --direct=1 --iodepth=256 --runtime=20 --time_based --group_reporting --output-format=json --output=x.json > /dev/null 2>&1
sudo umount -l $X > /dev/null 2>&1
sleep 2

echo "⚙️ Allocating Hugepages & Binding NVMe..."
sudo HUGEMEM=2048 ./spdk/scripts/setup.sh > /dev/null 2>&1
sleep 3

echo "🚀 Launching Resilient Dashboard..."
tmux kill-server 2>/dev/null || true
sleep 1

# Pane 0: Engine (Left) - Silences the harmless FUSE thread warning
tmux new-session -d -s d "sudo ./build/dataplane-emu -m $C -b -k 2>&1 | grep --line-buffered -v 'Ignoring invalid max threads' || sleep 15"

# Pane 1: Worker (Right)
tmux split-window -h -t d:0.0 "sleep 5 && cd ~/dataplane-emu && ./cobalt_worker.sh; echo ''; echo '--- Demo Complete. Press Enter to Exit ---'; read"

tmux attach-session -t d
