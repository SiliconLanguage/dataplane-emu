// Quick integration test for libdataplane_intercept.so
// Build: g++ -std=c++20 -o build/intercept_test tests/intercept_test.cpp
// Run:   env LD_PRELOAD=./build/libdataplane_intercept.so ./build/intercept_test

#include <fcntl.h>
#include <unistd.h>
#include <cstdio>
#include <cstring>
#include <cerrno>
#include <chrono>

static constexpr size_t BUF_SIZE = 4096;
static constexpr int    NUM_OPS  = 100000;

int main() {
    // 1. Open a file under the dataplane mount prefix.
    int fd = open("/mnt/dataplane/test_file", O_RDWR | O_CREAT, 0644);
    if (fd < 0) {
        std::fprintf(stderr, "open failed: %s (errno=%d)\n", strerror(errno), errno);
        return 1;
    }
    std::fprintf(stdout, "[TEST] open returned fd=%d (expect >= 1000000)\n", fd);

    if (fd < 1000000) {
        std::fprintf(stderr, "[FAIL] fd is not a fake FD — interception not active!\n");
        close(fd);
        return 1;
    }

    // 2. pwrite test
    char wbuf[BUF_SIZE];
    std::memset(wbuf, 'W', BUF_SIZE);
    ssize_t nw = pwrite(fd, wbuf, BUF_SIZE, 0);
    std::fprintf(stdout, "[TEST] pwrite returned %zd (expect %zu)\n", nw, BUF_SIZE);
    if (nw != static_cast<ssize_t>(BUF_SIZE)) {
        std::fprintf(stderr, "[FAIL] pwrite: %s\n", strerror(errno));
        close(fd);
        return 1;
    }

    // 3. pread test — engine fills buffer with 'A'
    char rbuf[BUF_SIZE];
    std::memset(rbuf, 0, BUF_SIZE);
    ssize_t nr = pread(fd, rbuf, BUF_SIZE, 0);
    std::fprintf(stdout, "[TEST] pread returned %zd (expect %zu)\n", nr, BUF_SIZE);
    if (nr != static_cast<ssize_t>(BUF_SIZE)) {
        std::fprintf(stderr, "[FAIL] pread: %s\n", strerror(errno));
        close(fd);
        return 1;
    }
    if (rbuf[0] != 'A' || rbuf[BUF_SIZE - 1] != 'A') {
        std::fprintf(stderr, "[FAIL] pread data mismatch: got '%c'/'%c', expected 'A'/'A'\n",
                     rbuf[0], rbuf[BUF_SIZE - 1]);
        close(fd);
        return 1;
    }
    std::fprintf(stdout, "[TEST] pread data verified: buf[0]='%c', buf[end]='%c'\n",
                 rbuf[0], rbuf[BUF_SIZE - 1]);

    // 4. Throughput benchmark: 100K pread operations
    auto t0 = std::chrono::steady_clock::now();
    for (int i = 0; i < NUM_OPS; ++i) {
        off_t off = static_cast<off_t>((static_cast<unsigned>(i) * 4096ULL) % (1024ULL * 1024 * 1024));
        pread(fd, rbuf, BUF_SIZE, off);
    }
    auto t1 = std::chrono::steady_clock::now();
    double elapsed_ms = std::chrono::duration<double, std::milli>(t1 - t0).count();
    double iops = NUM_OPS / (elapsed_ms / 1000.0);
    std::fprintf(stdout, "[TEST] %d x 4KB pread: %.1f ms => %.0f IOPS\n",
                 NUM_OPS, elapsed_ms, iops);

    // 5. Close
    int rc = close(fd);
    std::fprintf(stdout, "[TEST] close returned %d\n", rc);

    std::fprintf(stdout, "\n[PASS] All interception tests passed.\n");
    return 0;
}
