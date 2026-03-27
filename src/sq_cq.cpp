#include <dataplane_emu/sq_cq.hpp>
#include <iostream>
#include <cassert>
#include <thread> // Required for std::this_thread::yield
#include <sched.h>

namespace dataplane_emu {

// ---------------------------------------------------------
// HARDWARE/DEVICE THREAD (Simulating the NVMe Controller)
// ---------------------------------------------------------
/**
 * Checks if the process is restricted to a single CPU core.
 * The result is cached in a static variable to avoid repeated syscalls
 * during high-performance polling loops.
 */
static bool is_single_cpu_restricted() {
    // The 'static' keyword ensures this initialization happens only once
    static bool cached_result = []() {
        cpu_set_t cpuset;
        CPU_ZERO(&cpuset);
        
        // sched_getaffinity is a system call (kernel transition)
        if (sched_getaffinity(0, sizeof(cpu_set_t), &cpuset) == 0) {
            return CPU_COUNT(&cpuset) == 1;
        }
        
        // Fallback: If syscall fails, assume safe mode (yield enabled)
        return true; 
    }();
    
    return cached_result;
}

/**
 * Architecture-aware yield to optimize for ARM64 weak memory consistency.
 * * On ARM64 (Graviton), single-core execution can lead to consumer starvation 
 * if the producer is preempted. This function forces a kernel transition 
 * only when a single-CPU bottleneck is detected.
 */
inline void yield_single_cpu_restricted() {
#if defined(__aarch64__)
    // Scoped specifically for ARM64 to handle relaxed memory ordering hazards.
    if (is_single_cpu_restricted()) {
        // Path A: Single-core fallback. Force a context switch (sched_yield) 
        // to prevent livelocks between the producer and consumer threads.
        sched_yield();
    } else {
        // Path B: Multi-core Zero-Syscall path.
        // Provide a hardware hint (yield) to the CPU to reduce power/latency 
        // in spin-loops without exiting User Mode.
        __asm__ volatile("yield" ::: "memory");
    }
#else
    // Non-ARM architectures (e.g., x86_64) typically follow Total Store Ordering.
    // Use a lightweight hardware pause to mitigate spin-loop overhead without 
    // the heavy penalty of a kernel syscall.
    __builtin_ia32_pause(); 
#endif
}

void SqCqEmulator::nvme_device_loop() {
    size_t local_sq_head = 0;
    size_t local_cq_tail = 0;

    // Pattern: Independent Output Data (P2135R1 Section 2.6.2)
    // Relaxed is safe here as is_running is a simple control signal.
    while (is_running.load(std::memory_order_relaxed)) {
        // Pattern: Shared Handover (Acquire)
        // Ensure we see the payload data written by the host before the tail update.
        size_t current_sq_tail = sq_tail.load(std::memory_order_acquire);

        if (local_sq_head == current_sq_tail) {
            // Friendly Polling: Prevent Livelock/Deadlock on single-CPU systems.
            // Allows the Host thread to get a CPU slice to submit more I/O.
            yield_single_cpu_restricted();
            continue;
        }

        // Process all available entries in the Submission Queue
        while (local_sq_head != current_sq_tail) {
            const SQEntry& req = sq_payloads[local_sq_head % QUEUE_SIZE];
            
            // Simulation logic: In a real emulator, you would process 'req' here.
            local_sq_head++;

            // Prepare the Completion Queue entry
            CQEntry& comp = cq_payloads[local_cq_tail % QUEUE_SIZE];
            comp.status = 0; 
            comp.sq_head_pointer = static_cast<uint16_t>(local_sq_head % 65536);
            comp.complete_ts = read_hw_timestamp();
            local_cq_tail++;
        }

        // Pattern: Shared Handover (Release)
        // Ensure CQ payload writes are visible to Host before updating cq_tail.
        cq_tail.store(local_cq_tail, std::memory_order_release);
    }
}

// ---------------------------------------------------------
// HOST THREAD (Simulating SPDK User-Space Application)
// ---------------------------------------------------------

bool SqCqEmulator::submit_io(uint64_t target_lba) {
    // Pattern: Non-Racing Local Access (P2135R1 Section 2.1)
    // Host is the sole writer of sq_tail, so relaxed load always sees latest local state.
    size_t current_sq_tail = sq_tail.load(std::memory_order_relaxed);
    
    // Acquire ensures we see the Device's latest cq_tail to check for queue-full.
    size_t current_cq_tail = cq_tail.load(std::memory_order_acquire);

    if (current_sq_tail - current_cq_tail >= QUEUE_SIZE) {
        return false; 
    }

    // Write the actual I/O command to the ring buffer
    sq_payloads[current_sq_tail % QUEUE_SIZE] = SQEntry{1, target_lba, 4096, read_hw_timestamp()};

    // Pattern: Shared Handover (Release)
    // Commit the data to memory before making the new tail visible to the Device core.
    sq_tail.store(current_sq_tail + 1, std::memory_order_release);
    return true;
}

void SqCqEmulator::host_submit_and_poll(uint64_t target_lba) {
    // Submit with a yield-retry loop for single-core stability
    while (!submit_io(target_lba)) {
        yield_single_cpu_restricted();
        }

    // Capture our local progress to know which completion to wait for.
    size_t expected_cq_tail = sq_tail.load(std::memory_order_relaxed);

    while (true) {
        // Pattern: Shared Handover (Acquire)
        // Ensure we see the comp.status update written by the Device thread.
        size_t current_cq_tail = cq_tail.load(std::memory_order_acquire);
        
        if (current_cq_tail >= expected_cq_tail) {
            const CQEntry& comp = cq_payloads[(expected_cq_tail - 1) % QUEUE_SIZE];
            assert(comp.status == 0 && "I/O Failed!");
            // Capture SQ→CQ round-trip latency in timer ticks.
            const SQEntry& submitted = sq_payloads[(expected_cq_tail - 1) % QUEUE_SIZE];
            last_latency_ticks.store(
                comp.complete_ts - submitted.submit_ts,
                std::memory_order_relaxed);
            break; 
        }
        
        // Friendly Polling: Prevent starvation of the Device thread on one CPU.
        yield_single_cpu_restricted();
    }
}

void SqCqEmulator::shutdown() {
    // Release ensures any final memory operations are visible before stopping.
    is_running.store(false, std::memory_order_release);
}

} // namespace dataplane_emu