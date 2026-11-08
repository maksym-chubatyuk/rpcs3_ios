#include "JITPool.h"

#include <errno.h>
#include <libkern/OSCacheControl.h>
#include <mach/mach.h>
#include <os/log.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ucontext.h>
#include <unistd.h>

#define JIT_PAGE 0x4000u
#define BRK_JIT 0xd43e01a0u /* brk #0xf00d */

#define CS_OPS_STATUS 0
#define CS_DEBUGGED 0x10000000u
extern int csops(pid_t pid, unsigned int ops, void* useraddr, size_t usersize);

static rpcs3_jit_pool g_pool;
static bool g_have_pool;

static void fail(char* error, size_t error_size, const char* fmt, ...)
{
	char buf[512];
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(buf, sizeof(buf), fmt, ap);
	va_end(ap);

	os_log_error(OS_LOG_DEFAULT, "[jit] %{public}s", buf);
	fprintf(stderr, "[jit] %s\n", buf);

	if (error && error_size)
	{
		snprintf(error, error_size, "%s", buf);
	}
}

bool rpcs3_jit_is_debugged(void)
{
	uint32_t flags = 0;
	return csops(getpid(), CS_OPS_STATUS, &flags, sizeof(flags)) == 0 && (flags & CS_DEBUGGED);
}

// A request nobody answers (CS_DEBUGGED is set, but the debugger is gone) would kill the app on
// SIGTRAP. Skip our own brk and report 0 instead; leave every other trap alone.
static void jit_trap_handler(int sig, siginfo_t* info, void* context)
{
	(void)info;
	ucontext_t* uc = (ucontext_t*)context;
	const uint64_t pc = uc->uc_mcontext->__ss.__pc;

	if ((pc & 3) == 0 && *(const uint32_t*)(uintptr_t)pc == BRK_JIT)
	{
		uc->uc_mcontext->__ss.__pc = pc + 4;
		uc->uc_mcontext->__ss.__x[0] = 0;
		return;
	}

	signal(sig, SIG_DFL);
}

static void install_trap_handler(void)
{
	struct sigaction sa;
	memset(&sa, 0, sizeof(sa));
	sa.sa_flags = SA_SIGINFO;
	sa.sa_sigaction = jit_trap_handler;
	sigaction(SIGTRAP, &sa, NULL);
}

__attribute__((noinline)) static uintptr_t debugger_prepare(uintptr_t addr, size_t size)
{
	register uintptr_t x0 __asm__("x0") = addr;
	register size_t x1 __asm__("x1") = size;
	__asm__ volatile("mov x16, #1\n\tbrk #0xf00d" : "+r"(x0) : "r"(x1) : "x16", "memory");
	return x0;
}

__attribute__((noinline)) static void debugger_detach(void)
{
	__asm__ volatile("mov x16, #0\n\tbrk #0xf00d" ::: "x16", "x0", "x1", "memory");
}

// Every VM entry in [addr, addr + size) must be mapped and executable. The debugger's writes
// split its region into many small entries, so this walks them all.
static bool range_is_executable(uintptr_t addr, size_t size, vm_prot_t* bad_prot, uintptr_t* bad_at)
{
	uintptr_t at = addr;

	while (at < addr + size)
	{
		vm_address_t a = at;
		vm_size_t s = 0;
		vm_region_basic_info_data_64_t info;
		mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
		mach_port_t object = MACH_PORT_NULL;

		if (vm_region_64(mach_task_self(), &a, &s, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &count, &object) != KERN_SUCCESS || a > at)
		{
			*bad_prot = 0;
			*bad_at = at;
			return false;
		}

		if (!(info.protection & VM_PROT_EXECUTE))
		{
			*bad_prot = info.protection;
			*bad_at = at;
			return false;
		}

		at = a + s;
	}

	return true;
}

int rpcs3_jit_acquire(size_t size, bool detach, rpcs3_jit_pool* out, char* error, size_t error_size)
{
	if (g_have_pool)
	{
		*out = g_pool;
		return 0;
	}

	if (!rpcs3_jit_is_debugged())
	{
		fail(error, error_size, "No debugger has attached (CS_DEBUGGED is not set). Enable JIT first.");
		return -1;
	}

	size = (size + JIT_PAGE - 1) & ~(size_t)(JIT_PAGE - 1);
	install_trap_handler();

	// 1. The debugger allocates the region and writes into every page of it
	const uintptr_t rx = debugger_prepare(0, size);

	if (!rx || (rx & (JIT_PAGE - 1)))
	{
		// 0: nobody answered. Unaligned: x0 was left with something that is not an address.
		fail(error, error_size, "The debugger did not provide executable memory (returned 0x%lx). Is it running a JIT script?", (unsigned long)rx);
		return -2;
	}

	vm_prot_t bad_prot = 0;
	uintptr_t bad_at = 0;

	if (!range_is_executable(rx, size, &bad_prot, &bad_at))
	{
		fail(error, error_size, "The debugger's region 0x%lx+0x%lx is not executable at 0x%lx (prot=%d)", (unsigned long)rx, (unsigned long)size, (unsigned long)bad_at, bad_prot);
		debugger_detach();
		return -3;
	}

	// 2. Writable alias of the same pages
	vm_address_t rw = 0;
	vm_prot_t cur = 0, max = 0;
	kern_return_t kr = vm_remap(mach_task_self(), &rw, size, 0, VM_FLAGS_ANYWHERE, mach_task_self(), rx, FALSE, &cur, &max, VM_INHERIT_NONE);

	if (kr != KERN_SUCCESS)
	{
		fail(error, error_size, "vm_remap of the JIT region failed: %s (%d)", mach_error_string(kr), kr);
		debugger_detach();
		return -4;
	}

	kr = vm_protect(mach_task_self(), rw, size, FALSE, VM_PROT_READ | VM_PROT_WRITE);

	if (kr != KERN_SUCCESS)
	{
		fail(error, error_size, "Making the JIT alias writable failed: %s (%d, max_prot=%d)", mach_error_string(kr), kr, max);
		vm_deallocate(mach_task_self(), rw, size);
		debugger_detach();
		return -5;
	}

	// 3. Write a function through the alias and run it from the executable view.
	// The last page is used so nothing the core puts at the start is disturbed.
	const uint32_t probe[] = {0xd2800540u /* mov x0, #42 */, 0xd65f03c0u /* ret */};
	const size_t off = size - JIT_PAGE;
	memcpy((void*)(rw + off), probe, sizeof(probe));
	sys_icache_invalidate((void*)(rx + off), sizeof(probe));

	const long result = ((long (*)(void))(rx + off))();
	memset((void*)(rw + off), 0, sizeof(probe));

	if (result != 42)
	{
		fail(error, error_size, "Code written through the JIT alias did not run correctly (got %ld)", result);
		debugger_detach();
		return -6;
	}

	// 4. The pool is everything this process will get: the debugger may go
	if (detach)
	{
		debugger_detach();
	}

	g_pool.rx = rx;
	g_pool.rw = rw;
	g_pool.size = size;
	g_have_pool = true;

	char env[96];
	snprintf(env, sizeof(env), "%lx,%lx,%lx", (unsigned long)rx, (unsigned long)rw, (unsigned long)size);
	setenv("RPCS3_JIT_POOL", env, 1);

	os_log(OS_LOG_DEFAULT, "[jit] pool RX 0x%lx RW 0x%lx size %lu MiB", (unsigned long)rx, (unsigned long)rw, (unsigned long)(size >> 20));
	fprintf(stderr, "[jit] pool RX 0x%lx RW 0x%lx size %lu MiB\n", (unsigned long)rx, (unsigned long)rw, (unsigned long)(size >> 20));

	*out = g_pool;
	return 0;
}

const rpcs3_jit_pool* rpcs3_jit_current(void)
{
	return g_have_pool ? &g_pool : NULL;
}
