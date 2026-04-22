#pragma once

#include <cstdint>
#include <functional>
#include <string>

namespace gn {

// HTTP static files + WebSocket at /ws (one thread per connection)
void http_ws_run(uint16_t port, const std::string& web_root,
                 std::function<void(uint64_t conn_id, const std::string& json)> on_message,
                 std::function<void(uint64_t conn_id)> on_disconnect);

void http_ws_stop();
void http_ws_send(uint64_t conn_id, const std::string& text);

}  // namespace gn
