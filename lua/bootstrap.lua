-- Skynet 风格引导：单 VM 内按服务模块路由（轻量实现）
local lobby = require "service.lobby"

function dispatch(conn_id, msg)
  lobby.handle(conn_id, msg)
end

function tick()
  lobby.tick()
end
