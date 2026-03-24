#!/bin/bash
echo "--- Step 1: Installing SPDK Dependencies ---"
if [ ! -d "spdk" ]; then
    git clone https://github.com/spdk/spdk --recursive
fi
cd spdk
sudo ./scripts/pkgdep.sh --all

echo "--- Step 2: Building SPDK for ARM64 (Cobalt 100) ---"
./configure
make -j$(nproc)

echo "--- Step 3: Configuring Hugepages (2GB) ---"
sudo HUGEMEM=2048 ./scripts/setup.sh

echo "--- Step 4: Binding Azure NVMe to Userspace ---"
sudo ./scripts/setup.sh
