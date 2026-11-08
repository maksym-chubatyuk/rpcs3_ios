// Installing software for the app, as desktop RPCS3's "Install Packages/Raps/Edats" does
// (rpcs3qt/main_window.cpp, InstallPackages and HandlePackageInstallation): PKG files (games,
// updates, DLC) into dev_hdd0/game, and licence files (.rap, .edat) into the logged-in user's exdata.

#include "stdafx.h"
#include "rpcs3_ios.h"
#include "ios/config_json.hpp"

#include "Crypto/unpkg.h"
#include "Emu/System.h"
#include "Emu/system_config.h"
#include "Emu/system_utils.hpp"
#include "Loader/PSF.h"
#include "Utilities/File.h"
#include "Utilities/Thread.h"

#include <deque>
#include <mutex>

LOG_CHANNEL(packages_log, "Packages");

using ios_config::copy_string;
using ios_config::json_string;

namespace
{
	std::string text(const char* value)
	{
		return value ? value : "";
	}

	int fail(char* out, size_t size, int code, const std::string& message)
	{
		packages_log.error("%s", message);
		if (out && size) std::snprintf(out, size, "%s", message.c_str());
		return code;
	}

	// The installation running now, for rpcs3_ios_cancel_install
	std::mutex g_install_mutex;
	std::deque<package_reader>* g_readers = nullptr;
	atomic_t<bool> g_cancelled = false;

	// What the user will see the package as (desktop's game_compatibility::GetPkgInfo)
	std::string package_type(const package_reader& reader)
	{
		const std::string category{psf::get_string(reader.get_psf(), "CATEGORY")};

		if (category == "GD")
			return reader.get_metadata().package_type & pkg_flag::PKG_FLAG_PATCH ? "update" : "dlc";
		if (category == "HG" || category == "1P" || category == "2P" || category == "MN" || category == "PE" || category == "PP")
			return "game";
		if (category.empty())
			return "dlc"; // DLC packages often carry no PARAM.SFO
		return "other";
	}

	std::string version_problem(const package_install_result& result)
	{
		if (result.error != package_install_result::error_type::app_version)
			return "";

		const auto& v = result.version;

		if (!v.expected.empty() && !v.installed.empty())
			return fmt::format("This update (version %s) is for version %s, but version %s is installed.", v.app_ver, v.expected, v.installed);
		if (!v.expected.empty())
			return fmt::format("This update (version %s) is for version %s, but the game's data is not installed.", v.app_ver, v.expected);
		if (!v.installed.empty())
			return fmt::format("This update has version %s, but version %s is already installed.", v.app_ver, v.installed);
		return "This package cannot be installed over what is installed now.";
	}
}

extern "C" char* rpcs3_ios_package_info(const char* path)
{
	const package_reader reader(text(path));

	if (!reader.is_valid())
		return copy_string("{\"valid\":false}");

	const psf::registry& psf = reader.get_psf();
	const std::string localized_title{psf::get_string(psf, fmt::format("TITLE_%02d", static_cast<s32>(g_cfg.sys.language.get())))};
	std::string version{psf::get_string(psf, "APP_VER")};
	if (version.empty()) version = psf::get_string(psf, "VERSION");

	// What is installed already in the same place
	std::string installed;
	if (const std::string dir = reader.get_install_path(); !dir.empty())
	{
		if (const auto [installed_psf, error] = psf::load(dir + "/PARAM.SFO"); !installed_psf.empty())
			installed = psf::get_string(installed_psf, "APP_VER");
		else if (fs::is_dir(dir))
			installed = "?";
	}

	return copy_string(fmt::format("{\"valid\":true,\"title\":%s,\"titleID\":%s,\"version\":%s,\"category\":%s,\"type\":%s,"
		"\"size\":%u,\"installed\":%s,\"problem\":%s}",
		json_string(localized_title.empty() ? std::string(psf::get_string(psf, "TITLE")) : localized_title),
		json_string(psf::get_string(psf, "TITLE_ID")), json_string(version), json_string(psf::get_string(psf, "CATEGORY")),
		json_string(package_type(reader)), reader.get_header().data_size.value(), json_string(installed),
		json_string(version_problem(reader.check_target_app_version()))));
}

extern "C" int rpcs3_ios_install_packages(const char* paths_text, rpcs3_ios_progress_fn progress, void* ctx, char* message, size_t message_size)
{
	const std::vector<std::string> paths = ios_config::split_path(paths_text);

	if (paths.empty())
		return fail(message, message_size, -1, "No packages to install.");
	if (!Emu.IsStopped())
		return fail(message, message_size, -1, "Stop the game before installing packages.");

	std::deque<package_reader> readers;
	for (const std::string& path : paths)
	{
		readers.emplace_back(path);
		if (!readers.back().is_valid())
			return fail(message, message_size, -1, fmt::format("%s is not a PS3 package, or it is damaged.", path.substr(path.find_last_of('/') + 1)));
	}

	packages_log.notice("Installing packages:\n%s", fmt::merge(paths, "\n"));

	{
		std::lock_guard lock(g_install_mutex);
		g_readers = &readers;
		g_cancelled = false;
	}

	package_install_result result{};
	std::deque<std::string> bootables;

	named_thread worker("PKG Installer", [&]
	{
		result = package_reader::extract_data(readers, bootables, false);
		return result.error == package_install_result::error_type::no_error;
	});

	// Progress: each package counts 1000 (as desktop's dialog)
	const u32 total = ::size32(readers) * 1000;
	while (worker <= thread_state::aborting)
	{
		std::this_thread::sleep_for(20ms);

		u32 done = 0;
		for (const package_reader& reader : readers)
			done += reader.get_progress(1000);
		if (progress) progress(ctx, done, total);
	}

	const bool success = worker();

	{
		std::lock_guard lock(g_install_mutex);
		g_readers = nullptr;
	}

	if (g_cancelled)
	{
		bool dirty = false;
		for (const package_reader& reader : readers)
			dirty |= reader.get_result() == package_reader::aborted_dirty;
		return fail(message, message_size, -3, dirty ? "Cancelled. A package was installed in part; install it again to complete it." : "Cancelled.");
	}

	if (!success)
	{
		for (usz i = 0; i < readers.size(); i++)
		{
			const auto state = readers[i].get_result();
			if (state != package_reader::error && state != package_reader::error_dirty) continue;

			const std::string name = paths[i].substr(paths[i].find_last_of('/') + 1);
			if (result.error == package_install_result::error_type::app_version)
				return fail(message, message_size, -2, fmt::format("%s: %s", name, version_problem(result)));
			return fail(message, message_size, -1, fmt::format("%s could not be installed%s. See RPCS3.log.", name, state == package_reader::error_dirty ? " (in part)" : ""));
		}
		return fail(message, message_size, -1, "The packages could not be installed. See RPCS3.log.");
	}

	for (const std::string& path : bootables)
		packages_log.success("Installed bootable: %s", path);

	if (message && message_size)
		std::snprintf(message, message_size, "%s", paths.size() == 1 ? "Installed the package." : fmt::format("Installed %d packages.", paths.size()).c_str());
	return 0;
}

extern "C" void rpcs3_ios_cancel_install(void)
{
	std::lock_guard lock(g_install_mutex);

	if (g_readers)
	{
		g_cancelled = true;
		for (package_reader& reader : *g_readers)
			reader.abort_extract();
	}
}

extern "C" int rpcs3_ios_install_license(const char* path_text, char* message, size_t message_size)
{
	const std::string path = text(path_text);
	const std::string filename = path.substr(path.find_last_of('/') + 1);
	const usz dot = filename.find_last_of('.');
	const std::string extension = dot == umax ? "" : fmt::to_lower(filename.substr(dot + 1));

	if (extension != "rap" && extension != "edat")
		return fail(message, message_size, -1, fmt::format("%s is not a licence (.rap) or .edat file.", filename));

	// As desktop's InstallFileInExData: the name as it is, with a lower-case extension
	const std::string dir = rpcs3::utils::get_hdd0_dir() + "home/" + Emu.GetUsr() + "/exdata/";
	fs::create_path(dir);

	fs::file from(path);
	if (!from)
		return fail(message, message_size, -1, fmt::format("%s could not be read.", filename));

	const std::vector<u8> data = from.to_vector<u8>();
	if (data.size() < 0x10)
		return fail(message, message_size, -1, fmt::format("%s is too small to be a %s file.", filename, extension));

	fs::pending_file to(dir + filename.substr(0, dot) + "." + extension);
	if (!to.file || !to.file.write(data.data(), data.size()) || !to.commit())
		return fail(message, message_size, -1, fmt::format("%s could not be installed (%s).", filename, fs::g_tls_error));

	packages_log.success("Installed %s", filename);
	return 0;
}

extern "C" const char* rpcs3_ios_hdd0_game_dir(void)
{
	static const std::string dir = rpcs3::utils::get_hdd0_game_dir();
	return dir.c_str();
}
