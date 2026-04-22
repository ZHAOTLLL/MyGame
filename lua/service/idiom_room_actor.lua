local logic = require "service.idiom_room_logic"

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
    return
  end
  if msg.cmd == "disconnect" then
    logic.client_handle(cid, { cmd = "disconnect" })
    return
  end
  logic.client_handle(cid, msg)
end
