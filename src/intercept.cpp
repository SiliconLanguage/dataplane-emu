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
#include "dataplane_emu/telemetry.hpp"

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
// §T  Shared-Memory Telemetry Block (mmap'd by Python control plane)
// =========================================================================

static dataplane_telemetry::TelemetryBlock* g_telemetry = nullptr;

static void dp_init_telemetry() noexcept {
    namespace dt = dataplane_telemetry;
    int fd = ::open(dt::TELEMETRY_SHM_PATH,
                    O_RDWR | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) return;

    // Size the file to exactly one cache line.
    if (::ftruncate(fd, static_cast<off_t>(sizeof(dt::TelemetryBlock))) < 0) {
        ::close(fd);
        return;
    }

    void* addr = ::mmap(nullptr, sizeof(dt::TelemetryBlock),
                        PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    ::close(fd);
    if (addr == MAP_FAILED) return;

    g_telemetry = new (addr) dt::TelemetryBlock{};
    g_telemetry->engine_alive.store(1, std::memory_order_relaxed);
}

static void dp_fini_telemetry() noexcept {
    if (!g_telemetry) return;
    g_telemetry->engine_alive.store(0, std::memory_order_relaxed);
    ::munmap(g_telemetry, sizeof(dataplane_telemetry::TelemetryBlock));
    g_telemetry = nullptr;
}

// =========================================================================
// §5  Per-Thread SqCqEmulator Pool
// =========================================================================

dataplane_emu::SqCqEmulator* EmulatorPool::allocate() noexcept {
    size_t idx = count.fetch_add(1, std::memory_order_acq_rel);
    if (idx >= MAX_EMULATORS) {
        count.fetch_sub(1, std::memory_order_relaxed);
        return nullptr;
    }
    // SqCqEmulator::is_running defaults to true; launch its device loop.
    device_threads[idx] = std::thread([this, idx] {
        emulators[idx].nvme_device_loop();
    });
    return &emulators[idx];
}

void EmulatorPool::shutdown_all() noexcept {
    size_t n = count.load(std::memory_order_acquire);
    for (size_t i = 0; i < n; ++i)
        emulators[i].shutdown();
    for (size_t i = 0; i < n; ++i) {
        if (device_threads[i].joinable())
            device_threads[i].join();
    }
}

/// Thread-local emulator pointer + lazy allocation.
static thread_local dataplane_emu::SqCqEmulator* tl_emulator = nullptr;

dataplane_emu::SqCqEmulator* dp_get_thread_emulator() noexcept {
    if (!tl_emulator)
        tl_emulator = g_emulator_pool.allocate();
    return tl_emulator;
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
    g_trampoline.real_fstat    = reinterpret_cast<fstat_fn_t>(dlsym(RTLD_NEXT, "fstat64"));
    g_trampoline.real_lseek    = reinterpret_cast<lseek_fn_t>(dlsym(RTLD_NEXT, "lseek64"));
    g_trampoline.real_ftruncate = reinterpret_cast<ftruncate_fn_t>(dlsym(RTLD_NEXT, "ftruncate64"));
    g_trampoline.real_memcpy   = reinterpret_cast<memcpy_fn_t>(dlsym(RTLD_NEXT, "memcpy"));
    g_trampoline.real_memmove  = reinterpret_cast<memmove_fn_t>(dlsym(RTLD_NEXT, "memmove"));
    // Emulator threads are started lazily per-thread via dp_get_thread_emulator().

    // Initialise shared-memory telemetry export for the Python control plane.
    dp_init_telemetry();
}

void dp_fini() noexcept {
    // Shutdown all per-thread SqCqEmulator device threads.
    g_emulator_pool.shutdown_all();

    // Release remaining fake FDs.
    for (size_t i = 0; i < FAKE_FD_COUNT; ++i) {
        auto& e = g_fd_table.slots[i].entry;
        if (e.state.load(std::memory_order_relaxed) == FakeFdEntry::State::OPEN)
            e.state.store(FakeFdEntry::State::FREE, std::memory_order_release);
    }

    // Tear down shared-memory telemetry.
    dp_fini_telemetry();
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
// Helper: submit via SqCqEmulator and spin-wait for CQ completion
// =========================================================================

static ssize_t dp_submit_sqcq(bool is_read, void* buf,
                               size_t len, off_t offset) noexcept {
    auto* emu = dp_get_thread_emulator();
    if (!emu) { errno = EAGAIN; return -1; }

    // Translate POSIX offset/length to NVMe-style LBA.
    uint64_t lba = static_cast<uint64_t>(offset) / 4096;

    // Submit SQEntry → device thread processes → poll CQ with acquire.
    emu->host_submit_and_poll(lba);

    // Export latency + counters to the shared telemetry block.
    if (g_telemetry) {
        g_telemetry->last_latency_ticks.store(
            emu->last_latency_ticks.load(std::memory_order_relaxed),
            std::memory_order_relaxed);
        if (is_read)
            g_telemetry->total_read_ops.fetch_add(1, std::memory_order_relaxed);
        else
            g_telemetry->total_write_ops.fetch_add(1, std::memory_order_relaxed);
        g_telemetry->seq.fetch_add(1, std::memory_order_relaxed);
    }

    // Mock data fill post-completion (simulates DMA into user buffer).
    if (is_read)
        std::memset(buf, 'A', len);

    return static_cast<ssize_t>(len);
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
        std::fprintf(stderr, "[LD_PRELOAD -> SqCq] READ  fd:%d | size:%zu | offset:%lld\n",
                     fd, count, static_cast<long long>(offset));
        log_ctr = 0;
    }

    return dp_submit_sqcq(/*is_read=*/true, buf, count, offset);
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
        std::fprintf(stderr, "[LD_PRELOAD -> SqCq] WRITE fd:%d | size:%zu | offset:%lld\n",
                     fd, count, static_cast<long long>(offset));
        log_ctr = 0;
    }

    return dp_submit_sqcq(/*is_read=*/false,
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

// 64-bit aliases for pread/pwrite.
ssize_t pread64(int fd, void* buf, size_t count, off_t offset) {
    return pread(fd, buf, count, offset);
}

ssize_t pwrite64(int fd, const void* buf, size_t count, off_t offset) {
    return pwrite(fd, buf, count, offset);
}

int __fxstat64(int ver, int fd, struct stat64 *buf) {
    (void)ver;
    FakeFdEntry* e = g_fd_table.lookup(fd);
    if (!e) {
        // Fall through to real __fxstat64.
        using fxstat64_fn_t = int (*)(int, int, struct stat64*);
        static auto real_fxstat64 = reinterpret_cast<fxstat64_fn_t>(dlsym(RTLD_NEXT, "__fxstat64"));
        if (real_fxstat64) return real_fxstat64(ver, fd, buf);
        errno = ENOSYS;
        return -1;
    }

    // Synthesize a stat result for the mock file.
    std::memset(buf, 0, sizeof(*buf));
    buf->st_mode  = S_IFREG | 0666;
    buf->st_nlink = 1;
    buf->st_size  = static_cast<off_t>(e->file_size);
    buf->st_blksize = 4096;
    buf->st_blocks  = static_cast<blkcnt_t>(e->file_size / 512);
    return 0;
}

// Both *64 and non-64 variants are exported so LD_PRELOAD intercepts
// binaries compiled with or without _FILE_OFFSET_BITS=64.

int fstat64(int fd, struct stat64 *buf) {
    return __fxstat64(0, fd, buf);
}

int fstat(int fd, struct stat *buf) {
    return __fxstat64(0, fd, reinterpret_cast<struct stat64*>(buf));
}

off_t lseek64(int fd, off_t offset, int whence) {
    FakeFdEntry* e = g_fd_table.lookup(fd);
    if (!e)
        return g_trampoline.real_lseek(fd, offset, whence);

    off_t new_pos;
    switch (whence) {
    case SEEK_SET: new_pos = offset; break;
    case SEEK_CUR: new_pos = e->file_pos.load(std::memory_order_relaxed) + offset; break;
    case SEEK_END: new_pos = static_cast<off_t>(e->file_size) + offset; break;
    default: errno = EINVAL; return -1;
    }
    if (new_pos < 0) { errno = EINVAL; return -1; }
    e->file_pos.store(new_pos, std::memory_order_relaxed);
    return new_pos;
}

off_t lseek(int fd, off_t offset, int whence) {
    return lseek64(fd, offset, whence);
}

int ftruncate64(int fd, off_t length) {
    FakeFdEntry* e = g_fd_table.lookup(fd);
    if (!e)
        return g_trampoline.real_ftruncate(fd, length);
    // No-op for mock — file size stays fixed.
    return 0;
}

int ftruncate(int fd, off_t length) {
    return ftruncate64(fd, length);
}

int fallocate64(int fd, int mode, off_t offset, off_t len) {
    (void)mode; (void)offset; (void)len;
    if (g_fd_table.lookup(fd))
        return 0;  // no-op for mock
    // Fall through to glibc for real FDs.
    errno = ENOSYS;
    return -1;
}

int fallocate(int fd, int mode, off_t offset, off_t len) {
    return fallocate64(fd, mode, offset, len);
}

// open64 alias for binaries compiled with _FILE_OFFSET_BITS=64.
int open64(const char* path, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list ap;
        va_start(ap, flags);
        mode = static_cast<mode_t>(va_arg(ap, int));
        va_end(ap);
    }
    return open(path, flags, mode);
}

// fsync/fdatasync — no-op for fake FDs (in-memory emulation has no durability).
int fsync(int fd) {
    if (g_fd_table.lookup(fd))
        return 0;
    using fsync_fn_t = int (*)(int);
    static auto real_fsync = reinterpret_cast<fsync_fn_t>(dlsym(RTLD_NEXT, "fsync"));
    return real_fsync ? real_fsync(fd) : 0;
}

int fdatasync(int fd) {
    if (g_fd_table.lookup(fd))
        return 0;
    using fdatasync_fn_t = int (*)(int);
    static auto real_fdatasync = reinterpret_cast<fdatasync_fn_t>(dlsym(RTLD_NEXT, "fdatasync"));
    return real_fdatasync ? real_fdatasync(fd) : 0;
}

// posix_fadvise — no-op for fake FDs (prevents fio "cache invalidation" EBADF).
int posix_fadvise(int fd, off_t offset, off_t len, int advice) {
    (void)offset; (void)len; (void)advice;
    if (g_fd_table.lookup(fd))
        return 0;
    using fadvise_fn_t = int (*)(int, off_t, off_t, int);
    static auto real_fadvise = reinterpret_cast<fadvise_fn_t>(dlsym(RTLD_NEXT, "posix_fadvise"));
    return real_fadvise ? real_fadvise(fd, offset, len, advice) : 0;
}

int posix_fadvise64(int fd, off_t offset, off_t len, int advice) {
    return posix_fadvise(fd, offset, len, advice);
}

} // extern "C"
