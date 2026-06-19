# End-to-End Storage Architecture: Emulation — Kernel vs. Bypass

> **Note:** Mermaid does not support collapsible nodes. The diagram below shows the compact flow; expand each `▶ Details` section beneath it for per-layer descriptions.

```mermaid
%%{init: {"theme": "dark", "themeVariables": {"edgeLabelBackground": "transparent"}}}%%
flowchart TD
    %% ==========================================
    %% 1. DIAGRAM STRUCTURE & NODES
    %% ==========================================

    subgraph GUEST ["🛡️ GUEST OS VM"]
        subgraph USER ["🖥️ GUEST USER SPACE"]
            PA["Path A:<br/>Guest Standard<br/>Kernel I/O"]
            PB["Path B:<br/>Guest Kernel-QEMU Bypass I/O<br/>(Zero-Copy)"]
            PC["Path C:<br/>Direct Path /<br/>Guest Kernel-Bypass"]
            
            N1["1. Application"]
            N2["2. POSIX API / glibc"]
            N3["3. User-Space Polled-Mode<br/>Driver (e.g., SPDK)"]
        end
        
        subgraph KERNEL ["⚙️ GUEST KERNEL SPACE"]
            N4["4. VFS<br/>5. Filesystem (ext4 / xfs / btrfs)"]
            N6["6. Page Cache"]
            N7["7. Block Layer<br/>8. I/O Scheduler<br/>9. Device Driver"]
        end
    end

    subgraph VIRTUAL_HW ["🌐 VIRTUAL INTERCONNECT BUS"]
        N10["10. Virtual Transport / Interconnect Bus (vPCIe, vNVMe-oF, vSAS/SATA)"]
    end

    subgraph HOST ["⚙️ HOST OS CONTEXT"]
        subgraph QEMU ["11. QEMU PROCESS"]
            N12["12. QEMU NVMe Emulation Logic"]
        end
    end

    subgraph PHYSICAL_HW ["🔩 PHYSICAL HARDWARE SPACE"]
        N13["13. High-Speed Storage Device<br/>(NVMe SSD, NVMe-oF Target, Array)<br/>⚡ PCIe Gen4 / Gen5 Bare Metal"]
    end

    %% Invisible dummy node for Path C alignment
    LBL_C["MMIO and DMA Kernel-Bypass I/O"]

    %% ==========================================
    %% 2. CORE DATA ROUTING & EXACT INDEXING
    %% ==========================================
    
    %% Indices 0, 1, 2 (Invisible alignment links)
    PA ~~~ N1
    PB ~~~ N1
    PC ~~~ N1
    
    %% --- PATH A (RED) ---
    %% Indices 3, 4, 5, 6, 7, 8, 9
    PA -.-> N2
    N1 --> N2
    N2 == Standard Kernel I/O Stack ==> N4
    N4 --> N6
    N6 -->|Cache HIT to user space| N2
    N6 -->|Cache MISS| N7
    N7 -->|Guest Driver Commands over Virtual Bus| N10
    
    %% --- PATH B (YELLOW-GREEN) ---
    %% Indices 10, 11, 12, 13, 14
    PB -.-> N3
    N1 -->|Asynchronous Submission and Completion Queues| N3
    N3 -.->|To Emulated Virtual Bus| N10
    N10 == Virtual PCIe BAR writes, doorbells, SQEs ==> N12
    N12 == Translated Host Level I/O Requests ==> N13
    
    %% --- PATH C (GREEN) ---
    %% Indices 15, 16, 17
    PC -.-> N3
    N3 === LBL_C
    LBL_C ==> N13

    %% ==========================================
    %% 3. VISUAL STYLING (Safely at the bottom)
    %% ==========================================

    %% Subgraph Styles
    style GUEST fill:#112030,color:#cdd9e5,stroke:#375172
    style USER fill:#162b42,color:#cdd9e5,stroke:#42628a
    style KERNEL fill:#2a0a0a,color:#ffcccc,stroke:#ff4d4d
    style VIRTUAL_HW fill:#2a1a3a,color:#e6ccff,stroke:#ff00ff,stroke-width:3px,stroke-dasharray: 5 5
    style HOST fill:#3d2a14,color:#e1d1ba,stroke:#855d2c
    style QEMU fill:#4a1a4a,color:#ffccff,stroke:#ff00ff,stroke-width:3px,stroke-dasharray: 5 5
    style PHYSICAL_HW fill:#17191e,color:#e2e8f0,stroke:#94a3b8,stroke-width:3px

    %% Legend / Callout Node Styles
    style PA fill:#2a0a0a,stroke:#ff4d4d,stroke-width:2px,color:#ffcccc
    style PB fill:#1a220a,stroke:#ccff33,stroke-width:2px,color:#e6ffb3
    style PC fill:#0a2a1a,stroke:#00e676,stroke-width:2px,color:#b3ffcc
    style LBL_C fill:#0a2a1a,stroke:#00e676,stroke-width:2px,color:#b3ffcc,font-weight:bold

    %% Highlighted Internal Nodes
    style N10 fill:#4a104a,color:#ffccff,stroke:#ff00ff,stroke-width:4px
    style N12 fill:#5a105a,color:#ffddff,stroke:#ff00ff,stroke-width:4px
    style N13 fill:#0f1115,color:#38bdf8,stroke:#38bdf8,stroke-width:2px

    %% Path A Links (Red)
    linkStyle 4,6 stroke:#ff4d4d,stroke-width:2px,color:#ff4d4d
    linkStyle 3 stroke:#ff4d4d,stroke-width:2px,stroke-dasharray: 5 5,color:#ff4d4d
    linkStyle 5 stroke:#ff4d4d,stroke-width:3px,color:#ff4d4d
    linkStyle 7,8,9 stroke:#ff4d4d,stroke-width:2px,color:#ff4d4d

    %% Path B Links (Yellow-Green)
    linkStyle 11 stroke:#ccff33,stroke-width:2px,color:#ccff33
    linkStyle 10,12 stroke:#ccff33,stroke-width:2px,stroke-dasharray: 5 5,color:#ccff33
    linkStyle 13,14 stroke:#ccff33,stroke-width:3px,color:#ccff33

    %% Path C Links (Green)
    linkStyle 15 stroke:#00e676,stroke-width:2px,stroke-dasharray: 5 5,color:#00e676
    linkStyle 16,17 stroke:#00e676,stroke-width:4px,color:#00e676
```

---

<details>
<summary><strong>1. Application</strong> — User Space</summary>

Your program logic that processes data and initiates I/O requests (e.g. a database engine, web server, or CLI tool).

</details>

<details>
<summary><strong>2. POSIX API / C Standard Library (glibc)</strong> — User Space</summary>

Provides standard I/O wrappers: `read()`, `write()`, `pread()`, `mmap()`. Handles the transition from user space into the kernel via system call traps.

</details>

<details>
<summary><strong>3. User-Space Polled-Mode Driver (e.g., SPDK)</strong> — User Space</summary>

Implements the guest VM's asynchronous queue-driven path. Requests are issued through submission/completion queues in guest user space and then sent over the guest virtual interconnect to a single emulation point.

</details>

<details>
<summary><strong>4. VFS — Virtual File System</strong> — Kernel Space</summary>

Presents a unified file interface to the layers above, regardless of the underlying filesystem. Routes each request to the correct concrete filesystem implementation.

</details>

<details>
<summary><strong>5. Filesystem (ext4 / xfs / btrfs)</strong> — Kernel Space</summary>

Translates logical file offsets (byte ranges inside a file) into physical block addresses on the device. Manages filesystem metadata: inodes, directory entries, extents, journals.

</details>

<details>
<summary><strong>6. Page Cache</strong> — Kernel Space</summary>

Caches file data in RAM to avoid redundant disk access.

- **Cache HIT** — data is already in RAM; returned directly to user space without touching the block layer.
- **Cache MISS** — data is not cached; execution continues down to the Block Layer to fetch it from storage.

</details>

<details>
<summary><strong>7. Block Layer</strong> — Kernel Space</summary>

Constructs `bio` (block I/O) structures representing the read/write operation. Merges adjacent or overlapping requests (request merging) and queues them for the I/O scheduler.

</details>

<details>
<summary><strong>8. I/O Scheduler</strong> — Kernel Space</summary>

Reorders queued block requests to optimize throughput and latency. Common schedulers:

| Scheduler | Best for |
|-----------|----------|
| `mq-deadline` | latency-sensitive (databases, VMs) |
| `bfq` | interactive desktops, fairness |
| `none` | NVMe SSDs (already fast, no reorder needed) |

</details>

<details>
<summary><strong>9. Device Driver</strong> — Kernel Space</summary>

Translates kernel-level block I/O requests into hardware-specific command protocols. Examples: NVMe driver (NVMe command set over PCIe), SCSI driver (SCSI CDBs over SAS/SATA via libata).

</details>

<details>
<summary><strong>10. Virtual Transport / Interconnect Bus (vPCIe, vNVMe-oF, vSAS/SATA)</strong> — Guest/Host Boundary</summary>

Convergence point for both guest paths. Whether requests originate from guest-context synchronous system calls through the guest kernel stack or from guest asynchronous queue submission, both flows enter this same virtual bus and are forwarded to QEMU emulation.

</details>

<details>
<summary><strong>11. QEMU Process</strong> — Host OS Context</summary>

Host-side userspace process that terminates the guest virtual device model. It receives guest device interactions from the virtual bus and coordinates emulation, memory translation, and request submission toward host-accessible storage resources.

</details>

<details>
<summary><strong>12. QEMU NVMe Emulation Logic</strong> — Host OS Context</summary>

Processes guest NVMe protocol operations arriving over virtual PCIe semantics, including guest BAR writes, doorbell updates, and submission queue entries. The emulator translates guest memory pointers into host memory addresses, interprets command structures, and emits corresponding host-level I/O requests to reach real storage.

</details>

<details>
<summary><strong>13. Storage Device (NVMe SSD, NVMe-oF Target, Array)</strong> — Hardware Space</summary>

The physical endpoint that executes I/O operations, including local NVMe SSDs, remote NVMe-oF targets, and storage arrays.

</details>