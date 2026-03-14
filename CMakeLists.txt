cmake_minimum_required(VERSION 3.15)

# Name your project and specify C++ as the language
project(dataplane-emu VERSION 0.1.0 LANGUAGES CXX)

# Enforce C++20 standard
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED True)
set(CMAKE_CXX_EXTENSIONS False) # Disable compiler-specific extensions (e.g., gnu++20) for strict standard compliance

# Find the system threading library (required for std::thread on Linux/WSL)
find_package(Threads REQUIRED)

# ---------------------------------------------------------
# Define the main executable
# ---------------------------------------------------------
add_executable(SpdkSimulator
    src/main.cpp
    src/sq_cq.cpp
)

# Tell CMake where to find your public headers
# This allows you to do: #include <dataplane_emu/sq_cq.hpp>
target_include_directories(SpdkSimulator PUBLIC include)

# Link the threading library to your executable
target_link_libraries(SpdkSimulator PRIVATE Threads::Threads)