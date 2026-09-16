-- Owns tracker rehydration across startup, death, and travel. LoadTrackers is
-- captured after it finishes. A single settled-world save read recovers pins
-- when the game's load event happened before hook registration. Only primitive
-- coordinates cross quarantine or leave the persistence reader.

local Factory = {}

function Factory.New(ctx)
    local state = assert(ctx.State, "POI.TrackerLifecycle requires State")
    local Object = assert(ctx.Object, "POI.TrackerLifecycle requires Core.Object")
    local Registry = assert(ctx.Registry, "POI.TrackerLifecycle requires POI.Registry")
    local Persistence = assert(ctx.TrackerPersistence,
        "POI.TrackerLifecycle requires POI.TrackerPersistence")
    local WorkBudget = assert(ctx.WorkBudget,
        "POI.TrackerLifecycle requires Runtime.WorkBudget")
    local log = assert(ctx.Log, "POI.TrackerLifecycle requires Log")
    local poi = assert(state.poi, "POI.TrackerLifecycle requires initialized POI state")
    local runtime = {}

    poi.tracker_lifecycle = poi.tracker_lifecycle or {
        pending = nil,
        hook_mode = "unarmed",
        captures = 0,
        staged = 0,
        applied = 0,
        failures = 0,
        stale = 0,
        recovery_token = 0,
        recovery_armed = false,
        recovery_attempts = 0,
        recovery_applied = 0,
        recovery_empty = 0,
        recovery_skipped = 0,
        recovery_failures = 0,
        recovery_stale = 0,
    }
    local lifecycle = poi.tracker_lifecycle

    local function weak_values(values)
        return setmetatable(values or {}, { __mode = "v" })
    end

    local function apply(snapshot, disposition)
        if type(snapshot) ~= "table" or snapshot.generation ~= poi.generation then
            lifecycle.stale = lifecycle.stale + 1
            return false
        end
        local applied, err = Registry.ApplyTrackerSnapshot(snapshot, true)
        if not applied then
            lifecycle.failures = lifecycle.failures + 1
            log("Tracker lifecycle snapshot apply failed reason="
                .. tostring(snapshot.reason) .. " error=" .. tostring(err))
            return false
        end
        lifecycle.applied = lifecycle.applied + 1
        log(string.format(
            "Tracker lifecycle snapshot reason=%s generation=%d count=%d disposition=%s read=%s",
            tostring(snapshot.reason), snapshot.generation,
            math.max(0, math.floor(tonumber(snapshot.count) or 0)),
            tostring(disposition or "applied"),
            tostring(snapshot.read_method or "unknown")))
        return true
    end

    function runtime.Capture(handler, reason)
        poi.metrics.events_received = poi.metrics.events_received + 1
        handler = Object.Unwrap(handler)
        local snapshot, err = Registry.SnapshotTrackers(handler, false)
        if snapshot == nil then
            lifecycle.failures = lifecycle.failures + 1
            log("Tracker lifecycle capture failed reason=" .. tostring(reason)
                .. " error=" .. tostring(err))
            return false
        end
        lifecycle.captures = lifecycle.captures + 1
        snapshot.reason = tostring(reason or "load-trackers")
        if poi.quarantined then
            lifecycle.pending = snapshot
            lifecycle.staged = lifecycle.staged + 1
            log(string.format(
                "Tracker lifecycle snapshot reason=%s generation=%d count=%d disposition=staged read=%s",
                snapshot.reason, snapshot.generation, snapshot.count,
                tostring(snapshot.read_method or "unknown")))
            return true
        end
        Registry.BindHandler(handler, "load-trackers-hook-context")
        return apply(snapshot, "applied-live")
    end

    function runtime.DeferCapture(handler, reason)
        local generation = poi.generation
        local refs = weak_values({ handler = Object.Unwrap(handler) })
        return WorkBudget.Schedule(1, function()
            if poi.generation ~= generation then
                lifecycle.stale = lifecycle.stale + 1
                return
            end
            runtime.Capture(refs.handler, reason or "load-trackers-deferred")
        end, "tracker.defer-capture")
    end

    function runtime.SetHookMode(mode)
        lifecycle.hook_mode = tostring(mode or "unknown")
    end

    function runtime.ScheduleSettledRecovery(reason)
        if poi.quarantined or lifecycle.recovery_armed then return false end
        lifecycle.recovery_token = lifecycle.recovery_token + 1
        local token = lifecycle.recovery_token
        local generation = poi.generation
        lifecycle.recovery_armed = true
        local scheduled = WorkBudget.Schedule(500, function()
            if lifecycle.recovery_token ~= token then return end
            lifecycle.recovery_armed = false
            if poi.quarantined or poi.generation ~= generation then
                lifecycle.recovery_stale = lifecycle.recovery_stale + 1
                return
            end
            if math.max(0, tonumber(poi.tracker_count) or 0) > 0 then
                lifecycle.recovery_skipped = lifecycle.recovery_skipped + 1
                return
            end

            lifecycle.recovery_attempts = lifecycle.recovery_attempts + 1
            local handler = Registry.Handler()
            if handler == nil then handler = Registry.ResolveAndBindHandler() end
            local snapshot, err = Persistence.Snapshot(handler, generation)
            if snapshot == nil then
                lifecycle.recovery_failures = lifecycle.recovery_failures + 1
                log("Tracker settled recovery failed reason=" .. tostring(reason)
                    .. " error=" .. tostring(err))
                return
            end
            snapshot.reason = tostring(reason or "settled-save-recovery")
            if snapshot.count == 0 then
                lifecycle.recovery_empty = lifecycle.recovery_empty + 1
                log(string.format(
                    "Tracker settled recovery reason=%s generation=%d count=0 disposition=empty read=%s cpuMs=%.3f",
                    snapshot.reason, generation,
                    tostring(snapshot.read_method or "unknown"),
                    tonumber(snapshot.read_cpu_ms) or 0.0))
                return
            end
            local recovered, apply_error = Registry.ApplyTrackerSnapshot(snapshot, true)
            if not recovered then
                lifecycle.recovery_failures = lifecycle.recovery_failures + 1
                log("Tracker settled recovery apply failed reason="
                    .. snapshot.reason .. " error=" .. tostring(apply_error))
                return
            end
            lifecycle.recovery_applied = lifecycle.recovery_applied + 1
            log(string.format(
                "Tracker settled recovery reason=%s generation=%d count=%d disposition=applied read=%s cpuMs=%.3f",
                snapshot.reason, generation, snapshot.count,
                tostring(snapshot.read_method or "unknown"),
                tonumber(snapshot.read_cpu_ms) or 0.0))
        end, "tracker.settled-recovery")
        if not scheduled then lifecycle.recovery_armed = false end
        return scheduled == true
    end

    function runtime.OnLoadMapPre()
        lifecycle.pending = nil
        lifecycle.recovery_token = lifecycle.recovery_token + 1
        lifecycle.recovery_armed = false
    end

    function runtime.OnWorldReleased()
        local snapshot = lifecycle.pending
        lifecycle.pending = nil
        local applied = snapshot ~= nil and apply(snapshot, "applied-after-quarantine")
            or false
        runtime.ScheduleSettledRecovery("world-release-save")
        return applied
    end

    function runtime.EmitSummary(reason)
        log(string.format(
            "Tracker lifecycle summary reason=%s hookMode=%s pending=%s captures=%d staged=%d applied=%d failures=%d stale=%d recoveryArmed=%s recoveryAttempts=%d recoveryApplied=%d recoveryEmpty=%d recoverySkipped=%d recoveryFailures=%d recoveryStale=%d primitiveOnly=true",
            tostring(reason or "manual"), tostring(lifecycle.hook_mode),
            tostring(lifecycle.pending ~= nil), lifecycle.captures,
            lifecycle.staged, lifecycle.applied, lifecycle.failures,
            lifecycle.stale, tostring(lifecycle.recovery_armed),
            lifecycle.recovery_attempts, lifecycle.recovery_applied,
            lifecycle.recovery_empty, lifecycle.recovery_skipped,
            lifecycle.recovery_failures, lifecycle.recovery_stale))
        Persistence.EmitSummary(reason)
    end

    runtime.State = lifecycle
    return runtime
end

return Factory
