// 1. VERSION DEFINITION MUST BE THE VERY FIRST LINE
#ifndef FUSE_USE_VERSION
#define FUSE_USE_VERSION 31
#endif

#include <iostream>
#include <thread>
#include <cstdint>
#include <csignal>
#include <fuse.h>

// Include public API
#include <dataplane_emu/sq_cq.hpp>
#include "fuse_bridge/interceptor.h"

// Global pointer so the signal handler can see the mount info
static const char* global_mountpoint = "/mnt/virtual_nvme";

void signal_handler(int sig) {
    (void)sig; // Suppress unused warning
    std::cout << "\n[Signal] Cleaning up FUSE mount..." << std::endl;
    
    std::string cmd = "fusermount3 -u " + std::string(global_mountpoint) + " > /dev/null 2>&1";
    
    // 2. Fix 'warn_unused_result' by checking the return value
    int ret = system(cmd.c_str());
    (void)ret; 

    exit(0);
}

int main(int argc, char* argv[]) {
    // Register signal handler for Ctrl+C
    std::signal(SIGINT, signal_handler);

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

    // 2. Prepare FUSE mount arguments
    // We'll point it to /mnt/virtual_nvme
    // '-f' keeps it in the foreground so you can see logs
    std::cout << "Starting kernel-bypass backend..." << std::endl;

    // FUSE requires the program name (argv[0]) to initialize
    // Add "-o", "allow_other" to the arguments
    // Change fuse_argc to 5 and add the allow_other option
    const char* fuse_argv[] = { 
        argv[0], 
        "-f", 
        "-o", "allow_other", 
        global_mountpoint, 
        NULL 
    };
    int fuse_argc = 5;

    std::cout << "Mounting FUSE bridge at /mnt/virtual_nvme..." << std::endl;
    std::cout << "Press Ctrl+C to unmount and exit." << std::endl;

    // Start the interceptor loop
    return run_fuse_interceptor(fuse_argc, (char**)fuse_argv, &engine);

    engine.shutdown();
    device_thread.join();
    return 0;
}