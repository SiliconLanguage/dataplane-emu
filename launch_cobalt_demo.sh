#!/bin/bash
cd ~/dataplane-emu; rm -f x.json fuse.json 2>/dev/null
D="/dev/nvme0n1"; X="/mnt/nvme_xfs"; C="/tmp/cobalt"

sudo killall -9 dataplane-emu 2>/dev/null || true
sudo umount $C $X 2>/dev/null || true; mkdir -p $C $X

echo "⚙️ Resetting Hardware..."
sudo ./spdk/scripts/setup.sh reset > /dev/null; sleep 4

echo "⚙️ Running Legacy Baseline..."
sudo mount $D $X || (sudo mkfs.xfs -f $D && sudo mount $D $X)
sudo chown azureuser:azureuser $X
sudo fio --name=base --directory=$X --rw=randrw --bs=4k --size=50M --direct=1 --iodepth=32 --runtime=5 --group_reporting --output-format=json --output=x.json
sudo chmod 666 x.json; sudo umount $X

echo "⚙️ Allocating Hugepages..."
sudo HUGEMEM=2048 ./spdk/scripts/setup.sh > /dev/null

echo "🚀 Launching Resilient Dashboard..."
tmux kill-server 2>/dev/null || true
sleep 1
# Create session with a dummy window to ensure it stays open
tmux new-session -d -s d -n 'engine'
tmux set-option -g mouse on
tmux set-window-option -g remain-on-exit on

# Pane 1: Data Plane Engine
tmux send-keys -t d:0.0 "cd ~/dataplane-emu && sudo ./build/dataplane-emu -m $C -b -k" C-m

# Pane 2: Scorecard Worker
tmux split-window -h -t d:0.0
tmux send-keys -t d:0.1 "cd ~/dataplane-emu && ./cobalt_worker.sh" C-m

tmux attach-session -t d
