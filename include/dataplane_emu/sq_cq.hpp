#pragma once

#include <cstdint>
#include <cstddef>
#include <array>
#include <atomic>
#include <new>

namespace dataplane_emu {

// // Use the C++ standard way to determine cache line size to prevent false sharing
// #ifdef __cpp_lib_hardware_interference_size
//     constexpr size_t CACHE_LINE_SIZE = std::hardware_destructive_interference_size;
// #else
//     constexpr size_t CACHE_LINE_SIZE = 64; // Fallback for older compilers
// #endif

// Define a stable constant. 64 is the standard for x86/ARM64.
// This satisfies the compiler's request for a stable ABI value.
constexpr size_t CACHE_LINE_SIZE = 64;

constexpr size_t QUEUE_SIZE = 1024; // Must be a power of 2 for fast modulo arithmetic

// ---------------------------------------------------------
// 1. Hardware-Defined Descriptors
// ---------------------------------------------------------

struct SQEntry {
    uint8_t  opcode;
    uint64_t lba;     // Logical Block Address
    uint32_t length;
};

struct CQEntry {
    uint8_t  status;
    uint16_t sq_head_pointer; // Device tells host how many SQ items it consumed
};

// ---------------------------------------------------------
// 2. The User-Space Storage Engine
// ---------------------------------------------------------
class SqCqEmulator {
private:
    // --- SUBMISSION QUEUE (SQ) ---
    std::array<SQEntry, QUEUE_SIZE> sq_payloads{};
    
    // The Host Doorbell (Host writes, Device reads)
    // Aligned to its own cache line to prevent false sharing with cq_tail
    alignas(CACHE_LINE_SIZE) std::atomic<size_t> sq_tail{0};
    
    // --- COMPLETION QUEUE (CQ) ---
    std::array<CQEntry, QUEUE_SIZE> cq_payloads{};
    
    // The Device Doorbell (Device writes, Host reads)
    alignas(CACHE_LINE_SIZE) std::atomic<size_t> cq_tail{0};

    // System run state
    alignas(CACHE_LINE_SIZE) std::atomic<bool> is_running{true};

public:
    SqCqEmulator() = default;

    // ---------------------------------------------------------
    // HARDWARE/DEVICE THREAD (Simulating the NVMe Controller)
    // ---------------------------------------------------------
    void nvme_device_loop();

    // ---------------------------------------------------------
    // HOST THREAD (Simulating SPDK User-Space Application)
    // ---------------------------------------------------------
    bool submit_io(uint64_t target_lba);
    void host_submit_and_poll(uint64_t target_lba);

    void shutdown();
};

} // namespace dataplane_emu