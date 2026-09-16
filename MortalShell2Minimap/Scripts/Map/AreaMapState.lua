-- Resolves whether the current gameplay area has a usable native 2D map.
-- Exact WBP_MGT_WorldMap_C:HasAreaMap() answers remain authoritative when that
-- menu widget is resident. During ordinary closed-map gameplay, fall back to
-- the same BP_WorldMapSettings_2D world bounds used by the retained renderer.
-- v0.9.4 also watches the already-read primitive player pose for inside/outside
-- bounds crossings. Only a crossing invokes the existing resolver; there is no
-- recurring UObject scan, reflected poller, or retained callback wrapper.

local Factory = {}

function Factory.New(ctx)
    local state = assert(ctx.State, "Map.AreaMapState requires State")
    local Config = assert(ctx.Config, "Map.AreaMapState requires Config")
    local Object = assert(ctx.Object, "Map.AreaMapState requires Core.Object")
    local MapScale = assert(ctx.MapScale, "Map.AreaMapState requires Map.Scale")
    local Renderer = assert(ctx.Renderer, "Map.AreaMapState requires Map.NativeWidget")
    local WorkBudget = assert(ctx.WorkBudget, "Map.AreaMapState requires Runtime.WorkBudget")
    local global_runtime = assert(ctx.GlobalRuntime,
        "Map.AreaMapState requires GlobalRuntime")
    local instance_generation = assert(ctx.InstanceGeneration,
        "Map.AreaMapState requires InstanceGeneration")
    local debug_log = assert(ctx.DebugLog, "Map.AreaMapState requires DebugLog")
    local log = assert(ctx.Log, "Map.AreaMapState requires Log")
    local Perf = type(ctx.Perf) == "table" and ctx.Perf
        or { Begin = function() return nil end, End = function() end, Count = function() end }
    local runtime = {}
    local refresh_generation = 0

    local function current()
        return global_runtime.generation == instance_generation
            and not state.world_quarantined and state.world_ready
    end

    local function publish(value, reason, metadata)
        if type(value) ~= "boolean" then return false end
        metadata = type(metadata) == "table" and metadata or {}
        local changed = state.area_map_available ~= value
        state.area_map_available = value
        state.area_map_reason = tostring(reason or "unspecified")
        state.area_map_source = tostring(metadata.source or state.area_map_source or "unknown")
        if metadata.area_id ~= nil then state.area_map_area_id = tostring(metadata.area_id) end
        if tonumber(metadata.pan_x) ~= nil then state.area_map_pan_x = tonumber(metadata.pan_x) end
        if tonumber(metadata.pan_y) ~= nil then state.area_map_pan_y = tonumber(metadata.pan_y) end
        if tonumber(metadata.world_x) ~= nil then state.area_map_world_x = tonumber(metadata.world_x) end
        if tonumber(metadata.world_y) ~= nil then state.area_map_world_y = tonumber(metadata.world_y) end
        if tonumber(metadata.world_z) ~= nil then state.area_map_world_z = tonumber(metadata.world_z) end

        -- A HasAreaMap post-hook may be the source. Publish its primitive answer
        -- immediately, but defer mod-owned UMG writes until outside that hook.
        if changed then
            log(string.format(
                "Area map available=%s source=%s reason=%s area=%s world=(%s,%s,%s) pan=(%s,%s)",
                tostring(value), tostring(state.area_map_source), state.area_map_reason,
                tostring(state.area_map_area_id or "unknown"),
                tostring(state.area_map_world_x or "unknown"),
                tostring(state.area_map_world_y or "unknown"),
                tostring(state.area_map_world_z or "unknown"),
                tostring(state.area_map_pan_x or "unknown"),
                tostring(state.area_map_pan_y or "unknown")))
            local expected = value
            WorkBudget.Schedule(0, function()
                if current() and state.area_map_available == expected then
                    Renderer.SetAreaMapAvailable(expected, state.area_map_reason)
                end
            end, "areamap.confirm")
        end
        return true
    end

    local function retained_handler()
        local controller = Object.Unwrap(state.controller)
        if not Object.Valid(controller) then return nil end
        local handler = Object.Unwrap(Object.Property(controller, "World Map Handler"))
        return Object.Valid(handler) and handler or nil
    end

    local function current_area_id()
        local handler = retained_handler()
        if handler == nil then return state.area_map_area_id end
        local value = Object.Property(handler, "CurrentAreaID")
        return Object.Tag(value) or state.area_map_area_id
    end

    local function current_player_location()
        -- This path runs only on bounded lifecycle/UpdateAreaID/crossing work, so
        -- prefer a fresh read from the retained actor. Cached pose coordinates can
        -- still belong to the previous area for a short teleport/streaming window.
        local player = Object.Unwrap(state.player)
        local location = Object.ActorLocation(player)
        if location ~= nil then
            return tonumber(location.x), tonumber(location.y), tonumber(location.z)
        end

        local controller = Object.Unwrap(state.controller)
        if Object.Valid(controller) then
            local pawn = nil
            pcall(function() pawn = Object.Unwrap(controller:GetPawn()) end)
            location = Object.ActorLocation(pawn)
            if location ~= nil then
                return tonumber(location.x), tonumber(location.y), tonumber(location.z)
            end
        end

        local world_x, world_y, world_z = tonumber(state.player_world_x),
            tonumber(state.player_world_y), tonumber(state.player_world_z)
        if world_x ~= nil and world_y ~= nil then return world_x, world_y, world_z end
        return nil, nil, nil
    end

    local function remember_exact(value, reason)
        if type(value) ~= "boolean" then return end
        state.area_map_exact_value = value
        state.area_map_exact_reason = tostring(reason or "native-HasAreaMap")
    end

    local function exact_has_area_map()
        if type(FindFirstOf) ~= "function" then return nil end
        local token = Perf.Begin()
        local ok_find, widget = pcall(FindFirstOf, "WBP_MGT_WorldMap_C")
        Perf.End("native.findfirst", token)
        widget = Object.Unwrap(ok_find and widget or nil)
        if not Object.Valid(widget) then return nil end

        -- HasAreaMap dereferences CachedMapHandler. Do not invoke it during the
        -- construction window before that dependency has been cached.
        local handler = Object.Unwrap(Object.Property(widget, "CachedMapHandler"))
        if not Object.Valid(handler) then return nil end
        local ok_call, result = pcall(widget.HasAreaMap, widget)
        local value = nil
        if ok_call then value = Object.AsBoolean(result) end
        if type(value) == "boolean" then return value end
        return nil
    end

    local function bounds_fallback(reason, world_x, world_y, world_z)
        if world_x == nil or world_y == nil then
            world_x, world_y, world_z = current_player_location()
        end
        if world_x == nil or world_y == nil then return false end
        local inside, pan_x, pan_y = MapScale.WorldInsideNativeBounds(world_x, world_y)
        if type(inside) ~= "boolean" then return false end
        state.area_map_bounds_inside = inside
        local area_id = current_area_id()
        return publish(inside, tostring(reason or "lifecycle") .. ":native-bounds", {
            source = "native-bounds",
            area_id = area_id,
            world_x = world_x,
            world_y = world_y,
            world_z = world_z,
            pan_x = pan_x,
            pan_y = pan_y,
        })
    end

    local function resolve_at_pose(reason, world_x, world_y, world_z)
        if not current() then return false end
        local exact = exact_has_area_map()
        if type(exact) == "boolean" then
            remember_exact(exact, tostring(reason or "pose") .. ":HasAreaMap-query")
            local _, pan_x, pan_y = MapScale.WorldInsideNativeBounds(world_x, world_y)
            return publish(exact, tostring(reason or "pose") .. ":HasAreaMap-query", {
                source = "native-HasAreaMap",
                area_id = current_area_id(),
                world_x = world_x,
                world_y = world_y,
                world_z = world_z,
                pan_x = pan_x,
                pan_y = pan_y,
            })
        end
        return bounds_fallback(reason, world_x, world_y, world_z)
    end

    function runtime.ObserveResult(value, reason)
        local exact = Object.AsBoolean(value)
        remember_exact(exact, reason or "HasAreaMap-hook")
        return publish(exact, reason or "HasAreaMap-hook", {
            source = "native-HasAreaMap",
        })
    end

    function runtime.Refresh(reason)
        if not current() then return false end
        local exact = exact_has_area_map()
        if type(exact) == "boolean" then
            remember_exact(exact, tostring(reason or "lifecycle") .. ":HasAreaMap-query")
            return publish(exact, tostring(reason or "lifecycle") .. ":HasAreaMap-query", {
                source = "native-HasAreaMap",
                area_id = current_area_id(),
            })
        end
        return bounds_fallback(reason)
    end

    function runtime.ObservePose(world_x, world_y, world_z)
        if not current() then return false end
        world_x, world_y, world_z = tonumber(world_x), tonumber(world_y), tonumber(world_z)
        if world_x == nil or world_y == nil then return false end
        local inside, pan_x, pan_y = MapScale.WorldInsideNativeBounds(world_x, world_y)
        if type(inside) ~= "boolean" then return false end
        local previous = state.area_map_bounds_inside
        state.area_map_bounds_inside = inside
        if previous == nil or previous == inside then return false end

        state.area_map_bounds_crossings = math.max(0,
            math.floor(tonumber(state.area_map_bounds_crossings) or 0)) + 1
        state.area_map_last_crossing = tostring(previous) .. "->" .. tostring(inside)
        log(string.format(
            "Native map bounds crossing count=%d previous=%s current=%s world=(%.3f,%.3f,%s) pan=(%.6f,%.6f) priorAvailable=%s priorSource=%s area=%s",
            state.area_map_bounds_crossings, tostring(previous), tostring(inside),
            world_x, world_y, tostring(world_z or "unknown"), pan_x, pan_y,
            tostring(state.area_map_available), tostring(state.area_map_source),
            tostring(state.area_map_area_id or "unknown")))

        -- The crossing itself is primitive-only. Only here do we invoke the
        -- existing bounded resolver so a resident native HasAreaMap answer can
        -- still outrank the geometry fallback.
        return resolve_at_pose("pose-bounds-crossing", world_x, world_y, world_z)
    end

    function runtime.ScheduleRefresh(reason)
        refresh_generation = refresh_generation + 1
        local token = refresh_generation
        for _, delay_ms in ipairs({ 150, 500, 1200, 2500, 5000 }) do
            WorkBudget.Schedule(delay_ms, function()
                if token ~= refresh_generation or not current() then return end
                local attempt_reason = tostring(reason or "lifecycle")
                    .. ":" .. tostring(delay_ms) .. "ms"
                if runtime.Refresh(attempt_reason) then
                    refresh_generation = refresh_generation + 1
                elseif delay_ms == 5000 then
                    log("Area map unresolved; exact widget and native-bounds fallback unavailable reason="
                        .. attempt_reason)
                end
            end, "areamap.refresh")
        end
    end

    function runtime.EmitSummary(reason)
        state.area_map_diag_sequence = math.max(0,
            math.floor(tonumber(state.area_map_diag_sequence) or 0)) + 1
        local world_x, world_y, world_z = tonumber(state.player_world_x),
            tonumber(state.player_world_y), tonumber(state.player_world_z)
        local inside, pan_x, pan_y = MapScale.WorldInsideNativeBounds(world_x, world_y)
        local half = MapScale.WORLD_SPAN_UNITS / 2.0
        local x_min, x_max = MapScale.WORLD_ORIGIN_X - half, MapScale.WORLD_ORIGIN_X + half
        local y_min, y_max = MapScale.WORLD_ORIGIN_Y - half, MapScale.WORLD_ORIGIN_Y + half
        local mode = Config.TransparentNoMapBackground ~= false and "Transparent" or "Cloud"
        log(string.format(
            "AreaMap diagnostic seq=%d reason=%s generation=%d lifecycleEpoch=%d schedulerGeneration=%d worldReady=%s quarantined=%s built=%s mode=%s available=%s source=%s resolverReason=%s area=%s player=(%s,%s,%s) currentInside=%s currentPan=(%s,%s) classifiedWorld=(%s,%s,%s) classifiedPan=(%s,%s) boundsInside=%s crossings=%d lastCrossing=%s exactValue=%s exactReason=%s refreshGeneration=%d nativeBoundsX=(%.3f,%.3f) nativeBoundsY=(%.3f,%.3f)",
            state.area_map_diag_sequence, tostring(reason or "manual"),
            instance_generation, tonumber(state.lifecycle_epoch) or 0,
            tonumber(state.scheduler_generation) or 0, tostring(state.world_ready),
            tostring(state.world_quarantined), tostring(state.built), mode,
            tostring(state.area_map_available), tostring(state.area_map_source),
            tostring(state.area_map_reason), tostring(state.area_map_area_id or "unknown"),
            tostring(world_x or "unknown"), tostring(world_y or "unknown"),
            tostring(world_z or "unknown"), tostring(inside),
            tostring(pan_x or "unknown"), tostring(pan_y or "unknown"),
            tostring(state.area_map_world_x or "unknown"),
            tostring(state.area_map_world_y or "unknown"),
            tostring(state.area_map_world_z or "unknown"),
            tostring(state.area_map_pan_x or "unknown"),
            tostring(state.area_map_pan_y or "unknown"),
            tostring(state.area_map_bounds_inside),
            tonumber(state.area_map_bounds_crossings) or 0,
            tostring(state.area_map_last_crossing or "unobserved"),
            tostring(state.area_map_exact_value),
            tostring(state.area_map_exact_reason or "unobserved"),
            refresh_generation, x_min, x_max, y_min, y_max))
        return true
    end

    function runtime.OnLoadMapPre()
        refresh_generation = refresh_generation + 1
        -- LoadMap PRE is a strict no-UObject boundary. Reset only primitive
        -- state here; renderer/world references are dropped by their owners.
        state.area_map_available = nil
        state.area_map_reason = "load-map-pre"
        state.area_map_source = "unobserved"
        state.area_map_area_id = nil
        state.area_map_pan_x = nil
        state.area_map_pan_y = nil
        state.area_map_world_x = nil
        state.area_map_world_y = nil
        state.area_map_world_z = nil
        state.area_map_bounds_inside = nil
        state.area_map_bounds_crossings = 0
        state.area_map_last_crossing = "load-map-pre"
        state.area_map_exact_value = nil
        state.area_map_exact_reason = "load-map-pre"
    end

    function runtime.OnWorldReleased(reason)
        debug_log("Area-map observation scheduled reason=" .. tostring(reason))
        runtime.ScheduleRefresh(reason or "world-released")
    end

    return runtime
end

return Factory
