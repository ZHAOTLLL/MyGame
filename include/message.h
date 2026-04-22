#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace gn {

struct Message {
  uint32_t source = 0;
  int32_t session = 0;
  std::string proto;
  std::string payload;
};

}  // namespace gn
