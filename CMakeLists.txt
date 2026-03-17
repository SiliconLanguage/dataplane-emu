cmake_minimum_required(VERSION 3.15)

# 1. Explicitly force GCC toolchain
set(CMAKE_C_COMPILER "gcc")
set(CMAKE_CXX_COMPILER "g++")

project(dataplane-emu CXX C)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED True)

# --- New: TSAN Option ---
option(ENABLE_TSAN "Enable ThreadSanitizer for race detection" OFF)

# 2. Platform-Specific Optimization Logic
if(CMAKE_SYSTEM_PROCESSOR MATCHES "aarch64|arm64")
    message(STATUS "Detected ARM64 (Graviton) Platform - Applying Neoverse-V1 optimizations")
    set(ARCH_FLAGS "-mcpu=neoverse-v1")
else()
    message(STATUS "Detected x86_64 (WSL/Dev) Platform - Applying Native optimizations")
    set(ARCH_FLAGS "-march=native")
endif()

# Define base flags
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -O3 ${ARCH_FLAGS} -D_FILE_OFFSET_BITS=64")

# --- New: Apply TSAN Flags if enabled ---
if(ENABLE_TSAN)
    message(STATUS "ThreadSanitizer (TSAN) Enabled - Disabling -O3 for better reports")
    # TSAN works best with -O1 or -O2 and needs -g for stack traces
    set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -fsanitize=thread -g -fno-omit-frame-pointer")
    # Linker also needs the sanitize flag
    set(CMAKE_EXE_LINKER_FLAGS "${CMAKE_EXE_LINKER_FLAGS} -fsanitize=thread")
endif()

# Find required modules via pkg-config
find_package(PkgConfig REQUIRED)

# 3. Find SPDK & FUSE3
pkg_check_modules(FUSE3 REQUIRED fuse3)

include_directories(include)
include_directories(${FUSE3_INCLUDE_DIRS})

# 4. Define the executable dataplane-emu
add_executable(dataplane-emu 
    src/main.cpp
    src/sq_cq.cpp
    src/fuse_bridge/interceptor.cpp
)

# Link all required libraries
target_link_libraries(dataplane-emu 
    ${FUSE3_LIBRARIES}
    pthread dl uuid numa
)

# 5. Define the executable dataplane_ring
add_executable(dataplane_ring 
    src/dataplane_ring.cpp
)

# Link all required libraries
target_link_libraries(dataplane_ring
    pthread
)