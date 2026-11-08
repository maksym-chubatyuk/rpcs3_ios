#pragma once

// Force-included into every translation unit of the iOS build (see CMake: RPCS3_IOS).
//
// iOS has no MAP_JIT for third-party apps and marks pthread_jit_write_protect_np unavailable.
// Executable memory comes from the debugger-prepared pool instead (ios/jit_pool.hpp), and code
// is written through its RW alias, so the per-thread W^X toggles have nothing to do.

#include <pthread.h>

#ifdef __cplusplus
inline void rpcs3_ios_jit_write_protect(int) noexcept {}
#else
static inline void rpcs3_ios_jit_write_protect(int unused) { (void)unused; }
#endif

#define pthread_jit_write_protect_np(enabled) rpcs3_ios_jit_write_protect(enabled)
