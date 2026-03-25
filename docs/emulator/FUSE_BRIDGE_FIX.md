# FUSE Bridge Zero-IOPS Incident: Postmortem

## Status
Resolved. This issue is retained as historical context because it explains a real failure mode in the Stage 2 bridge benchmark.

## Symptom
Stage 2 (`fuse.json`) reported zero throughput/latency and fio exited immediately with ENOSYS during file setup.

Observed error:
```text
fio: pid=0, err=38/file:filesetup.c:150, func=unlink, error=Function not implemented
```

## Root Cause
The FUSE operations table in `src/fuse_bridge/interceptor.cpp` was missing file-management operations that fio expects during setup:
- `unlink`
- `truncate`
- `chmod`
- `chown`

fio calls these before issuing I/O. Returning ENOSYS prevented the workload from starting.

## Fix Implemented
Added no-op-compatible handlers for `nvme_raw_0` and registered them in `fuse_operations`:
- `dp_unlink`
- `dp_truncate`
- `dp_chmod`
- `dp_chown`

Result: fio setup now succeeds and Stage 2 executes normally.

## Why This Still Matters
This incident established a key reliability requirement for benchmark-facing FUSE layers:

FUSE must implement the practical POSIX surface that tools use during setup, not just the hot-path read/write calls.

## Current Benchmark Model (for context)
The project has since moved to deterministic orchestration and strict measured Stage 3:
1. Stage 1: Legacy kernel fio (`x.json`)
2. Stage 2: User-space bridge fio (`fuse.json`)
3. Stage 3: Strict PCIe SPDK `bdevperf` measurement (no synthetic bypass math)

Run command:
```bash
ARM_NEOVERSE_DEMO_CONFIRM=YES ./launch_arm_neoverse_demo_deterministic.sh
```

## Related Diagnostics
- `diagnose_fuse.sh` remains useful for quick checks of bridge process state, mount visibility, and JSON/log artifacts.
