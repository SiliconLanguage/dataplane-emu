#!/usr/bin/env bash
#
# Diagnostic script to check why the FUSE bridge benchmark fails
#
set -u

echo "=== FUSE Bridge Diagnostic ==="
echo ""

echo "1. Checking if dataplane-emu is running..."
if pgrep -x dataplane-emu >/dev/null 2>&1; then
    echo "   ✅ dataplane-emu is running"
    pgrep -a dataplane-emu
else
    echo "   ❌ dataplane-emu is NOT running"
fi
echo ""

echo "2. Checking for FUSE mount points..."
if mount | grep -i fuse; then
    echo "   ✅ FUSE mounts found"
else
    echo "   ❌ No FUSE mounts detected"
fi
echo ""

echo "3. Checking /tmp/arm_neoverse/ directory..."
if [ -d /tmp/arm_neoverse ]; then
    echo "   ✅ Directory exists"
    ls -la /tmp/arm_neoverse/
else
    echo "   ❌ Directory does not exist"
fi
echo ""

echo "4. Checking for nvme_raw_0 device file..."
if [ -e /tmp/arm_neoverse/nvme_raw_0 ]; then
    echo "   ✅ Device file exists"
    file /tmp/arm_neoverse/nvme_raw_0
    stat /tmp/arm_neoverse/nvme_raw_0
else
    echo "   ❌ Device file does not exist"
fi
echo ""

echo "5. Testing raw device access with dd..."
if [ -e /tmp/arm_neoverse/nvme_raw_0 ]; then
    echo "   Attempting to read first 4KB..."
    sudo dd if=/tmp/arm_neoverse/nvme_raw_0 of=/dev/null bs=4K count=1 2>&1 | head -5
else
    echo "   ❌ Cannot test: device file missing"
fi
echo ""

echo "6. Checking /dev/nvme device status..."
lsblk -d | grep nvme
echo ""

echo "7. Checking for recent fuse.json..."
if [ -f fuse.json ]; then
    echo "   ✅ fuse.json exists"
    echo "   Size: $(wc -c < fuse.json) bytes"
    head -50 fuse.json
else
    echo "   ❌ fuse.json does not exist"
fi
echo ""

echo "8. Checking dataplane-emu binary..."
if [ -x ./build/dataplane-emu ]; then
    echo "   ✅ Binary exists and is executable"
    ./build/dataplane-emu --version 2>&1 || echo "   (no --version flag available)"
else
    echo "   ❌ Binary missing or not executable"
fi
echo ""

echo "=== END DIAGNOSTIC ==="
