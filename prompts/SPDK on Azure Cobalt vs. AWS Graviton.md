SPDK (Storage Performance Development Kit) support on ARM-based cloud instances has matured significantly in 2026, though the implementation strategy differs fundamentally between AWS and Azure due to their respective hypervisor architectures.
Here is a summary comparing SPDK support on Azure Cobalt 100 (Neoverse-N2) and AWS Graviton (Neoverse-V2/V3).
1. AWS Graviton (The "Native" Path)
AWS Graviton instances (Graviton 3, 3E, and 4) provide the most straightforward SPDK experience because the AWS Nitro System is designed to support standard Linux hardware passthrough.
Driver Model: Uses standard VFIO-PCI. Because Nitro exposes a vIOMMU (Virtual IOMMU) to the guest, you can "unplug" NVMe devices from the kernel and bind them directly to SPDK without specialized cloud drivers.
Hardware Interaction: SPDK communicates directly with the Nitro card's NVMe controller. This is a "True PCIe Bypass" architecture.
Performance Tuning: * The 3-Queue Rule: Unlike physical SSDs, Nitro NVMe typically requires 2–3 Queue Pairs (QP) per device to reach full hardware saturation.
ISA-L: SPDK’s dependency on ISA-L (Intelligent Storage Acceleration Library) is fully optimized for Graviton's ARM64/Neon instructions, enabling high-speed CRC and encryption.
Best For: Low-latency, high-throughput storage applications that require a standard, upstream SPDK environment.
2. Azure Cobalt 100 (The "Mediated" Path)
Azure Cobalt 100 (v6 series) takes a more specialized approach through Azure Boost, which offloads storage to dedicated FPGAs but imposes stricter limits on guest-side hardware access.
Driver Model: Uses the NetVSC PMD (Poll Mode Driver) or UIO. Standard VFIO is typically not supported because the Cobalt 100 v6 hypervisor does not currently expose IOMMU groups to the guest.
Hardware Interaction: This is a "Mediated" path. You use a hybrid driver where the control plane stays in the kernel (via VMBus), but the data plane is handled in user-space by the NetVSC PMD.
Requirements:
Kernel 6.2+: Required for MANA (Microsoft Azure Network Adapter) and Azure Boost storage compatibility.
DPDK/SPDK Integration: You must build SPDK with specific flags to support the MANA hardware and the NetVSC interface.
Best For: Applications that need to operate within the Azure ecosystem's "Transparent VF" model, providing high performance while maintaining cloud-management features like live migration.
At a Glance Comparison
Feature
AWS Graviton (Nitro)
Azure Cobalt 100 (v6)
Bypass Method
True PCIe Bypass (VFIO)
Mediated User-space (NetVSC)
Guest IOMMU
Available
Not Available (currently)
Core Architecture
Neoverse-V series
Neoverse-N series
SPDK Setup
Standard setup.sh
Custom Build (MANA + NetVSC)
Storage Target
Nitro NVMe / EBS
Azure Boost SSD / Remote Disk
Summary Recommendation
If your goal is to run a vanilla SPDK application with minimal modification, AWS Graviton is the easier platform to target. If you are building for Azure Cobalt 100, you should focus on the NetVSC-mediated architecture, which requires a more modern kernel (6.2+) and a tighter integration with Microsoft's MANA driver stack.