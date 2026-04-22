#pragma once

#include "message.h"

#include <functional>
#include <string>

namespace gn {

// Skynet-like: single logic thread + queue; Lua routes by service module
bool skynet_init(const std::string& lua_root);
void skynet_shutdown();

void skynet_post(std::function<void()> fn);

using WsSender = std::function<void(uint64_t conn_id, const std::string& packet)>;
void skynet_set_ws_sender(WsSender fn);

void skynet_broadcast_lobby(const std::string& json);

void skynet_handle_client_packet(uint64_t conn_id, const std::string& packet);

void skynet_tick();

}  // namespace gn
