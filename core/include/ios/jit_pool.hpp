#pragma once

// Executable memory for platforms where the process cannot create it itself (iOS 26+).
//
// On iOS a debugger allocates one RX region for the app and writes into each page of it,
// which is what makes the pages executable under TXM. The app maps a second, RW view of
// the same memory (the "alias") and writes generated code there. The host app does both
// before the emulator core is loaded and hands the result over in RPCS3_JIT_POOL
// ("<rx hex>,<rw hex>,<size hex>"). Nothing in this file talks to a debugger.
//
// All executable memory comes from that pool, split into fixed partitions, and code is
// written through rw(ptr). Data that JIT code addresses PC-relatively lives in a normal RW
// arena reserved next to the pool, within ADRP range of all of it.
//
// On other platforms the pool does not exist and rw() returns its argument unchanged.

#include "util/types.hpp"

namespace utils::jit_pool
{
	enum class part : u32
	{
		global_code, // asmjit global runtime (gateways, trampolines); never reset
		rt_code,     // jit_runtime code; reset to its post-init snapshot when emulation stops
		rt_data,     // jit_runtime data (e.g. the SPU dispatcher)
		llvm_code,   // code sections of LLVM objects; reset when emulation stops
		llvm_data,   // data sections of LLVM objects
		count
	};

#ifdef RPCS3_IOS
	// True when the host app provided a pool (always expected on iOS; the core cannot run without one).
	bool available() noexcept;

	// Why the pool is not available ("" when it is).
	const char* error() noexcept;

	// Allocate from a partition; code partitions return RX addresses. nullptr when it is full.
	u8* alloc(part p, usz size, usz align) noexcept;

	// Return memory to an LLVM partition (other partitions are only reset as a whole).
	void free(part p, u8* ptr, usz size) noexcept;

	// Base and current top of a partition.
	u8* base(part p) noexcept;
	u8* top(part p) noexcept;
	usz capacity(part p) noexcept;

	// Forget all allocations in a partition (memory contents are kept).
	void reset(part p) noexcept;

	// Bounds of the RX pool and the distance from it to its RW alias.
	extern uptr g_rx_begin;
	extern uptr g_rx_end;
	extern s64 g_rw_delta;

	// Make freshly written code visible to instruction fetch (takes the RX address).
	void flush(const void* rx, usz size) noexcept;

	// Writable alias of an address inside the pool; other addresses are returned unchanged.
	template <typename T>
	inline T* rw(T* ptr) noexcept
	{
		const uptr p = reinterpret_cast<uptr>(ptr);

		if (p - g_rx_begin < g_rx_end - g_rx_begin)
		{
			return reinterpret_cast<T*>(p + g_rw_delta);
		}

		return ptr;
	}

	// Usage summary for logs.
	void report() noexcept;
#else
	constexpr bool available() noexcept
	{
		return false;
	}

	template <typename T>
	constexpr T* rw(T* ptr) noexcept
	{
		return ptr;
	}

	inline void flush(const void*, usz) noexcept
	{
	}
#endif
}
