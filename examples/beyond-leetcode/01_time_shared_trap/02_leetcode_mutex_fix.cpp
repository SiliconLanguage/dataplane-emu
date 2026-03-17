#include <iostream>
#include <thread>
#include <mutex>
#include <condition_variable>
constexpr int NUM_MESSAGES = 1'000'000;

static constexpr size_t CAPACITY = 1024; // Must be power of 2
struct Queue {
    int buffer[CAPACITY];
    size_t head = 0;
    size_t tail = 0;
    std::mutex mtx;
    std::condition_variable cv;
};

// Static inline for preallocation in .bss
static inline Queue q;

void producer() {
    for (int i = 0; i < NUM_MESSAGES; ++i) {
        std::unique_lock<std::mutex> lock(q.mtx);
        q.buffer[q.head & (CAPACITY - 1)] = 100; // Bitwise masking
        q.head++;
        q.cv.notify_one();
    }
}

void consumer() {
    for (int i = 0; i < NUM_MESSAGES; ++i) {

        std::unique_lock<std::mutex> lock(q.mtx);
        q.cv.wait(lock, [] { return q.head != q.tail; });
        volatile int val = q.buffer[q.tail & (CAPACITY - 1)]; // Prevent optimization
        (void)val; // Suppress unused variable warning
        q.tail++;
    }

    std::cout << "Consumed: " << NUM_MESSAGES << " messages." << std::endl;
}

int main() {
    std::thread c(consumer);
    std::thread p(producer);
    p.join(); c.join();
    return 0;
}