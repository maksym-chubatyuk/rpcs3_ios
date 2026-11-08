// RPCN, RPCS3's online service, for the app, as desktop's RPCN dialog sets it up
// (rpcs3qt/rpcn_settings_dialog.cpp): the server, creating an account, its sign-in details,
// testing them, the email token, changing the password and deleting the account.
//
// The account is kept in rpcn.yml (Emu/NP/rpcn_config.h). The calls that reach the server block;
// the app makes them off the main thread.

#include "stdafx.h"
#include "rpcs3_ios.h"
#include "ios/config_json.hpp"

#include "Emu/NP/rpcn_client.h"
#include "Emu/NP/rpcn_config.h"
#include "util/cctype.hpp"

#include <wolfssl/ssl.h>
#include <wolfssl/wolfcrypt/pwdbased.h>
#include <wolfssl/wolfcrypt/sha3.h>

#include <regex>

LOG_CHANNEL(rpcn_ios_log, "RPCN");

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
		rpcn_ios_log.error("%s", message);
		if (out && size) std::snprintf(out, size, "%s", message.c_str());
		return -1;
	}

	int done(char* out, size_t size, const std::string& message)
	{
		if (out && size) std::snprintf(out, size, "%s", message.c_str());
		return 0;
	}

	// The checks desktop makes
	bool valid_username(std::string_view name)
	{
		return name.size() >= 3 && name.size() <= 16 &&
			std::all_of(name.begin(), name.end(), [](char c) { return utils::isalnum(c) || c == '-' || c == '_'; });
	}

	bool valid_token(std::string_view token)
	{
		return token.size() == 16 && std::all_of(token.begin(), token.end(), [](char c) { return (c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z'); });
	}

	bool valid_email(const std::string& email)
	{
		static const std::regex pattern("^[a-zA-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-zA-Z0-9-]+(?:\\.[a-zA-Z0-9-]+)*$");
		return !email.empty() && std::regex_match(email, pattern);
	}

	// RPCN never sees the password itself, only this (as desktop derives it)
	std::string derive_password(std::string_view password)
	{
		constexpr std::string_view salt = "No matter where you go, everybody's connected.";
		u8 digest[WC_SHA3_256_DIGEST_SIZE];
		ensure(!wc_PBKDF2(digest, reinterpret_cast<const u8*>(password.data()), ::narrow<s32>(password.size()),
			reinterpret_cast<const u8*>(salt.data()), ::narrow<s32>(salt.size()), 200'000, WC_SHA3_256_DIGEST_SIZE, WC_SHA3_256));

		std::string out;
		for (const u8 byte : digest)
			out += fmt::format("%02X", byte);
		return out;
	}

	std::shared_ptr<rpcn::rpcn_client> connect(char* message, size_t size)
	{
		auto client = rpcn::rpcn_client::get_instance(0);

		if (const auto state = client->wait_for_connection(); state != rpcn::rpcn_state::failure_no_failure)
		{
			fail(message, size, "Could not connect to the RPCN server: " + rpcn::rpcn_state_to_string(state));
			return nullptr;
		}

		return client;
	}

	std::string error_text(rpcn::ErrorType error, std::string_view what)
	{
		switch (error)
		{
		case rpcn::ErrorType::CreationExistingUsername: return "An account with that username exists already.";
		case rpcn::ErrorType::CreationBannedEmailProvider: return "This email provider is not accepted.";
		case rpcn::ErrorType::CreationExistingEmail: return "An account with that email exists already.";
		case rpcn::ErrorType::CreationError: return "The account could not be created.";
		case rpcn::ErrorType::Invalid: return "This server has no email verification, so it needs no token and has no password reset.";
		case rpcn::ErrorType::DbFail: return "The server's database failed. Try again later.";
		case rpcn::ErrorType::TooSoon: return "This can be asked for only once every 24 hours.";
		case rpcn::ErrorType::EmailFail: return "The server could not send the email.";
		case rpcn::ErrorType::LoginError: return fmt::format("The %s is not right.", what);
		case rpcn::ErrorType::LoginAlreadyLoggedIn: return "The account is signed in elsewhere.";
		case rpcn::ErrorType::LoginInvalidUsername: return "The username is not right.";
		case rpcn::ErrorType::LoginInvalidPassword: return "The password is not right.";
		case rpcn::ErrorType::LoginInvalidToken: return "The token is not right.";
		default: return fmt::format("The server answered with error %d.", static_cast<int>(error));
		}
	}
}

extern "C" char* rpcs3_ios_rpcn(void)
{
	g_cfg_rpcn.load();

	std::string hosts = "[";
	for (const auto& [name, host] : g_cfg_rpcn.get_hosts())
		hosts += fmt::format("%s{\"name\":%s,\"host\":%s}", hosts.size() > 1 ? "," : "", json_string(name), json_string(host));

	// get_npid() makes up a name when there is none: read the entry itself
	return copy_string(fmt::format("{\"username\":%s,\"hasPassword\":%s,\"token\":%s,\"host\":%s,\"hosts\":%s]}",
		json_string(g_cfg_rpcn.npid.to_string()), g_cfg_rpcn.get_password().empty() ? "false" : "true",
		json_string(g_cfg_rpcn.get_token()), json_string(g_cfg_rpcn.get_host()), hosts));
}

extern "C" int rpcs3_ios_rpcn_set_host(const char* host)
{
	g_cfg_rpcn.load();
	g_cfg_rpcn.set_host(text(host));
	g_cfg_rpcn.save();
	return 0;
}

extern "C" int rpcs3_ios_rpcn_add_host(const char* name_text, const char* host_text, char* message, size_t message_size)
{
	const std::string name = text(name_text);
	const std::string host = text(host_text);

	if (name.empty() || name.find('|') != umax || host.find('|') != umax)
		return fail(message, message_size, "Give the server a name (without '|').");
	if (!parse_rpcn_host(host))
		return fail(message, message_size, "The address is not valid: a host name or IP address, optionally with :port.");

	g_cfg_rpcn.load();
	if (!g_cfg_rpcn.add_host(name, host))
		return fail(message, message_size, "This server is in the list already.");

	g_cfg_rpcn.set_host(host);
	g_cfg_rpcn.save();
	return 0;
}

extern "C" int rpcs3_ios_rpcn_remove_host(const char* name, const char* host)
{
	g_cfg_rpcn.load();
	if (!g_cfg_rpcn.del_host(text(name), text(host)))
		return -1;
	g_cfg_rpcn.save();
	return 0;
}

extern "C" int rpcs3_ios_rpcn_set_account(const char* username_text, const char* password_text, const char* token_text, char* message, size_t message_size)
{
	const std::string username = text(username_text);
	const std::string token = text(token_text);

	if (!valid_username(username))
		return fail(message, message_size, "A username has 3 to 16 letters, digits, '-' or '_'.");
	if (!token.empty() && !valid_token(token))
		return fail(message, message_size, "The token from the email has 16 characters, digits and capital letters.");

	g_cfg_rpcn.load();
	g_cfg_rpcn.set_npid(username);
	if (password_text && *password_text)
		g_cfg_rpcn.set_password(derive_password(password_text));
	g_cfg_rpcn.set_token(token);
	g_cfg_rpcn.save();

	if (g_cfg_rpcn.get_password().empty())
		return fail(message, message_size, "Enter the account's password too.");
	return 0;
}

extern "C" int rpcs3_ios_rpcn_create_account(const char* username_text, const char* password_text, const char* email_text, char* message, size_t message_size)
{
	const std::string username = text(username_text);
	const std::string password = text(password_text);
	const std::string email = text(email_text);

	if (!valid_username(username))
		return fail(message, message_size, "A username has 3 to 16 letters, digits, '-' or '_'.");
	if (password.empty())
		return fail(message, message_size, "Choose a password.");
	if (!valid_email(email))
		return fail(message, message_size, "Enter a valid email address: the server sends the token that activates the account to it.");

	const auto client = connect(message, message_size);
	if (!client)
		return -1;

	const std::string derived = derive_password(password);

	if (const auto error = client->create_user(username, derived, username, "https://rpcs3.net/cdn/netplay/DefaultAvatar.png", email); error != rpcn::ErrorType::NoError)
		return fail(message, message_size, error_text(error, "username"));

	g_cfg_rpcn.load();
	g_cfg_rpcn.set_npid(username);
	g_cfg_rpcn.set_password(derived);
	g_cfg_rpcn.set_token("");
	g_cfg_rpcn.save();

	rpcn_ios_log.success("Created the RPCN account %s", username);
	return done(message, message_size, "The account was created. Enter the token the server sent to your email to activate it.");
}

extern "C" int rpcs3_ios_rpcn_test(char* message, size_t message_size)
{
	g_cfg_rpcn.load();
	if (g_cfg_rpcn.npid.to_string().empty() || g_cfg_rpcn.get_password().empty())
		return fail(message, message_size, "Set up an account first.");

	const auto client = connect(message, message_size);
	if (!client)
		return -1;

	if (const auto state = client->wait_for_authentified(); state != rpcn::rpcn_state::failure_no_failure)
		return fail(message, message_size, "Could not sign in: " + rpcn::rpcn_state_to_string(state));

	return done(message, message_size, "The account works.");
}

extern "C" int rpcs3_ios_rpcn_resend_token(char* message, size_t message_size)
{
	g_cfg_rpcn.load();
	const std::string username = g_cfg_rpcn.npid.to_string();
	const std::string password = g_cfg_rpcn.get_password();

	if (username.empty() || password.empty())
		return fail(message, message_size, "Set up an account first.");

	const auto client = connect(message, message_size);
	if (!client)
		return -1;

	if (const auto error = client->resend_token(username, password); error != rpcn::ErrorType::NoError)
		return fail(message, message_size, error_text(error, "username or password"));

	return done(message, message_size, "The token was sent again to the account's email.");
}

extern "C" int rpcs3_ios_rpcn_send_reset_token(const char* username_text, const char* email_text, char* message, size_t message_size)
{
	const std::string username = text(username_text);
	const std::string email = text(email_text);

	if (!valid_username(username) || !valid_email(email))
		return fail(message, message_size, "Enter the account's username and the email it was created with.");

	const auto client = connect(message, message_size);
	if (!client)
		return -1;

	if (const auto error = client->send_reset_token(username, email); error != rpcn::ErrorType::NoError)
		return fail(message, message_size, error_text(error, "username or email"));

	return done(message, message_size, "A password reset token was sent to the account's email.");
}

extern "C" int rpcs3_ios_rpcn_reset_password(const char* username_text, const char* token_text, const char* password_text, char* message, size_t message_size)
{
	const std::string username = text(username_text);
	const std::string token = text(token_text);
	const std::string password = text(password_text);

	if (!valid_username(username))
		return fail(message, message_size, "A username has 3 to 16 letters, digits, '-' or '_'.");
	if (!valid_token(token))
		return fail(message, message_size, "The reset token from the email has 16 characters, digits and capital letters.");
	if (password.empty())
		return fail(message, message_size, "Choose a new password.");

	const auto client = connect(message, message_size);
	if (!client)
		return -1;

	const std::string derived = derive_password(password);

	if (const auto error = client->reset_password(username, token, derived); error != rpcn::ErrorType::NoError)
		return fail(message, message_size, error_text(error, "username or token"));

	g_cfg_rpcn.load();
	g_cfg_rpcn.set_npid(username);
	g_cfg_rpcn.set_password(derived);
	g_cfg_rpcn.save();
	return done(message, message_size, "The password was changed.");
}

extern "C" int rpcs3_ios_rpcn_delete_account(char* message, size_t message_size)
{
	g_cfg_rpcn.load();
	if (g_cfg_rpcn.npid.to_string().empty() || g_cfg_rpcn.get_password().empty())
		return fail(message, message_size, "Set up an account first.");

	const auto client = connect(message, message_size);
	if (!client)
		return -1;

	if (const auto error = client->delete_account(); error != rpcn::ErrorType::NoError)
		return fail(message, message_size, error_text(error, "username or password"));

	// The account is gone: forget it here too
	g_cfg_rpcn.set_npid("");
	g_cfg_rpcn.set_password("");
	g_cfg_rpcn.set_token("");
	g_cfg_rpcn.save();
	rpcn_ios_log.warning("Deleted the RPCN account");
	return done(message, message_size, "The account was deleted.");
}
