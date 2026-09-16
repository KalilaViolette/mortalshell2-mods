-- Primitive-indexed invisible objective/tracker/filter registry. No UMG work.

local Factory = {}

function Factory.New(ctx)
    local state = assert(ctx.State, "POI.Registry requires State")
    local Object = assert(ctx.Object, "POI.Registry requires Core.Object")
    local Reader = assert(ctx.StateReader, "POI.Registry requires POI.StateReader")
    local WorkBudget = assert(ctx.WorkBudget, "POI.Registry requires Runtime.WorkBudget")
    local IconResolver = assert(ctx.IconResolver, "POI.Registry requires POI.IconResolver")
    local TrackerTelemetry = assert(ctx.TrackerTelemetry, "POI.Registry requires POI.TrackerTelemetry")
    local TrackerPool = assert(ctx.TrackerPool, "POI.Registry requires Overlay.TrackerPool")
    local ObjectivePool = assert(ctx.ObjectivePool,
        "POI.Registry requires Overlay.ObjectivePool")
    local log = assert(ctx.Log, "POI.Registry requires Log")
    local runtime = {}

    local function weak_values(values)
        return setmetatable(values or {}, { __mode = "v" })
    end

    local function new_counts()
        return {
            enabled = 0,
            located = 0,
            save_loaded = 0,
            visible = 0,
            revealed = 0,
            completed = 0,
        }
    end

    local function initialize()
        if type(state.poi) == "table" then return state.poi end
        state.poi = {
            generation = 0,
            quarantined = true,
            ready = false,
            refs = weak_values(),
            handler_id = nil,
            handler_resolution = "none",
            records = {},
            record_count = 0,
            counts = new_counts(),
            trackers = {},
            tracker_count = 0,
            filters = {},
            filter_count = 0,
            work_queue = {},
            work_head = 1,
            work_tail = 0,
            work_membership = {},
            work_armed = false,
            audit = nil,
            audit_requested = false,
            audit_sequence = 0,
            audit_force_full = false,
            audit_previous_handler_id = nil,
            begin_armed = false,
            begin_token = 0,
            resolve_attempts = 0,
            hooks_armed = {},
            hook_target_count = 0,
            hook_stats = {},
            ready_logged_generation = -1,
            metrics = {
                world_resets = 0,
                events_received = 0,
                events_quarantined = 0,
                events_coalesced = 0,
                invalid_events = 0,
                queue_high_water = 0,
                work_slices = 0,
                work_items = 0,
                work_cpu_ms = 0.0,
                max_work_slice_ms = 0.0,
                audits_completed = 0,
                audit_cpu_ms = 0.0,
                max_audit_slice_ms = 0.0,
                last_audit_total = 0,
                last_audit_valid = 0,
                last_audit_unique = 0,
                last_audit_invalid = 0,
                last_audit_duplicates = 0,
                last_audit_copy_ms = 0.0,
                stale_retired = 0,
                full_reads = 0,
                state_reads = 0,
                refresh_failures = 0,
                tracker_reconciles = 0,
                tracker_empty_reconciles_suppressed = 0,
                filter_reconciles = 0,
                hook_cpu_ms = 0.0,
                hook_arm_attempts = 0,
                hook_arm_failures = 0,
                objective_transition_signals = 0,
                audit_interruptions = 0,
                settled_audits = 0,
                live_objective_adds = 0,
                objective_state_signals = 0,
                objective_state_misses = 0,
                objective_owner_retires = 0,
                objective_owner_retire_misses = 0,
            },
        }
        return state.poi
    end

    local poi = initialize()

    local function count_truth(value)
        return value == true and 1 or 0
    end

    local function apply_counts(record, direction)
        local counts = poi.counts
        counts.enabled = counts.enabled + direction * count_truth(record.enabled)
        counts.located = counts.located + direction * (record.world_x ~= nil and 1 or 0)
        counts.save_loaded = counts.save_loaded + direction * count_truth(record.save_loaded)
        counts.visible = counts.visible + direction * count_truth(record.visible)
        counts.revealed = counts.revealed + direction * count_truth(record.revealed)
        counts.completed = counts.completed + direction * count_truth(record.completed)
    end

    local function retire(id)
        local record = poi.records[id]
        if record == nil then return false end
        apply_counts(record, -1)
        poi.records[id] = nil
        poi.record_count = math.max(0, poi.record_count - 1)
        return true
    end

    local process_work

    local function queue_depth()
        if poi.work_tail < poi.work_head then return 0 end
        return poi.work_tail - poi.work_head + 1
    end

    local function arm_work()
        if poi.work_armed or poi.quarantined or queue_depth() == 0 then return end
        poi.work_armed = true
        local generation = poi.generation
        if not WorkBudget.Schedule(50, function()
            if not poi.quarantined and poi.generation == generation then process_work() end
        end, "registry.work") then
            poi.work_armed = false
        end
    end

    local function enqueue(item)
        if poi.quarantined then
            poi.metrics.events_quarantined = poi.metrics.events_quarantined + 1
            return false
        end
        local existing = poi.work_membership[item.key]
        if existing ~= nil then
            if item.kind == "objective" then
                existing.full = existing.full or item.full
                existing.refs.component = item.refs.component
            elseif item.kind == "tracker" then
                existing.action = item.action
                existing.index = item.index
                existing.refs.actor = item.refs.actor
            elseif item.kind == "filter" then
                existing.enabled = item.enabled
            end
            poi.metrics.events_coalesced = poi.metrics.events_coalesced + 1
            return true
        end
        poi.work_tail = poi.work_tail + 1
        poi.work_queue[poi.work_tail] = item
        poi.work_membership[item.key] = item
        poi.metrics.queue_high_water = math.max(poi.metrics.queue_high_water, queue_depth())
        arm_work()
        return true
    end

    function runtime.ResolveAndBindHandler()
        local controller = Object.Unwrap(state.controller)
        if not Object.Valid(controller) then return nil, "retained-controller-unavailable" end
        local handler = nil
        pcall(function() handler = Object.Unwrap(controller["World Map Handler"]) end)
        if not Object.Valid(handler) then return nil, "controller-property-unavailable" end
        poi.refs.handler = handler
        poi.handler_id = Object.Address(handler)
        poi.handler_resolution = "retained-local-controller-property"
        return handler, poi.handler_resolution
    end

    function runtime.BindHandler(handler, resolution)
        handler = Object.Unwrap(handler)
        if not Object.Valid(handler) then return false end
        poi.refs.handler = handler
        poi.handler_id = Object.Address(handler)
        poi.handler_resolution = tostring(resolution or "hook-context")
        return true
    end

    function runtime.Handler()
        local handler = Object.Unwrap(poi.refs.handler)
        return Object.Valid(handler) and handler or nil
    end

    function runtime.HasObjective(id)
        return id ~= nil and poi.records[id] ~= nil
    end

    function runtime.RefreshObjective(component, full)
        component = Object.Unwrap(component)
        local id = Object.Address(component)
        if id == nil then return nil, "component-invalid" end
        local existing = poi.records[id]
        if existing == nil or full == true then
            poi.metrics.full_reads = poi.metrics.full_reads + 1
            local replacement, err = Reader.ReadFull(component, poi.generation)
            if replacement == nil then
                poi.metrics.refresh_failures = poi.metrics.refresh_failures + 1
                if existing ~= nil then retire(id) end
                return nil, err
            end
            if existing ~= nil then
                replacement.future_pool_slot = existing.future_pool_slot
                apply_counts(existing, -1)
            else
                poi.record_count = poi.record_count + 1
            end
            poi.records[id] = replacement
            apply_counts(replacement, 1)
            return replacement, nil
        end

        poi.metrics.state_reads = poi.metrics.state_reads + 1
        apply_counts(existing, -1)
        local refreshed, err = Reader.RefreshState(existing, component)
        if not refreshed then
            poi.metrics.refresh_failures = poi.metrics.refresh_failures + 1
            apply_counts(existing, 1)
            retire(id)
            return nil, err
        end
        apply_counts(existing, 1)
        return existing, nil
    end

    -- AddMapObjective fires while the newly registered component is valid. Read
    -- it synchronously inside that callback, publish primitives, and retain no
    -- queued wrapper. This is the event-driven path for streamed-in POIs.
    function runtime.CaptureObjective(component, reason)
        poi.metrics.events_received = poi.metrics.events_received + 1
        local record, err = runtime.RefreshObjective(component, true)
        if record == nil then
            poi.metrics.invalid_events = poi.metrics.invalid_events + 1
            return false, err
        end
        poi.metrics.live_objective_adds = poi.metrics.live_objective_adds + 1
        ObjectivePool.RequestSync(reason or "objective-add")
        return true, nil
    end

    -- Objective lifecycle hooks know the state they are about to establish.
    -- Apply that primitive state directly instead of rescanning every component.
    function runtime.ApplyObjectiveState(id, updates, reason)
        poi.metrics.events_received = poi.metrics.events_received + 1
        id = id ~= nil and tostring(id) or nil
        local record = id ~= nil and poi.records[id] or nil
        if record == nil or type(updates) ~= "table" then
            poi.metrics.objective_state_misses =
                poi.metrics.objective_state_misses + 1
            return false, "objective-record-unavailable"
        end
        apply_counts(record, -1)
        for _, key in ipairs({ "enabled", "save_loaded", "visible",
                "revealed", "completed", "show_area" }) do
            if type(updates[key]) == "boolean" then record[key] = updates[key] end
        end
        apply_counts(record, 1)
        poi.metrics.objective_state_signals =
            poi.metrics.objective_state_signals + 1
        ObjectivePool.RequestSync(reason or "objective-state")
        return true, nil
    end

    -- Death-spoils retrieval is emitted by the owning actor, not by the map
    -- component. Match that already-published primitive owner address against
    -- the bounded registry and retire it without touching a live UObject.
    function runtime.RetireObjectiveByOwner(owner_id, reason)
        poi.metrics.events_received = poi.metrics.events_received + 1
        owner_id = owner_id ~= nil and tostring(owner_id) or nil
        if owner_id ~= nil then
            for id, record in pairs(poi.records) do
                if tostring(record.owner_id or "") == owner_id then
                    if retire(id) then
                        poi.metrics.objective_owner_retires =
                            poi.metrics.objective_owner_retires + 1
                        ObjectivePool.RequestSync(reason or "objective-owner-retire")
                        log(string.format(
                            "POI owner retired reason=%s generation=%d owner=%s record=%s category=%s remaining=%d syncRequested=true",
                            tostring(reason), poi.generation, owner_id, tostring(id),
                            tostring(record.icon_category), poi.record_count))
                        return true, nil
                    end
                end
            end
        end
        poi.metrics.objective_owner_retire_misses =
            poi.metrics.objective_owner_retire_misses + 1
        log(string.format(
            "POI owner retirement missed reason=%s generation=%d owner=%s objectives=%d",
            tostring(reason), poi.generation, tostring(owner_id), poi.record_count))
        return false, "objective-owner-unavailable"
    end

    function runtime.RetireUnseen(seen)
        local retired = 0
        for id in pairs(poi.records) do
            if seen[id] ~= true and retire(id) then retired = retired + 1 end
        end
        poi.metrics.stale_retired = poi.metrics.stale_retired + retired
        return retired
    end

    function runtime.QueueObjective(component, full)
        poi.metrics.events_received = poi.metrics.events_received + 1
        component = Object.Unwrap(component)
        local id = Object.Address(component)
        if id == nil then
            poi.metrics.invalid_events = poi.metrics.invalid_events + 1
            return false
        end
        return enqueue({
            kind = "objective",
            key = "objective:" .. id,
            full = full == true,
            refs = weak_values({ component = component }),
        })
    end

    function runtime.QueueTracker(action, actor, index)
        poi.metrics.events_received = poi.metrics.events_received + 1
        index = tonumber(Object.Unwrap(index))
        if action ~= "reconcile" and index == nil then
            poi.metrics.invalid_events = poi.metrics.invalid_events + 1
            return false
        end
        local key = action == "reconcile" and "tracker:reconcile" or "tracker:" .. tostring(index)
        return enqueue({
            kind = "tracker",
            key = key,
            action = action,
            index = index,
            refs = weak_values({ actor = Object.Unwrap(actor) }),
        })
    end

    function runtime.QueueFilter(tag, enabled)
        poi.metrics.events_received = poi.metrics.events_received + 1
        if tag == nil or enabled == nil then
            poi.metrics.invalid_events = poi.metrics.invalid_events + 1
            return false
        end
        return enqueue({
            kind = "filter",
            key = "filter:" .. tostring(tag),
            tag = tostring(tag),
            enabled = enabled == true,
        })
    end

    function runtime.SnapshotTrackers(handler, retain_actor_refs)
        handler = Object.Unwrap(handler)
        if not Object.Valid(handler) then return nil, "handler-invalid" end
        local map, max_trackers = nil, Object.Number(handler, "MaxTrackers") or 5
        local map_ok = pcall(function() map = handler.MapTrackers end)
        if not map_ok or map == nil then return nil, "map-trackers-unavailable" end
        local entries, read_method = Object.MapEntries(
            map, math.max(1, math.min(32, max_trackers)))
        local replacement, count = {}, 0
        for _, entry in ipairs(entries) do
            local index = tonumber(entry.key)
            local actor = Object.Unwrap(entry.value)
            if index ~= nil and Object.Valid(actor) then
                local location = Object.ActorLocation(actor)
                if location ~= nil then
                    replacement[index] = {
                        index = index,
                        actor_id = Object.Address(actor),
                        x = location.x,
                        y = location.y,
                    }
                    if retain_actor_refs == true then
                        replacement[index].refs = weak_values({ actor = actor })
                    end
                    count = count + 1
                end
            end
        end
        return {
            generation = poi.generation,
            records = replacement,
            count = count,
            read_method = tostring(read_method or "unknown"),
        }, nil
    end

    function runtime.ApplyTrackerSnapshot(snapshot, allow_empty)
        if type(snapshot) ~= "table" or type(snapshot.records) ~= "table" then
            return false, "snapshot-invalid"
        end
        if tonumber(snapshot.generation) ~= poi.generation then
            return false, "generation-stale"
        end
        local count = math.max(0, math.floor(tonumber(snapshot.count) or 0))
        if count == 0 and poi.tracker_count > 0 and allow_empty ~= true then
            poi.metrics.tracker_empty_reconciles_suppressed =
                poi.metrics.tracker_empty_reconciles_suppressed + 1
            return false, "empty-snapshot-suppressed"
        end
        poi.trackers = snapshot.records
        poi.tracker_count = count
        TrackerPool.SyncTrackers(poi.trackers)
        return true, nil
    end

    function runtime.ReconcileTrackers()
        local handler = runtime.Handler()
        if handler == nil then return false end
        local snapshot = runtime.SnapshotTrackers(handler, true)
        if snapshot == nil then return false end
        poi.metrics.tracker_reconciles = poi.metrics.tracker_reconciles + 1
        local applied = runtime.ApplyTrackerSnapshot(snapshot, false)
        return applied == true
    end

    function runtime.ReconcileFilters()
        local handler = runtime.Handler()
        if handler == nil then return false end
        local map = nil
        pcall(function() map = handler.MapFilterState end)
        local entries = Object.MapEntries(map, nil)
        local replacement, count = {}, 0
        for _, entry in ipairs(entries) do
            local tag = Object.Tag(entry.key)
            local enabled = Object.AsBoolean(entry.value)
            if tag ~= nil and enabled ~= nil then
                replacement[tag] = enabled
                count = count + 1
            end
        end
        poi.filters = replacement
        poi.filter_count = count
        poi.metrics.filter_reconciles = poi.metrics.filter_reconciles + 1
        return true
    end

    local function process_item(item)
        if item.kind == "objective" then
            runtime.RefreshObjective(item.refs.component, item.full)
            ObjectivePool.RequestSync("objective-event")
        elseif item.kind == "tracker" then
            if item.action == "reconcile" then
                runtime.ReconcileTrackers()
            elseif item.action == "remove" then
                poi.trackers[item.index] = nil
                poi.tracker_count = 0
                for _ in pairs(poi.trackers) do poi.tracker_count = poi.tracker_count + 1 end
                TrackerPool.SyncTrackers(poi.trackers)
            else
                local actor = Object.Unwrap(item.refs.actor)
                if Object.Valid(actor) then
                    local location = Object.ActorLocation(actor)
                    if poi.trackers[item.index] == nil then poi.tracker_count = poi.tracker_count + 1 end
                    poi.trackers[item.index] = {
                        index = item.index,
                        actor_id = Object.Address(actor),
                        refs = weak_values({ actor = actor }),
                        x = location and location.x or nil,
                        y = location and location.y or nil,
                    }
                    TrackerPool.SyncTrackers(poi.trackers)
                end
            end
        elseif item.kind == "filter" then
            if poi.filters[item.tag] == nil then poi.filter_count = poi.filter_count + 1 end
            poi.filters[item.tag] = item.enabled
        end
    end

    process_work = function()
        poi.work_armed = false
        if poi.quarantined then return end
        local processed, elapsed = WorkBudget.RunSlice(4, 0.20, function()
            if poi.work_head > poi.work_tail then return false end
            local item = poi.work_queue[poi.work_head]
            poi.work_queue[poi.work_head] = nil
            poi.work_head = poi.work_head + 1
            if item ~= nil and poi.work_membership[item.key] == item then
                poi.work_membership[item.key] = nil
                process_item(item)
            end
            return true
        end)
        poi.metrics.work_slices = poi.metrics.work_slices + 1
        poi.metrics.work_items = poi.metrics.work_items + processed
        poi.metrics.work_cpu_ms = poi.metrics.work_cpu_ms + elapsed
        poi.metrics.max_work_slice_ms = math.max(poi.metrics.max_work_slice_ms, elapsed)

        if poi.work_head > poi.work_tail then
            poi.work_queue = {}
            poi.work_head, poi.work_tail = 1, 0
            poi.work_membership = {}
        elseif poi.work_head > 512 and poi.work_head > poi.work_tail / 2 then
            local compacted, tail = {}, 0
            for index = poi.work_head, poi.work_tail do
                tail = tail + 1
                compacted[tail] = poi.work_queue[index]
            end
            poi.work_queue = compacted
            poi.work_head, poi.work_tail = 1, tail
        end
        arm_work()
    end

    function runtime.NoteHookCPU(elapsed_ms)
        poi.metrics.hook_cpu_ms = poi.metrics.hook_cpu_ms + (tonumber(elapsed_ms) or 0.0)
    end

    function runtime.OnWorldReleased()
        poi.quarantined = false
        poi.ready = false
        poi.resolve_attempts = 0
    end

    function runtime.OnLoadMapPre()
        poi.generation = poi.generation + 1
        poi.quarantined = true
        poi.ready = false
        poi.refs = weak_values()
        poi.handler_id = nil
        poi.handler_resolution = "none"
        poi.records = {}
        poi.record_count = 0
        poi.counts = new_counts()
        poi.trackers = {}
        poi.tracker_count = 0
        poi.filters = {}
        poi.filter_count = 0
        poi.work_queue = {}
        poi.work_head, poi.work_tail = 1, 0
        poi.work_membership = {}
        poi.work_armed = false
        poi.audit = nil
        poi.audit_requested = false
        poi.audit_force_full = false
        poi.audit_previous_handler_id = nil
        poi.begin_token = poi.begin_token + 1
        poi.begin_armed = false
        poi.resolve_attempts = 0
        poi.metrics.last_audit_total = 0
        poi.metrics.last_audit_valid = 0
        poi.metrics.last_audit_unique = 0
        poi.metrics.last_audit_invalid = 0
        poi.metrics.last_audit_duplicates = 0
        poi.metrics.last_audit_copy_ms = 0.0
        poi.metrics.world_resets = poi.metrics.world_resets + 1
    end

    function runtime.EmitSummary(reason)
        local counts, metrics = poi.counts, poi.metrics
        local hooks_armed = 0
        for _ in pairs(poi.hooks_armed) do hooks_armed = hooks_armed + 1 end
        local coverage = metrics.last_audit_unique > 0
            and poi.record_count / metrics.last_audit_unique or 0.0
        log(string.format(
            "POI summary reason=%s objectiveRegistryInvisible=true ready=%s generation=%d handler=%s objectives=%d enabled=%d located=%d saveLoaded=%d visible=%d revealed=%d completed=%d trackers=%d filters=%d hooks=%d/%d events=%d coalesced=%d queue=%d queueHigh=%d stale=%d bootstrapAudits=%d recurringAudits=0 liveAdds=%d objectiveStateSignals=%d objectiveStateMisses=%d ownerRetires=%d ownerRetireMisses=%d objectiveSignals=%d auditInterruptions=%d settledAudits=%d rawSlots=%d validSlots=%d unique=%d invalid=%d duplicates=%d coverage=%.3f fullReads=%d stateReads=%d refreshFailures=%d trackerReconciles=%d emptyTrackerReconcilesSuppressed=%d copyMs=%.3f workItems=%d workCpuMs=%.3f maxWorkSliceMs=%.3f auditCpuMs=%.3f maxAuditSliceMs=%.3f hookCpuMs=%.3f iconPolicy=%s trackerControl=fixed-pool-5 objectiveMarkers=event-driven-capped-pool",
            tostring(reason or "manual"), tostring(poi.ready), poi.generation,
            tostring(poi.handler_resolution), poi.record_count, counts.enabled,
            counts.located, counts.save_loaded, counts.visible, counts.revealed,
            counts.completed, poi.tracker_count, poi.filter_count, hooks_armed,
            tonumber(poi.hook_target_count) or 0,
            metrics.events_received, metrics.events_coalesced, queue_depth(),
            metrics.queue_high_water, metrics.stale_retired, metrics.audits_completed,
            metrics.live_objective_adds, metrics.objective_state_signals,
            metrics.objective_state_misses,
            metrics.objective_owner_retires,
            metrics.objective_owner_retire_misses,
            metrics.objective_transition_signals, metrics.audit_interruptions,
            metrics.settled_audits,
            metrics.last_audit_total, metrics.last_audit_valid,
            metrics.last_audit_unique, metrics.last_audit_invalid,
            metrics.last_audit_duplicates, coverage, metrics.full_reads,
            metrics.state_reads, metrics.refresh_failures,
            metrics.tracker_reconciles,
            metrics.tracker_empty_reconciles_suppressed,
            metrics.last_audit_copy_ms,
            metrics.work_items, metrics.work_cpu_ms, metrics.max_work_slice_ms,
            metrics.audit_cpu_ms, metrics.max_audit_slice_ms, metrics.hook_cpu_ms,
            IconResolver.Policy()))
        if tostring(reason or "manual") == "ctrl-delete" then
            -- Bounded, primitive-only category accounting makes a missing icon
            -- distinguishable from a state-filtered one without probing UObjects.
            local category_states, unresolved = {}, {
                raw = 0, ready = 0, visible = 0, revealed = 0,
            }
            for _, category in ipairs(IconResolver.Categories) do
                category_states[category.key] = {
                    raw = 0, ready = 0, visible = 0, revealed = 0,
                }
            end
            local map_station_samples = {}
            for _, record in pairs(poi.records) do
                local bucket = category_states[tostring(record.icon_category or "")]
                    or unresolved
                bucket.raw = bucket.raw + 1
                bucket.visible = bucket.visible + (record.visible == true and 1 or 0)
                bucket.revealed = bucket.revealed + (record.revealed == true and 1 or 0)
                local category = IconResolver.Category(record.icon_category)
                local reveal_ready = type(category) == "table"
                    and category.show_when_enabled == true
                    or record.visible == true or record.revealed == true
                local ready = record.enabled == true and record.save_loaded == true
                    and reveal_ready
                    and tonumber(record.world_x) ~= nil and tonumber(record.world_y) ~= nil
                bucket.ready = bucket.ready + (ready and 1 or 0)
                local owner_class = tostring(record.owner_class or "")
                local objective_tag = tostring(record.objective_tag or "")
                if #map_station_samples < 4
                    and (record.icon_category == "MapStation"
                        or owner_class:find("MapObjective_MapStation", 1, true) ~= nil
                        or objective_tag:find("MapStation", 1, true) ~= nil) then
                    map_station_samples[#map_station_samples + 1] = string.format(
                        "category=%s owner=%s icon=%s tag=%s enabled=%s loaded=%s visible=%s revealed=%s located=%s policy=%s",
                        tostring(record.icon_category or "none"),
                        owner_class ~= "" and owner_class or "none",
                        tostring(record.icon_key or "none"),
                        objective_tag ~= "" and objective_tag or "none",
                        tostring(record.enabled), tostring(record.save_loaded),
                        tostring(record.visible), tostring(record.revealed),
                        tostring(record.world_x ~= nil), tostring(record.icon_policy or "none"))
                end
            end
            local category_text = {}
            for _, category in ipairs(IconResolver.Categories) do
                local bucket = category_states[category.key]
                category_text[#category_text + 1] = string.format(
                    "%s:%d/%d(v%d,r%d)", category.key, bucket.ready,
                    bucket.raw, bucket.visible, bucket.revealed)
            end
            log(string.format(
                "POI category-state reason=ctrl-delete ready/raw(visible,revealed)=%s unresolved=%d/%d(v%d,r%d)",
                table.concat(category_text, "|"), unresolved.ready, unresolved.raw,
                unresolved.visible, unresolved.revealed))
            if #map_station_samples == 0 then
                log("POI map-station candidate reason=ctrl-delete samples=0")
            else
                for index, sample in ipairs(map_station_samples) do
                    log("POI map-station candidate reason=ctrl-delete sample="
                        .. tostring(index) .. " " .. sample)
                end
            end
        end
        TrackerPool.EmitSummary(reason)
        ObjectivePool.EmitSummary(reason)
        if type(ctx.TrackerLifecycle) == "table"
            and type(ctx.TrackerLifecycle.EmitSummary) == "function" then
            ctx.TrackerLifecycle.EmitSummary(reason)
        end
        if tostring(reason or "manual") == "ctrl-delete" then
            TrackerTelemetry.Emit(poi.trackers, poi.tracker_count)
        end
    end

    runtime.State = poi
    return runtime
end

return Factory
