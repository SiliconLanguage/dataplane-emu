# Session Handoff — Vibe Demo Scorecard Rewrite

**Date:** 2026-03-27  
**Status:** Implementation NOT started — all research complete, ready to code  
**Next Environment:** Azure Cobalt 100 (Standard_D4pds_v6) ARM64 instance with NVMe + SPDK

---

## Objective

Replace the vibe demo agent's `# SCORECARD` directive with logic that mirrors
`launch_arm_neoverse_demo_deterministic.sh` **exactly** — same fio commands,
same bdevperf invocations, same jq/awk parsing, same 3-stage × 3-QD scorecard.

### User's Exact Words

> "Please go through code/logic in launch_arm_neoverse_demo_deterministic.sh,
> and use the same logic to produce the score card, no additional hard coding
> than what launch_arm_neoverse_demo_deterministic.sh did. Also note, the same
> demo will be able to run on AWS graviton and produce report for graviton."

### What Was Rejected

1. **Hardcoded README numbers** — "So you just copied the numbers?"
2. **Loopback XFS dd probe** — "use the real demo, not smoke and mirrors"
3. Both were replaced but implementation of the REAL deterministic version has not started yet.

---

## Current File State (What Exists Now — Needs Replacement)

### `vibe_demo_agent/telemetry_sink.py`

Contains these functions that need **replacing/augmenting**:

| Function | What It Does Now | What It Should Do |
|---|---|---|
| `render_live_scorecard()` | Takes 2 values (kernel_lat, bypass_lat), renders single QD=1 box with 2 rows, computes IOPS as 1M/lat | Render full 3-stage × 3-QD scorecard (9 data points) matching deterministic script output |
| `measure_xfs_latency_us()` | Creates loopback XFS image, formats, mounts, runs `dd` reads | Not needed — replaced by real fio on real NVMe XFS |
| `measure_kernel_latency_us()` | Runs `dd` to /tmp | Not needed — replaced by real fio |

### `vibe_demo_agent/vibe_demo_agent.py`

The `# SCORECARD` directive handler (around line 298) currently:
1. Calls `measure_xfs_latency_us()` (loopback dd)
2. Reads bypass latency from telemetry SHM
3. Calls `render_live_scorecard(xfs_us, bypass_us)`

**Needs to be replaced** with the full deterministic benchmark orchestration.

### `vibe_demo_agent/scenario_1.sh`

Current flow: `ENGINE_START` → `ENGINE_SUMMARY` → `SCORECARD 10000` → `ENGINE_STOP` → `HIRE_ME`

The `# VOICE` lines reference "loopback XFS" — need updating to match the real 3-stage benchmark.

---

## Reference: `launch_arm_neoverse_demo_deterministic.sh` Logic (830 lines)

### Config Variables (lines 7-16)
```bash
RUNTIME="${DEMO_RUNTIME_SEC:-30}"
IODEPTH="${DEMO_IODEPTH:-128}"
IODEPTH_MID="${DEMO_MID_IODEPTH:-32}"
BS="${DEMO_BS:-4k}"
SIZE="${DEMO_SIZE:-4G}"
RWMIXREAD="${DEMO_RWMIXREAD:-50}"
```

### Cloud Detection (lines 22-30) — DMI-based, no network
```bash
SYS_VENDOR="$(cat /sys/devices/virtual/dmi/id/sys_vendor 2>/dev/null || true)"
PRODUCT_NAME="$(cat /sys/devices/virtual/dmi/id/product_name 2>/dev/null || true)"
# grep -Eqi 'microsoft|azure' → "azure"
# grep -Eqi 'amazon|ec2' → "aws"
# else → "unknown"
```

### Stage 3 Driver Selection (lines 37-46)
- **Azure** → `STAGE3_DRIVER="kernel"`, `STAGE3_MODE="uring"` (bdev_uring, io_uring passthrough)
- **AWS** → `STAGE3_DRIVER="vfio-pci"`, `STAGE3_MODE="pcie"` (bdev_nvme, true PCIe bypass)

### NVMe Device Auto-Detection (lines 177-189)
```bash
ROOT_SRC=$(findmnt -n -o SOURCE /)
ROOT_DISK=$(lsblk -no PKNAME "$ROOT_SRC" | head -n 1)
DATA_DISK=$(lsblk -d -no NAME | grep -E '^nvme[0-9]+n1$' | grep -v "^${ROOT_DISK}$" | head -n 1)
D="/dev/$DATA_DISK"
```

### Stage 1: Kernel fio on XFS (lines 440-458)
```bash
sudo mkfs.xfs -f "$D"
sudo mount "$D" "$X"
for _qd in 1 "$IODEPTH_MID" "$IODEPTH"; do
    sudo fio --name=base --directory="$X" --rw=randrw --bs="$BS" --size="$SIZE" \
        --ioengine=libaio --direct=1 --iodepth="$_qd" \
        --runtime="$RUNTIME" --time_based --group_reporting \
        --output-format=json --output="x_qd${_qd}.json"
done
sudo umount -l "$X"
```

### Stage 2: FUSE Bridge fio (lines 460-510)
```bash
sudo ./build/dataplane-emu -m "$C" -d "$D" -b -k > "$ENGINE_LOG" 2>&1 &
# Wait for $C/nvme_raw_0 readiness (up to 30s)
# Run fio at QD=1, QD=mid, QD=max against $C/nvme_raw_0
sudo fio --name=fuse --filename="$C/nvme_raw_0" --rw=randrw --bs="$BS" \
    --size="$BRIDGE_SIZE_BYTES" --ioengine=libaio --direct=1 --iodepth="$_qd" \
    --runtime="$RUNTIME" --time_based --group_reporting \
    --output-format=json --output="fuse_qd${_qd}.json"
# Kill engine, reset SPDK, wait for block device to reappear
```

### Stage 3: SPDK bdevperf (lines 560-730)

**Azure path** (bdev_uring):
```json
{"subsystems":[{"subsystem":"bdev","config":[
  {"method":"bdev_uring_create","params":{"name":"Uring0","filename":"/dev/nvmeXn1","block_size":512}}
]}]}
```
```bash
sudo LD_LIBRARY_PATH="$SPDK_LD_PATH" "$BDEVPERF_BIN" -c "$BDEV_CFG" \
    -q $QD -o 4096 -w randrw -M "$RWMIXREAD" -t "$RUNTIME"
```

**AWS path** (bdev_nvme via vfio-pci):
```json
{"subsystems":[{"subsystem":"bdev","config":[
  {"method":"bdev_nvme_attach_controller","params":{"name":"Nvme0","trtype":"PCIe","traddr":"$TARGET_BDF"}}
]}]}
```
Same bdevperf invocation, different config.

### Result Parsing (lines 740-780)

**fio JSON parsing:**
```bash
# Latency (µs): average of read + write clat_ns means, divided by 2000
jq -r '((.jobs[0].read.clat_ns.mean//0)+(.jobs[0].write.clat_ns.mean//0))/2000' "$json"

# IOPS: sum of read + write
jq -r '(.jobs[0].read.iops//0)+(.jobs[0].write.iops//0)' "$json"
```

**bdevperf log parsing:**
```bash
# Total line format: "  Total : IOPS MiB/s Fail/s TO/s AvgLat min max"
total=$(grep -E '^[[:space:]]*Total[[:space:]]*:' "$log" | tail -n 1 | sed 's/.*://')
iops=$(echo "$total" | awk '{printf "%.0f", $1+0}')
lat=$(echo "$total" | awk '{printf "%.2f", $5+0}')
```

### Scorecard Header Construction (README-level, not in script but needed)

The README scorecard uses this header detected from hardware:
```
Azure Cobalt 100 (Neoverse-N2) | Standard_D4pds_v6 | SILICON DATA PLANE SCORECARD
Target Drive: Microsoft NVMe Direct Disk v2 (Azure Hyper-V NVMe)
```

**CPU detection** (from `/proc/cpuinfo`):
```
CPU part 0xd49 → Neoverse-N2 (Azure Cobalt 100 / Graviton3E)
CPU part 0xd40 → Neoverse-V1 (Graviton3)
CPU part 0xd4f → Neoverse-V2 (Graviton4)
```

**Instance type detection:**
- Azure IMDS: `curl -s -H Metadata:true "http://169.254.169.254/metadata/instance?api-version=2021-02-01"` → `.compute.vmSize`
- AWS IMDS: `curl -s http://169.254.169.254/latest/meta-data/instance-type`
- Disk model: `lsblk -d -no MODEL /dev/nvmeXn1` (save to `/tmp/disk_model.txt`)

### Stage 3 Label Strings
```
Azure: "bdev_uring (io_uring → Azure Boost mediated passthrough)"
AWS:   "bdev_nvme (vfio-pci → PCIe bypass, no-IOMMU / Nitro DMA isolation)"
```

---

## Implementation Plan

### 1. Create `vibe_demo_agent/benchmark_runner.py` (NEW FILE)

A Python module that orchestrates the 3-stage deterministic benchmark using `subprocess`.
It should contain:

```python
def detect_cloud_provider() -> str:
    """DMI-based: returns 'azure', 'aws', or 'unknown'."""

def detect_cpu_desc() -> str:
    """Parse /proc/cpuinfo CPU part → 'Neoverse-N2', etc."""

def detect_instance_type(cloud: str) -> str:
    """IMDS fetch for Azure/AWS, fallback to DMI product_name."""

def detect_nvme_device() -> str:
    """Auto-detect non-root NVMe device. Returns '/dev/nvmeXn1'."""

def detect_disk_model(device: str) -> str:
    """lsblk -d -no MODEL device."""

def select_stage3(cloud: str) -> tuple[str, str, str]:
    """Returns (mode, driver, label) — 'uring'/'pcie', driver name, display label."""

def run_fio(directory_or_file: str, qd: int, runtime: int, bs: str,
            size: str, rwmixread: int, output_json: str, is_file: bool = False) -> None:
    """Run sudo fio with the exact flags from the deterministic script."""

def parse_fio(json_path: str) -> tuple[float, int]:
    """Parse fio JSON → (lat_us, iops) using same jq expressions."""

def run_bdevperf(bdevperf_bin: str, config_json: str, qd: int,
                 rwmixread: int, runtime: int, log_path: str) -> None:
    """Run sudo bdevperf with LD_LIBRARY_PATH."""

def parse_bdevperf(log_path: str) -> tuple[float, int]:
    """Parse bdevperf Total line → (lat_us, iops)."""

class BenchmarkResults:
    """Holds all 9 data points + metadata."""
    # kernel: (lat, iops) × 3 QDs
    # fuse:   (lat, iops) × 3 QDs
    # spdk:   (lat, iops) × 3 QDs
    # metadata: cpu_desc, instance_type, disk_model, stage3_label, bs, runtime, rwmixread, qd_mid

def run_deterministic_benchmark(
    runtime=30, bs='4k', size='4G', rwmixread=50,
    iodepth_max=128, iodepth_mid=32,
    verbose_cb=None,
) -> BenchmarkResults:
    """Full 3-stage orchestration matching launch_arm_neoverse_demo_deterministic.sh."""
```

### 2. Update `vibe_demo_agent/telemetry_sink.py`

Add `render_deterministic_scorecard(results: BenchmarkResults) -> str` that renders
the full 3-box scorecard with header, matching the exact box-drawing format from the
deterministic bash script. Keep existing functions (they're used by other directives).

### 3. Update `vibe_demo_agent/vibe_demo_agent.py`

Replace the `# SCORECARD` directive handler to:
1. Import `benchmark_runner`
2. Call `run_deterministic_benchmark()` with optional params from the directive
3. Call `render_deterministic_scorecard(results)`
4. Print the result

### 4. Update `vibe_demo_agent/scenario_1.sh`

- Remove `ENGINE_START benchmark` / `ENGINE_SUMMARY` / `ENGINE_STOP` around SCORECARD
  (the benchmark runner handles Stage 2 engine lifecycle internally)
- Update VOICE lines to describe the real 3-stage sweep
- The `# SCORECARD` directive becomes the main event

### 5. Key Constraints

- **No additional hardcoding** beyond what the bash script does
- **Works on both Azure and AWS** — cloud detection → driver selection → correct bdevperf config
- **Requires real ARM64 cloud instance** with NVMe and SPDK installed
- **Graceful degradation**: if SPDK not available, show Stage 3 as "N/A" (same as bash script)
- fio JSON files go to `/tmp/` (working dir), bdevperf logs to `/tmp/arm_neoverse_*.log`
- Safety interlocks: refuse to touch root disk, validate block device

---

## Files to Read First on Azure

| File | Why |
|---|---|
| `vibe_demo_agent/telemetry_sink.py` | Current render functions to augment |
| `vibe_demo_agent/vibe_demo_agent.py` | SCORECARD directive handler to update |
| `vibe_demo_agent/scenario_1.sh` | Demo flow/voiceover to update |
| `launch_arm_neoverse_demo_deterministic.sh` | THE reference — all logic comes from here |
| This file | Context transfer |

---

## Environment Notes

- **Previous session ran on:** WSL2 Ubuntu 24.04, dragonix02, Intel x86_64 — could NOT run real benchmarks
- **Next session target:** Azure Cobalt 100 (Neoverse-N2), Standard_D4pds_v6, real NVMe
- SPDK should be built with `-mcpu=neoverse-n2` and io_uring support
- Verify `fio`, `jq`, `bdevperf` are available before starting
- The dataplane-emu binary must be built: `cmake -B build && cmake --build build`
