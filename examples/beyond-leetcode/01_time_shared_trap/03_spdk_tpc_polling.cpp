#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <iostream>
#include <thread>
#include <iostream>
#include <thread>
#include <atomic>
#include <pthread.h>
constexpr int NUM_MESSAGES = 1'000'000;

std::atomic<bool> ready{false};

void pin_to_core(int core_id) {
    cpu_set_t cpuset;
    CPU_ZERO(&cpuset);
    CPU_SET(core_id, &cpuset);
    pthread_setaffinity_np(pthread_self(), sizeof(cpu_set_t), &cpuset);
}

void producer() {
    pin_to_core(0);
    
    for (int i = 0; i < NUM_MESSAGES; ++i) {
        ready.store(true, std::memory_order_release);
    }
}

void consumer() {
    pin_to_core(1);
    for (int i = 0; i < NUM_MESSAGES; ++i) {
        while (!ready.load(std::memory_order_acquire)); // Safe and efficient under TPC
    }

    std::cout << "TPC Consumer signaled." << std::endl;
}

int main() {
    std::thread c(consumer);
    std::thread p(producer);
    p.join(); c.join();
    return 0;
}