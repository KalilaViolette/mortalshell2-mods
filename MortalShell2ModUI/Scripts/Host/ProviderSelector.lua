-- MortalShell2ModUI Host.ProviderSelector
-- Host-owned provider selection for the one-window/many-mods menu. Selection is intentionally
-- allowed only while the shared menu is closed/idle so no consumer session is torn out from under
-- another consumer. A future in-menu directory can build on this service without changing the
-- primitive registry contract.

local M = {}

function M.Bind(registry, menu_service, options)
    options = type(options) == "table" and options or {}
    if type(registry) ~= "table" or type(registry.SetMenuActiveConsumerRequest) ~= "function" then
        return nil, "Host.ProviderSelector requires Host.Registry"
    end
    if type(menu_service) ~= "table" or type(menu_service.Providers) ~= "function" then
        return nil, "Host.ProviderSelector requires Host.MenuService"
    end
    local log = type(options.log) == "function" and options.log or function() end
    local host_epoch = type(options.host_epoch) == "function" and options.host_epoch or function() return "" end
    local self = { cycle_count = 0 }

    local function menu_closed()
        if type(registry.ReadMenuSessionState) ~= "function" then return true end
        local session = registry.ReadMenuSessionState()
        if type(session) ~= "table" then return true end
        local state = tostring(session.state or "idle")
        return state == "idle" or state == "closed"
    end

    local function providers()
        local list = menu_service.Providers()
        return type(list) == "table" and list or {}
    end

    local function selected_index(list)
        local selected = type(menu_service.Selected) == "function" and menu_service.Selected() or nil
        local consumer = type(selected) == "table" and tostring(selected.consumer or "") or ""
        for index, provider in ipairs(list) do
            if tostring(provider.consumer or "") == consumer then return index end
        end
        return #list > 0 and 1 or 0
    end

    function self.State()
        local list = providers()
        local index = selected_index(list)
        local provider = index > 0 and list[index] or nil
        return {
            count = #list,
            index = index,
            consumer = provider ~= nil and tostring(provider.consumer or "") or "",
            display = provider ~= nil and tostring(type(provider.fields) == "table" and provider.fields.display or provider.consumer or "") or "",
            menuClosed = menu_closed(),
            cycleCount = self.cycle_count,
        }
    end

    function self.Cycle(direction)
        if not menu_closed() then return false, "menu-active" end
        local list = providers()
        if #list <= 1 then return false, #list == 0 and "no-providers" or "single-provider" end
        direction = tonumber(direction) or 1
        direction = direction < 0 and -1 or 1
        local index = selected_index(list)
        if index <= 0 then index = 1 end
        local next_index = ((index - 1 + direction) % #list) + 1
        local target = list[next_index]
        local ok, set_err = registry.SetMenuActiveConsumerRequest(tostring(target.consumer or ""))
        if not ok then return false, set_err end
        if type(registry.Scan) == "function" and type(menu_service.Reconcile) == "function" then
            local entries = registry.Scan()
            pcall(menu_service.Reconcile, entries or {}, tostring(host_epoch() or ""))
        end
        self.cycle_count = self.cycle_count + 1
        log("provider selector switched index=" .. tostring(next_index) .. "/" .. tostring(#list)
            .. " consumer=" .. tostring(target.consumer or "")
            .. " display=" .. tostring(type(target.fields) == "table" and target.fields.display or target.consumer or ""))
        return true, target
    end

    return self
end

return M
