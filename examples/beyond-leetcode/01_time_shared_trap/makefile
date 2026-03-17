#CXX = g++
# Set compiler to clang++ for better support of sanitizers and static analysis tools
CXX = clang++
CXXFLAGS = -std=c++17 -O3 -Wall -Wextra
LDFLAGS = -pthread

# Uncomment the line below to enable Thread Sanitizer for debugging races
# DEBUG_FLAGS = -fsanitize=thread
DEBUG_FLAGS =""

TARGETS = 01_naive_spin_trap 02_leetcode_mutex_fix 03_spdk_tpc_polling

all: $(TARGETS)

01_naive_spin_trap: 01_naive_spin_trap.cpp
	$(CXX) $(CXXFLAGS) $(DEBUG_FLAGS) -o $@ $< $(LDFLAGS) $(DEBUG_FLAGS)

02_leetcode_mutex_fix: 02_leetcode_mutex_fix.cpp
	$(CXX) $(CXXFLAGS) $(DEBUG_FLAGS) -o $@ $< $(LDFLAGS) $(DEBUG_FLAGS)

03_spdk_tpc_polling: 03_spdk_tpc_polling.cpp
	$(CXX) $(CXXFLAGS) $(DEBUG_FLAGS) -o $@ $< $(LDFLAGS) $(DEBUG_FLAGS)

clean:
	rm -f $(TARGETS)

.PHONY: all clean