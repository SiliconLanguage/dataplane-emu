==========================================================

    AZURE COBALT 100: SILICON DATA PLANE SCORECARD
==========================================================

Architecture              | Latency (us) | IOPS
----------------------------------------------------------

1. Legacy Kernel          | 47.89        | 20693
2. User-Space Bridge      | 45.24        | 21585
3. Zero-Copy (Bypass)     | 29.40        | 33456.75
==========================================================

Metric                    | Legacy Path  | Cobalt Path
----------------------------------------------------------

Max CPU (Core 0)          | 7.9%         | 100.0%
Context Switches          | 413886       | 5
Memory Model              | Strong/Slow  | Weak/Atomic
==========================================================

🎯 INSIGHT: 5 context switches proves our reactor is polling.
