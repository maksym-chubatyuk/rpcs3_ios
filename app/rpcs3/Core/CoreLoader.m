#import "CoreLoader.h"
#import "../JIT/JITPool.h"

#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <stdio.h>

static struct
{
	int (*jit_available)(void);
	int (*initialize)(core_event_fn);
	const char* (*emulator_dir)(void);
	const char* (*firmware_version)(void);
	int (*install_firmware)(const char*, core_progress_fn, void*, char*, uint32_t);
	int (*install_pkg)(const char*);
	void (*set_render_view)(void*, int32_t, int32_t, double);
	void (*set_pad)(const core_pad*);
	int (*boot)(const char*);
	void (*pause)(void);
	void (*resume)(void);
	void (*stop)(void);
	int (*state)(void);
	char* (*settings)(const char*);
	int (*setting_set)(const char*, const char*, const char*, char*, size_t);
	int (*setting_reset)(const char*, const char*, char*, size_t);
	void (*free_memory)(void*);
	int (*boot_with)(const char*, const char*, int, const char*, const char*);
	int (*create_llvm_cache)(const char*, const char*);
	char* (*game_data)(const char*, const char*);
	int (*game_remove)(const char*, const char*);
	char* (*patches)(const char*, const char*);
	int (*patch_enable)(const char*, const char*, const char*, const char*, const char*, int);
	int (*patch_set_value)(const char*, const char*, const char*, const char*, const char*, const char*, double);
	char* (*patch_download_url)(void);
	const char* (*patch_engine_version)(void);
	int (*patch_install)(const char*, const char*, char*, size_t);
	int (*patch_import)(const char*, char*, size_t);
} g_core;

static bool g_loaded;

bool core_is_loaded(void)
{
	return g_loaded;
}

bool core_load(char* error, size_t error_size)
{
	if (g_loaded)
	{
		return true;
	}

	if (!rpcs3_jit_current())
	{
		snprintf(error, error_size, "The emulator core needs JIT; it was not loaded.");
		return false;
	}

	NSString* path = [NSBundle.mainBundle.privateFrameworksPath stringByAppendingPathComponent:@"RPCS3Core.framework/RPCS3Core"];
	void* handle = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);

	if (!handle)
	{
		snprintf(error, error_size, "Loading the emulator core failed: %s", dlerror());
		return false;
	}

#define RESOLVE(field, name)                                                       \
	if (!(*(void**)&g_core.field = dlsym(handle, name)))                          \
	{                                                                              \
		snprintf(error, error_size, "The emulator core has no %s", name);         \
		return false;                                                              \
	}

	RESOLVE(jit_available, "rpcs3_ios_jit_available");
	RESOLVE(initialize, "rpcs3_ios_initialize");
	RESOLVE(emulator_dir, "rpcs3_ios_emulator_dir");
	RESOLVE(firmware_version, "rpcs3_ios_firmware_version");
	RESOLVE(install_firmware, "rpcs3_ios_install_firmware");
	RESOLVE(install_pkg, "rpcs3_ios_install_pkg");
	RESOLVE(set_render_view, "rpcs3_ios_set_render_view");
	RESOLVE(set_pad, "rpcs3_ios_set_pad");
	RESOLVE(boot, "rpcs3_ios_boot");
	RESOLVE(pause, "rpcs3_ios_pause");
	RESOLVE(resume, "rpcs3_ios_resume");
	RESOLVE(stop, "rpcs3_ios_stop");
	RESOLVE(state, "rpcs3_ios_state");
	RESOLVE(settings, "rpcs3_ios_settings");
	RESOLVE(setting_set, "rpcs3_ios_setting_set");
	RESOLVE(setting_reset, "rpcs3_ios_setting_reset");
	RESOLVE(free_memory, "rpcs3_ios_free");
	RESOLVE(boot_with, "rpcs3_ios_boot_with");
	RESOLVE(create_llvm_cache, "rpcs3_ios_create_llvm_cache");
	RESOLVE(game_data, "rpcs3_ios_game_data");
	RESOLVE(game_remove, "rpcs3_ios_game_remove");
	RESOLVE(patches, "rpcs3_ios_patches");
	RESOLVE(patch_enable, "rpcs3_ios_patch_enable");
	RESOLVE(patch_set_value, "rpcs3_ios_patch_set_value");
	RESOLVE(patch_download_url, "rpcs3_ios_patch_download_url");
	RESOLVE(patch_engine_version, "rpcs3_ios_patch_engine_version");
	RESOLVE(patch_install, "rpcs3_ios_patch_install");
	RESOLVE(patch_import, "rpcs3_ios_patch_import");
#undef RESOLVE

	g_loaded = true;
	return true;
}

int core_jit_available(void) { return g_loaded ? g_core.jit_available() : 0; }
int core_initialize(core_event_fn events) { return g_loaded ? g_core.initialize(events) : -1; }
const char* core_emulator_dir(void) { return g_loaded ? g_core.emulator_dir() : ""; }
const char* core_firmware_version(void) { return g_loaded ? g_core.firmware_version() : ""; }

int core_install_firmware(const char* pup_path, core_progress_fn progress, void* ctx, char* error, uint32_t error_size)
{
	return g_loaded ? g_core.install_firmware(pup_path, progress, ctx, error, error_size) : -100;
}

int core_install_pkg(const char* pkg_path) { return g_loaded ? g_core.install_pkg(pkg_path) : -100; }

void core_set_render_view(void* uiview, int32_t width, int32_t height, double refresh_rate)
{
	if (g_loaded) g_core.set_render_view(uiview, width, height, refresh_rate);
}

void core_set_pad(const core_pad* pad)
{
	if (g_loaded) g_core.set_pad(pad);
}

int core_boot(const char* path) { return g_loaded ? g_core.boot(path) : -100; }
void core_pause(void) { if (g_loaded) g_core.pause(); }
void core_resume(void) { if (g_loaded) g_core.resume(); }
void core_stop(void) { if (g_loaded) g_core.stop(); }
int core_state(void) { return g_loaded ? g_core.state() : 0; }

char* core_settings(const char* game) { return g_loaded ? g_core.settings(game) : NULL; }

int core_setting_set(const char* game, const char* path, const char* value, char* error, size_t error_size)
{
	return g_loaded ? g_core.setting_set(game, path, value, error, error_size) : -100;
}

int core_setting_reset(const char* game, const char* path, char* error, size_t error_size)
{
	return g_loaded ? g_core.setting_reset(game, path, error, error_size) : -100;
}

void core_free(void* pointer) { if (g_loaded && pointer) g_core.free_memory(pointer); }

int core_boot_with(const char* path, const char* title_id, int mode, const char* config_file, const char* savestate)
{
	return g_loaded ? g_core.boot_with(path, title_id, mode, config_file, savestate) : -100;
}

int core_create_llvm_cache(const char* path, const char* title_id) { return g_loaded ? g_core.create_llvm_cache(path, title_id) : -100; }
char* core_game_data(const char* title_id, const char* path) { return g_loaded ? g_core.game_data(title_id, path) : NULL; }
int core_game_remove(const char* title_id, const char* what) { return g_loaded ? g_core.game_remove(title_id, what) : -100; }

char* core_patches(const char* title_id, const char* app_version) { return g_loaded ? g_core.patches(title_id, app_version) : NULL; }

int core_patch_enable(const char* hash, const char* description, const char* title, const char* serial, const char* app_version, int enabled)
{
	return g_loaded ? g_core.patch_enable(hash, description, title, serial, app_version, enabled) : -100;
}

int core_patch_set_value(const char* hash, const char* description, const char* title, const char* serial, const char* app_version, const char* name, double value)
{
	return g_loaded ? g_core.patch_set_value(hash, description, title, serial, app_version, name, value) : -100;
}

char* core_patch_download_url(void) { return g_loaded ? g_core.patch_download_url() : NULL; }
const char* core_patch_engine_version(void) { return g_loaded ? g_core.patch_engine_version() : ""; }
int core_patch_install(const char* content, const char* sha256, char* message, size_t message_size) { return g_loaded ? g_core.patch_install(content, sha256, message, message_size) : -100; }
int core_patch_import(const char* path, char* message, size_t message_size) { return g_loaded ? g_core.patch_import(path, message, message_size) : -100; }
