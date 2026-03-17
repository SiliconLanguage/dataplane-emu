cmake_minimum_required(VERSION 3.10)

# Explicitly set the compiler to clang++
set(CMAKE_CXX_COMPILER clang++)

project(BeyondLeetCode_TimeSharedTrap)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(Threads REQUIRED)

# --- Thread Sanitizer (TSAN) Configuration ---
# To enable, uncomment the two lines below:
# set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -fsanitize=thread")
# set(CMAKE_EXE_LINKER_FLAGS "${CMAKE_EXE_LINKER_FLAGS} -fsanitize=thread")

# 1. Naive Spin Trap
add_executable(01_naive_spin_trap 01_naive_spin_trap.cpp)
target_link_libraries(01_naive_spin_trap PRIVATE Threads::Threads)

# 2. LeetCode Mutex Fix
add_executable(02_leetcode_mutex_fix 02_leetcode_mutex_fix.cpp)
target_link_libraries(02_leetcode_mutex_fix PRIVATE Threads::Threads)

# 3. SPDK/TPC Polling
add_executable(03_spdk_tpc_polling 03_spdk_tpc_polling.cpp)
target_link_libraries(03_spdk_tpc_polling PRIVATE Threads::Threads)