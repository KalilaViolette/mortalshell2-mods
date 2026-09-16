-- Class-level event adapters. AddMapObjective captures a new component while it
-- is synchronously valid, then retains primitives only. Objective state hooks
-- capture the context address before the game transition and apply the known
-- resulting boolean without reading the component after the transition.
-- Death-spoils retrieval retires its primitive record by owner address.
-- LoadTrackers alone captures its bounded five-entry result after completion.

local Factory = {}

function Factory.New(ctx)
    local state = assert(ctx.State, "POI.Hooks requires State")
    local Object = assert(ctx.Object, "POI.Hooks requires Core.Object")
    local Perf = type(ctx.Perf) == "table" and ctx.Perf
        or { Begin = function() return nil end, End = function() end, Count = function() end }
    local Registry = assert(ctx.Registry, "POI.Hooks requires POI.Registry")
    local TrackerLifecycle = assert(ctx.TrackerLifecycle,
        "POI.Hooks requires POI.TrackerLifecycle")
    local AreaMapState = assert(ctx.AreaMapState,
        "POI.Hooks requires Map.AreaMapState")
    local global_runtime = assert(ctx.GlobalRuntime, "POI.Hooks requires GlobalRuntime")
    local instance_generation = assert(ctx.InstanceGeneration, "POI.Hooks requires InstanceGeneration")
    local runtime = {}
    local poi = assert(state.poi, "POI.Hooks requires initialized POI state")

    local HANDLER = "/Game/Sparta/UI/World/Map/Blueprints/BPC_WorldMapHandler.BPC_WorldMapHandler_C"
    local OBJECTIVE = "/Game/Sparta/UI/World/Map/Blueprints/BPC_WorldMapObjective.BPC_WorldMapObjective_C"
    local MAP = "/Game/Sparta/UI/World/Map/Widgets/WBP_MGT_WorldMap.WBP_MGT_WorldMap_C"
    local DEATH_SPOILS = "/Game/Sparta/Core/Player/Ability/Death/BP_DeathSpoils.BP_DeathSpoils_C"
    local SPECS = {
        { label = "handler.AddMapObjective", path = HANDLER .. ":AddMapObjective", kind = "objective-add" },
        { label = "handler.AddMapTracker", path = HANDLER .. ":AddMapTracker", kind = "tracker-add" },
        { label = "handler.RemoveMapTracker", path = HANDLER .. ":RemoveMapTracker", kind = "tracker-remove" },
        { label = "handler.DestroyMapTracker", path = HANDLER .. ":DestroyMapTracker", kind = "tracker-remove" },
        { label = "handler.LoadTrackers", path = HANDLER .. ":LoadTrackers", kind = "tracker-load" },
        { label = "handler.SaveLoaded", path = HANDLER .. ":SaveLoaded", kind = "bootstrap-observe" },
        { label = "handler.UpdateAreaID", path = HANDLER .. ":UpdateAreaID", kind = "area-map-refresh" },
        { label = "map.HasAreaMap", path = MAP .. ":HasAreaMap", kind = "area-map-result" },
        { label = "objective.RevealObjective", path = OBJECTIVE .. ":RevealObjective", kind = "objective-state", updates = { revealed = true } },
        { label = "objective.CompleteObjective", path = OBJECTIVE .. ":CompleteObjective", kind = "objective-state", updates = { completed = true } },
        { label = "objective.UncompleteObjective", path = OBJECTIVE .. ":UncompleteObjective", kind = "objective-state", updates = { completed = false } },
        { label = "objective.ShowArea", path = OBJECTIVE .. ":ShowArea", kind = "objective-state", updates = { show_area = true } },
        { label = "objective.SaveLoaded", path = OBJECTIVE .. ":SaveLoaded", kind = "objective-refresh-post" },
        { label = "objective.SessionReset", path = OBJECTIVE .. ":SessionReset", kind = "objective-refresh-post" },
        {
            -- The exported OnRetrieved function is FUNC_Delegate: a signature,
            -- not executable pickup code. Observe the callable GiveGloom body
            -- while its actor is still alive, before native pickup/destruction.
            label = "deathSpoils.GiveGloom",
            path = DEATH_SPOILS .. ":GiveGloom",
            kind = "objective-owner-retire",
        },
        {
            label = "map.FilterToggle",
            path = MAP .. ":BndEvt__WBP_MGT_WorldMap_WBP_Map_Filters_K2Node_ComponentBoundEvent_4_OnFilterToggle__DelegateSignature",
            kind = "filter",
        },
    }

    local function stats(label)
        local value = poi.hook_stats[label]
        if value == nil then
            value = { fired = 0, quarantined = 0 }
            poi.hook_stats[label] = value
        end
        return value
    end

    local function callback(spec)
        return function(context, first, second)
            if global_runtime.generation ~= instance_generation then return end
            local hook_stats = stats(spec.label)
            hook_stats.fired = hook_stats.fired + 1
            if poi.quarantined then
                hook_stats.quarantined = hook_stats.quarantined + 1
                poi.metrics.events_quarantined = poi.metrics.events_quarantined + 1
                return
            end
            local started = os.clock()
            if spec.kind == "objective-add" then
                Registry.CaptureObjective(Object.Unwrap(first),
                    "hook:" .. spec.label)
            elseif spec.kind == "objective-state" then
                -- This is the pre-hook: context is valid now. Keep only its
                -- primitive address; never inspect it after the native call.
                Registry.ApplyObjectiveState(Object.Address(context),
                    spec.updates, "hook:" .. spec.label)
            elseif spec.kind == "objective-owner-retire" then
                Registry.RetireObjectiveByOwner(Object.Address(context),
                    "hook:" .. spec.label)
            elseif spec.kind == "bootstrap-observe" then
                -- World release/renderer readiness owns the single baseline
                -- scan. SaveLoaded can fire once per component and must not
                -- multiply that scan or restart it mid-slice.
                poi.metrics.events_received = poi.metrics.events_received + 1
            elseif spec.kind == "tracker-add" then
                Registry.QueueTracker("add", Object.Unwrap(first), second)
            elseif spec.kind == "tracker-remove" then
                Registry.QueueTracker("remove", nil, first)
            elseif spec.kind == "filter" then
                Registry.QueueFilter(Object.Tag(first), Object.AsBoolean(second))
            elseif spec.kind == "area-map-refresh" then
                AreaMapState.ScheduleRefresh("hook:" .. spec.label)
            end
            Registry.NoteHookCPU((os.clock() - started) * 1000.0)
        end
    end

    local function tracker_load_post_callback(spec)
        return function(context)
            if global_runtime.generation ~= instance_generation then return end
            local hook_stats = stats(spec.label)
            hook_stats.fired = hook_stats.fired + 1
            if poi.quarantined then
                hook_stats.quarantined = hook_stats.quarantined + 1
            end
            local started = os.clock()
            TrackerLifecycle.Capture(Object.Unwrap(context), "load-trackers-post")
            Registry.NoteHookCPU((os.clock() - started) * 1000.0)
        end
    end

    local function objective_refresh_post_callback(spec)
        return function(context)
            if global_runtime.generation ~= instance_generation then return end
            local hook_stats = stats(spec.label)
            hook_stats.fired = hook_stats.fired + 1
            if poi.quarantined then
                hook_stats.quarantined = hook_stats.quarantined + 1
                poi.metrics.events_quarantined = poi.metrics.events_quarantined + 1
                return
            end
            local started = os.clock()
            -- SaveLoaded/SessionReset do not destroy the component. Reading its
            -- final state here updates a single record without an array scan.
            Registry.CaptureObjective(Object.Unwrap(context),
                "post:" .. spec.label)
            Registry.NoteHookCPU((os.clock() - started) * 1000.0)
        end
    end

    local function area_map_result_post_callback(spec)
        return function(context, result)
            if global_runtime.generation ~= instance_generation then return end
            local hook_stats = stats(spec.label)
            hook_stats.fired = hook_stats.fired + 1
            if poi.quarantined then
                hook_stats.quarantined = hook_stats.quarantined + 1
                poi.metrics.events_quarantined = poi.metrics.events_quarantined + 1
                return
            end
            local started = os.clock()
            AreaMapState.ObserveResult(result, "post:" .. spec.label)
            Registry.NoteHookCPU((os.clock() - started) * 1000.0)
        end
    end

    local function tracker_load_deferred_callback(spec)
        return function(context)
            if global_runtime.generation ~= instance_generation then return end
            local hook_stats = stats(spec.label)
            hook_stats.fired = hook_stats.fired + 1
            if poi.quarantined then
                hook_stats.quarantined = hook_stats.quarantined + 1
            end
            local started = os.clock()
            TrackerLifecycle.DeferCapture(
                Object.Unwrap(context), "load-trackers-deferred-pre")
            Registry.NoteHookCPU((os.clock() - started) * 1000.0)
        end
    end

    -- Times a hook callback as hook.poi.<label>. The section name is built once here,
    -- not per event.
    local function timed(spec, fn)
        local section = "hook.poi." .. tostring(spec.label)
        return function(...)
            local token = Perf.Begin()
            fn(...)
            Perf.End(section, token)
        end
    end

    function runtime.Arm()
        local armed = 0
        poi.hook_target_count = #SPECS
        poi.metrics.hook_arm_attempts = poi.metrics.hook_arm_attempts + 1
        for _, spec in ipairs(SPECS) do
            if poi.hooks_armed[spec.path] == nil then
                local ok, pre_id, post_id
                if spec.kind == "tracker-load" then
                    ok, pre_id, post_id = pcall(RegisterHook, spec.path,
                        function() end, timed(spec, tracker_load_post_callback(spec)))
                    if ok then
                        TrackerLifecycle.SetHookMode("post-hook")
                    else
                        ok, pre_id, post_id = pcall(RegisterHook, spec.path,
                            timed(spec, tracker_load_deferred_callback(spec)))
                        if ok then TrackerLifecycle.SetHookMode("deferred-pre-fallback") end
                    end
                elseif spec.kind == "objective-refresh-post" then
                    ok, pre_id, post_id = pcall(RegisterHook, spec.path,
                        function() end, timed(spec, objective_refresh_post_callback(spec)))
                elseif spec.kind == "area-map-result" then
                    ok, pre_id, post_id = pcall(RegisterHook, spec.path,
                        function() end, timed(spec, area_map_result_post_callback(spec)))
                else
                    ok, pre_id, post_id = pcall(
                        RegisterHook, spec.path, timed(spec, callback(spec)))
                end
                if ok then
                    poi.hooks_armed[spec.path] = { pre = pre_id, post = post_id }
                else
                    poi.metrics.hook_arm_failures = poi.metrics.hook_arm_failures + 1
                end
            end
            if poi.hooks_armed[spec.path] ~= nil then armed = armed + 1 end
        end
        return armed, #SPECS
    end

    function runtime.ArmedCount()
        local count = 0
        for _, spec in ipairs(SPECS) do
            if poi.hooks_armed[spec.path] ~= nil then count = count + 1 end
        end
        return count, #SPECS
    end

    return runtime
end

return Factory
