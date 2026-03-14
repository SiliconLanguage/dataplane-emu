cmake_minimum_required(VERSION 3.15)

# Name your project and specify C++ as the language
project(dataplane-emu VERSION 0.1.0 LANGUAGES CXX)

# Enforce C++20 standard
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED True)
set(CMAKE_CXX_EXTENSIONS False) # Disable compiler-specific extensions (e.g., gnu++20) for strict standard compliance

# Set the C and C++ compilers to clang-19
set(CMAKE_C_COMPILER clang-19)
set(CMAKE_CXX_COMPILER clang++-19)

# # Set compiler flags for ThreadSanitizer
# set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -fsanitize=thread -O2 -g -Wall -Wextra")
# set(CMAKE_EXE_LINKER_FLAGS "${CMAKE_EXE_LINKER_FLAGS} -fsanitize=thread")

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