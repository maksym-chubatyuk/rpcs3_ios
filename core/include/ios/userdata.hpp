#pragma once

// Users, save data and trophies (userdata.cpp).

#include <string>

namespace ios_userdata
{
	// The user to log in at start: the one last logged in, if it still exists, else 00000001
	std::string saved_user();
}
