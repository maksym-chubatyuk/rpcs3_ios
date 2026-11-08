// Controls for the app: RPCS3's input configuration (Emu/Io/pad_config.h) for the seven players,
// globally or for one game, as its desktop pad settings dialog edits it (rpcs3qt/pad_settings_dialog.cpp).
//
// On iOS the players use RPCS3's SDL handler: "RPCS3 Virtual Pad 1" is the app's controller (the
// on-screen controls merged with the first physical controller), and other controllers appear as
// SDL devices of their own.

#include "stdafx.h"
#include "rpcs3_ios.h"
#include "ios/config_json.hpp"

#include "Emu/System.h"
#include "Emu/system_utils.hpp"
#include "Emu/Io/pad_config.h"
#include "Input/pad_thread.h"
#include "Input/sdl_pad_handler.h"
#include "Utilities/File.h"

LOG_CHANNEL(controls_log, "Controls");

using namespace ios_config;

namespace
{
	constexpr std::string_view virtual_pad = "RPCS3 Virtual Pad 1";

	// RPCS3's SDL handler, for its button names (desktop's pad settings dialog offers the same list)
	class sdl_button_names final : public sdl_pad_handler
	{
	public:
		std::vector<std::string> names() const
		{
			std::vector<std::string> list;
			for (const auto& [code, name] : button_list)
				list.push_back(name);
			std::sort(list.begin(), list.end());
			list.erase(std::unique(list.begin(), list.end()), list.end());
			return list;
		}
	};

	std::string text(const char* value)
	{
		return value ? value : "";
	}

	std::string global_profile()
	{
		g_cfg_input_configs.load();
		const std::string profile = g_cfg_input_configs.active_configs.get_value(g_cfg_input_configs.global_key);
		return profile.empty() ? g_cfg_input_configs.default_config : profile;
	}

	// The controls of a scope: a game's own if it has them, otherwise (and for the global scope) the global ones
	void load(cfg_input& cfg, const std::string& game, bool& game_has_own)
	{
		cfg.from_default();

		const std::string own = game.empty() ? "" : rpcs3::utils::get_custom_input_config_path(game);
		game_has_own = !own.empty() && fs::is_file(own);

		if (fs::file file{game_has_own ? own : rpcs3::utils::get_input_config_dir() + global_profile() + ".yml"})
		{
			if (const std::string content = file.to_string(); !content.empty())
				cfg.from_string(content);
		}
	}

	void save(const cfg_input& cfg, const std::string& game)
	{
		if (game.empty())
			cfg.save("", global_profile());
		else
			cfg.save(game);

		// A running game picks the change up (as desktop does after its pad settings dialog)
		if (!Emu.IsStopped() && (game.empty() || game == Emu.GetTitleID()))
			pad::reset(Emu.GetTitleID());
	}

	std::vector<std::string> sdl_devices()
	{
		std::vector<std::string> names;
		std::shared_ptr<PadHandlerBase> handler = std::make_shared<sdl_pad_handler>();

		if (handler->Init())
		{
			for (const pad_list_entry& entry : handler->list_devices())
			{
				if (!entry.is_buddy_only)
					names.push_back(entry.name);
			}
		}

		return names;
	}

	// A pad's defaults depend on its handler: RPCS3 applies them as pad_thread::InitPadConfig does
	void apply_handler_defaults(cfg_pad& pad, pad_handler type)
	{
		std::shared_ptr<PadHandlerBase> handler;
		pad_thread::InitPadConfig(pad, type, handler);
	}
}

extern "C" char* rpcs3_ios_controls(const char* game_id)
{
	const std::string game = text(game_id);
	cfg_input cfg;
	bool game_has_own = false;
	load(cfg, game, game_has_own);

	std::string players = "[";

	for (usz i = 0; i < cfg.player.size(); i++)
	{
		cfg_player& player = *cfg.player[i];

		// What resetting gives: this handler's defaults (an empty config with them applied)
		cfg_input defaults;
		apply_handler_defaults(defaults.player[i]->config, player.handler);

		std::string settings = "[";
		std::vector<std::string> path;
		describe(player, path,
			[&](const std::vector<std::string>& p, const cfg::_base& entry) -> std::string
			{
				if (p.size() > 1 && p[0] == "Config")
				{
					if (cfg::_base* def = find(*defaults.player[i], p))
						return def->to_string();
				}

				return entry.to_string();
			},
			[](const std::vector<std::string>&) -> std::optional<bool> { return std::nullopt; },
			settings);

		players += fmt::format("%s{\"settings\":%s]}", i ? "," : "", settings);
	}

	players += "]";

	const std::string json = fmt::format("{\"running\":%s,\"gameHasOwn\":%s,\"devices\":%s,\"buttons\":%s,\"players\":%s}",
		Emu.IsStopped() ? "false" : "true", game_has_own ? "true" : "false",
		json_list(sdl_devices()), json_list(sdl_button_names().names()), players);

	return copy_string(json);
}

extern "C" int rpcs3_ios_control_set(const char* game_id, int player_index, const char* path_text, const char* value_text, char* error, size_t error_size)
{
	const std::string game = text(game_id);
	const std::vector<std::string> path = split_path(path_text);
	const std::string value = text(value_text);

	const auto fail = [&](const std::string& message)
	{
		controls_log.error("%s", message);
		if (error && error_size) std::snprintf(error, error_size, "%s", message.c_str());
		return -1;
	};

	if (player_index < 0 || player_index >= 7)
	{
		return fail("No such player");
	}

	cfg_input cfg;
	bool game_has_own = false;
	load(cfg, game, game_has_own);
	cfg_player& player = *cfg.player[player_index];

	if (path == std::vector<std::string>{"Handler"})
	{
		if (!player.handler.from_string(value))
		{
			return fail(fmt::format("Unknown handler: %s", value));
		}

		// A new handler starts from its own defaults, on a device it has (as desktop does)
		apply_handler_defaults(player.config, player.handler);
		std::string device;

		if (player.handler == pad_handler::sdl)
		{
			const std::vector<std::string> devices = sdl_devices();
			device = player_index == 0 || devices.empty() ? std::string(virtual_pad) : devices.front();
		}

		player.device.from_string(device);
		player.buddy_device.from_string("");
	}
	else
	{
		cfg::_base* entry = find(player, path);

		if (!entry || entry->get_type() == cfg::type::node)
		{
			return fail(fmt::format("Unknown control setting: %s", fmt::merge(path, "/")));
		}

		if (!entry->from_string(value))
		{
			return fail(fmt::format("'%s' is not a valid value for %s", value, fmt::merge(path, "/")));
		}
	}

	save(cfg, game);
	controls_log.notice("%s, player %d: %s = %s%s", game.empty() ? "global" : game, player_index + 1, fmt::merge(path, "/"), value,
		!game.empty() && !game_has_own ? " (the game's own controls start from the global ones)" : "");
	return 0;
}
