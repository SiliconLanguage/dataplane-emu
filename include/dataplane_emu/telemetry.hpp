#pragma once
// ============================================================================
// include/dataplane_emu/telemetry.hpp
// Shared-Memory Telemetry Export — mmap'd by Python control plane
// ============================================================================
//
// Layout: a single 64-byte-aligned struct written by the C++ data plane
// and read by the Python UI via mmap(MAP_SHARED) on a well-known path.
//
// Contract:
//   - Writer: the LD_PRELOAD library (intercept.cpp) after each sampled I/O
//   - Reader: Python TelemetrySink via struct.unpack on the mmap'd region
//   - Coherence: relaxed atomics — Python reads are advisory, not synchronised
//
// File path: /tmp/dataplane_telemetry.bin  (created by dp_lib_init)

#include <cstdint>
#include <atomic>
#include <new>

namespace dataplane_telemetry {

inline constexpr size_t CACHE_LINE = 64;

/// Path to the mmap'd telemetry file — shared between C++ writer and Python reader.
inline constexpr const char* TELEMETRY_SHM_PATH = "/tmp/dataplane_telemetry.bin";

/// Fixed binary layout exported to Python.  Total size = 64 bytes (one cache line).
/// All fields are updated with relaxed stores; Python reads are best-effort.
///
/// Python struct format string: "<QQQQQBxxx" (little-endian, 41 bytes packed)
/// — but we pad to 64 bytes for alignment.
struct alignas(CACHE_LINE) TelemetryBlock {
    // Monotonic sequence number — incremented on every sampled update.
    // Python detects stale data by comparing consecutive reads.
    std::atomic<uint64_t> seq{0};

    // Cumulative I/O counters (updated on every sampled log).
    std::atomic<uint64_t> total_read_ops{0};
    std::atomic<uint64_t> total_write_ops{0};

    // Last observed SQ→CQ round-trip latency in hardware timer ticks.
    // On ARM64 Neoverse (CNTFRQ ≈ 1 GHz), 1 tick ≈ 1 ns.
    // On x86 (TSC ≈ 2–3 GHz), divide by TSC frequency for ns.
    std::atomic<uint64_t> last_latency_ticks{0};

    // Cumulative bytes that were copy-elided (userfaultfd zero-copy wins).
    std::atomic<uint64_t> elided_bytes{0};

    // 1 if the engine is healthy and servicing I/O, 0 otherwise.
    std::atomic<uint8_t>  engine_alive{0};

    // Padding to fill the cache line.
    uint8_t _pad[64 - 5 * sizeof(uint64_t) - sizeof(uint8_t)]{};
};

static_assert(sizeof(TelemetryBlock) == CACHE_LINE,
              "TelemetryBlock must fit in exactly one cache line");
static_assert(alignof(TelemetryBlock) == CACHE_LINE,
              "TelemetryBlock must be cache-line aligned");

} // namespace dataplane_telemetry
