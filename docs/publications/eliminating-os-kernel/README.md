# Eliminating the OS Kernel from the Data Plane

### A Survey of Architectural Paradigms for User-Space Storage Engines and Implementation Strategy for Dataplane-Emu

## Abstract

Modern cloud-native storage demands have hit a performance wall imposed by the legacy POSIX system call interface and the "20-microsecond tax" of the Linux kernel's interrupt-driven data path. This paper explores the architectural transition from kernel-space to fully user-space data planes, specifically focusing on the hardware-software co-design required for **ARM64 Neoverse** architectures such as [Azure Cobalt 100](https://azure.microsoft.com/en-us/blog/azure-cobalt-100-based-virtual-machines-are-now-generally-available/) and [AWS Graviton4](https://aws.amazon.com/blogs/aws/join-the-preview-for-new-memory-optimized-aws-graviton4-powered-amazon-ec2-instances-r8g/). We present **dataplane-emu**, an implementation strategy that leverages trampoline-based system call interception and lock-free polling via [SPDK](https://github.com/spdk/spdk) to achieve near-hardware performance limits. By integrating advanced features such as [Large System Extensions (LSE)](https://developer.arm.com/documentation/ddi0487/latest/) and [eXpress Resubmission Path (XRP)](https://www.usenix.org/conference/osdi22/presentation/zhong), our approach demonstrates how legacy database applications can achieve true zero-copy I/O and massive parallelism on 96-core ARM64 cloud instances without requiring a complete codebase rewrite.

**Keywords:** Kernel-Bypass, ARM64 Neoverse, SPDK, POSIX Emulation, Azure Cobalt 100, AWS Graviton4, User-Space Storage, Zero-Copy I/O.

---

The transition from kernel-mediated I/O to user-space data planes represents one of the most significant shifts in systems programming over the last decade. As storage hardware achieves microsecond-scale latencies, the traditional Linux storage stack—comprising the Virtual File System (VFS), the block layer, and interrupt-driven drivers—has transitioned from an efficient abstraction into a primary performance bottleneck. In environments leveraging high-performance **ARM64** processors like **AWS Graviton**, the overhead of context switching and the rigid serialization of kernel I/O schedulers can consume a disproportionate percentage of the CPU’s instruction budget. For an experimental framework such as **dataplane-emu**, the goal is to implement a Phase 4 transition: the transparent routing of legacy POSIX application calls into highly optimized, lock-free user-space queues. This report provides an exhaustive technical analysis of industrial-strength user-mode filesystems, dissectible open-source frameworks, and the microarchitectural considerations necessary to achieve 10-million-IOPS performance on ARM64 infrastructure.

## Industrial-Strength User-Mode Filesystems: The Heavyweights

The landscape of industrial-strength user-mode filesystems is dominated by architectures that prioritize "disaggregation"—the separation of compute from storage resources—and the elimination of any kernel involvement in the fast path. These systems, notably **DAOS**, **PolarFS**, and DeepSeek’s **3FS**, serve as the technical benchmarks for any modern user-space storage engine.

### Distributed Asynchronous Object Storage (DAOS)

**DAOS**, developed primarily by Intel and now managed under the DAOS Foundation, is an open-source software-defined object store designed from the ground up for massively distributed Non-Volatile Memory (NVM).[1, 2] Unlike traditional storage stacks designed for rotating media, DAOS operates end-to-end in user space, leveraging Storage Class Memory (SCM) and NVMe SSDs to provide high-bandwidth, low-latency storage containers.[1, 3, 4]

The DAOS architecture is fundamentally different from block-based filesystems. It presents a key-value-array interface that provides transactional non-blocking I/O and advanced data protection through self-healing.[1, 5, 6] To achieve its performance goals, DAOS utilizes the **OpenFabric Interface (OFI)** for communication and avoids the Linux kernel entirely on the data path.[3, 7, 8]

#### User-Space I/O Routing and Kernel Bypass

In the DAOS model, the data plane is a multi-threaded process (`daos_engine`) written in C that runs the storage engine on the server side.[7] It processes incoming requests through the **CART** communication middleware, which is built on top of the **Mercury** RPC library.[7, 8, 9]

Mercury provides the fundamental mechanism for kernel bypass by supporting Remote Direct Memory Access (RDMA) for bulk data transfers.[8, 9, 10] When a client issues an I/O request, the DAOS library (`libdaos`) function-ships the operation to the storage servers.[3] The server-side engine then accesses local NVM storage via the Persistent Memory Development Kit (PMDK) for SCM and the Storage Performance Development Kit (SPDK) for NVMe SSDs.[7, 10]

| DAOS Communication Component | Functionality | Underlying Library |
| :--- | :--- | :--- |
| **Data Plane** | Lockless engine for NVM access | SPDK / PMDK [7] |
| **RPC Layer** | Low-latency remote procedure calls | Mercury [8, 9] |
| **Transport** | Collective and peer-to-peer reliability | CaRT [7, 9] |
| **Fabric** | Hardware-specific RDMA/TCP verbs | libfabric (OFI) [7, 8] |

#### POSIX Namespace Mapping to Distributed Object Plane

To maintain compatibility with legacy applications, DAOS implements a POSIX emulation layer through the `libdfs` library.[7, 11, 12] This library maps a hierarchical POSIX namespace (files and directories) onto DAOS containers.[6, 11]

In this mapping, a directory is represented as a DAOS object containing entries that link to other objects representing files or subdirectories.[3, 5] Both data and metadata are fully distributed across the available storage targets using a progressive layout to ensure resilience.[3] DAOS provides two primary modes for POSIX support:

1. **Conflict-free Mode**: Optimized for applications with well-behaved, non-overlapping I/O patterns, allowing for high concurrency.[3]
2. **Stricter Consistency Mode**: For applications requiring rigorous POSIX semantics at the cost of some performance.[3]

For transparent integration, applications can use `dfuse`, a FUSE-based daemon that mounts a DAOS container into the standard Linux file system tree.[11, 13, 14] However, to bypass the FUSE kernel module’s overhead, DAOS offers an Interception Library (`libioil` or the more comprehensive `libpil4dfs`) that uses `LD_PRELOAD` to route `libc` calls directly to the DAOS engine.[11, 13, 15]

### Alibaba PolarFS: Ultra-Low Latency via ParallelRaft

**PolarFS** is a distributed file system designed specifically for Alibaba Cloud’s PolarDB database service.[16, 17, 18] It represents a significant advancement in shared-storage database architectures by moving the entire network and I/O stack into user space to leverage RDMA and NVMe hardware.[16, 19]

#### Architecture and User-Space Design

The PolarFS data plane is designed to eliminate locks and context switches on the critical path.[16, 18] It implements its own drivers in user space, operating in a polling mode instead of relying on interrupts.[16] This approach allows PolarFS to reduce end-to-end latency to a level comparable to a local filesystem on an SSD.[16, 18, 19]

The system consists of three main components:

1. **PolarSwitch**: A component residing on the compute nodes that redirects I/O requests from applications to the backend storage.[16]
2. **ChunkServers**: Deployed on storage nodes to handle block-level I/O operations.[16]
3. **PolarCtrl**: The control plane that manages metadata and cluster configuration.[16]

#### ParallelRaft: Relaxing Serialization for Throughput

The most innovative feature of PolarFS is the **ParallelRaft** consensus protocol.[16, 19] Traditional Raft enforces strictly sequential log commitment and execution, which becomes a bottleneck in high-throughput database workloads using microsecond-latency hardware.[16, 20]

ParallelRaft breaks these constraints by allowing out-of-order log acknowledging, committing, and applying.[16, 20] This is possible because databases are often tolerant of out-of-order I/O completion for non-conflicting requests.[16, 18, 19] ParallelRaft uses Logical Block Addresses (LBAs) to identify conflicts; commands that access non-overlapping LBAs are executed in parallel.[20]

| Consensus Metric | Raft (Standard) | ParallelRaft |
| :--- | :--- | :--- |
| **Log Commitment** | Sequential | Out-of-Order [16, 20] |
| **Log Application** | Sequential | Out-of-Order [16, 20] |
| **Conflict Detection** | None (Implicitly serialized) | LBA-based collision check [20] |
| **Performance Gain** | Baseline | Up to 2x bandwidth [18] |

The ParallelRaft-CE (Concurrent Execution) variant tracks entry generations through "sync numbers" and term boundaries to ensure that even with out-of-order execution, bitwise identical replicas are maintained after recovery.[20]

### DeepSeek 3FS: Fire-Flyer File System

**3FS** is a high-performance distributed file system developed by DeepSeek to address the massive I/O demands of AI training and inference.[21, 22] It is designed for disaggregated architectures, where thousands of SSDs are combined into a unified storage pool accessible via an RDMA network.[21, 23]

#### Data Plane and USRBIO API

3FS leverages InfiniBand or RoCE networks to achieve extreme aggregate throughput—reaching 6.6 TiB/s in large-scale tests.[21] The system achieves this by striping equally sized chunks across multiple replication chains using the **CRAQ** (Chain Replication with Apportioned Queries) algorithm.[21, 24, 25] CRAQ provides strong consistency while allowing any node in the chain to serve read requests, balancing the load across all replicas.[21, 25]

A key technical contribution for low-latency access is the **USRBIO API**.[21, 25, 26] USRBIO is a native C++ API inspired by Linux `io_uring` and the RDMA Verbs API.[25, 26, 27] It uses shared memory submission and completion rings to provide asynchronous, zero-copy interaction between the user-space application and the storage nodes, bypassing the kernel entirely on the data path.[25, 26]

#### Stateless Metadata Services

Unlike traditional distributed filesystems that use centralized metadata servers, 3FS utilizes stateless metadata services backed by FoundationDB.[21, 24, 25] This choice provides several advantages:

* **Transactional Integrity**: Metadata operations use FoundationDB's Serializable Snapshot Isolation (SSI) to ensure atomicity.[21, 24, 25]
* **Scalability**: Inodes and directory entries are encoded as key-value pairs and spread across the FoundationDB cluster.[25, 26, 28]
* **Performance**: Directory entries map paths to 64-bit inode IDs using little-endian encoding to distribute the load evenly across the transactional backend.[25, 26]

| 3FS Component | Role | Underlying Tech |
| :--- | :--- | :--- |
| **Meta Service** | Path-to-Inode and directory mgmt | FoundationDB [24, 25] |
| **Mgmtd** | Cluster membership and chains | etcd / Zookeeper [24, 25] |
| **Storage Service** | SSD chunk management | RocksDB / XFS [24, 29] |
| **Native Client** | Zero-copy high-throughput I/O | USRBIO / RDMA [25, 26] |

## High-Quality Dissectible Open Source Frameworks

For developers building bespoke storage engines like **dataplane-emu**, established open-source frameworks provide the essential components for implementing user-space block devices and optimized filesystem interfaces.

### Block Devices in User Space: BDUS and ublk

Moving the block layer into user space allows for the implementation of custom logic (e.g., exotic RAID schemes or network-backed volumes) without the risks associated with kernel-mode programming.[30]

#### BDUS (Implementing Block Devices in User Space)

BDUS is a Linux framework introduced at SYSTOR '21 that allows block device drivers to be written as regular C programs.[31, 32] Its design prioritizes the reduction of memory copies and system calls compared to legacy solutions like NBD.[31] BDUS has been shown to outperform FUSE-based filesystems, particularly under metadata-intensive workloads, where FUSE can increase latencies by an order of magnitude.[31]

#### ublk: The io_uring Framework

While BDUS is a powerful research prototype, **ublk** has emerged as the modern, high-performance standard for user-space block devices in the Linux kernel (since version 6.0).[30, 33, 34] `ublk` is built entirely around the `io_uring` passthrough command interface.[30, 33]

In a ublk environment:

* The kernel driver (`ublk_drv`) manages the block device and relays I/O and `ioctl` requests to a user-space "server".[30, 33]
* The server process interacts with the driver using a pair of commands: `UBLK_IO_FETCH_REQ` (to fetch new work) and `UBLK_IO_COMMIT_AND_FETCH_REQ` (to report completion and fetch the next request simultaneously).[33, 34, 35]
* This design amortizes the cost of context switching by allowing a busy server to process large batches of work in a single kernel transition.[30, 33, 36]

| Feature | BDUS | ublk |
| :--- | :--- | :--- |
| **Communication** | Custom Kernel Module | `io_uring` Passthrough [30, 34] |
| **Scalability** | CPU-limited | Linear (per-queue affinity) [33] |
| **Recovery** | Basic | High (supports server restart) [33, 37] |
| **Mainline Support** | Out-of-tree | Linux 6.0+ [33, 37] |

### FUSE Optimizations and eBPF Acceleration

Filesystem in Userspace (FUSE) has traditionally been the go-to mechanism for implementing custom filesystems, but its context-switching overhead often hampers performance.[38, 39, 40] Modern optimizations aim to mitigate this "FUSE tax."

#### FUSE over io_uring

Recent work has integrated `io_uring` into the FUSE protocol, mirroring the success of `ublk`.[39, 41] By using shared memory ring buffers and `IORING_OP_URING_CMD`, the FUSE daemon can process requests without the heavy overhead of the traditional `/dev/fuse` read/write loop.[39, 41] Synchronous metadata operations, such as file creation, have shown a 4x performance increase using this method.[41]

#### ExtFUSE: eBPF-Accelerated File Systems

ExtFUSE is a research framework that uses the in-kernel **eBPF** virtual machine to execute "thin" extensions of a user-space filesystem directly in the kernel.[42, 43] eBPF programs can handle simple requests—such as permission checks, attribute lookups, and directory caching—using data stored in BPF maps.[42, 43] This avoids expensive user-space context switches for common metadata operations, reducing latency from 17% to under 6% for kernel compilation workloads.[42, 43]

### zIO: Transparent Zero-Copy I/O Paths

**zIO** is an OSDI '22 award-winning library that accelerates I/O-intensive applications by transparently eliminating unnecessary data copies.[44, 45] It is implemented as a user-space library and loaded using `LD_PRELOAD`, requiring no modification to the application’s source code.[44, 46]

#### The Mechanism of Unmapped Pages

zIO operates on the insight that many I/O-intensive applications only touch a small portion of the data they process.[44] Rather than copying a large buffer, zIO tracks the data's movement and marks the target memory area as "intermediate" by leaving the pages unmapped.[44, 45]

If the application attempts to access the data, the process triggers a page fault. zIO intercepts this fault, performs the actual copy for the touched page, and remaps it so execution can continue.[44] To prevent page fault overhead from dominating, zIO uses a tracking policy: it only monitors buffers larger than 16KB and reverts to standard copying if the fault-to-eliminated-bytes ratio exceeds 6%.[44, 46]

#### NVM and Kernel-Bypass Integration

When combined with kernel-bypass stacks like the Strata file system, zIO can eliminate copies across the API boundary itself.[44, 46] By leveraging Non-Volatile Memory (NVM), zIO can achieve "optimistic network receiver persistence," mapping socket receive buffers directly in NVM to provide end-to-end zero-copy from the network NIC through the application to persistent storage.[44, 45]

## Integration with Legacy POSIX Applications

Implementing a user-space storage engine that is transparent to legacy applications like PostgreSQL requires low-overhead techniques to intercept standard system calls and map storage buffers into the application's address space.

### System Call Interception Techniques

The most common method for transparently intercepting POSIX calls is dynamic library wrapping using `LD_PRELOAD`.[47, 48, 49] This allows a custom library to override symbols in the standard C library (glibc).

#### LD_PRELOAD and its Limitations

`LD_PRELOAD` works because dynamic linkers search preloaded libraries before the standard `libc.so`.[48, 49] This enables a wrapper to intercept calls like `pread()` or `pwrite()` and redirect them to a user-space queue.[13, 47, 50] However, this technique only intercepts the library wrappers for those calls, not the system calls themselves.[47] Statically linked binaries or applications using the `syscall()` interface directly will bypass these hooks.[47, 51]

#### Trampolines and Fake File Descriptors

Industrial implementations like DAOS `libpil4dfs` use more robust techniques [13, 15]:

* **Fake FDs**: Intercepted calls return large integers as file descriptors managed entirely in user space.[13, 15] This allows the library to distinguish between files on the local filesystem and those on the bypass engine.[13, 15]
* **Trampolines**: To handle internal libc calls, the library can use trampolines—overwriting the entry of target functions with jump instructions that redirect to the new implementation.[13, 47]

### XRP: Express Resubmission Path via eBPF

**XRP** is an award-winning framework from OSDI '22 that allows applications to execute storage functions (like B-tree lookups) directly from an **eBPF** hook in the NVMe driver.[52, 53, 54] This safely bypasses the block layer, filesystem, and system call layers by triggering the eBPF function immediately when an NVMe request completes in the interrupt handler.[52, 54, 55]

| Interception Method | Mechanism | Performance Overhead | Best Use Case |
| :--- | :--- | :--- | :--- |
| `LD_PRELOAD` | Overrides glibc symbols | Very Low | Dynamically linked legacy apps [48, 49] |
| **ptrace** | Pause execution at syscall boundary | High (2-3x) | Debugging and specialized tools [47, 56] |
| **Trampoline** | Overwrites function entry code | Low | Internal libc redirection [13, 47] |
| **XRP (eBPF)** | Driver-level interrupt hook | Minimal | Data structure lookups (B-trees) [52, 55] |

### Memory Mapping (mmap) in User Space

Zero-copy data transfer is frequently achieved by mapping user-space filesystem buffers directly into the memory space of legacy applications.[57, 58, 59] In a kernel-bypass architecture, this typically involves the use of hugepages (2MiB or 1GiB), which the Linux kernel ensures remain at a constant physical location.[60, 61, 62]

To achieve zero-copy between hardware and user space:

1.  Buffers are allocated in physical memory using tools like `dma_alloc_coherent` or hugepage pools.[60, 63, 64]
2.  These buffers are then exposed via `mmap` on a custom device file in `/dev/`.[57, 59, 63]
3.  For networking tasks, the `SO_ZEROCOPY` flag can be used, but it requires that the memory has `struct page*` metadata associated with it—achieved by repeatedly calling `vm_insert_page` on pre-allocated 0-order pages.[63]

* **mq-deadline**: Suffer from global lock contention on multi-socket NUMA machines.[38, 67] A lock for a global variable in the hardware context (`blk_mq_hw_ctx`) can contribute to nearly 80% of total CPU cycles in certain `io_uring` configurations.[38]
* **Kyber**: Shows the least amount of overhead but still reduces throughput by up to 47%.[38, 68, 69] Unlike mq-deadline, Kyber does not use a global lock, allowing for linear throughput scalability.[38, 65, 69]

#### SPDK vs. io_uring

While both **SPDK** and `io_uring` offer kernel bypass, their efficiency at high loads differs dramatically.[38, 70]

* **SPDK**: Can saturate high-performance hardware with only 5 cores (using `fio`) or just a single core when using its native, lightweight `perf` benchmark.[38] It spends approximately 83% of its instructions on high-performance polling within the NVMe driver.[38]
* `io_uring`: Requires up to 13 cores to saturate the same hardware at high loads.[38] Polling in `io_uring` increases performance by 1.7x but consumes 2.3x more CPU instructions.[38, 71]

| Microarchitectural Metric | SPDK (Polled) | POSIX (psync) | `io_uring` (DeferTR) |
| :--- | :--- | :--- | :--- |
| **Instructions per Cycle (IPC)** | High (Streamlined path) | Low (1/3rd of polled) | Moderate [38] |
| **Cache Miss Rate** | 14x higher (DMA to user) | 1.6 - 2.5x higher | Baseline [38] |
| **Lock Contention** | 0% (Lock-free queues) | High (VFS/Block locks) | Low (with batching) [38] |

## Hardware-Software Co-Design on ARM64 (Azure Cobalt 100 & AWS Graviton)

Optimizing for the **ARM64 Neoverse** architecture of Azure Cobalt 100 and AWS Graviton requires specific attention to memory ordering, core topology, and hardware-accelerated instructions.[72, 73, 74]

### Core Mapping and Parallelism

Modern ARM64 cloud processors, including Azure Cobalt and AWS Graviton (Graviton2/3/4), implement 1:1 physical core mapping with no simultaneous multithreading (SMT).[72, 73, 74] This architecture is ideal for user-space storage engines, as it eliminates the performance jitter caused by hyper-threading and allows for linear scalability of polling threads.[72, 75, 76]

### Taming the Weak Memory Model

ARM64 utilizes a relaxed, weakly-ordered memory model, necessitating the use of explicit barriers to guarantee memory ordering between CPU cores and peripheral hardware.[77, 78, 79] SPDK’s implementation of these barriers for ARM64 illustrates the precision required[77, 79, 80]:

* **FULL read/write barrier** (`dsb sy`): Ensures all data access instructions before the barrier are executed before any subsequent instructions.[77, 78]
* **Write memory barrier** (`dsb st`): A specialized barrier that only affects store operations, crucial for ringing NVMe doorbells after writing to the submission queue.[77, 78, 81]
* **SMP barriers** (`dmb ish` / `dmb ishld`): Ensure ordering within the "inner shareable" domain of the CPU cluster, typically used for lock-free queue synchronization between threads.[77, 78, 81]

### Large System Extensions (LSE) for Lock-Free Atomics

To achieve massive IOPS across 64+ cores, the storage engine must be compiled to leverage **Large System Extensions (LSE)**, introduced in ARMv8.1. LSE provides low-cost atomic instructions directly in hardware, improving system throughput for CPU-to-CPU communication and lock-free queues by up to an order of magnitude compared to legacy Load-Exclusive/Store-Exclusive (LL/SC) loops. Compiling the C++ data plane with `-march=armv8.2-a` or `-moutline-atomics` injects these hardware-accelerated LSE instructions.

### Vectorization and Top Byte Ignore (TBI)

For extreme optimization on ARM64, the data plane leverages two specific hardware features:

* **Scalable Vector Extension (SVE/SVE2) & NEON**: Used to accelerate memory copying and matrix operations within the fast-path by processing multiple data streams simultaneously using massive hardware registers. Graviton4's Neoverse V2 cores show substantial improvements in Instruction-Level Parallelism (ILP), with parsing operations achieving 4.7 IPC compared to 3.4 on Graviton3.[72, 75] This increased instruction throughput allows storage engines to handle more complex metadata logic while still maintaining sub-microsecond polling cycles.
* **Top Byte Ignore (TBI)**: ARM64 natively supports pointer tagging, where the hardware automatically ignores the top 8 bits of a 64-bit pointer during memory access. This allows the C++ engine to embed ABA-prevention sequence tags directly into the memory pointers of the lock-free queues, making state masking mathematically "free" on Azure Cobalt and Graviton without requiring extra instructions.

## Implementation Blueprint for Phase 4: Dataplane-Emu

To implement Phase 4—routing PostgreSQL I/O into user-space queues—the analysis suggests a four-layered architectural approach.

### Layer 1: The Transparent Interception Bridge

For PostgreSQL, which relies on glibc wrappers, the interception layer must use a trampoline-based `LD_PRELOAD` library similar to `libpil4dfs`.[13, 15]

```c
// Concept for a Trampoline-based pread() hook
ssize_t pread(int fd, void *buf, size_t count, off_t offset) {

    // 1. Identify if FD is a 'fake' FD managed by dataplane-emu
    if (is_emu_fd(fd)) {

        // 2. Resolve to SPDK bdev and qpair
        struct emu_qpair *q = get_qpair_for_fd(fd);

        // 3. Submit asynchronous read to SPDK lock-free queue
        return spdk_nvme_ns_cmd_read(q->ns, q->qpair, buf,
                                     offset / block_size, count / block_size,
                                     cb_fn, cb_arg, 0);
    }

    // 4. Fall back to original glibc symbol for standard files
    return original_pread(fd, buf, count, offset);
}
```
This bridge must handle the allocation of "fake" FDs (e.g., integers > 1,000,000) to ensure they do not collide with kernel-allocated FDs and must precisely manage internal libc calls through instruction overwriting.[13, 15]

### Layer 2: The Polling Data Plane (SPDK on ARM64)

The core engine will use **SPDK** to manage NVMe over Fabrics (NVMe-oF) connections over TCP loopback or RDMA.[70, 79, 82] To maximize Graviton efficiency:

* **Physical Core Affinity**: Pin each SPDK reactor thread to a dedicated Neoverse core.[72, 75, 83]
* **Lock-Free Command Buffers**: Use pre-allocated request objects inside the `spdk_nvme_qpair` structure to avoid heap allocation in the hot path.[81]
* **Barrier Precision**: Explicitly use `dsb st` after updating submission queue tail indices to ensure hardware visibility.[77, 78, 81]

### Layer 3: Zero-Copy Metadata and Buffer Management

Transparency is extended by mapping SPDK hugepage buffers directly into the PostgreSQL process memory space.[57, 58, 59] Following the zIO paradigm, the engine can implement lazy-copy logic.[44]

* **Pread Path**: Data is read by SPDK into a persistent hugepage. The interception layer returns a pointer to this page to PostgreSQL. If the application only performs read-only analytical queries, no copy ever occurs.[44, 46, 59]
* **Pwrite Path**: Applications like PostgreSQL often write from their own page cache. By unmapping the target memory area, zIO can track whether the buffer is modified before it is eventually submitted to the user-space SPDK queue, potentially eliminating up to four copies per I/O call.[44, 84]

### Layer 4: ParallelRaft Replication Layer

To support high availability, the replication engine should implement the **ParallelRaft** protocol.[16, 19]

* **Conflict-Free Parallelism**: PostgreSQL's random-write patterns are often geographically distinct in terms of LBAs. ParallelRaft allows these writes to be acknowledged and applied out-of-order, doubling the effective bandwidth of the storage cluster under heavy load.[16, 18, 19]
* **Strong Consistency**: Use CRAQ (per 3FS) to allow reads from any replica node while maintaining strong consistency for write transactions.[21, 24, 25]

By moving metadata management to a distributed transactional store like FoundationDB and leveraging USRBIO-style zero-copy APIs, dataplane-emu can reach near-hardware mechanical limits while providing a completely transparent interface to the application. The integration of trampoline-based system call interception and zIO-style transparent copy elimination ensures that Phase 4 can be achieved without requiring the rewrite of decades of established database code.

## Nuanced Conclusions and Outlook

The transition to a fully user-space data plane for legacy POSIX applications on modern architectures (like ARM64 and RISC-V) is now feasible due to the convergence of four critical technologies: high-performance polling frameworks (SPDK), asynchronous kernel communication (`io_uring`), programmable in-kernel extensions (**eBPF**), and SmartNIC/DPU hardware offloading.[33, 34, 38, 70]

The elimination of the "20,000-instruction kernel tax" is not merely about raw throughput; it is about freeing the CPU to perform more application-level logic.[38] On modern cloud processors like Microsoft's [Azure Cobalt 100](https://azure.microsoft.com/en-us/blog/azure-cobalt-100-based-virtual-machines-are-now-generally-available/) and [AWS Graviton4](https://aws.amazon.com/blogs/aws/join-the-preview-for-new-memory-optimized-aws-graviton4-powered-amazon-ec2-instances-r8g/)—which provide up to 96 isolated physical vCPUs—the primary architectural risk shifts away from raw compute and toward metadata complexity, cache pollution, and synchronization latency.[72, 89, 91] The [Azure Cobalt 100 VMs](https://azure.microsoft.com/en-us/blog/azure-cobalt-100-based-virtual-machines-are-now-generally-available/), for example, natively support 4x local storage IOPS (with NVMe) and up to 1.5x network bandwidth compared to previous Azure Arm generations.[89] Because legacy POSIX syscalls will severely bottleneck this underlying silicon, the data plane must transcend software-only solutions and leverage hardware-assisted synchronization—such as **Large System Extensions (LSE)** on ARM64 and the Zawrs extension on RISC-V—to execute energy-efficient, lock-free polling.[77, 85, 86]

Industrial research into [PolarFS](https://www.vldb.org/pvldb/vol11/p1849-cao.pdf), [DAOS](https://github.com/daos-stack/daos), and [DeepSeek 3FS](https://github.com/deepseek-ai/3FS) proves that the optimal storage architecture is disaggregated and stateless, relying heavily on RDMA fabrics (InfiniBand/RoCE) to bypass the host TCP/IP stack entirely.[1, 16, 21, 29] By moving metadata management to a distributed transactional store like FoundationDB and leveraging USRBIO-style zero-copy APIs, dataplane-emu can reach near-hardware mechanical limits while providing a completely transparent interface to the application.[41, 44]

The integration of trampoline-based system call interception and zIO-style transparent copy elimination ensures that Phase 4 can be achieved without requiring the rewrite of decades of established database code.[13, 15, 44] However, the ultimate evolutionary step for this architecture pushes computation even closer to the silicon. By integrating **XRP (eXpress Resubmission Path)** to execute storage functions (like B-tree lookups) directly inside the NVMe driver's eBPF interrupt hook,[52, 53] and utilizing GPUDirect Storage (GDS) alongside NVIDIA BlueField-3 DPUs for direct peer-to-peer DMA transfers,[64, 65] the architecture completely removes the host CPU from the critical data path, achieving true zero-copy data ingestion from NVMe directly into GPU memory.[66, 67]

## References

1. daos-stack/daos: DAOS Storage Stack (client libraries, storage engine, control plane) - GitHub, <https://github.com/daos-stack/daos>
2. An Introduction to DAOS- The Overlooked Side of AI | by Devansh - Medium, <https://machine-learning-made-simple.medium.com/an-introduction-to-daos-the-overlooked-side-of-ai-1cea3279bae6>
3. DAOS: Revolutionizing High-Performance Storage with Intel® Optane™ Technology, <https://www.intel.com/content/dam/www/public/us/en/documents/solution-briefs/high-performance-storage-brief.pdf>
4. DAOS on IBM Cloud VPC, <https://www.ibm.com/products/tutorials/daos-on-ibm-cloud-vpc>
5. daos/docs/overview/storage.md at master - GitHub, <https://github.com/daos-stack/daos/blob/master/docs/overview/storage.md>
6. Architecture - DAOS v2.6, <https://docs.daos.io/v2.6/overview/architecture/>
7. daos/src/README.md at master · daos-stack/daos - GitHub, <https://github.com/daos-stack/daos/blob/master/src/README.md>
8. Enhancing RPC on Slingshot for Aurora's DAOS Storage System - CUG, <https://cug.org/proceedings/cug2025_proceedings/includes/files/pap105s2-file1.pdf>
9. DISTRIBUTED ASYNCHRONOUS OBJECT STORAGE (DAOS) - OpenFabrics Alliance, <https://www.openfabrics.org/wp-content/uploads/2020-workshop-presentations/105.-DAOS_KCain_JLombardi_AOganezov_05Jun2020_Final.pdf>
10. An RDMA-First Object Storage System with SmartNIC Offload - arXiv, <https://arxiv.org/html/2509.13997v1>
11. File System - DAOS v2.4, <https://docs.daos.io/v2.4/user/filesystem/>
12. DAOS Overview, <https://daos.io/daos-overview>
13. DAOS Community - Confluence, <https://daosio.atlassian.net/wiki/spaces/DC/pages/11355422772/Interception+library+design+document>
14. DAOS Usage and Application - Argonne Training Program on Extreme-Scale Computing, <https://extremecomputingtraining.anl.gov/wp-content/uploads/sites/96/2025/08/DAOS_ATPESC-2025.pdf>
15. DAOS Client: Progress & Plans, <https://daos.io/wp-content/uploads/2025/11/DUG_DAOS-client-HPE.pdf>
16. PolarFS: An Ultra-low Latency and Failure Resilient Distributed File System for Shared Storage Cloud Database - VLDB Endowment, <https://www.vldb.org/pvldb/vol11/p1849-cao.pdf>
17. PolarFS: an ultra-low latency and failure resilient distributed file system for shared storage cloud database - ResearchGate, <https://www.researchgate.net/publication/327564629_PolarFS_an_ultra-low_latency_and_failure_resilient_distributed_file_system_for_shared_storage_cloud_database>
18. Alibaba Rolls Own Distributed File System for Cloud Database Performance, <https://www.nextplatform.com/cloud/2018/08/21/alibaba-rolls-own-distributed-file-system-for-cloud-database-performance/1656313>
19. Alibaba Unveils PolarFS Distributed File System for Cloud Computing - Medium, <https://medium.com/hackernoon/alibaba-unveils-new-distributed-file-system-6bade3ad0413>
20. ParallelRaft: Out-of-Order Executions in PolarFS - Metadata, <http://muratbuffalo.blogspot.com/2025/03/parallelraft-out-of-order-executions-in.html>
21. GitHub - deepseek-ai/3FS: A high-performance distributed file system designed to address the challenges of AI training and inference workloads., <https://github.com/deepseek-ai/3FS>
22. DeepSeek Realse 5th Bomb\! Cluster Bomb Again\! 3FS (distributed file system) & smallpond (A lightweight data processing framework) : r/LocalLLaMA - Reddit, <https://www.reddit.com/r/LocalLLaMA/comments/1izvwck/deepseek_realse_5th_bomb_cluster_bomb_again_3fs/>
23. DeepSeek AI Unveils Fire-Flyer File System (3FS): A High-Performance Distributed File System for AI Workloads | by Rishabh Dwivedi | Medium, <https://medium.com/@drishabh521/deepseek-ai-unveils-fire-flyer-file-system-3fs-a-high-performance-distributed-file-system-for-1dac7e4b8d21>
24. An Intro to DeepSeek's Distributed File System | Henry Zhu - GitHub Pages, <https://maknee.github.io/blog/2025/3FS-Performance-Journal-1/>
25. DeepSeek 3FS: A High-Performance Distributed File System for Modern Workloads, <https://dev.to/sf_1997/deepseek-3fs-a-high-performance-distributed-file-system-for-modern-workloads-5998>
26. Notes on Deepseek 3FS Filesystem - Ankush Jain, <https://ankushja.in/blog/2025/notes-on-deepseek-3fs/>
27. Deepseek 3fs Webinar Part1 f2dd6949 | PDF | Cache (Computing) - Scribd, <https://www.scribd.com/document/874651906/deepseek-3fs-webinar-part1-250401232537-8168baf0-250407074256-f2dd6949>
28. Untitled, <https://raw.githubusercontent.com/deepseek-ai/3FS/refs/heads/main/docs/design_notes.md>
29. 3FS/deploy/README.md at main · deepseek-ai/3FS - GitHub, <https://github.com/deepseek-ai/3FS/blob/main/deploy/README.md>
30. Block Devices In User Space | Hackaday, <https://hackaday.com/2026/01/20/block-devices-in-user-space/>
31. BDUS: Implementing Block Devices in User Space, <https://jtpaulo.github.io/assets/files/2021/bdus-systor21-albertofaria.pdf>
32. albertofaria/bdus: A framework for implementing Block Devices in User Space - GitHub, <https://github.com/albertofaria/bdus>
33. Userspace block device driver (ublk driver) - The Linux Kernel documentation, <https://docs.kernel.org/block/ublk.html>
34. Userspace block device driver (ublk driver) - The Linux Kernel Archives, <https://www.kernel.org/doc/html/v6.0/block/ublk.html>
35. Userspace block device driver (ublk driver) - The Linux Kernel Archives, <https://www.kernel.org/doc/html/v6.4/block/ublk.html>
36. Creating virtual block devices with ublk - Jiri Pospisil, <https://jpospisil.com/posts/2026-01-13-creating-virtual-block-devices-with-ublk>
37. UBLK - Vitastor, <https://vitastor.io/en/docs/usage/ublk.html>
38. Performance Characterization of Modern Storage Stacks: POSIX I/O, libaio, SPDK, and io\_uring - Massivizing Computer Systems, <https://atlarge-research.com/pdfs/2023-cheops-iostack.pdf>
39. FUSE over io\_uring : r/linux - Reddit, <https://www.reddit.com/r/linux/comments/1ldj8yz/fuse_over_io_uring/>
40. Direct-FUSE: Removing the Middleman for High-Performance FUSE File System Support - OSTI, <https://www.osti.gov/servlets/purl/1458703>
41. FUSE and io\_uring - LWN.net, <https://lwn.net/Articles/932079/>
42. ExtFUSE: Making FUSE File-Systems Faster With eBPF - Phoronix, <https://www.phoronix.com/news/ExtFUSE-Faster-FUSE-eBPF>
43. When eBPF Meets FUSE - Improving Performance of User File Systems - Linux Foundation Events, <https://events19.linuxfoundation.org/wp-content/uploads/2017/11/When-eBPF-Meets-FUSE-Improving-Performance-of-User-File-Systems-Ashish-Bijlani-Georgia-Tech.pdf>
44. zIO: Accelerating IO-Intensive Applications with Transparent Zero-Copy IO - USENIX, <https://www.usenix.org/system/files/osdi22-stamler.pdf>
45. zIO: Accelerating IO-Intensive Applications with Transparent Zero-Copy IO - USENIX, <https://www.usenix.org/conference/osdi22/presentation/stamler>
46. zIO: Accelerating IO-Intensive Applications with Transparent Zero-Copy IO - NSF PAR, <https://par.nsf.gov/servlets/purl/10340434>
47. LD\_PRELOAD: The Hero We Need and Deserve - Hacker News, <https://news.ycombinator.com/item?id=19187417>
48. LD\_PRELOAD in Linux: A Powerful Tool for Dynamic Library Interception | by Abhijit, <https://abhijit-pal.medium.com/ld-preload-in-linux-a-powerful-tool-for-dynamic-library-interception-7f681d0b6556>
49. Why does LD\_PRELOAD work with syscalls? - Stack Overflow, <https://stackoverflow.com/questions/60450102/why-does-ld-preload-work-with-syscalls>
50. Intercepting system calls with LD\_PRELOAD - Sebastian Österlund, <https://osterlund.xyz/posts/2018-03-12-interceptiong-functions-c.html>
51. Use LD\_PRELOAD to intercept system calls from library which is statically linked?, <https://stackoverflow.com/questions/77527007/use-ld-preload-to-intercept-system-calls-from-library-which-is-statically-linked>
52. XRP: In-Kernel Storage Functions with eBPF - USENIX, <https://www.usenix.org/system/files/osdi22-zhong_1.pdf>
53. XRP: In-Kernel Storage Functions with eBPF - USENIX, <https://www.usenix.org/conference/osdi22/presentation/zhong>
54. XRP: In-Kernel Storage Functions with eBPF, <http://nvmw.ucsd.edu/nvmw2023-program/nvmw2023-paper17-final_version_your_extended_abstract.pdf>
55. XRP: In-Kernel Storage Functions with eBPF, <https://www.asafcidon.com/uploads/5/9/7/0/59701649/xrp.pdf>
56. how could I intercept linux sys calls? - Stack Overflow, <https://stackoverflow.com/questions/69859/how-could-i-intercept-linux-sys-calls>
57. Zero-copy: Principle and Implementation | by Zhenyuan (Zane) Zhang | Medium, <https://medium.com/@kaixin667689/zero-copy-principle-and-implementation-9a5220a62ffd>
58. It's all about buffers: zero-copy, mmap and Java NIO - Shawn's Pitstop, <https://xunnanxu.github.io/2016/09/10/It-s-all-about-buffers-zero-copy-mmap-and-Java-NIO/>
59. Zero-Copy IO: Building Lightning-Fast Applications Across Languages - Aarambh Dev Hub, <https://aarambhdevhub.medium.com/zero-copy-io-building-lightning-fast-applications-across-languages-dc0fb47dd436>
60. Direct Memory Access (DMA) From User Space - SPDK, <https://spdk.io/doc/memory.html>
61. System Configuration User Guide - SPDK, <https://spdk.io/doc/system_configuration.html>
62. DOCA SNAP-4 Service Guide - NVIDIA Docs, <https://docs.nvidia.com/doca/archive/2-9-1/doca+snap-4+service+guide/index.html>
63. Zero-copy user-space TCP send of dma\_mmap\_coherent() mapped memory, <https://stackoverflow.com/questions/58627200/zero-copy-user-space-tcp-send-of-dma-mmap-coherent-mapped-memory>
64. spdk/lib/env\_dpdk/memory.c at master - GitHub, <https://github.com/spdk/spdk/blob/master/lib/env_dpdk/memory.c>
65. BFQ, Multiqueue-Deadline, or Kyber? Performance Characterization of Linux Storage Schedulers in the NVMe Era - SPEC Research Group, <https://research.spec.org/icpe_proceedings/2024/proceedings/p154.pdf>
66. How to Tune the Linux I/O Scheduler (mq-deadline, bfq, none) on RHEL - OneUptime, <https://oneuptime.com/blog/post/2026-03-04-tune-linux-io-scheduler-mq-deadline-bfq-none-rhel-9/view>
67. How to Tune I/O Schedulers (mq-deadline, bfq, none) on Ubuntu - OneUptime, <https://oneuptime.com/blog/post/2026-03-02-how-to-tune-io-schedulers-on-ubuntu/view>
68. BFQ, Multiqueue-Deadline, or Kyber? Performance Characterization of Linux Storage Schedulers in the NVMe Era - Vrije Universiteit Amsterdam, <https://research.vu.nl/en/publications/bfq-multiqueue-deadline-or-kyber-performance-characterization-of-/>
69. OOLinux IO Schedulers Explained: BFQ, MQ-Deadline & Kyber | by Majidbasharat | Medium, <https://medium.com/@majidbasharat21/linux-io-schedulers-explained-bfq-mq-deadline-kyber-ef94609b11a4>
70. Kernel Bypass Networking: DPDK, SPDK, and io\_uring for Mi... - Anshad Ameenza, <https://anshadameenza.com/blog/technology/2025-01-15-kernel-bypass-networking-dpdk-spdk-io_uring/>
71. Performance Characterization of Modern Storage Stacks: POSIX I/O, libaio, SPDK, and io\_uring, <https://atlarge-research.com/talks/2023-cheops-iostack-talk.html>
72. AWS Graviton4 Complete Guide: Strategic Performance Optimization and Cost Reduction, <https://medium.com/@buw/aws-graviton4-complete-guide-strategic-performance-optimization-and-cost-reduction-43a885d891d1>
73. How to Use Graviton Instances for Cost-Effective Compute - OneUptime, <https://oneuptime.com/blog/post/2026-02-12-use-graviton-instances-for-cost-effective-compute/view>
74. ARM64-First Multi-Architecture Strategy on AWS EC2 with Graviton, <https://builder.aws.com/content/32QeyfTmhpcbU7Lfm1LN2BtIUDc/arm64-first-multi-architecture-strategy-on-aws-ec2-with-graviton>
75. How to Use AWS Graviton (ARM) EC2 Instances for Cost Savings - OneUptime, <https://oneuptime.com/blog/post/2026-02-12-aws-graviton-arm-ec2-cost-savings/view>
76. ADVPERF02-BP05 Evaluate ARM architecture for performance considerations by using AWS Graviton - Video Streaming Advertising Lens, <https://docs.aws.amazon.com/wellarchitected/latest/video-streaming-advertising-lens/advperf02-bp05.html>
77. spdk/include/spdk/barrier.h at master · spdk/spdk - GitHub, <https://github.com/spdk/spdk/blob/master/include/spdk/barrier.h>
78. ARM64 Memory Barriers - ElseWhere, <https://duetorun.com/blog/20231007/a64-memory-barrier/>
79. spdk/spdk: Storage Performance Development Kit - GitHub, <https://github.com/spdk/spdk>
80. barrier.h File Reference - SPDK, <https://spdk.io/doc/barrier_8h.html>
81. spdk/doc/nvme\_spec.md at master - GitHub, <https://github.com/spdk/spdk/blob/master/doc/nvme_spec.md>
82. Evaluating the Performance of SPDK-based io uring and AIO Block Device - IJRASET, <https://www.ijraset.com/best-journal/evaluating-the-performance-of-spdkbased-io-uring-and-aio-block-device>
83. Performance Evolution of DAOS Servers - Intel, <https://www.intel.com/content/dam/www/central-libraries/us/en/documents/2023-05/performance-evolution-of-daos-servers-white-paper-0822.pdf>
84. shaoyi1997/zero-copy-io - GitHub, <https://github.com/shaoyi1997/zero-copy-io>
85. Arm Ltd., "[Arm Architecture Reference Manual for A-profile architecture](https://developer.arm.com/documentation/ddi0487/latest/)," Arm Ltd., Cambridge, U.K., Document DDI 0487, Sec. B2.9 "Large System Extensions", 2022.
86. AWS, "[AWS Graviton Technical Guide: C/C++ Atomics and Memory Ordering](https://github.com/aws/aws-graviton-getting-started)," Amazon Web Services GitHub Repository.
87. Arm Ltd., "[Memory Tagging Extension and Top Byte Ignore](https://developer.arm.com/documentation/ddi0487/latest/)," in Armv8-A Architecture Reference Manual, Arm Ltd., Cambridge, U.K., Document DDI 0487, Sec. D5.2, 2022.
88. N. Stephens et al., "The ARM Scalable Vector Extension and Application to Machine Learning," IEEE Micro, vol. 37, no. 2, pp. 26-39, Mar.-Apr. 2017.
89. Microsoft Azure, "[Azure Cobalt 100-based virtual machines are now generally available](https://azure.microsoft.com/en-us/blog/azure-cobalt-100-based-virtual-machines-are-now-generally-available/)," Azure Blog, Nov. 2023.
90. AWS, "[AWS Graviton Technical Guide](https://github.com/aws/aws-graviton-getting-started)," Amazon Web Services GitHub Repository, 2024.
91. Microsoft Learn, "[Use Arm64 Virtual Machines in Azure Kubernetes Service (AKS) for cost effectiveness](https://learn.microsoft.com/en-us/azure/aks/use-arm64-vms)," Azure Kubernetes Service Documentation.
92. Arm Newsroom, "[Arm Expands its Partnership with GitHub to Accelerate AI-Driven Cloud Development with its Cloud Migration Assistant Custom Agent](https://newsroom.arm.com/blog/arm-cloud-migration-assistant-custom-agent-for-github-copilot)," Arm Blog, Oct. 2025.
***
*Copyright © 2026 SiliconLanguage Foundry. All rights reserved.*
