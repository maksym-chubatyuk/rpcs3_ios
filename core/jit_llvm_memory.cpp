#include "stdafx.h"
#include "ios/jit_llvm_memory.hpp"
#include "ios/jit_pool.hpp"
#include "Utilities/JIT.h"
#include "util/asm.hpp"

#ifdef _MSC_VER
#pragma warning(push, 0)
#else
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wall"
#pragma GCC diagnostic ignored "-Wextra"
#pragma GCC diagnostic ignored "-Wold-style-cast"
#pragma GCC diagnostic ignored "-Wunused-parameter"
#pragma GCC diagnostic ignored "-Wmissing-noreturn"
#endif
#include "llvm/ExecutionEngine/RTDyldMemoryManager.h"
#include "llvm/ExecutionEngine/RuntimeDyld.h"
#include "llvm/Object/ObjectFile.h"
#ifdef _MSC_VER
#pragma warning(pop)
#else
#pragma GCC diagnostic pop
#endif

#include <vector>

LOG_CHANNEL(jit_pool_llvm_log, "JIT");

namespace
{
// Executable memory comes from the debugger-prepared pool (ios/jit_pool.hpp). RuntimeDyld writes
// each section where we say (the pool's RW alias) and computes relocations against the address
// given with mapSectionAddress (the RX address). Data sections live in the RW arena next to the
// pool, so ADRP reaches them from code.
struct MemoryManagerPool : llvm::RTDyldMemoryManager
{
	// true: jit_runtime memory, kept until emulation stops (role of MemoryManager2)
	// false: own chunks, returned to the pool with this manager (role of MemoryManager1)
	const bool m_runtime;

	std::function<u64(const std::string&)> m_symbols_cement;
	u64 (*m_null_function)(const std::string&);

	struct chunk
	{
		u8* base = nullptr;
		usz size = 0;
		usz pos = 0;
	};

	chunk m_code{}, m_data{};
	std::vector<std::pair<u8*, usz>> m_owned_code, m_owned_data;
	std::vector<std::pair<const void*, u64>> m_pending; // section RW address -> RX address
	std::vector<std::pair<u8*, usz>> m_unflushed;       // RX ranges written since the last finalize

	static constexpr usz c_chunk = 1 << 20;

	using llvm::RTDyldMemoryManager::notifyObjectLoaded;

	MemoryManagerPool(bool runtime, std::function<u64(const std::string&)> symbols_cement, u64 (*null_function)(const std::string&)) noexcept
		: m_runtime(runtime)
		, m_symbols_cement(std::move(symbols_cement))
		, m_null_function(null_function)
	{
	}

	MemoryManagerPool(const MemoryManagerPool&) = delete;

	MemoryManagerPool& operator=(const MemoryManagerPool&) = delete;

	~MemoryManagerPool() override
	{
		for (auto [ptr, size] : m_owned_code)
			utils::jit_pool::free(utils::jit_pool::part::llvm_code, ptr, size);
		for (auto [ptr, size] : m_owned_data)
			utils::jit_pool::free(utils::jit_pool::part::llvm_data, ptr, size);
	}

	llvm::JITSymbol findSymbol(const std::string& name) override
	{
		u64 addr = RTDyldMemoryManager::getSymbolAddress(name);

		if (!addr && m_symbols_cement)
		{
			addr = m_symbols_cement(name);
		}

		if (!addr)
		{
			addr = m_null_function(name);

			if (!addr)
			{
				fmt::throw_exception("Failed to link '%s' (pool)", name);
			}
		}

		return {addr, llvm::JITSymbolFlags::Exported};
	}

	static u8* sub_alloc(chunk& c, std::vector<std::pair<u8*, usz>>& owned, utils::jit_pool::part part, usz size, usz align)
	{
		align = std::max<usz>(align ? align : 16, 16);

		if (align > 0x4000)
		{
			jit_pool_llvm_log.fatal("Unsupported alignment (size=0x%x, align=0x%x)", size, align);
			return nullptr;
		}

		usz start = utils::align(c.pos, align);

		if (!c.base || start + size > c.size)
		{
			const usz csize = utils::align<usz>(std::max<usz>(size, c_chunk), 0x4000);
			u8* const ptr = utils::jit_pool::alloc(part, csize, 0x4000);

			if (!ptr)
			{
				fmt::throw_exception("JIT pool exhausted (part=%u, size=0x%x)", static_cast<u32>(part), size);
			}

			owned.emplace_back(ptr, csize);
			c = {ptr, csize, 0};
			start = 0;
		}

		c.pos = start + size;
		return c.base + start;
	}

	u8* allocateCodeSection(uptr size, uint align, uint /*sec_id*/, llvm::StringRef /*sec_name*/) override
	{
		u8* const rx = m_runtime
			? jit_runtime::alloc(size, align ? align : 16, true)
			: sub_alloc(m_code, m_owned_code, utils::jit_pool::part::llvm_code, size, align);

		if (!rx)
		{
			fmt::throw_exception("JIT pool exhausted (code, size=0x%x)", size);
		}

		u8* const rw = utils::jit_pool::rw(rx);
		m_pending.emplace_back(rw, reinterpret_cast<u64>(rx));
		m_unflushed.emplace_back(rx, size);
		return rw;
	}

	u8* allocateDataSection(uptr size, uint align, uint /*sec_id*/, llvm::StringRef /*sec_name*/, bool /*is_ro*/) override
	{
		u8* const ptr = m_runtime
			? jit_runtime::alloc(size, align ? align : 16, false)
			: sub_alloc(m_data, m_owned_data, utils::jit_pool::part::llvm_data, size, align);

		if (!ptr)
		{
			fmt::throw_exception("JIT pool exhausted (data, size=0x%x)", size);
		}

		return ptr;
	}

	void notifyObjectLoaded(llvm::RuntimeDyld& dyld, const llvm::object::ObjectFile& /*obj*/) override
	{
		// Relocations are resolved later (finalizeObject), against these addresses
		for (auto [rw, rx] : m_pending)
		{
			dyld.mapSectionAddress(rw, rx);
		}

		m_pending.clear();
	}

	bool finalizeMemory(std::string* = nullptr) override
	{
		for (auto [rx, size] : m_unflushed)
		{
			utils::jit_pool::flush(rx, size);
		}

		m_unflushed.clear();
		return false;
	}

	void registerEHFrames(u8*, u64, usz) override
	{
	}

	void deregisterEHFrames() override
	{
	}
};
}

namespace ios_jit
{
	std::unique_ptr<llvm::RTDyldMemoryManager> make_llvm_memory_manager(bool runtime,
		std::function<u64(const std::string&)> symbols_cement, u64 (*null_function)(const std::string&))
	{
		return std::make_unique<MemoryManagerPool>(runtime, std::move(symbols_cement), null_function);
	}
}
