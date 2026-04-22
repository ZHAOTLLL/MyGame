-- Lobby：按 Skynet 风格负责登录入口、匹配、建房/进房路由；房内高频命令由 agent 直连 room。
local M = {}

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

local agents = {} -- conn_id -> { agent_id, name, room_id, room_actor }
local room_to_actor = {}
local match_q = {} -- conn_id 列表
local LOGIN_USERS = {
  ["小明"] = "111111",
  ["李华"] = "222222",
  ["Tom"] = "333333",
  ["Jack"] = "444444",
}

local function send_to_actor(aid, payload)
  gn_send(aid, type(payload) == "string" and payload or j_obj(payload))
end

local function to_conn_id(v)
  local n = tonumber(v)
  if not n then
    return nil
  end
  return math.floor(n)
end

local function new_room_id()
  return "room_" .. tostring(math.random(100000, 999999))
end

local function remove_from_match_queue(conn_id)
  for i = #match_q, 1, -1 do
    if match_q[i] == conn_id then
      table.remove(match_q, i)
    end
  end
end

local function bind_room_for_conn(conn_id, room_id)
  local ag = agents[conn_id]
  if not ag then
    return
  end
  local aid = room_to_actor[room_id]
  ag.room_id = room_id
  ag.room_actor = aid
  if ag.agent_id then
    send_to_actor(ag.agent_id, { cmd = "__bind_room", room_id = room_id, room_actor = aid or 0 })
  end
end

local function unbind_room_for_conn(conn_id)
  local ag = agents[conn_id]
  if not ag then
    return
  end
  ag.room_id = nil
  ag.room_actor = nil
  if ag.agent_id then
    send_to_actor(ag.agent_id, { cmd = "__unbind_room" })
  end
end

local function leave_room_if_any(conn_id, skip_ack)
  local ag = agents[conn_id]
  if not ag or not ag.room_actor then
    return
  end
  send_to_actor(ag.room_actor, {
    cmd = "leave_room",
    __from_conn = conn_id,
    skip_ack = skip_ack and true or false,
  })
  ag.room_id = nil
  ag.room_actor = nil
  if ag.agent_id then
    send_to_actor(ag.agent_id, { cmd = "__unbind_room" })
  end
end

local function send_agent_error(conn_id, reason)
  local ag = agents[conn_id]
  if ag and ag.agent_id then
    send_to_actor(ag.agent_id, { cmd = "__error", reason = reason })
  else
    gn_send_ws(conn_id, j_obj({ cmd = "error", reason = reason }))
  end
end

local function on_login(conn_id, name, password)
  local expect = LOGIN_USERS[name]
  if not expect or tostring(password or "") ~= expect then
    gn_send_ws(conn_id, j_obj({ cmd = "error", reason = "bad_account_or_password" }))
    return
  end
  local old = agents[conn_id]
  if old and old.agent_id then
    send_to_actor(old.agent_id, { cmd = "__kick_by_relogin" })
  end

  local aid = gn_spawn("agent_actor", j_obj({ conn_id = conn_id, name = name }))
  if aid == nil or aid == 0 then
    gn_send_ws(conn_id, j_obj({ cmd = "error", reason = "spawn_agent_fail" }))
    return
  end

  gn_bind_conn(conn_id, aid)
  agents[conn_id] = { agent_id = aid, name = name, room_id = nil, room_actor = nil }
  send_to_actor(aid, { cmd = "__login_ok" })
end

local function on_agent_create_room(msg)
  local conn_id = msg.conn_id
  local ag = agents[conn_id]
  if not ag then
    return
  end
  leave_room_if_any(conn_id, true)
  local rid = new_room_id()
  local init = j_obj({ room_id = rid, host_conn = conn_id, host_name = ag.name })
  local raid = gn_spawn("room_actor", init)
  if raid == nil or raid == 0 then
    send_agent_error(conn_id, "spawn_fail")
    return
  end
  room_to_actor[rid] = raid
  bind_room_for_conn(conn_id, rid)
end

local function on_agent_create_idiom_room(msg)
  local conn_id = msg.conn_id
  local ag = agents[conn_id]
  if not ag then
    return
  end
  leave_room_if_any(conn_id, true)
  local rid = new_room_id()
  local init = j_obj({ room_id = rid, host_conn = conn_id, host_name = ag.name })
  local raid = gn_spawn("idiom_room_actor", init)
  if raid == nil or raid == 0 then
    send_agent_error(conn_id, "spawn_fail")
    return
  end
  room_to_actor[rid] = raid
  bind_room_for_conn(conn_id, rid)
end

local function on_agent_join_room(msg)
  local conn_id = msg.conn_id
  local rid = tostring(msg.room_id or "")
  local ag = agents[conn_id]
  if not ag then
    return
  end
  if ag.room_id == rid then
    send_agent_error(conn_id, "already_in_room")
    return
  end
  leave_room_if_any(conn_id, true)
  local raid = room_to_actor[rid]
  if not raid then
    send_agent_error(conn_id, "no_room")
    return
  end
  send_to_actor(raid, {
    cmd = "join",
    __from_conn = conn_id,
    name = ag.name,
  })
end

local function on_agent_match(msg)
  local conn_id = msg.conn_id
  local ag = agents[conn_id]
  if not ag then
    return
  end
  leave_room_if_any(conn_id, true)
  remove_from_match_queue(conn_id)
  match_q[#match_q + 1] = conn_id
  send_to_actor(ag.agent_id, { cmd = "__match_queued", position = #match_q })

  if #match_q < 4 then
    return
  end

  local rid = new_room_id()
  local players = {}
  for i = 1, 4 do
    local cid = match_q[i]
    local a = agents[cid]
    players[i] = { conn_id = cid, name = (a and a.name) or ("玩家" .. tostring(cid)) }
  end

  local raid = gn_spawn("room_actor", j_obj({ room_id = rid, match = true, players = players }))
  if raid == nil or raid == 0 then
    for i = 1, 4 do
      local cid = match_q[i]
      send_agent_error(cid, "spawn_fail")
    end
    match_q = {}
    return
  end

  room_to_actor[rid] = raid
  for i = 1, 4 do
    bind_room_for_conn(match_q[i], rid)
  end
  match_q = {}
end

local function on_agent_leave_room(msg)
  local conn_id = to_conn_id(msg.conn_id)
  if not conn_id then
    return
  end
  local ag = agents[conn_id]
  if not ag or not ag.room_actor then
    send_agent_error(conn_id, "not_in_room")
    return
  end
  leave_room_if_any(conn_id, false)
end

local function on_agent_disconnect(msg)
  local conn_id = to_conn_id(msg.conn_id)
  if not conn_id then
    return
  end
  remove_from_match_queue(conn_id)
  leave_room_if_any(conn_id, true)
  agents[conn_id] = nil
  gn_unbind_conn(conn_id)
end

function M.handle_client(conn_id, msg)
  local cmd = msg.cmd
  if cmd == "login" then
    local name = tostring(msg.name or "旅人")
    name = name:sub(1, 16)
    on_login(conn_id, name, tostring(msg.password or ""))
    return
  end

  if cmd == "disconnect" then
    on_agent_disconnect({ conn_id = conn_id })
    return
  end

  -- 未绑定 agent 前，只有 login 有效
  gn_send_ws(conn_id, j_obj({ cmd = "error", reason = "need_login" }))
end

function M.handle_system(msg)
  local cmd = msg.cmd
  if cmd == "__lobby_join_ok" then
    bind_room_for_conn(msg.conn_id, msg.room_id)
    return
  end
  if cmd == "__lobby_detach" then
    unbind_room_for_conn(msg.conn_id)
    return
  end
  if cmd == "__room_destroyed" then
    room_to_actor[msg.room_id] = nil
    return
  end

  if cmd == "agent_create_room" then
    on_agent_create_room(msg)
    return
  end
  if cmd == "agent_create_idiom_room" then
    on_agent_create_idiom_room(msg)
    return
  end
  if cmd == "agent_join_room" then
    on_agent_join_room(msg)
    return
  end
  if cmd == "agent_match" then
    on_agent_match(msg)
    return
  end
  if cmd == "agent_leave_room" then
    on_agent_leave_room(msg)
    return
  end
  if cmd == "agent_disconnect" then
    on_agent_disconnect(msg)
    return
  end
end

return M
