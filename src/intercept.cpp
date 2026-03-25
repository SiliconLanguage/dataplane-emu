// libdataplane_intercept.so — LD_PRELOAD trampoline and lifecycle implementation
//
// Build as shared library:
//   g++ -std=c++20 -march=armv8.2-a+lse -moutline-atomics \
//       -shared -fPIC -o libdataplane_intercept.so src/intercept.cpp \
//       -ldl -lpthread

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include "dataplane_emu/intercept.hpp"

#include <dlfcn.h>
#include <fcntl.h>
#include <cerrno>
#include <cstdarg>
#include <cstdlib>
#include <cstdio>
#include <cstring>
#include <thread>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <sys/stat.h>
#include <sched.h>

namespace dataplane_intercept {

// =========================================================================
// Telemetry (sampled — matches FUSE bridge contract)
// =========================================================================

static constexpr uint32_t LOG_NTH = 1500;

// =========================================================================
// §5  Engine Polling Thread
// =========================================================================

void EngineContext::poll_loop() noexcept {
    while (running.load(std::memory_order_relaxed)) {
        bool did_work = false;
        const size_t n = ring_count.load(std::memory_order_acquire);
        for (size_t i = 0; i < n; ++i) {
            IorRing* ring = rings[i].load(std::memory_order_acquire);
            if (!ring) continue;

            IorEntry* entry = ring->poll();
            if (!entry) continue;
            did_work = true;

            // Mock engine: replicate FUSE bridge behaviour.
            switch (entry->opcode) {
            case IorEntry::Op::READ:
                // Fill caller buffer with pattern data (same as FUSE memset 'A').
                std::memset(entry->user_buf, 'A', entry->length);
                entry->result = static_cast<ssize_t>(entry->length);
                break;
            case IorEntry::Op::WRITE:
                // Accept write (no-op sink, same as FUSE).
                entry->result = static_cast<ssize_t>(entry->length);
                break;
            case IorEntry::Op::FSYNC:
                entry->result = 0;
                break;
            }

            // Signal completion — release ensures result is visible.
            entry->ready.store(true, std::memory_order_release);
        }

        if (!did_work) {
            // Friendly yield — avoid burning a core when idle.
#if defined(__aarch64__)
            __asm__ volatile("yield" ::: "memory");
#else
            __builtin_ia32_pause();
#endif
        }
    }
}

/// Thread-local SPSC ring + lazy registration.
static thread_local IorRing tl_ring{};
static thread_local bool    tl_ring_registered = false;

IorRing* dp_get_thread_ring() noexcept {
    if (!tl_ring_registered) {
        g_engine.register_ring(&tl_ring);
        tl_ring_registered = true;
    }
    return &tl_ring;
}

// =========================================================================
// §6  Library Lifecycle
// =========================================================================

static std::thread g_engine_thread;

void dp_init_trampolines() noexcept {
    g_trampoline.real_open     = reinterpret_cast<open_fn_t>(dlsym(RTLD_NEXT, "open"));
    g_trampoline.real_close    = reinterpret_cast<close_fn_t>(dlsym(RTLD_NEXT, "close"));
    g_trampoline.real_pread    = reinterpret_cast<pread_fn_t>(dlsym(RTLD_NEXT, "pread"));
    g_trampoline.real_pwrite   = reinterpret_cast<pwrite_fn_t>(dlsym(RTLD_NEXT, "pwrite"));
    g_trampoline.real_read     = reinterpret_cast<read_fn_t>(dlsym(RTLD_NEXT, "read"));
    g_trampoline.real_write    = reinterpret_cast<write_fn_t>(dlsym(RTLD_NEXT, "write"));
    g_trampoline.real_memcpy   = reinterpret_cast<memcpy_fn_t>(dlsym(RTLD_NEXT, "memcpy"));
    g_trampoline.real_memmove  = reinterpret_cast<memmove_fn_t>(dlsym(RTLD_NEXT, "memmove"));

    // Start the engine polling thread.
    g_engine.running.store(true, std::memory_order_release);
    g_engine_thread = std::thread([] { g_engine.poll_loop(); });
}

void dp_fini() noexcept {
    // Stop engine thread.
    g_engine.running.store(false, std::memory_order_release);
    if (g_engine_thread.joinable())
        g_engine_thread.join();

    // Release remaining fake FDs.
    for (size_t i = 0; i < FAKE_FD_COUNT; ++i) {
        auto& e = g_fd_table.slots[i].entry;
        if (e.state.load(std::memory_order_relaxed) == FakeFdEntry::State::OPEN)
            e.state.store(FakeFdEntry::State::FREE, std::memory_order_release);
    }
}

// Configurable mount prefix; override via DATAPLANE_MOUNT_PREFIX env var.
static const char* g_mount_prefix = nullptr;

static const char* get_mount_prefix() noexcept {
    if (!g_mount_prefix) {
        g_mount_prefix = std::getenv("DATAPLANE_MOUNT_PREFIX");
        if (!g_mount_prefix) g_mount_prefix = "/mnt/dataplane";
    }
    return g_mount_prefix;
}

bool dp_is_dataplane_path(const char* path) noexcept {
    if (!path) return false;
    const char* prefix = get_mount_prefix();
    return std::strncmp(path, prefix, std::strlen(prefix)) == 0;
}

// =========================================================================
// §2  Fake FD Table Implementation
// =========================================================================

int FakeFdTable::alloc(uint64_t engine_handle, uint64_t file_size, uint32_t flags) noexcept {
    for (size_t i = 0; i < FAKE_FD_COUNT; ++i) {
        auto& e = slots[i].entry;
        auto expected = FakeFdEntry::State::FREE;
        if (e.state.compare_exchange_strong(expected, FakeFdEntry::State::OPEN,
                                            std::memory_order_acq_rel)) {
            e.engine_handle = engine_handle;
            e.file_size     = file_size;
            e.flags         = flags;
            e.file_pos.store(0, std::memory_order_relaxed);
            return static_cast<int>(i) + FAKE_FD_BASE;
        }
    }
    return -1;  // table full
}

int FakeFdTable::release(int fd) noexcept {
    if (fd < FAKE_FD_BASE || fd >= FAKE_FD_MAX) return -1;
    auto& e = slots[static_cast<size_t>(fd - FAKE_FD_BASE)].entry;
    auto expected = FakeFdEntry::State::OPEN;
    if (!e.state.compare_exchange_strong(expected, FakeFdEntry::State::FREE,
                                         std::memory_order_acq_rel))
        return -1;
    return 0;
}

// =========================================================================
// §4  Copy-Elision / userfaultfd
// =========================================================================

int UserfaultfdContext::init() noexcept {
    long fd = syscall(SYS_userfaultfd, O_CLOEXEC | O_NONBLOCK);
    if (fd < 0) return -errno;
    uffd = static_cast<int>(fd);

    struct uffdio_api api{};
    api.api = UFFD_API;
    api.features = 0;
    if (ioctl(uffd, UFFDIO_API, &api) < 0) {
        int err = errno;
        close(uffd);
        uffd = -1;
        return -err;
    }
    return 0;
}

int UserfaultfdContext::register_range(void* addr, size_t length) noexcept {
    if (uffd < 0) return -EBADF;
    struct uffdio_register reg{};
    reg.range.start = reinterpret_cast<uintptr_t>(addr);
    reg.range.len   = length;
    reg.mode        = UFFDIO_REGISTER_MODE_MISSING;
    if (ioctl(uffd, UFFDIO_REGISTER, &reg) < 0)
        return -errno;
    return 0;
}

int UserfaultfdContext::unregister_range(void* addr, size_t length) noexcept {
    if (uffd < 0) return -EBADF;
    struct uffdio_range range{};
    range.start = reinterpret_cast<uintptr_t>(addr);
    range.len   = length;
    if (ioctl(uffd, UFFDIO_UNREGISTER, &range) < 0)
        return -errno;
    return 0;
}

void UserfaultfdContext::destroy() noexcept {
    if (uffd >= 0) {
        close(uffd);
        uffd = -1;
    }
}

bool ElisionTracker::track(void* dst, const void* src, size_t len) noexcept {
    if (len < COPY_ELIDE_MIN_BYTES || count >= MAX_ELISION_ENTRIES)
        return false;
    auto& e = entries[count];
    e.src           = src;
    e.dst           = dst;
    e.length        = len;
    e.bytes_faulted = 0;
    e.bailed_out    = false;
    ++count;
    uffd_ctx.register_range(dst, len);
    return true;
}

ElisionEntry* ElisionTracker::find(void* addr) noexcept {
    auto target = reinterpret_cast<uintptr_t>(addr);
    for (size_t i = 0; i < count; ++i) {
        auto base = reinterpret_cast<uintptr_t>(entries[i].dst);
        if (target >= base && target < base + entries[i].length)
            return &entries[i];
    }
    return nullptr;
}

int ElisionTracker::handle_fault(void* fault_addr) noexcept {
    auto* e = find(fault_addr);
    if (!e) return -ENOENT;

    const size_t page_size = static_cast<size_t>(sysconf(_SC_PAGESIZE));
    auto dst_base  = reinterpret_cast<uintptr_t>(e->dst);
    auto fault_ptr = reinterpret_cast<uintptr_t>(fault_addr);
    size_t page_offset = (fault_ptr - dst_base) & ~(page_size - 1);
    size_t copy_len = (page_offset + page_size <= e->length)
                    ? page_size : (e->length - page_offset);

    auto src_page = reinterpret_cast<const char*>(e->src) + page_offset;
    auto dst_page = reinterpret_cast<char*>(e->dst) + page_offset;

    struct uffdio_copy uc{};
    uc.dst  = reinterpret_cast<uintptr_t>(dst_page);
    uc.src  = reinterpret_cast<uintptr_t>(src_page);
    uc.len  = page_size;
    uc.mode = 0;
    if (ioctl(uffd_ctx.uffd, UFFDIO_COPY, &uc) < 0)
        return -errno;

    e->bytes_faulted += copy_len;
    e->should_bailout();
    return 0;
}

// =========================================================================
// Helper: submit an IorEntry and spin-wait for completion
// =========================================================================

static ssize_t dp_submit_and_wait(IorEntry::Op op, int fake_fd,
                                  void* buf, size_t len, off_t offset) noexcept {
    IorRing* ring = dp_get_thread_ring();

    // Stack-allocated entry — no heap on the hot path.
    IorEntry entry{};
    entry.opcode   = op;
    entry.fake_fd  = fake_fd;
    entry.offset   = static_cast<uint64_t>(offset);
    entry.length   = static_cast<uint32_t>(len);
    entry.user_buf = buf;
    entry.ready.store(false, std::memory_order_relaxed);
    entry.result   = 0;

    // Submit to the per-thread ring. Spin-retry if full.
    while (!ring->submit(&entry)) {
#if defined(__aarch64__)
        __asm__ volatile("yield" ::: "memory");
#else
        __builtin_ia32_pause();
#endif
    }

    // Spin-wait for the engine to complete the entry.
    while (!entry.ready.load(std::memory_order_acquire)) {
#if defined(__aarch64__)
        __asm__ volatile("yield" ::: "memory");
#else
        __builtin_ia32_pause();
#endif
    }

    return entry.result;
}

} // namespace dataplane_intercept

// =========================================================================
// §1  Exported LD_PRELOAD Trampolines  (C linkage)
// =========================================================================

using namespace dataplane_intercept;

extern "C" {

__attribute__((constructor))
static void dp_lib_init() {
    dp_init_trampolines();
}

__attribute__((destructor))
static void dp_lib_fini() {
    dp_fini();
}

// Mock file size matching the FUSE bridge's /nvme_raw_0 (1 GB).
static constexpr uint64_t MOCK_FILE_SIZE = 1024ULL * 1024 * 1024;

int open(const char* path, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list ap;
        va_start(ap, flags);
        mode = static_cast<mode_t>(va_arg(ap, int));
        va_end(ap);
    }

    if (!dp_is_dataplane_path(path))
        return g_trampoline.real_open(path, flags, mode);

    // Mint a fake FD — engine_handle 0 for mock mode.
    int fd = g_fd_table.alloc(/*engine_handle=*/0, MOCK_FILE_SIZE,
                              static_cast<uint32_t>(flags));
    if (fd < 0) {
        errno = ENFILE;
        return -1;
    }
    return fd;
}

int close(int fd) {
    if (g_fd_table.lookup(fd)) {
        g_fd_table.release(fd);
        return 0;
    }
    return g_trampoline.real_close(fd);
}

ssize_t pread(int fd, void* buf, size_t count, off_t offset) {
    FakeFdEntry* e = g_fd_table.lookup(fd);
    if (!e)
        return g_trampoline.real_pread(fd, buf, count, offset);

    // Clamp to file size.
    if (static_cast<uint64_t>(offset) >= e->file_size)
        return 0;
    uint64_t avail = e->file_size - static_cast<uint64_t>(offset);
    if (count > avail) count = static_cast<size_t>(avail);

    // Sampled telemetry (matches FUSE STDOUT_LOG_NTH cadence).
    static thread_local uint32_t log_ctr = 0;
    if (__builtin_expect(++log_ctr >= LOG_NTH, 0)) {
        std::fprintf(stderr, "[LD_PRELOAD -> IorRing] READ  fd:%d | size:%zu | offset:%lld\n",
                     fd, count, static_cast<long long>(offset));
        log_ctr = 0;
    }

    return dp_submit_and_wait(IorEntry::Op::READ, fd,
                              buf, count, offset);
}

ssize_t pwrite(int fd, const void* buf, size_t count, off_t offset) {
    FakeFdEntry* e = g_fd_table.lookup(fd);
    if (!e)
        return g_trampoline.real_pwrite(fd, buf, count, offset);

    if (static_cast<uint64_t>(offset) >= e->file_size)
        return 0;
    uint64_t avail = e->file_size - static_cast<uint64_t>(offset);
    if (count > avail) count = static_cast<size_t>(avail);

    static thread_local uint32_t log_ctr = 0;
    if (__builtin_expect(++log_ctr >= LOG_NTH, 0)) {
        std::fprintf(stderr, "[LD_PRELOAD -> IorRing] WRITE fd:%d | size:%zu | offset:%lld\n",
                     fd, count, static_cast<long long>(offset));
        log_ctr = 0;
    }

    return dp_submit_and_wait(IorEntry::Op::WRITE, fd,
                              const_cast<void*>(buf), count, offset);
}

ssize_t read(int fd, void* buf, size_t count) {
    FakeFdEntry* e = g_fd_table.lookup(fd);
    if (!e)
        return g_trampoline.real_read(fd, buf, count);

    off_t pos = e->file_pos.load(std::memory_order_relaxed);
    ssize_t n = pread(fd, buf, count, pos);
    if (n > 0)
        e->file_pos.fetch_add(n, std::memory_order_relaxed);
    return n;
}

ssize_t write(int fd, const void* buf, size_t count) {
    FakeFdEntry* e = g_fd_table.lookup(fd);
    if (!e)
        return g_trampoline.real_write(fd, buf, count);

    off_t pos = e->file_pos.load(std::memory_order_relaxed);
    ssize_t n = pwrite(fd, buf, count, pos);
    if (n > 0)
        e->file_pos.fetch_add(n, std::memory_order_relaxed);
    return n;
}

} // extern "C"
