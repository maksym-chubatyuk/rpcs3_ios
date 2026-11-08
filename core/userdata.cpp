// Users, save data and trophies for the app, as RPCS3's desktop managers handle them
// (rpcs3qt/user_manager_dialog.cpp, save_manager_dialog.cpp, trophy_manager_dialog.cpp).
//
// Everything lives in dev_hdd0/home/<user id>/: savedata/<directory>/ (PARAM.SFO, ICON0.PNG and
// the game's files) and trophy/<communication id>/ (TROPCONF.SFM, TROPUSR.DAT, TROPxxx.PNG).

#include "stdafx.h"
#include "rpcs3_ios.h"
#include "ios/config_json.hpp"
#include "ios/userdata.hpp"

#include "Emu/System.h"
#include "Emu/system_config.h"
#include "Emu/system_utils.hpp"
#include "Emu/VFS.h"
#include "Emu/Cell/Modules/cellRtc.h"
#include "Emu/Cell/Modules/sceNpTrophy.h"
#include "Loader/PSF.h"
#include "Loader/TROPUSR.h"
#include "Utilities/File.h"

#include <regex>

LOG_CHANNEL(userdata_log, "Userdata");

using ios_config::copy_string;
using ios_config::json_string;

namespace
{
	std::string text(const char* value)
	{
		return value ? value : "";
	}

	int fail(char* out, size_t size, const std::string& message)
	{
		userdata_log.error("%s", message);
		if (out && size) std::snprintf(out, size, "%s", message.c_str());
		return -1;
	}

	std::string home_dir()
	{
		return rpcs3::utils::get_hdd0_dir() + "home/";
	}

	// Where the app remembers who is logged in (desktop keeps it in its persistent GUI settings)
	std::string active_user_file()
	{
		return fs::get_config_dir() + "active_user.txt";
	}

	bool is_user(const std::string& id)
	{
		return rpcs3::utils::check_user(id) > 0 && fs::is_file(home_dir() + id + "/localusername");
	}

	std::string username(const std::string& id)
	{
		std::string name;
		if (const fs::file file{home_dir() + id + "/localusername"})
			name = file.to_string();
		return name.substr(0, 16); // a PS3 name is at most 16 characters (as desktop crops it)
	}

	// As desktop: 3 to 16 letters, digits, underscores and hyphens
	bool valid_name(const std::string& name)
	{
		static const std::regex pattern("^[A-Za-z0-9_-]{3,16}$");
		return std::regex_match(name, pattern);
	}

	std::string json_number(u64 value)
	{
		return std::to_string(value);
	}

	// PS3 ticks (microseconds since 0001-01-01, UTC) as Unix seconds, 0 for none
	s64 unix_time(u64 tick)
	{
		return tick > RTC_MAGIC_OFFSET ? static_cast<s64>((tick - RTC_MAGIC_OFFSET) / 1000000) : 0;
	}

	std::string savedata_dir()
	{
		return home_dir() + Emu.GetUsr() + "/savedata/";
	}

	std::string trophy_vfs_dir()
	{
		return "/dev_hdd0/home/" + Emu.GetUsr() + "/trophy/";
	}

	// The trophy files are read through the VFS (TROPUSRLoader does); Emu.Init mounts it
	std::string trophy_dir()
	{
		if (vfs::get("/dev_hdd0/").empty())
			vfs::mount("/dev_hdd0", rpcs3::utils::get_hdd0_dir());
		return vfs::get(trophy_vfs_dir());
	}

	// The console's language as an icon suffix (ICON0_01.PNG), as desktop picks localized icons
	std::string localized_file(const std::string& dir, std::string_view base)
	{
		const std::string localized = fmt::format("%s_%02d.PNG", base, static_cast<s32>(g_cfg.sys.language.get()));
		if (fs::is_file(dir + localized)) return dir + localized;
		if (fs::is_file(dir + std::string(base) + ".PNG")) return dir + std::string(base) + ".PNG";
		return "";
	}

	u64 dir_size(const std::string& dir)
	{
		u64 size = 0;
		for (const auto& entry : fs::dir(dir))
		{
			if (entry.name == "." || entry.name == "..") continue;
			size += entry.is_directory ? dir_size(dir + entry.name + "/") : entry.size;
		}
		return size;
	}

	bool safe_name(const std::string& name)
	{
		return !name.empty() && name != "." && name != ".." && name.find_first_of("/\\") == umax;
	}

	// One game's trophy set, loaded as desktop's trophy manager loads it
	struct trophy_set
	{
		std::string id;
		std::string vfs_path;
		std::string path;
		TROPUSRLoader usr;
		trophy_xml_document config;
		std::shared_ptr<rXmlNode> root;

		bool load(const std::string& comm_id)
		{
			id = comm_id;
			vfs_path = trophy_vfs_dir() + comm_id;
			path = trophy_dir() + comm_id + "/";

			if (!usr.Load(vfs_path + "/TROPUSR.DAT", vfs_path + "/TROPCONF.SFM").success || usr.GetTrophiesCount() == 0)
				return false;

			const fs::file file{path + "TROPCONF.SFM"};
			if (!file || !config.Read(file.to_string()))
				return false;

			root = config.GetRoot();
			return !!root;
		}

		std::string child(const std::shared_ptr<rXmlNode>& node, std::string_view name) const
		{
			for (auto n = node->GetChildren(); n; n = n->GetNext())
			{
				if (n->GetName() == name) return n->GetNodeContent();
			}
			return "";
		}
	};

	std::string grade_name(char type)
	{
		switch (type)
		{
		case 'P': return "platinum";
		case 'G': return "gold";
		case 'S': return "silver";
		case 'B': return "bronze";
		default: return "unknown";
		}
	}
}

std::string ios_userdata::saved_user()
{
	std::string id;
	if (const fs::file file{active_user_file()})
		id = file.to_string();
	return is_user(id) ? id : "00000001";
}

// Users

extern "C" char* rpcs3_ios_users(void)
{
	std::string list = "[";

	std::vector<std::string> ids;
	for (const auto& entry : fs::dir(home_dir()))
	{
		if (entry.is_directory && is_user(entry.name))
			ids.push_back(entry.name);
	}
	std::sort(ids.begin(), ids.end());

	for (const std::string& id : ids)
		list += fmt::format("%s{\"id\":%s,\"name\":%s}", list.size() > 1 ? "," : "", json_string(id), json_string(username(id)));

	return copy_string(fmt::format("{\"active\":%s,\"users\":%s]}", json_string(Emu.GetUsr()), list));
}

extern "C" int rpcs3_ios_user_create(const char* name_text, char* message, size_t message_size)
{
	const std::string name = text(name_text);

	if (!valid_name(name))
		return fail(message, message_size, "A name has 3 to 16 letters, digits, underscores or hyphens.");

	// As desktop: the smallest free id, eight digits
	u32 smallest = 1;
	while (smallest < 100000000 && fs::is_dir(home_dir() + fmt::format("%08d", smallest)))
		smallest++;

	if (smallest >= 100000000)
		return fail(message, message_size, "There cannot be more users.");

	const std::string id = fmt::format("%08d", smallest);
	const std::string dir = home_dir() + id;
	fs::create_path(dir + "/exdata/");
	fs::create_path(dir + "/savedata/");
	fs::create_path(dir + "/trophy/");

	if (!fs::write_file(dir + "/localusername", fs::create + fs::excl + fs::write, name))
		return fail(message, message_size, fmt::format("The user could not be created (%s).", fs::g_tls_error));

	userdata_log.success("Created user %s (%s)", id, name);
	return 0;
}

extern "C" int rpcs3_ios_user_rename(const char* id_text, const char* name_text, char* message, size_t message_size)
{
	const std::string id = text(id_text);
	const std::string name = text(name_text);

	if (!is_user(id))
		return fail(message, message_size, "No such user.");
	if (!valid_name(name))
		return fail(message, message_size, "A name has 3 to 16 letters, digits, underscores or hyphens.");
	if (!fs::write_file(home_dir() + id + "/localusername", fs::rewrite, name))
		return fail(message, message_size, fmt::format("The user could not be renamed (%s).", fs::g_tls_error));

	userdata_log.success("Renamed user %s to %s", id, name);
	return 0;
}

extern "C" int rpcs3_ios_user_remove(const char* id_text, char* message, size_t message_size)
{
	const std::string id = text(id_text);

	if (!is_user(id))
		return fail(message, message_size, "No such user.");
	if (id == Emu.GetUsr())
		return fail(message, message_size, "The logged-in user cannot be deleted. Log in as another user first.");
	if (!fs::remove_all(home_dir() + id + "/"))
		return fail(message, message_size, fmt::format("The user could not be deleted (%s).", fs::g_tls_error));

	userdata_log.warning("Deleted user %s", id);
	return 0;
}

extern "C" int rpcs3_ios_user_login(const char* id_text, char* message, size_t message_size)
{
	const std::string id = text(id_text);

	if (!is_user(id))
		return fail(message, message_size, "No such user.");
	if (!Emu.IsStopped())
		return fail(message, message_size, "Stop the game before changing the user.");

	// As desktop's main_application::InitializeEmulator
	Emu.SetUsr(id);
	Emu.Init();
	fs::write_file(active_user_file(), fs::rewrite, id);
	userdata_log.success("Logged in as %s (%s)", id, username(id));
	return 0;
}

// Save data

extern "C" char* rpcs3_ios_saves(const char* serial_text)
{
	const std::string serial = text(serial_text);
	const std::string base = savedata_dir();
	std::string list = "[";

	for (const auto& entry : fs::dir(base))
	{
		if (!entry.is_directory || entry.name == "." || entry.name == "..")
			continue;

		// A game's saves are the directories named after its serial (as desktop's "Remove Save Data")
		if (!serial.empty() && !entry.name.starts_with(serial))
			continue;

		const std::string dir = base + entry.name + "/";
		const auto [psf, error] = psf::load(dir + "PARAM.SFO");

		if (psf.empty())
		{
			userdata_log.warning("No PARAM.SFO in save data %s (%s)", entry.name, error);
			continue;
		}

		list += fmt::format("%s{\"dir\":%s,\"title\":%s,\"subtitle\":%s,\"details\":%s,\"listParam\":%s,\"size\":%s,\"modified\":%s,\"icon\":%s}",
			list.size() > 1 ? "," : "", json_string(entry.name), json_string(psf::get_string(psf, "TITLE")),
			json_string(psf::get_string(psf, "SUB_TITLE")), json_string(psf::get_string(psf, "DETAIL")),
			json_string(psf::get_string(psf, "SAVEDATA_LIST_PARAM")), json_number(dir_size(dir)),
			std::to_string(entry.mtime), json_string(localized_file(dir, "ICON0")));
	}

	return copy_string(fmt::format("{\"dir\":%s,\"saves\":%s]}", json_string(base), list));
}

extern "C" int rpcs3_ios_save_remove(const char* dir_text)
{
	const std::string name = text(dir_text);

	if (!safe_name(name) || !fs::is_dir(savedata_dir() + name))
		return -1;

	if (!fs::remove_all(savedata_dir() + name + "/"))
	{
		userdata_log.error("Could not delete save data %s (%s)", name, fs::g_tls_error);
		return -1;
	}

	userdata_log.notice("Deleted save data %s", name);
	return 0;
}

// Trophies

extern "C" char* rpcs3_ios_trophy_games(void)
{
	const std::string base = trophy_dir();
	std::string list = "[";

	for (const auto& entry : fs::dir(base))
	{
		if (!entry.is_directory || entry.name == "." || entry.name == "..")
			continue;

		trophy_set set;
		if (!set.load(entry.name))
		{
			userdata_log.warning("Could not read the trophies in %s", entry.name);
			continue;
		}

		// Earned, by grade
		u32 earned[4]{};
		u32 total[4]{};
		for (auto n = set.root->GetChildren(); n; n = n->GetNext())
		{
			if (n->GetName() != "trophy") continue;

			const s32 id = std::atoi(n->GetAttribute("id").c_str());
			const usz grade = std::string("PGSB").find(n->GetAttribute("ttype")[0]);
			if (grade == umax) continue;

			total[grade]++;
			if (set.usr.GetTrophyUnlockState(id)) earned[grade]++;
		}

		list += fmt::format("%s{\"id\":%s,\"name\":%s,\"icon\":%s,\"total\":%u,\"earned\":%u,"
			"\"platinum\":[%u,%u],\"gold\":[%u,%u],\"silver\":[%u,%u],\"bronze\":[%u,%u]}",
			list.size() > 1 ? "," : "", json_string(entry.name), json_string(fmt::trim(set.child(set.root, "title-name"))),
			json_string(localized_file(set.path, "ICON0")), set.usr.GetTrophiesCount(), set.usr.GetUnlockedTrophiesCount(),
			earned[0], total[0], earned[1], total[1], earned[2], total[2], earned[3], total[3]);
	}

	return copy_string(list + "]");
}

extern "C" char* rpcs3_ios_trophies(const char* comm_id_text)
{
	const std::string comm_id = text(comm_id_text);
	trophy_set set;

	if (!safe_name(comm_id) || !set.load(comm_id))
		return copy_string("[]");

	// The trophy groups (a game's add-ons), by id
	std::map<std::string, std::string> groups;
	for (auto n = set.root->GetChildren(); n; n = n->GetNext())
	{
		if (n->GetName() == "group")
			groups[n->GetAttribute("id")] = fmt::trim(set.child(n, "name"));
	}

	std::string list = "[";

	for (auto n = set.root->GetChildren(); n; n = n->GetNext())
	{
		if (n->GetName() != "trophy") continue;

		const s32 id = std::atoi(n->GetAttribute("id").c_str());
		const std::string group_id = n->GetAttribute("gid");
		std::string group;
		if (!group_id.empty())
			group = groups.contains(group_id) && !groups[group_id].empty() ? groups[group_id] : "Group " + group_id;

		const std::string icon = fmt::format("%sTROP%03d.PNG", set.path, id);
		const bool earned = set.usr.GetTrophyUnlockState(id);

		list += fmt::format("%s{\"id\":%d,\"name\":%s,\"detail\":%s,\"grade\":%s,\"hidden\":%s,\"earned\":%s,\"time\":%d,\"icon\":%s,\"group\":%s}",
			list.size() > 1 ? "," : "", id, json_string(fmt::trim(set.child(n, "name"))), json_string(fmt::trim(set.child(n, "detail"))),
			json_string(grade_name(n->GetAttribute("ttype")[0])), n->GetAttribute("hidden")[0] == 'y' ? "true" : "false",
			earned ? "true" : "false", earned ? unix_time(set.usr.GetTrophyTimestamp(id)) : 0,
			json_string(fs::is_file(icon) ? icon : ""), json_string(group));
	}

	return copy_string(list + "]");
}

extern "C" int rpcs3_ios_trophy_set_earned(const char* comm_id_text, int trophy_id, int earned)
{
	const std::string comm_id = text(comm_id_text);
	trophy_set set;

	if (!safe_name(comm_id) || !set.load(comm_id) || trophy_id < 0 || static_cast<u32>(trophy_id) >= set.usr.GetTrophiesCount())
		return -1;

	if (!Emu.IsStopped())
	{
		userdata_log.error("Trophies cannot be changed while a game runs");
		return -1;
	}

	// As desktop's trophy manager: now, for both timestamps
	const u64 tick = RTC_MAGIC_OFFSET + static_cast<u64>(std::time(nullptr)) * 1000000;

	if (!(earned ? set.usr.UnlockTrophy(trophy_id, tick, tick) : set.usr.LockTrophy(trophy_id)) || !set.usr.Save(set.vfs_path + "/TROPUSR.DAT"))
	{
		userdata_log.error("Could not change trophy %d of %s", trophy_id, comm_id);
		return -1;
	}

	userdata_log.notice("Trophy %d of %s %s", trophy_id, comm_id, earned ? "earned" : "not earned");
	return 0;
}

extern "C" int rpcs3_ios_trophy_game_remove(const char* comm_id_text)
{
	const std::string comm_id = text(comm_id_text);
	const std::string base = trophy_dir();

	if (!safe_name(comm_id) || base.empty() || !fs::is_dir(base + comm_id))
		return -1;

	if (!Emu.IsStopped())
	{
		userdata_log.error("Trophies cannot be removed while a game runs");
		return -1;
	}

	if (!fs::remove_all(base + comm_id + "/"))
	{
		userdata_log.error("Could not remove the trophies of %s (%s)", comm_id, fs::g_tls_error);
		return -1;
	}

	userdata_log.warning("Removed the trophies of %s", comm_id);
	return 0;
}
