// Standalone process entry for optional room logic isolation (demo stub).
// Production: wire pipes/TCP from master; here only loads Lua and exits.

extern "C" {
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
}

#include <cstdio>
#include <string>

int main(int argc, char** argv) {
  const char* lua_root = (argc >= 2 && argv[1]) ? argv[1] : ".";
  std::printf("groundnet_roomd [stub] lua_root=%s\n", lua_root);

  lua_State* L = luaL_newstate();
  if (!L) {
    return 1;
  }
  luaL_openlibs(L);
  std::string path = std::string(lua_root) + "/?.lua;" + std::string(lua_root) + "/?/init.lua;";
  lua_getglobal(L, "package");
  lua_getfield(L, -1, "path");
  const char* cur = lua_tolstring(L, -1, nullptr);
  std::string merged = path + (cur ? cur : "");
  lua_pop(L, 1);
  lua_pushlstring(L, merged.data(), merged.size());
  lua_setfield(L, -2, "path");
  lua_pop(L, 1);

  std::string fp = std::string(lua_root) + "/service/room_actor.lua";
  if (luaL_dofile(L, fp.c_str()) != LUA_OK) {
    const char* e = lua_tolstring(L, -1, nullptr);
    std::fprintf(stderr, "[roomd] load %s: %s\n", fp.c_str(), e ? e : "?");
    lua_pop(L, 1);
  }
  lua_close(L);
  return 0;
}
