#include "stdafx.h"
#include "ios/jit_pool.hpp"

#ifdef RPCS3_IOS

#include "util/asm.hpp"
#include "util/atomic.hpp"
#include "util/logs.hpp"

#include <libkern/OSCacheControl.h>
#include <mach/mach.h>
#include <sys/mman.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <algorithm>
#include <map>
#include <mutex>

LOG_CHANNEL(jit_pool_log, "JITPool");

namespace utils::jit_pool
{
	char g_error[256] = "no JIT pool was provided (RPCS3_JIT_POOL)";

	uptr g_rx_begin = 0;
	uptr g_rx_end = 0;
	s64 g_rw_delta = 0;

	namespace
	{
		constexpr usz c_page = 0x4000;
		constexpr usz c_global_size = 16 << 20;
		constexpr usz c_rt_data_size = 64 << 20;
		constexpr usz c_llvm_data_size = 128 << 20;

		// Partitions with a bump allocator.
		struct bump_part
		{
			u8* base = nullptr;
			usz size = 0;
			atomic_t<usz> pos{0};
		};

		// Partitions whose memory is returned when its owner goes away (LLVM memory managers).
		struct heap_part
		{
			u8* base = nullptr;
			usz size = 0;
			std::mutex mtx;
			std::map<uptr, usz> free; // begin -> size, coalesced
			usz used = 0;
			usz peak = 0;
		};

		struct pool_state
		{
			bool ok = false;
			bump_part bumps[3]{}; // global_code, rt_code, rt_data
			heap_part heaps[2]{}; // llvm_code, llvm_data

			pool_state()
			{
				const char* env = std::getenv("RPCS3_JIT_POOL");

				unsigned long long rx = 0, rw = 0, size = 0;

				if (!env || std::sscanf(env, "%llx,%llx,%llx", &rx, &rw, &size) != 3 || !rx || !rw || size < (64 << 20))
				{
					std::snprintf(g_error, sizeof(g_error), "RPCS3_JIT_POOL is missing or invalid (%s)", env ? env : "unset");
					std::fprintf(stderr, "[jit-pool] %s\n", g_error);
					return;
				}

				size &= ~(c_page - 1);

				// Data that JIT code reaches PC-relatively must be writable and within ADRP range
				// (+-4 GiB) of the code. Preferably a separate RW reservation near the pool; on a
				// crowded map, the tail of the pool itself, used through its RW alias (which is
				// as close to the code as the alias is to the pool).
				const usz data_size = c_rt_data_size + c_llvm_data_size;
				u8* data = reserve_near(rx, size, data_size);
				const char* data_where = "separate";

				if (!data)
				{
					if (size < data_size + c_global_size + (128 << 20))
					{
						std::snprintf(g_error, sizeof(g_error), "the JIT pool (%llu MiB) is too small to also hold %zu MiB of data", size >> 20, data_size >> 20);
						std::fprintf(stderr, "[jit-pool] %s\n", g_error);
						return;
					}

					const s64 delta = static_cast<s64>(rw - rx);
					const u64 dist = delta < 0 ? 0 - static_cast<u64>(delta) : static_cast<u64>(delta);

					if (dist + size >= 0xF000'0000)
					{
						std::snprintf(g_error, sizeof(g_error), "no room for JIT data near the pool at 0x%llx, and its alias at 0x%llx is too far", rx, rw);
						std::fprintf(stderr, "[jit-pool] %s\n", g_error);
						return;
					}

					size -= data_size;
					data = reinterpret_cast<u8*>(rw + size);
					data_where = "in the pool's alias";
				}

				// Code: global runtime first, then jit_runtime code and LLVM code.
				const usz rest = size - c_global_size;
				usz rt_code = utils::align<usz>(rest * rt_code_percent() / 100, c_page);

				u8* const prx = reinterpret_cast<u8*>(rx);
				bumps[0].base = prx;
				bumps[0].size = c_global_size;
				bumps[1].base = prx + c_global_size;
				bumps[1].size = rt_code;
				bumps[2].base = data;
				bumps[2].size = c_rt_data_size;

				heaps[0].base = prx + c_global_size + rt_code;
				heaps[0].size = rest - rt_code;
				heaps[1].base = data + c_rt_data_size;
				heaps[1].size = c_llvm_data_size;

				for (auto& h : heaps)
				{
					h.free.emplace(reinterpret_cast<uptr>(h.base), h.size);
				}

				g_rx_begin = rx;
				g_rx_end = rx + size;
				g_rw_delta = static_cast<s64>(rw - rx);
				ok = true;

				std::fprintf(stderr, "[jit-pool] RX 0x%llx-0x%llx (%llu MiB), RW alias 0x%llx, data 0x%llx (%zu MiB, %s); global %zu MiB, jit_runtime %zu MiB, LLVM %zu MiB\n",
					rx, rx + size, size >> 20, rw, static_cast<unsigned long long>(reinterpret_cast<uptr>(data)), data_size >> 20, data_where,
					c_global_size >> 20, rt_code >> 20, (rest - rt_code) >> 20);
			}

			static usz rt_code_percent()
			{
				if (const char* s = std::getenv("RPCS3_JIT_RT_PERCENT"))
				{
					const long v = std::strtol(s, nullptr, 10);

					if (v >= 10 && v <= 90)
					{
						return static_cast<usz>(v);
					}
				}

				return 40;
			}

			static u8* try_fixed(uptr addr, usz size)
			{
				vm_address_t a = addr;

				if (vm_allocate(mach_task_self(), &a, size, VM_FLAGS_FIXED) == KERN_SUCCESS)
				{
					if (a == addr)
					{
						return reinterpret_cast<u8*>(a);
					}

					vm_deallocate(mach_task_self(), a, size);
				}

				return nullptr;
			}

			// The first free hole of `size` bytes such that pool and arena together span less
			// than 4 GiB (ADRP reaches +-4 GiB), found by walking the VM map.
			static u8* reserve_near(uptr rx, usz rx_size, usz size)
			{
				constexpr u64 reach = 0xF000'0000; // 3.75 GiB, a margin below ADRP's 4 GiB
				const uptr lo = rx + rx_size > reach ? rx + rx_size - reach : 0x1'0000'0000;
				const uptr hi = rx + reach;

				uptr at = std::max<uptr>(lo, 0x1'0000'0000);

				while (at + size <= hi)
				{
					vm_address_t region = at;
					vm_size_t region_size = 0;
					vm_region_basic_info_data_64_t info;
					mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
					mach_port_t object = MACH_PORT_NULL;

					const kern_return_t kr = vm_region_64(mach_task_self(), &region, &region_size, VM_REGION_BASIC_INFO_64, reinterpret_cast<vm_region_info_t>(&info), &count, &object);

					// The hole is [at, next mapped region)
					const uptr hole_end = kr == KERN_SUCCESS ? static_cast<uptr>(region) : hi;
					const uptr start = utils::align<uptr>(at, c_page);

					if (hole_end > start && hole_end - start >= size && start + size <= hi)
					{
						if (u8* p = try_fixed(start, size))
						{
							return p;
						}
					}

					if (kr != KERN_SUCCESS)
					{
						break;
					}

					at = static_cast<uptr>(region + region_size);
				}

				return nullptr;
			}
		};

		pool_state& state()
		{
			static pool_state s;
			return s;
		}

		u8* heap_alloc(heap_part& h, usz size)
		{
			size = utils::align(size, c_page);

			std::lock_guard lock(h.mtx);

			for (auto it = h.free.begin(); it != h.free.end(); ++it)
			{
				if (it->second >= size)
				{
					const uptr addr = it->first;
					const usz left = it->second - size;
					h.free.erase(it);

					if (left)
					{
						h.free.emplace(addr + size, left);
					}

					h.used += size;
					h.peak = std::max(h.peak, h.used);
					return reinterpret_cast<u8*>(addr);
				}
			}

			return nullptr;
		}

		void heap_free(heap_part& h, u8* ptr, usz size)
		{
			size = utils::align(size, c_page);
			uptr addr = reinterpret_cast<uptr>(ptr);

			std::lock_guard lock(h.mtx);

			h.used -= size;

			auto next = h.free.lower_bound(addr);

			if (next != h.free.begin())
			{
				auto prev = std::prev(next);

				if (prev->first + prev->second == addr)
				{
					addr = prev->first;
					size += prev->second;
					h.free.erase(prev);
				}
			}

			if (next != h.free.end() && addr + size == next->first)
			{
				size += next->second;
				h.free.erase(next);
			}

			h.free.emplace(addr, size);
		}

		bump_part* as_bump(part p)
		{
			switch (p)
			{
			case part::global_code: return &state().bumps[0];
			case part::rt_code: return &state().bumps[1];
			case part::rt_data: return &state().bumps[2];
			default: return nullptr;
			}
		}

		heap_part* as_heap(part p)
		{
			switch (p)
			{
			case part::llvm_code: return &state().heaps[0];
			case part::llvm_data: return &state().heaps[1];
			default: return nullptr;
			}
		}
	}

	bool available() noexcept
	{
		return state().ok;
	}

	const char* error() noexcept
	{
		return state().ok ? "" : g_error;
	}

	u8* alloc(part p, usz size, usz align) noexcept
	{
		if (!state().ok)
		{
			std::fprintf(stderr, "[jit-pool] allocation of %zu bytes without a JIT pool\n", size);
			return nullptr;
		}

		align = align ? align : 16;

		if (heap_part* h = as_heap(p))
		{
			u8* r = heap_alloc(*h, size);

			if (!r)
			{
				jit_pool_log.error("Partition %u exhausted (size=0x%x, used=0x%x of 0x%x)", static_cast<u32>(p), size, h->used, h->size);
			}

			return r;
		}

		bump_part& b = *as_bump(p);

		const auto [pos, ok] = b.pos.fetch_op([&](usz& v)
		{
			const usz start = utils::align(v, align);

			if (start + size > b.size || start + size < start)
			{
				return false;
			}

			v = start + size;
			return true;
		});

		if (!ok)
		{
			jit_pool_log.error("Partition %u exhausted (size=0x%x, used=0x%x of 0x%x)", static_cast<u32>(p), size, pos, b.size);
			return nullptr;
		}

		return b.base + utils::align(pos, align);
	}

	void free(part p, u8* ptr, usz size) noexcept
	{
		if (heap_part* h = as_heap(p); h && ptr)
		{
			heap_free(*h, ptr, size);
		}
	}

	u8* base(part p) noexcept
	{
		if (auto* b = as_bump(p))
			return b->base;
		return as_heap(p)->base;
	}

	u8* top(part p) noexcept
	{
		if (auto* b = as_bump(p))
			return b->base + b->pos.load();
		return as_heap(p)->base + as_heap(p)->peak;
	}

	usz capacity(part p) noexcept
	{
		if (auto* b = as_bump(p))
			return b->size;
		return as_heap(p)->size;
	}

	void reset(part p) noexcept
	{
		if (auto* b = as_bump(p))
		{
			b->pos = 0;
			return;
		}

		heap_part& h = *as_heap(p);
		std::lock_guard lock(h.mtx);

		if (h.used)
		{
			jit_pool_log.warning("Partition %u reset with 0x%x bytes still allocated", static_cast<u32>(p), h.used);
		}

		h.free.clear();
		h.free.emplace(reinterpret_cast<uptr>(h.base), h.size);
		h.used = 0;
	}

	void flush(const void* rx, usz size) noexcept
	{
		sys_icache_invalidate(const_cast<void*>(rx), size);
	}

	void report() noexcept
	{
		if (!state().ok)
		{
			return;
		}

		auto& s = state();
		jit_pool_log.notice("JIT pool usage: global %u/%u KiB, jit_runtime code %u/%u MiB, data %u/%u MiB, LLVM code %u (peak %u)/%u MiB, LLVM data %u (peak %u)/%u MiB",
			s.bumps[0].pos.load() >> 10, s.bumps[0].size >> 10,
			s.bumps[1].pos.load() >> 20, s.bumps[1].size >> 20,
			s.bumps[2].pos.load() >> 20, s.bumps[2].size >> 20,
			s.heaps[0].used >> 20, s.heaps[0].peak >> 20, s.heaps[0].size >> 20,
			s.heaps[1].used >> 20, s.heaps[1].peak >> 20, s.heaps[1].size >> 20);
	}
}

#endif // RPCS3_IOS
