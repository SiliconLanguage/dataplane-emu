# Arm Neoverse Demo: Technical Walkthrough

This document breaks down step-by-step what occurs under the hood when you run `bash demo_QD_1_32_128.sh` (or `./launch_arm_neoverse_demo_deterministic.sh` directly) and traces how every number on the three-tier, multi-queue-depth architectural SCORECARD is captured.

## Safety First (Mandatory Before Running)

The launcher performs destructive disk operations (`wipefs` and `mkfs.xfs`) on the configured demo NVMe device. To prevent accidental data loss, the script enforces:

1. A required explicit confirmation flag: `ARM_NEOVERSE_DEMO_CONFIRM=YES ./launch_arm_neoverse_demo_deterministic.sh`
2. A root-disk protection check (the script aborts if the target device appears to back `/`)
3. A mounted-filesystem check on the target device (the script aborts if anything is still mounted)
4. Optional explicit device override: `DEMO_NVME_DEVICE=/dev/<data-disk>`

Never run this demo against an OS disk or any device that contains persistent data you care about.

---

### Step 1: Deterministic Initialization and Readiness Probes
The harness enforces deterministic execution and explicit failure semantics.
1. **Build & Dependency Phase:** The launcher auto-detects the package manager (dnf on Amazon Linux 2023, apt on Ubuntu) and installs all required dependencies. It rebuilds SPDK with io_uring support if needed, and ensures the `dataplane-emu` binary is compiled via cmake.
2. **Device Discovery & BDF Resolution:** The script locates the NVMe data disk, resolves its PCI Bus/Device/Function (BDF) address via sysfs, and verifies it is not the root disk. On AWS Graviton (c7gd), the ephemeral NVMe is typically `0000:00:1f.0`.
3. **Sanitizing Hardware:** The launcher wipes and reformats the NVMe data disk only after passing safety interlocks. If SPDK is available, it calls `setup.sh reset` to release any prior vfio-pci bindings.
4. **Engine Startup and Logging:** The data-plane engine (`dataplane-emu`) launches with explicit PID and log capture. The worker is started only after strict readiness checks verify the FUSE bridge node exists and the engine is still alive.
5. **No Sleep-Based Race Windows:** Arbitrary startup sleeps were replaced by while-loop probes for bridge readiness (`/tmp/arm_neoverse/nvme_raw_0`) so benchmarks do not begin against an uninitialized path.
6. **C++ Startup Hardening:** The FUSE argv path uses owned mutable argument storage (static `char[4096]` buffer for the signal handler), removing unsafe pointer-cast behavior that could corrupt startup state.

---

### Step 2: Three-Stage Multi-QD Stress Benchmarking
The demo sweeps three queue depths — QD=1 (latency), QD=16 or 32 (knee-of-curve), and QD=128 (throughput saturation) — across three architectural tiers using 4 KB mixed random read/write (`rw=randrw`, 50/50 read/write mix, 30-second runtime per run).

The mid-QD is configurable via `DEMO_MID_IODEPTH` (default: 32, or 16 via the `demo_QD_1_32_128.sh` wrapper).

#### Stage 1 — Legacy Kernel Path (QD=1, QD=mid, QD=128)
Benchmarks `/mnt/nvme_xfs`, a partition formatted on the physical NVMe data disk. Every `fio` request traverses the full Linux VFS, XFS filesystem, block layer, and the kernel NVMe driver. The CPU context-switches between user and kernel mode hundreds of thousands of times under heavy locking barriers.

```bash
sudo fio --name=base --directory=/mnt/nvme_xfs --rw=randrw --bs=4k --size=4G \
    --ioengine=libaio --direct=1 --iodepth=$QD \
    --runtime=30 --time_based --group_reporting \
    --output-format=json --output=x_qd${QD}.json
```

This runs three times: once each at QD=1, QD=mid, and QD=128.

#### Stage 2 — User-Space FUSE Bridge (QD=1, QD=mid, QD=128)
Benchmarks `/tmp/arm_neoverse/nvme_raw_0`. `dataplane-emu` serves I/O via a FUSE mount backed by `pread()`/`pwrite()` against the raw block device. The FUSE bridge eliminates filesystem overhead but still incurs two privilege transitions per I/O (user → kernel → FUSE daemon → kernel → user).

The bridge file size is auto-detected from `stat` to avoid overrunning the virtual file boundary. Hugepages (2048 MB) are allocated via SPDK's `setup.sh` if available.

```bash
sudo fio --name=fuse --filename=/tmp/arm_neoverse/nvme_raw_0 --rw=randrw --bs=4k \
    --size=$BRIDGE_SIZE_BYTES --ioengine=libaio --direct=1 --iodepth=$QD \
    --runtime=30 --time_based --group_reporting \
    --output-format=json --output=fuse_qd${QD}.json
```

After all Stage 2 fio runs complete, the engine is killed, the FUSE mount is unmounted, and SPDK bindings are reset to release the NVMe device back to the kernel. The script waits up to 15 seconds for the block device to reappear before proceeding.

#### Stage 3 — SPDK PCIe Bypass via bdevperf (QD=1, QD=mid, QD=128)
**This is a real, measured kernel-bypass path** — no extrapolation. The NVMe device is unbound from the kernel `nvme` driver and rebound to `vfio-pci`, then SPDK's `bdevperf` polls the NVMe controller directly via PCIe.

##### Preflight Checks
1. **IOMMU groups:** EC2 Nitro does not expose a vIOMMU to guest VMs. If no IOMMU groups exist, the script enables `vfio` no-IOMMU mode (`enable_unsafe_noiommu_mode=1`). This is safe because Nitro provides DMA isolation at the hypervisor level.
2. **vfio-pci module:** Loaded via `modprobe vfio-pci` if not already present.
3. **PCI rebind:** The NVMe BDF is unbound from the kernel `nvme` driver and bound to `vfio-pci` via sysfs `driver_override` + `unbind` + `bind`. The script verifies the driver symlink reads `vfio-pci` before proceeding.
4. **Strict failure:** If any preflight check fails, the script exits immediately with diagnostics. There are **no fallback paths** (no bdev_aio, no bdev_uring, no kernel I/O fallbacks).

##### bdevperf Configuration
A JSON config attaches the NVMe controller to SPDK's bdev layer:
```json
{
    "subsystems": [{
        "subsystem": "bdev",
        "config": [{
            "method": "bdev_nvme_attach_controller",
            "params": {
                "name": "Nvme0",
                "trtype": "PCIe",
                "traddr": "0000:00:1f.0"
            }
        }]
    }]
}
```

##### bdevperf Runs
```bash
# Latency (QD=1)
sudo bdevperf -c /tmp/arm_neoverse_bdevperf.json -q 1 -o 4096 -w randrw -M 50 -t 30

# Knee-of-curve (QD=mid)
sudo bdevperf -c /tmp/arm_neoverse_bdevperf.json -q $MID -o 4096 -w randrw -M 50 -t 30

# Throughput (QD=128)
sudo bdevperf -c /tmp/arm_neoverse_bdevperf.json -q 128 -o 4096 -w randrw -M 50 -t 30
```

Each run writes to a separate log file (`bdevperf_lat.log`, `bdevperf_mid.log`, `bdevperf_iops.log`).

##### Cleanup
After Stage 3, the `cleanup` trap unbinds `vfio-pci` and restores the original kernel `nvme` driver via `driver_override` reset + `drivers_probe`, so the NVMe device returns to normal kernel operation.

---

### Step 3: Capturing the Metrics

#### Stages 1 & 2: fio JSON Extraction
Each fio run writes a JSON file: `x_qd1.json`, `x_qd${mid}.json`, `x_qd128.json` (kernel) and `fuse_qd1.json`, `fuse_qd${mid}.json`, `fuse_qd128.json` (FUSE bridge). The `parse_fio` function extracts:

* **Latency:** Average of read and write completion latency means: `(read.clat_ns.mean + write.clat_ns.mean) / 2000` → microseconds.
* **IOPS:** Sum of read and write IOPS: `read.iops + write.iops`, formatted as an integer.

#### Stage 3: bdevperf Log Parsing
`bdevperf` outputs a `Total` summary line at the end of each run. The `parse_bdevperf` function extracts:

* **IOPS:** Field 1 of the Total line.
* **Latency (μs):** Field 5 (AvgLat) of the Total line.

If the Total line is missing, a fallback regex grep for `IOPS` is attempted (throughput only).

#### Source Provenance
All three stages are **directly measured** — no extrapolation:

| Stage | Tool | Driver Path |
|---|---|---|
| 1. Kernel (XFS + fio) | fio (libaio) | kernel nvme → block layer → XFS → VFS |
| 2. User-Space Bridge (FUSE) | fio (libaio) | kernel → FUSE → dataplane-emu → pread/pwrite |
| 3. SPDK Zero-Copy (bdevperf) | bdevperf | vfio-pci → SPDK NVMe driver → PCIe DMA |

---

### Step 4: The Scorecard

The final output is a three-panel scorecard — one panel per queue depth — showing all three architectural tiers side-by-side:

```console
════════════════════════════════════════════════════════════════════════════
  DETERMINISTIC SILICON DATA PLANE SCORECARD
════════════════════════════════════════════════════════════════════════════
  Config: bs=4k  runtime=30s  rwmix=50/50  mid-QD=16
  Stage 3: bdev_nvme (vfio-pci → PCIe bypass)
────────────────────────────────────────────────────────────────────────────

  ┌─ Latency (QD=1) ──────────────────────────────────────────────────────┐
  │ Architecture                         Avg (μs)          IOPS          │
  │ ──────────────────────────────  ────────────  ────────────          │
  │ 1. Kernel (XFS + fio)                    50.18         19178          │
  │ 2. User-Space Bridge (FUSE)              24.03         33645          │
  │ 3. SPDK Zero-Copy (bdevperf)             22.16         44994          │
  └────────────────────────────────────────────────────────────────────────┘

  ┌─ Knee-of-Curve (QD=16) ───────────────────────────────────────────────┐
  │ Architecture                         Avg (μs)          IOPS          │
  │ ──────────────────────────────  ────────────  ────────────          │
  │ 1. Kernel (XFS + fio)                   226.02         70158          │
  │ 2. User-Space Bridge (FUSE)             233.07         64550          │
  │ 3. SPDK Zero-Copy (bdevperf)            227.98         70161          │
  └────────────────────────────────────────────────────────────────────────┘

  ┌─ Throughput (QD=128) ──────────────────────────────────────────────────┐
  │ Architecture                         Avg (μs)          IOPS          │
  │ ──────────────────────────────  ────────────  ────────────          │
  │ 1. Kernel (XFS + fio)                  1878.97         68038          │
  │ 2. User-Space Bridge (FUSE)            2065.59         61502          │
  │ 3. SPDK Zero-Copy (bdevperf)           1880.66         68056          │
  └────────────────────────────────────────────────────────────────────────┘
════════════════════════════════════════════════════════════════════════════
```

*Measured on AWS Graviton3 (Neoverse-V1) c7gd.xlarge, Amazon EC2 NVMe Instance Storage (Nitro SSD Controller), SPDK v26.01, compiled with `-mcpu=neoverse-v1 -moutline-atomics`.*

---

### Performance Analysis: The QD Sweep

The three queue depths reveal different bottlenecks:

1. **QD=1 (Latency):** Exposes per-I/O overhead. At QD=1, the kernel path is dominated by the XFS → VFS → block layer → NVMe driver round-trip (~50 μs). The FUSE bridge halves this by serving from the dataplane engine (~24 μs). SPDK's polling path shaves another ~2 μs by eliminating the FUSE protocol and privilege transitions (~22 μs, 2.3× over kernel).

2. **QD=16 (Knee-of-Curve):** The NVMe controller's internal parallelism saturates. All three paths converge toward the device's peak throughput (~70K IOPS), revealing that the Nitro SSD controller itself — not the software stack — becomes the bottleneck once sufficient queue depth exposes hardware parallelism.

3. **QD=128 (Throughput Saturation):** Confirms the device-limited regime. IOPS are nearly identical across all three paths (~68K), with latency scaling linearly with queue depth (~1.9 ms). The FUSE bridge shows slightly higher latency (~2.1 ms) due to the per-I/O context-switch tax accumulating under contention.

The key insight: **SPDK's advantage is most pronounced at low queue depths** (QD=1), where per-I/O software overhead dominates. At high queue depths, the NVMe device itself becomes the bottleneck and the kernel path catches up.

---

### Environment Variables

| Variable | Default | Description |
|---|---|---|
| `ARM_NEOVERSE_DEMO_CONFIRM` | — | Must be `YES` to run |
| `DEMO_NVME_DEVICE` | auto-detect | Override target NVMe block device |
| `DEMO_MID_IODEPTH` | 32 | Middle queue depth for knee-of-curve |
| `DEMO_IODEPTH` | 128 | High queue depth for throughput |
| `DEMO_RUNTIME_SEC` | 30 | Seconds per fio/bdevperf run |
| `DEMO_BS` | 4k | Block size |
| `DEMO_RWMIXREAD` | 50 | Read percentage (50 = 50/50 mix) |
| `DEMO_STAGE3_DRIVER` | vfio-pci | PCI driver for Stage 3 |
| `DEMO_SKIP_BUILD` | 0 | Set to 1 to skip build phase |
| `DEMO_BDEVPERF_BIN` | auto-detect | Override path to bdevperf binary |

---

### Log Files

| Log | Contents |
|---|---|
| `/tmp/arm_neoverse_base.log` | Stage 1 kernel fio output |
| `/tmp/arm_neoverse_fuse.log` | Stage 2 FUSE bridge fio output |
| `/tmp/arm_neoverse_spdk_setup.log` | SPDK setup/reset output |
| `/tmp/arm_neoverse_bdevperf_lat.log` | Stage 3 bdevperf QD=1 |
| `/tmp/arm_neoverse_bdevperf_mid.log` | Stage 3 bdevperf QD=mid |
| `/tmp/arm_neoverse_bdevperf_iops.log` | Stage 3 bdevperf QD=128 |
| `/tmp/arm_neoverse_engine.log` | dataplane-emu FUSE engine output |
