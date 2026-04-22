local pool = require "service.liar_agent_pool"

function handle(msg)
  if msg.__init then
    pool.init(msg)
    return
  end
  pool.handle(msg)
end
