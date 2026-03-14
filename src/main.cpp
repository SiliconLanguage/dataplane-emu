#include <iostream>
#include <thread>
#include <cstdint>

// Include public API
#include <dataplane_emu/sq_cq.hpp>

int main() {
    using namespace dataplane_emu;
    
    SqCqEmulator engine;

    // Start the simulated NVMe device in a background thread
    std::thread device_thread(&SqCqEmulator::nvme_device_loop, &engine);

    std::cout << "Starting kernel-bypass benchmark...\n";

    // Host submits 1,000,000 I/O requests
    for (uint64_t lba = 0; lba < 1000000; lba++) {
        engine.host_submit_and_poll(lba);
    }

    std::cout << "Successfully submitted and polled 1,000,000 I/Os using lock-free atomics.\n";

    engine.shutdown();
    device_thread.join();
    return 0;
}