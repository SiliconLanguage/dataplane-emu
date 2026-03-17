#include <iostream>
#include <thread>
#include <atomic>
#include <vector>

std::atomic<bool> flag{false};
std::atomic<int> data{0};

void producer() {
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
    data.store(42, std::memory_order_relaxed);
    flag.store(true, std::memory_order_release);
}

void consumer(int id) {
    // Naive lock-free spin-loop: Burns CPU time-slice
    while (!flag.load(std::memory_order_acquire)); 
    if (id == 0) std::cout << "Consumer received: " << data.load() << std::endl;
}

int main() {
    unsigned int cores = std::thread::hardware_concurrency();
    std::vector<std::thread> consumers;

    // Oversubscribe: Spawn more threads than cores to force starvation
    for (unsigned int i = 0; i < cores + 100; ++i) {
        consumers.emplace_back(consumer, i);
    }
    std::thread p(producer);

    p.join();
    for (auto& t : consumers) t.join();
    return 0;
}