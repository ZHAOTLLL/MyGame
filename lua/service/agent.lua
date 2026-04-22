-- Agent Actor：每连接一个，负责鉴权与 room 直连。
local M = {}
local liar_agent_runtime = require "service.liar_agent_runtime"

local function json_esc(s)
  s = tostring(s or "")
  s = s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n")
  return s
end

local function json_val(v)
  local tv = type(v)
  if tv == "table" then
    if v[1] ~= nil then
      local p = {}
      for i = 1, #v do
        p[#p + 1] = json_val(v[i])
      end
      return "[" .. table.concat(p, ",") .. "]"
    end
    local parts = {}
    for k, val in pairs(v) do
      parts[#parts + 1] = '"' .. json_esc(k) .. '":' .. json_val(val)
    end
    return "{" .. table.concat(parts, ",") .. "}"
  elseif tv == "number" then
    return tostring(v)
  elseif tv == "boolean" then
    return v and "true" or "false"
  elseif tv == "nil" then
    return "null"
  else
    return '"' .. json_esc(v) .. '"'
  end
end

local function j_obj(t)
  return json_val(t)
end

local conn_id = 0
local name = "旅人"
local token = ""
local room_id = nil
local room_actor = nil

local function mk_token(cid)
  return "tok_" .. tostring(cid) .. "_" .. tostring(math.random(10000, 99999))
end

local function send_err(reason)
  gn_send_ws(conn_id, j_obj({ cmd = "error", reason = reason }))
end

local function send_to_lobby(payload)
  gn_send(1, type(payload) == "string" and payload or j_obj(payload))
end

local function send_to_room(payload)
  if not room_actor or room_actor == 0 then
    send_err("not_in_room")
    return false
  end
  gn_send(room_actor, type(payload) == "string" and payload or j_obj(payload))
  return true
end

function M.init(msg)
  conn_id = tonumber(msg.conn_id) or 0
  name = tostring(msg.name or "旅人"):sub(1, 16)
  token = mk_token(conn_id)
  room_id = nil
  room_actor = nil
end

function M.on_system(msg)
  local cmd = msg.cmd
  if cmd == "__login_ok" then
    gn_send_ws(conn_id, j_obj({ cmd = "login_ok", token = token, name = name }))
    return
  end
  if cmd == "__error" then
    send_err(msg.reason or "unknown")
    return
  end
  if cmd == "__match_queued" then
    gn_send_ws(conn_id, j_obj({ cmd = "match_queued", position = msg.position or 1 }))
    return
  end
  if cmd == "__bind_room" then
    room_id = msg.room_id
    room_actor = tonumber(msg.room_actor) or 0
    return
  end
  if cmd == "__unbind_room" then
    room_id = nil
    room_actor = nil
    return
  end
  if cmd == "__kick_by_relogin" then
    gn_unbind_conn(conn_id)
    return
  end
end

function M.on_client(msg)
  local cmd = msg.cmd
  if not cmd then
    return
  end

  if cmd == "disconnect" then
    send_to_lobby({ cmd = "agent_disconnect", conn_id = conn_id })
    gn_unbind_conn(conn_id)
    return
  end

  if cmd == "login" then
    gn_send_ws(conn_id, j_obj({ cmd = "login_ok", token = token, name = name }))
    return
  end

  if msg.token ~= token then
    send_err("bad_token")
    return
  end

  if cmd == "create_room" then
    send_to_lobby({ cmd = "agent_create_room", conn_id = conn_id })
    return
  end
  if cmd == "create_idiom_room" then
    send_to_lobby({ cmd = "agent_create_idiom_room", conn_id = conn_id })
    return
  end
  if cmd == "join_room" then
    send_to_lobby({ cmd = "agent_join_room", conn_id = conn_id, room_id = tostring(msg.room_id or "") })
    return
  end
  if cmd == "match" then
    send_to_lobby({ cmd = "agent_match", conn_id = conn_id })
    return
  end
  if cmd == "leave_room" then
    send_to_lobby({ cmd = "agent_leave_room", conn_id = conn_id })
    return
  end
  if cmd == "llm_status" then
    local ok, reason = liar_agent_runtime.check_llm_ready()
    gn_send_ws(conn_id, j_obj({
      cmd = "llm_status",
      enabled = liar_agent_runtime.llm_enabled() and true or false,
      available = ok and true or false,
      detail = tostring(reason or ""),
      strategy = (liar_agent_runtime.llm_enabled() and ok) and "agent" or "random_fallback",
    }))
    return
  end

  if cmd == "add_bot" then
    send_to_room({ cmd = "add_bot", __from_conn = conn_id })
    return
  end
  if cmd == "set_ready" then
    send_to_room({ cmd = "set_ready", __from_conn = conn_id, ready = msg.ready })
    return
  end
  if cmd == "kick" then
    send_to_room({ cmd = "kick", __from_conn = conn_id, seat = msg.seat })
    return
  end
  if cmd == "start_game" then
    send_to_room({ cmd = "start_game", __from_conn = conn_id })
    return
  end
  if cmd == "play" then
    send_to_room({ cmd = "play", __from_conn = conn_id, cards = msg.cards })
    return
  end
  if cmd == "challenge" then
    send_to_room({ cmd = "challenge", __from_conn = conn_id })
    return
  end
  if cmd == "idiom_submit" then
    send_to_room({ cmd = "idiom_submit", __from_conn = conn_id, text = tostring(msg.text or "") })
    return
  end

  send_err("bad_cmd")
end

return M
