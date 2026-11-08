#include "stdafx.h"
#include "ios/config_json.hpp"

#include <cstdlib>
#include <cstring>

namespace ios_config
{
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

	void describe(const cfg::node& node, std::vector<std::string>& path, const reset_fn& reset, const overridden_fn& overridden, std::string& out)
	{
		for (const cfg::_base* child : node.get_nodes())
		{
			path.push_back(child->get_name());

			std::string type;
			std::vector<std::string> options;

			switch (child->get_type())
			{
			case cfg::type::node:
				describe(*static_cast<const cfg::node*>(child), path, reset, overridden, out);
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

				out += out.size() > 1 ? "," : "";
				out += fmt::format("{\"path\":%s,\"type\":\"%s\",\"value\":%s,\"reset\":%s,\"dynamic\":%s",
					json_list(path), type, json_string(child->to_string()), json_string(reset(path, *child)), child->get_is_dynamic() ? "true" : "false");

				if (ranged && options.size() == 2)
					out += fmt::format(",\"min\":%s,\"max\":%s", json_string(options[0]), json_string(options[1]));
				else if (type == "enum")
					out += ",\"options\":" + json_list(options);

				if (const std::optional<bool> set = overridden(path))
					out += fmt::format(",\"overridden\":%s", *set ? "true" : "false");

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

}
