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
	char* (*controls)(const char*);
	int (*control_set)(const char*, int, const char*, const char*, char*, size_t);
	char* (*users)(void);
	int (*user_create)(const char*, char*, size_t);
	int (*user_rename)(const char*, const char*, char*, size_t);
	int (*user_remove)(const char*, char*, size_t);
	int (*user_login)(const char*, char*, size_t);
	char* (*saves)(const char*);
	int (*save_remove)(const char*);
	char* (*trophy_games)(void);
	char* (*trophies)(const char*);
	int (*trophy_set_earned)(const char*, int, int);
	int (*trophy_game_remove)(const char*);
	char* (*package_info)(const char*);
	int (*install_packages)(const char*, void (*)(void*, uint32_t, uint32_t), void*, char*, size_t);
	void (*cancel_install)(void);
	int (*install_license)(const char*, char*, size_t);
	const char* (*hdd0_game_dir)(void);
	char* (*rpcn)(void);
	int (*rpcn_set_host)(const char*);
	int (*rpcn_add_host)(const char*, const char*, char*, size_t);
	int (*rpcn_remove_host)(const char*, const char*);
	int (*rpcn_set_account)(const char*, const char*, const char*, char*, size_t);
	int (*rpcn_create_account)(const char*, const char*, const char*, char*, size_t);
	int (*rpcn_test)(char*, size_t);
	int (*rpcn_resend_token)(char*, size_t);
	int (*rpcn_send_reset_token)(const char*, const char*, char*, size_t);
	int (*rpcn_reset_password)(const char*, const char*, const char*, char*, size_t);
	int (*rpcn_delete_account)(char*, size_t);
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
	RESOLVE(controls, "rpcs3_ios_controls");
	RESOLVE(control_set, "rpcs3_ios_control_set");
	RESOLVE(users, "rpcs3_ios_users");
	RESOLVE(user_create, "rpcs3_ios_user_create");
	RESOLVE(user_rename, "rpcs3_ios_user_rename");
	RESOLVE(user_remove, "rpcs3_ios_user_remove");
	RESOLVE(user_login, "rpcs3_ios_user_login");
	RESOLVE(saves, "rpcs3_ios_saves");
	RESOLVE(save_remove, "rpcs3_ios_save_remove");
	RESOLVE(trophy_games, "rpcs3_ios_trophy_games");
	RESOLVE(trophies, "rpcs3_ios_trophies");
	RESOLVE(trophy_set_earned, "rpcs3_ios_trophy_set_earned");
	RESOLVE(trophy_game_remove, "rpcs3_ios_trophy_game_remove");
	RESOLVE(package_info, "rpcs3_ios_package_info");
	RESOLVE(install_packages, "rpcs3_ios_install_packages");
	RESOLVE(cancel_install, "rpcs3_ios_cancel_install");
	RESOLVE(install_license, "rpcs3_ios_install_license");
	RESOLVE(hdd0_game_dir, "rpcs3_ios_hdd0_game_dir");
	RESOLVE(rpcn, "rpcs3_ios_rpcn");
	RESOLVE(rpcn_set_host, "rpcs3_ios_rpcn_set_host");
	RESOLVE(rpcn_add_host, "rpcs3_ios_rpcn_add_host");
	RESOLVE(rpcn_remove_host, "rpcs3_ios_rpcn_remove_host");
	RESOLVE(rpcn_set_account, "rpcs3_ios_rpcn_set_account");
	RESOLVE(rpcn_create_account, "rpcs3_ios_rpcn_create_account");
	RESOLVE(rpcn_test, "rpcs3_ios_rpcn_test");
	RESOLVE(rpcn_resend_token, "rpcs3_ios_rpcn_resend_token");
	RESOLVE(rpcn_send_reset_token, "rpcs3_ios_rpcn_send_reset_token");
	RESOLVE(rpcn_reset_password, "rpcs3_ios_rpcn_reset_password");
	RESOLVE(rpcn_delete_account, "rpcs3_ios_rpcn_delete_account");
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

char* core_controls(const char* game) { return g_loaded ? g_core.controls(game) : NULL; }

int core_control_set(const char* game, int player, const char* path, const char* value, char* error, size_t error_size)
{
	return g_loaded ? g_core.control_set(game, player, path, value, error, error_size) : -100;
}

char* core_users(void) { return g_loaded ? g_core.users() : NULL; }
int core_user_create(const char* name, char* message, size_t message_size) { return g_loaded ? g_core.user_create(name, message, message_size) : -100; }
int core_user_rename(const char* user, const char* name, char* message, size_t message_size) { return g_loaded ? g_core.user_rename(user, name, message, message_size) : -100; }
int core_user_remove(const char* user, char* message, size_t message_size) { return g_loaded ? g_core.user_remove(user, message, message_size) : -100; }
int core_user_login(const char* user, char* message, size_t message_size) { return g_loaded ? g_core.user_login(user, message, message_size) : -100; }
char* core_saves(const char* serial) { return g_loaded ? g_core.saves(serial) : NULL; }
int core_save_remove(const char* dir) { return g_loaded ? g_core.save_remove(dir) : -100; }
char* core_trophy_games(void) { return g_loaded ? g_core.trophy_games() : NULL; }
char* core_trophies(const char* communication_id) { return g_loaded ? g_core.trophies(communication_id) : NULL; }
int core_trophy_set_earned(const char* communication_id, int trophy, int earned) { return g_loaded ? g_core.trophy_set_earned(communication_id, trophy, earned) : -100; }
int core_trophy_game_remove(const char* communication_id) { return g_loaded ? g_core.trophy_game_remove(communication_id) : -100; }
char* core_package_info(const char* path) { return g_loaded ? g_core.package_info(path) : NULL; }
int core_install_packages(const char* paths, void (*progress)(void*, uint32_t, uint32_t), void* ctx, char* message, size_t message_size)
{
	return g_loaded ? g_core.install_packages(paths, progress, ctx, message, message_size) : -100;
}
void core_cancel_install(void) { if (g_loaded) g_core.cancel_install(); }
int core_install_license(const char* path, char* message, size_t message_size) { return g_loaded ? g_core.install_license(path, message, message_size) : -100; }
const char* core_hdd0_game_dir(void) { return g_loaded ? g_core.hdd0_game_dir() : ""; }
char* core_rpcn(void) { return g_loaded ? g_core.rpcn() : NULL; }
int core_rpcn_set_host(const char* host) { return g_loaded ? g_core.rpcn_set_host(host) : -100; }
int core_rpcn_add_host(const char* name, const char* host, char* message, size_t message_size) { return g_loaded ? g_core.rpcn_add_host(name, host, message, message_size) : -100; }
int core_rpcn_remove_host(const char* name, const char* host) { return g_loaded ? g_core.rpcn_remove_host(name, host) : -100; }
int core_rpcn_set_account(const char* username, const char* password, const char* token, char* message, size_t message_size) { return g_loaded ? g_core.rpcn_set_account(username, password, token, message, message_size) : -100; }
int core_rpcn_create_account(const char* username, const char* password, const char* email, char* message, size_t message_size) { return g_loaded ? g_core.rpcn_create_account(username, password, email, message, message_size) : -100; }
int core_rpcn_test(char* message, size_t message_size) { return g_loaded ? g_core.rpcn_test(message, message_size) : -100; }
int core_rpcn_resend_token(char* message, size_t message_size) { return g_loaded ? g_core.rpcn_resend_token(message, message_size) : -100; }
int core_rpcn_send_reset_token(const char* username, const char* email, char* message, size_t message_size) { return g_loaded ? g_core.rpcn_send_reset_token(username, email, message, message_size) : -100; }
int core_rpcn_reset_password(const char* username, const char* token, const char* password, char* message, size_t message_size) { return g_loaded ? g_core.rpcn_reset_password(username, token, password, message, message_size) : -100; }
int core_rpcn_delete_account(char* message, size_t message_size) { return g_loaded ? g_core.rpcn_delete_account(message, message_size) : -100; }
