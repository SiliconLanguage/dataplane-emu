cmake_minimum_required(VERSION 3.15)

# 1. Explicitly force GCC toolchain
set(CMAKE_C_COMPILER "gcc")
set(CMAKE_CXX_COMPILER "g++")

project(dataplane-emu CXX C)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED True)

# 2. Platform-Specific Optimization Logic
if(CMAKE_SYSTEM_PROCESSOR MATCHES "aarch64|arm64")
    message(STATUS "Detected ARM64 (Graviton) Platform - Applying Neoverse-V1 optimizations")
    set(ARCH_FLAGS "-mcpu=neoverse-v1")
else()
    message(STATUS "Detected x86_64 (WSL/Dev) Platform - Applying Native optimizations")
    set(ARCH_FLAGS "-march=native")
endif()

set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -O3 ${ARCH_FLAGS} -D_FILE_OFFSET_BITS=64")

# Find required modules via pkg-config
find_package(PkgConfig REQUIRED)

# 3. Find SPDK & FUSE3
#pkg_check_modules(SPDK REQUIRED spdk_nvme spdk_env_dpdk spdk_log spdk_util)
pkg_check_modules(FUSE3 REQUIRED fuse3)

include_directories(include)
include_directories(${SPDK_INCLUDE_DIRS})
include_directories(${FUSE3_INCLUDE_DIRS})

# 4. Define the executable
add_executable(dataplane-emu 
    src/main.cpp
    src/sq_cq.cpp
    src/fuse_bridge/interceptor.cpp
)

# Link all required libraries
target_link_libraries(dataplane-emu 
    ${SPDK_LIBRARIES} 
    ${FUSE3_LIBRARIES}
    pthread dl uuid numa
)