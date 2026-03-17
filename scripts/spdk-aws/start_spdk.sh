#!/bin/bash

# Navigate to the SPDK directory
cd /home/ec2-user/project/spdk

echo "1. Re-allocating hugepages and binding the Nitro NVMe..."
sudo HUGEMEM=2048 ./scripts/setup.sh

echo "2. Starting the SPDK target on Core 1..."
sudo LD_LIBRARY_PATH=$PWD/build/lib ./build/bin/spdk_tgt -m 0x2 -s 512 &

# Give the target 2 seconds to fully initialize
sleep 2

echo "3. Attaching the hardware to create Nvme0n1..."
sudo ./scripts/rpc.py bdev_nvme_attach_controller -b Nvme0 -t pcie -a 0000:00:1f.0

echo "Done! Verify below:"
sudo ./scripts/rpc.py bdev_get_bdevs -b Nvme0n1