// Settings for the app: RPCS3's configuration tree (Emu/system_config.h) read, described and written
// the way RPCS3's own frontend does it, through the C functions in rpcs3_ios.h.
//
// Global settings are config.yml. A game's own settings are custom_configs/config_<id>.yml, which
// RPCS3 applies over the global ones when the game boots; it holds only what the game changes, so
// every other setting follows the global value.

#include "stdafx.h"
#include "rpcs3_ios.h"

#include "Emu/System.h"
#include "Emu/system_config.h"
#include "Emu/system_utils.hpp"
#include "Utilities/File.h"
#include "util/yaml.hpp"

#include <cstdlib>
#include <cstring>

LOG_CHANNEL(settings_log, "Settings");

// The Vulkan device the app renders with (rpcs3_ios.mm)
std::string ios_vulkan_adapter();

namespace
{
	// A setting's place in the tree: one name per level ("Video", "Vulkan", "Adapter"). Names may
	// contain '/' ("Input/Output"), so the app passes them separated by newlines.
	std::vector<std::string> split_path(const char* path)
	{
		std::vector<std::string> names;
		std::string name;

		for (const char* p = path ? path : ""; *p; p++)
		{
			if (*p == '\n')
			{
				names.push_back(std::move(name));
				name.clear();
			}
			else
			{
				name += *p;
			}
		}

		names.push_back(std::move(name));
		return names;
	}

	cfg::_base* find(cfg::node& root, const std::vector<std::string>& path)
	{
		cfg::_base* current = &root;

		for (const std::string& name : path)
		{
			if (current->get_type() != cfg::type::node)
			{
				return nullptr;
			}

			cfg::_base* next = nullptr;

			for (cfg::_base* child : static_cast<cfg::node*>(current)->get_nodes())
			{
				if (child->get_name() == name)
				{
					next = child;
					break;
				}
			}

			if (!next)
			{
				return nullptr;
			}

			current = next;
		}

		return current;
	}

	// RPCS3's defaults, except where iOS needs another one (the bridge also fixes these at launch)
	std::string default_value(const cfg::_base& setting, const std::vector<std::string>& path)
	{
		if (path == std::vector<std::string>{"Audio", "Renderer"})
			return fmt::format("%s", audio_renderer::faudio);
		if (path == std::vector<std::string>{"Video", "Shader Mode"})
			return fmt::format("%s", shader_mode::async_recompiler);
		if (path == std::vector<std::string>{"Video", "Vulkan", "Adapter"})
			return ios_vulkan_adapter();

		return setting.def_to_string();
	}

	std::string global_config_path()
	{
		return fs::get_config_dir(true) + "config.yml";
	}

	// The global settings as saved, over RPCS3's defaults
	void load_global(cfg_root& cfg)
	{
		cfg.from_default();

		if (fs::file file{global_config_path()})
		{
			cfg.from_string(file.to_string());
		}
	}

	YAML::Node load_game_file(const std::string& game)
	{
		if (fs::file file{rpcs3::utils::get_custom_config_path(game)})
		{
			auto [node, error] = yaml_load(file.to_string());

			if (error.empty() && node.IsMap())
			{
				return node;
			}

			settings_log.error("Ignoring unreadable custom config for %s: %s", game, error);
		}

		return YAML::Node(YAML::NodeType::Map);
	}

	bool game_sets(const YAML::Node& file, const std::vector<std::string>& path)
	{
		YAML::Node node = YAML::Clone(file);

		for (const std::string& name : path)
		{
			if (!node.IsMap() || !node[name])
			{
				return false;
			}

			node.reset(node[name]);
		}

		return true;
	}

	// False if it could not be written (RPCS3's SaveSettings only logs that)
	bool save_game_file(const std::string& game, const YAML::Node& file)
	{
		const std::string path = rpcs3::utils::get_custom_config_path(game);

		if (file.size() == 0)
		{
			return !fs::is_file(path) || fs::remove_file(path);
		}

		YAML::Emitter out;
		out << file;
		fs::create_path(fs::get_parent_dir(path));
		Emulator::SaveSettings(out.c_str(), game);

		fs::file saved{path};
		return saved && saved.to_string() == out.c_str();
	}

	// Removes the entry and the levels it leaves empty
	void remove_from(YAML::Node node, const std::vector<std::string>& path, usz level = 0)
	{
		if (!node.IsMap() || !node[path[level]])
		{
			return;
		}

		if (level + 1 == path.size())
		{
			node.remove(path[level]);
			return;
		}

		YAML::Node child = node[path[level]];
		remove_from(child, path, level + 1);

		if (child.IsMap() && child.size() == 0)
		{
			node.remove(path[level]);
		}
	}

	std::string json_string(std::string_view text)
	{
		std::string out = "\"";

		for (const char c : text)
		{
			switch (c)
			{
			case '"': out += "\\\""; break;
			case '\\': out += "\\\\"; break;
			case '\n': out += "\\n"; break;
			case '\r': out += "\\r"; break;
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

	std::string json_list(const std::vector<std::string>& items)
	{
		std::string out = "[";

		for (usz i = 0; i < items.size(); i++)
		{
			out += (i ? "," : "") + json_string(items[i]);
		}

		return out + "]";
	}

	// Every setting the app can edit, depth first
	void describe(const cfg::node& node, std::vector<std::string>& path, const cfg_root* global, const YAML::Node* game_file, std::string& out)
	{
		for (const cfg::_base* child : node.get_nodes())
		{
			path.push_back(child->get_name());

			std::string type;
			std::vector<std::string> options;

			switch (child->get_type())
			{
			case cfg::type::node:
				describe(*static_cast<const cfg::node*>(child), path, global, game_file, out);
				break;
			case cfg::type::_bool: type = "bool"; break;
			case cfg::type::_enum: type = "enum"; options = child->to_list(); break;
			case cfg::type::_int:
				// cfg::_float is an _int to the tree; its range has decimals
				options = child->to_list();
				type = options.size() == 2 && options[0].find('.') != umax ? "float" : "int";
				break;
			case cfg::type::uint: type = "uint"; options = child->to_list(); break;
			case cfg::type::string: type = "string"; break;
			default: break; // sets, maps, log levels and devices have their own editors on desktop
			}

			if (!type.empty())
			{
				const bool ranged = type == "int" || type == "float" || type == "uint";
				std::string reset_value = default_value(*child, path);

				if (global)
				{
					// A game's setting goes back to the global value
					auto& root = const_cast<cfg_root&>(*global);
					reset_value = ensure(find(root, path))->to_string();
				}

				out += out.size() > 1 ? "," : "";
				out += fmt::format("{\"path\":%s,\"type\":\"%s\",\"value\":%s,\"reset\":%s,\"dynamic\":%s",
					json_list(path), type, json_string(child->to_string()), json_string(reset_value), child->get_is_dynamic() ? "true" : "false");

				if (ranged && options.size() == 2)
					out += fmt::format(",\"min\":%s,\"max\":%s", json_string(options[0]), json_string(options[1]));
				else if (type == "enum")
					out += ",\"options\":" + json_list(options);

				if (game_file)
					out += fmt::format(",\"overridden\":%s", game_sets(*game_file, path) ? "true" : "false");

				out += "}";
			}

			path.pop_back();
		}
	}

	char* copy_string(const std::string& text)
	{
		char* out = static_cast<char*>(std::malloc(text.size() + 1));
		std::memcpy(out, text.c_str(), text.size() + 1);
		return out;
	}

	int fail(char* error, size_t error_size, const std::string& message)
	{
		settings_log.error("%s", message);

		if (error && error_size)
		{
			std::snprintf(error, error_size, "%s", message.c_str());
		}

		return -1;
	}
}

extern "C" char* rpcs3_ios_settings(const char* game)
{
	const bool for_game = game && *game;

	cfg_root global;
	load_global(global);

	std::string settings = "[";
	std::vector<std::string> path;

	if (for_game)
	{
		// What the game runs with: the global settings, then its own file over them
		const YAML::Node file = load_game_file(game);
		cfg_root effective;
		load_global(effective);
		YAML::Emitter out;
		out << file;
		effective.from_string(out.c_str());
		describe(effective, path, &global, &file, settings);
	}
	else
	{
		describe(global, path, nullptr, nullptr, settings);
	}

	settings += "]";
	return copy_string(fmt::format("{\"running\":%s,\"settings\":%s}", Emu.IsStopped() ? "false" : "true", settings));
}

extern "C" int rpcs3_ios_setting_set(const char* game, const char* path_text, const char* value, char* error, size_t error_size)
{
	const std::vector<std::string> path = split_path(path_text);
	const std::string text = value ? value : "";

	// Checked by RPCS3's own type for this entry (range, enum names)
	cfg_root cfg;
	load_global(cfg);
	cfg::_base* setting = find(cfg, path);

	if (!setting || setting->get_type() == cfg::type::node)
	{
		return fail(error, error_size, fmt::format("Unknown setting: %s", fmt::merge(path, "/")));
	}

	if (!setting->from_string(text))
	{
		return fail(error, error_size, fmt::format("'%s' is not a valid value for %s", text, fmt::merge(path, "/")));
	}

	if (game && *game)
	{
		YAML::Node file = load_game_file(game);
		YAML::Node node = file;

		for (usz i = 0; i + 1 < path.size(); i++)
		{
			if (!node[path[i]] || !node[path[i]].IsMap())
			{
				node[path[i]] = YAML::Node(YAML::NodeType::Map);
			}

			node.reset(node[path[i]]);
		}

		node[path.back()] = setting->to_string();

		if (!save_game_file(game, file))
		{
			return fail(error, error_size, fmt::format("Could not save the settings of %s", game));
		}
	}
	else
	{
		Emulator::SaveSettings(cfg.to_string(), "");
	}

	settings_log.notice("%s: %s = %s", game && *game ? game : "global", fmt::merge(path, "/"), setting->to_string());
	return 0;
}

extern "C" int rpcs3_ios_setting_reset(const char* game, const char* path_text, char* error, size_t error_size)
{
	const std::vector<std::string> path = split_path(path_text);

	if (game && *game)
	{
		YAML::Node file = load_game_file(game);
		remove_from(file, path);

		if (!save_game_file(game, file))
		{
			return fail(error, error_size, fmt::format("Could not save the settings of %s", game));
		}

		return 0;
	}

	cfg_root cfg;
	load_global(cfg);
	cfg::_base* setting = find(cfg, path);

	if (!setting)
	{
		return fail(error, error_size, fmt::format("Unknown setting: %s", fmt::merge(path, "/")));
	}

	return rpcs3_ios_setting_set(nullptr, path_text, default_value(*setting, path).c_str(), error, error_size);
}

extern "C" void rpcs3_ios_free(void* pointer)
{
	std::free(pointer);
}
