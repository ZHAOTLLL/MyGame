#pragma once

#include <cstdint>
#include <functional>
#include <string>

namespace gn {

bool lua_env_init(const std::string& lua_root);
void lua_env_close();

void lua_env_set_ws_sender(std::function<void(uint64_t conn_id, const std::string& json)> fn);

bool lua_dispatch(uint64_t conn_id, const std::string& json);
bool lua_tick();

}  // namespace gn
