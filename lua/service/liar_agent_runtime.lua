local M = {}

local MODEL_ID = os.getenv("ARK_MODEL_ID") or os.getenv("ARK_DEFAULT_MODEL") or "doubao-1-5-lite-32k-250115"
local SUMMARY_MODEL_ID = os.getenv("LIAR_SUMMARY_MODEL") or MODEL_ID
local SUMMARY_WINDOW = tonumber(os.getenv("LIAR_SUMMARY_WINDOW") or "24") or 24
local POLICY_RETRY_LIMIT = tonumber(os.getenv("LIAR_POLICY_RETRY_LIMIT") or "1") or 1

local llm_checked = false
local llm_available = false
local llm_last_check_at = 0
local llm_last_reason = ""

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

local function short_reason(s)
  s = tostring(s or "")
  if #s > 64 then
    return s:sub(1, 64) .. "..."
  end
  return s
end

local function trim_public_log(public_log)
  if type(public_log) ~= "table" then
    return {}
  end
  if SUMMARY_WINDOW <= 0 or #public_log <= SUMMARY_WINDOW then
    return public_log
  end
  local out = {}
  for i = #public_log - SUMMARY_WINDOW + 1, #public_log do
    out[#out + 1] = public_log[i]
  end
  return out
end

local function compact_text(s)
  return tostring(s or ""):gsub("%s+", "")
end

function M.llm_enabled()
  local v = os.getenv("LIAR_BOT_LLM")
  return v == "1" or v == "true" or v == "yes"
end

function M.model_id()
  return MODEL_ID
end

function M.summary_model_id()
  return SUMMARY_MODEL_ID
end

function M.check_llm_ready()
  if not M.llm_enabled() then
    return false, "llm_disabled"
  end
  if llm_checked and (os.time() - llm_last_check_at) < 30 then
    return llm_available, llm_last_reason
  end
  llm_checked = true
  llm_last_check_at = os.time()
  local out = tostring(gn_llm_chat(MODEL_ID, "请仅回复“可用”两个字。") or "")
  local text = compact_text(out)
  if #text == 0 then
    llm_available = false
    llm_last_reason = "empty_response"
  elseif text:sub(1, 8) == "__ERR__:" then
    llm_available = false
    llm_last_reason = short_reason(text:sub(9))
  else
    llm_available = true
    llm_last_reason = "ok"
  end
  return llm_available, llm_last_reason
end

function M.build_summarizer_prompt(snapshot)
  snapshot = snapshot or {}
  local lines = {}
  lines[#lines + 1] = "你是观战视角的战局总结助手。输入仅为公开信息：已发生的出牌/开牌事件、各座位剩余张数、回合状态。你不知道、也不得推断任何玩家的具体手牌。"
  lines[#lines + 1] = "【公开结构化快照 JSON】"
  lines[#lines + 1] = j_obj({
    room_id = snapshot.room_id,
    subround = snapshot.subround,
    round_target = snapshot.round_target,
    turn = snapshot.turn,
    subphase = snapshot.subphase,
    react_to_seat = snapshot.react_to_seat,
    last_play = snapshot.last_play,
    seats = snapshot.seats,
    public_log = trim_public_log(snapshot.public_log),
  })
  lines[#lines + 1] = "请用 3 到 8 句中文总结当前战局与博弈重点。只能基于公开信息，不要猜测未在 reveal 事件中出现过的牌。"
  return table.concat(lines, "\n")
end

function M.build_policy_prompt(task, summary, retry_reason, last_output)
  local must = task.subphase == "must_play"
  local phase_hint
  if must then
    phase_hint = "当前你必须出牌（must_play）：只能输出 play，不可 challenge。"
  else
    phase_hint = "当前为 react：你可对上一手选择 challenge，或跟牌 play。"
  end
  local lines = {
    "你是骗子酒馆座位 " .. tostring(task.seat) .. " 的决策机器人。",
    phase_hint,
    "【公开结构化快照 JSON】",
    j_obj({
      room_id = task.room_id,
      subround = task.subround,
      round_target = task.round_target,
      turn = task.turn,
      subphase = task.subphase,
      react_to_seat = task.react_to_seat,
      last_play = task.last_play,
      seats = task.seats,
      public_log = trim_public_log(task.public_log),
    }),
    "【公开战局摘要】",
    tostring(summary or ""),
    "【你的手牌（仅此可见）】",
    table.concat(task.hand or {}, ","),
    "只允许输出一行 JSON，不要输出解释、代码块或其它文字。",
    '出牌格式：{"action":"play","cards":["Q","K"]}',
    '质疑格式：{"action":"challenge"}',
    "cards 必须是 1 到 3 张，且只能使用你手牌中的 Q/K/A/J。",
  }
  if retry_reason and #retry_reason > 0 then
    lines[#lines + 1] = "你上一条输出不合格，原因：" .. retry_reason
  end
  if last_output and #tostring(last_output) > 0 then
    lines[#lines + 1] = "上一条原始输出：" .. tostring(last_output)
  end
  return table.concat(lines, "\n")
end

local function extract_json_object(s)
  s = tostring(s or "")
  local fence = s:match("```[a-zA-Z]*%s*(.-)```")
  if fence and #fence > 0 then
    s = fence
  end
  local start = s:find("{")
  if not start then
    return nil
  end
  local depth = 0
  for i = start, #s do
    local c = s:sub(i, i)
    if c == "{" then
      depth = depth + 1
    elseif c == "}" then
      depth = depth - 1
      if depth == 0 then
        return s:sub(start, i)
      end
    end
  end
  return nil
end

function M.parse_bot_action(text)
  local obj = extract_json_object(text)
  if not obj then
    return nil, nil, "missing_json_object"
  end
  local action = obj:match('"action"%s*:%s*"([^"]+)"')
  if not action then
    action = obj:match("'action'%s*:%s*'([^']+)'")
  end
  action = tostring(action or ""):lower()
  if action == "challenge" then
    return "challenge", nil, nil
  end
  if action ~= "play" then
    return nil, nil, "bad_action"
  end
  local arr = obj:match('"cards"%s*:%s*%[([^%]]*)%]') or obj:match("'cards'%s*:%s*%[([^%]]*)%]")
  if not arr then
    return nil, nil, "missing_cards"
  end
  local cards = {}
  for q in arr:gmatch("[\"']([QKAJqkaj])[\"']") do
    cards[#cards + 1] = string.upper(q)
  end
  if #cards < 1 or #cards > 3 then
    return nil, nil, "bad_cards_count"
  end
  return "play", cards, nil
end

local function llm_call(model, prompt)
  local out = tostring(gn_llm_chat(model, prompt) or "")
  if #compact_text(out) == 0 then
    return nil, "empty_response"
  end
  if out:sub(1, 8) == "__ERR__:" then
    return nil, short_reason(out:sub(9))
  end
  return out, nil
end

function M.run_task(task)
  local summary, summary_err = llm_call(SUMMARY_MODEL_ID, M.build_summarizer_prompt(task))
  if not summary then
    return false, {
      stage = "summary",
      reason = summary_err or "summary_failed",
    }
  end
  local retry_reason = nil
  local last_output = nil
  for attempt = 1, POLICY_RETRY_LIMIT + 1 do
    local prompt = M.build_policy_prompt(task, summary, retry_reason, last_output)
    local out, policy_err = llm_call(MODEL_ID, prompt)
    if not out then
      retry_reason = policy_err or "policy_failed"
      last_output = nil
    else
      local action, cards, parse_err = M.parse_bot_action(out)
      if action then
        return true, {
          stage = "policy",
          action = action,
          cards = cards,
          summary = summary,
          raw_output = out,
          attempt = attempt,
        }
      end
      retry_reason = parse_err or "parse_failed"
      last_output = out
    end
  end
  return false, {
    stage = "policy",
    reason = retry_reason or "policy_failed",
    raw_output = last_output,
    summary = summary,
  }
end

return M
