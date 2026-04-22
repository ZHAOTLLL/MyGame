#pragma once

#include <string>

namespace gn {

// Protobuf-like wire packet:
// message WsPacket {
//   string json = 1;
// }
// We keep Lua/business payload as JSON string during migration.
std::string pb_encode_ws_packet(const std::string& json_payload);
bool pb_decode_ws_packet(const std::string& packet, std::string& json_payload);

}  // namespace gn
