-- Sliced bootstrap reconciliation for the invisible registry.
-- Each slice reacquires the live handler/array and retains no copied UObject
-- wrappers between callbacks. Runtime additions and state changes are handled
-- by targeted game events; there is deliberately no recurring component scan.

local Factory = {}

function Factory.New(ctx)
    local state = assert(ctx.State, "POI.Audit requires State")
    local Object = assert(ctx.Object, "POI.Audit requires Core.Object")
    local Registry = assert(ctx.Registry, "POI.Audit requires POI.Registry")
    local WorkBudget = assert(ctx.WorkBudget, "POI.Audit requires Runtime.WorkBudget")
    local log = assert(ctx.Log, "POI.Audit requires Log")
    local runtime = {}
    local poi = assert(state.poi, "POI.Audit requires initialized POI state")

    local begin_audit
    local step_audit

    local function cancel_scheduled_begin()
        poi.begin_token = poi.begin_token + 1
        poi.begin_armed = false
    end

    local function abandon_active_audit()
        local job = poi.audit
        if job == nil then return false end
        poi.audit = nil
        poi.audit_requested = false
        poi.metrics.audit_interruptions = poi.metrics.audit_interruptions + 1
        return true
    end

    local function schedule_begin(delay_ms, reason, replace)
        if poi.quarantined then return false end
        if poi.begin_armed and replace ~= true then return true end
        poi.begin_token = poi.begin_token + 1
        local token = poi.begin_token
        local generation = poi.generation
        poi.begin_armed = true
        local scheduled = WorkBudget.Schedule(delay_ms, function()
            if poi.begin_token ~= token then return end
            poi.begin_armed = false
            if not poi.quarantined and poi.generation == generation then begin_audit(reason) end
        end, "audit.begin")
        if not scheduled and poi.begin_token == token then poi.begin_armed = false end
        return scheduled
    end

    local function finish(job)
        if poi.audit ~= job then return end
        local previous_unique = tonumber(poi.metrics.last_audit_unique) or 0
        local retire_started = os.clock()
        local retired = Registry.RetireUnseen(job.seen)
        Registry.ReconcileTrackers()
        Registry.ReconcileFilters()
        if type(ctx.ObjectivePool) == "table"
            and type(ctx.ObjectivePool.RequestSync) == "function" then
            ctx.ObjectivePool.RequestSync("audit-finish")
        end
        local finish_ms = (os.clock() - retire_started) * 1000.0
        job.cpu_ms = job.cpu_ms + finish_ms
        job.max_slice_ms = math.max(job.max_slice_ms, finish_ms)
        poi.audit = nil
        poi.ready = true
        poi.metrics.audits_completed = poi.metrics.audits_completed + 1
        poi.metrics.audit_cpu_ms = poi.metrics.audit_cpu_ms + job.cpu_ms
        poi.metrics.max_audit_slice_ms = math.max(poi.metrics.max_audit_slice_ms, job.max_slice_ms)
        poi.metrics.last_audit_total = job.raw_slots
        poi.metrics.last_audit_valid = job.valid_items
        poi.metrics.last_audit_unique = job.unique_items
        poi.metrics.last_audit_invalid = job.invalid_items
        poi.metrics.last_audit_duplicates = job.duplicate_items
        poi.metrics.last_audit_copy_ms = job.copy_ms

        if poi.ready_logged_generation ~= poi.generation then
            poi.ready_logged_generation = poi.generation
            local coverage = job.unique_items > 0 and poi.record_count / job.unique_items or 0.0
            log(string.format(
                "POI registry ready invisibleState=true generation=%d objectives=%d trackers=%d filters=%d retired=%d rawSlots=%d validSlots=%d unique=%d invalid=%d duplicates=%d coverage=%.3f refreshFailures=%d copyMs=%.3f auditCpuMs=%.3f maxSliceMs=%.3f markers=capped-revealed-pool",
                poi.generation,
                poi.record_count, poi.tracker_count, poi.filter_count, retired,
                job.raw_slots, job.valid_items, job.unique_items,
                job.invalid_items, job.duplicate_items, coverage,
                poi.metrics.refresh_failures, job.copy_ms,
                job.cpu_ms, job.max_slice_ms))
        end

        if job.handler_changed or job.unique_items ~= previous_unique
            or job.id % 6 == 0 then
            log(string.format(
                "POI live audit reason=%s id=%d handler=%s previousHandler=%s handlerChanged=%s objectives=%d previousUnique=%d retired=%d rawSlots=%d valid=%d invalid=%d refreshFailures=%d arrayAccess=live-sliced retainedWrappers=0 auditCpuMs=%.3f maxSliceMs=%.3f",
                tostring(job.reason), job.id, tostring(job.handler_id),
                tostring(job.previous_handler_id), tostring(job.handler_changed),
                job.unique_items, previous_unique, retired, job.raw_slots,
                job.valid_items, job.invalid_items, poi.metrics.refresh_failures,
                job.cpu_ms, job.max_slice_ms))
        end

        if poi.audit_requested then
            poi.audit_requested = false
            schedule_begin(100, "coalesced-request", true)
        end
    end


    local function acquire_live_objectives()
        -- Always resolve through the current controller property. A previously
        -- valid handler can remain alive after the streaming system replaces it.
        local handler = Registry.ResolveAndBindHandler()
        if handler == nil then return nil, nil, nil, "handler-unavailable" end
        local handler_id = Object.Address(handler)
        if handler_id == nil then return nil, nil, nil, "handler-address-unavailable" end
        local objectives = nil
        local ok = pcall(function() objectives = handler.MapObjectives end)
        if not ok or objectives == nil then
            return nil, handler_id, nil, "array-unavailable"
        end
        local count, method = Object.ArrayCount(objectives)
        if count == nil then return nil, handler_id, nil, method or "array-count-unavailable" end
        return objectives, handler_id, count, method
    end

    local function restart_live_audit(job, reason, delay_ms, next_handler_id)
        if poi.audit ~= job then return false end
        if next_handler_id ~= nil and next_handler_id ~= job.handler_id then
            -- ResolveAndBindHandler publishes the new cached id immediately.
            -- Carry the old id and full-refresh requirement across the retry so
            -- a transient empty/new array cannot erase the handler transition.
            poi.audit_force_full = true
            poi.audit_previous_handler_id = job.handler_id
        end
        poi.audit = nil
        poi.audit_requested = false
        poi.metrics.audit_interruptions = poi.metrics.audit_interruptions + 1
        return schedule_begin(delay_ms or 250, reason, true)
    end

    step_audit = function(job)
        if poi.audit ~= job or poi.quarantined or job.generation ~= poi.generation then return end
        local objectives, handler_id, current_count, method = acquire_live_objectives()
        if objectives == nil then
            restart_live_audit(job, "live-array-retry:" .. tostring(method), 500)
            return
        end
        if handler_id ~= job.handler_id or current_count ~= job.raw_slots then
            restart_live_audit(job, "streaming-snapshot-changed", 250, handler_id)
            return
        end

        local _, elapsed = WorkBudget.RunSlice(4, 2.0, function()
            if job.index >= job.raw_slots then return false end
            job.index = job.index + 1
            local component = Object.ArrayAt(objectives, job.index)
            local id = Object.Address(component)
            if id ~= nil then
                job.valid_items = job.valid_items + 1
                if job.seen[id] == true then
                    job.duplicate_items = job.duplicate_items + 1
                else
                    job.seen[id] = true
                    job.unique_items = job.unique_items + 1
                    Registry.RefreshObjective(component,
                        job.force_full or not Registry.HasObjective(id))
                end
            else
                job.invalid_items = job.invalid_items + 1
            end
            return true
        end)
        job.cpu_ms = job.cpu_ms + elapsed
        job.max_slice_ms = math.max(job.max_slice_ms, elapsed)
        -- Drop the live TArray wrapper before yielding to the game thread.
        objectives = nil
        if job.index >= job.raw_slots then
            finish(job)
        else
            local generation = job.generation
            WorkBudget.Schedule(25, function()
                if not poi.quarantined and poi.generation == generation then step_audit(job) end
            end, "audit.step")
        end
    end

    begin_audit = function(reason)
        if poi.quarantined then return false end
        if poi.audit ~= nil then
            poi.audit_requested = true
            return false
        end
        local previous_handler_id = poi.audit_previous_handler_id or poi.handler_id
        local inherited_force_full = poi.audit_force_full == true
        local objectives, handler_id, raw_slots, method = acquire_live_objectives()
        if objectives == nil then
            poi.resolve_attempts = poi.resolve_attempts + 1
            schedule_begin(poi.resolve_attempts <= 8 and 500 or 5000,
                "handler-retry:" .. tostring(method), true)
            return false
        end
        local observed_handler_change = previous_handler_id ~= nil
            and previous_handler_id ~= handler_id
        if observed_handler_change then
            poi.audit_force_full = true
            poi.audit_previous_handler_id = previous_handler_id
            inherited_force_full = true
        end
        -- A zero-length list is transient in this game's streaming handoff. It
        -- must never erase a populated registry and strand the minimap empty.
        if raw_slots == 0 and poi.record_count > 0 then
            poi.resolve_attempts = poi.resolve_attempts + 1
            schedule_begin(1000, "streaming-empty-retry", true)
            return false
        end
        poi.resolve_attempts = 0
        poi.audit_force_full = false
        poi.audit_previous_handler_id = nil
        poi.audit_sequence = poi.audit_sequence + 1
        local handler_changed = inherited_force_full or observed_handler_change
        local job = {
            id = poi.audit_sequence,
            generation = poi.generation,
            reason = reason,
            handler_id = handler_id,
            previous_handler_id = previous_handler_id,
            handler_changed = handler_changed,
            force_full = handler_changed,
            raw_slots = raw_slots,
            copy_method = "live:" .. tostring(method),
            copy_ms = 0.0,
            index = 0,
            seen = {},
            valid_items = 0,
            unique_items = 0,
            invalid_items = 0,
            duplicate_items = 0,
            cpu_ms = 0.0,
            max_slice_ms = 0.0,
        }
        objectives = nil
        poi.audit = job
        step_audit(job)
        return true
    end

    function runtime.Begin(reason)
        cancel_scheduled_begin()
        return begin_audit(reason or "manual")
    end

    function runtime.Request(reason)
        if poi.quarantined then return false end
        if poi.audit ~= nil then
            poi.audit_requested = true
            return true
        end
        schedule_begin(100, reason or "event", true)
        return true
    end

    function runtime.OnWorldReleased(reason)
        -- Give renderer-ready the first opportunity to start the one bootstrap
        -- scan. This request is the fallback if the renderer is delayed.
        return runtime.Request("world-release:" .. tostring(reason))
    end

    function runtime.OnLoadMapPre()
        cancel_scheduled_begin()
        abandon_active_audit()
        poi.audit_requested = false
    end

    return runtime
end

return Factory
