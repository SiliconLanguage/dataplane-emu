# Phase 4: `LD_PRELOAD` POSIX Bridge Implementation

This document explicitly defines the low-level interception and injection mechanics required to establish a completely transparent user-space routing engine on top of legacy applications.

## RTLD_NEXT Trampoline Routing
To circumvent the standard operating system virtual filesystem layer, we construct explicit function overrides natively compiled into a shared library object (`.so`). Using `LD_PRELOAD`, we inject our library ahead of the system standard `libc`.
By relying securely on `dlsym(RTLD_NEXT, "open")`, the application intercepts exact signature definitions for `open`, `pread`, `pwrite`, and `close`. This "trampoline" effect allows us to seamlessly capture calls, inspect the target filesystem payloads, and unconditionally bypass the standard host operating system payload routing definitions.

## The Fake File Descriptor Allocation Strategy
Applications natively interact via integer File Descriptors (FDs). To cleanly route intercepted data into the simulated DPDK queue backend without catastrophically breaking overlapping standard operations (such as dynamically reading generic OS configuration files), we institute the **Fake FD Routing Protocol**.

1. **Interception Check:** When an `open()` call targets our optimized `/tmp/cobalt/` dataset, we explicitly abort the kernel execution.
2. **Elevated Value Return:** We manually assign and return a fabricated FD integer strictly offset aggressively far beyond conventional Linux definitions, such as assigning base descriptors starting solidly at `> 1,000,000`. 
3. **Collision Avoidance:** During subsequent `pread` or `pwrite` executions, if the input FD checks mathematically `> 1,000,000`, the execution skips `libc` and natively dumps the block into our DPDK submission queues. If the FD is a standard low-integer map, we transparently pass the payload off to the actual `glibc` implementation exactly as normal!
