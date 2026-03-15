# 🚀 dataplane-emu
*A Data Plane Emulation And Hardware-Software Co-Design Enabling Platform for AI and High-Performance Storage*

[![C++](https://img.shields.io/badge/Language-C%2B%2B20-blue.svg)](https://isocpp.org/)
[![License](https://img.shields.io/badge/License-Apache%202.0-red.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-x86__64%20%7C%20ARM64-green.svg)](#-architecture-adaptation)

## 📖 The Vision
*dataplane-emu* is designed to be the **"QEMU for Data Planes."** Modern cloud infrastructure relies on OS-bypass frameworks (SPDK, DPDK) to achieve microsecond latency. This emulator allows architects to simulate lock-free Submission/Completion Queues (SQ/CQ) and thread-per-core execution models—all without requiring physical NVMe hardware or specialized NICs.

## 🏗️ Core Architecture
- **100% Lock-Free Synchronization:** Elimination of `std::mutex` in favor of C++11 atomic memory orderings (Acquire/Release semantics).
- **Architecture Modeling:** Designed to simulate different hardware memory models (TSO vs. Weak Ordering) during I/O transfer.
- **POSIX Interceptor (FUSE):** A high-performance bridge allowing standard Linux tools (`ls`, `dd`, `fio`) to communicate directly with user-space storage queues.

## 🗺️ Development Roadmap

* ✅ **Phase 1: The Multi-API Engine**
    * High-concurrency Submission and Completion Queues (SQ/CQ) simulating physical NVMe hardware descriptors.
    * Unified backend abstractions for testing code against SPDK (user-space polling) and io_uring (async) paradigms.
* ✅ **Phase 2: Thread-Per-Core Scheduler**
    * DPDK-style logical core (lcore) thread pinning and NUMA-aware memory domain isolation.
    * Interrupt-free, run-to-completion polling loops for maximum deterministic throughput.
* ✅ **Phase 3: Automated Dev Environment**
    * **Zero-Touch SPDK Setup:** Automated provisioning of SPDK, DPDK, and FUSE3 dependencies, ensuring a "known-good" environment in minutes.
    * **Kernel & Hardware Tuning:** Automatic configuration of Hugepages (2MB/1GB) and CPU frequency scaling for deterministic benchmarking.
    * **Cloud-Native Automation:** Secure `cloud-init` and `terraform` templates for deployment on [AWS Graviton3 (C7g)](https://aws.amazon.com/ec2/instance-types/c7g/) instances.
* ✅ **Phase 4: POSIX Hardware Bridge (FUSE Interceptor)**
    * **Deterministic Sandbox:** Experiment with SPDK-based storage stacks on commodity machines or Amazon Graviton EC2 instances with full DPDK, SPDK, and ISA-L support.
    * **Kernel-to-Userspace Routing:** Low-latency interception of standard VFS calls (`read`, `write`, `open`) routed directly to user-space queues.
    * **Structured Data Verification:** Real-time data pattern injection (offset-tracking) to verify data integrity across the FUSE ABI.
    * **Architecture Agnostic Build:** Wrapper `Makefile` with auto-detection for x86_64 and ARM64 optimizations.
* 🔲 **Phase 5: NVMe over Fabrics (NVMe-oF) & Distributed Storage**
    * Stretch the SQ/CQ data plane across a simulated network fabric (TCP/RDMA).
    * Emulate an "Aurora-like" cloud database write path, serializing Redo Log vectors over the network.
* 🔲 **Phase 6: Computational Storage (eBPF)**
    * Provide a sandbox to execute Extended Berkeley Packet Filter (eBPF) code directly within the simulated storage device.

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
