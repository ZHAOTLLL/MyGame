-- Lobby Actor：未绑定连接的入口 + 系统消息处理。
local lobby = require "service.lobby"

function handle(msg)
  if not msg.__from_conn then
    lobby.handle_system(msg)
    return
  end
  local cid = msg.__from_conn
  local payload = {}
  for k, v in pairs(msg) do
    if k ~= "__from_conn" then
      payload[k] = v
    end
  end
  lobby.handle_client(cid, payload)
end
