# The Convergence of Domain-Specific Compilation

**Bridging LLM Siliconization and Infrastructure Hardware Offloading**

**Author:** Ping Long, Principal Systems Architect, Lead Researcher, SiliconLanguage Foundry

*Contact: [LinkedIn](https://www.linkedin.com/in/pinglong) | [GitHub](https://github.com/ping-long-github) | plongpingl@gmail.com*

---

## Abstract

The landscape of computer architecture is currently witnessing a tectonic shift as general-purpose processing reaches the limits of Dennard scaling and the "memory wall." This has necessitated the rise of Domain-Specific Architectures (DSAs), which are now bifurcating into two highly specialized yet technologically convergent fields: the siliconization of Large Language Models (LLMs) and the hardware hardening of infrastructure functions on SmartNICs and Data Processing Units (DPUs). The critical commonality between these domains is not just the specialization of the silicon, but the radical transformation of the compiler from a mere code translator into a spatial-temporal architect of hardware execution. This report investigates the compiler technologies, toolchains, and methodologies driving this evolution, providing a rigorous comparison of "Software-becomes-Silicon" paradigms in AI and networking.

---

## Keywords

Domain-Specific Compilation; Domain-Specific Accelerators (DSAs); Inference Accelerators; HPC Compilers; Speed-of-Light Execution; Tensor Compiler Backends; AST-to-RTL Synthesis; P4 Compilers; eBPF Offload; High-Level Synthesis (HLS); Heterogeneous Toolchains; Spatial Scheduling; Compiler Runtime Co-Design; SmartNIC; DPU; Arithmetic Intensity; Zero-Copy Data Planes; Deterministic Execution; Hardware-Software Co-Design.

---

## Architectural Frameworks for LLM Siliconization

LLM Siliconization represents the culmination of the "Software-Defined Hardware" movement, where the mathematical structure of a neural network, specifically the Transformer architecture, is used as the blueprint for physical silicon. This paradigm moves away from the traditional model where weights are data to be processed, and instead treats the model as an immutable or highly deterministic hardware configuration.

### Deterministic Orchestration and the Static Scheduling Paradigm

In conventional computing, the compiler produces a set of instructions that the hardware interprets at runtime, often using dynamic schedulers, branch predictors, and reorder buffers to manage execution flow. However, in the context of LLM inference, where the computational graph is largely static and the goal is to minimize latency jitter, a new class of deterministic orchestration compilers has emerged.

The Groq compiler is a primary example of this shift. It was developed with a "software-first" DNA, prioritizing the compiler’s ability to orchestrate every operation before the hardware was even finalized. [1, 2] The Groq LPU (Language Processing Unit) is intentionally designed without the traditional overhead of hardware-level resource management. It lacks branch predictors and cache controllers, essentially acting as a massive array of arithmetic units and memory banks that follow a cycle-accurate schedule dictated entirely by the compiler. [3, 4]

This compiler methodology is described as solving a multi-dimensional "Tetris" problem. It maps the data flow across the physical geometry of the chip, calculating the exact execution time of every operation. For example, the compiler knows that a specific matrix multiplication will take exactly 400 clock cycles and that at Cycle 1,000,050, a packet of data must be at coordinate (X,Y) on the chip to be consumed by an arithmetic unit. [4] This spatial orchestration ensures zero variance in execution time, providing "Deterministic Execution" where a task’s runtime is fixed down to the nanosecond. [1, 4]

Similarly, the Etched Sohu chip employs an architecture meticulously engineered to maximize the throughput of Transformer models. It achieves processing speeds exceeding 500,000 tokens per second for models like Llama 70B. [5] The compiler for such architectures must handle "plesiosynchronous" systems (synchronized to a shared clock reference with bounded, known drift), where the compiler accounts for slight, known drifts to manage multi-chip communication as a single, coherent memory space without external switches. [4]

### AST-to-RTL Translators and the "Hardcore" Model

A more radical approach to siliconization involves the direct translation of high-level software abstractions, such as the Abstract Syntax Tree (AST) of a neural network, into physical hardware descriptions (RTL). This is the "Model-as-Silicon" paradigm, where the software effectively becomes the silicon topology.

Companies like Taalas Foundry are at the forefront of this methodology. Instead of compiling code for a programmable pipeline, their tools translate the AST of a model directly into Register-Transfer Level (RTL) netlists. [6, 7] This process creates a custom hardware accelerator where the data paths are physically optimized for the specific tensor operations and connectivity of the target neural network. This methodology eliminates the overhead of instruction fetching and decoding entirely, as the "instructions" are essentially the fixed wiring and logic gates of the ASIC.

### The Immutable Tensor Architecture and Metal-Layer Encoding

The most extreme form of LLM Siliconization is found in the Immutable Tensor Architecture (ITA). This paradigm shift treats model weights not as data stored in SRAM or DRAM, but as physical circuit topology encoded into the metal interconnects of the chip. [8, 9]

The ITA compiler performs "Logic-Aware Quantization," where generic multipliers are replaced with constant-coefficient shift-add trees optimized during synthesis. [8] For instance, a generic multiplier might require 250 gates, but a hardwired shift-add for a specific weight could require only 16 gates. [8] This leads to a profound reduction in area and power. The mathematical transformation used by the compiler to replace multiplication by a constant can be represented as:

$$
y = w \cdot x \approx \sum_{i \in S} (x \ll i)
$$

where $S$ is a set of shifts determined by the binary representation of the weight $w$. By utilizing mature semiconductor processes like 28nm or 40nm, ITA can manufacture "Neural Cartridges" that are 50–100x more energy-efficient than traditional GPUs for inference. [8, 9] The compiler’s role here is to act as a physical architect, deciding which weights are etched into the ROM-embedded dataflow engine and which dynamic states (like the KV cache) are managed by a host CPU in a "Split-Brain" system design. [8, 9]

#### Siliconization Comparison

| Siliconization Category | Compiler Goal | Hardware Strategy | Target Metric |
| :--- | :--- | :--- | :--- |
| **Deterministic Orchestration** | Cycle-accurate spatial scheduling [4] | Programmable LPU with no caches [3] | Zero jitter, 100% compute utilization |
| **AST-to-RTL Synthesis** | Direct hardware generation [7] | Model-specific ASIC netlist [6] | Maximum throughput per mm² |
| **Immutable Architecture** | Weight-to-metal encoding [8] | ROM-embedded constants in logic [9] | Minimum energy (pJ/operation) |

---

## Infrastructure Hardware Offloading Toolchains

In parallel with the AI accelerator revolution, the world of networking and infrastructure has moved toward hardening complex software functions onto SmartNICs and DPUs. This domain relies on compilers to translate protocols and packet-processing tasks into high-speed hardware pipelines.

### P4 Compilers and Protocol-Independent Data Planes

P4 (Programming Protocol-Independent Packet Processors) is the standard DSL for defining packet-processing logic. P4 compilers must map the logical "match-action" pipeline of the program to the physical resources of an ASIC or FPGA. [10]

For example, the NVIDIA BlueField DPU supports a subset of P4 via the DOCA Pipeline Language (DPL). The DPL compiler is tailored to leverage the strengths of high-performance ASIC hardware, which sometimes requires trade-offs in flexibility. It may not support variable-length header types (`varbit`) or arbitrary-precision integers in all contexts, as these would compromise the wire-speed performance required for 400G connectivity. [11] The compiler must map the P4 program's logical stages to Disaggregated Reconfigurable Match+Action Table (dRMT) architectures, which provide a balance between the fixed-function efficiency of an ASIC and the programmability of a CPU. [12]

### eBPF to Hardware: VLIW and Pipeline Synthesis

While eBPF was originally an in-kernel software framework, it has become a popular target for hardware offloading due to its familiarity to software developers. Compiling eBPF bytecode for hardware requires bridging the gap between a sequential, instruction-based execution model and a parallel hardware pipeline.

The hXDP (High-performance XDP) toolchain is a key technology in this space. It includes an optimizing compiler that translates unmodified eBPF bytecode into a specialized VLIW instruction set architecture (ISA) designed for FPGAs. [13, 14] The hXDP compiler performs static analysis to extract instruction-level parallelism, allowing the FPGA to execute multiple instructions per clock cycle. This compensates for the lower clock frequencies of FPGAs (often 10x lower than server CPUs) while maintaining comparable throughput. [13] Furthermore, the compiler removes instructions that are redundant in a hardware context, such as memory boundary checks and variable zeroing, which the purpose-built hardware can guarantee by design. [13]

An alternative methodology is provided by eHDL, a high-level synthesis (HLS) framework that converts eBPF programs into VHDL hardware pipelines. [15, 16] eHDL represents the eBPF program as a "state evolution" where each stage of the pipeline carries a full replica of the packet and program state (registers and stack). [15] The compiler unrolls the sequential eBPF code into a parallel sequential pipeline, where at any given time, as many packets are being processed as there are pipeline stages. [15]

#### Infrastructure Offloading Comparison

| Offload Compiler | Source Abstraction | Hardware Target | Performance Realization |
| :--- | :--- | :--- | :--- |
| **P4 Compiler** | P4_16 Match-Action [17] | dRMT ASIC / FPGA | Line-rate (400G) packet processing [11] |
| **hXDP** | eBPF Bytecode [13] | VLIW Soft-CPU on FPGA | Matches CPU throughput at 156MHz [14] |
| **eHDL (HLS)** | C-based eBPF [15] | Tailored RTL Pipelines | 100Gbps at 64B packet size [15] |

---

## Comparative Analysis: Convergent Methodologies and Siloed Innovations

The primary objective of this research was to compare and contrast the compiler methodologies used in LLM Siliconization and Infrastructure Offloading. While these domains serve different markets, they are increasingly relying on the same architectural principles.

### The Shift to Spatial Compilation

In both domains, the compiler has moved from being a "sequence optimizer" to a "spatial mapper." In LLM Siliconization, compilers like Groq’s map tensor operations to a grid of cores. [4] In Infrastructure Offload, compilers like eHDL map packet transformations to a sequence of hardware stages. [15]

The common challenge is managing the trade-off between flexibility and determinism. The LLM domain is currently favoring absolute determinism, leading to the removal of hardware components that introduce jitter (like caches and branch predictors). [3, 4] The networking domain, while also valuing determinism, has historically retained more flexibility to handle the stochastic nature of network traffic. However, with the rise of AI-centric networking protocols like Ultra Ethernet (UEC), the networking compilers are adopting the "software-defined infrastructure" philosophy, utilizing run-to-complete models and Harvard architecture cores to achieve energy-efficient, truly programmable wire-speed products. [18]

### Memory Wall Mitigation: Localized Data Movement

The "memory wall" is a shared adversary. LLM compilers mitigate it by organizing computation around explicit, compiler-managed data movement over on-chip networks, reducing reliance on high-latency global memory. [3, 19] Infrastructure compilers achieve a similar result by processing packets entirely within the NIC or even within the pluggable optics (FlexSFP), avoiding unnecessary PCIe transfers to the host CPU. [13, 20]

The methodology for managing this data movement is where the two domains most clearly overlap. Both require the compiler to solve a scheduling problem where the "cost" of data movement is explicitly factored into the execution plan.

#### Comparison of Compiler-Level Transformations

| Transformation Type | LLM Siliconization (e.g., Groq/Etched) | Infrastructure Offload (e.g., hXDP/eHDL) |
| :--- | :--- | :--- |
| **Control Flow** | Removed; replaced by static spatial schedules [4] | Predicated or unrolled into pipeline stages [15] |
| **Data Dependencies** | Resolved at compile-time via cycle-accurate mapping [4] | Managed via hardware primitives for stateful maps [15] |
| **Memory Access** | Streamed via "conveyor belts" or ROM-encoded [3, 8] | Zero-copy packet buffers and on-NIC SRAM [13, 17] |
| **Parallelism** | Tensor and pipeline parallelism across chips [3] | Instruction-level (VLIW) and packet-level pipelining [13, 15] |

---

## Literature Search and the "Gap" in Cross-Domain Research

A critical part of this investigation was searching for existing literature that explicitly compares these two domains. The findings indicate a significant gap in the current literature.

### Existing Siloes

Current research is predominantly siloed:
- **AI Graph Compilers:** Papers like "A Software-Defined Tensor Streaming Multiprocessor" focus on the challenges of distributing tile instances across spatially distributed cores for ML workloads. [19]
- **Network DSL Compilers:** Papers like "eHDL: a high-level synthesis tool to turn eBPF/XDP programs into tailored hardware designs" focus on the specific needs of packet processing and stateful network functions. [15]

While there are many papers on "AI for Networking" (using AI to optimize networks) or "Networking for AI" (high-speed interconnects for training clusters), there is a dearth of work that analyzes the isomorphism of the compiler problems across these domains.

### Bridging the Gap: The "Taurus" and "Homunculus" Exception

The most significant attempt to bridge this gap found in the literature is the Taurus architecture and its accompanying Homunculus framework. [21] Taurus is a data-plane architecture designed to execute per-packet data-driven (AI-based) decisions directly within the data plane at line rate.

Homunculus serves as the declarative programming framework that bridges the gap between high-level AI policies and the constrained programming models of network devices (like match-action tables). It automatically converts operator policies into efficient ML models (like DNNs or SVMs) that can be executed on the Taurus hardware. [21] This is one of the few instances where the compiler technology for LLM-style workloads and network-style hardware pipelines is unified into a single research agenda. It demonstrates that the "MapReduce" parallel-patterns abstraction can be used to efficiently execute common ML models within the data plane. [21]

### Synthesis of the Literature Gap

The lack of direct comparative sources can be attributed to the differing origins of the two fields:
1. **Networking Compilers** grew out of the need for formal specifications of hardware functions, where safety and protocol correctness are paramount. [15]
2. **AI Compilers** grew out of the need for linear algebra optimization and massive parallelization, where throughput and energy efficiency are the primary drivers. [4, 22]

Despite these different origins, the current convergence toward "Software-Defined Hardware" suggests that a unified theory of domain-specific compilation is both necessary and forthcoming.

---

## Comparative Synthesis: From Code to Silicon Topology

In the absence of direct comparative literature, we synthesize a comparison based on the architectural differences identified in isolated sources.

### The Role of the Compiler in Binding

In LLM Siliconization, the binding between the software and the hardware is becoming "harder." In the ITA paradigm, the compiler is used to generate the metal-mask layers of a chip. The weights are "frozen" into the silicon. [8] This is a "One Model, One Chip" (OMOC) design philosophy where the hardware is the model. [9]

In Infrastructure Offload, the binding remains "soft" or "reconfigurable." The compiler typically targets an FPGA bitstream or an ASIC configuration table. This allows network features to be deployed or updated without hardware replacement cycles. [16, 20] This "Flexibility-at-the-Edge" is a strategically significant benefit of infrastructure offloading. [20]

### Scheduling and Utilization

The scheduling philosophies also diverge based on the nature of the "task." LLM inference consists of a high number of repeated, identical operations (tensor math) on a static graph. This allows compilers to achieve nearly 100% compute utilization because the schedule can be perfectly balanced at compile time. [4] Networking tasks are more irregular and stateful (e.g., managing hash tables for millions of flows). Compilers in this space, like eHDL, focus on maintaining line-rate throughput while minimizing the resource footprint of each stage, often achieving 100Gbps with only 6.5%-13.3% of FPGA resources. [15]

### The Convergence of Energy Efficiency

Both domains are using compilers to shift the burden of performance from high-frequency, energy-hungry CPUs to lower-frequency, parallel hardware. hXDP matches high-end CPU performance at 156MHz. [14] ITA achieves comparable AI inference efficiency on legacy 28nm nodes as 7nm GPUs by replacing SRAM fetches with hardwired logic. [9] The common insight is that the energy cost of data movement dominates the cost of computation. Compilers in both domains are now primarily "data movement controllers" rather than just "instruction sequencers."

### Performance Modeling as a Cross-Domain Discipline

The next step for this field is not only better compilation, but better performance modeling. Once the compiler becomes responsible for placement, scheduling, and data movement, it also becomes responsible for predicting where execution will saturate. In practice, a useful model must explain three ceilings: compute throughput, memory bandwidth, and synchronization overhead.

For AI and HPC workloads, roofline-style analysis provides a practical first-order model. It relates achieved performance to arithmetic intensity, making it possible to distinguish kernels that are fundamentally memory-bound from those that are compute-bound. [34, 36] This matters directly for domain-specific compilation because transformations such as operator fusion, tiling, KV-cache placement, and on-chip buffering are all attempts to move a workload toward a more favorable intensity regime.

This interpretation is consistent with NVIDIA profiling guidance. Nsight Compute combines Roofline analysis with a "SpeedOfLight" view that compares observed execution against hardware peak ceilings. [34, 35] The same framing extends beyond GPU kernels to SmartNIC, DPU, and storage-offload pipelines: the key question is not simply whether offload occurred, but which ceiling becomes dominant after offload. On BlueField-class systems, for example, throughput can be limited by polling placement, DMA completion behavior, and memory-ordering costs rather than by raw datapath width alone. [25]

For heterogeneous infrastructure, a complete model must also account for communication topology. NVLink, GPUDirect Storage, host memory, and device-local SRAM form a hierarchy whose transfer costs can dominate nominal FLOP efficiency if the compiler schedules computation without modeling movement explicitly. [27, 28] In that sense, performance modeling becomes a control system for the compiler: roofline analysis identifies the active ceiling, topology-aware accounting identifies the dominant transfer path, and queue-depth or completion analysis explains the tail-latency penalties of synchronization.

This suggests a practical metric stack for future domain-specific compilers:

1. **Ceiling model:** Peak compute, memory, and interconnect limits.
2. **Intensity model:** Useful work per byte moved across each boundary.
3. **Runtime model:** Queue occupancy, polling strategy, and completion behavior.
4. **Tail model:** P99/P999 latency inflation caused by contention and barriers.

The strategic value of this approach is that it gives compiler organizations a repeatable way to measure progress toward near-hardware-limit execution. Instead of treating performance debugging as a late-stage benchmarking exercise, the compiler pipeline can surface model-guided explanations for why a workload remains compute-bound, bandwidth-bound, or coordination-bound, and choose transformations accordingly.

---

## Future Outlook: The Democratization of Custom Silicon

The convergence of these two domains points toward a future where "Silicon Compilers" become standard tools in the software development lifecycle.

1. **Unified DSLs:** We may see the emergence of unified languages that can describe both data-plane logic and neural transformations, allowing a single compiler to optimize for a "converged" infrastructure where AI inference happens inside every network port. [21]
2. **Automated ASIC Generation:** Tools like Taalas Foundry suggest a future where small teams can generate custom ASICs for specific models or infrastructure tasks at a fraction of the traditional cost, utilizing mature process nodes and automated RTL synthesis. [7, 8]
3. **Real-Time Adaptive Hardware:** AI-driven feedback and continuous learning frameworks can be used to adapt hardware configurations in real-time based on workload patterns. Techniques such as Dynamic Classifier Selection [23] and Masking-Based Partial Updates via Dynamic Partial Reconfiguration (DPR) [24] allow systems to seamlessly swap hardware modules on the fly, enabling runtime-robust edge inference without halting the data plane.

---

## Final Insights and Technical Conclusions

This investigation identifies a clear methodological transition in semiconductor design: the "Intelligence" of the system is migrating from the hardware runtime to the compiler.

In the domain of LLM Siliconization, the compiler is used to eliminate hardware complexity. By taking total control over spatial and temporal orchestration, the Groq compiler allows for a "dumb" but extremely fast and predictable hardware target. [4] By hardwiring weights, the ITA compiler eliminates the memory hierarchy entirely, achieving extreme energy efficiency. [8]

In the domain of Infrastructure Hardware Offloading, the compiler is used to bridge the gap between software-defined flexibility and hardware-grade performance. Frameworks like hXDP and eHDL demonstrate that unmodified sequential programs can be transformed into parallel, wire-speed hardware pipelines through advanced synthesis and optimization techniques. [13, 15]

### Nuanced Conclusions and Outlook

At the micro-architectural level, studies of BlueField-3 show that userspace offload performance depends as much on control-path placement and memory ordering as on datapath bandwidth. [25] In practice, on-path versus off-path polling changes DMA completion behavior, barrier pressure, cache residency, and tail latency under contention. For compiler and runtime designers, this means offload is not binary: schedules must encode polling placement, completion-observation strategy, and barrier policy on ARM cores.

The same shift appears one layer up in system software: DPDPU-style frameworks move beyond packet acceleration and offload database semantics into the DPU/SmartNIC complex. [26] Relocating B-tree traversal and storage primitives reduces host mediation and narrows the gap between query operators and transport execution. The compiler implication is direct: intermediate representations must carry richer data-structure semantics so they can target host or DPU operators while preserving consistency and failure semantics across split execution domains.

In parallel, GPUDirect Storage (GDS) is reshaping heterogeneous co-design for model-adaptation workloads, including single-GPU fine-tuning paths that bypass the host CPU for bulk movement. [27] NVMe, staging memory, and GPU memory increasingly operate as a unified ingestion fabric. The compiler consequence aligns with this report's thesis: next-generation domain-specific compilers must co-schedule compute and movement across DPU, DMA, NVMe, and GPU engines, optimizing not only FLOPs utilization but also transfer topology, synchronization granularity, and queue-level backpressure.

As this co-design model moves into public cloud environments, virtualization boundaries become a first-order compiler and runtime concern. RosenBridge shows that Express I/O acceleration can cross guest-host boundaries via virtio-ndp and userspace BPF, letting guest VMs safely use host-side XRP and GDS-oriented optimizations without breaking isolation. [31] This bridges bare-metal offload assumptions and multi-tenant cloud reality.

The same progression appears inside storage devices. Selective On-Device Execution of Data-Dependent Read I/Os (SODE) shows that eBPF-like resubmission logic can be sandboxed on device-resident processors, moving data-dependent control decisions directly into the storage path. [32] In compiler terms, the target surface expands from host kernels and SmartNICs to embedded controller cores, where placement must jointly optimize latency, safety envelopes, and device-level contention.

At the host interface layer, BypassD offers a complementary path for fast, safe userspace storage access under shared-device conditions by extending IOMMU-assisted translation from file offsets to block addresses. [33] Relative to single-tenant polling frameworks, this supports a broader compiler strategy: multiple backend realizations selected by tenancy, protection, and utilization constraints.

### Frontier Trajectories (2026+)

The following trajectories are illustrated with recent NVIDIA public materials, but the compiler implications are vendor-agnostic. First, rack-scale GPU fabrics are becoming compilation targets in their own right: sixth-generation NVLink and NVLink Switch expose high-bandwidth all-to-all communication, in-switch collective acceleration (SHARP), and fusion pathways for hybrid ASIC + GPU scale-up designs. [28] This shifts optimization from intra-device kernel fusion toward inter-device topology-aware lowering, where compilers reason about collective placement and communication schedules at rack scope.

Second, control and orchestration planes are converging with accelerator runtimes. Open-source Dynamic Resource Allocation work in Kubernetes indicates a move toward programmable, policy-driven accelerator partitioning at cluster runtime. [29] For compiler systems, this implies tighter integration between static graph lowering and dynamic resource contracts, enabling plans that adapt to changing GPU/DPU allocations without full recompilation.

Third, networking and inference are increasingly co-designed as a single distributed system layer. Recent AI-grid direction for telecom inference suggests that placement, transport, and model-serving decisions will be jointly optimized across edge and core fabrics. [30] In this context, domain-specific compilation extends beyond code generation into cross-node plan synthesis, where data-plane, inference, and network operators are co-scheduled under latency, power, and reliability constraints.

While the literature has yet to fully acknowledge the isomorphism between these two domains, the architectural evidence is undeniable. The future of domain-specific computing will be defined by compilers that treat silicon as a programmable canvas, mapping high-level intentions directly onto the physical geometry of the chip to overcome the limitations of traditional general-purpose architectures. The convergence of AI and networking at the silicon level is the first step toward a broader "Software-as-Silicon" revolution.

---

## References

1. [AI Hardware Built from a Software-First Perspective: Groq's Flexible Silicon Architecture](https://www.allaboutcircuits.com/news/AI-hardware-accelerator-software-first-Groq-flexible-silicon-architecture/)
2. [Groq Wants to Reimagine High Performance Computing](https://moorinsightsstrategy.com/groq-wants-to-reimagine-high-performance-computing/)
3. [What Is LPU? Language Processing Units and AI Inference](https://www.clarifai.com/blog/what-is-lpu)
4. [Groq's Deterministic Architecture Is Rewriting the Physics of AI Inference](https://medium.com/the-low-end-disruptor/groqs-deterministic-architecture-is-rewriting-the-physics-of-ai-inference-bb132675dce4)
5. [Meet Sohu: The World's First Transformer-Specialized Chip ASIC](https://www.marktechpost.com/2024/06/26/meet-sohu-the-worlds-first-transformer-specialized-chip-asic/)
6. [The New Compiler Stack: A Survey on the Synergy of LLMs and Compilers (arXiv)](https://arxiv.org/html/2601.02045v1)
7. [A Comprehensive Guide to FPGAs in Artificial Intelligence](https://www.kynix.com/Blog/a-comprehensive-guide-to-fpgas-in-artificial-intelligence.html)
8. [The Immutable Tensor Architecture: A Pure Dataflow Approach for Secure, Energy-Efficient AI Inference (arXiv HTML)](https://arxiv.org/html/2511.22889v1)
9. [The Immutable Tensor Architecture: A Pure Dataflow Approach for Secure, Energy-Efficient AI Inference (arXiv PDF)](https://www.arxiv.org/pdf/2511.22889)
10. [P4-16 Language Specification (v1.2.3)](https://p4lang.github.io/p4-spec/docs/P4-16-v1.2.3.html)
11. [P4 Language Support in DPL (NVIDIA DOCA Documentation)](https://docs.nvidia.com/doca/archive/2-10-0/P4-Language-Support-in-DPL/index.html)
12. [Towards Accelerating the Network Performance on DPUs by Optimizing the P4 Runtime](https://vbn.aau.dk/ws/portalfiles/portal/697664030/Towards_Accelerating_the_Network_Performance_on_DPUs_by_optimising_the_P4_runtime.pdf)
13. [hXDP: Efficient Software Packet Processing on FPGA NICs (OSDI 2020)](https://www.usenix.org/system/files/osdi20-brunella.pdf)
14. [hXDP: Efficient Software Packet Processing on FPGA NICs (USENIX OSDI Presentation Page)](https://www.usenix.org/conference/osdi20/presentation/brunella)
15. [eHDL: Turning eBPF/XDP Programs into Tailored Hardware Designs (ASPLOS 2023)](https://pontarelli.di.uniroma1.it/publication/asplos23/asplos23.pdf)
16. [The Case for Ultra High Speed Portable Network Security Filters (CEUR Workshop Proceedings)](https://ceur-ws.org/Vol-3731/paper11.pdf)
17. [SmartNIC Computing Capabilities](https://www.emergentmind.com/topics/smartnic-computing-capabilities)
18. [Xsight Labs at AI Infrastructure Field Day](https://techfieldday.com/appearance/xsight-labs-presents-at-ai-infrastructure-field-day/)
19. [A Software-Defined Tensor Streaming Multiprocessor for Large-Scale Machine Learning](https://www.researchgate.net/publication/361235897_A_software-defined_tensor_streaming_multiprocessor_for_large-scale_machine_learning)
20. [FlexSFP: Rethinking Network Intelligence Inside the Cable (ACM HotNets 2025)](https://conferences.sigcomm.org/hotnets/2025/papers/hotnets25-final442.pdf)
21. [Special Session: FPGA Networking (FPL 2024)](http://asaclab.polito.it/fpl2024/networking/)
22. [An In-Depth Comparison of Compilers for Deep Neural Networks on Hardware](https://nicsefc.ee.tsinghua.edu.cn/%2Fnics_file%2Fpdf%2Fpublications%2F2019%2FIEEE%20ICESS_None.pdf)
23. [Real-Time Adaptive Neural Network on FPGA: Enhancing Adaptability Through Dynamic Classifier Selection (arXiv)](https://arxiv.org/abs/2311.09516)
24. [Runtime-Robust Edge Inference System With Masking-Based Partial Update on Dynamic Reconfigurable FPGA (PMC)](https://pmc.ncbi.nlm.nih.gov/articles/PMC12736569/)
25. [Understanding the Idiosyncrasies of Emerging BlueField DPUs (ICS 2025)](https://dl.acm.org/doi/10.1145/3732414.3732454)
26. [DPDPU: Data Processing With DPUs (CIDR 2025)](https://fardatalab.org/cidr25-hu.pdf)
27. [An Efficient Heterogeneous Co-Design for Fine-Tuning on a Single GPU (arXiv)](https://arxiv.org/abs/2603.16428)
28. [NVIDIA NVLink and NVLink Switch](https://www.nvidia.com/en-us/data-center/nvlink/)
29. [Advancing Open Source AI, NVIDIA Donates Dynamic Resource Allocation Driver for GPUs to Kubernetes Community](https://blogs.nvidia.com/blog/nvidia-at-kubecon-2026/)
30. [NVIDIA, Telecom Leaders Build AI Grids to Optimize Inference on Distributed Networks](https://blogs.nvidia.com/blog/telecom-ai-grids-inference/)
31. [RosenBridge: A Framework for Enabling Express I/O Paths Across the Virtualization Boundary (USENIX FAST 2026)](https://www.usenix.org/system/files/fast26-qiu.pdf)
32. [Selective On-Device Execution of Data-Dependent Read I/Os (USENIX FAST 2025)](https://www.usenix.org/system/files/fast25-park.pdf)
33. [BypassD: Enabling Fast Userspace Access to Shared SSDs (ASPLOS 2024)](https://pages.cs.wisc.edu/~swift/papers/asplos24-bypassd.pdf)
34. [NVIDIA Nsight Compute Profiling Guide](https://docs.nvidia.com/nsight-compute/ProfilingGuide/index.html)
35. [Accelerating HPC Applications with NVIDIA Nsight Compute Roofline Analysis](https://developer.nvidia.com/blog/accelerating-hpc-applications-with-nsight-compute-roofline-analysis/)
36. [Roofline: An Insightful Visual Performance Model for Multicore Architectures](https://doi.org/10.1145/1498765.1498785)

---

*Copyright (c) 2026 SiliconLanguage Foundry. All rights reserved.*
