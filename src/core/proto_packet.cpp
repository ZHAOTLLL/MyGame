#include "proto_packet.h"

#include <cstdint>

namespace gn {

namespace {

void append_varint(std::string& out, uint64_t v) {
  while (v >= 0x80) {
    out.push_back(static_cast<char>((v & 0x7F) | 0x80));
    v >>= 7;
  }
  out.push_back(static_cast<char>(v & 0x7F));
}

bool read_varint(const std::string& in, size_t& off, uint64_t& out) {
  out = 0;
  int shift = 0;
  for (int i = 0; i < 10; ++i) {
    if (off >= in.size()) {
      return false;
    }
    uint8_t b = static_cast<uint8_t>(in[off++]);
    out |= static_cast<uint64_t>(b & 0x7F) << shift;
    if ((b & 0x80) == 0) {
      return true;
    }
    shift += 7;
  }
  return false;
}

bool maybe_json_text(const std::string& s) {
  for (char c : s) {
    if (c == ' ' || c == '\t' || c == '\r' || c == '\n') {
      continue;
    }
    return c == '{' || c == '[';
  }
  return false;
}

}  // namespace

std::string pb_encode_ws_packet(const std::string& json_payload) {
  std::string out;
  out.reserve(json_payload.size() + 8);
  out.push_back(static_cast<char>(0x0A));  // field 1, wire type 2
  append_varint(out, static_cast<uint64_t>(json_payload.size()));
  out.append(json_payload);
  return out;
}

bool pb_decode_ws_packet(const std::string& packet, std::string& json_payload) {
  if (maybe_json_text(packet)) {
    json_payload = packet;
    return true;
  }

  size_t off = 0;
  bool seen_json = false;
  std::string parsed_json;

  while (off < packet.size()) {
    uint64_t key = 0;
    if (!read_varint(packet, off, key)) {
      return false;
    }
    uint32_t field_no = static_cast<uint32_t>(key >> 3);
    uint32_t wire_type = static_cast<uint32_t>(key & 0x07);

    if (wire_type == 2) {
      uint64_t len = 0;
      if (!read_varint(packet, off, len)) {
        return false;
      }
      if (off + static_cast<size_t>(len) > packet.size()) {
        return false;
      }
      if (field_no == 1) {
        parsed_json.assign(packet.data() + off, static_cast<size_t>(len));
        seen_json = true;
      }
      off += static_cast<size_t>(len);
      continue;
    }

    if (wire_type == 0) {  // varint
      uint64_t dummy = 0;
      if (!read_varint(packet, off, dummy)) {
        return false;
      }
      continue;
    }
    return false;
  }

  if (!seen_json) {
    return false;
  }
  json_payload = std::move(parsed_json);
  return true;
}

}  // namespace gn
