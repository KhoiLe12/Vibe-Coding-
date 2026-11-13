// Copyright 2026 The Pocket Studio Authors
// SPDX-License-Identifier: Apache-2.0
//
// Lock-free single-producer / single-consumer ring of floats.
// The producer is the audio thread; the consumer is the writer thread.
// No allocation after construction, no locks, no system calls.

#ifndef PS_RING_BUFFER_H
#define PS_RING_BUFFER_H

#include <algorithm>
#include <atomic>
#include <cstddef>
#include <cstring>
#include <memory>

namespace ps {

class SpscRing {
 public:
  // capacity must be a power of two.
  explicit SpscRing(size_t capacity)
      : buffer_(new float[capacity]), capacity_(capacity), mask_(capacity - 1) {}

  size_t capacity() const { return capacity_; }

  // Only call when neither side is active.
  void reset() {
    head_.store(0, std::memory_order_relaxed);
    tail_.store(0, std::memory_order_relaxed);
  }

  size_t available() const {
    return head_.load(std::memory_order_acquire) -
           tail_.load(std::memory_order_acquire);
  }

  // Producer. Writes up to n samples; returns how many fit.
  size_t write(const float* src, size_t n) {
    const size_t head = head_.load(std::memory_order_relaxed);
    const size_t tail = tail_.load(std::memory_order_acquire);
    n = std::min(n, capacity_ - (head - tail));
    const size_t start = head & mask_;
    const size_t first = std::min(n, capacity_ - start);
    std::memcpy(buffer_.get() + start, src, first * sizeof(float));
    std::memcpy(buffer_.get(), src + first, (n - first) * sizeof(float));
    head_.store(head + n, std::memory_order_release);
    return n;
  }

  // Consumer. Reads up to n samples; returns how many were read.
  size_t read(float* dst, size_t n) {
    const size_t tail = tail_.load(std::memory_order_relaxed);
    const size_t head = head_.load(std::memory_order_acquire);
    n = std::min(n, head - tail);
    const size_t start = tail & mask_;
    const size_t first = std::min(n, capacity_ - start);
    std::memcpy(dst, buffer_.get() + start, first * sizeof(float));
    std::memcpy(dst + first, buffer_.get(), (n - first) * sizeof(float));
    tail_.store(tail + n, std::memory_order_release);
    return n;
  }

 private:
  std::unique_ptr<float[]> buffer_;
  const size_t capacity_;
  const size_t mask_;
  alignas(64) std::atomic<size_t> head_{0};
  alignas(64) std::atomic<size_t> tail_{0};
};

}  // namespace ps

#endif  // PS_RING_BUFFER_H
