# Beyond LeetCode: Lock-Free Systems and Thread-Per-Core Data Planes

This tutorial explores the evolution of thread synchronization, moving from naive attempts at lock-free programming to industry-standard high-performance data plane architectures.

## 1. The "LeetCode Trap"
In many competitive programming and time-shared container environments, CPU resources are shared among many processes. When a thread uses a **naive lock-free spin-loop** (busy-waiting), it consumes its entire allotted OS time-slice without doing productive work. Because the OS sees the thread as "busy," it may not preempt it immediately to run the producer thread that would actually satisfy the condition. This leads to **CPU starvation** and catastrophic performance degradation.

## 2. The Standard Fix: Yielding to the OS
For standard applications and competitive coding, the correct approach is to use `std::mutex` and `std::condition_variable`. These primitives allow a thread to "sleep" and yield its CPU time back to the operating system. The OS can then use those cycles to run other threads (like the producer). This approach ensures fairness and efficiency in time-shared environments.

## 3. The Enterprise Fix: Thread-Per-Core (TPC)
High-performance frameworks like **SPDK** and **DPDK** bypass the kernel and manage hardware directly. They utilize a **Thread-Per-Core (TPC)** model where:
- Threads are strictly pinned to specific physical CPU cores (`pthread_setaffinity_np`).
- One thread owns all resources on that core, eliminating the overhead of OS context switches.
- Because no other threads are competing for that core, **lock-free polling** becomes safe and extremely efficient, achieving microsecond-level latency.

### System Specifications and Benchmark Results

Before running the code, we first check the CPU topology. Then we compile the three implementations and time their execution to observe the differences in latency and CPU utilization.

```console
~/dataplane-emu/examples/beyond-leetcode/01_time_shared_trap$ lscpu | grep -E "Architecture:|CPU\(s\):|Thread\(s\) per core:|Core\(s\) per socket:|Socket\(s\):|L1d:|L1i:|L2:|L3:"
Architecture:                         x86_64
CPU(s):                               24
Thread(s) per core:                   2
Core(s) per socket:                   12
Socket(s):                            1
NUMA node0 CPU(s):                    0-23
~/dataplane-emu/examples/beyond-leetcode/01_time_shared_trap$ make all
clang++ -std=c++17 -O3 -Wall -Wextra "" -o 01_naive_spin_trap 01_naive_spin_trap.cpp -pthread ""
clang++ -std=c++17 -O3 -Wall -Wextra "" -o 02_leetcode_mutex_fix 02_leetcode_mutex_fix.cpp -pthread ""
clang++ -std=c++17 -O3 -Wall -Wextra "" -o 03_spdk_tpc_polling 03_spdk_tpc_polling.cpp -pthread ""
~/dataplane-emu/examples/beyond-leetcode/01_time_shared_trap$ time ./01_naive_spin_trap 
Consumer received: 42

real    0m0.238s
user    0m4.646s
sys     0m0.243s
~/dataplane-emu/examples/beyond-leetcode/01_time_shared_trap$ time ./02_leetcode_mutex_fix clear
Consumed: 1000000 messages.

real    0m0.134s
user    0m0.197s
sys     0m0.040s
~/dataplane-emu/examples/beyond-leetcode/01_time_shared_trap$ time ./03_spdk_tpc_polling 
TPC Consumer signaled.

real    0m0.006s
user    0m0.003s
sys     0m0.001s
```

### Performance Breakdown

Here is a breakdown of what the `time` outputs demonstrate:

#### 1. The Naive Spin Trap (`01_naive_spin_trap`)
* **Real Time:** 0.200s
* **User Time:** 3.990s
* **The Problem:** Notice that **User Time is ~20x higher than Real Time**. This is the "LeetCode Trap" in action. CPU cores are pegged at 100% because the consumer threads are spinning in a `while` loop, burning through their entire OS time-slice while doing zero productive work. It took 4 seconds of "CPU effort" just to finish a 0.2-second task.

#### 2. The Mutex Fix (`02_leetcode_mutex_fix`)
* **Real Time:** 0.130s
* **User Time:** 0.183s
* **The Result:** This is much more efficient for a shared system. Because the threads use `std::condition_variable`, they "sleep" and yield the CPU back to the OS when there is no data. The **User Time is now very close to Real Time**, meaning the CPU was only working when it actually had data to process.

#### 3. The TPC Polling Fix (`03_spdk_tpc_polling`)
* **Real Time:** 0.007s
* **User Time:** 0.004s
* **The Result:** This is the high-performance "Enterprise" result. The total execution time dropped from 130ms to **7ms**. By pinning threads to specific cores, the overhead of the OS moving threads around and the latency of waking up a sleeping thread via a mutex is eliminated. This demonstrates why data planes like SPDK/DPDK can achieve sub-microsecond latencies that are impossible with standard `std::mutex`.

#### Summary
| Approach | Efficiency | Latency | Environment |
| :--- | :--- | :--- | :--- |
| **Naive Spin** | Terrible (Starvation) | High | Don't use in time-shared systems. |
| **Mutex/CV** | Excellent (Fair) | Medium | Best for standard apps/LeetCode. |
| **TPC Polling** | Unmatched (Raw Power)| Ultra-Low | Best for dedicated Data Planes. |