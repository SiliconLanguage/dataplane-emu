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
#include <sys/types.h>
#include <sys/ioctl.h>
#include <linux/userfaultfd.h>
#include <unistd.h>

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

// Ring sizing — must be power-of-two.
inline constexpr size_t IO_RING_SIZE = 1024;
static_assert((IO_RING_SIZE & (IO_RING_SIZE - 1)) == 0,
              "IO_RING_SIZE must be power of two");

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

// =========================================================================
// §3  I/O Ring Submission Descriptor (Ior — DeepSeek 3FS bridge)
// =========================================================================
//
// Translates synchronous POSIX calls into asynchronous ring submissions.
// Each intercepted pread/pwrite produces one IorEntry, submitted to a
// per-thread SPSC ring.  The engine thread polls and completes them.

struct IorEntry {
    enum class Op : uint8_t { READ = 0, WRITE = 1, FSYNC = 2 };

    Op       opcode;
    uint8_t  _reserved[3];
    int      fake_fd;          // identifies the FakeFdEntry
    uint64_t offset;           // file offset
    uint32_t length;           // bytes
    void*    user_buf;         // caller-supplied buffer (zero-copy target)

    // Completion signal: the engine stores the result here and sets ready.
    alignas(CACHE_LINE) std::atomic<bool> ready{false};
    ssize_t  result;           // bytes transferred, or -errno
};
static_assert(alignof(IorEntry) >= CACHE_LINE,
              "IorEntry completion flag must sit on its own cache line");

/// Lock-free SPSC ring for IorEntry pointers.
/// Producer: intercepted application thread.
/// Consumer: dataplane engine polling thread.
struct alignas(CACHE_LINE) IorRing {
    std::array<IorEntry*, IO_RING_SIZE> buf{};
    alignas(CACHE_LINE) std::atomic<size_t> head{0};   // producer writes
    alignas(CACHE_LINE) std::atomic<size_t> tail{0};   // consumer reads

    /// Submit an entry (producer side). Returns false if ring is full.
    bool submit(IorEntry* entry) noexcept {
        const size_t h = head.load(std::memory_order_relaxed);
        const size_t next = (h + 1) & (IO_RING_SIZE - 1);
        if (next == tail.load(std::memory_order_acquire))
            return false;   // ring full
        buf[h] = entry;
        head.store(next, std::memory_order_release);
        return true;
    }

    /// Dequeue one entry (consumer side). Returns nullptr if ring is empty.
    IorEntry* poll() noexcept {
        const size_t t = tail.load(std::memory_order_relaxed);
        if (t == head.load(std::memory_order_acquire))
            return nullptr; // ring empty
        IorEntry* e = buf[t];
        tail.store((t + 1) & (IO_RING_SIZE - 1), std::memory_order_release);
        return e;
    }
};

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
// §5  Engine Polling Thread & Per-Thread Ring Registry
// =========================================================================
//
// Each application thread that calls pread/pwrite gets a thread_local IorRing.
// Rings are registered with the global engine context so the polling thread
// can drain them.  The engine completes requests with mock data (memset 'A'
// for reads, no-op for writes) — matching the FUSE bridge contract.

inline constexpr size_t MAX_RINGS = 128;

struct EngineContext {
    std::array<std::atomic<IorRing*>, MAX_RINGS> rings{};
    std::atomic<size_t> ring_count{0};
    std::atomic<bool>   running{false};

    /// Register a per-thread ring.  Returns slot index or -1 on overflow.
    int register_ring(IorRing* ring) noexcept {
        size_t idx = ring_count.fetch_add(1, std::memory_order_acq_rel);
        if (idx >= MAX_RINGS) {
            ring_count.fetch_sub(1, std::memory_order_relaxed);
            return -1;
        }
        rings[idx].store(ring, std::memory_order_release);
        return static_cast<int>(idx);
    }

    /// Engine polling loop — runs in a dedicated thread.
    void poll_loop() noexcept;
};

/// Global engine context — started at library init.
inline EngineContext g_engine{};

/// Get (or create) the calling thread's IorRing.
IorRing* dp_get_thread_ring() noexcept;

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
