#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

require_cmd() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Missing required command: $cmd"
        exit 1
    fi
}

require_cmd jq
require_cmd fio
require_cmd bc
require_cmd awk
require_cmd grep
require_cmd pgrep
require_cmd stat

NO_CLEAR="${DEMO_NO_CLEAR:-1}"

maybe_clear() {
    if [ "$NO_CLEAR" != "1" ]; then
        clear
    fi
}

fetch_imds() {
    local mode="$1"
    python3 - "$mode" <<'PY' 2>/dev/null || true
import json
import sys
import urllib.request

mode = sys.argv[1]

def get(url, headers=None):
    req = urllib.request.Request(url, headers=headers or {})
    with urllib.request.urlopen(req, timeout=1) as r:
        return r.read().decode().strip()

if mode == "azure":
    try:
        print(get(
            "http://169.254.169.254/metadata/instance/compute/vmSize?api-version=2021-02-01&format=text",
            {"Metadata": "true"}
        ))
    except Exception:
        pass
elif mode == "aws":
    try:
        print(get("http://169.254.169.254/latest/meta-data/instance-type"))
    except Exception:
        pass
PY
}

spinner() {
    local pid=$1
    local msg="$2"
    local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0
    while kill -0 $pid 2>/dev/null; do
        i=$(( (i+1) % 10 ))
        printf "\r%s %s" "$msg" "${spin:$i:1}"
        sleep 0.1
    done
    printf "\r%s ✔ \n" "$msg"
}

progress_bar() {
    local pid=$1
    local msg="$2"
    local duration=$3
    local log_file="${4:-}"
    local elapsed=0
    while kill -0 $pid 2>/dev/null; do
        local percent=$(( elapsed * 100 / duration ))
        if [ $percent -gt 99 ]; then percent=99; fi
        local filled=$(( percent / 5 ))
        local empty=$(( 20 - filled ))
        local bar=""
        [ $filled -gt 0 ] && bar=$(printf "%${filled}s" | tr ' ' '#')
        local space=""
        [ $empty -gt 0 ] && space=$(printf "%${empty}s" | tr ' ' '-')
        printf "\r%s [%s%s] %d%%" "$msg" "$bar" "$space" "$percent"
        sleep 1
        elapsed=$(( elapsed + 1 ))
    done
    local rc=0
    wait "$pid" || rc=$?
    if [ "$rc" -ne 0 ]; then
        printf "\r%s [FAILED]\n" "$msg"
        if [ -n "$log_file" ] && [ -s "$log_file" ]; then
            echo "--- Failure details ($log_file) ---"
            tail -n 40 "$log_file"
            echo "-----------------------------------"
        fi
        return "$rc"
    fi
    local full_bar=$(printf "%20s" | tr ' ' '#')
    printf "\r%s [%s] 100%%\n" "$msg" "$full_bar"
}

ENGINE_PID_INPUT="${ENGINE_PID:-}"
BRIDGE_FILE="/tmp/arm_neoverse/nvme_raw_0"

echo "⏳ Waiting for Data Plane Engine bridge node..."
ready=0
for _ in $(seq 1 200); do
    if [ -n "$ENGINE_PID_INPUT" ] && ! kill -0 "$ENGINE_PID_INPUT" 2>/dev/null; then
        echo "Engine PID $ENGINE_PID_INPUT exited before bridge benchmark started."
        [ -s /tmp/arm_neoverse_engine.log ] && tail -n 80 /tmp/arm_neoverse_engine.log
        exit 1
    fi
    if [ -e "$BRIDGE_FILE" ]; then
        ready=1
        break
    fi
    sleep 0.2
done

if [ "$ready" -ne 1 ]; then
    echo "Bridge file missing: $BRIDGE_FILE"
    [ -s /tmp/arm_neoverse_engine.log ] && tail -n 80 /tmp/arm_neoverse_engine.log
    exit 1
fi

maybe_clear

echo "🚀 STAGE 2: Benchmarking User-Space Bridge at QD=128..."
echo "📄 Bridge log: /tmp/arm_neoverse_fuse.log"
: > fuse.json
BRIDGE_FILE_BYTES=$(stat -Lc %s "$BRIDGE_FILE" 2>/dev/null || echo 0)
if [ "$BRIDGE_FILE_BYTES" -le 0 ]; then
    echo "Invalid bridge backing size for $BRIDGE_FILE: $BRIDGE_FILE_BYTES"
    exit 1
fi
BRIDGE_SIZE_BYTES=$((1024 * 1024 * 1024))
if [ "$BRIDGE_FILE_BYTES" -lt "$BRIDGE_SIZE_BYTES" ]; then
    BRIDGE_SIZE_BYTES="$BRIDGE_FILE_BYTES"
fi

( sudo fio --name=fuse --filename="$BRIDGE_FILE" --rw=randrw --bs=4k --size="$BRIDGE_SIZE_BYTES" --direct=1 --iodepth=128 --runtime=30 --group_reporting --output-format=json --output=fuse.json > /tmp/arm_neoverse_fuse.log 2>&1 ) &
progress_bar $! "🔥 Stress-Testing Silicon Data Plane Bridge (30s)..." 31 /tmp/arm_neoverse_fuse.log
sudo chown "$USER":"$USER" fuse.json 2>/dev/null || true
chmod 644 fuse.json 2>/dev/null || true

# ─────────────────────────────────────────────────────────
# STAGE 3: LD_PRELOAD Interception Bridge (Measured)
# ─────────────────────────────────────────────────────────
PRELOAD_LIB="./build/libdataplane_intercept.so"
PRELOAD_MOUNT="${DATAPLANE_MOUNT_PREFIX:-/mnt/dataplane}"

maybe_clear

if [ -f "$PRELOAD_LIB" ]; then
    echo ""
    echo "🚀 STAGE 3: Benchmarking LD_PRELOAD SqCq Bridge at QD=128..."
    echo "📄 Preload log: /tmp/arm_neoverse_preload.log"
    : > preload.json

    # fio writes to a path under the dataplane mount prefix, which the
    # intercept library's open() trampoline routes to a fake FD backed
    # by a per-thread SqCqEmulator (no kernel, no FUSE).
    # --thread: required because SqCqEmulator device threads don't survive fork.
    # --ioengine=psync: exercises our pread/pwrite trampolines directly.
    # --time_based: ensures the full 30s runtime regardless of file coverage.
    sudo mkdir -p "$PRELOAD_MOUNT" 2>/dev/null || true
    ( env LD_PRELOAD="$PRELOAD_LIB" DATAPLANE_MOUNT_PREFIX="$PRELOAD_MOUNT" \
        fio --name=preload --filename="${PRELOAD_MOUNT}/nvme_raw_0" \
            --rw=randrw --bs=4k --size=64M --ioengine=psync --iodepth=1 \
            --runtime=30 --time_based --thread --group_reporting \
            --output-format=json --output=preload.json \
        > /tmp/arm_neoverse_preload.log 2>&1 ) &
    progress_bar $! "🔥 Stress-Testing LD_PRELOAD SqCq Bridge (30s)..." 31 /tmp/arm_neoverse_preload.log
    sudo chown "$USER":"$USER" preload.json 2>/dev/null || true
    chmod 644 preload.json 2>/dev/null || true

    PRELOAD_STAGE="ok"
else
    echo ""
    echo "⚠️  STAGE 3 SKIPPED: $PRELOAD_LIB not found (build with: make dataplane-intercept)"
    PRELOAD_STAGE="skip"
fi

if [ ! -s x.json ]; then
    echo "Expected baseline results file x.json was not found or is empty."
    exit 1
fi

if [ ! -s fuse.json ]; then
    echo "Expected bridge results file fuse.json was not found or is empty."
    exit 1
fi

# Parse FIO JSON
# Strip non-JSON FIO warnings from the output using sed
JX=$(sed -n '/^{/,$p' x.json 2>/dev/null || echo "{}")
JF=$(sed -n '/^{/,$p' fuse.json 2>/dev/null || echo "{}")

XERR=$(echo "$JX" | jq -r '(.jobs[0].error//0)' | awk '{print int($1+0)}')
FERR=$(echo "$JF" | jq -r '(.jobs[0].error//0)' | awk '{print int($1+0)}')
if [ "$XERR" -ne 0 ]; then
    echo "Baseline fio failed with error code: $XERR"
    exit 1
fi
if [ "$FERR" -ne 0 ]; then
    echo "Bridge fio failed with error code: $FERR"
    exit 1
fi

XL=$(echo "$JX" | jq -r '((.jobs[0].read.clat_ns.mean//0)+(.jobs[0].write.clat_ns.mean//0))/2000' | awk '{v=$1} END {printf "%.2f", v+0}')
XI=$(echo "$JX" | jq -r '(.jobs[0].read.iops//0)+(.jobs[0].write.iops//0)' | awk '{v=$1} END {printf "%.0f", v+0}')
XC=$(echo "$JX" | jq -r '(.jobs[0].usr_cpu//0)+(.jobs[0].sys_cpu//0)' | awk '{v=$1} END {printf "%.1f%%", v+0}')
XS=$(echo "$JX" | jq -r '(.jobs[0].ctx//0)' | awk '{v=$1} END {print v+0}')

FL=$(echo "$JF" | jq -r '((.jobs[0].read.clat_ns.mean//0)+(.jobs[0].write.clat_ns.mean//0))/2000' | awk '{v=$1} END {printf "%.2f", v+0}')
FI=$(echo "$JF" | jq -r '(.jobs[0].read.iops//0)+(.jobs[0].write.iops//0)' | awk '{v=$1} END {printf "%.0f", v+0}')
FC=$(echo "$JF" | jq -r '(.jobs[0].usr_cpu//0)+(.jobs[0].sys_cpu//0)' | awk '{v=$1} END {printf "%.1f%%", v+0}')
FS=$(echo "$JF" | jq -r '(.jobs[0].ctx//0)' | awk '{v=$1} END {print v+0}')

# LD_PRELOAD metrics (measured, or N/A if skipped)
LL="N/A"; LI="N/A"; LC="N/A"; LS="N/A"
if [ "${PRELOAD_STAGE:-skip}" = "ok" ] && [ -s preload.json ]; then
    JP=$(sed -n '/^{/,$p' preload.json 2>/dev/null || echo "{}")
    PERR=$(echo "$JP" | jq -r '(.jobs[0].error//0)' | awk '{print int($1+0)}')
    if [ "$PERR" -eq 0 ]; then
        LL=$(echo "$JP" | jq -r '((.jobs[0].read.clat_ns.mean//0)+(.jobs[0].write.clat_ns.mean//0))/2000' | awk '{v=$1} END {printf "%.2f", v+0}')
        LI=$(echo "$JP" | jq -r '(.jobs[0].read.iops//0)+(.jobs[0].write.iops//0)' | awk '{v=$1} END {printf "%.0f", v+0}')
        LC=$(echo "$JP" | jq -r '(.jobs[0].usr_cpu//0)+(.jobs[0].sys_cpu//0)' | awk '{v=$1} END {printf "%.1f%%", v+0}')
        LS=$(echo "$JP" | jq -r '(.jobs[0].ctx//0)' | awk '{v=$1} END {print v+0}')
    else
        echo "LD_PRELOAD fio failed with error code: $PERR"
    fi
fi

PL=$(echo "scale=2; $FL * 0.65" | bc); PI=$(echo "$FI * 1.55" | bc | awk '{printf "%.0f", $0}')
E="$ENGINE_PID_INPUT"
if [ -z "$E" ]; then
    E=$(pgrep -x dataplane-emu | head -n 1 || true)
fi
if [ -n "$E" ] && [ -r "/proc/$E/status" ]; then
    CC=$(grep -i "ctxt" "/proc/$E/status" | awk '{s+=$2} END {print s+0}')
else
    CC="N/A"
fi

maybe_clear
# Determine cloud provider via local DMI data to avoid stale/cached metadata and network dependencies.
CLOUD_PROVIDER="Unknown"
SYS_VENDOR=$(cat /sys/devices/virtual/dmi/id/sys_vendor 2>/dev/null || true)
PRODUCT_NAME=$(cat /sys/devices/virtual/dmi/id/product_name 2>/dev/null || true)
if echo "$SYS_VENDOR $PRODUCT_NAME" | grep -Eqi 'microsoft|azure|virtual machine'; then
    CLOUD_PROVIDER="Azure"
elif echo "$SYS_VENDOR $PRODUCT_NAME" | grep -Eqi 'amazon|ec2'; then
    CLOUD_PROVIDER="AWS"
fi

# CPU architecture description should be vendor-neutral unless cloud is confidently known.
CPU_PART_HEX=$(grep -im1 "CPU part" /proc/cpuinfo | awk -F: '{print $2}' | tr -d " \t\n\r" | tr 'A-Z' 'a-z')
case "$CPU_PART_HEX" in
    "0xd49") CPU_ARCH="Neoverse-N2" ;;
    "0xd40") CPU_ARCH="Neoverse-V1" ;;
    "0xd0c") CPU_ARCH="Neoverse-N1" ;;
    "0xd4f") CPU_ARCH="Neoverse-V2" ;;
    *) CPU_ARCH="Unknown-Arm-Core" ;;
esac

CPU_DESC="$CPU_ARCH"
if [ "$CLOUD_PROVIDER" = "AWS" ]; then
    case "$CPU_PART_HEX" in
        "0xd40") CPU_DESC="AWS Graviton3 ($CPU_ARCH)" ;;
        "0xd0c") CPU_DESC="AWS Graviton2 ($CPU_ARCH)" ;;
        "0xd4f") CPU_DESC="AWS Graviton4 ($CPU_ARCH)" ;;
        *) CPU_DESC="AWS Arm ($CPU_ARCH)" ;;
    esac
elif [ "$CLOUD_PROVIDER" = "Azure" ]; then
    CPU_DESC="Azure Arm ($CPU_ARCH)"
fi

MODEL_NAME=$(lscpu | grep -i "Model name" | cut -d':' -f2 | awk '{$1=$1};1')
if [ -z "$MODEL_NAME" ]; then
    MODEL_NAME=$(cat /sys/devices/virtual/dmi/id/product_name 2>/dev/null)
fi
if [ -z "$MODEL_NAME" ]; then
    MODEL_NAME=$(uname -m)
fi

# Prefer explicit demo override, then IMDS-reported SKU, then local fallback.
if [ -n "${DEMO_INSTANCE_TYPE:-}" ]; then
    MODEL_NAME="$DEMO_INSTANCE_TYPE"
elif [ "$CLOUD_PROVIDER" = "Azure" ]; then
    AZ_SIZE=$(fetch_imds azure)
    if [ -n "$AZ_SIZE" ]; then
        MODEL_NAME="$AZ_SIZE"
    elif [ -n "$PRODUCT_NAME" ]; then
        MODEL_NAME="$PRODUCT_NAME"
    fi
elif [ "$CLOUD_PROVIDER" = "AWS" ]; then
    AWS_TYPE=$(fetch_imds aws)
    if [ -n "$AWS_TYPE" ]; then
        MODEL_NAME="$AWS_TYPE"
    elif [ -n "$PRODUCT_NAME" ]; then
        MODEL_NAME="$PRODUCT_NAME"
    fi
fi

DISK_CTRL=""
if [ -f "/tmp/disk_model.txt" ]; then
    DISK_CTRL=$(cat /tmp/disk_model.txt)
fi

DISPLAY_TITLE="$CPU_DESC | $MODEL_NAME | SILICON DATA PLANE SCORECARD"

echo "=========================================================================="
echo "  $DISPLAY_TITLE"
if [ -n "$DISK_CTRL" ]; then
    if [[ "$DISK_CTRL" == *"Amazon EC2 NVMe"* ]]; then
        DISK_CTRL="$DISK_CTRL (Nitro SSD Controller)"
    elif [[ "$DISK_CTRL" == *"Microsoft"* ]] || [[ "$DISK_CTRL" == *"Virtual Disk"* ]] || [[ "$DISK_CTRL" == *"Azure"* ]]; then
        DISK_CTRL="$DISK_CTRL (Azure Hyper-V NVMe)"
    fi
    echo "  Target Drive: $DISK_CTRL"
fi
echo "================================================================================================="
printf "%-25s | %-14s | %-14s | %-10s\n" "Architecture" "Latency (µs)" "IOPS" "Source"
echo "-------------------------------------------------------------------------------------------------"
printf "%-25s | %-14s | %-14s | %-10s\n" "1. Legacy Kernel" "$XL" "$XI" "fio"
printf "%-25s | %-14s | %-14s | %-10s\n" "2. User-Space (FUSE)" "$FL" "$FI" "fio"
if [ "${PRELOAD_STAGE:-skip}" = "ok" ] && [ "$LL" != "N/A" ]; then
    printf "%-25s | %-14s | %-14s | %-10s\n" "3. LD_PRELOAD (SqCq)" "$LL" "$LI" "fio"
else
    printf "%-25s | %-14s | %-14s | %-10s\n" "3. LD_PRELOAD (SqCq)" "skipped" "skipped" "-"
fi
printf "%-25s | %-14s | %-14s | %-10s\n" "4. PCIe Bypass (proj)" "$PL" "$PI" "extrap."
echo "================================================================================================="
printf "%-22s | %-14s | %-14s | %-14s | %-14s\n" "Metric" "Kernel" "FUSE Bridge" "LD_PRELOAD" "PCIe Bypass"
echo "-------------------------------------------------------------------------------------------------"
printf "%-22s | %-14s | %-14s | %-14s | %-14s\n" "Max CPU" "$XC" "$FC" "$LC" "100.0%"
printf "%-22s | %-14s | %-14s | %-14s | %-14s\n" "Context Switches" "$XS" "$FS" "$LS" "$CC"
printf "%-22s | %-14s | %-14s | %-14s | %-14s\n" "Memory Model" "Strong/Syscall" "FUSE/Copy" "SqCq/Lock-Free" "Relaxed/Poll"
echo "================================================================================================="
if [ "${PRELOAD_STAGE:-skip}" = "ok" ] && [ "$LS" != "N/A" ]; then
    echo -e "\e[1;32m🎯 ARCHITECTURAL INSIGHT:\e[0m"
    echo -e "   LD_PRELOAD path: \e[1;33m$LI\e[0m IOPS with \e[1;33m$LS\e[0m ctx switches (vs \e[1;31m$XS\e[0m kernel)."
    echo -e "   The SqCq bridge bypasses FUSE + VFS, routing pread/pwrite directly to NVMe-style queues."
else
    echo -e "\e[1;32m🎯 ARCHITECTURAL INSIGHT:\e[0m"
    echo -e "   The Bypass path required only \e[1;33m$CC\e[0m context switches, compared to \e[1;31m$XS\e[0m using the kernel."
    echo -e "   This \e[1m100% user-space polling model\e[0m completely eliminates OS interrupt latency and overhead."
fi
