#include <atomic>
#include <cstdint>
#include <iostream>
#include <vector>
#include <thread>

// ---------------------------------------------------------
// 1. The Iov (Data Plane): Zero-Copy Memory Region
// In a real SPDK implementation, this represents a hugepage 
// memory region mapped directly to the NVMe DMA engine.
// ---------------------------------------------------------
struct IovPayload {
    uint32_t tensor_id;
    float kv_cache_data; // Emulated LLM KV Cache chunk
};

// ---------------------------------------------------------
// 2. Hardware-Assisted Tagged Pointers (ARM64 TBI)
// ---------------------------------------------------------
// We pack an 8-bit version counter into the top 8 bits (NVBITS) 
// of the 64-bit pointer. Because ARM64 Top Byte Ignore (TBI) 
// ignores bits [63:56] during memory translation, the hardware 
// will natively strip this tag for us during dereferencing.

inline uint64_t create_tagged_ptr(IovPayload* ptr, uint8_t version) {
    uint64_t raw_ptr = reinterpret_cast<uint64_t>(ptr);
    // Clear top 8 bits of pointer (just in case) and OR the version
    return (raw_ptr & 0x00FFFFFFFFFFFFFFULL) | (static_cast<uint64_t>(version) << 56);
}

inline uint8_t get_tag_version(uint64_t tagged_ptr) {
    return static_cast<uint8_t>(tagged_ptr >> 56);
}

// ---------------------------------------------------------
// 3. The Ior (Control Plane): Lock-Free Submission Queue
// ---------------------------------------------------------
class LockFreeIorRing {
private:
    // Standard 64-bit atomic, natively supported by ARMv8 LSE atomics
    std::atomic<uint64_t> head_tagged_ptr; 

public:
    LockFreeIorRing(IovPayload* initial_payload) {
        head_tagged_ptr.store(create_tagged_ptr(initial_payload, 0), std::memory_order_relaxed);
    }

    // Lock-free push mimicking NVMe submission queue behavior
    void enqueue_io_buffer(IovPayload* new_payload) {
        uint64_t expected_tagged = head_tagged_ptr.load(std::memory_order_relaxed);
        uint64_t new_tagged;

        do {
            // Extract the current version and increment it to prevent ABA
            uint8_t next_version = get_tag_version(expected_tagged) + 1;
            
            // Pack the new pointer and the incremented version into a single 64-bit word
            new_tagged = create_tagged_ptr(new_payload, next_version);

            // Execute a highly efficient 64-bit Compare-and-Swap. 
            // If another thread preempts us and causes an ABA scenario, the version 
            // mismatch in the top 8 bits forces the CAS to fail, protecting the structure.
        } while (!head_tagged_ptr.compare_exchange_weak(
                    expected_tagged, 
                    new_tagged, 
                    std::memory_order_release, 
                    std::memory_order_acquire));
    }

    // Consumer reads the buffer for LLM Inference
    IovPayload* process_next_io() {
        uint64_t current_tagged = head_tagged_ptr.load(std::memory_order_acquire);
        
        // --- THE HARDWARE MAGIC ---
        // We cast the 64-bit tagged integer directly back to a pointer.
        // We DO NOT execute a software bit-mask (ptr & 0x00FFFFFFFFFFFFFF).
        // ARM64 TBI silicon will automatically ignore the top 8 bits when we read from it.
        return reinterpret_cast<IovPayload*>(current_tagged);
    }
};

int main() {
    std::cout << "[*] Initializing Dataplane Emulator on ARM64..." << std::endl;
    
    // Allocate our zero-copy data region
    IovPayload buffer1 = {1, {1.0f}};
    IovPayload buffer2 = {2, {2.0f}};

    // Initialize the Control Plane ring
    LockFreeIorRing ior_ring(&buffer1);

    // Thread 1: NVMe/SPDK Polling Thread enqueuing new data
    std::thread producer([&]() {
        ior_ring.enqueue_io_buffer(&buffer2);
    });

    // Thread 2: llama.cpp Inference Thread consuming data
    std::thread consumer([&]() {
        IovPayload* payload = ior_ring.process_next_io();
        
        // This memory access proves TBI is working. If TBI is off, 
        // the top 8 bits (the version tag) will cause a Segmentation Fault.
        std::cout << "[+] llama.cpp fetched Tensor ID: " << payload->tensor_id << std::endl;
    });

    producer.join();
    consumer.join();

    return 0;
}