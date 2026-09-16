-- Shared deferred-close policy. No Unreal references are retained by the ticket.
local M = { DELAY_MS = 225 }

function M.New(options)
    options = options or {}
    local pending, serial = nil, 0
    local self = {}
    function self.Pending() return pending ~= nil end
    function self.Cancel()
        serial = serial + 1
        pending = nil
    end
    function self.Request(generation, reason)
        if pending then return false, "already-closing" end
        serial = serial + 1
        local ticket = { serial = serial, generation = generation, reason = reason }
        pending = ticket
        local function finish()
            if pending ~= ticket or serial ~= ticket.serial then return end
            pending = nil
            if options.current_generation() ~= ticket.generation then return end
            options.finalize(ticket.reason, ticket.generation)
        end
        local ok, scheduled = pcall(options.schedule, M.DELAY_MS, finish)
        if not ok or scheduled ~= true then
            pending = nil
            return false, "scheduler-unavailable"
        end
        return true, "quarantined"
    end
    return self
end

return M
