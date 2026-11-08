#pragma once

// Executable memory on iOS 26+ (TXM): an attached debugger allocates a region and writes into
// each of its pages, which is what lets them execute. The app then maps a second, writable view
// of the same memory and generates code through it.
//
// Requests to the debugger use the protocol StikDebug's universal script and scripts/jit_host.py
// understand: `brk #0xf00d` with the command in x16 (1 = prepare region: x0 address or 0 to
// allocate, x1 size, result in x0; 0 = detach).

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct rpcs3_jit_pool
{
	uintptr_t rx;   // executable view (as allocated by the debugger)
	uintptr_t rw;   // writable alias of the same pages
	size_t size;
} rpcs3_jit_pool;

// True once a debugger has attached to this process (CS_DEBUGGED). Stays set after it detaches.
bool rpcs3_jit_is_debugged(void);

// Ask the attached debugger for `size` bytes (rounded to 16 KiB pages), map the RW alias, check
// that code written through it runs, then ask the debugger to detach (when `detach` is true).
// On success fills `out`, sets RPCS3_JIT_POOL for the emulator core and returns 0. On failure
// returns a negative code and writes a reason into `error`.
int rpcs3_jit_acquire(size_t size, bool detach, rpcs3_jit_pool* out, char* error, size_t error_size);

// The pool acquired by this process, or NULL.
const rpcs3_jit_pool* rpcs3_jit_current(void);

#ifdef __cplusplus
}
#endif
