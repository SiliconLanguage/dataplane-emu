/**
 * @file main.cpp
 * @brief dataplane-emu — Zero-copy NVMe emulator entry point
 *
 * ARM64 Architectural Notes (Graviton3 / Cobalt 100):
 *   1. Architecture: Armv8.4-A (via -mcpu=neoverse-v1 / neoverse-n2)
 *   2. Atomics: LSE (CASAL/LDADD) — single-instruction lock-free ops
 *   3. SIMD: SVE/NEON for vectorised data movement
 *
 * SPDK integration:
 *   When compiled with -DWITH_SPDK=ON, the -s flag activates the real
 *   SPDK storage backend via dataplane_env::detect() + init_spdk().
 *   The environment wrapper (spdk_env.hpp) handles:
 *     AWS  → vfio-pci, trtype=PCIe, raw BDF addressing
 *     Azure → uio_hv_generic, trtype=vdev, VMBus GUID addressing
 *
 * @note Requires GCC 11+ or Clang 14+ for full Neoverse support.
 */

#ifndef FUSE_USE_VERSION
#define FUSE_USE_VERSION 31
#endif

#include <iostream>
#include <thread>
#include <cstdint>
#include <csignal>
#include <exception>
#include <string>
#include <cstring>
#include <vector>
#include <unistd.h>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <linux/fs.h>
#include <fuse.h>
#include <sys/wait.h>
#include <dataplane_emu/sq_cq.hpp>
#include "fuse_bridge/interceptor.h"

#ifdef WITH_SPDK
#include <dataplane_emu/spdk_env.hpp>
#endif

// Reverting to global mountpoint for the signal handler to access
static std::string global_mountpoint = "/mnt/virtual_nvme";

// Owned mutable copy for async-signal-safe execv() in the signal handler.
// c_str() returns const char* — casting that away for execv is UB if the
// runtime places the string in read-only pages.  We keep a separate char[]
// that is guaranteed mutable and survives for the lifetime of the process.
static char sig_mountpoint[4096];

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
         *
         * sig_mountpoint is a static char[] — always mutable, always
         * valid, never involves heap or std::string internals.
         */
        char fusermount_bin[] = "/usr/bin/fusermount3";
        char flag_u[]         = "-u";
        char* const args[] = {
            fusermount_bin,
            flag_u,
            sig_mountpoint,
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
    bool enable_spdk = false;
    std::string blk_device_path;

    while ((opt = getopt(argc, argv, "m:d:bks")) != -1) {
        switch (opt) {
            case 'm':
                global_mountpoint = optarg;
                break;
            // sig_mountpoint sync is done once below after all opts are parsed
            case 'd':
                blk_device_path = optarg;
                break;
            case 'b':
                run_benchmark = true;
                break;
            case 'k':
                enable_kernel_bypass = true;
                break;
            case 's':
                enable_spdk = true;
                break;
            default:
                std::cerr << "Usage: " << argv[0]
                          << " [-m mountpoint] [-d /dev/nvmeXnY] [-b] [-k] [-s]\n"
                          << "  -m  FUSE mountpoint (default: /mnt/virtual_nvme)\n"
                          << "  -d  Raw block device for FUSE bridge real I/O\n"
                          << "  -b  Run lock-free ring benchmark\n"
                          << "  -k  Enable FUSE kernel-bypass bridge\n"
                          << "  -s  Enable SPDK storage backend "
                             "(auto-detects AWS/Azure)\n";
                return 1;
        }
    }

    // Sync the mutable signal-handler buffer from the (possibly updated)
    // global_mountpoint.  Must happen after option parsing, before signal
    // registration, and the memcpy length is clamped to the buffer size.
    {
        size_t len = global_mountpoint.size();
        if (len >= sizeof(sig_mountpoint))
            len = sizeof(sig_mountpoint) - 1;
        std::memcpy(sig_mountpoint, global_mountpoint.data(), len);
        sig_mountpoint[len] = '\0';
    }

    std::signal(SIGINT, signal_handler);

    // -----------------------------------------------------------------
    // SPDK Environment Initialisation (compile-gated: -DWITH_SPDK=ON)
    // -----------------------------------------------------------------
    // When -s is passed, we detect the cloud environment (AWS Graviton
    // or Azure Cobalt 100) and initialise SPDK before starting the
    // emulator engine.
    //
    // Fail-fast contract:
    //   - detect() throws std::runtime_error if the cloud is unknown,
    //     the required kernel module is not loaded, or no device is found.
    //   - init_spdk() calls std::abort() if spdk_env_init() fails.
    //   - No silent degradation or kernel-space fallbacks.
#ifdef WITH_SPDK
    if (enable_spdk) {
        std::cerr << "[main] SPDK mode requested — detecting environment...\n";
        try {
            auto env_cfg = dataplane_env::detect();

            std::cerr << "[main] Cloud  : "
                      << dataplane_env::cloud_provider_str(env_cfg.cloud) << "\n"
                      << "[main] Transport: "
                      << dataplane_env::transport_type_str(env_cfg.transport) << "\n"
                      << "[main] Device : " << env_cfg.device_address << "\n"
                      << "[main] Driver : " << env_cfg.expected_driver << "\n";

            // init_spdk() populates spdk_env_opts, calls spdk_env_init(),
            // and configures spdk_nvme_transport_id with the correct
            // trtype (PCIe for AWS, vdev for Azure) and traddr
            // (BDF or VMBus GUID respectively).
            dataplane_env::init_spdk(env_cfg);

            std::cerr << "[main] SPDK environment initialised successfully.\n";
        } catch (const std::runtime_error& e) {
            // Fail-fast: driver mismatch, missing module, or no device.
            std::cerr << "[main] FATAL: " << e.what() << "\n";
            return 1;
        }
    }
#else
    if (enable_spdk) {
        std::cerr << "[main] FATAL: SPDK support not compiled in.\n"
                  << "  Rebuild with: cmake -DWITH_SPDK=ON ..\n";
        return 1;
    }
#endif

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

        // --- Open raw block device for real I/O (if -d was given) ---
        FuseBridgeCtx fuse_ctx{};
        fuse_ctx.engine   = &engine;
        fuse_ctx.blk_fd   = -1;
        fuse_ctx.blk_size = 0;

        if (!blk_device_path.empty()) {
            int fd = open(blk_device_path.c_str(), O_RDWR);
            if (fd < 0) {
                std::cerr << "FATAL: cannot open block device "
                          << blk_device_path << ": "
                          << strerror(errno) << std::endl;
                engine.shutdown();
                if (device_thread.joinable()) device_thread.join();
                return 1;
            }
            uint64_t dev_bytes = 0;
            if (ioctl(fd, BLKGETSIZE64, &dev_bytes) < 0) {
                std::cerr << "FATAL: BLKGETSIZE64 failed on "
                          << blk_device_path << ": "
                          << strerror(errno) << std::endl;
                close(fd);
                engine.shutdown();
                if (device_thread.joinable()) device_thread.join();
                return 1;
            }
            fuse_ctx.blk_fd   = fd;
            fuse_ctx.blk_size = static_cast<int64_t>(dev_bytes);
            std::cerr << "[main] Block device " << blk_device_path
                      << " opened (fd=" << fd
                      << ", size=" << dev_bytes << " bytes)" << std::endl;
        }

        std::vector<std::string> fuse_args_storage = {
            argv[0],
            "-f",
            "-o",
            "allow_other",
            global_mountpoint,
        };
        std::vector<char*> fuse_argv;
        fuse_argv.reserve(fuse_args_storage.size());
        for (auto& arg : fuse_args_storage) {
            fuse_argv.push_back(arg.data());
        }
        int fuse_argc = static_cast<int>(fuse_argv.size());
        int rc = 1;

        std::cout << "Mounting FUSE bridge at " << global_mountpoint << "..." << std::endl;
        try {
            rc = run_fuse_interceptor(fuse_argc, fuse_argv.data(), &fuse_ctx);
        } catch (const std::exception& ex) {
            std::cerr << "FUSE bridge terminated with exception: " << ex.what() << std::endl;
        } catch (...) {
            std::cerr << "FUSE bridge terminated with an unknown exception." << std::endl;
        }

        engine.shutdown();
        if (device_thread.joinable()) {
            device_thread.join();
        }
        return rc;
    } else {
        std::cout << "Simulation running. Press Ctrl+C to exit." << std::endl;
        device_thread.join();
    }

    engine.shutdown();
    return 0;
}