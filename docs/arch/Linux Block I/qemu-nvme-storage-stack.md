# Linux Block I/O Stack

> **Note:** Mermaid does not support collapsible nodes. The diagram below shows the compact flow; expand each `▶ Details` section beneath it for per-layer descriptions.

```mermaid
flowchart TD
    subgraph GUEST["🛡️ GUEST OS VM"]
        subgraph USER["🖥️ GUEST USER SPACE"]
            A["1. Application"]
            B["2. POSIX API / glibc"]
            J["3. User-Space Polled-Mode Driver (e.g., SPDK)"]
        end

        subgraph KERNEL["⚙️ GUEST KERNEL SPACE"]
            C["4. VFS"]
            D["5. Filesystem (ext4 / xfs / btrfs)"]
            E["6. Page Cache"]
            F["7. Block Layer"]
            G["8. I/O Scheduler"]
            H["9. Device Driver"]
        end
    end

    subgraph VIRTUAL_HW["🌐 VIRTUAL INTERCONNECT BUS"]
        T["10. Virtual Transport / Interconnect Bus\n(vPCIe, vNVMe-oF, vSAS/SATA)"]
    end

    subgraph HOST["⚙️ HOST OS CONTEXT"]
        subgraph QEMU["11. QEMU PROCESS"]
            QN["12. QEMU NVMe Emulation Logic"]
        end
    end

    subgraph PHYSICAL_HW["🔩 PHYSICAL HARDWARE SPACE"]
        I["13. Storage Device\n(NVMe SSD, NVMe-oF Target, Array)"]
    end

    A -->|"Guest-Context Synchronous Syscalls"| B
    B -->|"Standard Kernel I/O Stack"| C
    C --> D
    D --> E
    E -->|"Cache HIT → user space"| B
    E -->|"Cache MISS"| F
    F --> G
    G --> H
    H -->|"Guest Driver Commands over Virtual Bus"| T

    A -->|"Asynchronous Submission/Completion Queues"| J
    J -->|"Memory-Mapped I/O (MMIO) & DMA\nKernel-Bypass I/O (Zero-Copy)"| T
    T -->|"Virtual PCIe BAR writes, doorbells, SQEs"| QN
    QN -->|"Translated Host-Level I/O Requests"| I

    P1["Path A: Guest Standard Kernel I/O"]
    P2["Path B: Guest Kernel-Bypass I/O (Zero-Copy)"]
    P1 -.-> C
    P2 -.-> J

    style GUEST fill:#13283d,color:#d8ebff,stroke:#4a90d9,stroke-width:2px
    style USER fill:#1e3a5f,color:#cce0ff,stroke:#4a90d9
    style KERNEL fill:#1a3a1a,color:#ccffcc,stroke:#4aaa4a
    style HOST fill:#3d2d12,color:#ffe9cc,stroke:#d08a2b,stroke-width:2px
    style QEMU fill:#4a1a4a,color:#ffccff,stroke:#ff00ff,stroke-width:3px,stroke-dasharray: 5 5
    style QN fill:#5a105a,color:#ffddff,stroke:#ff00ff,stroke-width:4px
    style VIRTUAL_HW fill:#2a1a3a,color:#e6ccff,stroke:#ff00ff,stroke-width:3px,stroke-dasharray: 5 5
    style PHYSICAL_HW fill:#3a1a1a,color:#ffcccc,stroke:#aa4a4a
    style E fill:#2a3a1a,color:#eeffcc,stroke:#88aa44
    style J fill:#4a2a1a,color:#ffe6cc,stroke:#d9792b,stroke-width:2px
    style T fill:#4a104a,color:#ffccff,stroke:#ff00ff,stroke-width:4px
    style P1 fill:#1a3a1a,color:#d9ffd9,stroke:#4aaa4a,stroke-dasharray: 4 3
    style P2 fill:#4a2a1a,color:#ffe6cc,stroke:#d9792b,stroke-dasharray: 4 3
    linkStyle 9 stroke:#d9792b,stroke-width:3px,stroke-dasharray: 6 4
    linkStyle 10 stroke:#d9792b,stroke-width:3px,stroke-dasharray: 6 4
    linkStyle 11 stroke:#d9792b,stroke-width:3px,stroke-dasharray: 6 4
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