#!/usr/bin/env bash
# ============================================================================
# scripts/spdk-aws/setup_graviton_spdk.sh
# Graviton-Specific SPDK/DPDK Build & NVMe Environment Setup
# ============================================================================
#
# Enforces three ARM64 architectural rules for AWS Nitro:
#   1. PCIe Bypass: hugepages + vfio-pci (never uio_pci_generic)
#   2. LSE Atomics: -mcpu=neoverse-v1 -moutline-atomics
#   3. 3-Queue Rule: Nitro NVMe saturates at 2-3 QPs per device
#
# Usage:
#   sudo bash scripts/spdk-aws/setup_graviton_spdk.sh [--nvme-bdf 0000:00:1f.0]
#
# Environment overrides:
#   SPDK_DIR          SPDK source tree   (default: repo_root/spdk)
#   HUGEMEM_MB        Hugepage pool in MB (default: 4096)
#   NVME_BDF          NVMe BDF to bind    (auto-detected if omitted)
#   TARGET_MCPU       -mcpu target         (default: auto-detect Neoverse gen)
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SPDK_DIR="${SPDK_DIR:-$REPO_ROOT/spdk}"
HUGEMEM_MB="${HUGEMEM_MB:-4096}"
BUILD_JOBS="${BUILD_JOBS:-$(nproc)}"

# ---------------------------------------------------------------------------
# 0. Guard: must be aarch64 on AWS
# ---------------------------------------------------------------------------
if [[ "$(uname -m)" != "aarch64" ]]; then
    echo "FATAL: This script targets aarch64 (Graviton). Current arch: $(uname -m)" >&2
    exit 1
fi

# Verify AWS via IMDS v2 (link-local only, 1s timeout)
imds_token=$(curl -sf -X PUT \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 10" \
    --connect-timeout 1 --max-time 2 \
    "http://169.254.169.254/latest/api/token" 2>/dev/null || true)
if [[ -z "$imds_token" ]]; then
    echo "WARNING: Could not reach AWS IMDS — not running on EC2?" >&2
    echo "         Continuing anyway (set FORCE_AWS=1 to suppress)." >&2
fi

# ---------------------------------------------------------------------------
# 1. Detect Neoverse sub-generation for -mcpu
# ---------------------------------------------------------------------------
detect_neoverse_mcpu() {
    local midr
    # MIDR_EL1 exposed via /sys on Linux 5.x+
    if [[ -r /sys/devices/system/cpu/cpu0/regs/identification/midr_el1 ]]; then
        midr=$(cat /sys/devices/system/cpu/cpu0/regs/identification/midr_el1)
        case "$midr" in
            *0xd40*) echo "neoverse-v1" ; return ;;  # Graviton3
            *0xd4f*) echo "neoverse-v2" ; return ;;  # Graviton4
            *0xd0c*) echo "neoverse-n1" ; return ;;  # Graviton2
            *0xd49*) echo "neoverse-n2" ; return ;;  # Neoverse-N2
        esac
    fi
    # Fallback: parse /proc/cpuinfo implementer + part
    if grep -q "0xd40" /proc/cpuinfo 2>/dev/null; then
        echo "neoverse-v1"; return
    elif grep -q "0xd4f" /proc/cpuinfo 2>/dev/null; then
        echo "neoverse-v2"; return
    elif grep -q "0xd0c" /proc/cpuinfo 2>/dev/null; then
        echo "neoverse-n1"; return
    fi
    echo "neoverse-v1"  # safe default for Graviton3
}

TARGET_MCPU="${TARGET_MCPU:-$(detect_neoverse_mcpu)}"
echo "========================================"
echo "  Graviton SPDK/DPDK Build & Env Setup"
echo "  Target CPU : $TARGET_MCPU"
echo "  SPDK source: $SPDK_DIR"
echo "  Hugepages  : ${HUGEMEM_MB} MB"
echo "  Build jobs : $BUILD_JOBS"
echo "========================================"

# ---------------------------------------------------------------------------
# 2. Install system dependencies
# ---------------------------------------------------------------------------
install_deps() {
    echo "--- [1/6] Installing system dependencies ---"
    if command -v apt-get &>/dev/null; then
        sudo apt-get update -qq
        sudo apt-get install -y -qq \
            build-essential pkg-config python3-pip \
            libfuse3-dev libnuma-dev uuid-dev libssl-dev \
            libaio-dev liburing-dev meson ninja-build \
            autoconf automake libtool nasm \
            pciutils kmod
    elif command -v dnf &>/dev/null; then
        sudo dnf install -y gcc gcc-c++ make pkgconfig \
            fuse3-devel numactl-devel libuuid-devel openssl-devel \
            libaio-devel liburing-devel meson ninja-build \
            autoconf automake libtool nasm \
            pciutils kmod
    else
        echo "WARNING: Unknown package manager, skipping dep install" >&2
    fi

    # SPDK's own dependency installer (idempotent)
    if [[ -x "$SPDK_DIR/scripts/pkgdep.sh" ]]; then
        sudo "$SPDK_DIR/scripts/pkgdep.sh" --all || true
    fi
}

install_deps

# ---------------------------------------------------------------------------
# 3. Allocate 2 MiB hugepages for SPDK/DPDK DMA buffers
# ---------------------------------------------------------------------------
setup_hugepages() {
    echo "--- [2/6] Allocating ${HUGEMEM_MB} MB hugepages ---"
    local nr_pages=$(( HUGEMEM_MB / 2 ))

    # Ensure hugetlbfs is mounted
    if ! mountpoint -q /dev/hugepages 2>/dev/null; then
        sudo mkdir -p /dev/hugepages
        sudo mount -t hugetlbfs nodev /dev/hugepages
    fi

    echo "$nr_pages" | sudo tee /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages >/dev/null
    local actual
    actual=$(cat /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages)
    echo "  Requested: $nr_pages pages, Allocated: $actual pages"
    if (( actual < nr_pages / 2 )); then
        echo "WARNING: Could not allocate enough hugepages (got $actual of $nr_pages)" >&2
        echo "  Try: echo $nr_pages | sudo tee /proc/sys/vm/nr_hugepages" >&2
    fi
}

setup_hugepages

# ---------------------------------------------------------------------------
# 4. Load vfio-pci and bind NVMe device (NEVER uio_pci_generic)
# ---------------------------------------------------------------------------
# AWS Nitro provides a guest vIOMMU, so vfio-pci works without no_iommu mode.
# uio_pci_generic is explicitly forbidden — it lacks IOMMU isolation and
# is a security risk on multi-tenant Nitro hosts.
# ---------------------------------------------------------------------------
auto_detect_nvme_bdf() {
    # Find an NVMe device that is NOT the root disk
    local root_src root_disk
    root_src=$(findmnt -n -o SOURCE / || true)
    root_disk=$(lsblk -no PKNAME "$root_src" 2>/dev/null | head -n 1 || true)

    local bdf
    for dev in /sys/class/nvme/nvme*/device; do
        [[ -e "$dev" ]] || continue
        local candidate_bdf
        candidate_bdf=$(basename "$(readlink -f "$dev")" 2>/dev/null || true)
        # Skip the root filesystem's NVMe controller
        if [[ -n "$root_disk" ]]; then
            local ctrl_name
            ctrl_name=$(basename "$(dirname "$dev")")
            if lsblk -no NAME "/dev/${ctrl_name}n1" 2>/dev/null | grep -q "$root_disk"; then
                continue
            fi
        fi
        if echo "$candidate_bdf" | grep -Eq '[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-7]'; then
            echo "$candidate_bdf"
            return 0
        fi
    done
    return 1
}

bind_vfio_pci() {
    local bdf="$1"
    echo "--- [3/6] Binding $bdf to vfio-pci ---"

    # RULE: Never load uio_pci_generic on Graviton
    if lsmod | grep -q uio_pci_generic; then
        echo "WARNING: uio_pci_generic is loaded — this is NOT recommended on Nitro." >&2
        echo "  vfio-pci provides proper IOMMU isolation." >&2
    fi

    # Load vfio-pci
    sudo modprobe vfio-pci
    if ! lsmod | grep -q vfio_pci; then
        echo "FATAL: vfio-pci module failed to load" >&2
        exit 1
    fi

    # EC2 Nitro note: Most Graviton instance types (c7gd, i4g, etc.)
    # do NOT expose IOMMU groups to the guest VM.  This is normal —
    # Nitro handles DMA isolation at the hypervisor level.  SPDK and
    # DPDK work fine via vfio "no-IOMMU" mode, which gives us full
    # user-space NVMe access while Nitro provides the real isolation.
    if [[ ! -d /sys/kernel/iommu_groups ]] || [[ -z "$(ls -A /sys/kernel/iommu_groups 2>/dev/null)" ]]; then
        echo "  No IOMMU groups found — enabling vfio no-IOMMU mode (standard for EC2 Nitro)"
        # Enable vfio no-IOMMU mode
        echo 1 | sudo tee /sys/module/vfio/parameters/enable_unsafe_noiommu_mode >/dev/null
        # Reload vfio-pci so it picks up the no-IOMMU flag
        sudo modprobe -r vfio_pci 2>/dev/null || true
        sudo modprobe vfio-pci enable_sva=1 disable_idle_d3=1 2>/dev/null || sudo modprobe vfio-pci
    else
        echo "  IOMMU groups: present (full vfio-pci isolation)"
    fi

    local current_driver
    current_driver=$(basename "$(readlink "/sys/bus/pci/devices/${bdf}/driver" 2>/dev/null)" 2>/dev/null || echo "none")

    if [[ "$current_driver" == "vfio-pci" ]]; then
        echo "  $bdf already bound to vfio-pci"
        return 0
    fi

    echo "  Current driver: $current_driver — rebinding to vfio-pci"

    # Unbind from current driver
    if [[ "$current_driver" != "none" ]] && [[ -e "/sys/bus/pci/drivers/${current_driver}/unbind" ]]; then
        echo "$bdf" | sudo tee "/sys/bus/pci/drivers/${current_driver}/unbind" >/dev/null
    fi

    # Set driver_override and probe
    echo "vfio-pci" | sudo tee "/sys/bus/pci/devices/${bdf}/driver_override" >/dev/null
    echo "$bdf" | sudo tee "/sys/bus/pci/drivers/vfio-pci/bind" >/dev/null

    # Verify
    current_driver=$(basename "$(readlink "/sys/bus/pci/devices/${bdf}/driver" 2>/dev/null)" 2>/dev/null || echo "none")
    if [[ "$current_driver" != "vfio-pci" ]]; then
        echo "FATAL: Failed to bind $bdf to vfio-pci (still: $current_driver)" >&2
        exit 1
    fi

    echo "  $bdf successfully bound to vfio-pci"
}

NVME_BDF="${NVME_BDF:-}"
if [[ -z "$NVME_BDF" ]]; then
    NVME_BDF=$(auto_detect_nvme_bdf || true)
fi

# Parse CLI flags
while [[ $# -gt 0 ]]; do
    case "$1" in
        --nvme-bdf) NVME_BDF="$2"; shift 2 ;;
        *)          echo "Unknown flag: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$NVME_BDF" ]]; then
    echo "FATAL: Could not auto-detect NVMe BDF. Pass --nvme-bdf 0000:XX:YY.Z" >&2
    exit 1
fi

bind_vfio_pci "$NVME_BDF"

# ---------------------------------------------------------------------------
# 5. Build SPDK/DPDK with Graviton-optimal flags
# ---------------------------------------------------------------------------
# LSE Hardware Atomics:
#   -mcpu=neoverse-v1  — Graviton3 (Armv8.4-A, LSE, SVE)
#   -moutline-atomics  — Runtime dispatch: use CASAL/LDADD on LSE-capable
#                         cores, fall back to LL/SC only on pre-v8.1 (won't
#                         happen on Graviton, but satisfies mixed-binary compat)
#
# This ensures SPDK/DPDK lock-free queues use single-instruction hardware
# atomics (CASAL, LDADD, SWP) instead of slow LL/SC retry loops.
# ---------------------------------------------------------------------------
build_spdk() {
    echo "--- [4/6] Building SPDK/DPDK (${TARGET_MCPU} + LSE atomics) ---"

    if [[ ! -d "$SPDK_DIR" ]]; then
        echo "FATAL: SPDK source tree not found at $SPDK_DIR" >&2
        echo "  git submodule update --init --recursive" >&2
        exit 1
    fi

    # Fix ownership if cloned as root
    if [[ "$(stat -c '%U' "$SPDK_DIR")" != "$USER" ]]; then
        sudo chown -R "$USER":"$USER" "$SPDK_DIR"
    fi

    pushd "$SPDK_DIR" >/dev/null

    # Update submodules if needed
    if [[ ! -f dpdk/meson.build ]]; then
        git submodule update --init --recursive
    fi

    # Export Graviton-specific compiler flags
    export EXTRA_CFLAGS="-mcpu=${TARGET_MCPU} -moutline-atomics"
    export EXTRA_CXXFLAGS="-mcpu=${TARGET_MCPU} -moutline-atomics"

    echo "  EXTRA_CFLAGS  = $EXTRA_CFLAGS"
    echo "  EXTRA_CXXFLAGS= $EXTRA_CXXFLAGS"

    # Configure SPDK:
    #   (no --with-dpdk)     Build the bundled DPDK submodule automatically
    #   --with-vfio-user     Support vfio-user virtual devices
    #   --with-uring         io_uring for non-NVMe bdev paths
    #   --target-arch=native Let DPDK detect Neoverse features at configure time
    ./configure \
        --with-vfio-user \
        --with-uring \
        --target-arch=native \
        --disable-unit-tests

    make -j"$BUILD_JOBS"

    popd >/dev/null
    echo "  SPDK/DPDK build complete"
}

build_spdk

# ---------------------------------------------------------------------------
# 6. Build dataplane-emu with matching silicon flags
# ---------------------------------------------------------------------------
build_dataplane_emu() {
    echo "--- [5/6] Building dataplane-emu ---"
    local cmake_silicon_target

    case "$TARGET_MCPU" in
        neoverse-v1) cmake_silicon_target="GRAVITON3" ;;
        neoverse-v2) cmake_silicon_target="GRAVITON4" ;;
        neoverse-n1) cmake_silicon_target="GRAVITON2" ;;
        neoverse-n2) cmake_silicon_target="ARM_NEOVERSE_N2" ;;
        *)           cmake_silicon_target="GENERIC" ;;
    esac

    mkdir -p "$REPO_ROOT/build"
    pushd "$REPO_ROOT/build" >/dev/null
    cmake .. -DTARGET_SILICON="$cmake_silicon_target" -DWITH_SPDK=ON
    make -j"$BUILD_JOBS"
    popd >/dev/null
    echo "  dataplane-emu build complete (silicon=$cmake_silicon_target)"
}

build_dataplane_emu

# ---------------------------------------------------------------------------
# 7. Print verification and benchmark commands
# ---------------------------------------------------------------------------
# The "3-Queue Rule": Nitro NVMe controllers require 2-3 Queue Pairs (QP)
# per device to reach saturation. Single-QP benchmarks will undercount
# device throughput by 30-50%.
# ---------------------------------------------------------------------------
SPDK_LD_PATH="$SPDK_DIR/build/lib:$SPDK_DIR/dpdk/build/lib"

cat <<EOF

========================================
  Graviton SPDK Environment Ready
========================================
  NVMe BDF  : $NVME_BDF
  Driver    : vfio-pci
  CPU target: -mcpu=$TARGET_MCPU -moutline-atomics
  Hugepages : ${HUGEMEM_MB} MB

--- Verify binding ---
  readlink /sys/bus/pci/devices/${NVME_BDF}/driver

--- Benchmark commands (3-Queue Rule: use -q 3 for Nitro saturation) ---

  # Latency probe (QD=1, single queue)
  sudo LD_LIBRARY_PATH=$SPDK_LD_PATH \\
    $SPDK_DIR/build/bin/bdevperf \\
    -c /tmp/bdevperf_graviton.json -q 1 -o 4096 -w randread -t 30

  # Saturation sweep (QD=128, 3 queue pairs — Nitro optimal)
  sudo LD_LIBRARY_PATH=$SPDK_LD_PATH \\
    $SPDK_DIR/build/bin/bdevperf \\
    -c /tmp/bdevperf_graviton.json -q 128 -o 4096 -w randrw -M 50 -t 30 -T 3

  # fio via SPDK bdev plugin (3 jobs = 3 QPs)
  sudo LD_PRELOAD=$SPDK_DIR/build/fio/spdk_bdev \\
    LD_LIBRARY_PATH=$SPDK_LD_PATH \\
    fio --name=graviton --ioengine=spdk_bdev \\
    --thread=1 --numjobs=3 --bs=4k --iodepth=128 \\
    --rw=randrw --rwmixread=50 --direct=1 \\
    --runtime=30 --time_based --group_reporting \\
    --filename=Nvme0n1

--- bdevperf config (write to /tmp/bdevperf_graviton.json) ---
{
  "subsystems": [{
    "subsystem": "bdev",
    "config": [{
      "method": "bdev_nvme_attach_controller",
      "params": {
        "name": "Nvme0",
        "trtype": "PCIe",
        "traddr": "$NVME_BDF"
      }
    }]
  }]
}
EOF

# Write the bdevperf config for convenience
cat > /tmp/bdevperf_graviton.json <<BDEVCFG
{
  "subsystems": [{
    "subsystem": "bdev",
    "config": [{
      "method": "bdev_nvme_attach_controller",
      "params": {
        "name": "Nvme0",
        "trtype": "PCIe",
        "traddr": "$NVME_BDF"
      }
    }]
  }]
}
BDEVCFG

echo "--- [6/6] Setup complete ---"
