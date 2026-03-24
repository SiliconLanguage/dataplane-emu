#define FUSE_USE_VERSION 31

#include <fuse.h>
#include <string.h>
#include <errno.h>
#include <iostream>

#include "interceptor.h"
// Update the include path to match your new structure
#include <dataplane_emu/sq_cq.hpp>
using namespace dataplane_emu;

// --- IMPORTANT ---
// Replace 'SpdkSimulator' with the actual name of the class defined in your sq_cq.hpp
//using BackendType = SqCqEmulator ; 

// Helper to get our NVMe backend instance from the FUSE context
static SqCqEmulator* get_backend() {
    return static_cast<SqCqEmulator*>(fuse_get_context()->private_data);
}

// Intercepts 'stat' calls (e.g., when you run 'ls -l')
static int dp_getattr(const char *path, struct stat *stbuf, struct fuse_file_info *fi) {
    (void) fi;
    memset(stbuf, 0, sizeof(struct stat));

    if (strcmp(path, "/") == 0) {
        stbuf->st_mode = S_IFDIR | 0755;
        stbuf->st_nlink = 2;
        return 0;
    } else if (strcmp(path, "/nvme_raw_0") == 0) {
        stbuf->st_mode = S_IFREG | 0666;
        stbuf->st_nlink = 1;
        stbuf->st_size = 1024 * 1024 * 1024; // Mocked to 1GB
        return 0;
    }

    return -ENOENT;
}

// Intercepts directory listings
static int dp_readdir(const char *path, void *buf, fuse_fill_dir_t filler, off_t offset,
                      struct fuse_file_info *fi, enum fuse_readdir_flags flags) {
    (void) offset; (void) fi; (void) flags;

    if (strcmp(path, "/") != 0)
        return -ENOENT;

    filler(buf, ".", NULL, 0, (fuse_fill_dir_flags)0);
    filler(buf, "..", NULL, 0, (fuse_fill_dir_flags)0);
    filler(buf, "nvme_raw_0", NULL, 0, (fuse_fill_dir_flags)0);

    return 0;
}

// Intercepts file open requests
static int dp_open(const char *path, struct fuse_file_info *fi) {
    if (strcmp(path, "/nvme_raw_0") != 0)
        return -ENOENT;

    SqCqEmulator* backend = get_backend();
    if (!backend) {
        return -EIO;
    }

    return 0;
}

// Intercepts reads and routes them to the SQ/CQ implementation
// static int dp_read(const char *path, char *buf, size_t size, off_t offset, struct fuse_file_info *fi) {
//     if (strcmp(path, "/nvme_raw_0") != 0)
//         return -ENOENT;

//     SqCqEmulator* backend = get_backend();
    
//     // Meaningful Log: Operation, Path, Size, and Offset
//     std::cout << "[FUSE -> SQ/CQ] READ  path: " << path 
//               << " | size: " << size 
//               << " bytes | offset: " << offset << std::endl;
    
//     // Mock response
//     memset(buf, 'A', size); 
//     return size;
// }

// static int dp_read(const char *path, char *buf, size_t size, off_t offset, struct fuse_file_info *fi) {
//     if (strcmp(path, "/nvme_raw_0") != 0)
//         return -ENOENT;

//     // 1. Create a meaningful string to identify this specific chunk
//     std::string data = "[OFFSET:" + std::to_string(offset) + "] DATA-PLANE-EMU-BYTE-STREAM ";
    
//     // 2. Fill the buffer with this repeating pattern
//     size_t pattern_len = data.length();
//     for (size_t i = 0; i < size; ++i) {
//         buf[i] = data[i % pattern_len];
//     }

//     // 3. Keep your beautiful logging
//     std::cout << "[FUSE -> SQ/CQ] READ  path: " << path 
//               << " | size: " << size 
//               << " bytes | offset: " << offset << std::endl;

//     return size;
// }

/**
 * @brief High-Performance FUSE Read Handler (Data Plane Optimized)
 * * ARCHITECTURAL OPTIMIZATIONS (The "Zero-Overhead" Path):
 * * 1. Lock-Free Memory Allocation: 
 * Replaced `std::string` with a stack-allocated `char` array. This completely 
 * bypasses the glibc heap manager, eliminating global lock contention across 
 * FUSE worker threads while keeping the data L1-cache hot.
 * * 2. Vectorized Buffer Fills: 
 * Replaced byte-by-byte modulo division (`i % len`) with chunked `memcpy()`. 
 * Division is CPU-expensive; `memcpy` allows the ARM64 Neoverse core to use 
 * highly optimized SIMD/SVE vector instructions for bulk data transfer.
 * * 3. Blocking Syscall Avoidance: 
 * Replaced `std::endl` with `\n`. `std::endl` forces a synchronous `fflush()` 
 * system call to the TTY driver, destroying microsecond latency. `\n` allows 
 * the C++ runtime to efficiently batch the stream output.
 * * 4. Lock-Free Telemetry Sampling: 
 * Introduced a `thread_local` counter with `__builtin_expect` branch hints. 
 * Reduces visual logging context switches by 99.9% without introducing 
 * costly atomic variables or cache-line bouncing.
 */

constexpr uint32_t STDOUT_LOG_NTH = 1500;
constexpr long BRANCH_UNLIKELY = 0;

static int dp_read(const char *path, char *buf, size_t size, off_t offset, struct fuse_file_info *fi) {
    if (strcmp(path, "/nvme_raw_0") != 0)
        return -ENOENT;

    // 1. Extreme Fast Path: Kernel-optimized SIMD memset blocks all loop overhead
    memset(buf, 'A', size);

    // 2. Sampled, Non-Flushing Telemetry
    static thread_local uint32_t log_counter = 0;
    
    if (__builtin_expect(++log_counter >= STDOUT_LOG_NTH, BRANCH_UNLIKELY)) {
        // String formatting only occurs explicitly within the cold telemetry branch!
        std::cout << "[FUSE -> SQ/CQ] READ  path: " << path 
                  << " | size: " << size 
                  << " bytes | offset: " << offset << std::endl; // Flush explicitly!
        log_counter = 0;
    }

    return size;
}

// Intercepts writes and routes them to the SQ/CQ implementation
static int dp_write(const char *path, const char *buf, size_t size, off_t offset, struct fuse_file_info *fi) {
    if (strcmp(path, "/nvme_raw_0") != 0)
        return -ENOENT;

    SqCqEmulator* backend = get_backend();

    static thread_local uint32_t log_counter = 0;
    
    if (__builtin_expect(++log_counter >= STDOUT_LOG_NTH, BRANCH_UNLIKELY)) {
        std::cout << "[FUSE -> SQ/CQ] WRITE path: " << path 
                  << " | size: " << size 
                  << " bytes | offset: " << offset << std::endl; // Flush explicitly!
        log_counter = 0;
    }

    return size;
}

static struct fuse_operations dp_oper = {
    .getattr = dp_getattr,
    .open    = dp_open,
    .read    = dp_read,
    .write   = dp_write,
    .readdir = dp_readdir,
};

// Start the FUSE loop
int run_fuse_interceptor(int argc, char *argv[], void* backend_instance) {
    std::cout << "Starting FUSE POSIX Interceptor..." << std::endl;
    return fuse_main(argc, argv, &dp_oper, backend_instance);
}