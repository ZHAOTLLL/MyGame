#include "http_ws_server.h"

#include "sha1.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <cstdio>
#include <fstream>
#include <memory>
#include <mutex>
#include <queue>
#include <sstream>
#include <string>
#include <thread>
#include <unordered_map>
#include <utility>
#include <vector>

#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <winsock2.h>
#include <ws2tcpip.h>
#pragma comment(lib, "ws2_32.lib")
using sock_t = SOCKET;
static const sock_t kInvalidSock = INVALID_SOCKET;
inline int sock_err() { return WSAGetLastError(); }
inline void sock_close(sock_t s) {
  if (s != kInvalidSock) {
    closesocket(s);
  }
}
inline bool sock_init() {
  WSADATA w;
  if (WSAStartup(MAKEWORD(2, 2), &w) != 0) {
    std::fprintf(stderr, "[groundnet] WSAStartup failed\n");
    std::fflush(stderr);
    return false;
  }
  return true;
}
inline void sock_fini() { WSACleanup(); }
#else
#include <errno.h>
#include <arpa/inet.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <unistd.h>
using sock_t = int;
static const sock_t kInvalidSock = -1;
inline int sock_err() { return errno; }
inline void sock_close(sock_t s) {
  if (s >= 0) {
    close(s);
  }
}
inline bool sock_init() { return true; }
inline void sock_fini() {}
#endif

namespace gn {

namespace {

std::atomic<bool> g_run{true};
std::thread g_srv;

struct ConnCtx {
  sock_t sock = kInvalidSock;
  std::mutex send_mtx;
};

std::mutex g_mx;
std::unordered_map<uint64_t, std::shared_ptr<ConnCtx>> g_socks;
std::atomic<uint64_t> g_next_id{1};

std::function<void(uint64_t, const std::string&)> g_on_msg;
std::function<void(uint64_t)> g_on_disc;

std::mutex g_msg_mx;
std::condition_variable g_msg_cv;
std::queue<std::pair<uint64_t, std::string>> g_msg_queue;
std::vector<std::thread> g_msg_workers;
size_t g_msg_worker_count = 4;

static constexpr uint64_t kMaxWsPayload = 1024 * 1024;  // 1 MiB

std::string trim(const std::string& s) {
  size_t a = 0, b = s.size();
  while (a < b && (s[a] == ' ' || s[a] == '\r' || s[a] == '\n')) {
    ++a;
  }
  while (b > a && (s[b - 1] == ' ' || s[b - 1] == '\r' || s[b - 1] == '\n')) {
    --b;
  }
  return s.substr(a, b - a);
}

std::string to_lower(std::string s) {
  for (char& c : s) {
    if (c >= 'A' && c <= 'Z') {
      c = static_cast<char>(c - 'A' + 'a');
    }
  }
  return s;
}

std::string b64_encode(const unsigned char* data, size_t len) {
  static const char* tbl =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  std::string out;
  out.reserve((len + 2) / 3 * 4);
  for (size_t i = 0; i < len; i += 3) {
    uint32_t n = static_cast<uint32_t>(data[i]) << 16;
    if (i + 1 < len) {
      n |= static_cast<uint32_t>(data[i + 1]) << 8;
    }
    if (i + 2 < len) {
      n |= static_cast<uint32_t>(data[i + 2]);
    }
    out.push_back(tbl[(n >> 18) & 63]);
    out.push_back(tbl[(n >> 12) & 63]);
    if (i + 1 < len) {
      out.push_back(tbl[(n >> 6) & 63]);
    } else {
      out.push_back('=');
    }
    if (i + 2 < len) {
      out.push_back(tbl[n & 63]);
    } else {
      out.push_back('=');
    }
  }
  return out;
}

bool recv_all(sock_t s, char* buf, size_t n) {
  size_t o = 0;
  while (o < n) {
#ifdef _WIN32
    int r = recv(s, buf + o, static_cast<int>(n - o), 0);
#else
    ssize_t r = recv(s, buf + o, n - o, 0);
#endif
    if (r <= 0) {
      return false;
    }
    o += static_cast<size_t>(r);
  }
  return true;
}

bool send_all(sock_t s, const char* buf, size_t n) {
  size_t o = 0;
  while (o < n) {
#ifdef _WIN32
    int r = send(s, buf + o, static_cast<int>(n - o), 0);
#else
    ssize_t r = send(s, buf + o, n - o, 0);
#endif
    if (r <= 0) {
      return false;
    }
    o += static_cast<size_t>(r);
  }
  return true;
}

bool read_http_headers(sock_t s, std::string& out) {
  out.clear();
  for (;;) {
    char c;
    if (!recv_all(s, &c, 1)) {
      return false;
    }
    out.push_back(c);
    if (out.size() >= 4) {
      size_t n = out.size();
      if (out[n - 4] == '\r' && out[n - 3] == '\n' && out[n - 2] == '\r' && out[n - 1] == '\n') {
        break;
      }
    }
    if (out.size() > 65536) {
      return false;
    }
  }
  return true;
}

bool parse_ws_key(const std::string& headers, std::string& key) {
  std::istringstream iss(headers);
  std::string line;
  while (std::getline(iss, line)) {
    if (line.size() >= 2 && line.back() == '\r') {
      line.pop_back();
    }
    auto colon = line.find(':');
    if (colon == std::string::npos) {
      continue;
    }
    std::string name = trim(line.substr(0, colon));
    std::string val = trim(line.substr(colon + 1));
    if (to_lower(name) == "sec-websocket-key") {
      key = val;
      return true;
    }
  }
  return false;
}

std::string ws_accept(const std::string& key) {
  const std::string magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
  std::string payload = key + magic;
  SHA1_CTX ctx;
  unsigned char digest[20];
  SHA1Init(&ctx);
  SHA1Update(&ctx, reinterpret_cast<const unsigned char*>(payload.data()),
             static_cast<uint32_t>(payload.size()));
  SHA1Final(digest, &ctx);
  return b64_encode(digest, 20);
}

bool send_ws_frame(sock_t s, const std::string& data, bool is_text) {
  std::vector<unsigned char> frame;
  size_t len = data.size();
  frame.push_back(is_text ? 0x81 : 0x82);
  if (len < 126) {
    frame.push_back(static_cast<unsigned char>(len));
  } else if (len <= 0xFFFF) {
    frame.push_back(126);
    frame.push_back(static_cast<unsigned char>((len >> 8) & 0xFF));
    frame.push_back(static_cast<unsigned char>(len & 0xFF));
  } else {
    frame.push_back(127);
    for (int i = 7; i >= 0; --i) {
      frame.push_back(static_cast<unsigned char>((len >> (i * 8)) & 0xFF));
    }
  }
  frame.insert(frame.end(), data.begin(), data.end());
  return send_all(s, reinterpret_cast<const char*>(frame.data()), frame.size());
}

bool recv_ws_frame(sock_t s, bool& is_text, std::vector<unsigned char>& payload) {
  unsigned char h[2];
  if (!recv_all(s, reinterpret_cast<char*>(h), 2)) {
    return false;
  }
  bool fin = (h[0] & 0x80) != 0;
  (void)fin;
  unsigned char opcode = h[0] & 0x0F;
  bool masked = (h[1] & 0x80) != 0;
  uint64_t len = h[1] & 0x7F;
  if (len == 126) {
    unsigned char e[2];
    if (!recv_all(s, reinterpret_cast<char*>(e), 2)) {
      return false;
    }
    len = (static_cast<uint64_t>(e[0]) << 8) | e[1];
  } else if (len == 127) {
    unsigned char e[8];
    if (!recv_all(s, reinterpret_cast<char*>(e), 8)) {
      return false;
    }
    len = 0;
    for (int i = 0; i < 8; ++i) {
      len = (len << 8) | e[i];
    }
  }
  if (len > kMaxWsPayload) {
    return false;
  }
  unsigned char mask[4] = {0, 0, 0, 0};
  if (masked) {
    if (!recv_all(s, reinterpret_cast<char*>(mask), 4)) {
      return false;
    }
  }
  payload.resize(static_cast<size_t>(len));
  if (len > 0) {
    if (!recv_all(s, reinterpret_cast<char*>(payload.data()), static_cast<size_t>(len))) {
      return false;
    }
    if (masked) {
      for (uint64_t i = 0; i < len; ++i) {
        payload[static_cast<size_t>(i)] ^= mask[i % 4];
      }
    }
  }
  is_text = (opcode == 1);
  if (opcode == 8) {
    return false;
  }
  if (opcode == 0 || opcode == 1 || opcode == 2) {
    return true;
  }
  return opcode == 9 || opcode == 10;
}

std::string safe_path(const std::string& web_root, const std::string& req_path) {
  std::string p = req_path;
  if (p.empty() || p[0] != '/') {
    p = "/" + p;
  }
  if (p.find("..") != std::string::npos) {
    return {};
  }
  if (p == "/") {
    p = "/index.html";
  }
  return web_root + p;
}

bool send_http_file(sock_t s, const std::string& path) {
  std::ifstream f(path, std::ios::binary);
  if (!f) {
    const char* err = "HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\nConnection: close\r\n\r\nNot Found";
    return send_all(s, err, strlen(err));
  }
  std::string body((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
  const char* ct = "application/octet-stream";
  if (path.size() >= 5 && path.rfind(".html") == path.size() - 5) {
    ct = "text/html; charset=utf-8";
  } else if (path.size() >= 4 && path.rfind(".css") == path.size() - 4) {
    ct = "text/css; charset=utf-8";
  } else if (path.size() >= 3 && path.rfind(".js") == path.size() - 3) {
    ct = "text/javascript; charset=utf-8";
  }
  std::ostringstream oss;
  oss << "HTTP/1.1 200 OK\r\nContent-Type: " << ct << "\r\nContent-Length: " << body.size()
      << "\r\nConnection: close\r\n\r\n";
  std::string head = oss.str();
  if (!send_all(s, head.data(), head.size())) {
    return false;
  }
  return send_all(s, body.data(), body.size());
}

void client_thread(sock_t s, const std::string& web_root) {
  std::string headers;
  if (!read_http_headers(s, headers)) {
    sock_close(s);
    return;
  }
  std::string first = headers.substr(0, headers.find("\r\n"));
  std::string method, path, ver;
  std::istringstream fl(first);
  fl >> method >> path >> ver;
  std::string hlow = to_lower(headers);
  bool want_ws = hlow.find("upgrade: websocket") != std::string::npos;
  std::string ws_key;
  if (want_ws) {
    parse_ws_key(headers, ws_key);
  }
  if (want_ws && !ws_key.empty() && (path == "/ws" || path == "/ws/")) {
    std::string acc = ws_accept(ws_key);
    std::ostringstream resp;
    resp << "HTTP/1.1 101 Switching Protocols\r\n"
         << "Upgrade: websocket\r\n"
         << "Connection: Upgrade\r\n"
         << "Sec-WebSocket-Accept: " << acc << "\r\n\r\n";
    std::string rs = resp.str();
    if (!send_all(s, rs.data(), rs.size())) {
      sock_close(s);
      return;
    }
    int keepalive = 1;
#ifdef _WIN32
    setsockopt(s, SOL_SOCKET, SO_KEEPALIVE, reinterpret_cast<const char*>(&keepalive), sizeof(keepalive));
    int nodelay = 1;
    setsockopt(s, IPPROTO_TCP, TCP_NODELAY, reinterpret_cast<const char*>(&nodelay), sizeof(nodelay));
#else
    setsockopt(s, SOL_SOCKET, SO_KEEPALIVE, &keepalive, sizeof(keepalive));
    int nodelay = 1;
    setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &nodelay, sizeof(nodelay));
#endif

    uint64_t cid = g_next_id.fetch_add(1);
    auto ctx = std::make_shared<ConnCtx>();
    ctx->sock = s;
    {
      std::lock_guard<std::mutex> lk(g_mx);
      g_socks[cid] = ctx;
    }
    for (;;) {
      bool is_text = false;
      std::vector<unsigned char> pl;
      if (!recv_ws_frame(s, is_text, pl)) {
        break;
      }
      if (pl.empty()) {
        continue;
      }
      std::string msg(pl.begin(), pl.end());
      {
        std::lock_guard<std::mutex> lk(g_msg_mx);
        g_msg_queue.emplace(cid, std::move(msg));
      }
      g_msg_cv.notify_one();
    }
    {
      std::lock_guard<std::mutex> lk(g_mx);
      g_socks.erase(cid);
    }
    if (g_on_disc) {
      g_on_disc(cid);
    }
    sock_close(s);
    return;
  }
  std::string fp = safe_path(web_root, path);
  if (!fp.empty()) {
    send_http_file(s, fp);
  } else {
    const char* err =
        "HTTP/1.1 400 Bad Request\r\nContent-Length: 11\r\nConnection: close\r\n\r\nBad Request";
    send_all(s, err, strlen(err));
  }
  sock_close(s);
}

void accept_loop(uint16_t port, std::string web_root) {
  sock_t ls = socket(AF_INET, SOCK_STREAM, 0);
  if (ls == kInvalidSock) {
    return;
  }
  int opt = 1;
#ifdef _WIN32
  setsockopt(ls, SOL_SOCKET, SO_REUSEADDR, reinterpret_cast<const char*>(&opt), sizeof(opt));
#else
  setsockopt(ls, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
#endif
  sockaddr_in addr{};
  addr.sin_family = AF_INET;
  addr.sin_addr.s_addr = INADDR_ANY;
  addr.sin_port = htons(port);
  if (bind(ls, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0) {
    std::fprintf(stderr, "[groundnet] bind port %u failed (sock %d)\n", static_cast<unsigned>(port), sock_err());
    std::fflush(stderr);
    sock_close(ls);
    return;
  }
  if (listen(ls, 1024) != 0) {
    std::fprintf(stderr, "[groundnet] listen failed (sock %d)\n", sock_err());
    std::fflush(stderr);
    sock_close(ls);
    return;
  }
  while (g_run) {
#ifdef _WIN32
    WSAPOLLFD pfd{};
    pfd.fd = ls;
    pfd.events = POLLRDNORM;
    int pr = WSAPoll(&pfd, 1, 200);
    if (pr <= 0) {
      continue;
    }
#else
    fd_set rf;
    FD_ZERO(&rf);
    FD_SET(ls, &rf);
    timeval tv{0, 200000};
    if (select(static_cast<int>(ls) + 1, &rf, nullptr, nullptr, &tv) <= 0) {
      continue;
    }
#endif
    sockaddr_in cli{};
    socklen_t clen = sizeof(cli);
    sock_t cs = accept(ls, reinterpret_cast<sockaddr*>(&cli), &clen);
    if (cs == kInvalidSock) {
      continue;
    }
    std::thread(client_thread, cs, web_root).detach();
  }
  sock_close(ls);
}

}  // namespace

static void msg_worker_loop() {
  while (g_run) {
    std::pair<uint64_t, std::string> item;
    {
      std::unique_lock<std::mutex> lk(g_msg_mx);
      g_msg_cv.wait(lk, [] { return !g_msg_queue.empty() || !g_run; });
      if (!g_run && g_msg_queue.empty()) {
        return;
      }
      item = std::move(g_msg_queue.front());
      g_msg_queue.pop();
    }
    if (g_on_msg) {
      g_on_msg(item.first, item.second);
    }
  }
}

void http_ws_send(uint64_t conn_id, const std::string& packet) {
  std::shared_ptr<ConnCtx> ctx;
  {
    std::lock_guard<std::mutex> lk(g_mx);
    auto it = g_socks.find(conn_id);
    if (it != g_socks.end()) {
      ctx = it->second;
    }
  }
  if (ctx && ctx->sock != kInvalidSock) {
    std::lock_guard<std::mutex> wlk(ctx->send_mtx);
    send_ws_frame(ctx->sock, packet, false);
  }
}

void http_ws_run(uint16_t port, const std::string& web_root,
                 std::function<void(uint64_t, const std::string&)> on_message,
                 std::function<void(uint64_t)> on_disconnect) {
  g_on_msg = std::move(on_message);
  g_on_disc = std::move(on_disconnect);
  g_run = true;
  if (!sock_init()) {
    return;
  }
  unsigned int hc = std::thread::hardware_concurrency();
  g_msg_worker_count = std::max<size_t>(4, hc == 0 ? 4 : static_cast<size_t>(hc));
  for (size_t i = 0; i < g_msg_worker_count; ++i) {
    g_msg_workers.emplace_back(msg_worker_loop);
  }
  g_srv = std::thread(accept_loop, port, web_root);
}

void http_ws_stop() {
  g_run = false;
  g_msg_cv.notify_all();
  if (g_srv.joinable()) {
    g_srv.join();
  }
  for (auto& t : g_msg_workers) {
    if (t.joinable()) {
      t.join();
    }
  }
  g_msg_workers.clear();
  {
    std::lock_guard<std::mutex> lk(g_msg_mx);
    std::queue<std::pair<uint64_t, std::string>> empty;
    g_msg_queue.swap(empty);
  }
  sock_fini();
}

}  // namespace gn
