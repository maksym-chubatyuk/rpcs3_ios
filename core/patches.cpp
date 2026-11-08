// Game patches for the app, through RPCS3's patch engine (Utilities/bin_patch.h) as its desktop
// patch manager (rpcs3qt/patch_manager_dialog.cpp) uses it: the patches that apply to a game,
// turning them on and off, their adjustable values, the official patch file from rpcs3.net, and
// importing patch files.

#include "stdafx.h"
#include "rpcs3_ios.h"

#include "Crypto/utils.h"
#include "Utilities/File.h"
#include "Utilities/bin_patch.h"

#include <cstdlib>
#include <cstring>
#include <sstream>

LOG_CHANNEL(patches_log, "Patches");

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

	void set_message(char* out, size_t size, const std::string& message)
	{
		if (out && size)
		{
			std::snprintf(out, size, "%s", message.c_str());
		}
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
			case '\r': break;
			case '\t': out += "\\t"; break;
			default:
				if (static_cast<u8>(c) < 0x20)
					out += fmt::format("\\u%04x", static_cast<u8>(c));
				else
					out += c;
			}
		}

		return out + "\"";
	}

	std::string json_number(f64 value)
	{
		return fmt::format("%.17g", value);
	}

	// Every patch file, in the order RPCS3 applies them at boot (as desktop's patch manager loads them)
	patch_engine::patch_map load_all()
	{
		patch_engine::patch_map map;
		const std::string dir = patch_engine::get_patches_path();
		std::vector<std::string> files = {"patch.yml", "imported_patch.yml"};

		for (const auto& entry : fs::dir(dir))
		{
			if (!entry.is_directory && entry.name.ends_with("_patch.yml") && entry.name != "imported_patch.yml")
				files.push_back(entry.name);
		}

		for (const std::string& file : files)
		{
			if (!patch_engine::load(map, dir + file))
				patches_log.error("Errors in patch file %s", file);
		}

		return map;
	}

	std::string config_values_json(const std::map<std::string, patch_engine::patch_config_value>& values)
	{
		std::string out = "[";

		for (const auto& [name, value] : values)
		{
			const bool is_enum = value.type == patch_configurable_type::double_enum || value.type == patch_configurable_type::long_enum;
			const bool is_integer = value.type == patch_configurable_type::long_range || value.type == patch_configurable_type::long_enum;

			std::string options = "[";
			for (const auto& allowed : value.allowed_values)
				options += fmt::format("%s{\"label\":%s,\"value\":%s}", options.size() > 1 ? "," : "", json_string(allowed.label), json_number(allowed.value));
			options += "]";

			out += fmt::format("%s{\"name\":%s,\"value\":%s,\"min\":%s,\"max\":%s,\"isList\":%s,\"isInteger\":%s,\"options\":%s}",
				out.size() > 1 ? "," : "", json_string(name), json_number(value.value), json_number(value.min), json_number(value.max),
				is_enum ? "true" : "false", is_integer ? "true" : "false", options);
		}

		return out + "]";
	}

	// The entry a game's switch stands for: one patch, for one title/serial/app version key
	patch_engine::patch_config_values* find_entry(patch_engine::patch_map& map, const std::string& hash, const std::string& description,
		const std::string& title, const std::string& serial, const std::string& app_version, patch_engine::patch_info** info_out = nullptr)
	{
		const auto container = map.find(hash);
		if (container == map.end()) return nullptr;

		const auto info = container->second.patch_info_map.find(description);
		if (info == container->second.patch_info_map.end()) return nullptr;

		const auto titles = info->second.titles.find(title);
		if (titles == info->second.titles.end()) return nullptr;

		const auto serials = titles->second.find(serial);
		if (serials == titles->second.end()) return nullptr;

		const auto versions = serials->second.find(app_version);
		if (versions == serials->second.end()) return nullptr;

		if (info_out) *info_out = &info->second;
		return &versions->second;
	}
}

extern "C" char* rpcs3_ios_patches(const char* title_id, const char* app_version)
{
	const std::string serial = text(title_id);
	const std::string version = text(app_version);
	const patch_engine::patch_map map = load_all();

	std::string out = "[";

	for (const auto& [hash, container] : map)
	{
		for (const auto& [description, info] : container.patch_info_map)
		{
			for (const auto& [title, serials] : info.titles)
			{
				for (const auto& [patch_serial, versions] : serials)
				{
					if (patch_serial != serial && patch_serial != patch_key::all)
						continue;

					for (const auto& [patch_version_key, values] : versions)
					{
						if (patch_version_key != version && patch_version_key != patch_key::all)
							continue;

						const auto& config = values.config_values.empty() ? info.default_config_values : values.config_values;

						out += fmt::format("%s{\"hash\":%s,\"description\":%s,\"title\":%s,\"serial\":%s,\"appVersion\":%s,\"enabled\":%s,"
							"\"author\":%s,\"notes\":%s,\"version\":%s,\"group\":%s,\"file\":%s,\"configValues\":%s}",
							out.size() > 1 ? "," : "", json_string(hash), json_string(description), json_string(title), json_string(patch_serial),
							json_string(patch_version_key), values.enabled ? "true" : "false", json_string(info.author), json_string(info.notes),
							json_string(info.patch_version), json_string(info.patch_group), json_string(info.source_path.substr(info.source_path.find_last_of("/\\") + 1)),
							config_values_json(config));
					}
				}
			}
		}
	}

	return copy_string(out + "]");
}

extern "C" int rpcs3_ios_patch_enable(const char* hash, const char* description, const char* title, const char* serial, const char* app_version, int enabled)
{
	patch_engine::patch_map map = load_all();
	patch_engine::patch_info* info = nullptr;
	patch_engine::patch_config_values* entry = find_entry(map, text(hash), text(description), text(title), text(serial), text(app_version), &info);

	if (!entry)
	{
		patches_log.error("No patch '%s' (%s) for %s %s", text(description), text(hash), text(serial), text(app_version));
		return -1;
	}

	entry->enabled = enabled != 0;

	// As desktop: turning a patch on turns off the others of its group for the same game
	if (enabled && !info->patch_group.empty())
	{
		for (auto& [other_hash, container] : map)
		{
			for (auto& [other_description, other] : container.patch_info_map)
			{
				if (&other == info || other.patch_group != info->patch_group)
					continue;

				if (auto* sibling = find_entry(map, other_hash, other_description, text(title), text(serial), text(app_version)))
					sibling->enabled = false;
			}
		}
	}

	patch_engine::save_config(map);
	patches_log.notice("%s '%s' for %s %s", enabled ? "Enabled" : "Disabled", text(description), text(serial), text(app_version));
	return 0;
}

extern "C" int rpcs3_ios_patch_set_value(const char* hash, const char* description, const char* title, const char* serial, const char* app_version, const char* name, double value)
{
	patch_engine::patch_map map = load_all();
	patch_engine::patch_info* info = nullptr;
	patch_engine::patch_config_values* entry = find_entry(map, text(hash), text(description), text(title), text(serial), text(app_version), &info);

	if (!entry)
	{
		return -1;
	}

	if (entry->config_values.empty())
	{
		entry->config_values = info->default_config_values;
	}

	const auto found = entry->config_values.find(text(name));

	if (found == entry->config_values.end())
	{
		return -1;
	}

	found->second.set_and_check_value(value, text(name));
	patch_engine::save_config(map);
	return 0;
}

extern "C" char* rpcs3_ios_patch_download_url(void)
{
	// As desktop: the server answers "already up to date" when the hash matches
	std::string url = "https://rpcs3.net/compatibility?patch&api=v1&v=" + patch_engine_version;

	if (const fs::file file{patch_engine::get_patches_path() + "patch.yml"})
	{
		const std::string content = file.to_string();
		url += "&sha256=" + sha256_get_hash(content.c_str(), content.size(), true);
	}

	return copy_string(url);
}

extern "C" const char* rpcs3_ios_patch_engine_version(void)
{
	return patch_engine_version.c_str();
}

extern "C" int rpcs3_ios_patch_install(const char* content_text, const char* sha256, char* message, size_t message_size)
{
	const std::string content = text(content_text);

	if (sha256_get_hash(content.c_str(), content.size(), true) != text(sha256))
	{
		set_message(message, message_size, "The download is damaged (its checksum does not match).");
		return -1;
	}

	patch_engine::patch_map patches;
	std::stringstream log;

	if (!patch_engine::load(patches, "From Download", content, true, &log))
	{
		patches_log.error("Errors in the downloaded patch file:\n%s", log.str());
		set_message(message, message_size, "The downloaded patches have errors:\n" + log.str());
		return -1;
	}

	const std::string dir = patch_engine::get_patches_path();
	const std::string path = dir + "patch.yml";
	fs::create_path(dir);

	if (fs::is_file(path) && !fs::rename(path, path + ".old", true))
	{
		set_message(message, message_size, "The current patch file could not be backed up.");
		return -1;
	}

	fs::pending_file file(path);

	if (!file.file || !file.file.write(content) || !file.commit())
	{
		set_message(message, message_size, "The patches could not be saved.");
		return -1;
	}

	patches_log.success("Installed the latest patches");
	return 0;
}

extern "C" int rpcs3_ios_patch_import(const char* path, char* message, size_t message_size)
{
	patch_engine::patch_map patches;
	std::stringstream log;

	if (!patch_engine::load(patches, text(path), "", true, &log))
	{
		set_message(message, message_size, "The file has errors:\n" + log.str());
		return -1;
	}

	usz count = 0;
	usz total = 0;

	if (!patch_engine::import_patches(patches, patch_engine::get_imported_patch_path(), count, total, &log))
	{
		set_message(message, message_size, "The patches could not be imported:\n" + log.str());
		return -1;
	}

	set_message(message, message_size, count == total
		? fmt::format("Imported %d patches.", count)
		: fmt::format("Imported %d of %d patches; the others were already there.", count, total));
	return static_cast<int>(count);
}
