# Arm Neoverse Demo: Technical Walkthrough

This document breaks down step-by-step what occurs under the hood when you run `./launch_arm_neoverse_demo.sh` and traces how every number on the final four-tier architectural SCORECARD is captured.

## Safety First (Mandatory Before Running)

The launcher performs destructive disk operations (`wipefs` and `mkfs.xfs`) on the configured demo NVMe device. To prevent accidental data loss, the script enforces:

1. A required explicit confirmation flag: `ARM_NEOVERSE_DEMO_CONFIRM=YES ./launch_arm_neoverse_demo.sh`
2. A root-disk protection check (the script aborts if the target device appears to back `/`)
3. A mounted-filesystem check on the target device (the script aborts if anything is still mounted)
4. Optional explicit device override: `DEMO_NVME_DEVICE=/dev/<data-disk>`

Never run this demo against an OS disk or any device that contains persistent data you care about.

---

### Step 1: Deterministic Initialization and Readiness Probes
The harness enforces deterministic execution and explicit failure semantics.
1. **Sanitizing Hardware:** The launcher wipes and reformats the configured demo data disk only after passing safety interlocks, then calls SPDK `setup.sh` via `sudo` to reset and later re-allocate 2,048 MB of contiguous physical RAM (`HUGEMEM=2048`). DPDK relies on these 2 MB pinned hugepages so devices (or simulated queues) can DMA memory blocks directly without virtual-memory translation overhead.
2. **Engine Startup and Logging:** The data-plane engine (`dataplane-emu`) launches with explicit PID and log capture. The worker is started only after strict readiness checks verify the FUSE bridge node exists and the engine is still alive.
3. **No Sleep-Based Race Windows:** Arbitrary startup sleeps were replaced by while-loop probes for bridge readiness (`/tmp/arm_neoverse/nvme_raw_0`) so benchmarks do not begin against an uninitialized path.
4. **C++ Startup Hardening:** The FUSE argv path uses owned mutable argument storage, removing unsafe pointer-cast behavior that could corrupt startup state.

---

### Step 2: Three-Stage Stress Benchmarking
The demo runs three measured `fio` benchmarks (4 KB mixed random read/write, `rw=randrw`) to progressively strip away kernel overhead, followed by a projected fourth stage.

#### Stage 1 — Legacy Kernel Path (QD=128)
Benchmarks `/mnt/nvme_xfs`, a partition formatted directly on the physical NVMe data disk. Every `fio` request traverses the full Linux VFS, block layer, and PCIe drivers. The CPU context-switches between user and kernel mode hundreds of thousands of times under heavy locking barriers.

```
fio --name=base --directory=/mnt/nvme_xfs --rw=randrw --bs=4k --size=4G \
    --direct=1 --iodepth=128 --runtime=30 --time_based --group_reporting \
    --output-format=json --output=x.json
```

#### Stage 2 — User-Space FUSE Bridge (QD=128)
Benchmarks `/tmp/arm_neoverse/nvme_raw_0`. Instead of hitting the physical SSD, the kernel delegates I/O to `dataplane-emu` running in the left tmux pane. The emulator processes I/O in-memory using modeled DPDK queues, isolating kernel context-switching overhead from raw flash performance.

```
fio --name=fuse --filename=/tmp/arm_neoverse/nvme_raw_0 --rw=randrw --bs=4k \
    --size=<bridge_file_bytes> --direct=1 --iodepth=128 --runtime=30 \
    --group_reporting --output-format=json --output=fuse.json
```

#### Stage 3 — LD_PRELOAD SqCq Bridge (QD=1, psync)
Benchmarks a virtual path under the dataplane mount prefix (e.g. `/mnt/dataplane/nvme_raw_0`). The `libdataplane_intercept.so` shared library is injected via `LD_PRELOAD`. Its glibc trampolines (`open`, `close`, `pread`, `pwrite`, `read`, `write`, `fstat64`, `lseek64`, `ftruncate64`, `fallocate64`, `fsync`, `fdatasync`, `posix_fadvise`) intercept every POSIX call destined for the mount prefix and route it directly to a per-thread `SqCqEmulator` — no kernel, no FUSE, no VFS.

Critical `fio` flags for LD_PRELOAD compatibility:
* **`--thread`** — Required. `fio` defaults to `fork()`, which kills `SqCqEmulator` device threads in the child process (symptom: throughput drops to ~3 IOPS). Using `--thread` keeps everything in one address space.
* **`--ioengine=psync`** — Required. `libaio` and `io_uring` bypass glibc and issue syscalls directly, evading the LD_PRELOAD trampolines entirely. `psync` exercises `pread`/`pwrite` through glibc.
* **`--time_based`** — Ensures the full 30-second runtime regardless of file coverage.

```
env LD_PRELOAD=./build/libdataplane_intercept.so \
    DATAPLANE_MOUNT_PREFIX=/mnt/dataplane \
  fio --name=preload --filename=/mnt/dataplane/nvme_raw_0 \
      --rw=randrw --bs=4k --size=64M --ioengine=psync --iodepth=1 \
      --runtime=30 --time_based --thread --group_reporting \
      --output-format=json --output=preload.json
```

#### Stage 4 — PCIe Bypass (Projected)
The fourth row is extrapolated from the FUSE bridge measurements, not measured directly. True PCIe bypass requires VFIO passthrough of the NVMe device to userspace (SPDK `bdevperf`). On current Azure VMs, VFIO attach fails (errno −22, no IOMMU group exposed by the hypervisor), so Stage 4 remains a projection:

* **Latency:** `FL × 0.65` (FUSE latency scaled by the expected polling-path reduction)
* **IOPS:** `FI × 1.55` (FUSE IOPS scaled by the expected lock-free throughput gain)

When a platform with working VFIO becomes available, this row will switch to strict `bdevperf` measurements.

---

### Step 3: Capturing the Metrics
Once each `fio` stage completes, it writes a JSON file: `x.json` (Legacy), `fuse.json` (FUSE Bridge), and `preload.json` (LD_PRELOAD). The worker script parses them with `jq`.

#### Stages 1–3: Measured Metrics
All three measured stages use the same `jq` extraction pattern:
* **Latency (`$XL`, `$FL`, `$LL`):** Computed from completion latency means in nanoseconds (`.jobs[0].read.clat_ns.mean` + `.jobs[0].write.clat_ns.mean`) and converted to microseconds by dividing by 2000.
* **IOPS (`$XI`, `$FI`, `$LI`):** Summed from read and write IOPS `(.jobs[0].read.iops + .jobs[0].write.iops)`, formatted as a clean integer.
* **Max CPU (`$XC`, `$FC`, `$LC`):** Summed from `(.jobs[0].usr_cpu + .jobs[0].sys_cpu)`.
* **Context Switches (`$XS`, `$FS`, `$LS`):** Extracted from `(.jobs[0].ctx)`. The LD_PRELOAD path typically reports **0** context switches because every I/O completes entirely in user-space memory — no syscalls, no interrupts.

#### Stage 4: Projected Metrics
The PCIe Bypass row is derived arithmetically from the FUSE measurements (`$PL = FL × 0.65`, `$PI = FI × 1.55`). CPU is hardcoded to 100% (full polling) and context switches are read from the engine's `/proc/<pid>/status` voluntary/involuntary counters.

#### Source Column
The scorecard includes a **Source** column to make measurement provenance explicit:

| Architecture | Latency (µs) | IOPS | Source |
|---|---|---|---|
| 1. Legacy Kernel | `$XL` | `$XI` | fio |
| 2. User-Space (FUSE) | `$FL` | `$FI` | fio |
| 3. LD_PRELOAD (SqCq) | `$LL` | `$LI` | fio |
| 4. PCIe Bypass (proj) | `$PL` | `$PI` | extrap. |

The suite therefore reports four tiers:
1. Legacy kernel filesystem path (`fio` measured)
2. User-space FUSE bridge path (`fio` measured)
3. LD_PRELOAD SqCq bridge path (`fio` measured)
4. PCIe bypass path (extrapolated — awaiting VFIO platform support)
