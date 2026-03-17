cmake_minimum_required(VERSION 3.15)

project(dataplane-emu CXX C)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED True)

option(ENABLE_TSAN "Enable ThreadSanitizer" OFF)

# ==============================================================================
# GRAVITON OPTIMIZATION STRATEGY
# Target: AWS Graviton3 (Neoverse-V1)
# 
# -mcpu=neoverse-v1:
#   Tuning specifically for the Neoverse-V1 microarchitecture. This enables 
#   optimizations for the V1 pipeline, branch predictor, and cache hierarchy. 
#   It also implicitly sets the architecture to Armv8.4-A.
#
# -moutline-atomics:
#   Enables runtime detection of Large System Extensions (LSE). If the CPU 
#   supports LSE (like Graviton3), it uses high-performance atomic instructions 
#   (CAS, SWP, LDADD). This is critical for reducing contention in the 
#   dataplane's ring buffers and mutexes.
#
# Verified via: 
#   objdump -d | grep -i 'cas\|swp\|ldadd' (Confirmed LSE generation)
# 
#  curent state:
# [ec2-user@ip-xxx-xx-xx-xxx dataplane-emu]$ objdump -d build/dataplane-emu | grep -i "zmm\|ptrue" | wc -l
# 0
# [ec2-user@ip-xxx-xx-xx-xxx  dataplane-emu]$ objdump -d build/dataplane-emu | grep -i 'cas\|swp\|ldadd' | wc -l
# 5
# ==============================================================================

# --- Architecture Detection ---
if(CMAKE_SYSTEM_PROCESSOR MATCHES "aarch64|arm64")
    # Define as a list (no spaces inside the quotes)
    set(GRAVITON_FLAGS "-mcpu=neoverse-v1" "-moutline-atomics" "-fallow-store-data-races")
    message(STATUS "Optimization: Target Graviton3 (Neoverse-V1)")
else()
    set(GRAVITON_FLAGS "-march=native")
endif()

# --- Common Build Options ---
add_library(project_options INTERFACE)
target_compile_options(project_options INTERFACE -O3 ${GRAVITON_FLAGS})
target_compile_definitions(project_options INTERFACE _FILE_OFFSET_BITS=64)

if(ENABLE_TSAN)
    target_compile_options(project_options INTERFACE -fsanitize=thread -g -fno-omit-frame-pointer)
    target_link_options(project_options INTERFACE -fsanitize=thread)
endif()

# --- Dependencies ---
find_package(PkgConfig REQUIRED)
pkg_check_modules(FUSE3 REQUIRED fuse3)

# --- Targets ---
add_executable(dataplane-emu 
    src/main.cpp
    src/sq_cq.cpp
    src/fuse_bridge/interceptor.cpp
)
target_link_libraries(dataplane-emu PRIVATE project_options ${FUSE3_LIBRARIES} pthread dl uuid numa)
target_include_directories(dataplane-emu PRIVATE include ${FUSE3_INCLUDE_DIRS})

add_executable(dataplane_ring src/dataplane_ring.cpp)
target_link_libraries(dataplane_ring PRIVATE project_options pthread)