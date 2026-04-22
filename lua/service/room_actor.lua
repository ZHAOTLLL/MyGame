-- 每房间一个 Lua VM；业务在 room_logic。
local logic = require "service.room_logic"

function handle(msg)
  if msg.__init then
    logic.init(msg)
    return
  end
  if msg.cmd == "__tick" then
    logic.tick()
    return
  end
  local cid = msg.__from_conn
  if not cid then
    if logic.on_system then
      logic.on_system(msg)
    end
    return
  end
  if msg.cmd == "disconnect" then
    logic.disconnect(cid)
    return
  end
  logic.client_handle(cid, msg)
end
