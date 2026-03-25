# Engineering Retrospective and Architectural Runbook

**dataplane-emu: A Zero-Kernel, Zero-Copy Storage Engine for ARM64 AI Infrastructure**

> *"The fastest I/O is the I/O the kernel never sees."*

---

## Table of Contents

1. [The Vision & Planning](#1-the-vision--planning)
2. [Overcoming Roadblocks](#2-overcoming-roadblocks)
3. [The Result: The J-Curve Hardware Truth](#3-the-result-the-j-curve-hardware-truth)
4. [The Future Roadmap](#4-the-future-roadmap)

---

## 1. The Vision & Planning

### The Problem: Why Kernels Kill AI Throughput

Modern AI training pipelines ingest terabytes of checkpoint and dataset I/O per hour. Every `pread()` call in a conventional Linux stack traverses the Virtual File System, the block layer, a hardware dispatch queue, an interrupt handler, and two privilege transitions — User Mode to Kernel Mode and back. At Queue Depth 128, that architecture doesn't bend. It breaks.

On ARM64 Neoverse silicon (AWS Graviton3, Azure Cobalt 100), the weak memory model amplifies the cost further: every kernel-mediated I/O fence becomes a full pipeline drain across the interconnect. We measured hundreds of thousands of involuntary context switches per 30-second benchmark window — each one a cache-cold restart on the CPU's branch predictor and TLB.

The `dataplane-emu` project was founded on a single architectural bet: **eliminate every layer between the application and the storage silicon**. Not optimize it. Not cache around it. Remove it.

### Architectural Foundations: 0-Kernel, 0-Copy

We designed a three-pillar architecture, drawing directly from the state of the art in high-performance storage systems:

#### Pillar 1 — Seamless POSIX Interception (Intel DAOS `libpil4dfs`)

Intel's Data Access Object Store (DAOS) proved that you don't need to modify applications to bypass the kernel. Their `libpil4dfs` library uses `LD_PRELOAD` to inject a shared library ahead of `glibc`, resolving original libc symbols via `dlsym(RTLD_NEXT, ...)` at library construction time. Every subsequent `open()`, `pread()`, `pwrite()`, and `close()` call hits a 1-level trampoline: a single branch checks whether the file descriptor belongs to the data plane. If yes, the call routes to user-space queues. If no, the original libc function executes with zero overhead beyond the branch.

The critical innovation is the **Fake File Descriptor** table. When `open()` intercepts a path under the data plane mount prefix, it mints a synthetic FD in an elevated integer range (we use `≥ 1,000,000`) — far above anything the Linux kernel would allocate. This makes the routing check a single integer comparison: `O(1)`, lock-free, and branchless on the fast path.

Our implementation (`libdataplane_intercept.so`) extends this pattern with a 32,768-slot `FakeFdTable` where each slot is `alignas(64)` to prevent false sharing across threads. Allocation and release use `compare_exchange_strong` with `memory_order_acq_rel` — no mutexes, no spinlocks, no contention.

#### Pillar 2 — Lock-Free Asynchronous I/O Bridging (DeepSeek 3FS `USRBIO`)

DeepSeek's Fire-File-System (3FS) demonstrated that the synchronous POSIX interface doesn't have to mean synchronous execution. Their USRBIO API maps I/O requests into shared-memory ring buffers (`Ior` — I/O Rings for asynchronous dispatch, `Iov` — I/O Vectors for payload packing), allowing applications to submit I/O without any kernel transition.

We adopted this synchronous-to-asynchronous bridging pattern directly. Each application thread that performs I/O receives a dedicated `SqCqEmulator` — a Single-Producer, Single-Consumer (SPSC) queue pair modeled after the NVMe Submission Queue / Completion Queue specification:

- **Submission Queue (SQ):** The application thread writes an `SQEntry{opcode, lba, length}` to `sq_payloads[sq_tail % 1024]`, then commits with `sq_tail.store(next, memory_order_release)`.
- **Completion Queue (CQ):** A companion device-emulation thread polls `sq_tail` with `memory_order_acquire`, processes requests, writes `CQEntry{status, sq_head_pointer}` to `cq_payloads`, and publishes via `cq_tail.store(next, memory_order_release)`.
- **Host-side polling:** The application spins on `cq_tail.load(memory_order_acquire)` until the device acknowledges completion.

This is the exact handshake that real NVMe controllers perform in hardware. By emulating it in user space, we exercise the identical acquire/release memory-ordering paths that a production SPDK application would traverse — making our benchmarks architecturally honest.

#### Pillar 3 — Lazy Copy Elimination (zIO, OSDI '22)

The zIO system from OSDI 2022 showed that most application-level `memcpy()` calls into intermediate buffers are wasted: the application never touches the full destination range. By intercepting `memcpy()` and `memmove()` for buffers `≥ 16 KB`, leaving the destination pages unmapped via `userfaultfd`, and performing lazy page-granularity copies only when the application faults on a specific page, zIO eliminated up to 94% of data movement in I/O-heavy workloads.

Our `ElisionTracker` implements this pattern with a 6% bailout heuristic: if `bytes_faulted / bytes_tracked > 6%` for a given buffer, we stop eliding and fall back to eager copy. This prevents pathological behavior for workloads that genuinely read their entire buffer (e.g., checksum verification).

### ARM64 Silicon-Specific Optimizations

The entire codebase compiles with `-mcpu=neoverse-n2 -moutline-atomics`, targeting the specific silicon in Azure Cobalt 100 VMs:

- **Large System Extensions (LSE):** ARM's LSE provides single-instruction atomics (`CASA`, `LDADD`, `SWP`) that replace the legacy LL/SC (Load-Linked / Store-Conditional) retry loops. On a contested cache line, LL/SC can livelock under high contention; LSE atomics are arbitrated by the cache coherence protocol itself. Our `FakeFdTable` allocation, `SqCqEmulator` doorbell stores, and `EmulatorPool` slot claiming all compile down to single LSE instructions.

- **Top Byte Ignore (TBI):** The AArch64 virtual address space uses 48 significant bits for translation, leaving the top 8 bits of every pointer ignored by hardware. Lock-free data structures are classically vulnerable to the ABA problem — where a pointer is freed, reallocated, and reused at the same address, causing a stale CAS to succeed incorrectly. By stamping a monotonic generation counter into the top byte of queue pointers, we solve ABA with zero space overhead and zero additional cache-line traffic.

- **Architecture-Aware Yielding:** ARM64's weak memory model means that on a single-vCPU VM, a spin-polling producer can starve its consumer indefinitely — the compiler and hardware are free to reorder stores past the polling load. Our `yield_single_cpu_restricted()` function detects this at startup via `sched_getaffinity()`, caches the result, and selects between a zero-syscall `YIELD` instruction hint (multi-core path) and a `sched_yield()` kernel transition (single-core fallback).

---

## 2. Overcoming Roadblocks

Every production system has war stories. A runbook that only documents the happy path is fiction. Here are the two failure modes that cost us the most debugging time during our Azure Cobalt 100 deployment — and the systematic fixes that eliminated them.

### 2.1 The Silent FUSE Crash

**Symptom:** Stage 2 of the demo (the FUSE bridge benchmark) would silently fail. The data-plane engine process would launch, print its initialization banner, and then immediately terminate with no error message. `fio` would either hang waiting for the mount or report zero IOPS. No core dump. No segmentation fault message. Just silence.

**Root Cause:** The FUSE entry point (`fuse_main()`) requires a C-style `argv` array with stable, mutable string storage. Our original `main.cpp` constructed the argv using temporary C++ string expressions:

```cpp
// BROKEN: temporaries destroyed before fuse_main reads them
const char* fuse_argv[] = { argv[0], "-f", "-o", "allow_other", mountpoint.c_str() };
```

On x86/GCC, the compiler happened to keep the temporaries alive long enough. On ARM64/GCC 13 with `-O3`, the compiler legally destroyed the string backing storage before `fuse_main()` dereferenced the pointers — a textbook dangling-pointer UAF that manifested as a `SIGSEGV` inside libfuse's argument parser, which was hidden by FUSE's internal signal handling.

**Resolution:** We replaced the construction with a two-vector owned-storage pattern:

```cpp
std::vector<std::string> fuse_args_storage = {
    argv[0], "-f", "-o", "allow_other", global_mountpoint,
};
std::vector<char*> fuse_argv;
fuse_argv.reserve(fuse_args_storage.size());
for (auto& arg : fuse_args_storage) {
    fuse_argv.push_back(arg.data());
}
```

`fuse_args_storage` owns the string memory for the entire lifetime of the call. `fuse_argv` holds raw pointers into that storage. The two vectors are allocated on the same stack frame, guaranteeing lifetime ordering. The crash was eliminated permanently.

**Lesson:** On weakly-ordered architectures with aggressive optimizers, undefined behavior that "works" on x86 *will* fail. ARM64 is an excellent UB detector.

### 2.2 The All-Zero Scorecard Race Condition

**Symptom:** The demo scorecard would intermittently print all zeros for the FUSE bridge benchmark — `0 IOPS`, `0.00 µs latency`, `0 context switches`. The legacy kernel benchmark (Stage 1) always reported correct numbers. Rerunning the script sometimes produced valid results.

**Root Cause:** The original worker script used an arbitrary `sleep 2` between launching the data-plane engine and starting the `fio` benchmark:

```bash
# BROKEN: 2 seconds is not enough if the engine is slow to mount
./dataplane-emu --mount /tmp/cobalt &
sleep 2
fio --filename=/tmp/cobalt/nvme_raw_0 ...
```

On a cold VM boot (particularly after hugepage allocation), the FUSE mount could take 3–5 seconds to become visible in the VFS namespace. `fio` would open the file, find a zero-length regular file (the mount point directory entry, not the FUSE-backed virtual file), and complete instantly with zero I/O.

**Resolution:** We replaced the arbitrary sleep with a deterministic readiness probe:

```bash
ENGINE_PID=$!
for _ in $(seq 1 200); do
    if [ -n "$ENGINE_PID" ] && ! kill -0 "$ENGINE_PID" 2>/dev/null; then
        echo "Engine PID $ENGINE_PID exited before bridge ready."
        tail -n 80 /tmp/arm_neoverse_engine.log
        exit 1
    fi
    if [ -e "/tmp/arm_neoverse/nvme_raw_0" ]; then
        break
    fi
    sleep 0.2
done
```

This loop provides three guarantees:

1. **Existence check:** The benchmark cannot start until the FUSE bridge file (`nvme_raw_0`) is visible in the filesystem namespace.
2. **Fail-fast on engine death:** If the engine process exits before the bridge is ready (e.g., due to the FUSE crash above), the script detects it within 200ms and prints the engine's last 80 log lines.
3. **Bounded timeout:** 200 iterations × 200ms = 40 seconds maximum. If the bridge isn't ready by then, something is fundamentally broken and the script fails explicitly rather than producing misleading results.

**Lesson:** Never use `sleep` as a synchronization primitive in benchmarking scripts. Probe for the postcondition you actually need.

---

## 3. The Result: The J-Curve Hardware Truth

After resolving the above issues, we ran our final demo on an Azure Cobalt 100 VM (ARM Neoverse-N2, 4 vCPUs, NVMe data disk) at **Queue Depth 128** — deliberately chosen to stress the kernel's multi-queue lock contention.

### Friday Scorecard

| Metric | Legacy Kernel | User-Space FUSE Bridge | Strict PCIe Bypass (SPDK) |
|:----|----:|----:|----:|
| **IOPS** | 22,663 | 43,683 | 67,709 |
| **Latency (µs)** | 43.68 | 22.47 | 14.60 |
| **Context Switches** | 679,898 | 327,596 | 5 |
| **Memory Model** | Strong / Syscall | FUSE / Copy | Relaxed / Lock-Free |

### Reading the J-Curve

The numbers above are not a linear progression. They trace a **J-curve**: each architectural tier doesn't just improve throughput — it removes an entire category of overhead, causing a step-function improvement.

**Legacy Kernel → FUSE Bridge (1.93× IOPS):** The FUSE bridge eliminated the physical SSD's flash translation layer latency by serving reads from memory (`memset` at NEON/SVE speed). But the kernel's VFS dispatch, the FUSE `/dev/fuse` read/write protocol, and the two remaining privilege transitions still consumed half the CPU budget. Context switches dropped by 50%, but 327,596 is still catastrophic.

**FUSE Bridge → PCIe Bypass (1.55× IOPS, 3× over baseline):** The SPDK path eliminated *everything*: no VFS, no block layer, no interrupts, no privilege transitions. The NVMe controller's Submission and Completion Queues are mapped directly into user-space virtual memory. The application polls the CQ doorbell with `memory_order_acquire`; the controller writes completions with DMA. The CPU never leaves Ring 3.

### The Context Switch Cliff

The most dramatic number on the scorecard is the context switch count: **679,898 → 5**.

Those 5 context switches are not I/O. They are strictly localized to one-time setup operations:

- **VFIO group attachment** (1 context switch): The `ioctl(VFIO_SET_IOMMU)` call that binds the NVMe BDF to the user-space IOMMU domain.
- **HugePage pre-faulting** (2–3 context switches): The kernel's `mmap(MAP_HUGETLB)` + first-touch fault path that pins 2 GB of contiguous physical memory for DMA buffers.
- **Thread creation** (1 context switch): `pthread_create()` for the SPDK reactor thread.

After setup completes, the system enters a pure polling loop. No interrupts. No signals. No scheduler involvement. The CPU executes a tight `while(cq_tail.load(acquire) < expected)` loop that never leaves user mode. This is the theoretical minimum: you cannot do I/O with fewer than zero kernel transitions, and setup transitions are amortized to zero over the benchmark duration.

### Why the Kernel Suffocated at QD=128

At low queue depths (QD=1 through QD=32), the legacy kernel path performs respectably. The block layer's multi-queue (`blk-mq`) architecture distributes I/O across per-CPU hardware contexts, and the NVMe driver's interrupt coalescing keeps context-switch rates manageable.

At QD=128, the system hits a phase transition. 128 outstanding I/Os across 4 vCPUs means 32 requests per hardware context. The `blk-mq` tag allocator becomes contended: the `sbitmap` structure that tracks in-flight tags uses atomic bit operations that bounce cache lines across all cores. The interrupt handler fires after every coalescing window, forcing a kernel entry, a softirq drain, and a full TLB invalidation per batch. The scheduler rebalances threads to "help" with the interrupt storm, causing further cache pollution.

The result: the CPU spends more time managing I/O than performing it. By moving to a relaxed, lock-free polling model where the SQ/CQ doorbells are the *only* shared state — and that state sits on dedicated, `alignas(64)` cache lines — we eliminated the entire contention hierarchy.

---

## 4. The Future Roadmap

### LD_PRELOAD as the Production FUSE Replacement

The FUSE bridge was always a stepping stone. Our `libdataplane_intercept.so` library (`Phase 2`, now committed) already demonstrates 2.6M+ IOPS on a single thread for emulated 4KB reads — routing `pread()`/`pwrite()` through the full SqCqEmulator acquire/release handshake path with zero kernel involvement.

The next milestone is running `fio` itself under `LD_PRELOAD=libdataplane_intercept.so`, replacing FUSE as the measured Stage 2 in the demo. This requires completing the `fstat64`/`lseek64`/`ftruncate64`/`fallocate64` trampoline set (implemented, pending fio validation) and wiring the library into the demo orchestration scripts.

When complete, the demo will measure three purely hardware-grounded stages:
1. Legacy kernel filesystem (fio, measured)
2. **LD_PRELOAD user-space bridge (fio + libdataplane_intercept.so, measured)**
3. Strict PCIe bypass (SPDK bdevperf, measured)

No synthetic extrapolation. No multipliers. Every number on the scorecard backed by `fio` JSON or `bdevperf` output.

### In-Kernel Storage Functions via eXpress Resubmission Path (XRP)

The final architectural tier pushes compute *into* the storage stack. The eXpress Resubmission Path (XRP) extends the Linux NVMe driver with an eBPF hook at the I/O completion interrupt. Instead of returning a completion to user space and waiting for the application to submit the next dependent read (e.g., traversing a B-tree index node by node), XRP allows a small eBPF program to inspect the completion, compute the next LBA, and *resubmit directly from interrupt context* — without ever waking the application.

For AI workloads that perform index lookups into massive embedding tables stored on NVMe, this collapses a multi-round-trip read chain into a single submission with in-kernel chaining. The latency reduction is proportional to the tree depth: a 4-level B-tree lookup that required 4 user-kernel round trips becomes 1 submission + 3 in-kernel resubmissions.

This is the endgame: storage silicon that doesn't just respond to commands, but *anticipates* the next access pattern and prefetches it before the application asks.

---

*Built on Azure Cobalt 100 (ARM Neoverse-N2). Benchmarked with fio 3.x and SPDK 24.x. All numbers measured, not modeled.*

*dataplane-emu is open source: [github.com/SiliconLanguage/dataplane-emu](https://github.com/SiliconLanguage/dataplane-emu)*
