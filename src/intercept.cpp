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
#include <sys/mman.h>
#include <sys/syscall.h>

namespace dataplane_intercept {

// =========================================================================
// §5  Library Lifecycle
// =========================================================================

void dp_init_trampolines() noexcept {
    g_trampoline.real_open     = reinterpret_cast<open_fn_t>(dlsym(RTLD_NEXT, "open"));
    g_trampoline.real_close    = reinterpret_cast<close_fn_t>(dlsym(RTLD_NEXT, "close"));
    g_trampoline.real_pread    = reinterpret_cast<pread_fn_t>(dlsym(RTLD_NEXT, "pread"));
    g_trampoline.real_pwrite   = reinterpret_cast<pwrite_fn_t>(dlsym(RTLD_NEXT, "pwrite"));
    g_trampoline.real_read     = reinterpret_cast<read_fn_t>(dlsym(RTLD_NEXT, "read"));
    g_trampoline.real_write    = reinterpret_cast<write_fn_t>(dlsym(RTLD_NEXT, "write"));
    g_trampoline.real_memcpy   = reinterpret_cast<memcpy_fn_t>(dlsym(RTLD_NEXT, "memcpy"));
    g_trampoline.real_memmove  = reinterpret_cast<memmove_fn_t>(dlsym(RTLD_NEXT, "memmove"));
}

void dp_fini() noexcept {
    // Release any remaining open fake FDs.
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
    // Register destination range for fault interception.
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

    // Perform the lazy copy for this page.
    auto src_page = reinterpret_cast<const char*>(e->src) + page_offset;
    auto dst_page = reinterpret_cast<char*>(e->dst) + page_offset;

    // Use UFFDIO_COPY to resolve the fault.
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

int open(const char* path, int flags, ...) {
    // Extract optional mode argument.
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list ap;
        va_start(ap, flags);
        mode = static_cast<mode_t>(va_arg(ap, int));
        va_end(ap);
    }

    if (!dp_is_dataplane_path(path))
        return g_trampoline.real_open(path, flags, mode);

    // TODO: submit engine open command via IorRing, receive engine_handle.
    // For now, fall through to libc to allow incremental bring-up.
    return g_trampoline.real_open(path, flags, mode);
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

    // TODO: submit IorEntry to per-thread IorRing, spin on entry.ready.
    // Placeholder: return error until engine integration is wired.
    errno = ENOSYS;
    return -1;
}

ssize_t pwrite(int fd, const void* buf, size_t count, off_t offset) {
    FakeFdEntry* e = g_fd_table.lookup(fd);
    if (!e)
        return g_trampoline.real_pwrite(fd, buf, count, offset);

    // TODO: submit IorEntry to per-thread IorRing, spin on entry.ready.
    errno = ENOSYS;
    return -1;
}

ssize_t read(int fd, void* buf, size_t count) {
    if (!g_fd_table.lookup(fd))
        return g_trampoline.real_read(fd, buf, count);

    // TODO: track file position per fake FD and delegate to pread path.
    errno = ENOSYS;
    return -1;
}

ssize_t write(int fd, const void* buf, size_t count) {
    if (!g_fd_table.lookup(fd))
        return g_trampoline.real_write(fd, buf, count);

    // TODO: track file position per fake FD and delegate to pwrite path.
    errno = ENOSYS;
    return -1;
}

} // extern "C"
