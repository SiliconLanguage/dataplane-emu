/**
 * @file hardware_optimization.h
 * @brief Graviton3 Architectural Notes
 * * This project is compiled with hardware-specific flags for AWS Graviton3:
 * * 1. Architecture: Armv8.4-A (via -mcpu=neoverse-v1)
 * 2. Atomics: Large System Extensions (LSE) enabled.
 * - Replaces traditional Load/Store-Exclusive loops (LDXR/STXR) with 
 * single-instruction atomics.
 * - Provides significant throughput gains for the dataplane-emu ring 
 * structures under high thread concurrency.
 * 3. SIMD: SVE (Scalable Vector Extension) support is available in hardware, 
 * though current logic primarily utilizes NEON/ASIMD for data movement.
 * * @note Requires GCC 11+ or Clang 14+ for full Neoverse-V1 support.
 */

#ifndef FUSE_USE_VERSION
#define FUSE_USE_VERSION 31
#endif

#include <iostream>
#include <thread>
#include <cstdint>
#include <csignal>
#include <unistd.h>
#include <fuse.h>
#include <sys/wait.h>
#include <dataplane_emu/sq_cq.hpp>
#include "fuse_bridge/interceptor.h"

// Reverting to global mountpoint for the signal handler to access
static std::string global_mountpoint = "/mnt/virtual_nvme";

// Signal handler that cleans up and exits immediately
/**
 * CLEAN ROOM SIGNAL HANDLER PATTERN
 * * Why this is necessary for dataplane-emu on ARM64/Graviton:
 * 1. Async-Signal Safety: Functions like std::string, std::cout, and system() 
 * acquire internal locks (e.g., heap locks). If a signal interrupts the 
 * main thread while it holds these locks, the handler will DEADLOCK.
 * 2. TSAN Compliance: ThreadSanitizer flags unsafe calls to prevent 
 * non-deterministic crashes during signal delivery.
 * 3. ARM64 Weak Ordering: Ensures that external hardware state (FUSE) is 
 * cleaned up without relying on the interrupted thread's memory state.
 */
void signal_handler(int sig) {
    (void)sig;

    /* * STEP 1: fork() - The "Clean Room" Creation
     * fork() is one of the few complex POSIX functions guaranteed to be 
     * Async-Signal-Safe. It creates a new process with its own address space, 
     * effectively "bypassing" any locks held by the interrupted parent thread.
     */
    pid_t pid = fork();

    if (pid == 0) {
        /* * STEP 2: execv() - Replace Child with Cleanup Utility
         * We replace the child process with /usr/bin/fusermount3. 
         * This avoids any further C++ library overhead or heap usage.
         */
        char* const args[] = {
            (char*)"/usr/bin/fusermount3", 
            (char*)"-u", 
            (char*)global_mountpoint.c_str(), 
            nullptr
        };
        
        // execv() is safe to call here; it completely replaces the process image.
        execv(args[0], args);

        // If execv returns, an error occurred. Use _exit to stop immediately.
        _exit(1); 
    } 
    else if (pid > 0) {
        /* * STEP 3: waitpid() - Synchronous Cleanup
         * The parent thread waits briefly for the child to complete the unmount. 
         * This ensures the filesystem is actually unmounted before the app exits.
         */
        waitpid(pid, nullptr, 0);
    }

    /* * STEP 4: _exit() - The Final Escape
     * We use _exit(0) instead of exit(0). 
     * exit() attempts to call static destructors and flush C++ streams, 
     * which are NOT signal-safe and cause TSAN warnings. _exit() terminates 
     * the process instantly and safely.
     */
    _exit(0);
}

int main(int argc, char* argv[]) {
    int opt;
    bool run_benchmark = false;
    bool enable_kernel_bypass = false;

    while ((opt = getopt(argc, argv, "m:bk")) != -1) {
        switch (opt) {
            case 'm':
                global_mountpoint = optarg;
                break;
            case 'b':
                run_benchmark = true;
                break;
            case 'k':
                enable_kernel_bypass = true;
                break;
            default:
                std::cerr << "Usage: " << argv[0] << " [-m mountpoint] [-b] [-k]\n";
                return 1;
        }
    }

    std::signal(SIGINT, signal_handler);

    using namespace dataplane_emu;
    SqCqEmulator engine;

    // Start the simulated NVMe device in a background thread
    std::thread device_thread(&SqCqEmulator::nvme_device_loop, &engine);

    if (run_benchmark) {
        std::cout << "Starting kernel-bypass benchmark...\n";

        // Host submits 1,000,000 I/O requests
        for (uint64_t lba = 0; lba < 1000000; lba++) {
            engine.host_submit_and_poll(lba);
        }

        std::cout << "Successfully submitted and polled 1,000,000 I/Os using lock-free atomics.\n";
    }

    if (!enable_kernel_bypass) {
        std::cout << "Kernel-bypass bridge not enabled. Shutting down." << std::endl;
        
        // Pattern: Shared Handover (Release)
        // Signal the device thread to stop its loop
        engine.shutdown();

        // Ensure we wait for the device thread to finish any pending work 
        // to avoid TSAN 'thread leak' warnings.
        if (device_thread.joinable()) {
            device_thread.join();
        }

        std::cout << "Execution complete." << std::endl;
        return 0; // Immediate exit to capture accurate 'real' time
    }

    if (enable_kernel_bypass) {
        std::cout << "Starting kernel-bypass backend..." << std::endl;

        const char* fuse_argv[] = {
            argv[0],
            "-f",
            "-o",
            "allow_other",
            global_mountpoint.c_str(),
            NULL
        };
        int fuse_argc = 5;

        std::cout << "Mounting FUSE bridge at " << global_mountpoint << "..." << std::endl;
        return run_fuse_interceptor(fuse_argc, (char**)fuse_argv, &engine);
    } else {
        std::cout << "Simulation running. Press Ctrl+C to exit." << std::endl;
        device_thread.join();
    }

    engine.shutdown();
    return 0;
}