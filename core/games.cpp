// Per-game actions for the app, as RPCS3's desktop game list offers them (rpcs3qt/game_list_actions.cpp):
// booting with another configuration or from a savestate, building the PPU cache ahead of time,
// what a game stores and removing it. Through the C functions in rpcs3_ios.h.

#include "stdafx.h"
#include "rpcs3_ios.h"

#include "Emu/System.h"
#include "Emu/system_config.h"
#include "Emu/system_utils.hpp"
#include "Emu/Io/pad_config.h"
#include "Utilities/File.h"

#include <cstdlib>
#include <cstring>

LOG_CHANNEL(games_log, "Games");

std::string get_savestate_file(std::string_view title_id, std::string_view boot_path, s64 rel_id, u64 aggregate_file_size);
bool is_savestate_compatible(const std::string& filepath);

// rpcs3_ios.mm: boots with the app's render view and the test hooks
int ios_boot_game(const std::string& path, const std::string& title_id, cfg_mode mode, const std::string& config_path);

namespace
{
	std::string text(const char* value)
	{
		return value ? value : "";
	}

	char* copy_string(const std::string& value)
	{
		char* out = static_cast<char*>(std::malloc(value.size() + 1));
		std::memcpy(out, value.c_str(), value.size() + 1);
		return out;
	}

	std::string json_string(std::string_view value)
	{
		std::string out = "\"";

		for (const char c : value)
		{
			switch (c)
			{
			case '"': out += "\\\""; break;
			case '\\': out += "\\\\"; break;
			case '\n': out += "\\n"; break;
			default:
				if (static_cast<u8>(c) < 0x20)
					out += fmt::format("\\u%04x", static_cast<u8>(c));
				else
					out += c;
			}
		}

		return out + "\"";
	}

	u64 dir_size(const std::string& path)
	{
		const u64 size = fs::get_dir_size(path, 1);
		return size == umax ? 0 : size;
	}

	// Files under dir (recursively) whose names match one of the patterns ("v*.obj": prefix and suffix)
	template <typename F>
	void for_each_file(const std::string& dir, const std::vector<std::pair<std::string_view, std::string_view>>& patterns, F&& f)
	{
		for (const auto& entry : fs::dir(dir))
		{
			if (entry.name == "." || entry.name == "..")
				continue;

			const std::string path = dir + "/" + entry.name;

			if (entry.is_directory)
			{
				for_each_file(path, patterns, f);
				continue;
			}

			for (const auto& [prefix, suffix] : patterns)
			{
				if (entry.name.starts_with(prefix) && entry.name.ends_with(suffix))
				{
					f(path, entry.size);
					break;
				}
			}
		}
	}

	// Folders under dir (recursively) with this name
	template <typename F>
	void for_each_dir_named(const std::string& dir, std::string_view name, F&& f)
	{
		for (const auto& entry : fs::dir(dir))
		{
			if (!entry.is_directory || entry.name == "." || entry.name == "..")
				continue;

			const std::string path = dir + "/" + entry.name;

			if (entry.name == name)
				f(path);
			else
				for_each_dir_named(path, name, f);
		}
	}

	// The caches as desktop's game list removes them
	const std::vector<std::pair<std::string_view, std::string_view>> ppu_cache_files = {{"v", ".obj"}, {"v", ".obj.gz"}};
	const std::vector<std::pair<std::string_view, std::string_view>> spu_cache_files = {{"spu", ".dat"}, {"spu", ".dat.gz"}, {"spu", ".obj"}, {"spu", ".obj.gz"}};

	u64 files_size(const std::string& dir, const std::vector<std::pair<std::string_view, std::string_view>>& patterns)
	{
		u64 total = 0;
		for_each_file(dir, patterns, [&](const std::string&, u64 size) { total += size; });
		return total;
	}

	bool remove_files(const std::string& dir, const std::vector<std::pair<std::string_view, std::string_view>>& patterns)
	{
		bool ok = true;
		for_each_file(dir, patterns, [&](const std::string& path, u64) { ok = fs::remove_file(path) && ok; });
		return ok;
	}

	u64 shader_cache_size(const std::string& dir)
	{
		u64 total = 0;
		for_each_dir_named(dir, "shaders_cache", [&](const std::string& path) { total += dir_size(path); });
		return total;
	}

	// Folders in parent whose names start with the title ID (save data, installed content, HDD1 caches)
	std::vector<std::string> dirs_of(const std::string& parent, const std::string& serial)
	{
		std::vector<std::string> dirs;

		for (const auto& entry : fs::dir(parent))
		{
			if (entry.is_directory && entry.name.starts_with(serial))
				dirs.push_back(parent + entry.name);
		}

		return dirs;
	}

	std::string savedata_dir()
	{
		return rpcs3::utils::get_hdd0_dir() + "home/" + Emu.GetUsr() + "/savedata/";
	}

	u64 dirs_size(const std::vector<std::string>& dirs)
	{
		u64 total = 0;
		for (const std::string& dir : dirs)
			total += dir_size(dir);
		return total;
	}

	bool remove_dirs(const std::vector<std::string>& dirs)
	{
		bool ok = true;
		for (const std::string& dir : dirs)
			ok = fs::remove_all(dir) && ok;
		return ok;
	}

	bool remove_if_empty(const std::string& dir)
	{
		return !fs::is_dir(dir) || !fs::dir(dir) || fs::get_dir_size(dir) != 0 || fs::remove_all(dir);
	}
}

extern "C" int rpcs3_ios_boot_with(const char* path, const char* title_id, int mode, const char* config_file, const char* savestate)
{
	// What desktop's game menu offers: the game's own settings if it has any (otherwise the global
	// ones), the global ones even if it has its own, RPCS3's defaults, or a chosen config file
	cfg_mode config_mode = cfg_mode::custom;

	switch (mode)
	{
	case RPCS3_IOS_BOOT_GLOBAL: config_mode = cfg_mode::database_config; break; // no database: global
	case RPCS3_IOS_BOOT_DEFAULT: config_mode = cfg_mode::default_config; break;
	case RPCS3_IOS_BOOT_CONFIG_FILE: config_mode = cfg_mode::custom_selection; break;
	default: break;
	}

	const std::string state = text(savestate);
	games_log.notice("Booting %s (mode %d, config '%s', savestate '%s')", text(path), mode, text(config_file), state);
	return ios_boot_game(state.empty() ? text(path) : state, text(title_id), config_mode, text(config_file));
}

extern "C" int rpcs3_ios_create_llvm_cache(const char* path, const char* title_id)
{
	// As desktop's "Create LLVM Cache": boots the game only to compile its PPU modules, then stops
	Emu.GracefulShutdown(false);
	Emu.SetForceBoot(true);
	Emu.SetPrecompileCacheOption(emu_precompilation_option_t{.is_fast = false});

	std::string game = text(path);

	if (fs::is_file(game))
	{
		game = fs::get_parent_dir(game);
	}

	// RPCS3 compiles <game>/USRDIR/EBOOT.BIN: for a disc game that is inside PS3_GAME
	if (fs::is_file(game + "/PS3_GAME/USRDIR/EBOOT.BIN"))
	{
		game += "/PS3_GAME";
	}

	if (const auto error = Emu.BootGame(game, text(title_id), true); error != game_boot_result::no_errors)
	{
		games_log.error("Could not create the LLVM cache of %s: %s", game, error);
		return static_cast<int>(error);
	}

	games_log.notice("Creating the LLVM cache of %s", game);
	return 0;
}

extern "C" char* rpcs3_ios_game_data(const char* title_id, const char* path)
{
	const std::string serial = text(title_id);
	const std::string cache = rpcs3::utils::get_cache_dir_by_serial(serial);

	// Savestates of this game, newest first
	std::string savestates = "[";
	{
		std::vector<std::pair<s64, std::string>> files;
		const std::string dir = rpcs3::utils::get_savestates_dir(serial);

		for (const auto& entry : fs::dir(dir))
		{
			if (!entry.is_directory && entry.name.ends_with(".SAVESTAT"))
				files.emplace_back(entry.mtime, dir + entry.name);
		}

		std::sort(files.begin(), files.end(), std::greater<>());

		for (const auto& [mtime, file] : files)
		{
			fs::stat_t info{};
			fs::get_stat(file, info);
			savestates += fmt::format("%s{\"path\":%s,\"date\":%d,\"size\":%u,\"compatible\":%s}", savestates.size() > 1 ? "," : "",
				json_string(file), mtime, info.size, is_savestate_compatible(file) ? "true" : "false");
		}
	}
	savestates += "]";

	std::string last = get_savestate_file(serial, text(path), 1, umax);

	if (!last.empty() && !is_savestate_compatible(last))
	{
		last.clear();
	}

	const std::string json = fmt::format(
		"{\"customConfig\":%s,\"customInput\":%s,\"shaderCache\":%u,\"ppuCache\":%u,\"spuCache\":%u,\"hdd1Cache\":%u,"
		"\"saveData\":%u,\"installedData\":%u,\"savestatesSize\":%u,\"lastSavestate\":%s,\"savestates\":%s}",
		fs::is_file(rpcs3::utils::get_custom_config_path(serial)) ? "true" : "false",
		fs::is_dir(rpcs3::utils::get_input_config_dir(serial)) ? "true" : "false",
		shader_cache_size(cache), files_size(cache, ppu_cache_files), files_size(cache, spu_cache_files),
		dirs_size(dirs_of(rpcs3::utils::get_hdd1_cache_dir(), serial)),
		dirs_size(dirs_of(savedata_dir(), serial)),
		dirs_size(dirs_of(rpcs3::utils::get_hdd0_game_dir(), serial)),
		dir_size(rpcs3::utils::get_savestates_dir(serial)),
		json_string(last), savestates);

	return copy_string(json);
}

extern "C" int rpcs3_ios_game_remove(const char* title_id, const char* what)
{
	const std::string serial = text(title_id);
	const std::string item = text(what);
	const std::string cache = rpcs3::utils::get_cache_dir_by_serial(serial);

	if (serial.empty() || !Emu.IsStopped())
	{
		games_log.error("Not removing %s of '%s' while a game runs", item, serial);
		return -1;
	}

	const auto remove_shader_caches = [&]()
	{
		bool ok = true;
		for_each_dir_named(cache, "shaders_cache", [&](const std::string& dir) { ok = fs::remove_all(dir) && ok; });
		return ok;
	};

	bool ok = false;

	if (item == "config")
	{
		const std::string file = rpcs3::utils::get_custom_config_path(serial);
		ok = !fs::is_file(file) || fs::remove_file(file);
	}
	else if (item == "input")
	{
		g_cfg_input_configs.load();
		g_cfg_input_configs.active_configs.erase(serial);
		g_cfg_input_configs.save();
		const std::string dir = rpcs3::utils::get_input_config_dir(serial);
		ok = !fs::is_dir(dir) || fs::remove_all(dir);
	}
	else if (item == "shaders")
		ok = remove_shader_caches();
	else if (item == "ppu")
		ok = remove_files(cache, ppu_cache_files);
	else if (item == "spu")
		ok = remove_files(cache, spu_cache_files);
	else if (item == "hdd1")
		ok = remove_dirs(dirs_of(rpcs3::utils::get_hdd1_cache_dir(), serial));
	else if (item == "caches")
	{
		const bool shaders = remove_shader_caches();
		const bool ppu = remove_files(cache, ppu_cache_files);
		const bool spu = remove_files(cache, spu_cache_files);
		const bool hdd1 = remove_dirs(dirs_of(rpcs3::utils::get_hdd1_cache_dir(), serial));
		ok = shaders && ppu && spu && hdd1;
	}
	else if (item == "savestates")
	{
		const std::string dir = rpcs3::utils::get_savestates_dir(serial);
		ok = !fs::is_dir(dir) || fs::remove_all(dir);
	}
	else if (item == "savedata")
		ok = remove_dirs(dirs_of(savedata_dir(), serial));
	else if (item == "installed")
		ok = remove_dirs(dirs_of(rpcs3::utils::get_hdd0_game_dir(), serial));
	else
		games_log.error("Unknown item to remove: %s", item);

	remove_if_empty(cache);
	(ok ? games_log.notice : games_log.error)("Removing %s of %s: %s", item, serial, ok ? "done" : "failed");
	return ok ? 0 : -1;
}
