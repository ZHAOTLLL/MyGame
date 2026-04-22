#include "skynet.h"
#include "actor_system.h"
#include "proto_packet.h"

#include <nlohmann/json.hpp>

namespace gn {

static WsSender g_ws_sender;

bool skynet_init(const std::string& lua_root) {
  return actor_system_init(lua_root, [](uint64_t cid, const std::string& j) {
    if (g_ws_sender) {
      g_ws_sender(cid, pb_encode_ws_packet(j));
    }
  });
}

void skynet_shutdown() {
  actor_system_shutdown();
}

void skynet_post(std::function<void()> fn) {
  if (fn) {
    fn();
  }
}

void skynet_set_ws_sender(WsSender fn) {
  g_ws_sender = std::move(fn);
}

void skynet_handle_client_packet(uint64_t conn_id, const std::string& packet) {
  std::string json;
  if (!pb_decode_ws_packet(packet, json)) {
    return;
  }
  try {
    nlohmann::json j = nlohmann::json::parse(json);
    j["__from_conn"] = conn_id;
    actor_send_conn(conn_id, j.dump());
  } catch (...) {
    // ignore
  }
}

void skynet_broadcast_lobby(const std::string& json) { (void)json; }

void skynet_tick() {
  actor_tick_all();
}

}  // namespace gn
