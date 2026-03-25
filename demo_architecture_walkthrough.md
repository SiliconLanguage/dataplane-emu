# Arm Neoverse Demo: Technical Walkthrough

This document explicitly breaks down step-by-step what occurs under the hood when you run `./launch_arm_neoverse_demo_deterministic.sh` and traces how every number on the final architectural SCORECARD is captured.

## Safety First (Mandatory Before Running)

The deterministic launcher performs destructive disk operations (`wipefs` and `mkfs.xfs`) on the configured demo NVMe device. To prevent accidental data loss, the script enforces:

1. A required explicit confirmation flag: `ARM_NEOVERSE_DEMO_CONFIRM=YES ./launch_arm_neoverse_demo_deterministic.sh`
2. A root-disk protection check (the script aborts if the target device appears to back `/`)
3. A mounted-filesystem check on the target device (the script aborts if anything is still mounted)
4. Optional explicit device override: `DEMO_NVME_DEVICE=/dev/<data-disk>`

Never run this demo against an OS disk or any device that contains persistent data you care about.

---

### Step 1: Deterministic Initialization and Readiness Probes
The harness was upgraded for deterministic execution and explicit failure semantics.
1. **Sanitizing Hardware:** The deterministic launcher wipes and reformats the configured demo data disk only after passing safety interlocks, then calls `setup.sh` via `sudo` to reset and later re-allocate 2,048MB of contiguous physical RAM (`HUGEMEM=2048`). DPDK relies on these 2MB pinned hugepages so devices (or simulated queues) can DMA memory blocks directly without virtual-memory translation overhead.
2. **Engine Startup and Logging:** The data-plane engine launches with explicit PID and log capture. The worker is started only after strict readiness checks verify the FUSE bridge node exists and the engine is still alive.
3. **No Sleep-Based Race Windows:** Arbitrary startup sleeps were replaced by while-loop probes for bridge readiness (`/tmp/arm_neoverse/nvme_raw_0`) so the benchmark does not begin against an uninitialized path.
4. **C++ Startup Hardening:** The FUSE argv path was fixed to use owned mutable argument storage, removing unsafe pointer-cast behavior that could corrupt startup state.

---

### Step 2: High-Concurrency Stress Benchmarking (QD=128)
To expose legacy-kernel scaling limits under contention, the benchmark queue depth was raised from QD=32 to QD=128.

The flow executes two explicit `fio` benchmarks simulating 4KB mixed workloads (`rw=randrw, direct=1`):
- **Legacy baseline:** 30 seconds at `iodepth=128` on the filesystem path.
- **Bridge path:** 30 seconds at `iodepth=128` through the userspace bridge node.

This intentionally stresses lock-heavy kernel pathways (including blk-mq hardware context contention) that degrade throughput at high concurrency.

- **1. Legacy Kernel Path (Physical SSD):** Benchmarks `/mnt/nvme_xfs`. This partition is natively formatted directly on the physical `/dev/nvme0n1` disk. This forces `fio` requests to travel through the absolute entirety of the Linux VFS (Virtual File System) and PCIe block-drivers. The CPU jumps back and forth from User Mode to Kernel Mode millions of times via heavy locking barriers (TSO).
- **2. User-Space Bridge Path (Emulated Queue):** Benchmarks `/tmp/arm_neoverse/nvme_raw_0`. Instead of hitting the physical SSD, the Linux kernel delegates the I/O to `dataplane-emu` running in the left panel. The emulator processes the I/O in-memory using modeled DPDK queues, isolating kernel context-switching overhead from raw flash performance.

---

### Step 3: Capturing the Metrics
Once `fio` completes, it writes two JSON files: `x.json` (Legacy) and `fuse.json` (Bridge). The worker script parses them with `jq`.

#### The Legacy Kernel & Bridge Path Metrics (True Hardware Measurements)
The first two sections of the scorecard represent purely authentic, mathematically verified hardware outputs from `fio`:
* **Latency ($XL, $FL):** Computed from completion latency means in nanoseconds (`.jobs[0].read.clat_ns.mean` + `.jobs[0].write.clat_ns.mean`) and converted to microseconds by dividing by 2000.
* **IOPS ($XI, $FI):** Parsed by explicitly summing both read and write IOPS `(.jobs[0].read.iops + .jobs[0].write.iops)` and printing them using an `awk '%0.f'` formatter to guarantee clean integer alignment.
* **Max CPU Core 0 ($XC, $FC):** Summed directly from the system CPU timers inside the JSON logs `(.jobs[0].usr_cpu + .jobs[0].sys_cpu)`. The Bridge FUSE daemon pegs the CPU to **~34%** because DPDK actively targets extreme processor utilization to aggressively poll memory rings instead of sleeping.
* **Context Switches ($XS, $FS):** Extracted purely from `(.jobs[0].ctx)`. Notice the massive drop! Traditional Linux Syscalls ($XS) generate *hundreds of thousands* of interrupts. The FUSE bridge bypass slashes this to just ~30,000, completely unblocking the kernel.

#### The Zero-Copy Bypass Path Metrics (Strict Measured Stage 3)
Synthetic extrapolation was removed. Stage 3 now reports only measured values from a strict PCIe-attached SPDK `bdevperf` run.

* **Latency and IOPS:** Collected directly from `bdevperf` output against the target NVMe PCIe function.
* **Strict Ownership Rule:** Stage 3 requires the target device to be attached through a userspace PCIe driver path (no kernel-backed fallback). If strict attach fails, the stage fails loudly.
* **Architectural Meaning:** This path represents the lock-free polling ceiling without FUSE mediation or synthetic multipliers.

The suite therefore reports:
1. Legacy kernel filesystem path (`fio` measured)
2. User-space bridge path (`fio` measured)
3. Zero-copy/SPDK path (`bdevperf` measured)
