#include <dataplane_emu/sq_cq.hpp>
#include <iostream>
#include <cassert>

namespace dataplane_emu {

// ---------------------------------------------------------
// HARDWARE/DEVICE THREAD (Simulating the NVMe Controller)
// ---------------------------------------------------------
void SqCqEmulator::nvme_device_loop() {
    size_t local_sq_head = 0;
    size_t local_cq_tail = 0;

    while (is_running.load(std::memory_order_relaxed)) {
        size_t current_sq_tail = sq_tail.load(std::memory_order_acquire);

        if (local_sq_head != current_sq_tail) {
            while (local_sq_head != current_sq_tail) {
                const SQEntry& req = sq_payloads[local_sq_head % QUEUE_SIZE];
                local_sq_head++;

                CQEntry& comp = cq_payloads[local_cq_tail % QUEUE_SIZE];
                comp.status = 0; 
                comp.sq_head_pointer = static_cast<uint16_t>(local_sq_head % 65536);
                local_cq_tail++;
            }
            cq_tail.store(local_cq_tail, std::memory_order_release);
        }
    }
}

// ---------------------------------------------------------
// HOST THREAD (Simulating SPDK User-Space Application)
// ---------------------------------------------------------
bool SqCqEmulator::submit_io(uint64_t target_lba) {
    size_t current_sq_tail = sq_tail.load(std::memory_order_relaxed);
    size_t current_cq_tail = cq_tail.load(std::memory_order_acquire);

    if (current_sq_tail - current_cq_tail >= QUEUE_SIZE) {
        return false; 
    }

    sq_payloads[current_sq_tail % QUEUE_SIZE] = SQEntry{1, target_lba, 4096};
    sq_tail.store(current_sq_tail + 1, std::memory_order_release);
    return true;
}

void SqCqEmulator::host_submit_and_poll(uint64_t target_lba) {
    while (!submit_io(target_lba)) {
        // Spin
    }

    size_t expected_cq_tail = sq_tail.load(std::memory_order_relaxed);

    while (true) {
        size_t current_cq_tail = cq_tail.load(std::memory_order_acquire);
        if (current_cq_tail >= expected_cq_tail) {
            const CQEntry& comp = cq_payloads[(expected_cq_tail - 1) % QUEUE_SIZE];
            assert(comp.status == 0 && "I/O Failed!");
            break; 
        }
    }
}

void SqCqEmulator::shutdown() {
    is_running.store(false, std::memory_order_release);
}

} // namespace dataplane_emu