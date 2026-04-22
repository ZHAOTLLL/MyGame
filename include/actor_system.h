#pragma once

#include <cstdint>
#include <functional>
#include <memory>
#include <string>

namespace gn {

// Skynet-style: many actors, each with own inbox; worker threads pop runnable actors.
// Each actor owns one lua_State (separate Lua VM).
constexpr uint32_t kLobbyActorId = 1;

using WsSendFn = std::function<void(uint64_t conn_id, const std::string& json)>;

bool actor_system_init(const std::string& lua_root, WsSendFn ws_send);
void actor_system_shutdown();

// Async: worker threads run handle() on the target actor.
void actor_send(uint32_t to_actor, const std::string& json, uint32_t from_actor = 0);
void actor_send_conn(uint64_t conn_id, const std::string& json);

// Spawn: load lua/service/<name>.lua, first message is {"__init":true,...params}
uint32_t actor_spawn(const std::string& service_name, const std::string& init_json);

void actor_tick_all();

uint32_t actor_current_id();
uint32_t liar_agent_pool_actor_id();

}  // namespace gn
