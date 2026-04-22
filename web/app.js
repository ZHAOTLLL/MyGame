const qs = (s) => document.querySelector(s);
const logBox = () => qs("#logBox");

let WsPacket = null;
function ensureProto() {
  if (WsPacket) return WsPacket;
  if (!window.protobuf) throw new Error("protobufjs not loaded");
  const root = window.protobuf.Root.fromJSON({
    nested: {
      WsPacket: {
        fields: {
          json: { type: "string", id: 1 },
        },
      },
    },
  });
  WsPacket = root.lookupType("WsPacket");
  return WsPacket;
}

function encodePacketFromObject(obj) {
  const type = ensureProto();
  const payload = { json: JSON.stringify(obj) };
  const err = type.verify(payload);
  if (err) throw new Error(err);
  return type.encode(type.create(payload)).finish();
}

function decodePacketToObject(data) {
  const type = ensureProto();
  if (typeof data === "string") return JSON.parse(data);
  const bytes = new Uint8Array(data);
  const m = type.decode(bytes);
  return JSON.parse(m.json || "{}");
}

const state = {
  ws: null,
  token: null,
  name: "",
  _loginPassword: "",
  roomId: null,
  hand: [],
  selected: new Set(),
  lastState: null,
  mySeat: null,
  declarationConfirmed: false,
  _playCtxKey: "",
  tableStack: {
    by: null,
    cards: [],
    nonce: 0,
  },
  lastChallengeMeta: null,
  lastChallengeExpireAt: 0,
  tableRevealExpireAt: 0,
  lastSettlement: null,
  turnDeadlineAt: 0,
  turnCtxKey: "",
  gunFxTimer: 0,
  llmStatus: null,
};

function rankLabel(r) {
  if (r === "Q") return "QUEEN（Q）";
  if (r === "K") return "KING（K）";
  if (r === "A") return "ACE（A）";
  if (r === "J") return "JOKER";
  return String(r);
}

function shortCardName(c) {
  const v = String(c || "?");
  if (v === "J") return "J";
  if (v === "Q" || v === "K" || v === "A") return v;
  return "?";
}

function log(line) {
  const el = logBox();
  if (!el) return;
  el.textContent += `[${new Date().toLocaleTimeString()}] ${line}\n`;
  el.scrollTop = el.scrollHeight;
}

function setConn(ok, text) {
  const pill = qs("#connPill");
  const t = qs("#connText");
  pill.classList.toggle("ok", ok);
  t.textContent = text;
}

function setLlmStatus(payload) {
  state.llmStatus = payload || null;
  const dot = qs("#llmStatusDot");
  const text = qs("#llmStatusText");
  const detail = qs("#llmStatusDetail");
  if (!dot || !text || !detail) return;
  dot.classList.remove("online", "offline", "warn");
  if (!payload) {
    dot.classList.add("offline");
    text.textContent = "未检测";
    detail.textContent = "登录后会自动检测当前机器人是否可用。";
    return;
  }
  if (payload.available) {
    dot.classList.add("online");
    text.textContent = payload.enabled ? "Agent 已在线" : "模型可用";
    detail.textContent =
      payload.detail === "ok"
        ? "当前大模型接口检测成功，机器人可进入 Agent 决策流程。"
        : String(payload.detail || "接口就绪");
    return;
  }
  dot.classList.add(payload.enabled ? "warn" : "offline");
  text.textContent = payload.enabled ? "Agent 回退随机" : "未启用大模型";
  detail.textContent = String(payload.detail || "当前大模型不可用，机器人会回退到随机策略。");
}

function setLlmStatus(payload) {
  state.llmStatus = payload || null;
  const dot = qs("#llmStatusDot");
  const text = qs("#llmStatusText");
  const detail = qs("#llmStatusDetail");
  if (!dot || !text || !detail) return;
  dot.classList.remove("online", "offline", "warn");
  if (!payload) {
    dot.classList.add("offline");
    text.textContent = "未检测";
    detail.textContent = "登录后会自动检测当前机器人是否可用。";
    return;
  }
  if (payload.available) {
    dot.classList.add("online");
    text.textContent = payload.enabled ? "Agent 已在线" : "模型可用";
    detail.textContent = payload.detail === "ok" ? "当前大模型接口检测成功，机器人可进入 Agent 决策流程。" : String(payload.detail || "接口就绪");
    return;
  }
  dot.classList.add(payload.enabled ? "warn" : "offline");
  text.textContent = payload.enabled ? "Agent 回退随机" : "未启用大模型";
  detail.textContent = String(payload.detail || "当前大模型不可用，机器人会回退到随机策略。");
}

function wsUrl() {
  const loc = window.location;
  const scheme = loc.protocol === "https:" ? "wss" : "ws";
  return `${scheme}://${loc.hostname}:8765/ws`;
}

function show(id) {
  ["screen-login", "screen-lobby", "screen-room"].forEach((x) => {
    qs("#" + x).classList.toggle("hidden", x !== id);
  });
  if (document.body) document.body.setAttribute("data-screen", id);
}

function send(obj) {
  if (!state.ws || state.ws.readyState !== WebSocket.OPEN) {
    log("当前未连接，操作未发送。");
    return;
  }
  state.ws.send(encodePacketFromObject(obj));
}

function renderSeatPositions() {
  if (window.innerWidth <= 720) {
    return [
      { left: "50%", top: "-4%", transform: "translate(-50%, 0)" },
      { left: "95%", top: "42%", transform: "translate(-50%, -50%)" },
      { left: "50%", top: "88%", transform: "translate(-50%, 0)" },
      { left: "5%", top: "42%", transform: "translate(-50%, -50%)" },
    ];
  }
  if (window.innerWidth <= 980) {
    return [
      { left: "50%", top: "-10%", transform: "translate(-50%, 0)" },
      { left: "98%", top: "42%", transform: "translate(-50%, -50%)" },
      { left: "50%", top: "91%", transform: "translate(-50%, 0)" },
      { left: "2%", top: "42%", transform: "translate(-50%, -50%)" },
    ];
  }
  return [
    { left: "50%", top: "-16%", transform: "translate(-50%, 0)" },
    { left: "102%", top: "42%", transform: "translate(-50%, -50%)" },
    { left: "50%", top: "96%", transform: "translate(-50%, 0)" },
    { left: "-2%", top: "42%", transform: "translate(-50%, -50%)" },
  ];
}

function playSlotPosition(seat) {
  if (window.innerWidth <= 720) {
    if (seat === 1) return { left: "50%", top: "20%" };
    if (seat === 2) return { left: "69%", top: "43%" };
    if (seat === 3) return { left: "50%", top: "63%" };
    return { left: "31%", top: "43%" };
  }
  if (seat === 1) return { left: "50%", top: "18%" };
  if (seat === 2) return { left: "72%", top: "43%" };
  if (seat === 3) return { left: "50%", top: "67%" };
  return { left: "28%", top: "43%" };
}

/** Lua 序列化 seats[1..4] 为 JSON 数组，JS 里下标 0 对应座位 1 */
function seatAt(st, seatIndex) {
  const seats = st.seats;
  if (!seats) return null;
  if (Array.isArray(seats)) return seats[seatIndex - 1] != null ? seats[seatIndex - 1] : null;
  if (seats[seatIndex] != null) return seats[seatIndex];
  if (seats[String(seatIndex)] != null) return seats[String(seatIndex)];
  return null;
}

function isRoomWaiting(st) {
  const ph = st.phase;
  return !ph || ph === "lobby" || ph === "ended";
}

function canOperateTurn(st) {
  if (!st || st.phase !== "playing") return false;
  const my = st.my_seat;
  const t = st.turn;
  const sub = st.subphase;
  if (my == null || t !== my) return false;
  const me = seatAt(st, my);
  if (me && me.alive === false) return false;
  if (sub === "must_play") return true;
  if (sub === "react" && st.last_play) return true;
  return false;
}

/** 回合/阶段变化时重置「已声明」 */
function playContextKey(st) {
  if (!st || st.phase !== "playing") return "";
  const lp = st.last_play;
  return `${st.turn}|${st.subphase}|${lp ? `${lp.by}:${lp.count}` : "-"}`;
}

function needsDeclarationForPlay(st) {
  if (!st || st.phase !== "playing") return false;
  const sub = st.subphase;
  if (sub === "must_play") return true;
  if (sub === "react" && st.last_play) return true;
  return false;
}

function setActionReason(text) {
  const el = qs("#actionReason");
  if (!el) return;
  el.textContent = text || "";
}

function setHandHint(text) {
  const el = qs("#handHint");
  if (!el) return;
  el.textContent = text || "";
}

function updateRoomMeta(st) {
  const el = qs("#roomMeta");
  if (!el || !st) return;
  const mode = st.game_type === "idiom" ? "成语接龙" : "骗子酒馆";
  const seat = st.my_seat != null ? `你的座位 ${st.my_seat}` : "旁观同步中";
  const phase =
    st.phase === "playing"
      ? `对局进行中 · 第 ${st.subround || 1} 小局`
      : st.phase === "ended"
        ? "本局已结束，等待再次开局"
        : "房间准备阶段";
  el.textContent = `${mode} · ${seat} · 房主座位 ${st.host_seat || "?"} · ${phase}`;
}

function actionState(st) {
  const result = {
    canPlay: false,
    canChallenge: false,
    playReason: "",
    hint: "",
  };
  if (!st || st.phase !== "playing") {
    result.playReason = "等待房主开始新一局。";
    result.hint = "当前不在对局中，可先等待玩家齐备或重新开局。";
    return result;
  }
  if (st.my_seat == null) {
    result.playReason = "正在同步你的座位信息。";
    result.hint = "请稍候，房间状态同步完成后再操作。";
    return result;
  }
  if (st.turn !== st.my_seat) {
    result.playReason = `当前轮到座位 ${st.turn || "?"}。`;
    result.hint = "现在不是你的回合，先观察桌面声明与已开牌信息。";
    return result;
  }
  if (st.subphase === "must_play") {
    result.canPlay = true;
    result.playReason = "先选 1 到 3 张手牌，再确认声明后出牌。";
    result.hint = "这是你的主动出牌阶段，只能出牌，不能质疑。";
    return result;
  }
  if (st.subphase === "react" && st.last_play) {
    result.canPlay = true;
    result.canChallenge = true;
    result.playReason = "你可以先质疑上家，也可以直接继续跟牌。";
    result.hint = `上家是座位 ${st.react_to_seat != null ? st.react_to_seat : "?"}，此时需要做出风险判断。`;
    return result;
  }
  result.playReason = "正在等待当前阶段稳定。";
  result.hint = "请稍候片刻，界面会在下一次状态同步后更新。";
  return result;
}

function requestLlmStatus() {
  if (!state.token) return;
  send({ cmd: "llm_status", token: state.token });
}

function requestLlmStatus() {
  if (!state.token) return;
  send({ cmd: "llm_status", token: state.token });
}

function updateRoomChrome(st) {
  const hostEl = qs("#roomActionsHost");
  const guestEl = qs("#roomActionsGuest");
  const handBar = qs("#handBar");
  const idiomBar = qs("#idiomBar");
  if (!hostEl || !guestEl) return;
  const my = st.my_seat;
  const hs = st.host_seat;
  const imHost = my != null && hs === my;
  const waiting = isRoomWaiting(st);
  const playing = st.phase === "playing";
  const isIdiom = st.game_type === "idiom";
  hostEl.classList.toggle("hidden", !(waiting && imHost));
  guestEl.classList.toggle("hidden", !(waiting && !imHost && my != null));
  if (handBar) handBar.classList.toggle("hidden", !playing || isIdiom);
  if (idiomBar) idiomBar.classList.toggle("hidden", !playing || !isIdiom);
  if (!playing) {
    const hand = qs("#hand");
    if (hand) hand.innerHTML = "";
    state.hand = [];
    state.selected.clear();
    setActionReason("");
    setHandHint("当前不在出牌阶段。");
  }
  const btnR = qs("#btnReady");
  if (btnR && my != null && !imHost) {
    const me = seatAt(st, my);
    const rd = me && me.ready;
    btnR.textContent = rd ? "取消准备" : "准备";
    btnR.classList.toggle("ready-on", !!rd);
  }
}

function refreshHandInteractivity(st) {
  const hand = qs("#hand");
  if (!hand) return;
  const can = canOperateTurn(st);
  hand.classList.toggle("hand-locked", !can);
  hand.querySelectorAll(".card-tile").forEach((el) => {
    el.classList.toggle("locked", !can);
  });
  if (!can) {
    state.selected.clear();
    hand.querySelectorAll(".card-tile.sel").forEach((el) => el.classList.remove("sel"));
  }
}

function updateTurnStrip(st) {
  const el = qs("#turnStrip");
  if (!el) return;
  const ph = st.phase;
  const my = st.my_seat;
  const t = st.turn;
  const sub = st.subphase;
  if (ph !== "playing") {
    if (ph === "lobby" || !ph) {
      el.innerHTML =
        `<span class="status-kicker">准备阶段</span>` +
        `<div>等待凑满 4 人。非房主请先准备，房主可加入机器人并在全员就绪后开始。</div>`;
    } else {
      el.innerHTML =
        `<span class="status-kicker">结算阶段</span>` +
        `<div>本局已结束。请查看结算信息，房主可在全员准备后再次开始。</div>`;
    }
    return;
  }
  if (my == null || !t) {
    el.innerHTML =
      `<span class="status-kicker">同步中</span>` +
      `<div>正在同步房间状态，请稍候。</div>`;
    return;
  }
  const target = st.round_target ? rankLabel(st.round_target) : "?";
  if (sub === "must_play") {
    if (t === my) {
      el.innerHTML =
        `<span class="status-kicker">你的回合</span>` +
        `<div><strong>立即行动：</strong> 选择 <strong>1 到 3 张</strong> 手牌，并声明为本轮骗子牌 <strong>${target}</strong> 后出牌。</div>`;
    } else {
      el.innerHTML =
        `<span class="status-kicker">等待行动</span>` +
        `<div>当前由座位 <strong>${t}</strong> 行动，本轮骗子牌是 <strong>${target}</strong>。</div>`;
    }
  } else if (sub === "react") {
    if (t === my) {
      el.innerHTML =
        `<span class="status-kicker">风险判断</span>` +
        `<div><strong>你可以质疑座位 ${st.react_to_seat != null ? st.react_to_seat : "?"}</strong>，也可以继续跟牌。若不质疑，仍需打出 1 到 3 张并声明为 <strong>${target}</strong>。</div>`;
    } else {
      el.innerHTML =
        `<span class="status-kicker">观察中</span>` +
        `<div>座位 <strong>${t}</strong> 正在决定是质疑上家还是继续跟牌。</div>`;
    }
  } else {
    el.innerHTML =
      `<span class="status-kicker">进行中</span>` +
      `<div>等待下一步动作。</div>`;
  }
}

function updateRoundInfo(st) {
  const el = qs("#roundInfo");
  if (!el) return;
  if (st.phase !== "playing" || !st.round_target) {
    el.innerHTML =
      `<div class="round-card"><span class="k">房间状态</span><div class="v">当前还未进入正式对局。房主可补齐玩家并开始游戏。</div></div>`;
    return;
  }
  const lp = st.last_play;
  const phaseText = st.subphase === "react" ? "可质疑 / 跟牌" : "必须出牌";
  let extra = "尚无本轮出牌，等待首位玩家打出背面牌。";
  if (lp) {
    extra = `上一手由座位 ${lp.by} 宣称打出 ${lp.count} 张骗子牌 ${rankLabel(st.round_target)}。`;
  }
  el.innerHTML = `
    <div class="round-card">
      <span class="k">本轮骗子牌</span>
      <div class="v"><strong>${rankLabel(st.round_target)}</strong> · 第 ${st.subround || 1} 小局</div>
    </div>
    <div class="round-card">
      <span class="k">当前阶段</span>
      <div class="v">${phaseText}</div>
    </div>
    <div class="round-card">
      <span class="k">桌面最新情报</span>
      <div class="v">${extra}</div>
    </div>
  `;
}

function setTableStack(bySeat, count, reveal, revealedCards, honest) {
  const c = Math.max(0, Math.min(3, Number(count) || 0));
  state.tableStack.by = bySeat != null ? bySeat : null;
  state.tableStack.nonce += 1;
  const src = Array.isArray(revealedCards) ? revealedCards : [];
  state.tableStack.cards = Array.from({ length: c }, (_, idx) => ({
    id: `stack_${state.tableStack.nonce}_${idx}`,
    reveal: !!reveal,
    face: src[idx] ? shortCardName(src[idx]) : "?",
    honest: honest == null ? null : !!honest,
    fresh: true,
  }));
}

function revealTableStack(revealedCards, honest) {
  if (!state.tableStack.cards.length) return;
  const src = Array.isArray(revealedCards) ? revealedCards : [];
  state.tableStack.cards = state.tableStack.cards.map((c) => ({
    ...c,
    reveal: true,
    face: src.length ? shortCardName(src.shift()) : c.face,
    honest: honest == null ? c.honest : !!honest,
    fresh: false,
    flipFresh: true,
  }));
}

function clearTableStack() {
  state.tableStack.by = null;
  state.tableStack.cards = [];
}

function gunFxPosition(seat) {
  if (window.innerWidth <= 720) {
    if (seat === 1) return { left: "50%", top: "12%" };
    if (seat === 2) return { left: "82%", top: "43%" };
    if (seat === 3) return { left: "50%", top: "76%" };
    return { left: "18%", top: "43%" };
  }
  if (window.innerWidth <= 980) {
    if (seat === 1) return { left: "50%", top: "10%" };
    if (seat === 2) return { left: "84%", top: "43%" };
    if (seat === 3) return { left: "50%", top: "79%" };
    return { left: "16%", top: "43%" };
  }
  if (seat === 1) return { left: "50%", top: "8%" };
  if (seat === 2) return { left: "86%", top: "42%" };
  if (seat === 3) return { left: "50%", top: "82%" };
  return { left: "14%", top: "42%" };
}

function gunTrailAngle(seat) {
  if (seat === 1) return 96;
  if (seat === 2) return 188;
  if (seat === 3) return 276;
  return 8;
}

function triggerGunEffect(seat, killed) {
  const layer = qs("#gunFx");
  const flash = qs("#tableFlash");
  const table = qs("#table");
  if (!layer || !flash || !table) return;
  if (state.gunFxTimer) clearTimeout(state.gunFxTimer);
  layer.innerHTML = "";
  flash.classList.remove("fire");
  table.classList.remove("revolver-fire", "revolver-kill");
  const pos = gunFxPosition(seat || 1);
  const trail = document.createElement("div");
  trail.className = "gun-trail";
  trail.style.left = pos.left;
  trail.style.top = pos.top;
  trail.style.transform = `translate(-50%, -50%) rotate(${gunTrailAngle(seat || 1)}deg)`;
  const burst = document.createElement("div");
  burst.className = "gun-burst" + (killed ? " is-kill" : "");
  burst.style.left = pos.left;
  burst.style.top = pos.top;
  const word = document.createElement("div");
  word.className = "gun-word";
  word.style.left = pos.left;
  word.style.top = pos.top;
  word.textContent = killed ? "BANG" : "CLICK";
  layer.appendChild(trail);
  layer.appendChild(burst);
  layer.appendChild(word);
  void table.offsetWidth;
  flash.classList.add("fire");
  table.classList.add(killed ? "revolver-kill" : "revolver-fire");
  state.gunFxTimer = window.setTimeout(() => {
    layer.innerHTML = "";
    flash.classList.remove("fire");
    table.classList.remove("revolver-fire", "revolver-kill");
    state.gunFxTimer = 0;
  }, killed ? 700 : 560);
}

function syncTableStackWithState(st) {
  const now = Date.now();
  if (!st || st.phase !== "playing") {
    clearTableStack();
    return;
  }
  const lp = st.last_play;
  if (!lp) {
    if (state.tableStack.cards.length && now < (state.tableRevealExpireAt || 0)) {
      return;
    }
    clearTableStack();
    return;
  }
  if (
    !state.tableStack.cards.length ||
    state.tableStack.by !== lp.by ||
    state.tableStack.cards.length !== lp.count
  ) {
    setTableStack(lp.by, lp.count, false);
  }
}

function renderPlayStack(st) {
  const hub = qs("#playStack");
  if (!hub) return;
  hub.innerHTML = "";
  const cards = state.tableStack.cards;
  if (!cards.length) {
    hub.classList.remove("has-cards");
    return;
  }
  hub.classList.add("has-cards");
  const bySeat = state.tableStack.by || 1;
  const p = playSlotPosition(bySeat);
  const slot = document.createElement("div");
  slot.className = "player-play-slot";
  slot.style.left = p.left;
  slot.style.top = p.top;
  slot.style.transform = "translate(-50%, -50%)";
  hub.appendChild(slot);
  cards.forEach((card, idx) => {
    const el = document.createElement("div");
    el.className = "table-card";
    if (card.fresh) el.classList.add("enter");
    el.style.setProperty("--i", String(idx));
    const frontCls =
      card.honest == null ? "" : card.honest ? "truth" : "lie";
    el.innerHTML = `
      <div class="table-card-face table-card-back">?</div>
      <div class="table-card-face table-card-front ${frontCls}">${card.face || "?"}</div>
    `;
    slot.appendChild(el);
    if (card.reveal && card.flipFresh) {
      const delay = idx * 130;
      window.setTimeout(() => {
        el.classList.add("revealed");
      }, delay);
      card.flipFresh = false;
    } else if (card.reveal) {
      el.classList.add("revealed");
    }
    if (card.fresh) {
      requestAnimationFrame(() => {
        el.classList.remove("enter");
      });
      card.fresh = false;
    }
  });
  if (st && st.subphase === "react" && st.last_play && st.turn) {
    const cp = playSlotPosition(st.turn);
    const tag = document.createElement("div");
    tag.className = "challenge-badge";
    tag.style.left = cp.left;
    tag.style.top = cp.top;
    tag.textContent = "质疑!";
    hub.appendChild(tag);
  }
}

function updateDeclareBar(st) {
  const bar = qs("#declareBar");
  if (!bar) return;
  const ph = st.phase;
  const my = st.my_seat;
  const t = st.turn;
  const sub = st.subphase;
  const show =
    ph === "playing" &&
    my != null &&
    t === my &&
    (sub === "must_play" || (sub === "react" && st.last_play));
  bar.classList.toggle("hidden", !show);
  if (!show) return;
  const rt = st.round_target;
  bar.querySelectorAll(".rank-chip").forEach((btn) => {
    const r = btn.dataset.rank;
    const isTarget = r === rt;
    btn.disabled = !isTarget;
    btn.classList.toggle("is-target", isTarget);
  });
  const stEl = qs("#declareStatus");
  if (stEl) {
    if (state.declarationConfirmed) {
      stEl.textContent = `声明已确认：你将口头声明这些牌都是 ${rankLabel(rt)}。`;
    } else {
      stEl.textContent = `请点击 ${rankLabel(rt)}，确认你的口头声明与本轮骗子牌一致。`;
    }
  }
}

function updateActionButtons(st) {
  const btnP = qs("#btnPlay");
  const btnC = qs("#btnChallenge");
  if (!btnP || !btnC) return;
  const sub = st.subphase;
  const action = actionState(st);
  const canPlay = action.canPlay;
  const canChallenge = action.canChallenge;
  const declOk = !needsDeclarationForPlay(st) || state.declarationConfirmed;
  const idxs = Array.from(state.selected);
  const hasCards = idxs.length >= 1 && idxs.length <= 3;
  btnP.disabled = !canPlay || !declOk || !hasCards;
  btnC.disabled = !canChallenge;
  btnP.textContent = sub === "react" ? "继续跟牌" : "确认出牌";
  btnC.textContent = "质疑开牌";
  btnC.classList.toggle("pulse", !!canChallenge);
  if (!canPlay && !canChallenge) {
    setActionReason(action.playReason);
  } else if (!hasCards && canPlay) {
    setActionReason("请先从手牌区选择 1 到 3 张牌。");
  } else if (!declOk && canPlay) {
    setActionReason("请先点击上方声明筹码，确认口头声明。");
  } else if (canChallenge && sub === "react") {
    setActionReason("你可以直接质疑上家，或继续跟牌压过局势。");
  } else {
    setActionReason("操作条件已满足，可以执行当前动作。");
  }
  setHandHint(action.hint);
}

function bustSvg(avatarIdx) {
  if (typeof cyberCharacterBust === "function") {
    return cyberCharacterBust(avatarIdx);
  }
  return "";
}

function renderTable(st) {
  const ctx = playContextKey(st);
  if (ctx !== state._playCtxKey) {
    state._playCtxKey = ctx;
    state.declarationConfirmed = false;
  }
  const table = qs("#table");
  table.querySelectorAll(".seat").forEach((el) => el.remove());
  const pos = renderSeatPositions();
  const my = st.my_seat;
  const hostSeat = st.host_seat;
  for (let i = 1; i <= 4; i++) {
    const s = seatAt(st, i);
    const el = document.createElement("div");
    el.className = "seat";
    el.style.left = pos[i - 1].left;
    el.style.top = pos[i - 1].top;
    el.style.transform = pos[i - 1].transform;
    if (st.phase === "playing" && st.turn === i) el.classList.add("active");
    if (st.phase === "playing" && st.subphase === "react" && st.turn === my && st.react_to_seat === i) {
      el.classList.add("challenge-target");
    }
    if (my === i) el.classList.add("self");
    if (!s || s.empty) {
      el.innerHTML = `<div class="cyber-bust-wrap" style="height:72px;opacity:.35"></div><div class="seat-meta seat-empty-inner">空位 // SLOT_${i}</div>`;
    } else {
      const hostHtml = i === hostSeat || s.is_host ? `<span class="host-badge">房主</span>` : "";
      const who = (s.name || "玩家") + hostHtml;
      const cnt = s.hand_count != null ? s.hand_count : "—";
      const hc = my === i ? `你 · 剩余 ${cnt} 张` : `剩余 ${cnt} 张`;
      const tag = s.bot ? "BOT" : "LINK";
      const svg = bustSvg(s.avatar || 1);
      const inLobby = !st.phase || st.phase === "lobby";
      const imHost = my != null && hostSeat === my;
      const canKick =
        inLobby && imHost && s.human && !s.bot && my !== i;
      const kickBtn = canKick
        ? `<button type="button" class="btn btn-kick" data-kick-seat="${i}">踢出</button>`
        : "";
      const readyLine =
        inLobby && s.human
          ? `<div class="ready-line">${s.ready ? "● 已准备" : "○ 未准备"}</div>`
          : "";
      const botStatusLine =
        s.bot && s.bot_status
          ? `<div class="ready-line" style="color:#fcd34d">${s.bot_status}</div>`
          : "";
      const challengeLine =
        st.phase === "playing" && st.subphase === "react" && st.turn === my && st.react_to_seat === i
          ? `<div class="challenge-seat-tag">可开牌目标</div>`
          : "";
      let revLine = "";
      if (st.phase === "playing") {
        if (s.alive === false) {
          el.classList.add("eliminated");
          revLine = `<div class="revolver-meta dead">已中弹淘汰</div>`;
        } else {
          revLine = `<div class="revolver-meta">左轮·空枪 ${s.revolver_pulls != null ? s.revolver_pulls : 0} 次</div>`;
        }
      }
      el.innerHTML = `
        <div class="cyber-bust-wrap">${svg}</div>
        <div class="seat-meta">
          <div class="who">${who}</div>
          <div class="hand-count">${hc}</div>
          ${readyLine}
          ${botStatusLine}
          ${challengeLine}
          ${revLine}
          <div class="muted" style="font-size:10px;margin-top:4px;letter-spacing:.12em">${tag} · S${i}</div>
          ${kickBtn}
        </div>`;
      if (canKick) {
        const kb = el.querySelector(".btn-kick");
        if (kb)
          kb.onclick = (e) => {
            e.stopPropagation();
            send({ cmd: "kick", token: state.token, seat: i });
          };
      }
    }
    table.appendChild(el);
  }
  const pile = st.last_play;
  const pileEl = qs("#pileInfo");
  if (pileEl) {
    if (pile && st.round_target) {
      pileEl.textContent = `最新桌面声明：座位 ${pile.by} 宣称打出 ${pile.count} 张骗子牌 ${rankLabel(st.round_target)}，当前仍为盖牌状态。`;
    } else if (
      state.lastChallengeMeta &&
      st.phase === "playing" &&
      Date.now() < (state.lastChallengeExpireAt || 0)
    ) {
      pileEl.textContent = state.lastChallengeMeta;
    } else if (st.phase === "playing") {
      pileEl.textContent = `本轮尚无人出牌，等待座位 ${st.turn || "?"} 先手。`;
    } else {
      pileEl.textContent = "";
    }
  }
  syncTableStackWithState(st);
  renderPlayStack(st);
  updateTurnStrip(st);
  updateRoundInfo(st);
  updateDeclareBar(st);
  updateActionButtons(st);
  updateRoomChrome(st);
  updateRoomMeta(st);
  refreshHandInteractivity(st);
  if (st.game_type === "idiom") {
    const hint = qs("#idiomHint");
    if (hint) {
      hint.textContent = `当前成语：${st.idiom_current || "（等待开始）"}，已使用 ${st.idiom_used_count || 0} 条。`;
    }
  }
}

function renderSettlement(settlement) {
  const panel = qs("#gameResultPanel");
  const textEl = qs("#gameResultText");
  const listEl = qs("#gameResultList");
  if (!panel || !textEl || !listEl) return;
  if (!settlement) {
    panel.classList.add("hidden");
    textEl.textContent = "";
    listEl.innerHTML = "";
    return;
  }
  panel.classList.remove("hidden");
  const reason =
    settlement.reason === "last_standing" ? "最后存活" : settlement.reason || "结算";
  textEl.textContent = `胜者：座位 ${settlement.winner_seat} · 原因：${reason}。${settlement.text || ""}`;
  listEl.innerHTML = "";
  (settlement.seats || []).forEach((s) => {
    const row = document.createElement("div");
    row.className = "result-row" + (s.is_winner ? " win" : "");
    row.textContent = `S${s.seat} ${s.name || "玩家"} · ${s.alive ? "存活" : "淘汰"} · 手牌${s.hand_count != null ? s.hand_count : 0} · 左轮空枪${s.revolver_pulls != null ? s.revolver_pulls : 0}`;
    listEl.appendChild(row);
  });
}

function cardLabel(c) {
  if (c === "J") return { big: "🃏", sm: "JOKER" };
  return { big: c, sm: rankLabel(c).split("（")[0] };
}

function renderHand(cards) {
  state.hand = Array.isArray(cards) ? cards.slice() : [];
  state.selected.clear();
  const hand = qs("#hand");
  hand.innerHTML = "";
  state.hand.forEach((v, idx) => {
    const t = document.createElement("div");
    t.className = "card-tile";
    const lab = cardLabel(String(v));
    t.innerHTML = `<span class="sm">${lab.sm}</span>${lab.big}`;
    t.dataset.idx = String(idx);
    t.title = `${lab.sm} · 点击选中`;
    t.onclick = () => {
      if (!canOperateTurn(state.lastState)) return;
      t.classList.toggle("sel");
      const i = Number(t.dataset.idx);
      if (state.selected.has(i)) state.selected.delete(i);
      else state.selected.add(i);
      if (state.lastState) updateActionButtons(state.lastState);
    };
    hand.appendChild(t);
  });
  if (state.lastState) updateActionButtons(state.lastState);
}

function bindUi() {
  qs("#wsHint").textContent = wsUrl();
  qs("#btnLogin").onclick = () => {
    state.name = qs("#nameInput").value.trim() || "旅人";
    const pwdInput = qs("#pwdInput");
    const password = pwdInput && pwdInput.value ? pwdInput.value.trim() : "";
    connect();
    state._loginPassword = password;
  };
  qs("#btnCreate").onclick = () => send({ cmd: "create_room", token: state.token });
  const btnCreateIdiom = qs("#btnCreateIdiom");
  if (btnCreateIdiom) {
    btnCreateIdiom.onclick = () => send({ cmd: "create_idiom_room", token: state.token });
  }
  qs("#btnJoin").onclick = () => {
    const rid = qs("#roomIdInput").value.trim();
    send({ cmd: "join_room", token: state.token, room_id: rid });
  };
  qs("#btnMatch").onclick = () => send({ cmd: "match", token: state.token });
  qs("#btnBot").onclick = () => send({ cmd: "add_bot", token: state.token });
  qs("#btnStart").onclick = () => send({ cmd: "start_game", token: state.token });
  qs("#btnReady").onclick = () => send({ cmd: "set_ready", token: state.token });
  qs("#btnLeaveRoom").onclick = () => send({ cmd: "leave_room", token: state.token });
  qs("#btnPlay").onclick = () => {
    const st = state.lastState;
    if (needsDeclarationForPlay(st) && !state.declarationConfirmed) {
      log("请先点击 Q / K / A 中与本轮目标一致的那张，确认声明");
      return;
    }
    const idxs = Array.from(state.selected).sort((a, b) => a - b);
    if (idxs.length < 1 || idxs.length > 3) {
      log("请选择 1～3 张牌");
      return;
    }
    const cards = idxs.map((i) => state.hand[i]);
    send({ cmd: "play", token: state.token, cards });
  };
  qs("#btnChallenge").onclick = () => send({ cmd: "challenge", token: state.token });
  const btnIdiomSubmit = qs("#btnIdiomSubmit");
  if (btnIdiomSubmit) {
    btnIdiomSubmit.onclick = () => {
      const idiomInput = qs("#idiomInput");
      const v = idiomInput && idiomInput.value ? idiomInput.value.trim() : "";
      if (!v) return;
      send({ cmd: "idiom_submit", token: state.token, text: v });
      const inp = qs("#idiomInput");
      if (inp) inp.value = "";
    };
  }
  const chips = qs("#declareChips");
  if (chips) {
    chips.onclick = (e) => {
      const b = e.target.closest(".rank-chip");
      if (!b || b.disabled) return;
      const st = state.lastState;
      if (!canOperateTurn(st) || !needsDeclarationForPlay(st)) return;
      const r = b.dataset.rank;
      if (r !== st.round_target) return;
      state.declarationConfirmed = true;
      updateDeclareBar(st);
      updateActionButtons(st);
    };
  }
}

function handleMessage(msg) {
  const c = msg.cmd;
  if (c === "login_ok") {
    state.token = msg.token;
    log(`登录成功`);
    show("screen-lobby");
    requestLlmStatus();
    return;
  }
  if (c === "llm_status") {
    setLlmStatus(msg);
    return;
  }
  if (c === "error") {
    const r = msg.reason || "unknown";
    log(`错误：${r}`);
    if (r === "bad_account_or_password") log("账号或密码错误（小明/111111，李华/222222，Tom/333333，Jack/444444）");
    if (r === "need_4_players") log("开始游戏需要 4 人就座（可让房主添加机器人）。");
    if (r === "not_all_ready") log("仍有未准备的玩家（非房主需点「准备」）。");
    if (r === "llm_unavailable") {
      log("大模型接口不可用：请先检查 ARK_API_KEY/VOLCENGINE_API_KEY 与网络。");
      if (msg.detail) log(`LLM 细节：${msg.detail}`);
    }
    return;
  }
  if (c === "room_joined" || c === "match_ready") {
    state.roomId = msg.room_id;
    state.mySeat = msg.your_seat != null ? msg.your_seat : null;
    qs("#roomTitle").textContent = `房间 ${msg.room_id}`;
    qs("#roomMeta").textContent =
      state.mySeat != null
        ? `你的座位：${state.mySeat}。非房主请先「准备」；房主可拉机器人并在全员准备后开始。`
        : `你是参与者之一。`;
    show("screen-room");
    log(`进入房间 ${msg.room_id}`);
    return;
  }
  if (c === "room_state") {
    state.lastState = msg.state;
    if (msg.state.my_seat != null) state.mySeat = msg.state.my_seat;
    renderTable(msg.state);
    return;
  }
  if (c === "your_hand") {
    renderHand(msg.cards);
    refreshHandInteractivity(state.lastState);
    return;
  }
  if (c === "game_start") {
    state.lastSettlement = null;
    renderSettlement(null);
    const sr = msg.subround != null ? ` 第${msg.subround}小局` : "";
    log(
      (msg.text || "对局开始") +
        sr +
        ` · 骗子牌：${rankLabel(msg.round_target || "")}`
    );
    return;
  }
  if (c === "subround_start") {
    clearTableStack();
    state.tableRevealExpireAt = 0;
    state.lastChallengeMeta = null;
    renderSettlement(null);
    log(
      (msg.text || "新小局") +
        ` · 骗子牌：${rankLabel(msg.round_target || "")}`
    );
    return;
  }
  if (c === "idiom_prompt") {
    log(`接龙起始：${msg.text || ""}`);
    return;
  }
  if (c === "idiom_play") {
    log(`座位${msg.seat} 接龙：${msg.text}${msg.auto ? "（机器人）" : ""}`);
    return;
  }
  if (c === "idiom_invalid") {
    log(`座位${msg.seat} 提交无效：${msg.text}（${msg.reason || "invalid"}）`);
    return;
  }
  if (c === "idiom_bot_thinking") {
    log(`座位${msg.seat} 机器人思考中...`);
    return;
  }
  if (c === "idiom_bot_retry") {
    log(`座位${msg.seat} 机器人重试第${msg.retry}次`);
    return;
  }
  if (c === "idiom_bot_result") {
    log(`座位${msg.seat} 机器人应答来源：${msg.source || "unknown"}`);
    return;
  }
  if (c === "idiom_out") {
    log(`座位${msg.seat} 淘汰：${msg.text || ""}`);
    return;
  }
  if (c === "challenge_result") {
    revealTableStack(msg.revealed_cards, msg.honest);
    renderPlayStack(state.lastState);
    triggerGunEffect(msg.loser_seat, !!msg.revolver_killed);
    state.tableRevealExpireAt = Date.now() + 5000;
    state.lastChallengeMeta = msg.honest
      ? `开牌结果：座位${msg.challenged_seat} 说真话（牌面：${(msg.revealed_cards || []).join(" ") || "?"}）。`
      : `开牌结果：座位${msg.challenged_seat} 吹牛（牌面：${(msg.revealed_cards || []).join(" ") || "?"}）。`;
    state.lastChallengeExpireAt = Date.now() + 5000;
    let extra = msg.text || "质疑结算";
    if (msg.revolver_killed != null) {
      extra += msg.revolver_killed ? "（中弹）" : "（空枪）";
    }
    log(extra + (msg.auto ? " · 自动" : ""));
    return;
  }
  if (c === "game_over") {
    clearTableStack();
    state.tableRevealExpireAt = 0;
    state.lastSettlement = msg.settlement || null;
    renderSettlement(state.lastSettlement);
    const why =
      msg.reason === "empty_hand"
        ? "[打空手牌]"
        : msg.reason === "last_standing"
          ? "[存活至终局]"
          : "";
    log(`游戏结束 ${why} 胜者座位：${msg.winner_seat} ${msg.text || ""}`);
    return;
  }
  if (c === "match_queued") {
    log(`匹配队列位置 ${msg.position}`);
    return;
  }
  if (c === "player_join" || c === "bot_join" || c === "player_left" || c === "player_kicked") {
    log(JSON.stringify(msg));
    return;
  }
  if (c === "left_room" || c === "kicked") {
    state.roomId = null;
    state.mySeat = null;
    state.lastState = null;
    state.hand = [];
    state.selected.clear();
    state.declarationConfirmed = false;
    state._playCtxKey = "";
    state.lastChallengeMeta = null;
    state.lastChallengeExpireAt = 0;
    state.tableRevealExpireAt = 0;
    state.lastSettlement = null;
    renderSettlement(null);
    clearTableStack();
    const hand = qs("#hand");
    if (hand) hand.innerHTML = "";
    const hb = qs("#handBar");
    if (hb) hb.classList.add("hidden");
    setActionReason("");
    setHandHint("当前不在出牌阶段。");
    const pileEl = qs("#pileInfo");
    if (pileEl) pileEl.textContent = "";
    const gunFx = qs("#gunFx");
    if (gunFx) gunFx.innerHTML = "";
    const flash = qs("#tableFlash");
    if (flash) flash.classList.remove("fire");
    const table = qs("#table");
    if (table) table.classList.remove("revolver-fire", "revolver-kill");
    if (state.gunFxTimer) {
      clearTimeout(state.gunFxTimer);
      state.gunFxTimer = 0;
    }
    const turnEl = qs("#turnStrip");
    if (turnEl) {
      turnEl.innerHTML =
        `<span class="status-kicker">大厅</span><div>你当前不在任何房间中。</div>`;
    }
    show("screen-lobby");
    log(c === "kicked" ? "你已被房主移出房间" : "已离开房间");
    return;
  }
  if (c === "play") {
    state.lastChallengeMeta = null;
    state.tableRevealExpireAt = 0;
    setTableStack(msg.seat, msg.count, false);
    renderPlayStack(state.lastState);
    return;
  }
}

function connect() {
  if (state.ws) {
    try {
      state.ws.close();
    } catch (_) {}
  }
  const url = wsUrl();
  const ws = new WebSocket(url);
  ws.binaryType = "arraybuffer";
  state.ws = ws;
  setConn(false, "连接中…");
  ws.onopen = () => {
    setConn(true, "已连接");
    log(`WebSocket 已连接`);
    send({ cmd: "login", name: state.name, password: state._loginPassword || "" });
  };
  ws.onclose = () => {
    setConn(false, "已断开");
    setLlmStatus(null);
    log("连接关闭");
  };
  ws.onerror = () => log("WebSocket 错误");
  ws.onmessage = (ev) => {
    try {
      const msg = decodePacketToObject(ev.data);
      handleMessage(msg);
    } catch (e) {
      log("消息解码失败（protobuf）");
    }
  };
}

window.addEventListener("load", () => {
  bindUi();
  setInterval(() => {
    const roomScreen = qs("#screen-room");
    const roomVisible = roomScreen ? !roomScreen.classList.contains("hidden") : false;
    if (state.lastState && roomVisible) {
      if (
        state.tableStack.cards.length &&
        state.tableRevealExpireAt > 0 &&
        Date.now() >= state.tableRevealExpireAt &&
        !(state.lastState && state.lastState.last_play)
      ) {
        clearTableStack();
        state.tableRevealExpireAt = 0;
        renderPlayStack(state.lastState);
      }
      updateTurnStrip(state.lastState);
    }
  }, 1000);
});
