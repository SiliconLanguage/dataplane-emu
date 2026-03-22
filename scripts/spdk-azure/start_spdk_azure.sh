#!/bin/bash
source "$(dirname "$0")/.env"

cd "$SPDK_DIR" || exit
echo "Allocating ${SPDK_HUGE_MEM}MB hugepages and binding NVMe..."
sudo HUGEMEM="$SPDK_HUGE_MEM" ./scripts/setup.sh

echo "Verifying Cobalt NVMe visibility..."
sudo ./build/bin/spdk_nvme_identify
