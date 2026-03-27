# SPDK ARM Architecture Divergence in Multi-Cloud Environments

**Abstract**: This research analyzes the **fundamental architectural divergence** between AWS Graviton and Azure Cobalt 100 implementations of the Storage Performance Development Kit (SPDK) in ARM-based cloud infrastructure. The study reveals two distinct compilation and runtime paradigms: **True PCIe Bypass** versus **Mediated User-Space** architectures, each requiring domain-specific optimization strategies.

---

## 1. Executive Summary

SPDK (Storage Performance Development Kit) support on ARM-based cloud instances has **matured significantly in 2026**, though the implementation strategy differs fundamentally between AWS and Azure due to their respective **hypervisor architecture philosophies**. This analysis demonstrates how **hardware passthrough mechanisms** create irreconcilable differences in compilation targets and runtime optimization strategies.

The research establishes two primary architectural patterns:

- **AWS Graviton**: Native PCIe bypass enabling **standard upstream SPDK** compilation
- **Azure Cobalt 100**: Mediated virtualization requiring **domain-specific driver integration**

---

## 2. AWS Graviton: The "Native" Path

### 2.1 Architectural Foundation

AWS Graviton instances (Graviton 3, 3E, and 4) provide the most **straightforward SPDK experience** because the **AWS Nitro System** is designed to support standard Linux hardware passthrough mechanisms.

### 2.2 Driver Model Characteristics

**Driver Architecture**: Uses standard **VFIO-PCI** implementation. The AWS Nitro System exposes a **vIOMMU (Virtual IOMMU)** to the guest, enabling direct device "unplugging" from the kernel and binding directly to SPDK **without specialized cloud drivers**.

**Hardware Interaction**: SPDK communicates directly with the **Nitro card's NVMe controller** through a **"True PCIe Bypass" architecture**. This approach maintains full compatibility with upstream SPDK compilation targets.

### 2.3 Performance Optimization Framework

#### 2.3.1 The 3-Queue Rule
Unlike physical SSDs, **Nitro NVMe** typically requires **2–3 Queue Pairs (QP) per device** to reach full hardware saturation. This architectural constraint stems from the virtualized nature of Nitro's PCIe presentation layer.

#### 2.3.2 ISA-L Integration
SPDK's dependency on **ISA-L (Intelligent Storage Acceleration Library)** is **fully optimized for Graviton's ARM64/Neon instructions**, enabling high-speed CRC and encryption operations without compilation modifications.

**Optimal Use Cases**: Low-latency, high-throughput storage applications requiring a **standard, upstream SPDK environment** with minimal architectural modifications.

---

## 3. Azure Cobalt 100: The "Mediated" Path

### 3.1 Architectural Philosophy

Azure Cobalt 100 (v6 series) implements a **specialized approach through Azure Boost**, which offloads storage operations to dedicated FPGAs while imposing **stricter limits on guest-side hardware access**.

### 3.2 Driver Model Architecture

**Driver Implementation**: Utilizes **NetVSC PMD (Poll Mode Driver)** or **UIO** frameworks. Standard VFIO is **typically not supported** because the Cobalt 100 v6 hypervisor does not currently expose **IOMMU groups** to the guest environment.

**Hardware Interaction Pattern**: Implements a **"Mediated" path** utilizing hybrid driver architecture where:
- **Control plane** remains in kernel space (via VMBus)
- **Data plane** operations are handled in user-space by the NetVSC PMD

### 3.3 Compilation Requirements

#### 3.3.1 Kernel Dependencies
- **Minimum Requirement**: Kernel 6.2+ for **MANA (Microsoft Azure Network Adapter)** and Azure Boost storage compatibility
- **DPDK/SPDK Integration**: Requires SPDK compilation with **specific flags** to support MANA hardware and NetVSC interface

#### 3.3.2 Build Configuration
Custom compilation process requiring **domain-specific driver integration** rather than standard SPDK setup procedures.

**Optimal Use Cases**: Applications operating within the Azure ecosystem's **"Transparent VF" model**, providing high performance while maintaining **cloud-management features** like live migration.

---

## 4. Comparative Analysis Framework

| **Architectural Dimension** | **AWS Graviton (Nitro)** | **Azure Cobalt 100 (v6)** |
|---------------------------|-------------------------|---------------------------|
| **Bypass Method** | True PCIe Bypass (VFIO) | Mediated User-space (NetVSC) |
| **Guest IOMMU** | Available | Not Available (currently) |
| **Core Architecture** | Neoverse-V series | Neoverse-N series |
| **SPDK Setup** | Standard setup.sh | Custom Build (MANA + NetVSC) |
| **Storage Target** | Nitro NVMe / EBS | Azure Boost SSD / Remote Disk |
| **Compilation Complexity** | Upstream Compatible | Domain-Specific Required |

---

## 5. Strategic Recommendations

### 5.1 AWS Graviton Deployment Strategy
For **vanilla SPDK applications** with minimal modification requirements, **AWS Graviton represents the easier platform** to target due to its **upstream compatibility** and standard PCIe bypass mechanisms.

### 5.2 Azure Cobalt 100 Deployment Strategy
Azure Cobalt 100 deployments should focus on the **NetVSC-mediated architecture**, requiring:
- **Modern kernel** (6.2+) baseline
- **Tighter integration** with Microsoft's MANA driver stack
- **Custom compilation workflows** for domain-specific optimization

### 5.3 Multi-Cloud Considerations
Organizations targeting **both platforms** must maintain **dual compilation pipelines** due to irreconcilable differences in hypervisor architecture and hardware abstraction layers.

---

## 6. Future Research Directions

1. **Performance Benchmarking**: Quantitative analysis of throughput and latency differences between True PCIe Bypass and Mediated architectures
2. **Compilation Automation**: Development of automated toolchains for managing dual-target SPDK builds
3. **Migration Strategies**: Investigation of workload portability patterns between architectural paradigms

---

## 7. Conclusion

The **fundamental architectural divergence** between AWS Nitro and Azure Boost creates **irreconcilable differences** in SPDK implementation strategies. This research establishes the need for **domain-specific compilation approaches** rather than unified cross-cloud deployment methodologies. Organizations must architect their SPDK implementations with **platform-specific optimization** as a primary design constraint rather than an afterthought.

**Key Insight**: The maturation of ARM-based cloud infrastructure has not converged toward standardization, but rather has **crystallized into distinct architectural philosophies** that require fundamentally different technical approaches for optimal performance.