#include "lua_env.h"

extern "C" {
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
}
#include <nlohmann/json.hpp>

#include <cstdio>
#include <string>

namespace gn {

namespace {

lua_State* g_L = nullptr;
std::string g_lua_root;
std::function<void(uint64_t, const std::string&)> g_ws_send;

static int l_send_ws(lua_State* L) {
  if (!g_ws_send) {
    return 0;
  }
  lua_Integer cid = luaL_checkinteger(L, 1);
  size_t len = 0;
  const char* s = luaL_checklstring(L, 2, &len);
  g_ws_send(static_cast<uint64_t>(cid), std::string(s, len));
  return 0;
}

static int l_log(lua_State* L) {
  const char* s = luaL_checkstring(L, 1);
  std::fprintf(stderr, "[lua] %s\n", s);
  return 0;
}

static void push_json(lua_State* L, const nlohmann::json& j) {
  if (j.is_null()) {
    lua_pushnil(L);
  } else if (j.is_boolean()) {
    lua_pushboolean(L, j.get<bool>() ? 1 : 0);
  } else if (j.is_number()) {
    if (j.is_number_integer()) {
      lua_pushinteger(L, static_cast<lua_Integer>(j.get<int64_t>()));
    } else {
      lua_pushnumber(L, j.get<double>());
    }
  } else if (j.is_string()) {
    auto str = j.get<std::string>();
    lua_pushlstring(L, str.data(), str.size());
  } else if (j.is_array()) {
    lua_createtable(L, static_cast<int>(j.size()), 0);
    int i = 1;
    for (const auto& el : j) {
      push_json(L, el);
      lua_rawseti(L, -2, i++);
    }
  } else if (j.is_object()) {
    lua_createtable(L, 0, static_cast<int>(j.size()));
    for (auto it = j.begin(); it != j.end(); ++it) {
      const std::string key = it.key();
      lua_pushlstring(L, key.data(), key.size());
      push_json(L, it.value());
      lua_rawset(L, -3);
    }
  } else {
    lua_pushnil(L);
  }
}

}  // namespace

void lua_env_set_ws_sender(std::function<void(uint64_t, const std::string&)> fn) {
  g_ws_send = std::move(fn);
}

bool lua_env_init(const std::string& lua_root) {
  g_lua_root = lua_root;
  g_L = luaL_newstate();
  if (!g_L) {
    std::fprintf(stdout, "ERROR: luaL_newstate failed.\n");
    return false;
  }
  luaL_openlibs(g_L);

  std::string path = g_lua_root + "/?.lua;" + g_lua_root + "/?/init.lua;";
  lua_getglobal(g_L, "package");
  lua_getfield(g_L, -1, "path");
  const char* curp = lua_tolstring(g_L, -1, nullptr);
  std::string cur = curp ? std::string(curp) : std::string();
  lua_pop(g_L, 1);
  std::string merged = path + cur;
  lua_pushlstring(g_L, merged.data(), merged.size());
  lua_setfield(g_L, -2, "path");
  lua_pop(g_L, 1);

  lua_register(g_L, "gn_send_ws", l_send_ws);
  lua_register(g_L, "gn_log", l_log);

  const std::string boot = g_lua_root + "/bootstrap.lua";
  if (luaL_dofile(g_L, boot.c_str()) != LUA_OK) {
    const char* em = lua_tolstring(g_L, -1, nullptr);
    std::fprintf(stdout, "ERROR loading %s: %s\n", boot.c_str(), em ? em : "(non-string error)");
    lua_close(g_L);
    g_L = nullptr;
    return false;
  }
  return true;
}

void lua_env_close() {
  if (g_L) {
    lua_close(g_L);
    g_L = nullptr;
  }
  g_ws_send = nullptr;
}

bool lua_dispatch(uint64_t conn_id, const std::string& json) {
  if (!g_L) {
    return false;
  }
  nlohmann::json j;
  try {
    j = nlohmann::json::parse(json);
  } catch (...) {
    return false;
  }
  lua_getglobal(g_L, "dispatch");
  if (!lua_isfunction(g_L, -1)) {
    lua_pop(g_L, 1);
    return false;
  }
  lua_pushinteger(g_L, static_cast<lua_Integer>(conn_id));
  push_json(g_L, j);
  if (lua_pcall(g_L, 2, 0, 0) != LUA_OK) {
    const char* em = lua_tolstring(g_L, -1, nullptr);
    std::fprintf(stderr, "dispatch err: %s\n", em ? em : "(non-string error)");
    lua_pop(g_L, 1);
    return false;
  }
  return true;
}

bool lua_tick() {
  if (!g_L) {
    return false;
  }
  lua_getglobal(g_L, "tick");
  if (!lua_isfunction(g_L, -1)) {
    lua_pop(g_L, 1);
    return true;
  }
  if (lua_pcall(g_L, 0, 0, 0) != LUA_OK) {
    const char* em = lua_tolstring(g_L, -1, nullptr);
    std::fprintf(stderr, "tick err: %s\n", em ? em : "(non-string error)");
    lua_pop(g_L, 1);
    return false;
  }
  return true;
}

}  // namespace gn
