-- MortalShell2ModUI Runtime.NativeMenuGate
-- Primitive-only native-menu lifecycle state. The host owns Unreal hooks and
-- publishes snapshots; consumers only read the resulting primitive metadata.
-- Hook callbacks must never retain, unwrap, validate, or dereference Context.
-- v0.68.4: the host may pass a primitive per-widget instance key (the widget's
-- address, read inside the live callback and never retained). Every
-- WBP_Menu_Game_Tab shares one UpdateOpenState hook, so nested menus (beacon ->
-- level up) must be tracked per instance: closing the child must not release
-- the still-open parent. Closing the last open instance still releases every
-- lease (the v0.68.2 authoritative semantics).

local NativeMenuGate = {}

local function text(value, fallback)
    local result = tostring(value or "")
    if result == "" then return tostring(fallback or "") end
    return result
end

function NativeMenuGate.New(options)
    options = type(options) == "table" and options or {}
    local publish = assert(options.publish, "Runtime.NativeMenuGate requires publish")
    local schedule = assert(options.schedule, "Runtime.NativeMenuGate requires schedule")
    local settle_ms = math.max(250, math.floor(tonumber(options.settle_ms) or 1000))

    local state = {
        status = "starting",
        active = false,
        reason = "startup",
        sequence = 0,
        token = 0,
        sources = {},
        instances = {},
    }
    local gate = {}

    -- Game menus nest at most a few deep (pause -> tab, beacon -> level up).
    -- A widget destroyed without UpdateOpenState(false) would otherwise hold the
    -- gate until the next world change; bounding the set evicts the oldest.
    local MAX_OPEN_INSTANCES = 4
    state.instance_order = 0

    local function instance_count()
        local n = 0
        for _ in pairs(state.instances) do n = n + 1 end
        return n
    end

    local function has_sources()
        for _, active in pairs(state.sources) do
            if active == true then return true end
        end
        return instance_count() > 0
    end

    local function snapshot()
        return {
            state = state.status,
            active = state.active == true,
            reason = state.reason,
            sequence = state.sequence,
            settleMs = settle_ms,
            openMenus = instance_count(),
            evictedMenus = state.evicted_instances or 0,
        }
    end

    local function emit(status, active, reason, force)
        status = text(status, "idle")
        active = active == true
        reason = text(reason, status)
        local open_menus = instance_count()
        if force == true or status ~= state.status or active ~= state.active
            or reason ~= state.reason or open_menus ~= state.published_open_menus then
            state.published_open_menus = open_menus
            state.status = status
            state.active = active
            state.reason = reason
            state.sequence = state.sequence + 1
            publish(snapshot())
        end
        return snapshot()
    end

    local function begin_settle(source, reason_prefix)
        if has_sources() then
            return emit("active", true, "close-retained:" .. source)
        end

        local token = state.token
        reason_prefix = text(reason_prefix, "close")
        emit("settling", true, reason_prefix .. "-settling:" .. source)
        local scheduled = schedule(settle_ms, function()
            if state.token ~= token or has_sources() then return end
            emit("idle", false, reason_prefix .. "-settled:" .. source)
        end)
        if scheduled ~= true then
            -- A failed timer must fail open to gameplay. Retaining a permanent
            -- quarantine is worse than losing the brief transition cushion.
            return emit("idle", false, reason_prefix .. "-schedule-failed-release:" .. source)
        end
        return snapshot()
    end

    function gate.Ready(reason)
        if state.active then return snapshot() end
        return emit("idle", false, text(reason, "hooks-ready"), true)
    end

    function gate.Open(source, lease_ms)
        source = text(source, "native-ui")
        state.token = state.token + 1
        state.sources[source] = true
        local token = state.token
        local opened = emit("active", true, "open:" .. source)

        -- Some game Blueprint "open" events have no balanced close on aborted
        -- interactions. Exact widget hooks therefore use a bounded safety lease.
        -- A renewed open invalidates the older lease through the token.
        lease_ms = math.max(0, math.floor(tonumber(lease_ms) or 0))
        if lease_ms > 0 then
            local scheduled = schedule(lease_ms, function()
                if state.token ~= token or state.sources[source] ~= true then return end
                state.token = state.token + 1
                state.sources[source] = nil
                begin_settle(source, "lease-expired")
            end)
            if scheduled ~= true and state.token == token and state.sources[source] == true then
                state.token = state.token + 1
                state.sources[source] = nil
                return emit("idle", false, "lease-schedule-failed-release:" .. source)
            end
        end
        return opened
    end

    function gate.Close(source, authoritative)
        source = text(source, "native-ui")
        state.token = state.token + 1
        if authoritative == true then
            state.sources = {}
            state.instances = {}
        else
            state.sources[source] = nil
        end
        return begin_settle(source, "close")
    end

    -- Per-widget open state (instance is a primitive key, e.g. the address).
    function gate.OpenInstance(source, instance)
        source = text(source, "native-ui")
        state.token = state.token + 1
        local key = source .. "#" .. text(instance, "?")
        if state.instances[key] == nil then
            state.instance_order = state.instance_order + 1
            state.instances[key] = state.instance_order
        end
        while instance_count() > MAX_OPEN_INSTANCES do
            local oldest_key, oldest = nil, math.huge
            for k, order in pairs(state.instances) do
                if order < oldest then oldest_key, oldest = k, order end
            end
            state.instances[oldest_key] = nil
            state.evicted_instances = (state.evicted_instances or 0) + 1
        end
        return emit("active", true, "open:" .. source)
    end

    function gate.CloseInstance(source, instance)
        source = text(source, "native-ui")
        state.token = state.token + 1
        state.instances[source .. "#" .. text(instance, "?")] = nil
        if instance_count() == 0 then
            -- Last open menu closed: release every lease too (v0.68.2 behavior).
            state.sources = {}
        end
        return begin_settle(source, "close")
    end

    function gate.Quarantine(reason)
        state.token = state.token + 1
        state.sources = {}
        state.instances = {}
        return emit("quarantined", true, text(reason, "world-transition"), true)
    end

    function gate.Release(reason)
        state.token = state.token + 1
        state.sources = {}
        state.instances = {}
        return emit("idle", false, text(reason, "world-ready"), true)
    end

    function gate.Degraded(reason)
        state.token = state.token + 1
        state.sources = {}
        state.instances = {}
        return emit("degraded", false, text(reason, "hooks-unavailable"), true)
    end

    function gate.Snapshot()
        return snapshot()
    end

    return gate
end

return NativeMenuGate
