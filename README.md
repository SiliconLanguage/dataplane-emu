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

### Phase 5: Hardware Offloading & Zero-Copy I/O (Active Research)
Moving beyond user-space POSIX interception, the final phase pushes storage computation directly to the hardware boundaries to support legacy databases and IO-intensive AI workloads:
* **In-Kernel eBPF Offloading (XRP):** Implementing the eXpress Resubmission Path (XRP) by hooking an eBPF parser directly into the NVMe driver's completion interrupt handler [1, 2]. This completely bypasses the block, file system, and system call layers, allowing the NVMe interrupt handler to instantly construct and resubmit dependent storage requests (like B-Tree lookups) [1, 2], moving computation closer to the storage device [3].
* **Transparent Zero-Copy I/O (zIO):** Eliminating memory copies between kernel-bypass networking (DPDK) and storage stacks (SPDK) [4]. Leveraging `userfaultfd` to intercept application memory access, this dynamically maps and resolves intermediate buffers to eliminate CPU copy overheads without requiring developers to rewrite their applications [5]. 

### Phase 6: Transparent Silicon Enablement of Legacy Software (Infrastructure Integration)
The ultimate capstone of `dataplane-emu` is providing seamless, zero-modification acceleration for legacy applications (e.g., PostgreSQL, Redis, MongoDB) and legacy file systems. This phase integrates our kernel-bypass and hardware-offloading primitives into transparent infrastructure layers:
* **User-Space Block Devices (`ublk`):** Exposing lock-free user-space SPDK queues as standard Linux block devices via the `io_uring`-based `ublk` framework. This allows legacy file systems (ext4, XFS) to operate transparently on top of an extreme-throughput, kernel-bypassed NVMe storage engine.
* **SmartNIC / DPU Offloading:** Relocating the POSIX-compatible client data plane entirely onto a Data Processing Unit (e.g., NVIDIA BlueField-3). This presents a standard interface to the host CPU while executing all RDMA and NVMe-oF networking transparently on the NIC's embedded ARM cores, achieving multi-tenant isolation and host-CPU relief.
* **Transparent Zero-Copy Memory Tracking (zIO):** Utilizing page-fault interception to track data flows within legacy applications. By unmapping intermediate buffers, we can transparently eliminate unnecessary application-level data copies and achieve optimistic end-to-end network-to-storage persistence without modifying application source code.
* **Hardware-Assisted OS Services (RISC-V):** Emulating RISC-V hardware accelerators (inspired by the ChamelIoT framework) that transparently replace software-based OS kernel services (scheduling, IPC) at compile time, achieving drastic latency reduction for unmodified legacy software.

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

*   **[deepseek-ai/3FS](https://github.com/deepseek-ai/3FS):** For its application of RDMA and zero-copy user-space APIs (`USRBIO`) to bypass the kernel and FUSE overheads entirely, achieving extreme throughput for AI training and KV caching [7].
*   **[daos-stack/daos](https://github.com/daos-stack/daos) (Intel):** For its end-to-end user-space I/O routing and its `libpil4dfs` interception library, which allows seamless POSIX application integration [8, 9].
*   **Alibaba PolarFS:** For its compute-storage decoupling and user-space file system designed to provide ultra-low latency for cloud databases [10, 11].
*   **[pulp-platform/mempool](https://github.com/pulp-platform/mempool):** For their pioneering research in mapping OS-level synchronization primitives and message queues directly into tightly-coupled RISC-V hardware accelerators and shared L1 memory clusters [6, 12].

## 🚀 Getting Started

### Prerequisites
- **Compiler:** GCC/G++ 11+ (Optimized for SPDK compatibility)
- **Linux:** Ubuntu 22.04+ or WSL2
- **Libraries:** `libfuse3-dev`, `libnuma-dev`, `pkg-config`

### Build Instructions
```bash
# 1. Clone the repository
git clone [https://github.com/SiliconLanguage/dataplane-emu.git](https://github.com/SiliconLanguage/dataplane-emu.git)
cd dataplane-emu

# 2. Automated Environment Setup (Phase 3)
sudo ./scripts/spdk-aws/provision-graviton.sh

# 3. Build the project
make

# 4. Create the mount point
sudo mkdir -p /mnt/virtual_nvme

# 5. Running the Emulator

# Start the backend and mount the FUSE bridge
sudo ./build/dataplane-emu

# In a second terminal, verify the POSIX bridge:
ls -l /mnt/virtual_nvme/nvme_raw_0
head -c 128 /mnt/virtual_nvme/nvme_raw_0 | hexdump -C

## ⚠️ Active Development: ARM64 Memory Ordering
**Note on Graviton/ARM64 Execution:** `dataplane-emu` is currently undergoing aggressive optimization for ARM64's weakly-ordered memory model. 
Because x86 enforces Total Store Ordering (TSO), the lock-free SPSC (Single-Producer Single-Consumer) queues currently exhibit deterministic behavior on x86_64. However, when deployed on AWS Graviton (ARM64), the relaxed memory model can occasionally result in out-of-order store visibility, leading to consumer starvation or deadlocks under high concurrency. 

**Current Mitigation Path:**
* Upgrading raw atomic increments to strict C++20 `memory_order_acquire` / `memory_order_release` semantics to enforce implicit `DMB ISH` (Inner Shareable) barriers.
* Re-aligning Submission/Completion Queue (SQ/CQ) atomic indices with `alignas(64)` to eliminate L1 cache false-sharing across Graviton physical cores.
* Investigating `DSB` (Data Synchronization Barrier) insertion during FUSE bridging to guarantee POSIX payload visibility before ringing the SPDK doorbell.