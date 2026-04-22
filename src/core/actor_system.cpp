#include "actor_system.h"

extern "C" {
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
}

#include <nlohmann/json.hpp>

#include <atomic>
#include <cstdlib>
#include <condition_variable>
#include <cstdio>
#include <fstream>
#include <mutex>
#include <queue>
#include <sstream>
#include <thread>
#include <unordered_map>
#include <vector>

#ifdef _WIN32
#include <windows.h>
#include <winhttp.h>
#pragma comment(lib, "winhttp.lib")
#else
#include <unistd.h>
#endif

namespace gn {

thread_local uint32_t g_tls_actor_id = 0;

std::string g_lua_root;
WsSendFn g_ws_send;

struct Actor {
  uint32_t id = 0;
  std::string service_name;
  lua_State* L = nullptr;
  std::queue<std::string> inbox;
  std::mutex inbox_mtx;
  std::atomic<bool> enqueued{false};
  std::atomic<bool> running{false};
};

std::mutex g_map_mtx;
std::unordered_map<uint32_t, std::unique_ptr<Actor>> g_actors;
std::mutex g_conn_mtx;
std::unordered_map<uint64_t, uint32_t> g_conn_route;

std::mutex g_run_mtx;
std::condition_variable g_run_cv;
std::queue<uint32_t> g_runnable;
std::atomic<bool> g_running{true};

std::atomic<uint32_t> g_next_actor_id{2};
std::mutex g_llm_mtx;
std::atomic<uint32_t> g_liar_agent_pool_id{0};

static constexpr int kWorkerThreads = 4;
std::vector<std::thread> g_workers;

void schedule(uint32_t id);

static void push_runnable(uint32_t id) {
  {
    std::lock_guard<std::mutex> lk(g_run_mtx);
    g_runnable.push(id);
  }
  g_run_cv.notify_one();
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

static bool dispatch_lua(Actor* a, const std::string& json) {
  nlohmann::json j;
  try {
    j = nlohmann::json::parse(json);
  } catch (...) {
    return false;
  }
  lua_getglobal(a->L, "handle");
  if (!lua_isfunction(a->L, -1)) {
    lua_pop(a->L, 1);
    std::fprintf(stderr, "[actor %u] no global handle()\n", a->id);
    return false;
  }
  push_json(a->L, j);
  g_tls_actor_id = a->id;
  if (lua_pcall(a->L, 1, 0, 0) != LUA_OK) {
    const char* em = lua_tolstring(a->L, -1, nullptr);
    std::fprintf(stderr, "[actor %u] handle err: %s\n", a->id, em ? em : "?");
    lua_pop(a->L, 1);
    g_tls_actor_id = 0;
    return false;
  }
  g_tls_actor_id = 0;
  return true;
}

void schedule(uint32_t id) {
  Actor* actor = nullptr;
  {
    std::lock_guard<std::mutex> mk(g_map_mtx);
    auto it = g_actors.find(id);
    if (it == g_actors.end()) {
      return;
    }
    actor = it->second.get();
  }
  bool expected = false;
  if (!actor->enqueued.compare_exchange_strong(expected, true, std::memory_order_acq_rel)) {
    return;
  }
  push_runnable(id);
}

static bool inbox_nonempty(Actor* a) {
  std::lock_guard<std::mutex> lk(a->inbox_mtx);
  return !a->inbox.empty();
}

static std::string pop_inbox(Actor* a) {
  std::lock_guard<std::mutex> lk(a->inbox_mtx);
  if (a->inbox.empty()) {
    return {};
  }
  std::string m = std::move(a->inbox.front());
  a->inbox.pop();
  return m;
}

static void worker_loop() {
  while (g_running) {
    uint32_t id = 0;
    {
      std::unique_lock<std::mutex> lk(g_run_mtx);
      g_run_cv.wait(lk, [] { return !g_runnable.empty() || !g_running; });
      if (!g_running && g_runnable.empty()) {
        break;
      }
      if (g_runnable.empty()) {
        continue;
      }
      id = g_runnable.front();
      g_runnable.pop();
    }
    Actor* actor = nullptr;
    {
      std::lock_guard<std::mutex> mk(g_map_mtx);
      auto it = g_actors.find(id);
      if (it == g_actors.end()) {
        continue;
      }
      actor = it->second.get();
    }
    actor->enqueued.store(false, std::memory_order_release);
    bool expected = false;
    if (!actor->running.compare_exchange_strong(expected, true, std::memory_order_acq_rel)) {
      if (inbox_nonempty(actor)) {
        schedule(id);
      }
      continue;
    }
    std::string msg = pop_inbox(actor);
    if (msg.empty()) {
      actor->running.store(false, std::memory_order_release);
      continue;
    }
    dispatch_lua(actor, msg);
    actor->running.store(false, std::memory_order_release);
    if (inbox_nonempty(actor)) {
      schedule(id);
    }
  }
}

static void set_lua_path(lua_State* L) {
  std::string path = g_lua_root + "/?.lua;" + g_lua_root + "/?/init.lua;";
  lua_getglobal(L, "package");
  lua_getfield(L, -1, "path");
  const char* curp = lua_tolstring(L, -1, nullptr);
  std::string cur = curp ? std::string(curp) : std::string();
  lua_pop(L, 1);
  std::string merged = path + cur;
  lua_pushlstring(L, merged.data(), merged.size());
  lua_setfield(L, -2, "path");
  lua_pop(L, 1);
}

static void register_lua_api(lua_State* L);

bool load_actor_script(Actor* a, const std::string& service_name) {
  a->service_name = service_name;
  a->L = luaL_newstate();
  if (!a->L) {
    return false;
  }
  luaL_openlibs(a->L);
  set_lua_path(a->L);
  register_lua_api(a->L);
  std::string fp = g_lua_root + "/service/" + service_name + ".lua";
  if (luaL_dofile(a->L, fp.c_str()) != LUA_OK) {
    const char* em = lua_tolstring(a->L, -1, nullptr);
    std::fprintf(stderr, "ERROR loading %s: %s\n", fp.c_str(), em ? em : "?");
    lua_close(a->L);
    a->L = nullptr;
    return false;
  }
  return true;
}

static void actor_send_impl(uint32_t to_actor, const std::string& json) {
  Actor* target = nullptr;
  {
    std::lock_guard<std::mutex> lk(g_map_mtx);
    auto it = g_actors.find(to_actor);
    if (it == g_actors.end()) {
      return;
    }
    target = it->second.get();
  }
  {
    std::lock_guard<std::mutex> lk(target->inbox_mtx);
    target->inbox.push(json);
  }
  schedule(to_actor);
}

static uint32_t actor_spawn_impl(const std::string& service_name, const std::string& init_json) {
  uint32_t id = g_next_actor_id.fetch_add(1);
  auto actor = std::make_unique<Actor>();
  actor->id = id;
  if (!load_actor_script(actor.get(), service_name)) {
    return 0;
  }
  {
    std::lock_guard<std::mutex> lk(g_map_mtx);
    g_actors[id] = std::move(actor);
  }
  nlohmann::json j;
  try {
    j = nlohmann::json::parse(init_json.empty() ? "{}" : init_json);
  } catch (const std::exception& e) {
    std::fprintf(stderr, "ERROR spawn %s: bad init json: %s\n", service_name.c_str(), e.what());
    return 0;
  } catch (...) {
    std::fprintf(stderr, "ERROR spawn %s: bad init json\n", service_name.c_str());
    return 0;
  }
  j["__init"] = true;
  actor_send_impl(id, j.dump());
  return id;
}

static int l_gn_send_ws(lua_State* L) {
  if (!g_ws_send) {
    return 0;
  }
  lua_Integer cid = luaL_checkinteger(L, 1);
  size_t len = 0;
  const char* s = luaL_checklstring(L, 2, &len);
  g_ws_send(static_cast<uint64_t>(cid), std::string(s, len));
  return 0;
}

static int l_gn_send(lua_State* L) {
  uint32_t to = static_cast<uint32_t>(luaL_checkinteger(L, 1));
  size_t len = 0;
  const char* s = luaL_checklstring(L, 2, &len);
  actor_send_impl(to, std::string(s, len));
  return 0;
}

static int l_gn_spawn(lua_State* L) {
  const char* svc = luaL_checkstring(L, 1);
  size_t len = 0;
  const char* init = luaL_checklstring(L, 2, &len);
  uint32_t id = actor_spawn_impl(svc, std::string(init, len));
  lua_pushinteger(L, static_cast<lua_Integer>(id));
  return 1;
}

static int l_gn_self(lua_State* L) {
  (void)L;
  lua_pushinteger(L, static_cast<lua_Integer>(g_tls_actor_id));
  return 1;
}

static int l_gn_liar_agent_pool(lua_State* L) {
  (void)L;
  lua_pushinteger(L, static_cast<lua_Integer>(g_liar_agent_pool_id.load(std::memory_order_acquire)));
  return 1;
}

static std::string shell_quote(const std::string& s) {
  std::string out = "'";
  for (char c : s) {
    if (c == '\'') {
      out += "'\"'\"'";
    } else {
      out.push_back(c);
    }
  }
  out.push_back('\'');
  return out;
}

static std::string run_command_capture(const std::string& cmd) {
  std::string out;
#ifdef _WIN32
  FILE* pipe = _popen(cmd.c_str(), "r");
#else
  FILE* pipe = popen(cmd.c_str(), "r");
#endif
  if (!pipe) {
    return {};
  }
  char buf[4096];
  while (std::fgets(buf, sizeof(buf), pipe)) {
    out += buf;
  }
#ifdef _WIN32
  _pclose(pipe);
#else
  pclose(pipe);
#endif
  return out;
}

static std::string llm_chat_impl(const std::string& model, const std::string& prompt) {
  std::lock_guard<std::mutex> guard(g_llm_mtx);
#ifdef _WIN32
  const char* k1 = std::getenv("ARK_API_KEY");
  const char* k2 = std::getenv("VOLCENGINE_API_KEY");
  std::string api_key = (k1 && *k1) ? std::string(k1) : ((k2 && *k2) ? std::string(k2) : std::string());
  if (api_key.empty()) {
    return {};
  }

  nlohmann::json body = {
      {"model", model},
      {"messages", nlohmann::json::array({{{"role", "user"}, {"content", prompt}}})},
      {"temperature", 0.2},
      {"max_tokens", 64},
  };
  std::string payload = body.dump();

  HINTERNET hSession = WinHttpOpen(L"Groundnet/1.0", WINHTTP_ACCESS_TYPE_DEFAULT_PROXY, WINHTTP_NO_PROXY_NAME,
                                   WINHTTP_NO_PROXY_BYPASS, 0);
  if (!hSession) {
    return {};
  }
  HINTERNET hConnect = WinHttpConnect(hSession, L"ark.cn-beijing.volces.com", INTERNET_DEFAULT_HTTPS_PORT, 0);
  if (!hConnect) {
    WinHttpCloseHandle(hSession);
    return {};
  }
  HINTERNET hRequest = WinHttpOpenRequest(hConnect, L"POST", L"/api/v3/chat/completions", nullptr,
                                          WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES, WINHTTP_FLAG_SECURE);
  if (!hRequest) {
    WinHttpCloseHandle(hConnect);
    WinHttpCloseHandle(hSession);
    return {};
  }

  // Some model providers may take several seconds to respond.
  WinHttpSetTimeouts(hRequest, 10000, 10000, 60000, 60000);

  std::wstring headers = L"Content-Type: application/json\r\nAuthorization: Bearer ";
  headers.append(std::wstring(api_key.begin(), api_key.end()));
  headers.append(L"\r\n");

  BOOL ok = WinHttpSendRequest(hRequest, headers.c_str(), static_cast<DWORD>(headers.size()), (LPVOID)payload.data(),
                               static_cast<DWORD>(payload.size()), static_cast<DWORD>(payload.size()), 0);
  if (!ok || !WinHttpReceiveResponse(hRequest, nullptr)) {
    WinHttpCloseHandle(hRequest);
    WinHttpCloseHandle(hConnect);
    WinHttpCloseHandle(hSession);
    return {};
  }

  std::string resp;
  DWORD status = 0;
  DWORD status_len = sizeof(status);
  WinHttpQueryHeaders(hRequest, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER, WINHTTP_HEADER_NAME_BY_INDEX,
                      &status, &status_len, WINHTTP_NO_HEADER_INDEX);
  DWORD dwSize = 0;
  do {
    dwSize = 0;
    if (!WinHttpQueryDataAvailable(hRequest, &dwSize) || dwSize == 0) {
      break;
    }
    std::string chunk(dwSize, '\0');
    DWORD dwRead = 0;
    if (!WinHttpReadData(hRequest, chunk.data(), dwSize, &dwRead) || dwRead == 0) {
      break;
    }
    chunk.resize(dwRead);
    resp += chunk;
  } while (dwSize > 0);

  WinHttpCloseHandle(hRequest);
  WinHttpCloseHandle(hConnect);
  WinHttpCloseHandle(hSession);

  if (resp.empty()) {
    return {};
  }
  try {
    auto j = nlohmann::json::parse(resp);
    if (j.contains("choices") && j["choices"].is_array() && !j["choices"].empty() &&
        j["choices"][0].contains("message") && j["choices"][0]["message"].contains("content")) {
      return j["choices"][0]["message"]["content"].get<std::string>();
    }
    if (j.contains("error")) {
      if (j["error"].is_object() && j["error"].contains("message")) {
        return std::string("__ERR__:") + j["error"]["message"].get<std::string>();
      }
      return std::string("__ERR__:") + j["error"].dump();
    }
    if (status != 200) {
      return std::string("__ERR__:HTTP_") + std::to_string(status);
    }
    return std::string("__ERR__:unexpected_response");
  } catch (...) {
    if (status != 200) {
      return std::string("__ERR__:HTTP_") + std::to_string(status);
    }
    return std::string("__ERR__:bad_json");
  }
#else
  const char* k1 = std::getenv("ARK_API_KEY");
  const char* k2 = std::getenv("VOLCENGINE_API_KEY");
  std::string api_key = (k1 && *k1) ? std::string(k1) : ((k2 && *k2) ? std::string(k2) : std::string());
  if (api_key.empty()) {
    return {};
  }

  nlohmann::json body = {
      {"model", model},
      {"prompt", prompt},
      {"temperature", 0.2},
      {"max_tokens", 128},
  };

  char tmp_name[] = "/tmp/groundnet_llm_XXXXXX";
  int fd = mkstemp(tmp_name);
  if (fd < 0) {
    return "__ERR__:mkstemp_failed";
  }
  close(fd);
  const std::string tmp_path = tmp_name;
  {
    std::ofstream ofs(tmp_path, std::ios::binary);
    if (!ofs) {
      std::remove(tmp_path.c_str());
      return "__ERR__:payload_open_failed";
    }
    ofs << body.dump();
  }

  const std::string helper = g_lua_root + "/ark_chat.py";
  const std::string cmd = "python3 " + shell_quote(helper) + " " + shell_quote(tmp_path);
  std::string raw = run_command_capture(cmd);
  std::remove(tmp_path.c_str());
  if (raw.empty()) {
    return {};
  }

  try {
    auto j = nlohmann::json::parse(raw);
    if (j.contains("ok") && j["ok"].is_boolean() && j["ok"].get<bool>()) {
      if (j.contains("content") && j["content"].is_string()) {
        return j["content"].get<std::string>();
      }
      return "__ERR__:empty_content";
    }
    if (j.contains("error")) {
      if (j["error"].is_string()) {
        return std::string("__ERR__:") + j["error"].get<std::string>();
      }
      return std::string("__ERR__:") + j["error"].dump();
    }
    return "__ERR__:unexpected_response";
  } catch (...) {
    return "__ERR__:bad_json";
  }
#endif
}

static int l_gn_llm_chat(lua_State* L) {
  const char* model = luaL_checkstring(L, 1);
  size_t plen = 0;
  const char* prompt = luaL_checklstring(L, 2, &plen);
  std::string out;
  try {
    out = llm_chat_impl(model ? model : "", std::string(prompt, plen));
  } catch (const std::exception& e) {
    out = std::string("__ERR__:llm_exception:") + e.what();
  } catch (...) {
    out = "__ERR__:llm_unknown_exception";
  }
  lua_pushlstring(L, out.data(), out.size());
  return 1;
}

static int l_gn_bind_conn(lua_State* L) {
  uint64_t cid = static_cast<uint64_t>(luaL_checkinteger(L, 1));
  uint32_t aid = static_cast<uint32_t>(luaL_checkinteger(L, 2));
  std::lock_guard<std::mutex> lk(g_conn_mtx);
  g_conn_route[cid] = aid;
  return 0;
}

static int l_gn_unbind_conn(lua_State* L) {
  uint64_t cid = static_cast<uint64_t>(luaL_checkinteger(L, 1));
  std::lock_guard<std::mutex> lk(g_conn_mtx);
  g_conn_route.erase(cid);
  return 0;
}

static void register_lua_api(lua_State* L) {
  lua_register(L, "gn_send_ws", l_gn_send_ws);
  lua_register(L, "gn_send", l_gn_send);
  lua_register(L, "gn_spawn", l_gn_spawn);
  lua_register(L, "gn_self", l_gn_self);
  lua_register(L, "gn_liar_agent_pool", l_gn_liar_agent_pool);
  lua_register(L, "gn_bind_conn", l_gn_bind_conn);
  lua_register(L, "gn_unbind_conn", l_gn_unbind_conn);
  lua_register(L, "gn_llm_chat", l_gn_llm_chat);
}

uint32_t actor_current_id() {
  return g_tls_actor_id;
}

uint32_t liar_agent_pool_actor_id() {
  return g_liar_agent_pool_id.load(std::memory_order_acquire);
}

void actor_send(uint32_t to_actor, const std::string& json, uint32_t /*from_actor*/) {
  actor_send_impl(to_actor, json);
}

void actor_send_conn(uint64_t conn_id, const std::string& json) {
  uint32_t to = kLobbyActorId;
  {
    std::lock_guard<std::mutex> lk(g_conn_mtx);
    auto it = g_conn_route.find(conn_id);
    if (it != g_conn_route.end()) {
      to = it->second;
    }
  }
  actor_send_impl(to, json);
}

uint32_t actor_spawn(const std::string& service_name, const std::string& init_json) {
  return actor_spawn_impl(service_name, init_json);
}

void actor_tick_all() {
  std::vector<uint32_t> room_ids;
  {
    std::lock_guard<std::mutex> lk(g_map_mtx);
    for (const auto& kv : g_actors) {
      const auto& a = kv.second;
      if (a && a->service_name == "room_actor") {
        room_ids.push_back(kv.first);
      } else if (a && a->service_name == "idiom_room_actor") {
        room_ids.push_back(kv.first);
      }
    }
  }
  for (uint32_t id : room_ids) {
    actor_send_impl(id, R"({"cmd":"__tick"})");
  }
}

bool actor_system_init(const std::string& lua_root, WsSendFn ws_send) {
  g_lua_root = lua_root;
  g_ws_send = std::move(ws_send);

  auto lobby = std::make_unique<Actor>();
  lobby->id = kLobbyActorId;
  if (!load_actor_script(lobby.get(), "lobby_actor")) {
    return false;
  }
  {
    std::lock_guard<std::mutex> lk(g_map_mtx);
    g_actors[kLobbyActorId] = std::move(lobby);
  }

  uint32_t pool_id = actor_spawn_impl("liar_agent_pool_actor", R"({"actor_id":0})");
  g_liar_agent_pool_id.store(pool_id, std::memory_order_release);

  g_running = true;
  for (int i = 0; i < kWorkerThreads; ++i) {
    g_workers.emplace_back(worker_loop);
  }
  return true;
}

void actor_system_shutdown() {
  g_running = false;
  g_liar_agent_pool_id.store(0, std::memory_order_release);
  g_run_cv.notify_all();
  for (auto& t : g_workers) {
    if (t.joinable()) {
      t.join();
    }
  }
  g_workers.clear();
  {
    std::lock_guard<std::mutex> lk(g_conn_mtx);
    g_conn_route.clear();
  }
  std::lock_guard<std::mutex> lk(g_map_mtx);
  for (auto& kv : g_actors) {
    if (kv.second && kv.second->L) {
      lua_close(kv.second->L);
      kv.second->L = nullptr;
    }
  }
  g_actors.clear();
}

}  // namespace gn
