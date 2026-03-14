<div align="center">
  <h1>🚀 dataplane-emu</h1>
  <p><b>A Hardware-Accurate Data Plane Emulator for High-Performance Storage and Networks.</b></p>

  [![C++](https://img.shields.io/badge/C++-20-blue.svg)](https://isocpp.org/)
  [![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
  [![Build Status](https://img.shields.io/badge/build-passing-brightgreen.svg)]()
  [![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)]()
</div>

---

## 📖 The Vision

While tools like QEMU have become the industry standard for CPU and full-system emulation, there is a massive gap in the industry for testing and benchmarking high-performance, kernel-bypass data planes. Modern cloud infrastructure relies on OS-bypass frameworks (SPDK, DPDK) and asynchronous in-kernel APIs (io_uring) to achieve microsecond latency and process millions of IOPS.

**`dataplane-emu` is designed to be the "QEMU for Data Planes".** It is a highly concurrent, C++ based emulator that allows architects to simulate, benchmark, and verify lock-free Submission/Completion Queues (SQ/CQ), thread-per-core execution models, and distributed NVMe over Fabrics (NVMe-oF) architectures—all without requiring physical Intel Optane drives or specialized networking hardware.

## 🏗️ Core Architecture

Built from the ground up for extreme performance and strict hardware modeling, the core engine enforces the following principles:

* **100% Lock-Free Synchronization:** Complete elimination of `std::mutex` and kernel-level futexes. The emulator utilizes strict C++11 atomic memory orderings (`memory_order_acquire` / `memory_order_release`) to manage ring buffers and cross-thread communication.
* **Cache-Line Optimization:** Rigorous use of `alignas(64)` to prevent false sharing across the CPU interconnect, ensuring that the SQ tail and CQ tail reside on isolated, dedicated cache lines.
* **Run-to-Completion Polling:** Schedulers do not yield to the OS. The emulator implements a DPDK-style thread-per-core polling mechanism, bypassing preemptive OS context switches for maximum deterministic throughput.

## 🗺️ Development Roadmap

We are building `dataplane-emu` in iterative phases to ensure robust emulation at every layer of the storage and network stack:

- [ ] **Phase 1: The Multi-API Engine**
  - Implement user-space Submission and Completion Queues (SQ/CQ) simulating physical NVMe hardware descriptors.
  - Provide unified backend abstractions allowing applications to test code against SPDK (user-space polling) and io_uring (in-kernel async) paradigms.

- [ ] **Phase 2: Thread-Per-Core Scheduler**
  - Implement DPDK-style logical core (lcore) thread pinning.
  - Isolate memory domains for NUMA-awareness.
  - Build run-to-completion, interrupt-free polling loops to simulate true data plane execution.

- [ ] **Phase 3: NVMe over Fabrics (NVMe-oF) & Separated Storage**
  - Stretch the SQ/CQ data plane across a simulated network fabric (TCP/RDMA).
  - Emulate an "Aurora-like" cloud database write path, serializing Redo Log vectors over the network and implementing a 4/6 node quorum consensus mechanism for fault tolerance.

- [ ] **Phase 4: Hardware Memory Model Simulation**
  - Actively simulate weak memory consistency models like RISC-V Weak Memory Ordering (RVWMO) and ARM64 by artificially reordering simulated DMA writes, forcing developers to use correct compiler/hardware barriers.
  - Provide a toggle to switch between x86 Total Store Ordering (TSO) and weakly-ordered architectures.

- [ ] **Phase 5: Computational Storage (eBPF)**
  - Provide a sandbox to execute Extended Berkeley Packet Filter (eBPF) code directly within the simulated storage device, modeling the bleeding edge of in-storage database filtering.

## 🚀 Getting Started

### Prerequisites

To build `dataplane-emu`, you will need the following installed on your system:
- A modern C++ compiler supporting **C++20** (GCC 11+, Clang 14+, or MSVC).
- **CMake** (3.15 or higher)

### Build Instructions

```bash
# 1. Clone the repository
git clone [https://github.com/SiliconLanguage/dataplane-emu.git](https://github.com/SiliconLanguage/dataplane-emu.git)
cd dataplane-emu

# 2. Create a build directory
mkdir build && cd build

# 3. Configure and compile
cmake .. -DCMAKE_BUILD_TYPE=Release
make -j$(nproc)

# 4. Run the simulator
Once you've made one of those changes and ran make one last time to get a "Clean" output, you can finally execute your creation:

./SpdkSimulator

# 5. To see how fast it actually is, try timing it:
time ./SpdkSimulator