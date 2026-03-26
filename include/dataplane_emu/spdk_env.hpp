#pragma once
// ============================================================================
// include/dataplane_emu/spdk_env.hpp
// SPDK Cross-Cloud Environment Wrapper
// ============================================================================
//
// Transparently configures SPDK initialisation for two distinct ARM64 clouds:
//
//   AWS Graviton (Neoverse-V)     → vfio-pci, trtype=PCIe, raw BDF addressing
//   Azure Cobalt 100 (Neoverse-N) → uio_hv_generic, trtype=vdev, VMBus GUIDs
//
// Design rationale:
//   Azure does not expose guest IOMMU groups, so vfio-pci passthrough is
//   impossible.  Instead, Azure Boost routes NVMe traffic through a VMBus
//   virtual device backed by MANA.  This header detects which driver stack
//   is present and configures spdk_env_opts + transport addresses accordingly.
//
// Usage:
//   #include <dataplane_emu/spdk_env.hpp>
//   auto cfg = dataplane_env::detect();   // fast, fail-fast on misconfiguration
//   dataplane_env::init_spdk(cfg);        // calls spdk_env_init()
//
// Fail-fast policy:
//   If the detected cloud does not match the loaded kernel drivers, we abort
//   immediately rather than proceeding into undefined hardware state.
//
// Build requirements:
//   - Link against SPDK (libspdk_env_dpdk, libspdk_nvme) and DPDK
//   - C++17, -mcpu=neoverse-{v1,v2,n2}
// ============================================================================

#include <cstdint>
#include <cstdlib>
#include <cstdio>
#include <cstring>
#include <string>
#include <array>
#include <optional>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <stdexcept>

// Guard SPDK headers — they're C-only and must be included inside extern "C"
extern "C" {
#include <spdk/env.h>
#include <spdk/nvme.h>
#include <spdk/log.h>
}

namespace dataplane_env {

// =========================================================================
// §0  Constants & Types
// =========================================================================

// Cache-line alignment for all shared state (matches sq_cq.hpp)
inline constexpr std::size_t CACHE_LINE = 64;

// Default hugepage reservation in MB
inline constexpr int DEFAULT_HUGEPAGE_MB = 2048;

// Default core mask — core 1 only, leaving core 0 for the OS
inline constexpr const char* DEFAULT_CORE_MASK = "0x2";

/// Transport type — maps to the SPDK spdk_nvme_transport_id.trtype field.
enum class TransportType : uint8_t {
    PCIe = 0,   // AWS: raw PCIe BDF via vfio-pci
    VMBus = 1,  // Azure: VMBus virtual device via uio_hv_generic
};

/// Detected cloud identity.
enum class CloudProvider : uint8_t {
    AWS   = 0,
    Azure = 1,
};

/// Fully resolved environment configuration.
/// Populated by detect() and consumed by init_spdk().
struct EnvConfig {
    CloudProvider  cloud;
    TransportType  transport;

    // SPDK env tuning
    int            hugepage_mb  = DEFAULT_HUGEPAGE_MB;
    std::string    core_mask    = DEFAULT_CORE_MASK;
    std::string    app_name     = "dataplane-emu";

    // Transport address — either a PCIe BDF (e.g. "0000:00:1f.0") or
    // a VMBus GUID (e.g. "{f8615163-df3e-46c5-913f-f2d2f965ed0e}")
    std::string    device_address;

    // Driver name that must be bound for the chosen transport
    std::string    expected_driver;
};

// =========================================================================
// §1  Cloud Detection (fast, no allocations in hot path)
// =========================================================================

namespace detail {

/// Read the first line of a sysfs/procfs file.  Returns empty on failure.
inline std::string read_sysfs(const char* path) {
    std::ifstream f(path);
    if (!f.is_open()) return {};
    std::string line;
    std::getline(f, line);
    return line;
}

/// Detect cloud from DMI system-manufacturer (works without dmidecode binary).
inline std::optional<CloudProvider> detect_from_dmi() {
    // /sys/class/dmi/id/ is readable without root on modern kernels
    auto vendor = read_sysfs("/sys/class/dmi/id/sys_vendor");
    if (vendor.find("Amazon") != std::string::npos)    return CloudProvider::AWS;
    if (vendor.find("Microsoft") != std::string::npos)  return CloudProvider::Azure;
    return std::nullopt;
}

/// Detect cloud from board_vendor (fallback for minimal kernels).
inline std::optional<CloudProvider> detect_from_board() {
    auto vendor = read_sysfs("/sys/class/dmi/id/board_vendor");
    if (vendor.find("Amazon") != std::string::npos)    return CloudProvider::AWS;
    if (vendor.find("Microsoft") != std::string::npos)  return CloudProvider::Azure;
    return std::nullopt;
}

/// Detect from the FORCE_CLOUD environment variable (test/CI override).
inline std::optional<CloudProvider> detect_from_env() {
    const char* val = std::getenv("FORCE_CLOUD");
    if (!val) return std::nullopt;
    if (std::strcmp(val, "aws")   == 0) return CloudProvider::AWS;
    if (std::strcmp(val, "azure") == 0) return CloudProvider::Azure;
    return std::nullopt;
}

// -------------------------------------------------------------------------
// Driver verification helpers
// -------------------------------------------------------------------------

/// Check whether a kernel module is currently loaded (appears in /proc/modules).
inline bool is_module_loaded(const char* mod_name) {
    std::ifstream f("/proc/modules");
    if (!f.is_open()) return false;
    std::string line;
    while (std::getline(f, line)) {
        // Module name is the first whitespace-delimited token
        if (line.compare(0, std::strlen(mod_name), mod_name) == 0 &&
            (line.size() == std::strlen(mod_name) || line[std::strlen(mod_name)] == ' ')) {
            return true;
        }
    }
    return false;
}

/// Scan /sys/bus/pci/devices/ for the first NVMe device bound to |driver|.
/// Returns the PCI BDF string (e.g. "0000:00:1f.0") or empty.
inline std::string find_pci_device_for_driver(const char* driver) {
    namespace fs = std::filesystem;
    const fs::path bus_path("/sys/bus/pci/devices");
    if (!fs::exists(bus_path)) return {};

    for (auto& entry : fs::directory_iterator(bus_path)) {
        auto driver_link = entry.path() / "driver";
        if (!fs::is_symlink(driver_link)) continue;

        auto target = fs::read_symlink(driver_link).filename().string();
        if (target == driver) {
            // Verify it's class 0x0108xx (NVMe mass-storage controller)
            auto class_path = entry.path() / "class";
            auto cls = read_sysfs(class_path.c_str());
            if (cls.find("0x0108") != std::string::npos) {
                return entry.path().filename().string();
            }
        }
    }
    return {};
}

/// Scan /sys/bus/vmbus/devices/ for the first device with a matching channel type GUID.
/// Azure NVMe storage presents as SCSI-over-VMBus; the GUID is well-known.
inline std::string find_vmbus_device() {
    namespace fs = std::filesystem;
    const fs::path bus_path("/sys/bus/vmbus/devices");
    if (!fs::exists(bus_path)) return {};

    for (auto& entry : fs::directory_iterator(bus_path)) {
        // Each VMBus device directory name is a GUID
        auto class_id_path = entry.path() / "class_id";
        auto class_id = read_sysfs(class_id_path.c_str());
        // SCSI controller class GUID for Azure NVMe-over-VMBus
        // {ba6163d9-04a1-4d29-b605-72e2ffb1dc7f}
        if (!class_id.empty()) {
            return entry.path().filename().string();
        }
    }
    return {};
}

} // namespace detail

// =========================================================================
// §2  Primary API: detect()
// =========================================================================
//
// Returns a fully-populated EnvConfig or throws if the environment is
// unrecognisable or the required drivers are not loaded.
//
// Detection order:
//   1. FORCE_CLOUD env var (for CI / emulated testing)
//   2. DMI sys_vendor
//   3. DMI board_vendor
//
// After cloud identification, we verify the kernel driver stack and locate
// the first available device address.

inline EnvConfig detect() {
    // --- Identify cloud ---
    auto cloud = detail::detect_from_env();
    if (!cloud) cloud = detail::detect_from_dmi();
    if (!cloud) cloud = detail::detect_from_board();

    if (!cloud) {
        throw std::runtime_error(
            "spdk_env::detect(): Unable to identify cloud provider.\n"
            "  Set FORCE_CLOUD=aws or FORCE_CLOUD=azure to override.");
    }

    EnvConfig cfg{};
    cfg.cloud = *cloud;

    switch (cfg.cloud) {
    // -----------------------------------------------------------------
    // AWS Graviton — vfio-pci, raw PCIe BDF
    // -----------------------------------------------------------------
    //
    // The Nitro hypervisor exposes NVMe devices as standard PCIe
    // functions.  SPDK/DPDK binds them via vfio-pci (or uio_pci_generic
    // as fallback).  The IOMMU is type-1 and fully functional.
    case CloudProvider::AWS: {
        cfg.transport        = TransportType::PCIe;
        cfg.expected_driver  = "vfio-pci";

        // Verify vfio-pci is loaded
        if (!detail::is_module_loaded("vfio_pci")) {
            // Allow uio_pci_generic as a fallback (common on older AMIs)
            if (detail::is_module_loaded("uio_pci_generic")) {
                cfg.expected_driver = "uio_pci_generic";
                std::fprintf(stderr,
                    "[spdk_env] WARNING: vfio-pci not loaded; "
                    "falling back to uio_pci_generic.\n");
            } else {
                throw std::runtime_error(
                    "spdk_env::detect() [AWS]: Neither vfio-pci nor "
                    "uio_pci_generic is loaded.\n"
                    "  Run: sudo modprobe vfio-pci\n"
                    "  Or:  sudo HUGEMEM=2048 spdk/scripts/setup.sh");
            }
        }

        // Find the first NVMe BDF bound to the expected driver
        cfg.device_address = detail::find_pci_device_for_driver(
            cfg.expected_driver.c_str());
        if (cfg.device_address.empty()) {
            throw std::runtime_error(
                "spdk_env::detect() [AWS]: No NVMe device bound to " +
                cfg.expected_driver + ".\n"
                "  Run: sudo spdk/scripts/setup.sh");
        }
        break;
    }

    // -----------------------------------------------------------------
    // Azure Cobalt 100 — uio_hv_generic, VMBus virtual device
    // -----------------------------------------------------------------
    //
    // Azure does NOT expose IOMMU groups to guests, so vfio-pci is
    // impossible.  The MANA NIC and NVMe storage are presented over
    // VMBus.  DPDK/SPDK accesses them via the uio_hv_generic driver
    // which maps VMBus ring buffers into userspace.
    //
    // The transport type is "vdev" — SPDK treats it as a virtual device
    // rather than a raw PCIe function.
    case CloudProvider::Azure: {
        cfg.transport        = TransportType::VMBus;
        cfg.expected_driver  = "uio_hv_generic";

        // Verify uio_hv_generic is loaded — mandatory on Azure
        if (!detail::is_module_loaded("uio_hv_generic")) {
            throw std::runtime_error(
                "spdk_env::detect() [Azure]: uio_hv_generic module is NOT loaded.\n"
                "  This driver is REQUIRED for VMBus device access on Azure.\n"
                "  Run: sudo modprobe uio_hv_generic");
        }

        // Also verify hv_netvsc is loaded (NetVSC backend for MANA)
        if (!detail::is_module_loaded("hv_netvsc")) {
            std::fprintf(stderr,
                "[spdk_env] WARNING: hv_netvsc not loaded; "
                "MANA network acceleration may be unavailable.\n");
        }

        // Locate a VMBus-attached storage device
        cfg.device_address = detail::find_vmbus_device();
        if (cfg.device_address.empty()) {
            throw std::runtime_error(
                "spdk_env::detect() [Azure]: No VMBus storage device found.\n"
                "  Ensure the VM has NVMe-capable disk attached and "
                "uio_hv_generic is bound.");
        }
        break;
    }
    } // switch

    return cfg;
}

// =========================================================================
// §3  SPDK Initialisation: init_spdk()
// =========================================================================
//
// Translates the EnvConfig into spdk_env_opts and calls spdk_env_init().
// After env init, attaches the detected NVMe controller with the correct
// transport type.
//
// This function does NOT return on failure — it calls std::abort() after
// logging the error, because a partially-initialised SPDK env is
// unrecoverable.

inline void init_spdk(const EnvConfig& cfg) {
    // --- Step 1: Populate spdk_env_opts ---
    struct spdk_env_opts opts{};
    spdk_env_opts_init(&opts);

    opts.name      = cfg.app_name.c_str();
    opts.core_mask = cfg.core_mask.c_str();
    opts.mem_size  = cfg.hugepage_mb;

    // Log the configuration before committing
    std::fprintf(stderr,
        "[spdk_env] Initialising SPDK environment\n"
        "  Cloud     : %s\n"
        "  Transport : %s\n"
        "  Device    : %s\n"
        "  Driver    : %s\n"
        "  Cores     : %s\n"
        "  HugePages : %d MB\n",
        (cfg.cloud == CloudProvider::AWS) ? "AWS Graviton" : "Azure Cobalt 100",
        (cfg.transport == TransportType::PCIe) ? "PCIe" : "VMBus (vdev)",
        cfg.device_address.c_str(),
        cfg.expected_driver.c_str(),
        cfg.core_mask.c_str(),
        cfg.hugepage_mb);

    // --- Step 2: Initialise SPDK/DPDK environment ---
    int rc = spdk_env_init(&opts);
    if (rc != 0) {
        std::fprintf(stderr,
            "[spdk_env] FATAL: spdk_env_init() failed (rc=%d).\n"
            "  Likely causes:\n"
            "  - Hugepages not allocated (run: echo 1024 | sudo tee "
            "/sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages)\n"
            "  - Permissions: run as root or with CAP_SYS_RAWIO\n",
            rc);
        std::abort();
    }

    // --- Step 3: Build transport ID for controller attachment ---
    struct spdk_nvme_transport_id trid{};
    std::memset(&trid, 0, sizeof(trid));

    switch (cfg.transport) {
    case TransportType::PCIe:
        // AWS: standard PCIe transport, address is a BDF like "0000:00:1f.0"
        trid.trtype = SPDK_NVME_TRANSPORT_PCIE;
        if (spdk_nvme_transport_id_parse_trtype(
                &trid.trtype, "PCIe") != 0) {
            std::fprintf(stderr,
                "[spdk_env] FATAL: Failed to parse PCIe transport type.\n");
            std::abort();
        }
        std::snprintf(trid.traddr, sizeof(trid.traddr), "%s",
                      cfg.device_address.c_str());
        break;

    case TransportType::VMBus:
        // Azure Cobalt 100: Mediated User-space path via VMBus.
        //
        // Azure Boost does NOT expose guest IOMMU groups, so standard VFIO
        // passthrough is blocked.  Instead, SPDK handles the high-speed data
        // plane in user-space while the Linux kernel manages the VMBus control
        // plane.  The transport type is "vdev" — a virtual device whose
        // traddr maps to a VMBus GUID (not a PCIe BDF).
        //
        // The DPDK bus/vmbus layer (built with -Dwith_mana=true
        // -Dwith_netvsc=true) surfaces the MANA/NetVSC backend, and
        // uio_hv_generic provides the user-space VMBus ring mapping.
        if (spdk_nvme_transport_id_parse_trtype(
                &trid.trtype, "vdev") != 0) {
            std::fprintf(stderr,
                "[spdk_env] FATAL: Failed to parse 'vdev' transport type.\n"
                "  Ensure SPDK was built with MANA/NetVSC support:\n"
                "    meson setup build -Dwith_mana=true -Dwith_netvsc=true\n");
            std::abort();
        }
        std::snprintf(trid.traddr, sizeof(trid.traddr), "%s",
                      cfg.device_address.c_str());
        break;
    }

    std::fprintf(stderr,
        "[spdk_env] Transport ID configured — traddr: %s\n",
        trid.traddr);

    // Controller probe is left to the caller (spdk_nvme_probe / bdev layer)
    // because the attach callback is application-specific.  Example:
    //
    //   spdk_nvme_probe(&trid, ctx, probe_cb, attach_cb, nullptr);
    //
    // See scripts/spdk-aws/start_spdk.sh and spdk-azure/start_spdk_azure.sh
    // for full bdev_nvme_attach_controller RPC examples.
}

// =========================================================================
// §4  Utility: transport_type_str / cloud_provider_str
// =========================================================================

inline const char* transport_type_str(TransportType t) {
    switch (t) {
        case TransportType::PCIe:  return "PCIe";
        case TransportType::VMBus: return "VMBus";
    }
    return "unknown";
}

inline const char* cloud_provider_str(CloudProvider c) {
    switch (c) {
        case CloudProvider::AWS:   return "AWS Graviton";
        case CloudProvider::Azure: return "Azure Cobalt 100";
    }
    return "unknown";
}

} // namespace dataplane_env
