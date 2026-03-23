# 🚀 dataplane-emu
*A Data Plane Emulation And Hardware-Software Co-Design Enabling Platform for AI and High-Performance Storage*

[![C++](https://img.shields.io/badge/Language-C%2B%2B20-blue.svg)](https://isocpp.org/)
[![Rust](https://img.shields.io/badge/Language-Rust-orange.svg)](https://www.rust-lang.org/)
[![License](https://img.shields.io/badge/License-Apache%202.0-red.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-x86__64%20%7C%20ARM64%20%7C%20RISC--V-green.svg)](#-architecture-adaptation)

## 📖 The Vision
*dataplane-emu* is designed to be the **"QEMU for Data Planes."** Modern cloud infrastructure relies on OS-bypass frameworks (SPDK, DPDK) to achieve microsecond latency. This emulator allows architects to simulate lock-free Submission/Completion Queues (SQ/CQ) and thread-per-core execution models—all without requiring physical NVMe hardware or specialized NICs. 

As Generative AI, LLM training, and massive data analytics demand unprecedented I/O throughput (such as high-concurrency dataloaders and KV caching), the traditional Linux kernel storage stack (VFS, block layer, interrupt-driven drivers) has become a primary performance bottleneck. `dataplane-emu` completely bypasses the OS kernel to map hardware queues directly into user space, acting as a deterministic sandbox for next-generation data plane architectures.

## 🏗️ Core Architecture
- **100% Lock-Free Synchronization:** Elimination of `std::mutex` in favor of C++11/Rust atomic memory orderings (Acquire/Release semantics) to prevent thread contention.
- **Architecture Modeling:** Designed to simulate different hardware memory models (TSO vs. Weak Ordering) during I/O transfer. It models architecture-specific microarchitectural hazards, such as utilizing explicit `DSB` barriers on ARM64 Graviton instances, and `FENCE` instructions on RISC-V (RVWMO).
- **POSIX Interceptor (FUSE/LD_PRELOAD):** A high-performance bridge allowing standard Linux tools (`ls`, `dd`, `fio`) and legacy databases to communicate directly with user-space storage queues without code modification.

## 🚀 Phased Implementation & Deliverables

### Phase 1: Bare-Metal Kernel Bypass (SPDK & NVMe-oF)
Leverages the Storage Performance Development Kit (SPDK) to unbind PCIe NVMe controllers from native kernel drivers and bind them to user-space `vfio-pci` drivers. Creates an NVMe over Fabrics (NVMe-oF) TCP loopback target to disaggregate the storage plane for AI-scale workloads.

### Phase 2: Hardware-Accurate Lock-Free Queues (ARM64 & RISC-V)
Implements pure C++/Rust Single-Producer Single-Consumer (SPSC) ring buffers. This phase tames weakly-ordered memory models (ARM64/RVWMO) by:
*   **Eliminating False Sharing:** Forcing `alignas(64)` on atomic tail pointers.
*   **Hardware-Assisted Polling:** Utilizing the RISC-V `Zawrs` (Wait-on-Reservation-Set) extension to replace power-hungry spin-loops with energy-efficient polling.
*   **Cache Pollution Mitigation:** Utilizing the RISC-V `Zihintntl` extension (Non-Temporal Locality Hints) to prevent ephemeral message-passing data from polluting the L1 cache.

### Phase 3: Cloud-Native Automated Dev Environment
Engineers an automated, architecture-agnostic AWS Graviton3 (ARM64) environment via Terraform and `cloud-init`. This securely isolates the developer OS on persistent EBS volumes while dedicating raw ephemeral NVMe block access exclusively to the user-space SPDK drivers. It includes automated zero-touch hugepage allocation (2MB/1GB) for Direct Memory Access (DMA).

### Phase 4: Transparent POSIX Interception Bridge
A DAOS-inspired user-space file system bridge using FUSE and `LD_PRELOAD` interception (`libpil4dfs`-style). This layer catches standard `glibc` system calls (e.g., `pread`, `pwrite`) from legacy databases like PostgreSQL and routes them directly into lock-free SPDK queues. This achieves zero-copy I/O without modifying application source code, mirroring the high-throughput, kernel-bypassing architectures used in modern AI file systems.

### Phase 5: Transparent POSIX Interception (LD_PRELOAD)
To accelerate unmodified legacy applications (e.g., PostgreSQL) without requiring source code rewrites, `dataplane-emu` implements a transparent system call interception bridge.

*   **Dynamic Linker Hooking:** Utilizing `LD_PRELOAD`, we inject a custom shared library that overrides standard `glibc` I/O symbols (e.g., `pread`, `pwrite`).
*   **User-Space Routing:** Intercepted I/O requests targeting our storage volumes are routed directly into our zero-copy, lock-free SPDK queues, completely bypassing the Linux Virtual File System (VFS) and the "20,000-instruction kernel tax."
*   **Industry Alignment:** This trampoline-based interception architecture mirrors the high-throughput design patterns of modern AI file systems, such as the DAOS `libpil4dfs` library.
*   **Limitations:** This fast-path routing requires dynamically linked executables. Statically linked binaries or applications invoking raw inline `syscall` instructions will bypass the hook and fall back to standard kernel I/O.

### Phase 6: Hardware Offloading & Zero-Copy I/O (Active Research)
Moving beyond user-space POSIX interception, the final phase pushes storage computation directly to the hardware boundaries to support legacy databases and IO-intensive AI workloads:
* **In-Kernel eBPF Offloading (XRP):** Implementing the eXpress Resubmission Path (XRP) by hooking an eBPF parser directly into the NVMe driver's completion interrupt handler [1, 2]. This completely bypasses the block, file system, and system call layers, allowing the NVMe interrupt handler to instantly construct and resubmit dependent storage requests (like B-Tree lookups) [1, 2], moving computation closer to the storage device [3].
* **Transparent Zero-Copy I/O (zIO):** Eliminating memory copies between kernel-bypass networking (DPDK) and storage stacks (SPDK) [4]. Leveraging `userfaultfd` to intercept application memory access, this dynamically maps and resolves intermediate buffers to eliminate CPU copy overheads without requiring developers to rewrite their applications [5]. 

### Phase 7: Transparent Silicon Enablement of Legacy Software (Infrastructure Integration)
The ultimate capstone of `dataplane-emu` is providing seamless, zero-modification acceleration for legacy applications (e.g., PostgreSQL, Redis, MongoDB) and legacy file systems. This phase integrates our kernel-bypass and hardware-offloading primitives into transparent infrastructure layers:
* **User-Space Block Devices (`ublk`):** Exposing lock-free user-space SPDK queues as standard Linux block devices via the `io_uring`-based `ublk` framework. This allows legacy file systems (ext4, XFS) to operate transparently on top of an extreme-throughput, kernel-bypassed NVMe storage engine.
* **SmartNIC / DPU Offloading:** Relocating the POSIX-compatible client data plane entirely onto a Data Processing Unit (e.g., NVIDIA BlueField-3). This presents a standard interface to the host CPU while executing all RDMA and NVMe-oF networking transparently on the NIC's embedded ARM cores, achieving multi-tenant isolation and host-CPU relief.
* **Transparent Zero-Copy Memory Tracking (zIO):** Utilizing page-fault interception to track data flows within legacy applications. By unmapping intermediate buffers, we can transparently eliminate unnecessary application-level data copies and achieve optimistic end-to-end network-to-storage persistence without modifying application source code.
* **Hardware-Assisted OS Services (RISC-V):** Emulating RISC-V hardware accelerators (inspired by the ChamelIoT framework) that transparently replace software-based OS kernel services (scheduling, IPC) at compile time, achieving drastic latency reduction for unmodified legacy software.

### Validation & Benchmarking: The "Executive Demo"
To empirically prove the performance gains of our kernel-bypass architecture on Azure Cobalt 100, we utilize a custom-compiled `fio` benchmark targeting the SPDK engine. 

By pushing a massive queue depth (`iodepth=256`) of small 4K random reads/writes through a single polling thread (`thread=1`), the benchmark demonstrates:
1. **Zero-Copy DMA:** Complete evasion of the Linux VFS and block layer overhead.
2. **Lock-Free Contention Resolution:** The ability of Neoverse-N2 Large System Extensions (LSE) atomics to sustain extreme queue contention without POSIX mutex degradation.
3. **Compute Isolation:** Saturating the local NVMe drive using only a single physical core, leaving the remaining cluster topology entirely free for compute-heavy AI workloads.
We have successfully architected the C++ memory semantics, the Azure Cobalt 100 

### Hardware Optimization: Azure Cobalt 100 & ARM64 (Neoverse V2)
To achieve true zero-copy I/O and maximize throughput on modern cloud silicon, `dataplane-emu` is heavily optimized for the Azure Cobalt 100 and AWS Graviton4 architectures.

*   **Large System Extensions (LSE):** We bypass traditional, heavily contended x86 locks by compiling with `-mcpu=neoverse-v2 -moutline-atomics`. This forces the binary to utilize hardware-accelerated LSE atomics for our submission and completion queues.
*   **Strict Memory Semantics:** Because ARM64 uses a weakly ordered memory model, all lock-free SPDK ring buffers enforce strict `std::memory_order_acquire` and `std::memory_order_release` semantics to prevent microarchitectural hazards.
*   **1:1 Physical Core Pinning (No SMT):** Cobalt 100 maps vCPUs directly to physical cores. We pin our DPDK-style polling threads directly to these cores (`--core-mask`), guaranteeing zero performance jitter from shared execution resources.
*   **SVE2 & NEON Vectorization:** Bulk data transformations and checksums are auto-vectorized using the Scalable Vector Extension 2 (SVE2), massively outperforming legacy x86 instruction-level parallelism.

### Autonomous Execution Engine: Colab MCP Server Integration
To overcome local hardware bottlenecks and secure the code execution environment, `dataplane-emu` agents leverage the open-source **Google Colab MCP Server** as their primary execution sandbox [1].

*   **Cloud-Native Prototyping:** Instead of running an autonomous agent's generated code directly on local hardware—which might not be ideal for security or performance—agents connect to Colab's cloud environment, utilizing it as a fast, secure sandbox with powerful compute capabilities [1].
*   **Full Lifecycle Automation:** Our control plane agents can programmatically control the Colab notebook interface to automate the development lifecycle [2]. This includes creating `.ipynb` files, injecting markdown cells to explain methodology, writing and executing Python code in real time, and dynamically managing dependencies (e.g., `!pip install`) [4]. 
*   **Lightweight Local Orchestration:** The local agentic framework relies on a minimal footprint, requiring only Python, `git`, and `uv` (the required Python package manager) to run the MCP tool servers and dispatch tasks to the cloud sandbox [3, 5].

### Security Architecture: Zero-Trust Agentic Governance
To safely orchestrate autonomous C++ kernel generation without exposing the host infrastructure to malicious prompt injection or unintended execution loops, `dataplane-emu` employs a defense-in-depth strategy combining hardware sandboxing with strict Model Context Protocol (MCP) governance.

*   **Hardware-Accelerated Sandboxing (TEEs & DPUs):** Agent execution and code compilation are strictly isolated using Trusted Execution Environments (TEEs) and Data Processing Units (DPUs). By leveraging technologies like TEE-I/O and BlueField-3 DPUs, we enforce a hardware-level functional isolation layer [1-3]. This ensures that if an agent's sandbox is compromised, it cannot break out to access cross-tenant data or the host OS kernel [4].
*   **Logical Bounding via MCP Gateways:** Hardware isolation alone does not prevent an agent with valid session tokens from executing unauthorized but technically "valid" commands. To solve this, all agent actions are routed through a governed MCP Gateway that enforces explicit operational contracts and permissions [5].
*   **Tool Filtering & Virtual Keys:** The local control plane utilizes Virtual Keys to enforce strict, per-agent tool allow-lists [6, 7]. An agent is only granted access to the specific MCP tools required for its immediate task (e.g., code compilation), completely blocking unauthorized lateral movement.
*   **Read-Only Defaults & Human-in-the-Loop:** All high-stakes infrastructure and system actions default to a read-only state [8]. True autonomy is bounded by strict policy-as-code evaluations, requiring explicit Human-in-the-Loop (HITL) approval and maintaining centralized "kill switches" to halt anomalous agent behavior instantly [9, 10].

## 📂 Repository Structure

```text
dataplane-emu/
├── docs/
│   ├── adr/
│   │   └── 0001-graviton-hybrid-storage-topology.md
│   └── architecture/
│       ├── memory_models_arm64_rvwmo.md
│       └── compute_storage_decoupling.md
├── scripts/
│   ├── spdk-aws/
│   │   ├── provision-graviton.sh       # AWS CLI EC2 & Security Group provisioning
│   │   ├── iam-role-setup.sh           # IAM instance profile for passwordless access
│   │   ├── cloud-init-userdata.yaml    # Bootstraps Hugepages & vfio-pci rehydration
│   │   └── start-graviton.ps1          # Dynamic Cloudflare DNS updater
├── src/
│   ├── core/
│   │   ├── sq_cq.hpp                   # Lock-free Submission/Completion Queues
│   │   └── sq_cq.cpp                   # ARM64 wfe/dsb & RISC-V Zawrs implementations
│   ├── target/
│   │   └── nvmf_tgt_loopback.cpp       # SPDK NVMe-oF TCP Target initialization
│   └── fuse_bridge/
│       └── interceptor.cpp             # Phase 4: FUSE/LD_PRELOAD POSIX interception
├── tests/
│   └── concurrency_stress_test.cpp
├── CMakeLists.txt
└── README.md
```
## 📚 Prior Art & Inspiration
`dataplane-emu` draws deep architectural inspiration from industrial-strength distributed storage engines, user-space networking frameworks, and virt-to-silicon hardware research:

*   **[deepseek-ai/3FS](https://github.com/deepseek-ai/3FS):** For its application of RDMA and zero-copy user-space APIs (`USRBIO`) to bypass the kernel and FUSE overheads entirely, achieving extreme throughput for AI training and KV caching.
*   **[daos-stack/daos](https://github.com/daos-stack/daos) (Intel):** For its end-to-end user-space I/O routing and its `libpil4dfs` interception library, which allows seamless POSIX application integration.
*   **Alibaba PolarFS:** For its compute-storage decoupling and user-space file system designed to provide ultra-low latency for cloud databases.
*   **[pulp-platform/mempool](https://github.com/pulp-platform/mempool):** For their pioneering research in mapping OS-level synchronization primitives and message queues directly into tightly-coupled RISC-V hardware accelerators and shared L1 memory clusters.


## Key Features Implemented
* **Hardware-Assisted Pointer Tagging:** Utilizes ARM64 Top Byte Ignore (TBI) to achieve lock-free ABA protection. By packing an 8-bit version counter into the upper bits of a virtual address, we can use standard 64-bit Compare-And-Swap (CAS) instructions to safely update pointers, avoiding the heavy register pressure of 128-bit DW-CAS.
* **Lock-Free Synchronization:** Strict avoidance of `std::mutex`. Relies entirely on C++11 atomic memory orderings (Acquire/Release) to manage Submission/Completion Queues (SQ/CQ).
* **Dual-Backend Support:** 
  * *Zero-Syscall Path:* A pure user-space polling engine utilizing `Iov`/`Ior` shared memory splits for microsecond-latency tensor passing.
  * *Legacy POSIX Bridge:* A FUSE-based mount that allows standard Linux tools to interact with the queues. (Note: This path incurs standard kernel context-switching overhead and is intended for compatibility, not peak latency).

## Getting Started

### Prerequisites
* **Hardware:** ARM64 architecture (AWS Graviton3 `c7g`/`c7gd` recommended)
* **Linux:** Ubuntu 22.04+ 
* **Compiler:** GCC/G++ 11+ (C++17 support required)
* **Dependencies:** `libfuse3-dev`, `libnuma-dev`, `pkg-config`

### Build Instructions
```bash
git clone https://github.com/SiliconLanguage/dataplane-emu.git
cd dataplane-emu

# Provision the automated AWS environment (allocates hugepages, unbinds NVMe)
sudo ./scripts/spdk-aws/provision-graviton.sh

mkdir -p build
g++ -O3 -Wall -std=c++17 -pthread src/dataplane_ring.cpp -o build/dataplane_ring

# Export AArch64 library paths for FUSE/SPDK
export LD_LIBRARY_PATH=/usr/lib/aarch64-linux-gnu:$LD_LIBRARY_PATH

## Usage & Execution Modes

### 1. Zero-Copy Ring (ARM64 TBI Demonstration)
This executes the standalone data plane ring. It proves that the Graviton MMU is actively ignoring the top 8 bits of our tagged pointers during user-space execution, allowing safe lock-free polling.

```bash
./build/dataplane_ring
```
Expected output:
```console
allocating Iov memory... ok.
ring init: head_ptr=0x12345678
llama.cpp_consumer: fetched tensor_id=2
```
### 2. High-Performance Benchmark (Pure Polling)
Test the lock-free SPSC queues without mounting the FUSE bridge. We use taskset to pin the emulator to dedicated physical cores, enabling the Zero-Syscall path.

```bash
time sudo taskset -c 1,2 ./build/dataplane-emu -b
```

### 3. Standard Backend (FUSE POSIX Bridge)
Enables the FUSE bridge and mounts the virtual device for legacy compatibility. Because this routes through the Linux VFS, expect standard context-switch latency overheads here.

```bash
sudo mkdir -p /mnt/virtual_nvme
sudo ./build/dataplane-emu -k -m /mnt/virtual_nvme
```
In a second terminal, interact with the bridge:

```bash
head -c 128 /mnt/virtual_nvme/nvme_raw_0 | hexdump -C
```

### 4. Azure Cobalt 100 Silicon Data Plane Demo
This benchmark quantifies the "20-microsecond tax" reduction on [Azure Cobalt 100](https://azure.microsoft.com/en-us/blog/microsoft-azure-delivers-purpose-built-chips-with-azure-cobalt-100-and-azure-maia-100/) silicon. It compares a legacy XFS baseline against the `dataplane-emu` user-space reactor.

**Run the automated demo:**
```bash
./launch_cobalt_demo.sh
```
#### Verified Performance Scorecard (Azure Cobalt 100)
```consol
==========================================================

    AZURE COBALT 100: SILICON DATA PLANE SCORECARD
==========================================================

Architecture              | Latency (us) | IOPS
----------------------------------------------------------

1. Legacy Kernel          | 47.89        | 20693
2. User-Space Bridge      | 45.24        | 21585
3. Zero-Copy (Bypass)     | 29.40        | 33456.75
==========================================================

Metric                    | Legacy Path  | Cobalt Path
----------------------------------------------------------

Max CPU (Core 0)          | 7.9%         | 100.0%
Context Switches          | 413886       | 5
Memory Model              | Strong/Slow  | Weak/Atomic
==========================================================
```

### Verified Performance Scorecard (Azure Cobalt 100)

| Architecture | Latency (μs) | IOPS | Context Switches |
| :--- | :--- | :--- | :--- |
| **1. Legacy Kernel (XFS)** | 40 - 50 | ~20,000 | >400,000 |
| **2. User-Space Bridge** | 42 - 48 | ~20,000 | 5 - 15 |
| **3. Zero-Copy (Bypass)** | ~29* | >33,000* | 0 |

> **[*]** Representing raw SPDK hardware performance without POSIX/FUSE overhead.

#### 🔍 Performance Analysis: The "FUSE Tax" vs. Polling Efficiency
A critical observation in our benchmark is that the **User-Space Bridge** matches the Legacy Kernel's IOPS despite reducing context switches by **99.9%**. 

1. **The Success:** The drop from 400,000+ to 5-15 context switches proves the sq_cq.cpp reactor is successfully polling on the Cobalt 100 cores. This architecture is specifically optimized for ARM64 weak memory models, ensuring deterministic I/O performance by bypassing the kernel's interrupt-driven stack.
2. **The Bottleneck:** The IOPS are currently capped at ~20,000 due to the **"FUSE Tax"**—the kernel-to-user memory copies required by the FUSE protocol. Even with a polling driver, these copies consume the CPU cycles needed for higher throughput.
3. **The Solution:** This validates the shift to **Phase 5 (LD_PRELOAD)**. By intercepting syscalls at the `glibc` level, we eliminate these memory copies, unlocking the true **33,000+ IOPS** hardware potential demonstrated in the Zero-Copy Bypass results.
