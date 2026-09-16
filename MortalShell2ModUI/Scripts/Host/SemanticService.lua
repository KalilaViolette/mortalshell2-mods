-- MortalShell2ModUI Host.SemanticService
-- Bounded shared-menu native semantic hook owner.
-- Unlike the rejected process-lifetime InputTriggeredCallback mirror, this service registers
-- exactly one class hook only while the canonical shared-menu lease is active, exact-filters
-- callbacks to the current host-owned listener address before any pointer/controller work, and
-- unregisters on session close or LoadMap-pre. Native events are published through Host.Registry
-- so any active consumer Lua state can consume the same primitive route stream.

local M = {}

function M.Bind(registry, protocol, object_api, options)
    options = type(options) == "table" and options or {}
    if type(registry) ~= "table" or type(protocol) ~= "table" then
        return nil, "Host.SemanticService requires Host.Registry/Protocol"
    end
    if type(object_api) ~= "table" or type(object_api.Unwrap) ~= "function" or type(object_api.Address) ~= "function" then
        return nil, "Host.SemanticService requires ModUI.Object"
    end

    local RegisterHook = options.register_hook
    local UnregisterHook = options.unregister_hook
    local LoadAsset = options.load_asset
    local input_service = options.input_service
    local menu_service = options.menu_service
    local listener_address = options.listener_address
    local publish_state = options.publish_state or function() end
    local observe_event = options.observe_event
    local log = options.log or function() end
    local listener_asset = tostring(options.listener_asset or "/Game/Sparta/UI/Core/Navigation/WBP_InputListener")
    local hook_path = tostring(options.hook_path or "/Game/Sparta/UI/Core/Navigation/WBP_InputListener.WBP_InputListener_C:InputTriggeredCallback")

    if type(RegisterHook) ~= "function" or type(UnregisterHook) ~= "function" or type(LoadAsset) ~= "function" then
        return nil, "Host.SemanticService hook APIs unavailable"
    end
    if type(input_service) ~= "table" or type(input_service.PublishNativeInput) ~= "function" then
        return nil, "Host.SemanticService requires Host.InputService"
    end
    if type(menu_service) ~= "table" or type(menu_service.Selected) ~= "function" then
        return nil, "Host.SemanticService requires Host.MenuService"
    end
    if type(listener_address) ~= "function" then
        return nil, "Host.SemanticService requires listener address provider"
    end

    local state = {
        registered = false,
        pre = nil,
        post = nil,
        callback = nil,
        consumer = "",
        slot = -1,
        revision = 0,
        generation = 0,
        address = "",
        cycle = 0,
        world_quarantined = false,
        asset_loaded = false,
    }

    local function state_report(status, reason)
        local report = {
            status = tostring(status or (state.registered and "session-ready" or "session-idle")),
            registered = state.registered == true,
            consumer = state.consumer,
            slot = state.slot,
            revision = state.revision,
            generation = state.generation,
            address = state.address,
            cycle = state.cycle,
            reason = tostring(reason or ""),
        }
        pcall(publish_state, report.status, report)
        return report
    end

    local function clear_state()
        state.registered = false
        state.pre, state.post, state.callback = nil, nil, nil
        state.consumer, state.slot, state.revision = "", -1, 0
        state.generation, state.address = 0, ""
    end

    local function retire(reason)
        reason = tostring(reason or "session-idle")
        if not state.registered then
            state_report(state.world_quarantined and "quarantined" or "session-idle", reason)
            return true, "not-registered"
        end
        local ok, err = pcall(UnregisterHook, hook_path, state.pre, state.post)
        if not ok then
            state_report("degraded", "unregister-failed:" .. tostring(err))
            return false, tostring(err)
        end
        local prior_consumer, prior_generation, prior_cycle = state.consumer, state.generation, state.cycle
        clear_state()
        state_report(state.world_quarantined and "quarantined" or "session-idle", reason)
        log("shared-menu semantic hook retired consumer=" .. tostring(prior_consumer)
            .. " generation=" .. tostring(prior_generation) .. " cycle=" .. tostring(prior_cycle)
            .. " reason=" .. reason)
        return true, "retired"
    end

    local function arm(selected, generation, address)
        if state.world_quarantined then return false, "world-quarantined" end
        if not state.asset_loaded then
            local ok_load, loaded = pcall(LoadAsset, listener_asset)
            if not ok_load or loaded == nil then
                state_report("degraded", "listener-asset-load-failed")
                return false, "listener-asset-load-failed:" .. tostring(loaded)
            end
            state.asset_loaded = true
        end

        local consumer = tostring(selected.consumer or "")
        local slot = math.floor(tonumber(selected.slot) or -1)
        local revision = math.max(0, math.floor(tonumber(selected.revision) or 0))
        generation = math.max(0, math.floor(tonumber(generation) or 0))
        address = tostring(address or "")
        if consumer == "" or slot < 0 or generation <= 0 or not address:match("^%d+$") then
            return false, "invalid-session-identity"
        end

        -- Store the exact primitive address before registration. The callback performs no
        -- route/pointer/controller work unless Context resolves to this exact host listener.
        state.consumer, state.slot, state.revision = consumer, slot, revision
        state.generation, state.address = generation, address
        local callback = function(Context, Input)
            if not state.registered or state.world_quarantined then return end
            local context = object_api.Unwrap(Context)
            local callback_address = object_api.Address(context)
            if tonumber(callback_address) == nil
                or string.format("%.0f", tonumber(callback_address)) ~= tostring(state.address) then
                return
            end
            local input_number = tonumber(object_api.Unwrap(Input))
            if input_number == nil then return end
            if type(observe_event) == "function" then
                pcall(observe_event, string.format("%.0f", tonumber(callback_address)), input_number)
            end
            local ok_publish, publish_err = pcall(input_service.PublishNativeInput, callback_address, input_number)
            if not ok_publish then
                log("shared-menu semantic publish exception: " .. tostring(publish_err))
            end
        end

        local ok_register, pre, post = pcall(RegisterHook, hook_path, callback)
        if not ok_register or (pre == nil and post == nil) then
            clear_state()
            state_report("degraded", "register-failed:" .. tostring(pre))
            return false, "register-failed:" .. tostring(pre)
        end
        state.registered = true
        state.pre, state.post, state.callback = pre, post, callback
        state.cycle = state.cycle + 1
        state_report("session-ready", "armed")
        log("shared-menu semantic hook armed consumer=" .. consumer
            .. " generation=" .. tostring(generation) .. " address=" .. address
            .. " cycle=" .. tostring(state.cycle))
        return true, "armed"
    end

    local self = {}

    function self.Tick(menu_report)
        menu_report = type(menu_report) == "table" and menu_report or {}
        if state.world_quarantined then
            retire("world-quarantined")
            return state_report("quarantined", "world-quarantined")
        end
        local selected = menu_service.Selected()
        local lease = type(menu_report.lease) == "table" and menu_report.lease or {}
        local session_state = tostring(menu_report.state or "idle")
        local generation = math.max(0, math.floor(tonumber(menu_report.generation) or 0))
        local active_session = session_state == "opening" or session_state == "ready" or session_state == "closing"
        local lease_ok = tostring(lease.state or "idle") == "granted"
            and math.max(0, math.floor(tonumber(lease.generation) or 0)) == generation
        local address = tostring(listener_address() or "")
        local active = type(selected) == "table" and active_session and lease_ok
            and generation > 0 and address:match("^%d+$") ~= nil

        if not active then
            retire("session-" .. session_state)
            return state_report("session-idle", "session-" .. session_state)
        end

        local consumer = tostring(selected.consumer or "")
        local revision = math.max(0, math.floor(tonumber(selected.revision) or 0))
        if state.registered then
            -- Descriptor revisions are presentation/configuration metadata. Keep the one hook
            -- alive across a same-consumer/same-generation revision just like the visible shell.
            if state.consumer == consumer and state.generation == generation and state.address == address then
                state.slot = math.floor(tonumber(selected.slot) or state.slot)
                state.revision = revision
                return state_report("session-ready", "revision-continuity")
            end
            retire("session-identity-changed")
        end
        local ok, status = arm(selected, generation, address)
        return state_report(ok and "session-ready" or "degraded", status)
    end

    function self.WorldPreload(reason)
        state.world_quarantined = true
        local ok, status = retire(tostring(reason or "LoadMap-pre"))
        state_report("quarantined", tostring(reason or "LoadMap-pre"))
        return ok, status
    end

    function self.WorldPostload(reason)
        state.world_quarantined = false
        state_report("session-idle", tostring(reason or "LoadMap-post"))
        return true
    end

    function self.Retire(reason)
        return retire(reason)
    end

    function self.State()
        return state_report(state.registered and "session-ready"
            or (state.world_quarantined and "quarantined" or "session-idle"), "snapshot")
    end

    return self
end

return M
