#!/usr/bin/env bash
# ============================================================================
# scripts/build_spdk.sh — SPDK Cross-Cloud Build Driver
# ============================================================================
#
# Detects the cloud environment (AWS Graviton / Azure Cobalt 100) and
# executes the correct SPDK build path:
#
#   AWS  (vfio-pci)    → ./configure + make  (standard SPDK flow)
#   Azure (uio_hv_generic) → meson setup      (MANA/NetVSC backend)
#
# Both paths link against the ARM64 NEON-optimised ISA-L library for
# hardware-accelerated CRC32-C and erasure coding.
#
# Usage:
#   bash scripts/build_spdk.sh [--force-cloud aws|azure] [--jobs N]
#
# Environment:
#   SPDK_DIR          Override SPDK source root (default: repo_root/spdk)
#   BUILD_JOBS        Parallel make/ninja jobs   (default: nproc)
#   FORCE_CLOUD       Force a specific cloud     (aws | azure)
# ============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# 0. Resolve paths
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SPDK_DIR="${SPDK_DIR:-$REPO_ROOT/spdk}"

if [[ ! -d "$SPDK_DIR" ]]; then
    echo "FATAL: SPDK source tree not found at $SPDK_DIR" >&2
    exit 1
fi

BUILD_JOBS="${BUILD_JOBS:-$(nproc)}"

# ---------------------------------------------------------------------------
# 1. Cloud detection
# ---------------------------------------------------------------------------
# Priority: CLI flag > env var > dmidecode > IMDS metadata endpoint.
# We never curl arbitrary URLs — only the well-known link-local metadata IPs.

detect_cloud() {
    # CLI / env override
    local forced="${FORCE_CLOUD:-}"
    if [[ -n "$forced" ]]; then
        echo "$forced"
        return
    fi

    # dmidecode (requires root or readable DMI tables)
    if command -v dmidecode &>/dev/null; then
        local sys_vendor
        sys_vendor=$(sudo dmidecode -s system-manufacturer 2>/dev/null || true)
        case "$sys_vendor" in
            *"Amazon"*|*"amazon"*)  echo "aws";   return ;;
            *"Microsoft"*)          echo "azure"; return ;;
        esac
    fi

    # AWS IMDS v2 — token-based, 1-second timeout, link-local only
    local imds_token
    imds_token=$(curl -sf -X PUT \
        -H "X-aws-ec2-metadata-token-ttl-seconds: 10" \
        --connect-timeout 1 --max-time 2 \
        "http://169.254.169.254/latest/api/token" 2>/dev/null || true)
    if [[ -n "$imds_token" ]]; then
        echo "aws"
        return
    fi

    # Azure IMDS — Metadata: true header, link-local only
    local az_check
    az_check=$(curl -sf -H "Metadata: true" \
        --connect-timeout 1 --max-time 2 \
        "http://169.254.169.254/metadata/instance?api-version=2021-02-01" 2>/dev/null || true)
    if [[ -n "$az_check" ]]; then
        echo "azure"
        return
    fi

    echo "unknown"
}

# Parse optional CLI flags
while [[ $# -gt 0 ]]; do
    case "$1" in
        --force-cloud) FORCE_CLOUD="$2"; shift 2 ;;
        --jobs)        BUILD_JOBS="$2";  shift 2 ;;
        *)             echo "Unknown flag: $1" >&2; exit 1 ;;
    esac
done

CLOUD=$(detect_cloud)
echo "========================================"
echo "  Cloud detected : $CLOUD"
echo "  SPDK source    : $SPDK_DIR"
echo "  Build jobs     : $BUILD_JOBS"
echo "========================================"

if [[ "$CLOUD" == "unknown" ]]; then
    echo "FATAL: Unable to determine cloud environment." >&2
    echo "       Set FORCE_CLOUD=aws or FORCE_CLOUD=azure and re-run." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 2. Common: Verify ARM64 and install dependencies if missing
# ---------------------------------------------------------------------------
ARCH=$(uname -m)
if [[ "$ARCH" != "aarch64" ]]; then
    echo "WARNING: Running on $ARCH — this build is optimised for aarch64." >&2
fi

# Ensure SPDK's pkgdep has been run (idempotent)
if [[ -x "$SPDK_DIR/scripts/pkgdep.sh" ]]; then
    echo "--- Ensuring SPDK build dependencies are installed ---"
    sudo "$SPDK_DIR/scripts/pkgdep.sh" --all
fi

# ---------------------------------------------------------------------------
# 3. Common: Build ISA-L with NEON acceleration
# ---------------------------------------------------------------------------
# ISA-L provides NEON-vectorised CRC32-C, RAID-erasure code, and
# deflate/inflate used by SPDK's blobstore and NVMe-oF target.
ISAL_DIR="$SPDK_DIR/isa-l"
ISAL_INSTALL="$ISAL_DIR/install"
if [[ -d "$ISAL_DIR" && ! -f "$ISAL_INSTALL/lib/libisal.a" ]]; then
    echo "--- Building ISA-L (NEON-optimised) ---"
    pushd "$ISAL_DIR" > /dev/null
    if [[ -f autogen.sh ]]; then
        ./autogen.sh
    fi
    # --host=aarch64 enables the NEON/CRC intrinsic code paths.
    # --prefix installs into a known location so SPDK can link it.
    ./configure --host=aarch64-linux-gnu \
        --prefix="$ISAL_INSTALL" \
        CFLAGS="-O3 -mcpu=native" \
        ASMFLAGS="-march=armv8-a+crc+crypto"
    make -j"$BUILD_JOBS"
    make install
    popd > /dev/null
    echo "--- ISA-L build complete (installed to $ISAL_INSTALL) ---"
fi

# Also build isa-l-crypto if present (AES-NI equivalent on ARM: AES/SHA extensions)
ISAL_CRYPTO_DIR="$SPDK_DIR/isa-l-crypto"
ISAL_CRYPTO_INSTALL="$ISAL_CRYPTO_DIR/install"
if [[ -d "$ISAL_CRYPTO_DIR" && ! -f "$ISAL_CRYPTO_INSTALL/lib/libisal_crypto.a" ]]; then
    echo "--- Building ISA-L Crypto (ARM AES/SHA) ---"
    pushd "$ISAL_CRYPTO_DIR" > /dev/null
    if [[ -f autogen.sh ]]; then
        ./autogen.sh
    fi
    ./configure --host=aarch64-linux-gnu \
        --prefix="$ISAL_CRYPTO_INSTALL" \
        CFLAGS="-O3 -mcpu=native" \
        ASMFLAGS="-march=armv8-a+crc+crypto"
    make -j"$BUILD_JOBS"
    make install
    popd > /dev/null
    echo "--- ISA-L Crypto build complete (installed to $ISAL_CRYPTO_INSTALL) ---"
fi

# ---------------------------------------------------------------------------
# 3b. Export ISA-L paths so SPDK's ./configure and linker find our external build
# ---------------------------------------------------------------------------
# PKG_CONFIG_PATH: lets SPDK's configure resolve libisal.pc / libisal_crypto.pc
# EXTRA_LDFLAGS:   direct -L/-l fallback if pkg-config is not used
# EXTRA_CFLAGS:    header search path for isal.h
export PKG_CONFIG_PATH="${ISAL_INSTALL}/lib/pkgconfig:${ISAL_CRYPTO_INSTALL}/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
export EXTRA_LDFLAGS="-L${ISAL_INSTALL}/lib -lisal -L${ISAL_CRYPTO_INSTALL}/lib -lisal_crypto"
export EXTRA_CFLAGS="-I${ISAL_INSTALL}/include -I${ISAL_CRYPTO_INSTALL}/include"

echo "  ISA-L pkg-config : $PKG_CONFIG_PATH"
echo "  ISA-L LDFLAGS    : $EXTRA_LDFLAGS"

# ---------------------------------------------------------------------------
# 4A. AWS Graviton (Neoverse-V) — Standard SPDK build via ./configure + make
# ---------------------------------------------------------------------------
# AWS Nitro exposes NVMe devices as standard PCIe BDFs.  We bind them to
# vfio-pci (True PCIe Bypass) and SPDK's env_dpdk layer handles the rest.
#
# Key flags:
#   --with-vfio-user   Optional virtual device support for testing
#   --with-uring       Enable io_uring fallback for non-NVMe paths
#   --target-arch      Emit Neoverse-V1/V2 tuned instructions via DPDK
build_aws() {
    echo "--- AWS Graviton: ./configure + make ---"
    pushd "$SPDK_DIR" > /dev/null

    # Determine Neoverse sub-generation for DPDK's -mcpu flag.
    # Graviton3 = neoverse-v1, Graviton4 = neoverse-v2.
    local target_arch="native"
    if grep -q "neoverse-v2" /proc/cpuinfo 2>/dev/null; then
        target_arch="neoverse-v2"
    elif grep -q "neoverse-v1" /proc/cpuinfo 2>/dev/null; then
        target_arch="neoverse-v1"
    fi

    # --without-isal: we built ISA-L externally with precise NEON asm control.
    # SPDK picks up our external ISA-L via PKG_CONFIG_PATH and EXTRA_LDFLAGS
    # exported in §3b above.
    ./configure \
        --with-dpdk \
        --with-vfio-user \
        --with-uring \
        --target-arch="$target_arch" \
        --without-isal

    make EXTRA_LDFLAGS="$EXTRA_LDFLAGS" EXTRA_CFLAGS="$EXTRA_CFLAGS" -j"$BUILD_JOBS"
    popd > /dev/null
    echo "--- AWS build complete ---"
}

# ---------------------------------------------------------------------------
# 4B. Azure Cobalt 100 (Neoverse-N2) — Meson build with MANA/NetVSC
# ---------------------------------------------------------------------------
# Azure does NOT expose raw IOMMU groups to guests, so vfio-pci passthrough
# is not available.  Instead, Azure Boost presents network and storage via:
#   - MANA (Microsoft Azure Network Adapter)  → accelerated data plane
#   - NetVSC                                   → VMBus storage backend
#   - uio_hv_generic                           → user-space VMBus driver
#
# We use DPDK's meson build system to enable these backends and produce
# the libraries that SPDK links against.
build_azure() {
    echo "--- Azure Cobalt 100: Meson build (MANA + NetVSC) ---"

    # Ensure uio_hv_generic is loaded — required for VMBus device binding
    if ! lsmod | grep -q uio_hv_generic; then
        echo "Loading uio_hv_generic kernel module..."
        sudo modprobe uio_hv_generic
    fi

    # Phase 1: Build DPDK with MANA/NetVSC support via Meson
    local dpdk_dir="$SPDK_DIR/dpdk"
    local dpdk_build="$dpdk_dir/build"

    if [[ -d "$dpdk_dir" ]]; then
        echo "  Building DPDK with MANA + NetVSC..."
        pushd "$dpdk_dir" > /dev/null

        # Wipe stale build to avoid meson reconfigure errors
        if [[ -d "$dpdk_build" ]]; then
            rm -rf "$dpdk_build"
        fi

        # Enable MANA + NetVSC explicitly — required for Azure Boost's
        # mediated user-space path where the kernel manages the VMBus
        # control plane and DPDK/SPDK handle the data plane.
        meson setup "$dpdk_build" \
            -Dplatform=generic \
            -Dcpu_instruction_set=generic \
            -Ddisable_drivers='' \
            -Denable_drivers='net/mana,bus/vmbus,net/netvsc' \
            -Dwith_mana=true \
            -Dwith_netvsc=true \
            -Dprefix="$dpdk_dir/install" \
            -Dmachine=aarch64 \
            -Dbuildtype=release

        ninja -C "$dpdk_build" -j"$BUILD_JOBS"
        ninja -C "$dpdk_build" install
        popd > /dev/null
    fi

    # Phase 2: Build SPDK, pointing it at our custom DPDK installation
    pushd "$SPDK_DIR" > /dev/null
    # --without-isal: external NEON-optimised build; linked via EXTRA_LDFLAGS.
    ./configure \
        --with-dpdk="$dpdk_dir/install" \
        --with-uring \
        --target-arch="neoverse-n2" \
        --without-isal

    make EXTRA_LDFLAGS="$EXTRA_LDFLAGS" EXTRA_CFLAGS="$EXTRA_CFLAGS" -j"$BUILD_JOBS"
    popd > /dev/null
    echo "--- Azure build complete ---"
}

# ---------------------------------------------------------------------------
# 5. Dispatch
# ---------------------------------------------------------------------------
case "$CLOUD" in
    aws)   build_aws   ;;
    azure) build_azure ;;
esac

echo ""
echo "========================================"
echo "  SPDK build succeeded for $CLOUD"
echo "  Libraries: $SPDK_DIR/build/lib/"
echo "========================================"
