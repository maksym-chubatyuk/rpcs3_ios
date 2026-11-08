#pragma once

// The LLVM memory manager for iOS, which places code in the JIT pool (ios/jit_pool.hpp).
// RPCS3's jit_compiler picks it instead of its own managers (patches/0003-jit-llvm-pool.patch).

#include "util/types.hpp"

#include <functional>
#include <memory>
#include <string>

namespace llvm
{
	class RTDyldMemoryManager;
}

namespace ios_jit
{
	// runtime: code lives as long as jit_runtime memory (until emulation stops), as RPCS3's
	// MemoryManager2; otherwise in chunks returned to the pool with the manager (MemoryManager1).
	// null_function: RPCS3's fallback for symbols it cannot resolve.
	std::unique_ptr<llvm::RTDyldMemoryManager> make_llvm_memory_manager(bool runtime,
		std::function<u64(const std::string&)> symbols_cement, u64 (*null_function)(const std::string&));
}
