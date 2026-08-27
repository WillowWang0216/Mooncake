#pragma once

#include <cstddef>

namespace mooncake {

void* ub_allocate_memory(size_t alignment, size_t total_size);

// Same as ub_allocate_memory but binds the allocation to a specific NUMA node
// (numa_node < 0 falls back to node-local). Still allocated via libnuma and
// registered in the store-memory range table, so URMA can register it.
void* ub_allocate_memory_onnode(size_t alignment, size_t total_size,
                                int numa_node);

// Allocate GPU device memory using CUDA Driver API for UB GDR mode.
// device_id < 0 keeps the current device/context.
void* ub_allocate_memory_gdr(size_t total_size, int device_id = -1);

void ub_free_memory(void* ptr);
void ub_free_memory_gdr(void* ptr);
bool ub_is_gdr_memory(void* ptr);

bool ub_is_store_memory(void* addr, size_t length);

}  // namespace mooncake
