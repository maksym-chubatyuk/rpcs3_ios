#pragma once

// Loads RPCS3Core.framework from the app bundle with dlopen() and forwards to its C interface
// (core/rpcs3_ios.h). The framework is not linked: its static initializers emit
// JIT code, so it may only be loaded once rpcs3_jit_acquire() has succeeded.

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*core_event_fn)(int event);
typedef void (*core_progress_fn)(void* ctx, uint32_t done, uint32_t total);

bool core_load(char* error, size_t error_size);
bool core_is_loaded(void);

int core_jit_available(void);
int core_initialize(core_event_fn events);
const char* core_emulator_dir(void);
const char* core_firmware_version(void);
int core_install_firmware(const char* pup_path, core_progress_fn progress, void* ctx, char* error, uint32_t error_size);
int core_install_pkg(const char* pkg_path);
// Same layout as rpcs3_ios_pad (core/rpcs3_ios.h)
typedef struct core_pad
{
	uint32_t buttons;
	float lx, ly, rx, ry;
	float l2, r2;
} core_pad;

void core_set_pad(const core_pad* pad);
void core_set_render_view(void* uiview, int32_t width, int32_t height, double refresh_rate);
int core_boot(const char* path);
void core_pause(void);
void core_resume(void);
void core_stop(void);
int core_state(void);

// Settings (see rpcs3_ios_settings in core/rpcs3_ios.h). core_settings returns JSON to release with core_free.
char* core_settings(const char* game);
int core_setting_set(const char* game, const char* path, const char* value, char* error, size_t error_size);
int core_setting_reset(const char* game, const char* path, char* error, size_t error_size);
void core_free(void* pointer);

#ifdef __cplusplus
}
#endif
