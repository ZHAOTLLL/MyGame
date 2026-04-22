-- Room VM：单房间状态机（由 room_actor 加载）。与 Lobby 通过 gn_send(1, ...) 同步 session。
-- 规则说明见原 lobby 注释。
local M = {}
local agent_runtime = require "service.liar_agent_runtime"

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

local room = nil
local next_bot = 1
local clear_bot_pending

local BOT_LLM_TIMEOUT_SEC = tonumber(os.getenv("LIAR_AGENT_TIMEOUT_SEC") or "18") or 18
local BOT_FALLBACK_COOLDOWN_SEC = tonumber(os.getenv("LIAR_RANDOM_FALLBACK_COOLDOWN_SEC") or "2") or 2

local RANKS = { "Q", "K", "A" }
local broadcast_state
local start_next_subround

local function broadcast_room(room, payload)
  local js = type(payload) == "string" and payload or j_obj(payload)
  for i = 1, 4 do
    local seat = room.seats[i]
    if seat and seat.human and seat.conn_id then
      gn_send_ws(seat.conn_id, js)
    end
  end
end

local function empty_seat_index(room)
  for i = 1, 4 do
    if not room.seats[i] then
      return i
    end
  end
  return nil
end

local function host_seat_index(room)
  for i = 1, 4 do
    local s = room.seats[i]
    if s and s.is_host then
      return i
    end
  end
  if room.host then
    for i = 1, 4 do
      local s = room.seats[i]
      if s and s.human and s.conn_id == room.host then
        return i
      end
    end
  end
  return 1
end

local function clear_game_if_any(room)
  if room.game then
    clear_bot_pending(room.game)
    room.game = nil
  end
end

local function remove_human_from_seat(room, conn_id)
  for i = 1, 4 do
    local seat = room.seats[i]
    if seat and seat.human and seat.conn_id == conn_id then
      room.seats[i] = nil
      return i
    end
  end
  return nil
end

-- 房主离开后，将房主交给剩余真人中座位号最小者
local function elect_new_host(room)
  for i = 1, 4 do
    local s = room.seats[i]
    if s and s.human then
      room.host = s.conn_id
      for j = 1, 4 do
        local sj = room.seats[j]
        if sj and sj.human then
          sj.is_host = (sj.conn_id == room.host)
        elseif sj then
          sj.is_host = false
        end
      end
      return true
    end
  end
  room.host = nil
  return false
end

local function cleanup_room_if_empty()
  if not room then
    return
  end
  for i = 1, 4 do
    if room.seats[i] then
      return
    end
  end
  local rid = room.id
  room = nil
  gn_send(1, j_obj({ cmd = "__room_destroyed", room_id = rid }))
end

local function ensure_ready_slots(room)
  if not room.ready then
    room.ready = { false, false, false, false }
  end
end

-- 非房主真人需「准备」；开局后在一局结束时清空
local function reset_guest_ready(room)
  ensure_ready_slots(room)
  for i = 1, 4 do
    local s = room.seats[i]
    if s and s.human and not s.is_host then
      room.ready[i] = false
    end
  end
end

-- opts.skip_ack：内部换房时不发 left_room，避免客户端闪回大厅
local function do_leave_room(conn_id, opts)
  opts = opts or {}
  if not room then
    return false
  end
  local was_host = (room.host == conn_id)
  remove_human_from_seat(room, conn_id)
  gn_send(1, j_obj({ cmd = "__lobby_detach", conn_id = conn_id }))
  clear_game_if_any(room)
  if was_host then
    elect_new_host(room)
  end
  broadcast_room(room, { cmd = "player_left", conn_id = conn_id })
  broadcast_state(room)
  cleanup_room_if_empty()
  if not opts.skip_ack then
    gn_send_ws(conn_id, j_obj({ cmd = "left_room" }))
  end
  return true
end

-- 头像编号 1~8，由名字简单哈希
local function avatar_for_name(name)
  local n = 0
  for i = 1, #name do
    n = n + string.byte(name, i)
  end
  return (n % 8) + 1
end

local function hand_count(g, si)
  return #(g.hands[si] or {})
end

local function now_sec()
  return os.time()
end

local function set_bot_cooldown(g, sec)
  if not g then
    return
  end
  local wait_sec = tonumber(sec) or 0
  if wait_sec < 0 then
    wait_sec = 0
  end
  g.bot_next_action_at = now_sec() + wait_sec
end

local function bot_status_text(text)
  text = tostring(text or "")
  if #text > 48 then
    return text:sub(1, 48) .. "..."
  end
  return text
end

local function set_bot_status(room, seat, text)
  room.bot_status = room.bot_status or {}
  room.bot_status[seat] = bot_status_text(text)
end

clear_bot_pending = function(g)
  if g then
    g.bot_pending_request = nil
  end
end

local function count_players_with_cards(room, g)
  local n = 0
  local sole = nil
  for i = 1, 4 do
    if room.seats[i] and g.alive[i] and hand_count(g, i) > 0 then
      n = n + 1
      sole = i
    end
  end
  return n, sole
end

local function alive_players(room, g)
  local n = 0
  for i = 1, 4 do
    if room.seats[i] and g.alive[i] then
      n = n + 1
    end
  end
  return n
end

local function next_alive_seat(room, g, from)
  local tries = 0
  local i = from
  repeat
    i = i % 4 + 1
    tries = tries + 1
    if tries > 8 then
      return from
    end
  until room.seats[i] and g.alive[i]
  return i
end

-- 下一发是否命中；命中则淘汰
local function revolver_pull(g, seat)
  local r = g.revolver
  if r.next[seat] == r.bullet[seat] then
    g.alive[seat] = false
    r.pulls[seat] = (r.pulls[seat] or 0) + 1
    return true
  end
  r.pulls[seat] = (r.pulls[seat] or 0) + 1
  r.next[seat] = (r.next[seat] % 6) + 1
  return false
end

local new_deck_20

local function deal_subround(room, starter_seat)
  local g = room.game
  local deck = new_deck_20()
  local order = {}
  for i = 1, 4 do
    if room.seats[i] and g.alive[i] then
      order[#order + 1] = i
    end
  end
  table.sort(order)
  local n = #order
  for i = 1, 4 do
    g.hands[i] = {}
  end
  if n < 1 then
    return
  end
  local di = 1
  local total = math.min(#deck, n * 5)
  for idx = 1, total do
    local seat = order[di]
    g.hands[seat][#g.hands[seat] + 1] = deck[idx]
    di = di % n + 1
  end
  g.round_target = RANKS[math.random(1, #RANKS)]
  g.last_play = nil
  g.subphase = "must_play"
  g.react_to_seat = nil
  g.pending_empty_winner = nil
  g.subround = (g.subround or 0) + 1
  if starter_seat and room.seats[starter_seat] and g.alive[starter_seat] then
    g.turn = starter_seat
  else
    g.turn = order[1]
  end
  g.public_log = g.public_log or {}
  g.public_log[#g.public_log + 1] = {
    type = "subround",
    subround = g.subround,
    round_target = g.round_target,
  }
end

-- 下家：顺时针下一个仍在场且有血量的人
local function next_seat_after(room, g, seat)
  return next_alive_seat(room, g, seat)
end

local function play_is_honest(cards, round_target)
  for _, c in ipairs(cards) do
    if c == "J" then
      -- ok
    elseif c == round_target then
      -- ok
    else
      return false
    end
  end
  return true
end

local function remove_cards_from_hand(hand, play)
  local h = {}
  for _, x in ipairs(hand) do
    h[#h + 1] = x
  end
  for _, want in ipairs(play) do
    local ok = false
    for j = 1, #h do
      if h[j] == want then
        table.remove(h, j)
        ok = true
        break
      end
    end
    if not ok then
      return nil
    end
  end
  return h
end

new_deck_20 = function()
  local d = {}
  for _ = 1, 6 do
    d[#d + 1] = "Q"
  end
  for _ = 1, 6 do
    d[#d + 1] = "K"
  end
  for _ = 1, 6 do
    d[#d + 1] = "A"
  end
  for _ = 1, 2 do
    d[#d + 1] = "J"
  end
  for i = #d, 2, -1 do
    local j = math.random(i)
    d[i], d[j] = d[j], d[i]
  end
  return d
end

local function build_public_state(room, for_conn_id)
  local g = room.game
  local seats = {}
  for i = 1, 4 do
    local s = room.seats[i]
    if not s then
      seats[i] = { empty = true }
    else
      local hc = g and hand_count(g, i) or 0
      local alive = true
      local pulls = 0
      if g and g.alive then
        alive = g.alive[i] and true or false
        if g.revolver and g.revolver.pulls then
          pulls = g.revolver.pulls[i] or 0
        end
      end
      local entry = {
        name = s.name,
        human = s.human and true or false,
        bot = (not s.human) and true or false,
        alive = alive,
        revolver_pulls = pulls,
        hand_count = hc,
        is_host = s.is_host and true or false,
        avatar = avatar_for_name(s.name or "?"),
        bot_status = room.bot_status and room.bot_status[i] or nil,
      }
      local in_prep = not g or g.phase ~= "playing"
      if in_prep then
        ensure_ready_slots(room)
        if not s.human or s.is_host then
          entry.ready = true
        else
          entry.ready = room.ready[i] and true or false
        end
      end
      seats[i] = entry
    end
  end
  local my_seat = nil
  if for_conn_id then
    for i = 1, 4 do
      local s = room.seats[i]
      if s and s.human and s.conn_id == for_conn_id then
        my_seat = i
        break
      end
    end
  end
  local last = g and g.last_play
  local last_pub = nil
  if last then
    last_pub = {
      by = last.by,
      count = #last.cards,
      rank_name = g.round_target,
    }
  end
  local out = {
    game_type = "liar_poker",
    room_id = room.id,
    phase = g and g.phase or "lobby",
    subphase = g and g.subphase or "none",
    round_target = g and g.round_target or nil,
    subround = g and g.subround or 0,
    seats = seats,
    host_seat = host_seat_index(room),
    turn = g and g.turn or 0,
    my_seat = my_seat,
    last_play = last_pub,
    react_to_seat = g and g.react_to_seat or nil,
  }
  return out
end

local function build_agent_public_snapshot(room, g)
  local seats = {}
  for i = 1, 4 do
    local s = room.seats[i]
    if s then
      seats[#seats + 1] = {
        seat = i,
        name = s.name,
        human = s.human and true or false,
        bot = (not s.human) and true or false,
        alive = g.alive[i] and true or false,
        hand_count = hand_count(g, i),
        revolver_pulls = (g.revolver and g.revolver.pulls and g.revolver.pulls[i]) or 0,
      }
    end
  end
  local last_play = nil
  if g.last_play then
    last_play = {
      by = g.last_play.by,
      count = #g.last_play.cards,
      rank_name = g.round_target,
    }
  end
  return {
    room_id = room.id,
    subround = g.subround,
    round_target = g.round_target,
    turn = g.turn,
    subphase = g.subphase,
    react_to_seat = g.react_to_seat,
    last_play = last_play,
    seats = seats,
    public_log = g.public_log or {},
  }
end

broadcast_state = function(room)
  for i = 1, 4 do
    local seat = room.seats[i]
    if seat and seat.human and seat.conn_id then
      local st = build_public_state(room, seat.conn_id)
      gn_send_ws(seat.conn_id, j_obj({ cmd = "room_state", state = st }))
    end
  end
end

local function send_state(room, conn_id)
  local st = build_public_state(room, conn_id)
  gn_send_ws(conn_id, j_obj({ cmd = "room_state", state = st }))
end

local function send_hand(room, conn_id)
  local g = room.game
  if not g then
    return
  end
  for i = 1, 4 do
    local seat = room.seats[i]
    if seat and seat.human and seat.conn_id == conn_id then
      local js = j_obj({ cmd = "your_hand", cards = g.hands[i] or {} })
      gn_send_ws(conn_id, js)
      return
    end
  end
end

local function build_settlement(room, g, winner, reason, text)
  local seats = {}
  for i = 1, 4 do
    local s = room.seats[i]
    if s then
      seats[#seats + 1] = {
        seat = i,
        name = s.name,
        alive = g.alive[i] and true or false,
        hand_count = hand_count(g, i),
        revolver_pulls = (g.revolver and g.revolver.pulls and g.revolver.pulls[i]) or 0,
        is_winner = (i == winner),
      }
    end
  end
  return {
    winner_seat = winner,
    reason = reason,
    text = text,
    seats = seats,
  }
end

local function maybe_auto_challenge_or_win(room)
  local g = room.game
  if not g or g.phase ~= "playing" then
    return
  end
  local n, sole = count_players_with_cards(room, g)
  if n == 0 then
    if alive_players(room, g) <= 1 then
      g.phase = "ended"
      reset_guest_ready(room)
      local win = 0
      for i = 1, 4 do
        if room.seats[i] and g.alive[i] then
          win = i
          break
        end
      end
      local txt = "场上仅剩一名存活，整局结束"
      broadcast_room(room, {
        cmd = "game_over",
        winner_seat = win,
        text = txt,
        reason = "last_standing",
        settlement = build_settlement(room, g, win, "last_standing", txt),
      })
      broadcast_state(room)
      return
    end
    local starter = next_alive_seat(room, g, g.turn or 1)
    start_next_subround(room, starter, "本小轮全部玩家已打空，重新发牌。")
    return
  end
  if n == 1 then
    if g.last_play and sole then
      local ch = next_alive_seat(room, g, g.last_play.by)
      if ch and ch ~= g.last_play.by then
        M._do_challenge(room, ch, true)
      end
    end
  end
end

local function next_playable_seat(room, g, from)
  local cur = from or 1
  for _ = 1, 4 do
    cur = next_alive_seat(room, g, cur)
    if room.seats[cur] and g.alive[cur] and hand_count(g, cur) > 0 then
      return cur
    end
  end
  return nil
end

local function normalize_turn_if_needed(room)
  local g = room.game
  if not g or g.phase ~= "playing" then
    return
  end
  if g.subphase ~= "must_play" or g.last_play then
    return
  end
  local t = g.turn
  local bad =
    (not t) or
    (not room.seats[t]) or
    (not g.alive[t]) or
    hand_count(g, t) <= 0
  if not bad then
    return
  end
  local base = t or 1
  local nxt = next_playable_seat(room, g, base)
  if nxt then
    g.turn = nxt
  end
end

start_next_subround = function(room, starter_seat, text)
  local g = room.game
  if not g or g.phase ~= "playing" then
    return
  end
  deal_subround(room, starter_seat)
  normalize_turn_if_needed(room)
  broadcast_room(room, {
    cmd = "subround_start",
    subround = g.subround,
    round_target = g.round_target,
    text = text or ("重新发牌，进入第 " .. tostring(g.subround) .. " 小局"),
  })
  broadcast_state(room)
  for i = 1, 4 do
    local s = room.seats[i]
    if s and s.human then
      send_hand(room, s.conn_id)
    end
  end
  -- 新小轮开始后，给玩家留一点观察时间，避免机器人立刻连招。
  set_bot_cooldown(g, 2)
end

function M._do_challenge(room, challenger, auto)
  local g = room.game
  if not g.last_play then
    return false, "no_last_play"
  end
  local last = g.last_play
  local ch = challenger
  if not auto then
    local expected = next_seat_after(room, g, last.by)
    if ch ~= expected then
      return false, "only_next_may_challenge"
    end
    if g.subphase ~= "react" or g.turn ~= ch then
      return false, "not_your_turn"
    end
  end
  local honest = play_is_honest(last.cards, g.round_target)
  g.public_log = g.public_log or {}
  g.public_log[#g.public_log + 1] = {
    type = "reveal",
    subround = g.subround,
    played_by = last.by,
    challenger = ch,
    honest = honest and true or false,
    revealed_cards = last.cards,
  }
  local loser
  if not honest then
    loser = last.by
  else
    loser = ch
  end
  local killed = revolver_pull(g, loser)
  local msg
  if not honest then
    msg = "开牌：座位" .. last.by .. " 所出含非骗子牌，对自己开枪"
  else
    msg = "开牌：均为骗子牌或小丑，座位" .. ch .. " 质疑失败，对自己开枪"
  end
  if killed then
    msg = msg .. " → 中弹淘汰！"
  else
    msg = msg .. " → 空枪，存活。"
  end
  broadcast_room(room, {
    cmd = "challenge_result",
    text = msg,
    honest = honest and true or false,
    challenged_seat = last.by,
    challenger_seat = ch,
    revealed_cards = last.cards,
    loser_seat = loser,
    revolver_killed = killed,
    auto = auto and true or false,
  })
  -- 开牌动画与结果展示窗口：机器人至少等待 5 秒再继续行动。
  set_bot_cooldown(g, 5)
  local empty_winner = g.pending_empty_winner
  g.pending_empty_winner = nil
  g.last_play = nil
  g.subphase = "must_play"
  g.react_to_seat = nil
  if alive_players(room, g) <= 1 then
    g.phase = "ended"
    reset_guest_ready(room)
    local win = 0
    for i = 1, 4 do
      if room.seats[i] and g.alive[i] then
        win = i
        break
      end
    end
    broadcast_room(room, {
      cmd = "game_over",
      winner_seat = win,
      text = msg,
      reason = "last_standing",
      settlement = build_settlement(room, g, win, "last_standing", msg),
    })
    broadcast_state(room)
    return true
  end
  if empty_winner and empty_winner ~= loser and room.seats[empty_winner] and g.alive[empty_winner] then
    start_next_subround(
      room,
      loser,
      "开牌成立，座位" .. empty_winner .. " 成功打空赢下本小轮；由输家座位" .. loser .. " 先手。"
    )
    maybe_auto_challenge_or_win(room)
    return true
  end
  -- 质疑后仍由当前操作方继续出牌（符合“开牌后依旧需要出牌”）
  g.turn = ch
  if not room.seats[g.turn] or not g.alive[g.turn] then
    g.turn = next_alive_seat(room, g, ch)
  end
  normalize_turn_if_needed(room)
  broadcast_state(room)
  for i = 1, 4 do
    local s = room.seats[i]
    if s and s.human then
      send_hand(room, s.conn_id)
    end
  end
  maybe_auto_challenge_or_win(room)
  return true
end

local function try_play_cards(room, seat_idx, cards)
  local g = room.game
  if g.phase ~= "playing" then
    return false, "not_playing"
  end
  if not g.alive[seat_idx] then
    return false, "dead"
  end
  local n = #cards
  if n < 1 or n > 3 then
    return false, "bad_count"
  end
  if g.turn ~= seat_idx then
    return false, "not_your_turn"
  end
  if g.subphase ~= "must_play" and g.subphase ~= "react" then
    return false, "bad_phase"
  end
  if g.subphase == "react" and not g.last_play then
    return false, "no_last_play"
  end
  local newh = remove_cards_from_hand(g.hands[seat_idx], cards)
  if not newh then
    return false, "invalid_cards"
  end
  g.hands[seat_idx] = newh
  if #newh == 0 then
    g.pending_empty_winner = seat_idx
  end
  g.last_play = { by = seat_idx, cards = cards }
  local nxt = next_playable_seat(room, g, seat_idx)
  if not nxt then
    maybe_auto_challenge_or_win(room)
    return true
  end
  g.turn = nxt
  g.subphase = "react"
  g.react_to_seat = seat_idx
  g.public_log = g.public_log or {}
  g.public_log[#g.public_log + 1] = {
    type = "play",
    subround = g.subround,
    seat = seat_idx,
    count = n,
    round_target = g.round_target,
  }
  broadcast_room(room, {
    cmd = "play",
    seat = seat_idx,
    count = n,
    rank = g.round_target,
  })
  broadcast_state(room)
  for i = 1, 4 do
    local s = room.seats[i]
    if s and s.human then
      send_hand(room, s.conn_id)
    end
  end
  -- 每次出牌后放慢机器人节奏，便于观察流程。
  set_bot_cooldown(g, 2)
  maybe_auto_challenge_or_win(room)
  return true
end

local function start_game(room)
  local filled = {}
  for i = 1, 4 do
    if room.seats[i] then
      filled[#filled + 1] = i
    end
  end
  if #filled < 4 then
    return false, "need_4_players"
  end
  ensure_ready_slots(room)
  for i = 1, 4 do
    local s = room.seats[i]
    if s and s.human and not s.is_host then
      if not room.ready[i] then
        return false, "not_all_ready"
      end
    end
  end
  local g = {
    phase = "playing",
    alive = { false, false, false, false },
    revolver = { next = {}, bullet = {}, pulls = {} },
    hands = { {}, {}, {}, {} },
    subphase = "must_play",
    last_play = nil,
    react_to_seat = nil,
    subround = 0,
    pending_empty_winner = nil,
    bot_next_action_at = 0,
    public_log = {},
    bot_request_seq = 0,
    bot_pending_request = nil,
  }
  for si = 1, 4 do
    if room.seats[si] then
      g.alive[si] = true
      g.revolver.next[si] = 1
      g.revolver.bullet[si] = math.random(1, 6)
      g.revolver.pulls[si] = 0
    end
  end
  room.game = g
  room.bot_status = room.bot_status or {}
  local llm_ok, llm_reason = agent_runtime.check_llm_ready()
  for si = 1, 4 do
    local s = room.seats[si]
    if s and not s.human then
      if agent_runtime.llm_enabled() and llm_ok then
        set_bot_status(room, si, "Agent在线")
      elseif agent_runtime.llm_enabled() then
        set_bot_status(room, si, "回退随机：" .. tostring(llm_reason or "llm_unavailable"))
      else
        set_bot_status(room, si, "随机策略")
      end
    end
  end
  deal_subround(room)
  normalize_turn_if_needed(room)
  broadcast_room(room, {
    cmd = "game_start",
    room_id = room.id,
    round_target = g.round_target,
    subround = g.subround,
    text = "对局开始：每人左轮随机 1 弹，骗子牌已抽取",
  })
  broadcast_state(room)
  for i = 1, 4 do
    local s = room.seats[i]
    if s and s.human then
      send_hand(room, s.conn_id)
    end
  end
  maybe_auto_challenge_or_win(room)
  return true
end

local bot_turn_random

local function hand_contains_play(hand, play)
  if not hand or not play then
    return false
  end
  local h = {}
  for _, x in ipairs(hand) do
    h[#h + 1] = x
  end
  return remove_cards_from_hand(h, play) ~= nil
end

local function pending_matches_state(g, pending)
  if not g or not pending then
    return false
  end
  if g.phase ~= "playing" then
    return false
  end
  local last_by = g.last_play and g.last_play.by or 0
  if g.turn ~= pending.seat then
    return false
  end
  if g.subround ~= pending.subround or g.subphase ~= pending.subphase then
    return false
  end
  if last_by ~= (pending.last_play_by or 0) then
    return false
  end
  if #(g.public_log or {}) ~= (pending.public_log_len or 0) then
    return false
  end
  return true
end

local function enqueue_bot_llm_request(room, si)
  local g = room.game
  local hand = g.hands[si] or {}
  if #hand == 0 then
    return false, "empty_hand"
  end
  local pool_actor = tonumber(gn_liar_agent_pool() or 0) or 0
  if pool_actor == 0 then
    return false, "no_agent_pool"
  end
  local snapshot = build_agent_public_snapshot(room, g)
  g.bot_request_seq = (g.bot_request_seq or 0) + 1
  local request_id = tostring(room.id) .. ":" .. tostring(si) .. ":" .. tostring(g.bot_request_seq)
  g.bot_pending_request = {
    request_id = request_id,
    seat = si,
    subround = g.subround,
    subphase = g.subphase,
    last_play_by = g.last_play and g.last_play.by or 0,
    public_log_len = #(g.public_log or {}),
    expire_at = now_sec() + BOT_LLM_TIMEOUT_SEC,
  }
  gn_send(pool_actor, j_obj({
    cmd = "liar_agent_eval",
    reply_to = gn_self(),
    room_id = room.id,
    request_id = request_id,
    seat = si,
    subround = snapshot.subround,
    round_target = snapshot.round_target,
    turn = snapshot.turn,
    subphase = snapshot.subphase,
    react_to_seat = snapshot.react_to_seat,
    last_play = snapshot.last_play,
    public_log = snapshot.public_log,
    seats = snapshot.seats,
    hand = hand,
  }))
  return true, nil
end

local function bot_turn_llm(room, si)
  local g = room.game
  local hand = g.hands[si] or {}
  if g.subphase == "react" and g.last_play and #hand == 0 then
    set_bot_status(room, si, "无牌可跟，自动质疑")
    M._do_challenge(room, si, false)
    set_bot_cooldown(g, 3)
    return true, nil
  end
  if #hand == 0 then
    return false, nil
  end
  local pending = g.bot_pending_request
  if pending then
    if not pending_matches_state(g, pending) then
      clear_bot_pending(g)
    elseif now_sec() >= (pending.expire_at or 0) then
      clear_bot_pending(g)
      bot_turn_random(room, si, "Agent超时回退")
      set_bot_cooldown(g, BOT_FALLBACK_COOLDOWN_SEC)
      broadcast_state(room)
      return true, nil
    else
      return true, nil
    end
  end
  local llm_ok, llm_reason = agent_runtime.check_llm_ready()
  if not llm_ok then
    return false, "LLM不可用:" .. tostring(llm_reason or "llm_unavailable")
  end
  local ok, why = enqueue_bot_llm_request(room, si)
  if not ok then
    return false, "提交失败:" .. tostring(why or "enqueue_failed")
  end
  set_bot_status(room, si, "Agent思考中")
  broadcast_state(room)
  return true, nil
end

bot_turn_random = function(room, si, reason_prefix)
  local g = room.game
  local hand = g.hands[si]
  local prefix = reason_prefix and (tostring(reason_prefix) .. "，") or ""
  if g.subphase == "react" and g.last_play then
    if not hand or #hand == 0 then
      set_bot_status(room, si, prefix .. "随机质疑")
      M._do_challenge(room, si, false)
      return
    end
    if math.random() < 0.4 then
      set_bot_status(room, si, prefix .. "随机质疑")
      M._do_challenge(room, si, false)
    else
      set_bot_status(room, si, prefix .. "随机跟牌")
      local cnt = math.random(1, math.min(3, #hand))
      local play = {}
      for j = 1, cnt do
        play[j] = hand[j]
      end
      try_play_cards(room, si, play)
    end
    return
  end
  if not hand or #hand == 0 then
    return
  end
  if g.subphase == "must_play" then
    set_bot_status(room, si, prefix .. "随机出牌")
    local cnt = math.random(1, math.min(3, #hand))
    local play = {}
    for j = 1, cnt do
      play[j] = hand[j]
    end
    try_play_cards(room, si, play)
  end
end

local function bot_turn(room)
  local g = room.game
  if not g or g.phase ~= "playing" then
    return
  end
  if g.bot_next_action_at and now_sec() < g.bot_next_action_at then
    return
  end
  local si = g.turn
  local seat = room.seats[si]
  if not seat or seat.human then
    return
  end
  if not g.alive[si] then
    return
  end
  g.public_log = g.public_log or {}
  if agent_runtime.llm_enabled() then
    local handled, fallback_reason = bot_turn_llm(room, si)
    if handled then
      return
    end
    bot_turn_random(room, si, fallback_reason)
    return
  end
  bot_turn_random(room, si)
end

local function apply_bot_llm_result(msg)
  if not room or not room.game then
    return
  end
  local g = room.game
  local pending = g.bot_pending_request
  if not pending then
    return
  end
  if tostring(msg.request_id or "") ~= tostring(pending.request_id or "") then
    return
  end
  clear_bot_pending(g)
  if not pending_matches_state(g, pending) then
    return
  end
  local si = tonumber(msg.seat) or pending.seat
  if si ~= pending.seat or not room.seats[si] or room.seats[si].human or not g.alive[si] then
    return
  end
  if not msg.ok then
    bot_turn_random(room, si, "Agent失败回退:" .. tostring(msg.reason or "llm_failed"))
    set_bot_cooldown(g, BOT_FALLBACK_COOLDOWN_SEC)
    broadcast_state(room)
    return
  end
  local hand = g.hands[si] or {}
  local action = tostring(msg.action or "")
  if g.subphase == "must_play" then
    if action == "play" and type(msg.cards) == "table" and hand_contains_play(hand, msg.cards) then
      set_bot_status(room, si, "Agent出牌")
      try_play_cards(room, si, msg.cards)
      set_bot_cooldown(g, 3)
    else
      bot_turn_random(room, si, "Agent输出非法回退")
      set_bot_cooldown(g, BOT_FALLBACK_COOLDOWN_SEC)
      broadcast_state(room)
    end
    return
  end
  if g.subphase == "react" and g.last_play then
    if action == "challenge" then
      set_bot_status(room, si, "Agent质疑")
      M._do_challenge(room, si, false)
      set_bot_cooldown(g, 3)
      return
    end
    if action == "play" and type(msg.cards) == "table" and hand_contains_play(hand, msg.cards) then
      set_bot_status(room, si, "Agent跟牌")
      try_play_cards(room, si, msg.cards)
      set_bot_cooldown(g, 3)
      return
    end
    bot_turn_random(room, si, "Agent输出非法回退")
    set_bot_cooldown(g, BOT_FALLBACK_COOLDOWN_SEC)
    broadcast_state(room)
  end
end

function M.on_system(msg)
  if not msg or not msg.cmd then
    return
  end
  if msg.cmd == "__bot_llm_result" then
    apply_bot_llm_result(msg)
  end
end

function M.tick()
  if room and room.game and room.game.phase == "playing" then
    normalize_turn_if_needed(room)
    bot_turn(room)
  end
end

function M.init(msg)
  if msg.match then
    room = {
      id = msg.room_id,
      host = msg.players[1].conn_id,
      seats = {},
      ready = { false, false, false, false },
      bot_status = {},
    }
    for i = 1, #msg.players do
      local p = msg.players[i]
      room.seats[i] = {
        human = true,
        conn_id = p.conn_id,
        name = p.name,
        is_host = (i == 1),
      }
    end
    broadcast_room(room, { cmd = "match_ready", room_id = room.id })
    broadcast_state(room)
  else
    room = {
      id = msg.room_id,
      host = msg.host_conn,
      seats = {},
      ready = { false, false, false, false },
      bot_status = {},
    }
    room.seats[1] = {
      human = true,
      conn_id = msg.host_conn,
      name = msg.host_name,
      is_host = true,
    }
    gn_send_ws(msg.host_conn, j_obj({ cmd = "room_joined", room_id = room.id, your_seat = 1 }))
    send_state(room, msg.host_conn)
  end
end

function M.disconnect(conn_id)
  if not room then
    return
  end
  local was_host = room.host == conn_id
  remove_human_from_seat(room, conn_id)
  gn_send(1, j_obj({ cmd = "__lobby_detach", conn_id = conn_id }))
  clear_game_if_any(room)
  if was_host then
    elect_new_host(room)
  end
  broadcast_room(room, { cmd = "player_left", conn_id = conn_id })
  broadcast_state(room)
  cleanup_room_if_empty()
end

function M.client_handle(conn_id, msg)
  local cmd = msg.cmd
  if not cmd then
    return
  end
  if not room then
    return
  end

  if cmd == "join" then
    local name = tostring(msg.name or "旅人")
    name = name:sub(1, 16)
    local idx = empty_seat_index(room)
    if not idx then
      gn_send_ws(conn_id, j_obj({ cmd = "error", reason = "full" }))
      return
    end
    ensure_ready_slots(room)
    room.seats[idx] = {
      human = true,
      conn_id = conn_id,
      name = name,
      is_host = false,
    }
    room.ready[idx] = false
    gn_send(1, j_obj({ cmd = "__lobby_join_ok", conn_id = conn_id, room_id = room.id }))
    gn_send_ws(conn_id, j_obj({ cmd = "room_joined", room_id = room.id, your_seat = idx }))
    broadcast_room(room, { cmd = "player_join", name = name, seat = idx })
    broadcast_state(room)
    return
  end

  if cmd == "add_bot" then
    if room.host ~= conn_id then
      gn_send_ws(conn_id, j_obj({ cmd = "error", reason = "not_host" }))
      return
    end
    local idx = empty_seat_index(room)
    if not idx then
      gn_send_ws(conn_id, j_obj({ cmd = "error", reason = "full" }))
      return
    end
    local bid = next_bot
    next_bot = next_bot + 1
    ensure_ready_slots(room)
    room.seats[idx] = { human = false, name = "机器人#" .. tostring(bid), is_host = false }
    room.ready[idx] = true
    if agent_runtime.llm_enabled() then
      local ok, reason = agent_runtime.check_llm_ready()
      if ok then
        set_bot_status(room, idx, "Agent待命")
      else
        set_bot_status(room, idx, "回退随机：" .. tostring(reason or "llm_unavailable"))
      end
    else
      set_bot_status(room, idx, "随机策略")
    end
    broadcast_room(room, { cmd = "bot_join", seat = idx, name = room.seats[idx].name })
    broadcast_state(room)
    return
  end

  if cmd == "set_ready" then
    local g = room.game
    if g and g.phase == "playing" then
      gn_send_ws(conn_id, j_obj({ cmd = "error", reason = "not_in_lobby" }))
      return
    end
    local seat_idx = nil
    for i = 1, 4 do
      local s = room.seats[i]
      if s and s.human and s.conn_id == conn_id then
        seat_idx = i
        break
      end
    end
    if not seat_idx then
      return
    end
    local occ = room.seats[seat_idx]
    if occ.is_host then
      gn_send_ws(conn_id, j_obj({ cmd = "error", reason = "host_no_ready" }))
      return
    end
    ensure_ready_slots(room)
    local want = msg.ready
    if want == nil then
      room.ready[seat_idx] = not room.ready[seat_idx]
    else
      room.ready[seat_idx] = want and true or false
    end
    broadcast_state(room)
    return
  end

  if cmd == "leave_room" then
    do_leave_room(conn_id, { skip_ack = msg.skip_ack })
    return
  end

  if cmd == "kick" then
    if room.host ~= conn_id then
      gn_send_ws(conn_id, j_obj({ cmd = "error", reason = "not_host" }))
      return
    end
    local target_seat = tonumber(msg.seat)
    if not target_seat or target_seat < 1 or target_seat > 4 then
      gn_send_ws(conn_id, j_obj({ cmd = "error", reason = "bad_seat" }))
      return
    end
    local t = room.seats[target_seat]
    if not t or not t.human then
      gn_send_ws(conn_id, j_obj({ cmd = "error", reason = "no_player" }))
      return
    end
    if t.conn_id == conn_id then
      gn_send_ws(conn_id, j_obj({ cmd = "error", reason = "kick_self" }))
      return
    end
    local target_cid = t.conn_id
    room.seats[target_seat] = nil
    gn_send(1, j_obj({ cmd = "__lobby_detach", conn_id = target_cid }))
    clear_game_if_any(room)
    gn_send_ws(target_cid, j_obj({ cmd = "kicked", reason = "by_host" }))
    broadcast_room(room, { cmd = "player_kicked", seat = target_seat, conn_id = target_cid })
    broadcast_state(room)
    return
  end

  if cmd == "start_game" then
    if room.host ~= conn_id then
      gn_send_ws(conn_id, j_obj({ cmd = "error", reason = "not_host" }))
      return
    end
    local ok, why = start_game(room)
    if not ok then
      gn_send_ws(conn_id, j_obj({ cmd = "error", reason = why or "start_fail" }))
    end
    return
  end

  if cmd == "play" then
    local seat_idx = nil
    for i = 1, 4 do
      local s = room.seats[i]
      if s and s.human and s.conn_id == conn_id then
        seat_idx = i
        break
      end
    end
    if not seat_idx then
      return
    end
    local cards = msg.cards
    if type(cards) ~= "table" then
      gn_send_ws(conn_id, j_obj({ cmd = "error", reason = "bad_cards" }))
      return
    end
    local play = {}
    for i = 1, #cards do
      play[i] = tostring(cards[i])
    end
    local ok, why = try_play_cards(room, seat_idx, play)
    if not ok then
      gn_send_ws(conn_id, j_obj({ cmd = "error", reason = why or "play_fail" }))
    end
    return
  end

  if cmd == "challenge" then
    local seat_idx = nil
    for i = 1, 4 do
      local s = room.seats[i]
      if s and s.human and s.conn_id == conn_id then
        seat_idx = i
        break
      end
    end
    if not seat_idx then
      return
    end
    local ok, why = M._do_challenge(room, seat_idx, false)
    if not ok then
      gn_send_ws(conn_id, j_obj({ cmd = "error", reason = why or "challenge_fail" }))
    end
    return
  end
end

return M
