You are the Lead Control Plane Engineer and UI/UX Specialist for the Tensorplane AI Foundry. 

We are preparing an executive-level demonstration of `dataplane-emu` (our C++ zero-copy, kernel-bypassing storage engine utilizing SPDK and ARM64 LSE atomics) for the Azure PostgreSQL (HorizonDB) leadership team. 

Another agent (the Web Agent) has generated a rough Python prototype for the interactive control plane. Your objective is to take this raw prototype and transform it into a Director-ready, enterprise-grade Command Line Interface (CLI) and execution harness. 

Please execute the following tasks:

1. **Aesthetic & Vibe Overhaul (The "SiliconLanguage" Brand):**
   - Scrub the existing UI output. Implement a strict, high-signal, ultra-minimalist cyberpunk aesthetic using cyan (`\033[36m`), magenta (`\033[35m`), and dark gray (`\033[90m`) ANSI color codes.
   - Integrate our company ASCII art logo (featuring the lambda `λ` symbol embedded in a 64-bit instruction encoding block) to display cleanly upon startup.
   - Format the live telemetry output (IOPS, microsecond latency, zero-copy verification) to look like a precision hardware-monitoring tool.

2. **Setup Script & Virtual Environment Hardening:**
   - Refactor `run_demo.sh` to be bulletproof. It must correctly bootstrap the Python virtual environment.
   - Inject the ultra-minimalist Monad prompt directly into the virtual environment's activation script so the terminal dynamically transforms to: `[Dark Gray](silicon-fabric) [Cyan]\W [Magenta]λ ` and does not revert to the default Ubuntu prompt during subshell executions.

3. **Code Refactoring & Robustness:**
   - Modularize the Python code. Separate the Model Context Protocol (MCP) client logic, the C++ `spdk_tgt` subprocess management, and the UI rendering loop into distinct, maintainable classes.
   - Enforce strict Python typing and robust error handling (e.g., gracefully catching if the C++ data plane crashes or if the NVMe-oF target fails to bind).

4. **Documentation:**
   - Add comprehensive, executive-level docstrings to all Python classes. 
   - Update the `README.md` to clearly explain the "Control-to-Data Plane Bridge" (how this Python UI orchestrates the underlying C++ bare-metal engine).

Do not alter the underlying C++ SPDK engine logic; your domain is strictly the Python control plane, the setup scripts, and the executive look-and-feel. Deliver clean, refactored, and heavily documented code.