local runtime = require "service.liar_agent_runtime"

local M = {}

local self_id = 0

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

function M.init(msg)
  self_id = tonumber(msg.actor_id) or tonumber(gn_self()) or 0
end

function M.handle(msg)
  if msg.cmd ~= "liar_agent_eval" then
    return
  end
  local reply_to = tonumber(msg.reply_to) or 0
  if reply_to == 0 then
    return
  end
  local call_ok, task_ok, result = pcall(runtime.run_task, {
    room_id = msg.room_id,
    request_id = msg.request_id,
    seat = msg.seat,
    subround = msg.subround,
    round_target = msg.round_target,
    turn = msg.turn,
    subphase = msg.subphase,
    react_to_seat = msg.react_to_seat,
    last_play = msg.last_play,
    public_log = msg.public_log,
    seats = msg.seats,
    hand = msg.hand,
  })
  if not call_ok then
    gn_send(reply_to, j_obj({
      cmd = "__bot_llm_result",
      request_id = msg.request_id,
      seat = msg.seat,
      ok = false,
      source = "agent_pool",
      stage = "exception",
      reason = tostring(task_ok),
      pool_actor = self_id,
    }))
    return
  end
  gn_send(reply_to, j_obj({
    cmd = "__bot_llm_result",
    request_id = msg.request_id,
    seat = msg.seat,
    ok = task_ok and true or false,
    source = "agent_pool",
    stage = result.stage,
    reason = result.reason,
    action = result.action,
    cards = result.cards,
    summary = result.summary,
    raw_output = result.raw_output,
    attempt = result.attempt,
    pool_actor = self_id,
  }))
end

return M
