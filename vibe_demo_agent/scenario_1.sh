#!/bin/bash
clear

bash "$(dirname "${BASH_SOURCE[0]}")/logo.sh"
echo -e "\033[94m       >>> From Language To Monad on Chip <<<\033[0m\n"

# WAIT: 1
# VOICE: Welcome to the SiliconLanguage Foundry.
# WAIT: 1
# VOICE: Traditional AI infrastructure is bottlenecked by layers of OS abstraction. 
# VOICE: Our philosophy bridges that gap, compiling high-level, safe semantics directly into hardware state—what we call the Monad-On-Chip architecture.

echo -e "\033[90m[COMPILER]  Parsing SiliconLanguage functional semantics...\033[0m"
sleep 0.8
echo -e "\033[90m[SYNTHESIS] Lowering abstract state to bare-metal MonadOnChip...\033[0m"
sleep 0.8
echo -e "\033[90m[DATAPLANE] Binding user-space to lock-free SPDK queues...\033[0m"
sleep 0.8
echo -e "\033[92m[SYS_READY] Unified Silicon Fabric established.\033[0m\n"

# WAIT: 1.5
# VOICE: Watch as we lower the representation straight to the bare-metal dataplane, executing with sub-microsecond latency.

./dataplane-emu --init --mode=lock-free --verbose 2>&1 | pv -qL 150

# WAIT: 2
# VOICE: The environment is initialized. Notice how we maintain zero-copy IO throughput without triggering a single kernel context switch.

./dataplane-emu --benchmark --threads=4 2>&1 | pv -qL 300

# WAIT: 1
# VOICE: That concludes the baseline performance demonstration.
# WAIT: 1
# HIRE_ME
