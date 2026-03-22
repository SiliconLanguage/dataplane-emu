cmake_minimum_required(VERSION 3.15)
project(dataplane-emu CXX C)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED True)

# --- Silicon-Specific Optimization (Azure Cobalt 100) ---
if(CMAKE_SYSTEM_PROCESSOR MATCHES "aarch64|arm64")
    # FIX: Use RESULT_VARIABLE to check grep's exit code (0 = found)
    execute_process(COMMAND grep -qi "0xd49" /proc/cpuinfo RESULT_VARIABLE IS_N2)
    if(IS_N2 EQUAL 0)
        set(ARCH_FLAGS "-mcpu=neoverse-n2")
        message(STATUS "🚀 Target: Azure Cobalt 100 (Neoverse-N2)")
    else()
        set(ARCH_FLAGS "-mcpu=neoverse-v1")
        message(STATUS "🚀 Target: AWS Graviton (Neoverse-V1)")
    endif()
    set(CPU_FLAGS ${ARCH_FLAGS} "-moutline-atomics" "-fallow-store-data-races")
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
target_link_libraries(dataplane-emu PRIVATE project_options ${SPDK_LIBS} ${FUSE3_LIBRARIES} pthread dl uuid numa)

# --- Target: Ring Test ---
add_executable(dataplane-ring-test src/dataplane_ring.cpp)
target_link_libraries(dataplane-ring-test PRIVATE project_options pthread)
