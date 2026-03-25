#pragma once
// libdataplane_intercept.so — Phase 4 LD_PRELOAD POSIX Interception Bridge
//
// Replaces the FUSE bridge with zero-context-switch interception.
// Architecture references:
//   Intel DAOS libpil4dfs  — Fake FD routing via dlsym trampolines
//   DeepSeek 3FS USRBIO    — Sync-to-async bridging on lock-free rings
//   zIO (OSDI '22)         — userfaultfd lazy copy elimination
//
// Build: g++ -std=c++20 -march=armv8.2-a+lse -moutline-atomics -shared -fPIC

#include <cstdint>
#include <cstddef>
#include <cstring>
#include <atomic>
#include <array>
#include <new>
#include <thread>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/ioctl.h>
#include <linux/userfaultfd.h>
#include <unistd.h>

#include "sq_cq.hpp"

namespace dataplane_intercept {

// =========================================================================
// §0  Constants
// =========================================================================

inline constexpr size_t CACHE_LINE = 64;

// Fake FD space starts here; anything >= this value is routed to the engine.
inline constexpr int FAKE_FD_BASE   = 1'000'000;
inline constexpr int FAKE_FD_MAX    = 1'032'767;       // 32 K concurrent handles
inline constexpr size_t FAKE_FD_COUNT = FAKE_FD_MAX - FAKE_FD_BASE;

// Copy-elision tracking thresholds (zIO heuristics).
inline constexpr size_t COPY_ELIDE_MIN_BYTES   = 16 * 1024;   // 16 KB floor
inline constexpr double COPY_ELIDE_BAILOUT_RATIO = 0.06;       // 6 %

// =========================================================================
// §1  LD_PRELOAD Trampoline Table
// =========================================================================
//
// Resolved once at library init via dlsym(RTLD_NEXT, ...).
// Every intercepted call checks the trampoline; if the engine is not the
// target (wrong FD, non-tracked buffer), the original libc symbol is called
// with zero overhead beyond a branch.

// Typedefs matching the libc signatures we intercept.
using open_fn_t     = int      (*)(const char*, int, ...);
using close_fn_t    = int      (*)(int);
using pread_fn_t    = ssize_t  (*)(int, void*, size_t, off_t);
using pwrite_fn_t   = ssize_t  (*)(int, const void*, size_t, off_t);
using read_fn_t     = ssize_t  (*)(int, void*, size_t);
using write_fn_t    = ssize_t  (*)(int, const void*, size_t);
using fstat_fn_t    = int      (*)(int, struct stat64*);
using lseek_fn_t    = off_t    (*)(int, off_t, int);
using ftruncate_fn_t = int     (*)(int, off_t);
using memcpy_fn_t   = void*    (*)(void*, const void*, size_t);
using memmove_fn_t  = void*    (*)(void*, const void*, size_t);

/// Lazily-resolved original libc symbols.
/// Populated by dp_init_trampolines() at library load (__attribute__((constructor))).
struct TrampolineTable {
    open_fn_t     real_open     = nullptr;
    close_fn_t    real_close    = nullptr;
    pread_fn_t    real_pread    = nullptr;
    pwrite_fn_t   real_pwrite   = nullptr;
    read_fn_t     real_read     = nullptr;
    write_fn_t    real_write    = nullptr;
    fstat_fn_t    real_fstat    = nullptr;
    lseek_fn_t    real_lseek    = nullptr;
    ftruncate_fn_t real_ftruncate = nullptr;
    memcpy_fn_t   real_memcpy   = nullptr;
    memmove_fn_t  real_memmove  = nullptr;
};

/// Single global instance; written once at init, read-only thereafter.
/// No synchronisation needed beyond the constructor ordering guarantee.
inline TrampolineTable g_trampoline{};

// =========================================================================
// §2  Fake File Descriptor Table  (DAOS libpil4dfs pattern)
// =========================================================================
//
// When open() intercepts a path under the dataplane mount, we mint a fake FD
// in [FAKE_FD_BASE, FAKE_FD_MAX) and store the mapping here.  Subsequent
// pread/pwrite calls check this table before falling through to libc.

/// Per-handle state kept entirely in user space.
struct FakeFdEntry {
    enum class State : uint8_t { FREE = 0, OPEN = 1 };

    std::atomic<State> state{State::FREE};
    uint64_t           engine_handle;   // opaque handle from the dataplane engine
    uint64_t           file_size;       // cached file size for range checks
    uint32_t           flags;           // O_RDONLY / O_WRONLY / O_RDWR etc.
    std::atomic<off_t> file_pos{0};     // current position for read()/write()
};

/// Wrap FakeFdEntry in a cache-line-aligned slot to prevent false sharing.
struct alignas(CACHE_LINE) FakeFdSlot {
    FakeFdEntry entry;
};

/// Fixed-capacity FD table.  Index = (fd - FAKE_FD_BASE).
struct FakeFdTable {
    std::array<FakeFdSlot, FAKE_FD_COUNT> slots{};

    /// Allocate the next free slot. Returns the fake FD, or -1 on exhaustion.
    int alloc(uint64_t engine_handle, uint64_t file_size, uint32_t flags) noexcept;

    /// Release a fake FD. Returns 0 on success, -1 if fd is out of range or already free.
    int release(int fd) noexcept;

    /// Lookup, returning nullptr for non-fake or closed FDs.
    FakeFdEntry* lookup(int fd) noexcept {
        if (fd < FAKE_FD_BASE || fd >= FAKE_FD_MAX) return nullptr;
        auto& e = slots[static_cast<size_t>(fd - FAKE_FD_BASE)].entry;
        if (e.state.load(std::memory_order_acquire) != FakeFdEntry::State::OPEN)
            return nullptr;
        return &e;
    }
};

/// Global FD table (process-wide, thread-safe via per-slot atomics).
inline FakeFdTable g_fd_table{};

// §3 and §5 replaced by SqCqEmulator bridge — see EmulatorPool below §4.

// =========================================================================
// §4  Copy-Elision Tracker  (zIO pattern — userfaultfd)
// =========================================================================
//
// Intercepts memcpy/memmove for buffers ≥ 16 KB.  Instead of copying,
// the source pages are left unmapped via userfaultfd.  If the application
// faults on the intermediate buffer, a lazy copy is performed.
//
// Bailout: if (bytes_faulted / bytes_tracked) > 6%, future copies on that
// buffer are no longer elided.

/// Metadata for one tracked elided copy.
struct ElisionEntry {
    const void* src;               // original source address
    void*       dst;               // destination (left unmapped)
    size_t      length;            // bytes
    size_t      bytes_faulted;     // how many bytes the app actually touched
    bool        bailed_out;        // true → stop eliding for this buffer

    /// Check the bailout ratio and flip the flag if exceeded.
    bool should_bailout() noexcept {
        if (bailed_out) return true;
        if (length == 0) return false;
        if (static_cast<double>(bytes_faulted) /
            static_cast<double>(length) > COPY_ELIDE_BAILOUT_RATIO) {
            bailed_out = true;
        }
        return bailed_out;
    }
};

/// Registration bookkeeping for the userfaultfd subsystem.
struct UserfaultfdContext {
    int uffd = -1;                          // userfaultfd file descriptor

    /// Initialise userfaultfd. Returns 0 on success, -errno on failure.
    int init() noexcept;

    /// Register a virtual address range for fault interception.
    int register_range(void* addr, size_t length) noexcept;

    /// Unregister and remap a range after a lazy copy completes.
    int unregister_range(void* addr, size_t length) noexcept;

    /// Tear down.
    void destroy() noexcept;
};

/// Per-thread elision state.  A flat array is used for the initial
/// implementation; a skiplist index can be layered on top when the
/// number of tracked regions warrants it.
inline constexpr size_t MAX_ELISION_ENTRIES = 256;

struct ElisionTracker {
    std::array<ElisionEntry, MAX_ELISION_ENTRIES> entries{};
    size_t count = 0;
    UserfaultfdContext uffd_ctx{};

    /// Track a new elided copy.  Returns true if the copy was elided.
    bool track(void* dst, const void* src, size_t len) noexcept;

    /// Called from the userfaultfd handler when a page is faulted.
    /// Performs the lazy copy for the faulted page and updates accounting.
    int handle_fault(void* fault_addr) noexcept;

    /// Lookup by destination address.
    ElisionEntry* find(void* addr) noexcept;
};

// =========================================================================
// §5  Per-Thread SqCqEmulator Pool  (Phase 2 — direct NVMe queue bridge)
// =========================================================================
//
// Each application thread that calls pread/pwrite gets a dedicated
// SqCqEmulator (SPSC queue pair) plus a device-emulation thread.
// pread/pwrite translate to SQEntry submissions via host_submit_and_poll(),
// exercising the full acquire/release handshake path.

inline constexpr size_t MAX_EMULATORS = 128;

struct EmulatorPool {
    std::array<dataplane_emu::SqCqEmulator, MAX_EMULATORS> emulators{};
    std::array<std::thread, MAX_EMULATORS> device_threads{};
    std::atomic<size_t> count{0};

    /// Allocate a fresh SqCqEmulator + start its device thread.
    dataplane_emu::SqCqEmulator* allocate() noexcept;

    /// Shutdown all emulators and join device threads.
    void shutdown_all() noexcept;
};

/// Global emulator pool — started/stopped by library lifecycle.
inline EmulatorPool g_emulator_pool{};

/// Get (or lazily allocate) the calling thread's SqCqEmulator.
dataplane_emu::SqCqEmulator* dp_get_thread_emulator() noexcept;

// =========================================================================
// §6  Library Lifecycle
// =========================================================================

/// Resolve all dlsym trampolines.  Called from __attribute__((constructor)).
void dp_init_trampolines() noexcept;

/// Tear down rings, uffd, and release fake FDs.
/// Called from __attribute__((destructor)).
void dp_fini() noexcept;

/// Check whether a path falls under the dataplane mount prefix.
bool dp_is_dataplane_path(const char* path) noexcept;

} // namespace dataplane_intercept
