#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

X="${DEMO_MOUNT_DIR:-/mnt/nvme_xfs}"
C="${DEMO_ARM_DIR:-/tmp/arm_neoverse}"
RUNTIME="${DEMO_RUNTIME_SEC:-30}"
IODEPTH="${DEMO_IODEPTH:-128}"
BS="${DEMO_BS:-4k}"
SIZE="${DEMO_SIZE:-4G}"
RWMIXREAD="${DEMO_RWMIXREAD:-50}"
STAGE3_DRIVER="${DEMO_STAGE3_DRIVER:-vfio-pci}"

BASE_LOG="/tmp/arm_neoverse_base.log"
BRIDGE_LOG="/tmp/arm_neoverse_fuse.log"
SPDK_SETUP_LOG="/tmp/arm_neoverse_spdk_setup.log"
BDEV_LOG="/tmp/arm_neoverse_bdevperf.log"
ENGINE_LOG="/tmp/arm_neoverse_engine.log"
BUILD_LOG="/tmp/arm_neoverse_bdevperf_build.log"
ENGINE_PID=""
ORIGINAL_STAGE3_DRIVER=""
STAGE3_REBOUND=0

require_cmd() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Missing required command: $cmd"
        exit 1
    fi
}

for cmd in sudo fio jq awk bc findmnt lsblk readlink grep timeout modprobe; do
    require_cmd "$cmd"
done

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
    if [ -n "$mounted" ] && [ "$mounted" != "$X" ]; then
        echo "Refusing to run: target device $D currently has mounted filesystems."
        echo "Found mountpoint: $mounted"
        exit 1
    fi
}

CONFIRM_FLAG="${ARM_NEOVERSE_DEMO_CONFIRM:-${COBALT_DEMO_CONFIRM:-}}"
if [ "$CONFIRM_FLAG" != "YES" ]; then
    echo "Safety interlock: this demo wipes and reformats $D."
    echo "Rerun with: ARM_NEOVERSE_DEMO_CONFIRM=YES ./launch_arm_neoverse_demo_deterministic.sh"
    exit 1
fi

assert_safe_device

extract_bdf_from_path() {
    local p="$1"
    echo "$p" | grep -Eo '([0-9a-fA-F]{4}:)?[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-7]' | tail -n 1 || true
}

resolve_nvme_bdf() {
    local blk="$1"
    local cand path bdf

    for cand in \
        "/sys/class/block/${blk}/device/device" \
        "/sys/class/block/${blk}/device" \
        "/sys/class/nvme/$(basename "$(readlink -f "/sys/class/block/${blk}/device" 2>/dev/null || echo /dev/null)")/device"; do
        path="$(readlink -f "$cand" 2>/dev/null || true)"
        if [ -n "$path" ]; then
            bdf="$(extract_bdf_from_path "$path")"
            if [ -n "$bdf" ]; then
                echo "$bdf"
                return 0
            fi
        fi
    done

    # Azure NVMe may expose controller at /sys/class/block/<blk>/device -> ../../nvmeX.
    path="$(readlink -f "/sys/class/block/${blk}/device" 2>/dev/null || true)"
    bdf="$(extract_bdf_from_path "$path")"
    if [ -n "$bdf" ]; then
        echo "$bdf"
        return 0
    fi

    return 1
}

TARGET_BDF="$(resolve_nvme_bdf "$(basename "$D")" || true)"
if [ -z "$TARGET_BDF" ]; then
    echo "Could not determine PCI BDF for $D"
    echo "Hint: readlink -f /sys/class/block/$(basename "$D")/device"
    exit 1
fi

ROOT_NVME_BDF=$(basename "$(readlink "/sys/class/block/${ROOT_DISK}/device/device" 2>/dev/null || true)" 2>/dev/null || true)
if [ -z "$ROOT_NVME_BDF" ] || [ "$ROOT_NVME_BDF" = "." ]; then
    ROOT_NVME_BDF=$(basename "$(readlink "/sys/class/block/${ROOT_DISK}/device" 2>/dev/null || true)" 2>/dev/null || true)
fi
export PCI_BLOCKED="$ROOT_NVME_BDF nvme0"

SPDK_SETUP=""
for candidate in "./spdk/scripts/setup.sh" "./spdk-azure/scripts/setup.sh" "./spdk-aws/scripts/setup.sh"; do
    if [ -f "$candidate" ]; then
        SPDK_SETUP="$candidate"
        break
    fi
done
if [ -z "$SPDK_SETUP" ]; then
    echo "Missing SPDK setup script. Checked: ./spdk/scripts/setup.sh, ./spdk-azure/scripts/setup.sh, ./spdk-aws/scripts/setup.sh"
    exit 1
fi

locate_bdevperf() {
    local candidate
    for candidate in "./spdk/build/bin/bdevperf" "./spdk/build/examples/bdevperf" "./spdk/test/bdev/bdevperf/bdevperf"; do
        if [ -x "$candidate" ]; then
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

BDEVPERF_BIN="${DEMO_BDEVPERF_BIN:-}"
if [ -z "$BDEVPERF_BIN" ]; then
    BDEVPERF_BIN="$(locate_bdevperf || true)"
fi
if [ -z "$BDEVPERF_BIN" ]; then
    if [ "${DEMO_AUTOBUILD_BDEVPERF:-1}" = "1" ]; then
        echo "bdevperf not found, attempting auto-build..."
        : > "$BUILD_LOG"
        JOBS="$(command -v nproc >/dev/null 2>&1 && nproc || echo 4)"
        (
            cd ./spdk
            make -j"$JOBS" bdevperf || make -j"$JOBS" app/bdevperf || make -j"$JOBS"
        ) >> "$BUILD_LOG" 2>&1 || true
        BDEVPERF_BIN="$(locate_bdevperf || true)"
    fi

    if [ -z "$BDEVPERF_BIN" ]; then
        echo "Missing bdevperf binary after auto-build attempt."
        echo "Set DEMO_BDEVPERF_BIN=/absolute/path/to/bdevperf"
        echo "Build log: $BUILD_LOG"
        exit 1
    fi
fi

echo "=== Deterministic ARM Neoverse Demo ==="
echo "Target device: $D"
echo "Target PCI BDF: $TARGET_BDF"
echo "SPDK setup: $SPDK_SETUP"
echo "bdevperf: $BDEVPERF_BIN"
echo "Logs: $BASE_LOG $BRIDGE_LOG $SPDK_SETUP_LOG $BDEV_LOG $ENGINE_LOG"
if [ -f "$BUILD_LOG" ]; then
    echo "Build log: $BUILD_LOG"
fi

current_pci_driver() {
    local bdf="$1"
    local link
    link="$(readlink "/sys/bus/pci/devices/${bdf}/driver" 2>/dev/null || true)"
    if [ -z "$link" ]; then
        echo "none"
        return 0
    fi
    basename "$link"
}

restore_stage3_driver() {
    if [ -z "$ORIGINAL_STAGE3_DRIVER" ]; then
        return 0
    fi

    if [ -e "/sys/bus/pci/devices/${TARGET_BDF}/driver_override" ]; then
        echo "" | sudo tee "/sys/bus/pci/devices/${TARGET_BDF}/driver_override" >/dev/null || true
    fi
    if [ -e "/sys/bus/pci/drivers/${STAGE3_DRIVER}/unbind" ]; then
        echo "$TARGET_BDF" | sudo tee "/sys/bus/pci/drivers/${STAGE3_DRIVER}/unbind" >/dev/null || true
    fi
    if [ -e "/sys/bus/pci/drivers/${ORIGINAL_STAGE3_DRIVER}/bind" ]; then
        echo "$TARGET_BDF" | sudo tee "/sys/bus/pci/drivers/${ORIGINAL_STAGE3_DRIVER}/bind" >/dev/null || true
    else
        echo "$TARGET_BDF" | sudo tee "/sys/bus/pci/drivers_probe" >/dev/null || true
    fi
}

ensure_userspace_stage3_driver() {
    local current_driver

    current_driver="$(current_pci_driver "$TARGET_BDF")"
    if [ -z "$current_driver" ]; then
        echo "Could not determine current PCI driver for $TARGET_BDF"
        exit 1
    fi
    if [ "$current_driver" = "vfio-pci" ] || [ "$current_driver" = "uio_pci_generic" ]; then
        return 0
    fi

    ORIGINAL_STAGE3_DRIVER="$current_driver"
    echo "Stage 3 requires a user-space driver; rebinding $TARGET_BDF from $current_driver to $STAGE3_DRIVER"
    sudo modprobe "$STAGE3_DRIVER"
    STAGE3_REBOUND=1

    if [ -e "/sys/bus/pci/devices/${TARGET_BDF}/driver_override" ]; then
        echo "$STAGE3_DRIVER" | sudo tee "/sys/bus/pci/devices/${TARGET_BDF}/driver_override" >/dev/null
    fi
    if [ "$current_driver" != "none" ] && [ -e "/sys/bus/pci/drivers/${current_driver}/unbind" ]; then
        echo "$TARGET_BDF" | sudo tee "/sys/bus/pci/drivers/${current_driver}/unbind" >/dev/null
    fi
    if [ -e "/sys/bus/pci/drivers/${STAGE3_DRIVER}/bind" ]; then
        if ! echo "$TARGET_BDF" | sudo tee "/sys/bus/pci/drivers/${STAGE3_DRIVER}/bind" >/dev/null; then
            echo "Stage 3 bind command failed for $TARGET_BDF -> $STAGE3_DRIVER"
        fi
    fi
    if [ "$(current_pci_driver "$TARGET_BDF")" = "none" ]; then
        echo "$TARGET_BDF" | sudo tee "/sys/bus/pci/drivers_probe" >/dev/null || true
    fi

    current_driver="$(current_pci_driver "$TARGET_BDF")"
    if [ "$current_driver" != "$STAGE3_DRIVER" ]; then
        echo "Stage 3 strict PCIe attach failed: $TARGET_BDF is bound to ${current_driver:-none}, expected $STAGE3_DRIVER"
        echo "Check /sys/bus/pci/devices/${TARGET_BDF}/driver and $SPDK_SETUP_LOG"
        restore_stage3_driver
        exit 1
    fi
}

cleanup() {
    if [ -n "${ENGINE_PID:-}" ]; then
        sudo kill -TERM "$ENGINE_PID" >/dev/null 2>&1 || true
        wait "$ENGINE_PID" 2>/dev/null || true
    fi
    restore_stage3_driver
    sudo pkill -9 -x dataplane-emu >/dev/null 2>&1 || true
    sudo umount -l "$C" >/dev/null 2>&1 || true
    sudo umount -l "$X" >/dev/null 2>&1 || true
}
trap cleanup EXIT

sudo mkdir -p "$X" "$C"

: > "$BASE_LOG"
: > "$BRIDGE_LOG"
: > "$SPDK_SETUP_LOG"
: > "$BDEV_LOG"
: > "$ENGINE_LOG"
: > x.json
: > fuse.json

echo "[Stage 0] Sanitize and reset SPDK"
sudo wipefs -a "$D" >> "$BASE_LOG" 2>&1
sudo -E bash "$SPDK_SETUP" reset >> "$SPDK_SETUP_LOG" 2>&1

echo "[Stage 1] Kernel baseline fio (filesystem path)"
if ! sudo mount "$D" "$X" >> "$BASE_LOG" 2>&1; then
    sudo mkfs.xfs -f "$D" >> "$BASE_LOG" 2>&1
    sudo mount "$D" "$X" >> "$BASE_LOG" 2>&1
fi
sudo chown "$USER":"$USER" "$X"
sudo fio --name=base --directory="$X" --rw=randrw --bs="$BS" --size="$SIZE" --direct=1 --iodepth="$IODEPTH" --runtime="$RUNTIME" --time_based --group_reporting --output-format=json --output=x.json >> "$BASE_LOG" 2>&1
sudo umount -l "$X" >> "$BASE_LOG" 2>&1

echo "[Stage 2] User-space bridge fio (strict readiness probe)"
HUGEMEM=2048 sudo -E bash "$SPDK_SETUP" >> "$SPDK_SETUP_LOG" 2>&1
sudo ./build/dataplane-emu -m "$C" -b -k > "$ENGINE_LOG" 2>&1 &
ENGINE_PID=$!

ready=0
for _ in $(seq 1 30); do
    if [ -e "$C/nvme_raw_0" ] && timeout 2 sudo dd if="$C/nvme_raw_0" of=/dev/null bs=4k count=1 iflag=direct status=none 2>/dev/null; then
        ready=1
        break
    fi
    sleep 1
done
if [ "$ready" -ne 1 ]; then
    echo "Bridge readiness probe failed: $C/nvme_raw_0 was not readable within 30s"
    echo "--- Engine log tail ---"
    tail -n 60 "$ENGINE_LOG"
    exit 1
fi

BRIDGE_FILE_BYTES=$(stat -c '%s' "$C/nvme_raw_0" 2>/dev/null || echo 0)
if [ "$BRIDGE_FILE_BYTES" -le 0 ]; then
    echo "Could not determine bridge file size for $C/nvme_raw_0"
    exit 1
fi

# Use bridge capacity by default to avoid EIO when requested size exceeds virtual file size.
BRIDGE_SIZE_BYTES="${DEMO_BRIDGE_SIZE_BYTES:-$BRIDGE_FILE_BYTES}"
if ! echo "$BRIDGE_SIZE_BYTES" | grep -Eq '^[0-9]+$'; then
    echo "DEMO_BRIDGE_SIZE_BYTES must be an integer byte value"
    exit 1
fi
if [ "$BRIDGE_SIZE_BYTES" -gt "$BRIDGE_FILE_BYTES" ]; then
    BRIDGE_SIZE_BYTES="$BRIDGE_FILE_BYTES"
fi
echo "Bridge fio size: ${BRIDGE_SIZE_BYTES} bytes (file capacity: ${BRIDGE_FILE_BYTES})"

sudo fio --name=fuse --filename="$C/nvme_raw_0" --rw=randrw --bs="$BS" --size="$BRIDGE_SIZE_BYTES" --direct=1 --iodepth="$IODEPTH" --runtime="$RUNTIME" --time_based --group_reporting --output-format=json --output=fuse.json >> "$BRIDGE_LOG" 2>&1

XERR=$(jq -r '(.jobs[0].error//0)' x.json | awk '{print int($1+0)}')
FERR=$(jq -r '(.jobs[0].error//0)' fuse.json | awk '{print int($1+0)}')
if [ "$XERR" -ne 0 ] || [ "$FERR" -ne 0 ]; then
    echo "fio error detected (baseline=$XERR bridge=$FERR)"
    exit 1
fi

echo "[Stage 3] Real SPDK bdevperf run (no synthetic bypass math)"
ensure_userspace_stage3_driver
BDEV_CFG="/tmp/arm_neoverse_bdevperf.json"
cat > "$BDEV_CFG" <<EOF
{
  "subsystems": [
    {
      "subsystem": "bdev",
      "config": [
        {
          "method": "bdev_nvme_attach_controller",
          "params": {
            "name": "Nvme0",
            "trtype": "PCIe",
            "traddr": "$TARGET_BDF"
          }
        }
      ]
    }
  ]
}
EOF

if ! sudo "$BDEVPERF_BIN" -c "$BDEV_CFG" -q "$IODEPTH" -o 4096 -w randrw -M "$RWMIXREAD" -t "$RUNTIME" > "$BDEV_LOG" 2>&1; then
        echo "bdevperf stage failed"
        tail -n 120 "$BDEV_LOG"
        exit 1
fi

XL=$(jq -r '((.jobs[0].read.clat_ns.mean//0)+(.jobs[0].write.clat_ns.mean//0))/2000' x.json | awk '{printf "%.2f", $1+0}')
XI=$(jq -r '(.jobs[0].read.iops//0)+(.jobs[0].write.iops//0)' x.json | awk '{printf "%.0f", $1+0}')
FL=$(jq -r '((.jobs[0].read.clat_ns.mean//0)+(.jobs[0].write.clat_ns.mean//0))/2000' fuse.json | awk '{printf "%.2f", $1+0}')
FI=$(jq -r '(.jobs[0].read.iops//0)+(.jobs[0].write.iops//0)' fuse.json | awk '{printf "%.0f", $1+0}')

BI=$( (grep -Eo '([0-9]+\.?[0-9]*)[[:space:]]*IOPS' "$BDEV_LOG" | tail -n 1 | awk '{printf "%.0f", $1+0}') || true )
BL=$( (grep -Eo '([0-9]+\.?[0-9]*)[[:space:]]*usec' "$BDEV_LOG" | tail -n 1 | awk '{printf "%.2f", $1+0}') || true )
if [ -z "$BI" ] || [ "$BI" = "0" ] || [ -z "$BL" ] || [ "$BL" = "0.00" ]; then
    TOTAL_NUMS=$( (grep -E '^[[:space:]]*Total[[:space:]]*:' "$BDEV_LOG" | tail -n 1 | grep -Eo '[0-9]+(\.[0-9]+)?') || true )
    if [ -n "$TOTAL_NUMS" ]; then
        [ -z "$BI" ] || [ "$BI" = "0" ] && BI=$(echo "$TOTAL_NUMS" | sed -n '1p' | awk '{printf "%.0f", $1+0}')
        [ -z "$BL" ] || [ "$BL" = "0.00" ] && BL=$(echo "$TOTAL_NUMS" | sed -n '5p' | awk '{printf "%.2f", $1+0}')
    fi
fi
if [ -z "$BI" ]; then BI="N/A"; fi
if [ -z "$BL" ]; then BL="N/A"; fi

echo "=========================================================================="
echo "  DETERMINISTIC SILICON DATA PLANE SCORECARD"
echo "=========================================================================="
echo "  Stage 3 driver: $STAGE3_DRIVER"
printf "%-25s | %-12s | %-12s\n" "Architecture" "Latency (us)" "IOPS"
echo "--------------------------------------------------------------------------"
printf "%-25s | %-12s | %-12s\n" "1. Legacy Kernel" "$XL" "$XI"
printf "%-25s | %-12s | %-12s\n" "2. User-Space Bridge" "$FL" "$FI"
printf "%-25s | %-12s | %-12s\n" "3. Zero-Copy (bdevperf)" "$BL" "$BI"
echo "=========================================================================="
echo "Baseline log: $BASE_LOG"
echo "Bridge log:   $BRIDGE_LOG"
echo "SPDK log:     $SPDK_SETUP_LOG"
echo "bdevperf log: $BDEV_LOG"
