#pragma once

#include <cstdint>

/// Context passed through fuse_main() private_data.
/// Carries both the emulator engine and the raw block-device fd.
struct FuseBridgeCtx {
    void*    engine;      // SqCqEmulator*
    int      blk_fd;      // open fd to the raw block device (-1 if none)
    int64_t  blk_size;    // device size in bytes (from BLKGETSIZE64)
};

int run_fuse_interceptor(int argc, char *argv[], FuseBridgeCtx* ctx);