#pragma once

// RPCS3's configuration trees (Utilities/Config.h) described to the app as JSON and edited by path.
// Used for the settings (settings.cpp) and the controls (controls.cpp).

#include "Utilities/Config.h"

#include <functional>
#include <optional>
#include <string>
#include <vector>

namespace ios_config
{
	// A setting's place in the tree: one name per level ("Video", "Vulkan", "Adapter"). Names may
	// contain '/' ("Input/Output"), so the app passes them separated by newlines.
	std::vector<std::string> split_path(const char* path);

	cfg::_base* find(cfg::node& root, const std::vector<std::string>& path);

	std::string json_string(std::string_view text);
	std::string json_list(const std::vector<std::string>& items);

	// What resetting an entry gives, and whether a scope sets it itself (nullopt: not asked)
	using reset_fn = std::function<std::string(const std::vector<std::string>& path, const cfg::_base& entry)>;
	using overridden_fn = std::function<std::optional<bool>(const std::vector<std::string>& path)>;

	// Appends every editable entry under node, depth first, as JSON objects separated by commas:
	// {"path": [...], "type": "bool|enum|int|uint|float|string", "value", "reset", "dynamic",
	//  "options": [...] | "min"/"max", "overridden"?}. path holds the node's own place.
	void describe(const cfg::node& node, std::vector<std::string>& path, const reset_fn& reset, const overridden_fn& overridden, std::string& out);

	// A malloc'd copy, for the C interface (freed with rpcs3_ios_free)
	char* copy_string(const std::string& text);
}
