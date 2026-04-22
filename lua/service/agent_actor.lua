-- Agent Actor：每连接一个 Lua VM。
local agent = require "service.agent"

function handle(msg)
  if msg.__init then
    agent.init(msg)
    return
  end
  if not msg.__from_conn then
    agent.on_system(msg)
    return
  end
  agent.on_client(msg)
end
