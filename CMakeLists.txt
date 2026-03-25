cmake_minimum_required(VERSION 3.15)
project(dataplane-emu CXX C)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED True)

# --- Explicit Silicon-Specific Optimization Mapping ---
# Set via command line: cmake -DTARGET_SILICON=GRAVITON3 ..
set(TARGET_SILICON "GENERIC" CACHE STRING "Target Silicon (ARM_NEOVERSE_N2, GRAVITON2, GRAVITON3, GRAVITON4, GENERIC)")

if(CMAKE_SYSTEM_PROCESSOR MATCHES "aarch64|arm64")
    if(TARGET_SILICON STREQUAL "ARM_NEOVERSE_N2")
        set(ARCH_FLAGS "-mcpu=neoverse-n2")
        message(STATUS "🚀 Target: Azure Arm Neoverse-N2 (Neoverse-N2)")
        
    elseif(TARGET_SILICON STREQUAL "GRAVITON4")
        set(ARCH_FLAGS "-mcpu=neoverse-v2")
        message(STATUS "🚀 Target: AWS Graviton4 (Neoverse-V2)")
        
    elseif(TARGET_SILICON STREQUAL "GRAVITON3")
        set(ARCH_FLAGS "-mcpu=neoverse-v1")
        message(STATUS "🚀 Target: AWS Graviton3 (Neoverse-V1)")
        
    elseif(TARGET_SILICON STREQUAL "GRAVITON2")
        set(ARCH_FLAGS "-mcpu=neoverse-n1")
        message(STATUS "🚀 Target: AWS Graviton2 (Neoverse-N1)")
        
    else()
        # AWS Recommended balanced flag for all modern ARM64
        set(ARCH_FLAGS "-march=armv8.2-a")
        message(STATUS "🚀 Target: Generic ARM64v8.2-a")
    endif()

    # Apply outline-atomics for runtime LSE detection
    set(CPU_FLAGS ${ARCH_FLAGS} "-moutline-atomics")
else()
    set(CPU_FLAGS "-march=native")
endif()

# --- Common Options ---
add_library(project_options INTERFACE)
target_compile_options(project_options INTERFACE -O3 ${CPU_FLAGS})
target_compile_definitions(project_options INTERFACE _FILE_OFFSET_BITS=64)

find_package(PkgConfig REQUIRED)
pkg_check_modules(FUSE3 REQUIRED fuse3)

# --- SPDK & DPDK Library Resolution ---
set(SPDK_LIB_DIR "${CMAKE_CURRENT_SOURCE_DIR}/spdk/build/lib")
set(DPDK_LIB_DIR "${CMAKE_CURRENT_SOURCE_DIR}/spdk/dpdk/build/lib")
link_directories(${SPDK_LIB_DIR} ${DPDK_LIB_DIR})

set(SPDK_LIBS 
    spdk_nvme spdk_env_dpdk rte_eal rte_mempool 
    rte_ring rte_mbuf rte_telemetry rte_kvargs 
    rte_net rte_ethdev rte_pci rte_bus_pci
)

# --- Target: Data Plane Emulator ---
add_executable(dataplane-emu
    src/main.cpp
    src/sq_cq.cpp
    src/fuse_bridge/interceptor.cpp
)
target_include_directories(dataplane-emu PRIVATE include "${CMAKE_CURRENT_SOURCE_DIR}/spdk/include" ${FUSE3_INCLUDE_DIRS})
target_link_libraries(dataplane-emu PRIVATE project_options ${FUSE3_LIBRARIES} pthread dl)

# --- Target: Ring Test ---
add_executable(dataplane-ring-test src/dataplane_ring.cpp)
target_link_libraries(dataplane-ring-test PRIVATE project_options pthread)

# --- Target: LD_PRELOAD Interception Library ---
add_library(dataplane-intercept SHARED src/intercept.cpp src/sq_cq.cpp)
target_include_directories(dataplane-intercept PRIVATE include)
target_compile_definitions(dataplane-intercept PRIVATE _GNU_SOURCE)
target_compile_options(dataplane-intercept PRIVATE -O3 ${CPU_FLAGS} -fPIC)
target_link_libraries(dataplane-intercept PRIVATE dl pthread)
set_target_properties(dataplane-intercept PROPERTIES
    OUTPUT_NAME "dataplane_intercept"
    PREFIX "lib"
)
