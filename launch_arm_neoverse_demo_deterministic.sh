#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

X="${DEMO_MOUNT_DIR:-/mnt/nvme_xfs}"
C="${DEMO_ARM_DIR:-/tmp/arm_neoverse}"
RUNTIME="${DEMO_RUNTIME_SEC:-30}"
IODEPTH="${DEMO_IODEPTH:-128}"
IODEPTH_MID="${DEMO_MID_IODEPTH:-32}"
BS="${DEMO_BS:-4k}"
SIZE="${DEMO_SIZE:-4G}"
RWMIXREAD="${DEMO_RWMIXREAD:-50}"
SKIP_BUILD="${DEMO_SKIP_BUILD:-0}"

# ---------------------------------------------------------------------------
# Cloud provider detection (DMI-based, no network dependency)
# ---------------------------------------------------------------------------
SYS_VENDOR="$(cat /sys/devices/virtual/dmi/id/sys_vendor 2>/dev/null || true)"
PRODUCT_NAME="$(cat /sys/devices/virtual/dmi/id/product_name 2>/dev/null || true)"
CLOUD_PROVIDER="unknown"
if echo "$SYS_VENDOR $PRODUCT_NAME" | grep -Eqi 'microsoft|azure'; then
    CLOUD_PROVIDER="azure"
elif echo "$SYS_VENDOR $PRODUCT_NAME" | grep -Eqi 'amazon|ec2'; then
    CLOUD_PROVIDER="aws"
fi

# Stage 3 backend selection:
#   AWS  (Nitro)       → bdev_nvme via vfio-pci  (true PCIe bypass)
#   Azure (Boost/MANA) → bdev_uring via io_uring (mediated passthrough;
#                         vfio-pci cannot bind Azure's Hyper-V NVMe device)
if [ -n "${DEMO_STAGE3_DRIVER:-}" ]; then
    STAGE3_DRIVER="$DEMO_STAGE3_DRIVER"
elif [ "$CLOUD_PROVIDER" = "azure" ]; then
    STAGE3_DRIVER="kernel"   # keep kernel NVMe driver; use bdev_uring
else
    STAGE3_DRIVER="vfio-pci" # default: PCIe bypass
fi
STAGE3_MODE="pcie"  # "pcie" = bdev_nvme via vfio-pci, "uring" = bdev_uring
if [ "$STAGE3_DRIVER" = "kernel" ]; then
    STAGE3_MODE="uring"
fi

BASE_LOG="/tmp/arm_neoverse_base.log"
BRIDGE_LOG="/tmp/arm_neoverse_fuse.log"
SPDK_SETUP_LOG="/tmp/arm_neoverse_spdk_setup.log"
BDEV_LAT_LOG="/tmp/arm_neoverse_bdevperf_lat.log"
BDEV_MID_LOG="/tmp/arm_neoverse_bdevperf_mid.log"
BDEV_IOPS_LOG="/tmp/arm_neoverse_bdevperf_iops.log"
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

for cmd in sudo fio jq awk bc findmnt lsblk readlink grep timeout modprobe cmake make; do
    require_cmd "$cmd"
done

# =========================================================================
# Build Phase: ensure all binaries are ready before running the demo
# =========================================================================
install_build_deps() {
    echo "[Build] Checking build dependencies..."

    if command -v dnf &>/dev/null; then
        # Amazon Linux 2023 / RHEL / Fedora
        local pkgs_needed=()
        rpm -q gcc-c++        &>/dev/null || pkgs_needed+=(gcc-c++)
        rpm -q make            &>/dev/null || pkgs_needed+=(make)
        rpm -q cmake           &>/dev/null || pkgs_needed+=(cmake)
        rpm -q pkgconfig       &>/dev/null || pkgs_needed+=(pkgconfig)
        rpm -q fuse3-devel     &>/dev/null || pkgs_needed+=(fuse3-devel)
        rpm -q numactl-devel   &>/dev/null || pkgs_needed+=(numactl-devel)
        rpm -q libuuid-devel   &>/dev/null || pkgs_needed+=(libuuid-devel)
        rpm -q openssl-devel   &>/dev/null || pkgs_needed+=(openssl-devel)
        rpm -q libaio-devel    &>/dev/null || pkgs_needed+=(libaio-devel)
        rpm -q liburing-devel  &>/dev/null || pkgs_needed+=(liburing-devel)
        rpm -q jq              &>/dev/null || pkgs_needed+=(jq)
        rpm -q fio             &>/dev/null || pkgs_needed+=(fio)

        if [ ${#pkgs_needed[@]} -gt 0 ]; then
            echo "[Build] Installing missing packages: ${pkgs_needed[*]}"
            sudo dnf install -y "${pkgs_needed[@]}"
        else
            echo "[Build] All build dependencies satisfied"
        fi

    elif command -v apt-get &>/dev/null; then
        # Debian / Ubuntu
        local pkgs_needed=()
        dpkg -s build-essential  &>/dev/null || pkgs_needed+=(build-essential)
        dpkg -s pkg-config       &>/dev/null || pkgs_needed+=(pkg-config)
        dpkg -s libfuse3-dev     &>/dev/null || pkgs_needed+=(libfuse3-dev)
        dpkg -s libnuma-dev      &>/dev/null || pkgs_needed+=(libnuma-dev)
        dpkg -s uuid-dev         &>/dev/null || pkgs_needed+=(uuid-dev)
        dpkg -s libssl-dev       &>/dev/null || pkgs_needed+=(libssl-dev)
        dpkg -s libaio-dev       &>/dev/null || pkgs_needed+=(libaio-dev)
        dpkg -s liburing-dev     &>/dev/null || pkgs_needed+=(liburing-dev)

        if [ ${#pkgs_needed[@]} -gt 0 ]; then
            echo "[Build] Installing missing packages: ${pkgs_needed[*]}"
            sudo apt-get update -qq
            sudo apt-get install -y -qq "${pkgs_needed[@]}"
        else
            echo "[Build] All build dependencies satisfied"
        fi

    else
        echo "[Build] WARNING: Unknown package manager — skipping dependency install"
        echo "  Ensure gcc-c++, cmake, fuse3-devel, numactl-devel, libaio-devel are installed"
    fi
}

# Rebuild SPDK with io_uring if not already enabled
ensure_spdk_uring() {
    local spdk_dir="./spdk"
    local config_mk="$spdk_dir/mk/config.mk"

    if [ ! -f "$config_mk" ]; then
        echo "[Build] SPDK config not found — full SPDK build required"
        return 1
    fi

    # Check if io_uring is already enabled
    if grep -q 'CONFIG_URING?=y' "$config_mk" 2>/dev/null; then
        echo "[Build] SPDK already built with io_uring support"
        return 0
    fi

    # Only rebuild if liburing-dev is available
    if ! dpkg -s liburing-dev &>/dev/null; then
        echo "[Build] liburing-dev not available — skipping io_uring rebuild"
        return 0
    fi

    echo "[Build] Rebuilding SPDK with io_uring support..."
    # SPDK source tree may be root-owned (submodule clone); fix perms so
    # configure can write CONFIG.sh and mk/config.mk as the current user.
    local abs_spdk_dir
    abs_spdk_dir="$(cd "$spdk_dir" && pwd)"
    if [ "$(stat -c '%U' "$abs_spdk_dir/CONFIG")" != "$USER" ]; then
        echo "[Build] Fixing SPDK source tree ownership..."
        sudo chown -R "$USER":"$USER" "$abs_spdk_dir"
    fi
    pushd "$spdk_dir" > /dev/null
    PKG_CONFIG_PATH="$abs_spdk_dir/dpdk/build/lib/pkgconfig:${PKG_CONFIG_PATH:-}" \
        ./configure --with-dpdk --with-uring --target-arch=native
    JOBS="$(nproc)"
    make -j"$JOBS"
    popd > /dev/null
    echo "[Build] SPDK rebuild with io_uring complete"
}

# Build the dataplane-emu binary
ensure_dataplane_emu() {
    if [ -x "./build/dataplane-emu" ]; then
        echo "[Build] dataplane-emu binary exists"
        return 0
    fi
    echo "[Build] Building dataplane-emu..."
    mkdir -p build
    cd build && cmake .. && make -j"$(nproc)" && cd ..
}

if [ "$SKIP_BUILD" != "1" ]; then
    install_build_deps
    # ensure_spdk_uring is best-effort — SPDK may not be cloned yet.
    # Stage 3 will fail-fast later if bdevperf is unavailable.
    ensure_spdk_uring || echo "[Build] SPDK not available — Stage 3 will require manual SPDK setup"
    ensure_dataplane_emu
fi

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
    echo "[WARN] SPDK setup script not found — Stages 1 & 2 will run without SPDK."
    echo "       Stage 3 (bdevperf) will be skipped unless SPDK is cloned."
    echo "       Checked: ./spdk/scripts/setup.sh, ./spdk-azure/scripts/setup.sh, ./spdk-aws/scripts/setup.sh"
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
    if [ "${DEMO_AUTOBUILD_BDEVPERF:-1}" = "1" ] && [ -d "./spdk" ]; then
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
        echo "[WARN] bdevperf binary not found — Stage 3 will be skipped."
        echo "       To enable: clone SPDK, build it, then re-run."
    fi
fi

# SPDK shared libraries may be in non-standard paths after a local build
SPDK_LD_PATH="$SCRIPT_DIR/spdk/build/lib:$SCRIPT_DIR/spdk/dpdk/build/lib"
export LD_LIBRARY_PATH="$SPDK_LD_PATH:${LD_LIBRARY_PATH:-}"

echo "=== Deterministic ARM Neoverse Demo ==="
echo "Target device: $D"
echo "Target PCI BDF: $TARGET_BDF"
echo "SPDK setup: $SPDK_SETUP"
echo "bdevperf: $BDEVPERF_BIN"
echo "Logs: $BASE_LOG $BRIDGE_LOG $SPDK_SETUP_LOG $BDEV_LAT_LOG $BDEV_MID_LOG $BDEV_IOPS_LOG $ENGINE_LOG"
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
: > "$BDEV_LAT_LOG"
: > "$BDEV_MID_LOG"
: > "$BDEV_IOPS_LOG"
: > "$ENGINE_LOG"
for _qd in 1 "$IODEPTH_MID" "$IODEPTH"; do
    : > "x_qd${_qd}.json"
    : > "fuse_qd${_qd}.json"
done

echo "[Stage 0] Sanitize device"
sudo wipefs -a "$D" >> "$BASE_LOG" 2>&1
if [ -n "$SPDK_SETUP" ]; then
    echo "[Stage 0] Resetting SPDK PCI bindings"
    sudo -E bash "$SPDK_SETUP" reset >> "$SPDK_SETUP_LOG" 2>&1
fi

echo "[Stage 1] Kernel baseline fio (filesystem path)"
if ! sudo mount "$D" "$X" >> "$BASE_LOG" 2>&1; then
    sudo mkfs.xfs -f "$D" >> "$BASE_LOG" 2>&1
    sudo mount "$D" "$X" >> "$BASE_LOG" 2>&1
fi
sudo chown "$USER":"$USER" "$X"
for _qd in 1 "$IODEPTH_MID" "$IODEPTH"; do
    echo "  [Stage 1] Kernel fio QD=$_qd"
    sudo fio --name=base --directory="$X" --rw=randrw --bs="$BS" --size="$SIZE" \
        --ioengine=libaio --direct=1 --iodepth="$_qd" \
        --runtime="$RUNTIME" --time_based --group_reporting \
        --output-format=json --output="x_qd${_qd}.json" >> "$BASE_LOG" 2>&1
done
sudo umount -l "$X" >> "$BASE_LOG" 2>&1

echo "[Stage 2] User-space bridge fio (strict readiness probe)"
# The FUSE bridge uses pread/pwrite against the raw block device directly;
# hugepages are only needed for Stage 3 (SPDK).  Allocate them here only
# if the SPDK setup script is available, otherwise proceed without.
if [ -n "$SPDK_SETUP" ]; then
    HUGEMEM=2048 sudo -E bash "$SPDK_SETUP" >> "$SPDK_SETUP_LOG" 2>&1
fi
sudo ./build/dataplane-emu -m "$C" -d "$D" -b -k > "$ENGINE_LOG" 2>&1 &
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

sudo fio --name=fuse --filename="$C/nvme_raw_0" --rw=randrw --bs="$BS" --size="$BRIDGE_SIZE_BYTES" \
    --ioengine=libaio --direct=1 --iodepth=1 \
    --runtime="$RUNTIME" --time_based --group_reporting \
    --output-format=json --output=fuse_qd1.json >> "$BRIDGE_LOG" 2>&1
for _qd in "$IODEPTH_MID" "$IODEPTH"; do
    echo "  [Stage 2] FUSE fio QD=$_qd"
    sudo fio --name=fuse --filename="$C/nvme_raw_0" --rw=randrw --bs="$BS" --size="$BRIDGE_SIZE_BYTES" \
        --ioengine=libaio --direct=1 --iodepth="$_qd" \
        --runtime="$RUNTIME" --time_based --group_reporting \
        --output-format=json --output="fuse_qd${_qd}.json" >> "$BRIDGE_LOG" 2>&1
done

# Validate all fio runs
for _qd in 1 "$IODEPTH_MID" "$IODEPTH"; do
    XERR=$(jq -r '(.jobs[0].error//0)' "x_qd${_qd}.json" | awk '{print int($1+0)}')
    FERR=$(jq -r '(.jobs[0].error//0)' "fuse_qd${_qd}.json" | awk '{print int($1+0)}')
    if [ "$XERR" -ne 0 ] || [ "$FERR" -ne 0 ]; then
        echo "fio error at QD=$_qd (baseline=$XERR bridge=$FERR)"
        exit 1
    fi
done

# Kill the bridge engine and reset SPDK before Stage 3
if [ -n "${ENGINE_PID:-}" ]; then
    sudo kill -TERM "$ENGINE_PID" >/dev/null 2>&1 || true
    wait "$ENGINE_PID" 2>/dev/null || true
    ENGINE_PID=""
fi
sudo pkill -9 -x dataplane-emu >/dev/null 2>&1 || true
sudo umount -l "$C" >/dev/null 2>&1 || true
if [ -n "$SPDK_SETUP" ]; then
    sudo -E bash "$SPDK_SETUP" reset >> "$SPDK_SETUP_LOG" 2>&1
fi

# Wait for the NVMe block device to reappear after SPDK reset
stage3_ready=0
for _ in $(seq 1 15); do
    if [ -b "$D" ]; then
        stage3_ready=1
        break
    fi
    sleep 1
done
if [ "$stage3_ready" -ne 1 ]; then
    echo "Block device $D did not reappear after SPDK reset"
    exit 1
fi


# ---------------------------------------------------------------------------
# Stage 3: SPDK bdevperf
# ---------------------------------------------------------------------------
#   AWS  (Nitro)  → bdev_nvme via vfio-pci   (true PCIe bypass, no-IOMMU)
#   Azure (Boost) → bdev_uring via io_uring   (mediated passthrough;
#                   kernel NVMe driver stays bound — vfio-pci probe fails
#                   on Azure Hyper-V NVMe with EINVAL)
# ---------------------------------------------------------------------------

# Gate: SPDK must be present for Stage 3
if [ -z "$SPDK_SETUP" ] || [ -z "${BDEVPERF_BIN:-}" ]; then
    echo ""
    echo "════════════════════════════════════════════════════════════════"
    echo "  Stage 3 SKIPPED — SPDK not available on this host"
    echo "════════════════════════════════════════════════════════════════"
    echo "  Stages 1 & 2 completed successfully."
    echo "  To enable Stage 3:"
    echo "    1. git clone https://github.com/spdk/spdk.git --recursive"
    echo "    2. sudo bash scripts/spdk-aws/setup_graviton_spdk.sh"
    echo "    3. Re-run this demo"
    echo "════════════════════════════════════════════════════════════════"

    # Print the Stages 1+2 scorecard with N/A for Stage 3
    BL="N/A"; BL_IOPS="N/A"; BM_LAT="N/A"; BM_IOPS="N/A"; BI="N/A"; BI_LAT="N/A"
    STAGE3_LABEL="SKIPPED (SPDK not installed)"

elif [ "$STAGE3_MODE" = "uring" ]; then
# ---------------------------------------------------------------------------
# Stage 3 — Azure path: bdev_uring (kernel NVMe driver stays bound)
# ---------------------------------------------------------------------------
echo "[Stage 3] Azure Boost path — bdev_uring (io_uring mediated passthrough)"
echo "  Cloud provider : $CLOUD_PROVIDER"
echo "  NVMe BDF       : $TARGET_BDF"
echo "  Kernel driver  : $(basename "$(readlink "/sys/bus/pci/devices/${TARGET_BDF}/driver" 2>/dev/null)" 2>/dev/null || echo none)"
echo "  vfio-pci       : not used (Azure Hyper-V NVMe rejects vfio-pci bind)"
echo "  Backend        : bdev_uring → /dev/$(basename "$D")"

# bdev_uring talks to the block device directly via io_uring; the kernel
# NVMe driver remains bound.  No hugepages or driver rebinding needed.
BDEV_CFG="/tmp/arm_neoverse_bdevperf.json"
cat > "$BDEV_CFG" <<EOF
{
    "subsystems": [
        {
            "subsystem": "bdev",
            "config": [
                {
                    "method": "bdev_uring_create",
                    "params": {
                        "name": "Uring0",
                        "filename": "$D",
                        "block_size": 512
                    }
                }
            ]
        }
    ]
}
EOF

echo "[Stage 3a] SPDK bdevperf (uring) — Latency run (QD=1)"
if ! sudo LD_LIBRARY_PATH="$SPDK_LD_PATH" "$BDEVPERF_BIN" -c "$BDEV_CFG" -q 1 -o 4096 -w randrw -M "$RWMIXREAD" -t "$RUNTIME" > "$BDEV_LAT_LOG" 2>&1; then
    echo "bdevperf (uring) latency run failed"
    tail -n 60 "$BDEV_LAT_LOG"
    exit 1
fi
echo "[Stage 3m] SPDK bdevperf (uring) — Knee-of-curve run (QD=$IODEPTH_MID)"
if ! sudo LD_LIBRARY_PATH="$SPDK_LD_PATH" "$BDEVPERF_BIN" -c "$BDEV_CFG" -q "$IODEPTH_MID" -o 4096 -w randrw -M "$RWMIXREAD" -t "$RUNTIME" > "$BDEV_MID_LOG" 2>&1; then
    echo "bdevperf (uring) mid-QD run failed"
    tail -n 60 "$BDEV_MID_LOG"
    exit 1
fi
echo "[Stage 3b] SPDK bdevperf (uring) — Throughput run (QD=$IODEPTH)"
if ! sudo LD_LIBRARY_PATH="$SPDK_LD_PATH" "$BDEVPERF_BIN" -c "$BDEV_CFG" -q "$IODEPTH" -o 4096 -w randrw -M "$RWMIXREAD" -t "$RUNTIME" > "$BDEV_IOPS_LOG" 2>&1; then
    echo "bdevperf (uring) throughput run failed"
    tail -n 120 "$BDEV_IOPS_LOG"
    exit 1
fi

else
# ---------------------------------------------------------------------------
# Stage 3 — AWS path: bdev_nvme via vfio-pci (true PCIe bypass)
# ---------------------------------------------------------------------------
echo "[Stage 3] Preflight: verifying vfio-pci ownership"

# 3a. IOMMU groups — if not present, enable no-IOMMU mode (standard for EC2 Nitro)
if [[ ! -d /sys/kernel/iommu_groups ]] || [[ -z "$(ls -A /sys/kernel/iommu_groups 2>/dev/null)" ]]; then
    echo "  No IOMMU groups — enabling vfio no-IOMMU mode (standard for EC2 Nitro)"
    echo 1 | sudo tee /sys/module/vfio/parameters/enable_unsafe_noiommu_mode >/dev/null 2>&1 || true
else
    echo "  IOMMU groups: present"
fi

# 3b. Ensure vfio-pci module is loaded
if ! lsmod | grep -q vfio_pci; then
    echo "  Loading vfio-pci kernel module..."
    sudo modprobe vfio-pci
fi
if ! lsmod | grep -q vfio_pci; then
    echo "FATAL: vfio-pci module could not be loaded."
    exit 1
fi
echo "  vfio-pci module: loaded"

# 3c. Bind the NVMe device to vfio-pci (reuses ensure_userspace_stage3_driver)
ensure_userspace_stage3_driver

# 3d. Final driver verification — read the sysfs driver symlink directly
PREFLIGHT_DRIVER="$(basename "$(readlink "/sys/bus/pci/devices/${TARGET_BDF}/driver" 2>/dev/null)" 2>/dev/null || echo "none")"
if [[ "$PREFLIGHT_DRIVER" != "vfio-pci" ]]; then
    echo "FATAL: Stage 3 preflight FAILED"
    echo "  Expected driver : vfio-pci"
    echo "  Actual driver   : $PREFLIGHT_DRIVER"
    echo "  Device BDF      : $TARGET_BDF"
    echo "  sysfs path      : /sys/bus/pci/devices/${TARGET_BDF}/driver"
    echo ""
    echo "  The kernel NVMe driver still owns this device."
    echo "  Run: sudo bash scripts/spdk-aws/setup_graviton_spdk.sh --nvme-bdf $TARGET_BDF"
    exit 1
fi
echo "  $TARGET_BDF driver: vfio-pci (user-space NVMe verified)"

# 3e. Verify IOMMU group if available (no-IOMMU mode is valid on Nitro)
IOMMU_GROUP_PATH="$(readlink -f "/sys/bus/pci/devices/${TARGET_BDF}/iommu_group" 2>/dev/null || true)"
if [[ -n "$IOMMU_GROUP_PATH" ]]; then
    echo "  IOMMU group: $(basename "$IOMMU_GROUP_PATH")"
else
    echo "  IOMMU group: none (vfio no-IOMMU mode — Nitro provides DMA isolation)"
fi

echo "[Stage 3] Preflight PASSED — launching SPDK bdevperf (PCIe bypass)"

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

echo "[Stage 3a] SPDK bdevperf — Latency run (QD=1)"
if ! sudo LD_LIBRARY_PATH="$SPDK_LD_PATH" "$BDEVPERF_BIN" -c "$BDEV_CFG" -q 1 -o 4096 -w randrw -M "$RWMIXREAD" -t "$RUNTIME" > "$BDEV_LAT_LOG" 2>&1; then
    echo "bdevperf latency run failed"
    tail -n 60 "$BDEV_LAT_LOG"
    exit 1
fi
echo "[Stage 3m] SPDK bdevperf — Knee-of-curve run (QD=$IODEPTH_MID)"
if ! sudo LD_LIBRARY_PATH="$SPDK_LD_PATH" "$BDEVPERF_BIN" -c "$BDEV_CFG" -q "$IODEPTH_MID" -o 4096 -w randrw -M "$RWMIXREAD" -t "$RUNTIME" > "$BDEV_MID_LOG" 2>&1; then
    echo "bdevperf mid-QD run failed"
    tail -n 60 "$BDEV_MID_LOG"
    exit 1
fi
echo "[Stage 3b] SPDK bdevperf — Throughput run (QD=$IODEPTH)"
if ! sudo LD_LIBRARY_PATH="$SPDK_LD_PATH" "$BDEVPERF_BIN" -c "$BDEV_CFG" -q "$IODEPTH" -o 4096 -w randrw -M "$RWMIXREAD" -t "$RUNTIME" > "$BDEV_IOPS_LOG" 2>&1; then
    echo "bdevperf throughput run failed"
    tail -n 120 "$BDEV_IOPS_LOG"
    exit 1
fi

fi  # end of Stage 3 branch

# ---------------------------------------------------------------------------
# Parse results
# ---------------------------------------------------------------------------
parse_fio() {
    local json="$1" field="$2"
    case "$field" in
        lat) jq -r '((.jobs[0].read.clat_ns.mean//0)+(.jobs[0].write.clat_ns.mean//0))/2000' "$json" | awk '{printf "%.2f", $1+0}' ;;
        iops) jq -r '(.jobs[0].read.iops//0)+(.jobs[0].write.iops//0)' "$json" | awk '{printf "%.0f", $1+0}' ;;
    esac
}

# Per-QD kernel numbers
XL_1=$(parse_fio x_qd1.json lat);               XI_1=$(parse_fio x_qd1.json iops)
XL_M=$(parse_fio "x_qd${IODEPTH_MID}.json" lat); XI_M=$(parse_fio "x_qd${IODEPTH_MID}.json" iops)
XL_H=$(parse_fio "x_qd${IODEPTH}.json" lat);     XI_H=$(parse_fio "x_qd${IODEPTH}.json" iops)

# Per-QD FUSE numbers
FL_1=$(parse_fio fuse_qd1.json lat);               FI_1=$(parse_fio fuse_qd1.json iops)
FL_M=$(parse_fio "fuse_qd${IODEPTH_MID}.json" lat); FI_M=$(parse_fio "fuse_qd${IODEPTH_MID}.json" iops)
FL_H=$(parse_fio "fuse_qd${IODEPTH}.json" lat);     FI_H=$(parse_fio "fuse_qd${IODEPTH}.json" iops)

# bdevperf: parse latency run (QD=1)
parse_bdevperf() {
    local log="$1" field="$2"
    local val=""
    # Total line format after stripping "...Total...:" prefix:
    #   $1=IOPS  $2=MiB/s  $3=Fail/s  $4=TO/s  $5=AvgLat  $6=min  $7=max
    local total
    total=$(grep -E '^[[:space:]]*Total[[:space:]]*:' "$log" 2>/dev/null | tail -n 1 | sed 's/.*://' || true)
    if [ -n "$total" ]; then
        case "$field" in
            iops) val=$(echo "$total" | awk '{printf "%.0f", $1+0}') ;;
            lat)  val=$(echo "$total" | awk '{printf "%.2f", $5+0}') ;;
        esac
    fi
    # Fallback: grep running output line
    if [ -z "$val" ] || [ "$val" = "0" ] || [ "$val" = "0.00" ]; then
        case "$field" in
            iops) val=$( (grep -Eo '([0-9]+\.?[0-9]*)[[:space:]]*IOPS' "$log" | tail -n 1 | awk '{printf "%.0f", $1+0}') || true ) ;;
            lat)  ;; # no fallback for latency — only the Total line is authoritative
        esac
    fi
    echo "${val:-N/A}"
}

# bdevperf results (only if Stage 3 ran — otherwise already set to N/A)
if [ -z "${BL:-}" ]; then
BL=$(parse_bdevperf "$BDEV_LAT_LOG" lat)
BL_IOPS=$(parse_bdevperf "$BDEV_LAT_LOG" iops)
BM_LAT=$(parse_bdevperf "$BDEV_MID_LOG" lat)
BM_IOPS=$(parse_bdevperf "$BDEV_MID_LOG" iops)
BI=$(parse_bdevperf "$BDEV_IOPS_LOG" iops)
BI_LAT=$(parse_bdevperf "$BDEV_IOPS_LOG" lat)
fi

# ---------------------------------------------------------------------------
# Scorecard
# ---------------------------------------------------------------------------
if [ -z "${STAGE3_LABEL:-}" ]; then
    if [ "$STAGE3_MODE" = "uring" ]; then
        STAGE3_LABEL="bdev_uring (io_uring → Azure Boost mediated passthrough)"
    else
        STAGE3_LABEL="bdev_nvme (vfio-pci → PCIe bypass)"
    fi
fi

echo ""
echo "════════════════════════════════════════════════════════════════════════════"
echo "  DETERMINISTIC SILICON DATA PLANE SCORECARD"
echo "════════════════════════════════════════════════════════════════════════════"
echo "  Config: bs=$BS  runtime=${RUNTIME}s  rwmix=$RWMIXREAD/$((100 - RWMIXREAD))  mid-QD=$IODEPTH_MID"
echo "  Stage 3: $STAGE3_LABEL"
echo "────────────────────────────────────────────────────────────────────────────"
echo ""
echo "  ┌─ Latency (QD=1) ──────────────────────────────────────────────────────┐"
printf "  │ %-32s  %12s  %12s │\n" "Architecture" "Avg (μs)" "IOPS"
echo "  │ ──────────────────────────────  ────────────  ──────────── │"
printf "  │ %-32s  %12s  %12s │\n" "1. Kernel (XFS + fio)"         "$XL_1" "$XI_1"
printf "  │ %-32s  %12s  %12s │\n" "2. User-Space Bridge (FUSE)"   "$FL_1" "$FI_1"
printf "  │ %-32s  %12s  %12s │\n" "3. SPDK Zero-Copy (bdevperf)"  "$BL" "$BL_IOPS"
echo "  └────────────────────────────────────────────────────────────────────────┘"
echo ""
echo "  ┌─ Knee-of-Curve (QD=$IODEPTH_MID) ────────────────────────────────────────────┐"
printf "  │ %-32s  %12s  %12s │\n" "Architecture" "Avg (μs)" "IOPS"
echo "  │ ──────────────────────────────  ────────────  ──────────── │"
printf "  │ %-32s  %12s  %12s │\n" "1. Kernel (XFS + fio)"         "$XL_M" "$XI_M"
printf "  │ %-32s  %12s  %12s │\n" "2. User-Space Bridge (FUSE)"   "$FL_M" "$FI_M"
printf "  │ %-32s  %12s  %12s │\n" "3. SPDK Zero-Copy (bdevperf)"  "$BM_LAT" "$BM_IOPS"
echo "  └────────────────────────────────────────────────────────────────────────┘"
echo ""
echo "  ┌─ Throughput (QD=$IODEPTH) ───────────────────────────────────────────────┐"
printf "  │ %-32s  %12s  %12s │\n" "Architecture" "Avg (μs)" "IOPS"
echo "  │ ──────────────────────────────  ────────────  ──────────── │"
printf "  │ %-32s  %12s  %12s │\n" "1. Kernel (XFS + fio)"         "$XL_H" "$XI_H"
printf "  │ %-32s  %12s  %12s │\n" "2. User-Space Bridge (FUSE)"   "$FL_H" "$FI_H"
printf "  │ %-32s  %12s  %12s │\n" "3. SPDK Zero-Copy (bdevperf)"  "$BI_LAT" "$BI"
echo "  └────────────────────────────────────────────────────────────────────────┘"
echo ""
echo "────────────────────────────────────────────────────────────────────────────"
echo "  Logs:"
echo "    Baseline:       $BASE_LOG"
echo "    Bridge:         $BRIDGE_LOG"
echo "    SPDK setup:     $SPDK_SETUP_LOG"
echo "    bdevperf (lat): $BDEV_LAT_LOG"
echo "    bdevperf (mid): $BDEV_MID_LOG"
echo "    bdevperf (thr): $BDEV_IOPS_LOG"
echo "════════════════════════════════════════════════════════════════════════════"
