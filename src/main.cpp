#include "http_ws_server.h"
#include "proto_packet.h"
#include "skynet.h"

#include <chrono>
#include <cstdio>
#include <filesystem>
#include <string>
#include <thread>
#include <vector>

#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#endif

namespace {

namespace fs = std::filesystem;

fs::path exe_directory() {
#ifdef _WIN32
  char buf[MAX_PATH] = {};
  DWORD n = GetModuleFileNameA(nullptr, buf, MAX_PATH);
  if (n == 0 || n >= MAX_PATH) {
    return {};
  }
  return fs::path(buf).parent_path();
#else
  return fs::current_path();
#endif
}

// Find folder containing marker: cwd, next to exe, or parent of exe (e.g. build2/lua when exe is in Release/).
std::string resolve_asset_dir(const char* dir_name, const fs::path& marker_rel) {
  std::vector<fs::path> candidates;
  candidates.push_back(fs::current_path() / dir_name);
  fs::path ed = exe_directory();
  if (!ed.empty()) {
    candidates.push_back(ed / dir_name);
    candidates.push_back(ed.parent_path() / dir_name);
  }
  for (const auto& base : candidates) {
    if (fs::exists(base / marker_rel)) {
      return fs::absolute(base).lexically_normal().generic_string();
    }
  }
  return {};
}

}  // namespace

int main(int argc, char** argv) {
  std::setvbuf(stdout, nullptr, _IONBF, 0);
  std::setvbuf(stderr, nullptr, _IONBF, 0);
  std::puts("Groundnet: starting...");

  std::string lua_root = (argc >= 2 && argv[1]) ? argv[1] : "lua";
  std::string web_root = (argc >= 3 && argv[2]) ? argv[2] : "web";

  if (argc < 2 || !argv[1]) {
    std::string found = resolve_asset_dir("lua", fs::path("bootstrap.lua"));
    if (!found.empty()) {
      lua_root = std::move(found);
    }
  }
  if (argc < 3 || !argv[2]) {
    std::string found = resolve_asset_dir("web", fs::path("index.html"));
    if (!found.empty()) {
      web_root = std::move(found);
    }
  }

  std::printf("Working directory: %s\n", fs::current_path().string().c_str());
  std::printf("Lua root:  %s\n", lua_root.c_str());
  std::printf("Web root:  %s\n", web_root.c_str());

  if (!fs::exists(fs::path(lua_root) / "bootstrap.lua")) {
    std::printf(
        "ERROR: cannot find lua/bootstrap.lua.\n"
        "  Run the exe from the build directory (e.g. build2) where CMake copied the lua/ folder,\n"
        "  or pass: groundnet.exe <path-to-lua-dir> <path-to-web-dir>\n");
    return 1;
  }
  if (!fs::exists(fs::path(web_root) / "index.html")) {
    std::printf(
        "ERROR: cannot find web/index.html.\n"
        "  Pass the web folder as second argument, or build with CMake so web/ is copied next to the exe.\n");
    return 1;
  }

  const uint16_t port = 8765;

  if (!gn::skynet_init(lua_root)) {
    std::printf("ERROR: skynet_init failed (see messages above about bootstrap.lua).\n");
    return 1;
  }
  std::puts("Lua VM and bootstrap OK.");

  gn::skynet_set_ws_sender(
      [](uint64_t conn_id, const std::string& json) { gn::http_ws_send(conn_id, json); });

  gn::http_ws_run(
      port, web_root,
      [](uint64_t conn_id, const std::string& packet) {
        gn::skynet_handle_client_packet(conn_id, packet);
      },
      [](uint64_t conn_id) {
        gn::skynet_post([conn_id]() {
          std::string j = "{\"cmd\":\"disconnect\",\"conn_id\":" + std::to_string(conn_id) + "}";
          gn::skynet_handle_client_packet(conn_id, gn::pb_encode_ws_packet(j));
        });
      });

  std::printf(
      "Server ready.\n"
      "  HTTP:  http://127.0.0.1:%u/\n"
      "  WebSocket: ws://127.0.0.1:%u/ws\n"
      "Press Ctrl+C to stop.\n",
      static_cast<unsigned>(port), static_cast<unsigned>(port));

  for (;;) {
    std::this_thread::sleep_for(std::chrono::milliseconds(400));
    gn::skynet_post([] { gn::skynet_tick(); });
  }
}
