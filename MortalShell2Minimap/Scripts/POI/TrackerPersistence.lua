-- Bounded save-layer reader for player map pins. It is invoked once after a
-- world settles and returns primitive index/XY records only; it never retains
-- the save object, scans global objects, or constructs/spawns tracker actors.

local Factory = {}

function Factory.New(ctx)
    local state = assert(ctx.State, "POI.TrackerPersistence requires State")
    local Object = assert(ctx.Object, "POI.TrackerPersistence requires Core.Object")
    local log = assert(ctx.Log, "POI.TrackerPersistence requires Log")
    local poi = assert(state.poi,
        "POI.TrackerPersistence requires initialized POI state")
    local runtime = {}

    poi.tracker_persistence = poi.tracker_persistence or {
        attempts = 0,
        snapshots = 0,
        entries = 0,
        empty = 0,
        failures = 0,
        last_method = "none",
        last_out_success = "unknown",
        last_error = "none",
    }
    local metrics = poi.tracker_persistence

    local function bounded_max(handler)
        local value = math.floor(tonumber(Object.Number(handler, "MaxTrackers")) or 5)
        if value < 1 then value = 1 end
        if value > 32 then value = 32 end
        return value
    end

    local function save_data(handler)
        -- bSuccess is a non-const Blueprint out parameter. UE4SS counts it as
        -- one required Lua argument even though the object itself is the
        -- function return value. Primitive out parameters are populated into
        -- the named field of the supplied table.
        local out_success = {}
        local ok, first, second, third = pcall(function()
            return handler:GetMySaveData(out_success)
        end)
        if not ok then return nil, nil, "get-save-call-failed:" .. tostring(first) end
        local success = Object.AsBoolean(out_success.bSuccess)

        local candidates = { first, second, third }
        for index = 1, 3 do
            local candidate = Object.Unwrap(candidates[index])
            if Object.Valid(candidate) then
                local trackers, property_error = Object.Property(candidate, "Trackers")
                if property_error == nil then
                    return candidate, Object.Unwrap(trackers), nil, success
                end
            end
        end
        return nil, nil, success == false and "save-object-unsuccessful"
            or "save-object-unavailable", success
    end

    local function build_snapshot(handler, tracker_map, generation)
        if tracker_map == nil then return nil, "save-trackers-unavailable" end
        local records, count = {}, 0
        local maximum = bounded_max(handler)

        local function keep(raw_index, raw_location)
            local index = tonumber(Object.Unwrap(raw_index))
            local location = Object.Vector(raw_location)
            if index == nil or index ~= math.floor(index)
                or index < 0 or index >= maximum or location == nil then return end
            if records[index] == nil then count = count + 1 end
            records[index] = {
                index = index,
                actor_id = "saved-index:" .. tostring(index),
                x = location.x,
                y = location.y,
            }
        end

        local foreach_ok, foreach_error = pcall(function()
            tracker_map:ForEach(function(key, value) keep(key, value) end)
        end)
        local method = "ForEach"
        if not foreach_ok then
            method = "Contains+Find(index)"
            local answered = false
            for index = 0, maximum - 1 do
                local contains_ok, contains = pcall(function()
                    return Object.AsBoolean(tracker_map:Contains(index))
                end)
                if contains_ok and contains ~= nil then
                    answered = true
                    if contains == true then
                        local find_ok, value = pcall(function()
                            return Object.Unwrap(tracker_map:Find(index))
                        end)
                        if find_ok then keep(index, value) end
                    end
                end
            end
            if not answered then return nil, "save-map-unreadable:" .. tostring(foreach_error) end
        end

        return {
            generation = generation,
            records = records,
            count = count,
            read_method = "save." .. method,
        }, nil
    end

    function runtime.Snapshot(handler, generation)
        metrics.attempts = metrics.attempts + 1
        handler = Object.Unwrap(handler)
        if not Object.Valid(handler) then
            metrics.failures = metrics.failures + 1
            metrics.last_error = "handler-invalid"
            return nil, metrics.last_error
        end

        local started = os.clock()
        local _, tracker_map, save_error, out_success = save_data(handler)
        metrics.last_out_success = out_success == nil and "unknown"
            or tostring(out_success)
        if save_error ~= nil then
            metrics.failures = metrics.failures + 1
            metrics.last_error = save_error
            return nil, save_error
        end
        local snapshot, snapshot_error = build_snapshot(
            handler, tracker_map, tonumber(generation) or poi.generation)
        if snapshot == nil then
            metrics.failures = metrics.failures + 1
            metrics.last_error = tostring(snapshot_error)
            return nil, snapshot_error
        end

        metrics.snapshots = metrics.snapshots + 1
        metrics.entries = metrics.entries + snapshot.count
        if snapshot.count == 0 then metrics.empty = metrics.empty + 1 end
        metrics.last_method = snapshot.read_method
        metrics.last_error = "none"
        snapshot.read_cpu_ms = (os.clock() - started) * 1000.0
        return snapshot, nil
    end

    function runtime.EmitSummary(reason)
        log(string.format(
            "Tracker persistence summary reason=%s attempts=%d snapshots=%d entries=%d empty=%d failures=%d lastMethod=%s lastOutSuccess=%s lastError=%s oneShotPerWorld=true primitiveOnly=true",
            tostring(reason or "manual"), metrics.attempts, metrics.snapshots,
            metrics.entries, metrics.empty, metrics.failures,
            tostring(metrics.last_method), tostring(metrics.last_out_success),
            tostring(metrics.last_error)))
    end

    runtime.State = metrics
    return runtime
end

return Factory
