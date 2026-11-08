#pragma once

// C interface between the iOS app (Swift) and the RPCS3 emulator core.
//
// The core is loaded with dlopen() only after the app has obtained its JIT pool (see
// ios/jit_pool.hpp): its static initializers already emit code into that pool. The app passes
// the pool to the core in the RPCS3_JIT_POOL environment variable before loading it.
//
// Unless noted otherwise, call these from the main thread.

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*rpcs3_ios_log_fn)(int level, const char* message);
typedef void (*rpcs3_ios_progress_fn)(void* ctx, uint32_t done, uint32_t total);
typedef void (*rpcs3_ios_event_fn)(int event); // rpcs3_ios_event

enum rpcs3_ios_event
{
	RPCS3_IOS_EVENT_READY = 1,
	RPCS3_IOS_EVENT_RUN = 2,
	RPCS3_IOS_EVENT_PAUSE = 3,
	RPCS3_IOS_EVENT_RESUME = 4,
	RPCS3_IOS_EVENT_STOP = 5,
	RPCS3_IOS_EVENT_MISSING_FIRMWARE = 6,
	// Stopped only to boot again in the same game screen: after a savestate is saved (and the game
	// resumed from it), a savestate reloaded, or a restart from RPCS3's home menu. RUN follows.
	RPCS3_IOS_EVENT_RESTART = 7,
};

// 1 if the core found a usable JIT pool. Nothing else works without one.
int rpcs3_ios_jit_available(void);

// Initialize the emulator (config, VFS, callbacks). `events` may be NULL. Returns 0 on success.
int rpcs3_ios_initialize(rpcs3_ios_event_fn events);

// Directory holding config.yml, dev_hdd0 and the other emulator folders (with trailing '/').
const char* rpcs3_ios_emulator_dir(void);

// Where RPCS3 writes its logs (RPCS3.log, TTY.log).
const char* rpcs3_ios_log_dir(void);

// Installed firmware version ("" when none). The string stays valid until the next call.
const char* rpcs3_ios_firmware_version(void);

// Install a PS3UPDAT.PUP. Blocking; call it from a background thread. Returns 0 on success,
// otherwise a negative error code; `error` (may be NULL) receives a short description.
int rpcs3_ios_install_firmware(const char* pup_path, rpcs3_ios_progress_fn progress, void* ctx, char* error, uint32_t error_size);

// Install a .pkg (game, update or DLC). Blocking; call it from a background thread.
int rpcs3_ios_install_pkg(const char* pkg_path);

// Packages (core/packages.cpp), as desktop's "Install Packages/Raps/Edats". What a .pkg holds, as JSON
// to free with rpcs3_ios_free: {"valid": bool, "title", "titleID", "version", "category",
// "type": "game|update|dlc|other", "size": bytes, "installed": installed version or "" or "?",
// "problem": why it cannot go over what is installed, or ""}
char* rpcs3_ios_package_info(const char* path);
// Installs .pkg files (paths separated by '\n') in order, while no game runs. Blocking; call it from a
// background thread. progress(ctx, done, total). 0 on success, -2 for an update that does not fit the
// installed version, -3 when cancelled, -1 otherwise; message says what happened.
int rpcs3_ios_install_packages(const char* paths, rpcs3_ios_progress_fn progress, void* ctx, char* message, size_t message_size);
// Stops the running installation (any thread).
void rpcs3_ios_cancel_install(void);
// A licence (.rap) or .edat file, into the logged-in user's exdata. 0 on success.
int rpcs3_ios_install_license(const char* path, char* message, size_t message_size);
// dev_hdd0/game/: installed games, updates and DLC, each in a folder named after its title ID.
const char* rpcs3_ios_hdd0_game_dir(void);

// The view the game renders into: a UIView whose layer is a CAMetalLayer. Sizes are in pixels.
// Set it before booting; update the size when it changes.
void rpcs3_ios_set_render_view(void* uiview, int32_t width, int32_t height, double refresh_rate);

// Player 1's controller as the app sees it: the on-screen controls merged with any physical
// controller. The core presents it to the game as an SDL virtual gamepad ("RPCS3 Virtual Pad").
enum rpcs3_ios_pad_button
{
	RPCS3_IOS_PAD_CROSS = 1u << 0,
	RPCS3_IOS_PAD_CIRCLE = 1u << 1,
	RPCS3_IOS_PAD_SQUARE = 1u << 2,
	RPCS3_IOS_PAD_TRIANGLE = 1u << 3,
	RPCS3_IOS_PAD_L1 = 1u << 4,
	RPCS3_IOS_PAD_R1 = 1u << 5,
	RPCS3_IOS_PAD_L3 = 1u << 6,
	RPCS3_IOS_PAD_R3 = 1u << 7,
	RPCS3_IOS_PAD_SELECT = 1u << 8,
	RPCS3_IOS_PAD_START = 1u << 9,
	RPCS3_IOS_PAD_PS = 1u << 10,
	RPCS3_IOS_PAD_UP = 1u << 11,
	RPCS3_IOS_PAD_DOWN = 1u << 12,
	RPCS3_IOS_PAD_LEFT = 1u << 13,
	RPCS3_IOS_PAD_RIGHT = 1u << 14,
};

typedef struct rpcs3_ios_pad
{
	uint32_t buttons;          // rpcs3_ios_pad_button bits
	float lx, ly, rx, ry;      // -1...1, +y is up
	float l2, r2;              // 0...1
} rpcs3_ios_pad;

// Any thread. Cheap; call it whenever the state changes.
void rpcs3_ios_set_pad(const rpcs3_ios_pad* pad);

// Boot a game: a disc game folder, an EBOOT.BIN or SELF, or an ISO. Returns game_boot_result (0 = ok).
int rpcs3_ios_boot(const char* path);

// Emulation control.
void rpcs3_ios_pause(void);
void rpcs3_ios_resume(void);
void rpcs3_ios_stop(void);

// Savestates, as RPCS3's home menu makes them. Save: the game continues from the new state
// (or stops, if "Suspend Emulation" mode is set). Load: index 1 is the newest savestate. 0 if not possible.
int rpcs3_ios_save_state(void);
int rpcs3_ios_load_state(int index);

// system_state: 0 stopped, 1 loading, 2 stopping, 3 running, 4 paused, 5 frozen, 6 ready, 7 starting.
int rpcs3_ios_state(void);

// Booting as RPCS3's desktop game menu offers it (core/games.cpp)
enum
{
	RPCS3_IOS_BOOT_NORMAL = 0,      // the game's own settings if it has any, otherwise the global ones
	RPCS3_IOS_BOOT_GLOBAL = 1,      // the global settings, even if the game has its own
	RPCS3_IOS_BOOT_DEFAULT = 2,     // RPCS3's default settings
	RPCS3_IOS_BOOT_CONFIG_FILE = 3, // a config file (config_file)
};
// savestate: a .SAVESTAT file to resume instead of starting the game (NULL or "" for none)
int rpcs3_ios_boot_with(const char* path, const char* title_id, int mode, const char* config_file, const char* savestate);
// Compiles the game's PPU modules without running it ("Create LLVM Cache"); the stop event follows
int rpcs3_ios_create_llvm_cache(const char* path, const char* title_id);
// What a game stores, as JSON (free with rpcs3_ios_free): {"customConfig", "customInput": bool,
// "shaderCache", "ppuCache", "spuCache", "hdd1Cache", "saveData", "installedData", "savestatesSize": bytes,
// "lastSavestate": path or "", "savestates": [{"path", "date", "size", "compatible"}]}
char* rpcs3_ios_game_data(const char* title_id, const char* path);
// Removes one of: "config", "input", "shaders", "ppu", "spu", "hdd1", "caches" (all four),
// "savestates", "savedata", "installed" (updates and DLC on the virtual HDD). 0 on success.
int rpcs3_ios_game_remove(const char* title_id, const char* what);

// Game patches (core/patches.cpp), through RPCS3's patch engine
// The patches that apply to a game (its serial and app version, or "All"), as JSON to free with
// rpcs3_ios_free: [{"hash", "description", "title", "serial", "appVersion" (the keys of the entry),
// "enabled", "author", "notes", "version", "group", "file", "configValues": [{"name", "value", "min",
// "max", "isList", "isInteger", "options": [{"label", "value"}]}]}]
char* rpcs3_ios_patches(const char* title_id, const char* app_version);
// Turns one entry on or off (on turns off the others of its group, as desktop does). 0 on success.
int rpcs3_ios_patch_enable(const char* hash, const char* description, const char* title, const char* serial, const char* app_version, int enabled);
int rpcs3_ios_patch_set_value(const char* hash, const char* description, const char* title, const char* serial, const char* app_version, const char* name, double value);
// The official patches: the URL to ask rpcs3.net (free with rpcs3_ios_free), the patch engine version the
// answer must have, and installing the "patch" text of the answer after checking its "sha256"
char* rpcs3_ios_patch_download_url(void);
const char* rpcs3_ios_patch_engine_version(void);
int rpcs3_ios_patch_install(const char* content, const char* sha256, char* message, size_t message_size);
// Adds the patches of a patch file to imported_patch.yml. Number added, or -1; message says what happened.
int rpcs3_ios_patch_import(const char* path, char* message, size_t message_size);

// Controls (core/controls.cpp): the seven players' input configuration. game: NULL or "" for the
// global controls, or a title ID for that game's own (its first change starts them from the global ones).
// As JSON to free with rpcs3_ios_free: {"running", "gameHasOwn": bool, "devices": [SDL device names],
// "buttons": [SDL button names for mappings], "players": [{"settings": [entries as rpcs3_ios_settings
// describes them, with paths inside the player: ["Handler"], ["Device"], ["Config", "Cross"]...]}]}
// "reset" of a Config entry is the player's handler default.
char* rpcs3_ios_controls(const char* game);
// Sets one entry of a player (0-6). Setting "Handler" also gives the player that handler's defaults.
int rpcs3_ios_control_set(const char* game, int player, const char* path, const char* value, char* error, size_t error_size);

// Users (core/userdata.cpp), in dev_hdd0/home, as desktop's user manager keeps them. Messages say
// what went wrong. {"active": id, "users": [{"id": "00000001", "name"}]}, to free with rpcs3_ios_free.
char* rpcs3_ios_users(void);
// A name has 3 to 16 letters, digits, '_' or '-'. 0 on success, else -1.
int rpcs3_ios_user_create(const char* name, char* message, size_t message_size);
int rpcs3_ios_user_rename(const char* id, const char* name, char* message, size_t message_size);
// Not the logged-in user.
int rpcs3_ios_user_remove(const char* id, char* message, size_t message_size);
// While no game runs. Remembered for the next start.
int rpcs3_ios_user_login(const char* id, char* message, size_t message_size);

// Save data of the logged-in user; serial: NULL or "" for all, or a game's (the directories named after it).
// {"dir": savedata directory, "saves": [{"dir", "title", "subtitle", "details", "listParam",
//  "size": bytes, "modified": Unix time, "icon": path or ""}]}, to free with rpcs3_ios_free.
char* rpcs3_ios_saves(const char* serial);
// Deletes one save directory. 0 on success.
int rpcs3_ios_save_remove(const char* dir);

// Trophies of the logged-in user, by communication ID (NPWR00000_00). To free with rpcs3_ios_free:
// [{"id", "name", "icon", "total", "earned", "platinum"|"gold"|"silver"|"bronze": [earned, total]}]
char* rpcs3_ios_trophy_games(void);
// [{"id": number, "name", "detail", "grade": "platinum|gold|silver|bronze", "hidden", "earned",
//   "time": Unix time or 0, "icon": path or "", "group": "" for the base game, or the add-on's name}]
char* rpcs3_ios_trophies(const char* communication_id);
// As desktop's trophy manager: marks a trophy earned (now) or not. While no game runs. 0 on success.
int rpcs3_ios_trophy_set_earned(const char* communication_id, int trophy_id, int earned);
// Removes a game's trophy data. While no game runs. 0 on success.
int rpcs3_ios_trophy_game_remove(const char* communication_id);

// RPCN, RPCS3's online service (core/rpcn.cpp), as desktop's RPCN dialog. Messages say what happened.
// {"username", "hasPassword", "token", "host", "hosts": [{"name", "host"}]}, to free with rpcs3_ios_free.
char* rpcs3_ios_rpcn(void);
int rpcs3_ios_rpcn_set_host(const char* host);
int rpcs3_ios_rpcn_add_host(const char* name, const char* host, char* message, size_t message_size);
int rpcs3_ios_rpcn_remove_host(const char* name, const char* host);
// An existing account. password: NULL or "" keeps the saved one. 0 on success.
int rpcs3_ios_rpcn_set_account(const char* username, const char* password, const char* token, char* message, size_t message_size);
// These reach the server and block: call them from a background thread. 0 on success, else -1.
int rpcs3_ios_rpcn_create_account(const char* username, const char* password, const char* email, char* message, size_t message_size);
int rpcs3_ios_rpcn_test(char* message, size_t message_size);
int rpcs3_ios_rpcn_resend_token(char* message, size_t message_size);
int rpcs3_ios_rpcn_send_reset_token(const char* username, const char* email, char* message, size_t message_size);
int rpcs3_ios_rpcn_reset_password(const char* username, const char* token, const char* password, char* message, size_t message_size);
int rpcs3_ios_rpcn_delete_account(char* message, size_t message_size);

// Settings (core/settings.cpp). game: NULL or "" for the global settings (config.yml), or a title ID
// for that game's own settings, which RPCS3 applies over the global ones when it boots.
// A setting's path is its names in the config tree, separated by '\n' ("Video\nVulkan\nAdapter").

// All settings as JSON, to free with rpcs3_ios_free:
// {"running": bool, "settings": [{"path": [...], "type": "bool|enum|int|uint|float|string",
//   "value": "...", "reset": "...", "dynamic": bool, "options": [...] | "min"/"max": "...",
//   "overridden": bool (for a game only)}]}
// "reset" is what resetting gives: the default (iOS's where it differs), or the global value for a game.
char* rpcs3_ios_settings(const char* game);
// Sets and saves one setting (value as written in config.yml). 0 on success, else -1 and a message.
int rpcs3_ios_setting_set(const char* game, const char* path, const char* value, char* error, size_t error_size);
// Global: back to the default. Game: back to the global value (the game no longer sets it).
int rpcs3_ios_setting_reset(const char* game, const char* path, char* error, size_t error_size);
void rpcs3_ios_free(void* pointer);

#ifdef __cplusplus
}
#endif
