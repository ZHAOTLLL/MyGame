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
      for i = 1, #v do p[#p + 1] = json_val(v[i]) end
      return "[" .. table.concat(p, ",") .. "]"
    end
    local parts = {}
    for k, val in pairs(v) do parts[#parts + 1] = '"' .. json_esc(k) .. '":' .. json_val(val) end
    return "{" .. table.concat(parts, ",") .. "}"
  elseif tv == "number" then return tostring(v)
  elseif tv == "boolean" then return v and "true" or "false"
  elseif tv == "nil" then return "null"
  else return '"' .. json_esc(v) .. '"' end
end
local function j_obj(t) return json_val(t) end

local room = nil
local next_bot = 1
local MODEL_ID = os.getenv("ARK_MODEL_ID")
  or os.getenv("ARK_DEFAULT_MODEL")
  or "doubao-1-5-lite-32k-250115"
local MAX_SEATS = 2
local local_idioms = {"一心一意","意气风发","发扬光大","大吉大利","利国利民","民富国强","强词夺理","理直气壮","壮志凌云","云开见日","日新月异","异口同声"}
local BOT_RETRY_LIMIT = 1
local llm_checked = false
local llm_available = false
local llm_last_check_at = 0
local llm_last_reason = ""

local function empty_seat_index(r)
  for i = 1, MAX_SEATS do if not r.seats[i] then return i end end
  return nil
end
local function alive_count(g)
  local n=0 for i=1,MAX_SEATS do if g.alive[i] then n=n+1 end end return n
end
local function next_alive(g, from)
  local i=from
  for _=1,MAX_SEATS*2 do i=i%MAX_SEATS+1 if g.alive[i] then return i end end
  return from
end
local function utf8_chars(s)
  local t = {}
  local ok = pcall(function()
    for _, c in utf8.codes(tostring(s or "")) do
      t[#t + 1] = utf8.char(c)
    end
  end)
  if not ok then
    return {}
  end
  return t
end
local function first_char(s) local t=utf8_chars(s) return t[1] or "" end
local function last_char(s) local t=utf8_chars(s) return t[#t] or "" end
local function is_cjk(ch)
  local ok, code = pcall(utf8.codepoint, ch)
  if not ok or not code then return false end
  return code >= 0x4E00 and code <= 0x9FFF
end
local function extract_first_four_cjk(s)
  local out = {}
  for _, ch in ipairs(utf8_chars(s or "")) do
    if is_cjk(ch) then
      out[#out + 1] = ch
      if #out == 4 then
        return table.concat(out)
      end
    end
  end
  return nil
end

local function broadcast(payload)
  local js = type(payload)=="string" and payload or j_obj(payload)
  for i=1,MAX_SEATS do local s=room.seats[i]; if s and s.human then gn_send_ws(s.conn_id, js) end end
end

local function build_state(for_conn)
  local g = room.game
  local seats = {}
  local my=nil
  for i=1,MAX_SEATS do
    local s=room.seats[i]
    if not s then seats[i]={empty=true}
    else
      if s.human and s.conn_id==for_conn then my=i end
      seats[i]={
        name=s.name,
        human=s.human and true or false,
        bot=(not s.human),
        alive=g and g.alive[i] or true,
        is_host=s.is_host and true or false,
        score=g and (g.score[i] or 0) or 0,
        bot_status=(room.bot_status and room.bot_status[i]) or nil,
      }
    end
  end
  return {
    game_type="idiom",
    room_id=room.id,
    phase=g and g.phase or "lobby",
    subphase="turn",
    host_seat=1,
    my_seat=my,
    turn=g and g.turn or 0,
    seats=seats,
    idiom_current=g and g.current or "",
    idiom_used_count=g and (g.used_count or 0) or 0,
  }
end
local function broadcast_state()
  for i=1,MAX_SEATS do local s=room.seats[i]; if s and s.human then gn_send_ws(s.conn_id, j_obj({cmd="room_state", state=build_state(s.conn_id)})) end end
end

local function do_leave(conn_id, skip_ack)
  for i=1,MAX_SEATS do
    local s=room.seats[i]
    if s and s.human and s.conn_id==conn_id then
      room.seats[i]=nil
      if room.game then room.game.alive[i]=false end
      gn_send(1, j_obj({cmd="__lobby_detach", conn_id=conn_id}))
      if not skip_ack then gn_send_ws(conn_id, j_obj({cmd="left_room"})) end
      broadcast({cmd="player_left", conn_id=conn_id})
      broadcast_state()
      return
    end
  end
end

local function short_bot_status(s)
  s = tostring(s or "")
  if #s > 36 then
    return s:sub(1, 36) .. "..."
  end
  return s
end

local function test_bot_api_for_idiom()
  local prompt = "你现在是成语接龙游戏的机器人玩家。请只回复：准备好了"
  local out = tostring(gn_llm_chat(MODEL_ID, prompt) or "")
  local compact = out:gsub("%s+", "")
  if #compact == 0 then
    return false, "接口空返回"
  end
  if compact:sub(1, 8) == "__ERR__:" then
    return false, short_bot_status(compact:sub(9))
  end
  return true, "API就绪"
end

local function finish_if_needed(reason)
  local g=room.game
  if not g or g.phase~="playing" then return true end
  if alive_count(g)<=1 then
    g.phase="ended"
    local win=0 for i=1,MAX_SEATS do if g.alive[i] then win=i break end end
    broadcast({cmd="game_over", winner_seat=win, reason=reason or "last_standing", text="成语接龙结束"})
    broadcast_state()
    return true
  end
  return false
end

local function bot_pick(g)
  local need = last_char(g.current)
  local prompt =
    "你在玩成语接龙。\n" ..
    "规则：只能回复一个四字中文成语，且首字必须接“" .. need .. "”。\n" ..
    "严格要求：\n" ..
    "1) 只输出4个汉字；\n" ..
    "2) 不要任何标点符号；\n" ..
    "3) 不要任何解释、前后缀、引号、换行；\n" ..
    "4) 不要输出拼音或英文。\n" ..
    "现在只回复一个四字成语。"
  local out = gn_llm_chat(MODEL_ID, prompt)
  local cand = extract_first_four_cjk(tostring(out or ""))
  if cand and first_char(cand) == need then
    return cand, "llm"
  end
  for _,v in ipairs(local_idioms) do
    if first_char(v)==need then
      return v, "fallback"
    end
  end
  return nil, "none"
end

local function check_llm_ready()
  if llm_checked and (os.time() - llm_last_check_at) < 30 then
    return llm_available
  end
  llm_checked = true
  llm_last_check_at = os.time()
  local prompt = "请仅回复“可用”两个字。"
  local out = tostring(gn_llm_chat(MODEL_ID, prompt) or "")
  local text = out:gsub("%s+", "")
  if text:sub(1, 8) == "__ERR__:" or #text == 0 then
    llm_available = false
    llm_last_reason = (#text == 0) and "empty_response" or text
  else
    llm_available = true
    llm_last_reason = "ok"
  end
  return llm_available
end

local function apply_submit(seat, text, auto)
  local g=room.game
  if g.phase~="playing" then return false, "not_playing" end
  if g.turn~=seat then return false, "not_your_turn" end
  if not g.alive[seat] then return false, "dead" end
  local chars=utf8_chars(text)
  if #chars~=4 then
    g.fail[seat]=(g.fail[seat] or 0)+1
    broadcast({cmd="idiom_invalid", seat=seat, text=text, reason="not_4_chars"})
  elseif g.used[text] then
    g.fail[seat]=(g.fail[seat] or 0)+1
    broadcast({cmd="idiom_invalid", seat=seat, text=text, reason="used"})
  elseif first_char(text)~=last_char(g.current) then
    g.fail[seat]=(g.fail[seat] or 0)+1
    broadcast({cmd="idiom_invalid", seat=seat, text=text, reason="not_linked"})
  else
    g.current=text
    g.used[text]=true
    g.used_count=g.used_count+1
    g.score[seat]=(g.score[seat] or 0)+1
    broadcast({cmd="idiom_play", seat=seat, text=text, auto=auto and true or false})
  end
  if (g.fail[seat] or 0) >= 3 then
    g.alive[seat]=false
    broadcast({cmd="idiom_out", seat=seat, text="失误三次淘汰"})
  end
  if finish_if_needed("last_standing") then return true end
  g.turn=next_alive(g, seat)
  broadcast_state()
  return true
end

function M.init(msg)
  room={id=msg.room_id,host=msg.host_conn,seats={},ready={false,false,false,false},game=nil,bot_status={}}
  room.seats[1]={human=true,conn_id=msg.host_conn,name=msg.host_name,is_host=true}
  gn_send_ws(msg.host_conn, j_obj({cmd="room_joined", room_id=room.id, your_seat=1}))
  broadcast_state()
end

function M.tick()
  local g=room and room.game
  if not g or g.phase~="playing" then return end
  local s=room.seats[g.turn]
  if s and (not s.human) and g.next_bot_at and os.time()>=g.next_bot_at then
    g.next_bot_at=os.time()+3
    local turn_seat = g.turn
    broadcast({cmd="idiom_bot_thinking", seat=turn_seat})
    local ok_pick, text, source = pcall(bot_pick, g)
    if not ok_pick then
      text = nil
      source = "exception"
      broadcast({cmd="idiom_invalid", seat=turn_seat, text="(机器人调用异常)", reason="bot_exception"})
    end
    if not text then
      g.bot_retry = g.bot_retry or {}
      g.bot_retry[turn_seat] = (g.bot_retry[turn_seat] or 0) + 1
      if g.bot_retry[turn_seat] <= BOT_RETRY_LIMIT then
        broadcast({cmd="idiom_bot_retry", seat=turn_seat, retry=g.bot_retry[turn_seat]})
        g.next_bot_at = os.time() + 2
        return
      end
      g.bot_retry[turn_seat] = 0
      g.fail[turn_seat]=(g.fail[turn_seat] or 0)+1
      broadcast({cmd="idiom_invalid", seat=turn_seat, text="(无有效成语输出)", reason="llm_no_result"})
      if (g.fail[turn_seat] or 0)>=3 then g.alive[turn_seat]=false broadcast({cmd="idiom_out", seat=turn_seat, text="失误三次淘汰"}) end
      if finish_if_needed("last_standing") then return end
      g.turn=next_alive(g,turn_seat)
      broadcast_state()
      return
    end
    g.bot_retry = g.bot_retry or {}
    g.bot_retry[turn_seat] = 0
    broadcast({cmd="idiom_bot_result", seat=turn_seat, source=source})
    apply_submit(turn_seat, text, true)
  end
end

function M.client_handle(conn_id,msg)
  if not room then return end
  local cmd=msg.cmd
  if cmd=="disconnect" then do_leave(conn_id,true) return end
  if cmd=="join" then
    local idx=empty_seat_index(room)
    if not idx then gn_send_ws(conn_id,j_obj({cmd="error",reason="full"})) return end
    room.seats[idx]={human=true,conn_id=conn_id,name=tostring(msg.name or "旅人"),is_host=false}
    gn_send(1, j_obj({cmd="__lobby_join_ok", conn_id=conn_id, room_id=room.id}))
    gn_send_ws(conn_id, j_obj({cmd="room_joined", room_id=room.id, your_seat=idx}))
    broadcast({cmd="player_join", name=room.seats[idx].name, seat=idx})
    broadcast_state()
    return
  end
  local my=nil
  for i=1,MAX_SEATS do local s=room.seats[i]; if s and s.human and s.conn_id==conn_id then my=i break end end
  if not my then return end

  if cmd=="add_bot" then
    if room.host~=conn_id then gn_send_ws(conn_id,j_obj({cmd="error",reason="not_host"})) return end
    for i=1,MAX_SEATS do
      local s=room.seats[i]
      if s and (not s.human) then
        gn_send_ws(conn_id,j_obj({cmd="error",reason="only_one_bot"}))
        return
      end
    end
    local idx=empty_seat_index(room)
    if not idx then gn_send_ws(conn_id,j_obj({cmd="error",reason="full"})) return end
    room.seats[idx]={human=false,name="机器人#"..tostring(next_bot),is_host=false}
    local ok, st = test_bot_api_for_idiom()
    room.bot_status[idx] = ok and ("机器人在线：" .. st) or ("机器人离线：" .. st)
    next_bot=next_bot+1
    broadcast({cmd="bot_join", seat=idx, name=room.seats[idx].name})
    broadcast_state()
    return
  end

  if cmd=="leave_room" then do_leave(conn_id,false) return end

  if cmd=="start_game" then
    if room.host~=conn_id then gn_send_ws(conn_id,j_obj({cmd="error",reason="not_host"})) return end
    local filled=0 for i=1,MAX_SEATS do if room.seats[i] then filled=filled+1 end end
    if filled<2 then gn_send_ws(conn_id,j_obj({cmd="error",reason="need_players"})) return end
    if not check_llm_ready() then
      gn_send_ws(conn_id,j_obj({cmd="error",reason="llm_unavailable", detail=llm_last_reason}))
      return
    end
    local g={phase="playing",turn=1,current="一心一意",used={ ["一心一意"]=true },used_count=1,alive={},score={},fail={},bot_retry={},next_bot_at=os.time()+2}
    for i=1,MAX_SEATS do
      g.alive[i] = room.seats[i] and true or false
      g.score[i] = 0
      g.fail[i] = 0
      g.bot_retry[i] = 0
    end
    if not g.alive[g.turn] then g.turn=next_alive(g,g.turn) end
    room.game=g
    broadcast({cmd="game_start", text="成语接龙开始", game_type="idiom"})
    broadcast({cmd="idiom_prompt", text=g.current})
    broadcast_state()
    return
  end

  if cmd=="idiom_submit" then
    local g=room.game
    if g and g.phase=="playing" then
      apply_submit(my, tostring(msg.text or ""), false)
    end
    return
  end
end

return M
