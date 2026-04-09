# **Zero-Kernel, Zero-Copy on Weakly-Ordered Silicon: Building Lock-Free High-performance Data Structure for ARM64 and RISC-V Silicon**

Author: Ping Long, Chief Systems Architect, Lead Researcher, SiliconLanguage Foundry

*Contact: [LinkedIn](https://www.linkedin.com/in/pinglong) | [GitHub](https://github.com/ping-long-github) | plongpingl@gmail.com*

---

### **The Bare-Metal Pivot**

This research explores hardware-software co-design to optimize high-performance data structures for ARM64 and RISC-V. By integrating weakly-ordered memory orders with zero-copy, kernel-bypassing frameworks, the study demonstrates significant latency reductions for high-volume workloads.

The evolution of data center infrastructure is currently undergoing a radical architectural divergence. The proliferation of microsecond-scale Non-Volatile Memory Express (NVMe) storage devices and high-throughput smart Network Interface Cards (SmartNICs) operating at 100GbE and 400GbE has fundamentally shifted the performance bottlenecks in modern computing systems. The legacy x86-64 architecture, characterized by its strict Total Store Ordering (TSO) memory model and monolithic kernel storage stacks, is increasingly being superseded by highly parallel, weakly-ordered silicon architectures such as ARM64 (e.g., AWS Graviton) and RISC-V. To fully exploit the massive core counts and aggregate memory bandwidth of these emerging architectures, systems software must undergo a parallel paradigm shift.

Monolithic kernel interactions, busy-wait spinlocks, and cache-polluting memory operations generate insurmountable latency overheads when processing millions of operations per second. Specifically, kernel software overhead now accounts for approximately 51.4% of the latency when executing a standard 512-byte random read on ultra-low-latency NVMe drives such as the Intel Optane SSD P5800X.1 This analysis investigates the convergence of hardware-software co-design across several critical pillars: the microarchitectural nuances of ARM64 weak memory ordering, the formal memory models and custom extensions of the RISC-V instruction set architecture, the alignment and tag-pointer physics of modern non-uniform cache architectures, and the emergence of zero-copy, kernel-bypassing I/O ecosystems.

## **The Architectural Foundations of Memory Consistency Models**

Memory consistency models dictate the strictness with which a processor must enforce the ordering of load and store operations as they are perceived by other processing elements (harts or cores) within a coherent memory domain. The x86-64 architecture operates under the Total Store Order (TSO) model, which is inherently restrictive. TSO ensures that all cores observe stores in the exact order they were issued, permitting only Store-Load reordering (where a load may execute before a preceding store if they target different addresses).2 While this strictness simplifies the development of multithreaded software, it severely restricts the microarchitecture's ability to extract Instruction-Level Parallelism (ILP). The hardware must employ complex store buffers and deep load queues to maintain the illusion of sequential execution, which rapidly scales in transistor complexity and power consumption as core counts increase.

In contrast, ARM64 and RISC-V employ weakly-ordered (or relaxed) memory models.2 These architectures operate under the fundamental assumption that memory accesses are inherently independent unless explicit data, address, or control dependencies are detected by the execution pipeline, or unless the programmer inserts explicit synchronization instructions. This allows the processor to aggressively reorder Load-Load, Load-Store, Store-Store, and Store-Load operations. The pipeline can freely hoist loads above delayed stores, coalesce adjacent stores, and serve loads directly from the local store buffer before they become globally visible to the L1 data cache. The trade-off for this massive theoretical throughput is that systems software must assume total responsibility for enforcing ordering across thread boundaries, primarily through the precise application of memory barriers and atomic instructions.

## **ARM64 Microarchitecture and Synchronization Semantics**

The ARMv8 and ARMv9 architectures, including the Neoverse V1 microarchitecture powering AWS Graviton 3 and the Neoverse V2 powering Graviton 4 processors, provide specialized primitives for managing synchronization across distributed coherent meshes.4 The implementation of C++11 and Rust atomic memory models on these processors reveals significant microarchitectural differences compared to legacy platforms.

### **The High Cost of Explicit Memory Barriers**

In legacy ARM implementations, or in unoptimized codebases, memory synchronization is frequently achieved using explicit, full-system memory barriers. The most common instruction utilized is the Data Memory Barrier (DMB), specifically the DMB ISH (Data Memory Barrier, Inner Shareable).6 The DMB ISH instruction ensures that all explicit memory accesses appearing in program order before the barrier are completely observed by all processing elements within the Inner Shareable domain before any memory accesses appearing after the barrier are observed.2

While functionally robust, the microarchitectural execution of a DMB is highly punitive. It acts as a full bidirectional fence. When a core encounters a DMB ISH, it must effectively drain its local store buffer, propagating all pending stores to the globally coherent L1/L2 cache subsystem, and wait for acknowledgment signals via the cache coherence protocol (e.g., MESI/MOESI) across the inter-core interconnect (such as the ARM CMN-600 or CMN-700 mesh).7 The instruction stalls the execution pipeline until all preceding memory transactions are globally visible. On a 64-core or 128-core monolithic die, the broadcast and synchronization of these barrier signals induce severe latency spikes and degrade the Instruction Per Cycle (IPC) efficiency of the core.2

### **Acquire and Release Semantics: LDAR and STLR**

To mitigate the catastrophic performance penalties associated with full memory barriers, the ARMv8 architecture introduced a set of specialized load and store instructions that encapsulate "one-way" implicit barrier semantics, adhering strictly to the Release Consistency sequentially consistent (RCsc) model.10

When mapping the C++11 or Rust memory model to ARM64, the standard std::memory\_order\_acquire and std::memory\_order\_release semantics are mapped directly to these specialized instructions, completely bypassing the need for explicit DMB fences in most lock-free data structures.

The **Load-Acquire (LDAR)** instruction ensures that all memory accesses appearing in program order after the LDAR are observed only after the LDAR completes.10 It functions as a unidirectional barrier: preceding operations may be delayed and reordered past the LDAR instruction, but subsequent load or store operations cannot be hoisted before it.11

* *C++ Construct:* std::atomic\<T\>::load(std::memory\_order\_acquire)  
* *Assembly Mapping:* ldar w0, \[x1\]

The **Store-Release (STLR)** instruction ensures that all memory accesses appearing in program order before the STLR are observed globally before the STLR executes.10 Subsequent operations can theoretically be reordered before the store, but prior operations cannot be pushed past it.11

* *C++ Construct:* std::atomic\<T\>::store(val, std::memory\_order\_release)  
* *Assembly Mapping:* stlr w0, \[x1\]

By replacing DMB ISH with LDAR and STLR in lock-free Single-Producer Single-Consumer (SPSC) and Multiple-Producer Multiple-Consumer (MPMC) queues, the hardware avoids draining the entire store buffer and stalling the pipeline.13 The combination of LDAR and STLR establishes a critical section that functions as a lightweight barrier, yielding massive throughput improvements on AWS Graviton 3 (Neoverse V1) architectures compared to their x86-64 equivalents.11

C++

// Advanced Lock-Free SPSC Queue for ARM64 using Acquire/Release Semantics  
template \<typename T, size\_t Capacity\>  
class SPSCQueue {  
    // Aligned to 128 bytes to prevent Neoverse V1 destructive interference  
    alignas(128) std::atomic\<size\_t\> head\_idx\_{0};  
    alignas(128) std::atomic\<size\_t\> tail\_idx\_{0};  
    alignas(128) T buffer\_\[Capacity\];

public:  
    bool enqueue(const T& item) {  
        // Relaxed load: We are the only producer, so head\_idx\_ cannot change concurrently  
        size\_t current\_head \= head\_idx\_.load(std::memory\_order\_relaxed);  
        size\_t next\_head \= (current\_head \+ 1) % Capacity;

        // Acquire load (LDAR): Ensure subsequent buffer writes are strictly ordered   
        // after we read the consumer's current tail position.  
        if (next\_head \== tail\_idx\_.load(std::memory\_order\_acquire)) {  
            return false; // Queue is full  
        }

        buffer\_\[current\_head\] \= item;

        // Release store (STLR): Ensure the item write is globally visible   
        // before we publish the new head index.  
        head\_idx\_.store(next\_head, std::memory\_order\_release);  
        return true;  
    }

    bool dequeue(T& item) {  
        size\_t current\_tail \= tail\_idx\_.load(std::memory\_order\_relaxed);

        // Acquire load (LDAR): Ensure we observe the producer's payload   
        // strictly after we observe the updated head index.  
        if (current\_tail \== head\_idx\_.load(std::memory\_order\_acquire)) {  
            return false; // Queue is empty  
        }

        item \= buffer\_\[current\_tail\];

        // Release store (STLR): Ensure payload read is complete before  
        // consumer publishes the freed slot.  
        tail\_idx\_.store((current\_tail \+ 1) % Capacity, std::memory\_order\_release);  
        return true;  
    }  
};

## **Top Byte Ignore (TBI) and PCIe DMA Addressing Boundaries**

Lock-free data structures, particularly those utilizing Compare-And-Swap (CAS) loops for pointer manipulation, are notoriously susceptible to the ABA problem. This race condition occurs when a thread reads a value A from a shared memory location, computes a new value, but before the CAS executes, a second thread modifies the location to B and then quickly changes it back to A. The first thread's CAS operation succeeds, utterly unaware that the underlying logical state (such as the node allocation or the surrounding graph structure) has fundamentally changed, invariably leading to data corruption or segmentation faults.14

The classical resolution to the ABA problem involves appending an "epoch" or "generation" counter adjacent to the pointer. However, atomically updating a 64-bit virtual memory pointer alongside a 64-bit epoch counter requires a double-width Compare-And-Swap instruction (e.g., CMPXCHG16B on x86, or CASP on ARM). Double-width atomic operations are microarchitecturally complex, frequently non-deterministic in execution latency, and lack universal support across all embedded hardware profiles.

The ARMv8 AArch64 architecture provides a sophisticated hardware-software co-design mechanism to bypass this limitation: Top Byte Ignore (TBI).15 In a modern 64-bit processor configured with a standard 48-bit virtual address space, the uppermost 16 bits of a virtual pointer are theoretically redundant.4 When the TBI feature is actively enabled within the processor's Translation Control Register (TCR\_ELx), the hardware's Memory Management Unit (MMU) completely ignores the upper 8 bits (bits 56-63) of a 64-bit pointer during the virtual-to-physical address translation process.15

This architectural trait allows systems programmers to embed an 8-bit epoch counter, generation sequence, or object metadata tag directly into the top byte of the pointer itself. Consequently, a highly efficient, standard 64-bit single-width atomic swap (CAS or LDADD) can simultaneously update both the memory address and its embedded version, elegantly neutralizing the ABA problem with absolute zero instruction overhead.15

### **The SMMU Translation Fault Paradigm**

While TBI resolves locking issues transparently within the confines of the CPU's MMU, passing these tagged pointers across the system interconnect to peripheral hardware devices—such as NVMe storage controllers, PCIe network interfaces, or FPGA accelerators—introduces severe architectural hazards.15

Hardware controllers utilizing Direct Memory Access (DMA) operate autonomously from the CPU and interact with system memory via the PCIe bus. These peripheral requests are invariably routed through the System Memory Management Unit (SMMU, synonymous with IOMMU in the x86 domain), which validates and translates the intermediate or virtual DMA addresses into physical addresses. By default, the SMMU treats the entire 64-bit address supplied to the DMA engine as the valid target space.19

If a software application passes a tagged pointer (where the top byte contains metadata) directly to a DMA mapping interface such as dma\_map\_single, the SMMU will interpret the tag bits as a constituent part of the address. The hardware will subsequently attempt to traverse a massive, unallocated virtual address range.19 Because this tagged address profoundly exceeds the valid translation table boundaries defined by the SMMU's configuration, the SMMU intercepts the transaction and triggers a critical Stage 1 Translation Fault.19

Operating system kernel logs (such as dmesg under Linux) will report an arm-smmu event 0x10 F\_TRANSLATION.21 Detailed event queue records will reveal that the Input Address Size (IPS) or the TxSZ parameter failed the range check because the TB0 or TB1 (Top Byte Ignore) fields within the SMMU's Context Descriptor were disabled, forcing the SMMU to validate the full 64-bit vector.19

To engineer true zero-copy networking or storage pipelines using tagged pointers, systems architects must enforce rigid hardware-software alignment across the PCIe boundary via two primary methodologies:

1. **Explicit Software Masking:** The user-space PMD (Poll Mode Driver) or kernel module must mathematically bit-mask the top 8 bits to zero (ptr & 0x00FFFFFFFFFFFFFF) prior to inserting the physical address into the PCIe DMA descriptor ring.16 While safe, this consumes minor ALU cycles in the critical path.  
2. **SMMU Context Descriptor Configuration:** If the deployment environment permits bare-metal or hypervisor-level configuration, the SMMUv3 can be programmed to precisely mirror the CPU's TBI behavior. By asserting the TBI0 bit (Top Byte Ignore for Translation Table Base Register 0\) within the TCR\_ELx mapping of the SMMU context descriptor, the peripheral hardware will natively ignore the tag bits during DMA translation, allowing seamlessly integrated lock-free tags to traverse the entire system stack.20

## **Cacheline Physics and Destructive Interference on Neoverse V1**

The architectural layout of lock-free Single-Producer Single-Consumer (SPSC) queues mandates meticulous spatial placement of highly volatile atomic variables. If the producer's write-index (head pointer) and the consumer's read-index (tail pointer) reside on the exact same cache line, every single state mutation triggers a cache invalidation protocol sequence (e.g., MESI, MOESI) across the inter-core interconnect.25

Whenever the producer enqueues data, it requests exclusive write access to the cache line containing the head pointer, subsequently invalidating the consumer's cached copy of the entire line (including the tail pointer). When the consumer attempts to dequeue data, it incurs an expensive L1 cache miss, forcing a re-fetch of the cache line from the L2/L3 cache or main memory. This endless invalidation cycle causes the cache line to rapidly "ping-pong" between the private L1 caches of the respective CPU cores, a devastating performance anti-pattern defined as false sharing, or destructive interference.25

Historically, systems programmers universally aligned heavily contended atomic structures to strict 64-byte boundaries, reflecting the standard L1 cache line size dominant across x86-64 architectures and legacy ARM implementations.27 However, applying this legacy convention to AWS Graviton 3 processors—powered by the ARM Neoverse V1 microarchitecture—proves critically insufficient.28

While the physical L1 data cache line size on the Neoverse V1 CPU remains technically 64 bytes 5, the broader memory subsystem behavior heavily dictates performance. To maximize throughput for high-bandwidth vector workloads, the Neoverse V1 microarchitecture implements a highly aggressive L2 spatial prefetcher. When a memory request is issued, the hardware often attempts to complete 128-byte-aligned pairs of 64-byte lines to maximize memory level parallelism (MLP) across the bus.28

Furthermore, the coherency mechanisms and L2 cache structure treat adjacent 64-byte lines as paired sectors within a larger 128-byte logical tracking granule.28 Consequently, if a producer's head index and a consumer's tail index are separated by only 64 bytes, modifying one will frequently trigger the L2 spatial prefetcher or coherency protocol to couple the operations, drawing both variables into the contention domain. This effectively induces destructive interference at the L2/L3 boundaries, drastically inflating latency compared to isolated access patterns.29

To circumvent this hardware-specific bottleneck and achieve absolute maximum throughput on modern weakly-ordered silicon, shared atomic state must be aligned to 128-byte boundaries. C++17 provides a standard macro for this exact microarchitectural variance: std::hardware\_destructive\_interference\_size.26 On Neoverse V1 toolchains, this constant dynamically evaluates to 128 bytes, dictating that highly concurrent struct layouts must utilize alignas(128) to explicitly pad variables, ensuring that no spatial prefetcher or tag-sector pairing overlaps highly contested atomic state.28

## **RISC-V Memory Models and Hardware-Software Extensions**

The RISC-V Instruction Set Architecture (ISA) represents the vanguard of open-source silicon, approaching concurrency and execution efficiency through a highly modular framework. The memory model governing this architecture is the RISC-V Weak Memory Ordering (RVWMO) model. RVWMO provides a relaxed consistency framework, granting the microarchitecture an immense degree of flexibility to execute instructions out of order, extract Instruction-Level Parallelism (ILP), and mask main memory latency.3

### **RVWMO vs. x86 TSO Compatibility**

Unlike the x86-64 TSO model, which strictly forbids Load-Load, Load-Store, and Store-Store reordering 2, RVWMO explicitly permits the reordering of any independent memory operation unless syntactic dependencies (address, data, or explicit control dependencies) dictate otherwise.3

To safely construct sequential consistency and lock-free concurrency within this relaxed model, systems programmers rely on the RISC-V "A" (Atomic) extension. The extension provides specific acquire (.aq) and release (.rl) annotation bits that can be appended directly to load, store, and atomic memory operation (AMO) instructions, embedding implicit barrier semantics directly into the opcode.33

| C++11 Memory Operation | RISC-V Instruction Mapping | RVWMO Semantic Guarantee |
| :---- | :---- | :---- |
| load(memory\_order\_acquire) | lw.aq rd, (rs1) | Prevents subsequent memory operations from reordering before the load. Maps to RCsc atomic load-acquire.33 |
| store(memory\_order\_release) | sw.rl rs2, (rs1) | Prevents preceding memory operations from reordering after the store.33 |
| fetch\_add(memory\_order\_acq\_rel) | amoadd.w.aqrl rd, rs2, (rs1) | Enforces a full bidirectional memory barrier surrounding the atomic operation.33 |
| atomic\_thread\_fence(seq\_cst) | fence rw, rw | Flushes queues and enforces global sequential consistency across all connected harts.33 |

*Table 1: Translation of C++11 Memory Semantics to RISC-V RVWMO Primitives.*

### **Energy-Efficient Polling: The Zawrs Extension**

In high-performance user-space networking (such as DPDK) and storage (SPDK), applications bypass hardware interrupts. Instead, thread execution is relegated to continuous user-space polling loops, checking the tail pointers of DMA hardware ring buffers for incoming data.1 Historically, this is implemented as an aggressive busy-wait spin-loop utilizing a standard pause or nop instruction.35

While spin-polling guarantees ultra-low microsecond latency, it exacts a massive toll on power efficiency. Polling forces the CPU core to execute at 100% utilization, generating extreme thermal output, draining power budgets, and degrading the execution efficiency of sibling hyperthreads operating on the same physical core.35

The RISC-V architecture elegantly resolves this fundamental trade-off through the **Zawrs (Wait-on-Reservation-Set)** extension. Zawrs introduces a specialized instruction specifically tailored for lock-free polling algorithms: WRS.NTO (Wait-on-Reservation-Set, No Timeout).35

The Zawrs mechanism integrates synchronously with the standard LR (Load-Reserved) and SC (Store-Conditional) instructions defined in the A extension. The hardware-software interaction proceeds as follows:

1. **Reservation Setup:** The hart (hardware thread) executes an LR instruction targeting the contested memory address (e.g., the queue's producer index). This physical load inherently registers a "reservation set" on that specific cache line within the microarchitecture's tracking logic.35  
2. **Suspension:** If the condition is not met (data is not ready), the hart executes WRS.NTO instead of executing a wasteful while(1) spin-loop.  
3. **Low-Power Stall:** The execution pipeline immediately suspends instruction fetching and forces the core into a transient, low-power stalled state, effectively halting dynamic power draw.35  
4. **Hardware Wake-up:** The core remains dormant until another agent—be it a sibling hart, a PCIe DMA controller, or an accelerator device—performs a memory store that invalidates the registered reservation set cache line. The cache coherency protocol instantly signals the suspended core, automatically terminating the stall and resuming instruction execution at full speed without any operating system intervention.35

Rust

// Rust implementation of RISC-V Zawrs lock-free consumer poll loop  
\#\[inline(always)\]  
pub unsafe fn wait\_on\_address\_zawrs(addr: \*const u32, expected: u32) {  
    core::arch::asm\!(  
        "1:",  
        "lr.w t0, ({0})",       // Load-Reserved: Set reservation set on queue index  
        "beq t0, {1}, 2f",      // If value\!= expected, data is ready; break loop  
        "wrs.nto",              // Hardware stall until reservation set is invalidated  
        "j 1b",                 // Wake-up triggered; re-evaluate condition  
        "2:",  
        in(reg) addr,  
        in(reg) expected,  
        out("t0") \_,  
        options(nostack)  
    );  
}

Unlike yielding to the operating system or invoking an ecall, WRS.NTO does not trap to the hypervisor or the Linux scheduler.35 There is zero context-switch overhead. The RISC-V Zawrs extension enables bare-metal polling latency profiles while operating with the energy efficiency traditionally associated with slow, interrupt-driven architectures.35

### **Cache Pollution Management: The Zihintntl Extension**

High-performance data plane applications suffer drastically from localized cache pollution. When an application streams massive quantities of ephemerally useful data—such as high-speed network packets routing through an NFV (Network Function Virtualization) proxy, or bulk cryptographic payloads—this sheer volume of incoming data rapidly displaces highly critical, long-lived data structures (such as B-tree indices, routing tables, and process control blocks) from the L1 and L2 caches.39 Once evicted, fetching the routing indices from main memory introduces severe latency stalls.

The RISC-V **Zihintntl (Non-Temporal Locality Hints)** extension mitigates this structural flaw by providing software-directed microarchitectural hints regarding the temporal locality of specific memory accesses.39 These hints act as fusable prefixes applied immediately preceding standard load and store operations.

The most critical hint for zero-copy streaming pipelines is NTL.P1. When a load or store instruction is prefixed with NTL.P1, it explicitly informs the memory hierarchy that the associated data exhibits negligible temporal locality within the innermost level of the private cache (the L1 cache).39

Depending on the specific silicon implementation, when a producer writes a network packet utilizing an NTL.P1-prefixed store, the microarchitecture will intercept the transaction and execute one of two optimizations:

* **Cache Bypassing:** The memory controller bypasses the L1 cache entirely, allocating the cache line directly in the shared L2 or L3 cache. This strictly isolates transit data from the core's private compute space.39  
* **LRU Injection:** The data is allocated in the L1 cache to satisfy immediate throughput needs, but the cache block is instantly marked as Least-Recently Used (LRU) in the cache's replacement policy matrix. Therefore, it is guaranteed to be the very first line evicted upon the next standard cache miss, rather than randomly evicting critical application state.39

| Zihintntl Variant | Cache Level Affected | Recommended Usage Scenario |
| :---- | :---- | :---- |
| NTL.P1 | Innermost Private Cache (L1) | Access to working sets larger than L1 but smaller than L2. |
| NTL.PALL | All Private Caches (L1/L2) | Access to massive working sets exceeding private boundaries, or highly contended lock-free synchronization variables. |
| NTL.S1 | Innermost Shared Cache (L3) | Extremely large data structures exceeding local shared memory limits. |
| NTL.ALL | All Cache Levels | High-speed data streaming (e.g., NIC to Memory zero-copy pipelines) with absolutely zero temporal reuse.40 |

Table 2: RISC-V Zihintntl Memory Hierarchy Mappings and Use Cases.40

By embedding Zihintntl prefixes into the data paths of lock-free data structures, systems architects prevent ephemeral transit data from polluting the silicon's L1 cache, preserving optimal hit rates for the critical, long-lived data structures dictating system logic.41

## **Zero-Kernel and Zero-Copy I/O Ecosystems**

While hardware architectures like ARM64 and RISC-V provide the necessary instruction-level primitives to build hyper-optimized, lock-free queues and cache-friendly topologies, traditional POSIX operating systems impose an insurmountable ceiling on aggregate throughput.

When an application invokes a standard read() or recv() system call, the processor must undergo a heavily penalized context switch from user mode to kernel mode. Security boundaries are validated, process states are saved, and Translation Lookaside Buffers (TLB) are frequently invalidated.44 Furthermore, under traditional paradigms, data is invariably copied from the hardware device (NIC or NVMe) via DMA into an isolated kernel buffer. It is then copied a second time from the kernel buffer to the user-space application's target buffer.44 At multi-gigabyte throughputs, CPU cycles are entirely consumed by memory copy overhead.

To fully exploit weakly-ordered silicon, the software stack must fundamentally bypass the monolithic kernel entirely, eliminating both context switches and physical memory copies.

### **User-Space Polling Frameworks: DPDK, SPDK, and io\_uring**

Frameworks such as the Data Plane Development Kit (DPDK) for network packet processing and the Storage Performance Development Kit (SPDK) for NVMe storage achieve absolute kernel bypass. These architectures detach the peripheral hardware from the Linux Virtual File System (VFS) and standard TCP/IP stacks. Instead, they leverage the UIO or VFIO frameworks to map the PCIe Base Address Registers (BARs) and device queues directly into the user-space application's virtual memory table.1

These frameworks eradicate context switching by operating entirely via Poll Mode Drivers (PMDs). Instead of relying on expensive hardware interrupts—which arbitrarily invoke the OS scheduler and pollute the instruction cache—a dedicated CPU core runs a continuous user-space loop, lock-free polling the DMA-mapped hardware ring buffers for completion.1 When combined with RISC-V's Zawrs extension (WRS.NTO), DPDK/SPDK deployments achieve extreme throughput and single-digit microsecond latencies without the extreme thermal degradation historically associated with PMD spin-polling.35

Concurrently, the newer Linux io\_uring subsystem provides an advanced "pseudo-bypass" architecture for applications that still require underlying kernel services. io\_uring establishes highly optimized, shared Submission Queue (SQ) and Completion Queue (CQ) rings between user-space and the kernel. By enabling the IORING\_SETUP\_IOPOLL flag, the kernel launches a dedicated background thread to directly poll the hardware block drivers, while the user thread pushes I/O descriptors into the shared memory ring completely lock-free. This orchestrates extreme I/O parallelism, effectively eliminating system call boundary crossings per transaction without requiring root privileges or entirely monopolizing the PCIe device.45

### **Transparent Zero-Copy: The zIO Framework**

While user-space kernel bypass frameworks eliminate CPU-driven copies, re-architecting legacy applications to interface with DPDK or SPDK is an exceptionally costly engineering endeavor.47 Furthermore, even within high-performance stacks, application-level "double buffering" remains a prevalent bottleneck. Modern IO-intensive applications routinely copy data from the I/O stack into application-level buffers, modify a minor routing header, and copy the payload onward.44

The **zIO** framework introduces an entirely transparent zero-copy mechanism specifically engineered to dismantle the double buffering paradigm. zIO operates as an unprivileged user-space library that intercepts memory allocation and standard library copy calls via dynamic linking (LD\_PRELOAD).44

Instead of executing a physical, byte-by-byte memory copy (e.g., memcpy), zIO heavily leverages the processor's Memory Management Unit (MMU) to perform logical manipulation:

1. **Buffer Tracking:** zIO intercepts the IO stream, tracking physical buffer locations using a highly concurrent skiplist mapped to the intermediate data locations. The skiplist tracks original buffer addresses, core intermediate buffer boundaries, and timestamps with negligible overhead.44  
2. **Page Table Unmapping:** When the application logically attempts to execute a copy, zIO intercepts the call. It unmaps the destination virtual memory addresses, leaving them pointing to invalid space.44  
3. **Page Fault Interception:** When the application logic subsequently attempts to process the data, accessing the destination virtual address, the MMU naturally triggers a Page Fault.44  
4. **Transparent Resolution:** zIO's custom fault handler intercepts the trap, instantly resolves it by manipulating the page tables, and maps the exact physical memory pages containing the original DMA-delivered data directly into the user-space application's context.44

By relying entirely on virtual memory mapping rather than CPU-driven byte copying, zIO bypasses massive memory bandwidth constraints. Exhaustive evaluations demonstrate that this transparent elimination of copies yields up to a 1.8× throughput increase on standard Linux IO stacks, and up to 2.5× throughput improvements when layered atop kernel-bypass stacks like Strata. Critically, zIO achieves this while dynamically reducing Translation Lookaside Buffer (TLB) shootdown overheads by up to 17% compared to traditional mmap methodologies.44

### **Express Resubmission Path (XRP): eBPF NVMe Offloading**

The baseline latency of modern NVMe SSDs, particularly those utilizing 3D XPoint architectures or low-latency NAND, has dropped aggressively to the low single-digit microseconds (e.g., \~3µs for an Intel Optane P5800X).45 At these unprecedented hardware speeds, the execution of the Linux kernel's block layer, file system layer, and system call validation routines accounts for approximately 51.4% of the total end-to-end read latency.45

While complete kernel bypass frameworks (like SPDK) successfully eliminate this overhead, they force the application to abandon the kernel's robust VFS features, requiring complex custom file system logic and drastically complicating the safe, concurrent sharing of the storage device among isolated processes.1

**XRP (Express Resubmission Path)** represents a landmark architectural breakthrough, pushing the concept of "Near-Data Processing" (NDP) directly into the Linux kernel by leveraging Extended Berkeley Packet Filter (eBPF) technology.45

Rather than propagating a fetched disk block all the way up through the kernel storage stack to user-space, XRP allows unprivileged applications to inject a highly restricted, user-defined eBPF function directly into the NVMe driver's hardware interrupt handler—the lowest and fastest execution context in the operating system.49

#### **XRP Architecture and B-Tree Traversal Acceleration**

The immense utility of XRP is profoundly evident in heavily pointer-chasing data structures, such as the on-disk B-trees and Log-Structured Merge (LSM) trees utilized by pervasive key-value stores like MongoDB (WiredTiger) and BPF-KV.51 A standard B-tree lookup over an NVMe drive is structurally inefficient: the application issues a read() for the root node, waits through the full kernel stack context switch, parses the node in user-space to extract the next block pointer, issues a new read() syscall for the child node, and repeats the cycle.45

With XRP integrated, the execution pipeline is fundamentally transformed:

1. **Metadata Digest Propagation:** Because the lowest-level NVMe driver operates exclusively on raw Logical Block Addressing (LBAs) and lacks abstract file system context, XRP extracts a minimal "metadata digest" directly from the file system (e.g., ext4).45 This digest maps logical file offsets to physical NVMe blocks and is securely cached directly in the NVMe driver.45  
2. **eBPF Execution:** When the hardware raises an interrupt signaling that the root B-tree node has been fetched via DMA, the XRP eBPF hook immediately fires within the high-priority interrupt context.45  
3. **In-Kernel Node Parsing:** The verifier-secured eBPF bytecode instantly parses the raw B-tree block in kernel memory, executes the search logic against the node keys, and isolates the exact offset of the next required child node.51  
4. **Instant Resubmission:** Using the metadata digest, the XRP handler translates the logical child offset directly to a physical LBA and instantly appends a new read request back onto the NVMe Submission Queue (SQ), completely bypassing the block layer and VFS.45

This lightning-fast fetch-parse-resubmit cycle loops entirely within the NVMe driver's interrupt context until the final data payload (the leaf node) is identified. Only upon completion is the target data payload copied to a user-provided scratch buffer, and the thread finally awakened for processing.45

By entirely avoiding the kernel-to-user context switches for intermediate node lookups, XRP slashes the p99 latency of B-tree index traversals by up to 34% and drives raw multi-threaded throughput increases of up to 2.5×. Under heavy contention, XRP exhibits 56% better tail latency than equivalent SPDK implementations, delivering near bare-metal performance while rigorously maintaining OS-level access control, file system coherency, and safe multi-tenant core sharing.1

## **Synthesis: The Frontier of Co-Design on Weakly-Ordered Silicon**

The relentless acceleration of IO interfaces necessitates a profound architectural convergence between silicon microarchitecture and systems software. The monolithic operating system kernel, originally designed for single-core, heavily-ordered execution contexts, is fundamentally misaligned with the latency physics of modern NVMe arrays and 400GbE NICs.

Architecting next-generation data planes demands ruthless exploitation of the specific physical attributes unique to highly parallel, weakly-ordered processor layouts:

* On **ARM64 Neoverse** platforms (such as AWS Graviton), systems engineers must categorically abandon full DMB barriers in favor of the specialized, unidirectional LDAR/STLR constructs. To prevent L2 spatial prefetchers from destroying cache cohesion, atomic variables must be aggressively padded to 128-byte alignments. Concurrently, leveraging Top Byte Ignore (TBI) allows the safe circumvention of the ABA problem without complex double-width atomics, provided the software mitigates the inevitable SMMUv3 PCIe translation faults.  
* On **RISC-V** implementations, maximizing the RVWMO model requires the intelligent application of .aq/.rl atomic load/store annotations to prevent unconstrained pipeline reordering. Integrating the Zawrs (WRS.NTO) extension enables absolute zero-power user-space spin-polling, while the Zihintntl (NTL.P1) extension guarantees that high-speed IO transit data bypasses the L1 cache, preserving invaluable compute state.

When these granular microarchitectural optimizations are fused with modern zero-kernel I/O frameworks—whether via PMDs in DPDK, page-fault-driven memory mapping in zIO, or deep in-kernel eBPF resubmission hooks like XRP—the resulting ecosystem dissolves traditional latency ceilings. As hardware capability continues to outpace legacy software constructs, the absolute mastery of hardware-software co-design at the bare-metal silicon boundary remains the definitive discipline for extracting absolute compute performance.

#### **Works cited**

1. XRP: In-Kernel Storage Functions with eBPF \- USENIX, accessed April 7, 2026, [https://www.usenix.org/sites/default/files/conference/protected-files/osdi22\_slides\_zhong\_yuhong.pdf](https://www.usenix.org/sites/default/files/conference/protected-files/osdi22_slides_zhong_yuhong.pdf)  
2. Arm64 performance and Arm memory model (barriers) \- General Discussion, accessed April 7, 2026, [https://community.amperecomputing.com/t/arm64-performance-and-arm-memory-model-barriers/891](https://community.amperecomputing.com/t/arm64-performance-and-arm-memory-model-barriers/891)  
3. 17.1. RVWMO Memory Consistency Model, Version 2.0 :: RISC-V Ratified Specifications Library \- riscv.org, accessed April 7, 2026, [https://docs.riscv.org/reference/isa/unpriv/rvwmo.html](https://docs.riscv.org/reference/isa/unpriv/rvwmo.html)  
4. Benchmarking ARM processors: Graviton 4, Graviton 3 and Apple M2 \- Daniel Lemire's blog, accessed April 7, 2026, [https://lemire.me/blog/2024/07/10/benchmarking-arm-processors-graviton-4-graviton-3-and-apple-m2/](https://lemire.me/blog/2024/07/10/benchmarking-arm-processors-graviton-4-graviton-3-and-apple-m2/)  
5. L1 data memory system \- Arm Neoverse N2 Core Technical Reference Manual, accessed April 7, 2026, [https://developer.arm.com/documentation/102099/0003/L1-data-memory-system](https://developer.arm.com/documentation/102099/0003/L1-data-memory-system)  
6. The AArch64 processor (aka arm64), part 14: Barriers \- The Old New Thing, accessed April 7, 2026, [https://devblogs.microsoft.com/oldnewthing/20220812-00/?p=106968](https://devblogs.microsoft.com/oldnewthing/20220812-00/?p=106968)  
7. Arm Neoverse V1 Platform: Unleashing a new performance tier for Arm-based computing, accessed April 7, 2026, [https://developer.arm.com/community/arm-community-blogs/b/architectures-and-processors-blog/posts/neoverse-v1-platform-a-new-performance-tier-for-arm](https://developer.arm.com/community/arm-community-blogs/b/architectures-and-processors-blog/posts/neoverse-v1-platform-a-new-performance-tier-for-arm)  
8. How expensive are memory barriers on ARM64? \-- The cost of a DMB instruction, accessed April 7, 2026, [https://stackoverflow.com/questions/76095875/how-expensive-are-memory-barriers-on-arm64-the-cost-of-a-dmb-instruction](https://stackoverflow.com/questions/76095875/how-expensive-are-memory-barriers-on-arm64-the-cost-of-a-dmb-instruction)  
9. Ampere Altra vs. AWS Graviton, accessed April 7, 2026, [https://amperecomputing.com/en/briefs/ai-altra-vs-graviton](https://amperecomputing.com/en/briefs/ai-altra-vs-graviton)  
10. Load-Acquire and Store-Release instructions \- Learn the architecture \- Memory Systems, Ordering, and Barriers, accessed April 7, 2026, [https://developer.arm.com/documentation/102336/0100/Load-Acquire-and-Store-Release-instructions](https://developer.arm.com/documentation/102336/0100/Load-Acquire-and-Store-Release-instructions)  
11. ARM64 One-Way Barriers \- ElseWhere, accessed April 7, 2026, [https://duetorun.com/blog/20231007/a64-oneway-barrier/](https://duetorun.com/blog/20231007/a64-oneway-barrier/)  
12. ARM STLR memory ordering semantics \- Stack Overflow, accessed April 7, 2026, [https://stackoverflow.com/questions/65466840/arm-stlr-memory-ordering-semantics](https://stackoverflow.com/questions/65466840/arm-stlr-memory-ordering-semantics)  
13. No Barrier in the Road: A Comprehensive Study and Optimization of ARM Barriers \- ipads-sjtu, accessed April 7, 2026, [https://ipads.se.sjtu.edu.cn/\_media/publications/liuppopp20.pdf](https://ipads.se.sjtu.edu.cn/_media/publications/liuppopp20.pdf)  
14. I Built a Lock-Free Queue That's 15x Faster Than Mutex — Here's How (And Why You Should Care) | by CodeOrbit | Medium, accessed April 7, 2026, [https://medium.com/@theabhishek.040/building-lock-free-concurrent-queue-rust-atomic-operations-15x-faster-ad4ea325683a](https://medium.com/@theabhishek.040/building-lock-free-concurrent-queue-rust-atomic-operations-15x-faster-ad4ea325683a)  
15. RFC-0143: Userspace Top-Byte-Ignore \- Fuchsia.dev, accessed April 7, 2026, [https://fuchsia.dev/fuchsia-src/contribute/governance/rfcs/0143\_userspace\_top\_byte\_ignore](https://fuchsia.dev/fuchsia-src/contribute/governance/rfcs/0143_userspace_top_byte_ignore)  
16. Top Byte Ignore For Fun and Memory Savings | Blog \- Linaro, accessed April 7, 2026, [https://www.linaro.org/blog/top-byte-ignore-for-fun-and-memory-savings/](https://www.linaro.org/blog/top-byte-ignore-for-fun-and-memory-savings/)  
17. Armv8.5-A Memory Tagging Extension \- Arm Developer, accessed April 7, 2026, [https://developer.arm.com/-/media/Arm%20Developer%20Community/PDF/Arm\_Memory\_Tagging\_Extension\_Whitepaper.pdf](https://developer.arm.com/-/media/Arm%20Developer%20Community/PDF/Arm_Memory_Tagging_Extension_Whitepaper.pdf)  
18. Armv8 has an opt-in feature you can turn on to ignore the top byte \- Hacker News, accessed April 7, 2026, [https://news.ycombinator.com/item?id=21029526](https://news.ycombinator.com/item?id=21029526)  
19. linux device driver \- PCIe DMA aarch64 0x10 Translation Fault \- Stack Overflow, accessed April 7, 2026, [https://stackoverflow.com/questions/70651820/pcie-dma-aarch64-0x10-translation-fault](https://stackoverflow.com/questions/70651820/pcie-dma-aarch64-0x10-translation-fault)  
20. D8.9.1 Logical Address Tag control \- Arm Developer, accessed April 7, 2026, [https://developer.arm.com/documentation/ddi0487/maa/-Part-D-The-AArch64-System-Level-Architecture/-Chapter-D8-The-AArch64-Virtual-Memory-System-Architecture/-D8-9-Logical-Address-Tagging/-D8-9-1-Logical-Address-Tag-control](https://developer.arm.com/documentation/ddi0487/maa/-Part-D-The-AArch64-System-Level-Architecture/-Chapter-D8-The-AArch64-Virtual-Memory-System-Architecture/-D8-9-Logical-Address-Tagging/-D8-9-1-Logical-Address-Tag-control)  
21. Xilinx PCIe DMA translation fault \- Arm Development Platforms forum, accessed April 7, 2026, [https://community.arm.com/support-forums/f/dev-platforms-forum/52088/xilinx-pcie-dma-translation-fault](https://community.arm.com/support-forums/f/dev-platforms-forum/52088/xilinx-pcie-dma-translation-fault)  
22. ARM® System Memory Management Unit Architecture Specification, SMMU architecture version 3.0 and version 3.1, accessed April 7, 2026, [http://kib.kiev.ua/x86docs/ARM/SMMU/IHI\_0070\_A\_SMMUv3.pdf](http://kib.kiev.ua/x86docs/ARM/SMMU/IHI_0070_A_SMMUv3.pdf)  
23. Pcie driver smmu error \- Jetson TX2 \- NVIDIA Developer Forums, accessed April 7, 2026, [https://forums.developer.nvidia.com/t/pcie-driver-smmu-error/128388](https://forums.developer.nvidia.com/t/pcie-driver-smmu-error/128388)  
24. Configure the translation regime \- Learn the architecture \- AArch64 memory management examples, accessed April 7, 2026, [https://developer.arm.com/documentation/102416/0201/Single-level-table-at-EL3/Configure-the-translation-regime](https://developer.arm.com/documentation/102416/0201/Single-level-table-at-EL3/Configure-the-translation-regime)  
25. Measuring the size of the cache line empirically \- Daniel Lemire's blog, accessed April 7, 2026, [https://lemire.me/blog/2023/12/12/measuring-the-size-of-the-cache-line-empirically/](https://lemire.me/blog/2023/12/12/measuring-the-size-of-the-cache-line-empirically/)  
26. Understanding std::hardware\_destructive\_interference\_size and std::hardware\_constructive\_interference\_size \- Stack Overflow, accessed April 7, 2026, [https://stackoverflow.com/questions/39680206/understanding-stdhardware-destructive-interference-size-and-stdhardware-cons](https://stackoverflow.com/questions/39680206/understanding-stdhardware-destructive-interference-size-and-stdhardware-cons)  
27. Why are most cache line sizes designed to be 64 byte instead of 32/128byte now?, accessed April 7, 2026, [https://stackoverflow.com/questions/68320687/why-are-most-cache-line-sizes-designed-to-be-64-byte-instead-of-32-128byte-now](https://stackoverflow.com/questions/68320687/why-are-most-cache-line-sizes-designed-to-be-64-byte-instead-of-32-128byte-now)  
28. Cache must be physically organized as 64 byte lines. Cache line size is most imp... | Hacker News, accessed April 7, 2026, [https://news.ycombinator.com/item?id=45248049](https://news.ycombinator.com/item?id=45248049)  
29. Should the cache padding size of x86-64 be 128 bytes? \- Stack Overflow, accessed April 7, 2026, [https://stackoverflow.com/questions/72126606/should-the-cache-padding-size-of-x86-64-be-128-bytes](https://stackoverflow.com/questions/72126606/should-the-cache-padding-size-of-x86-64-be-128-bytes)  
30. Aligning to cache line and knowing the cache line size \- Stack Overflow, accessed April 7, 2026, [https://stackoverflow.com/questions/7281699/aligning-to-cache-line-and-knowing-the-cache-line-size](https://stackoverflow.com/questions/7281699/aligning-to-cache-line-and-knowing-the-cache-line-size)  
31. LockFreeSpscQueue: A high-performance, single-producer, single-consumer (SPSC) queue implemented in modern C++23 : r/cpp \- Reddit, accessed April 7, 2026, [https://www.reddit.com/r/cpp/comments/1mjwjx6/lockfreespscqueue\_a\_highperformance/](https://www.reddit.com/r/cpp/comments/1mjwjx6/lockfreespscqueue_a_highperformance/)  
32. The RISC-V Instruction Set Manual Volume I, accessed April 7, 2026, [https://courses.grainger.illinois.edu/ece391/sp2025/docs/unpriv-isa-20240411.pdf](https://courses.grainger.illinois.edu/ece391/sp2025/docs/unpriv-isa-20240411.pdf)  
33. riscv-elf-psabi-doc/riscv-atomic.adoc at master \- GitHub, accessed April 7, 2026, [https://github.com/riscv-non-isa/riscv-elf-psabi-doc/blob/master/riscv-atomic.adoc](https://github.com/riscv-non-isa/riscv-elf-psabi-doc/blob/master/riscv-atomic.adoc)  
34. RVWMO Explanatory Material, Version 0.1 \- RISC-V Instruction Set Manual, Volume I: RISC-V User-Level ISA | Five EmbedDev, accessed April 7, 2026, [https://five-embeddev.com/riscv-user-isa-manual/Priv-v1.12/memory.html](https://five-embeddev.com/riscv-user-isa-manual/Priv-v1.12/memory.html)  
35. 14.1. "Zawrs" Extension for Wait-on-Reservation-Set instructions, Version 1.01 \- riscv.org, accessed April 7, 2026, [https://docs.riscv.org/reference/isa/unpriv/zawrs.html](https://docs.riscv.org/reference/isa/unpriv/zawrs.html)  
36. Wait-on-Reservation-Set (WRS) | RISC-V, accessed April 7, 2026, [https://lists.riscv.org/g/apps-tools-software/attachment/180/0/Wait-on-Reservation-Set%20(WRS).pdf](https://lists.riscv.org/g/apps-tools-software/attachment/180/0/Wait-on-Reservation-Set%20\(WRS\).pdf)  
37. Shifting Vector Database Workloads to Arm Neoverse: Performance and Cost Observations, accessed April 7, 2026, [https://dev.to/e\_b680bbca20c348/shifting-vector-database-workloads-to-arm-neoverse-performance-and-cost-observations-470p](https://dev.to/e_b680bbca20c348/shifting-vector-database-workloads-to-arm-neoverse-performance-and-cost-observations-470p)  
38. riscv-zawrs/zawrs.adoc at main \- GitHub, accessed April 7, 2026, [https://github.com/riscv/riscv-zawrs/blob/main/zawrs.adoc](https://github.com/riscv/riscv-zawrs/blob/main/zawrs.adoc)  
39. riscv.md \- GitHub Gist, accessed April 7, 2026, [https://gist.github.com/nlitsme/babe52c747d8e8a7c5c87bd69860084a](https://gist.github.com/nlitsme/babe52c747d8e8a7c5c87bd69860084a)  
40. 8.1. "Zihintntl" Extension for Non-Temporal Locality Hints, Version 1.0 \- riscv.org, accessed April 7, 2026, [https://docs.riscv.org/reference/isa/unpriv/zihintntl.html](https://docs.riscv.org/reference/isa/unpriv/zihintntl.html)  
41. The RISC-V Instruction Set Manual \- UIM, accessed April 7, 2026, [https://uim.fei.stuba.sk/wp-content/uploads/2018/02/riscv-spec-2022.pdf](https://uim.fei.stuba.sk/wp-content/uploads/2018/02/riscv-spec-2022.pdf)  
42. The RISC-V Instruction Set Manual: Volume I: Unprivileged Architecture, accessed April 7, 2026, [https://lists.riscv.org/g/tech-unprivileged/attachment/535/0/unpriv-isa-asciidoc.pdf](https://lists.riscv.org/g/tech-unprivileged/attachment/535/0/unpriv-isa-asciidoc.pdf)  
43. tech-unprivileged@lists.riscv.org | Non-temporal locality hints (Zihintntl), accessed April 7, 2026, [https://lists.riscv.org/g/tech-unprivileged/topic/non\_temporal\_locality\_hints/83128638](https://lists.riscv.org/g/tech-unprivileged/topic/non_temporal_locality_hints/83128638)  
44. zIO: Accelerating IO-Intensive Applications with Transparent Zero-Copy IO \- USENIX, accessed April 7, 2026, [https://www.usenix.org/system/files/osdi22-stamler.pdf](https://www.usenix.org/system/files/osdi22-stamler.pdf)  
45. XRP: In-Kernel Storage Functions with eBPF \- USENIX, accessed April 7, 2026, [https://www.usenix.org/system/files/osdi22-zhong\_1.pdf](https://www.usenix.org/system/files/osdi22-zhong_1.pdf)  
46. GitHub \- riscvarchive/riscv-zawrs: The repo will be used to hold the draft Zawrs (fast-track) extension and to make releases for reviews., accessed April 7, 2026, [https://github.com/riscvarchive/riscv-zawrs](https://github.com/riscvarchive/riscv-zawrs)  
47. zIO: Accelerating IO-Intensive Applications with Transparent Zero-Copy IO \- USENIX, accessed April 7, 2026, [https://www.usenix.org/conference/osdi22/presentation/stamler](https://www.usenix.org/conference/osdi22/presentation/stamler)  
48. tstamler/zIO: Transparent zero-copy IO · GitHub, accessed April 7, 2026, [https://github.com/tstamler/zIO](https://github.com/tstamler/zIO)  
49. XRP: In-Kernel Storage Functions with eBPF, accessed April 7, 2026, [http://nvmw.ucsd.edu/nvmw2023-program/nvmw2023-paper17-final\_version\_your\_extended\_abstract.pdf](http://nvmw.ucsd.edu/nvmw2023-program/nvmw2023-paper17-final_version_your_extended_abstract.pdf)  
50. XRP: In-Kernel Storage Functions with eBPF \- Asaf Cidon, accessed April 7, 2026, [https://www.asafcidon.com/uploads/5/9/7/0/59701649/xrp.pdf](https://www.asafcidon.com/uploads/5/9/7/0/59701649/xrp.pdf)  
51. XRP: In-Kernel Storage Functions with eBPF \- USENIX, accessed April 7, 2026, [https://www.usenix.org/conference/osdi22/presentation/zhong](https://www.usenix.org/conference/osdi22/presentation/zhong)  
52. BPF-oF: Storage Function Pushdown Over the Network \- arXiv, accessed April 7, 2026, [https://arxiv.org/html/2312.06808v1](https://arxiv.org/html/2312.06808v1)

---

*Copyright (c) 2026 SiliconLanguage Foundry. All rights reserved.*
