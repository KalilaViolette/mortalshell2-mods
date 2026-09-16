-- Fixed five-image tracker pool. All UImages and slots are allocated together
-- after the native renderer is ready. Normal movement performs bounded pure
-- projection plus epsilon/state-gated writes to those existing slots.

local Factory = {}

function Factory.New(ctx)
    local state = assert(ctx.State, "Overlay.TrackerPool requires State")
    local Config = assert(ctx.Config, "Overlay.TrackerPool requires Config")
    local Object = assert(ctx.Object, "Overlay.TrackerPool requires Core.Object")
    local Projection = assert(ctx.TrackerProjection,
        "Overlay.TrackerPool requires Overlay.TrackerProjection")
    local WorkBudget = assert(ctx.WorkBudget, "Overlay.TrackerPool requires Runtime.WorkBudget")
    local log = assert(ctx.Log, "Overlay.TrackerPool requires Log")
    local Perf = type(ctx.Perf) == "table" and ctx.Perf
        or { Begin = function() return nil end, End = function() end, Count = function() end }
    local unwrap, valid = Object.Unwrap, Object.Valid

    local TRACKER_TEXTURE_PATH = "/Game/Sparta/UI/World/Map/Textures/T_UI_Icon_Map_Tracker_Color.T_UI_Icon_Map_Tracker_Color"
    local IMAGE_CLASS_PATH = "/Script/UMG.Image"
    local MAX_TRACKERS = 5
    -- v0.9.9 replaces the fixed midpoint edge anchor with Config.EdgeVisibility.
    -- The legacy positional argument remains zero for TrackerProjection API compatibility.
    local EDGE_INSET_SCALE = 0.0
    local VIS_COLLAPSED = 1
    local VIS_HIT_TEST_INVISIBLE = 3
    local POSITION_EPSILON_SQ = 0.001 * 0.001

    local runtime = {}
    state.tracker_pool = state.tracker_pool or {
        entries = {},
        ready = false,
        active_count = 0,
        no_map_hidden = false,
        build_token = 0,
        dependency_attempted = false,
        asset_state = "unattempted",
        texture = nil,
        image_class = nil,
        metrics = {
            builds = 0,
            build_failures = 0,
            images_constructed = 0,
            build_cpu_ms = 0.0,
            max_build_cpu_ms = 0.0,
            dependency_attempts = 0,
            dependency_cpu_ms = 0.0,
            syncs = 0,
            position_writes = 0,
            position_skips = 0,
            size_writes = 0,
            visibility_writes = 0,
            offscreen_updates = 0,
            persistent_updates = 0,
            hidden_updates = 0,
            ignored_trackers = 0,
            target_transitions = 0,
            frame_transitions = 0,
            mode_transitions = 0,
            update_calls = 0,
            update_runs = 0,
            no_map_latch_skips = 0,
            entries_examined = 0,
            broad_phase_rejects = 0,
            projections_executed = 0,
            update_cpu_ms = 0.0,
            max_update_cpu_ms = 0.0,
            update_timing_samples = 0,
        },
    }
    local pool = state.tracker_pool
    if pool.no_map_hidden == nil then pool.no_map_hidden = false end
    pool.metrics = pool.metrics or {}
    local metric_defaults = {
        update_calls = 0, update_runs = 0, no_map_latch_skips = 0,
        entries_examined = 0, broad_phase_rejects = 0,
        projections_executed = 0, update_cpu_ms = 0.0,
        max_update_cpu_ms = 0.0, update_timing_samples = 0,
    }
    for key, value in pairs(metric_defaults) do
        if pool.metrics[key] == nil then pool.metrics[key] = value end
    end

    local function ensure_entry(index)
        local item = pool.entries[index]
        if type(item) ~= "table" then
            item = {
                index = index,
                refs = {},
                target = {},
                ready = false,
                visible = false,
                last_x = nil,
                last_y = nil,
                last_standard_inside = nil,
                last_mode = nil,
                last_render_size = nil,
                pending_target_log = false,
                write_error_logged = false,
                size_error_logged = false,
                position_value = { X = -10000, Y = -10000 },
                size_value = { X = 1, Y = 1 },
            }
            pool.entries[index] = item
        end
        return item
    end

    for index = 0, MAX_TRACKERS - 1 do ensure_entry(index) end

    local function make_name(base)
        state.widget_counter = state.widget_counter + 1
        return FName("MS2Minimap_" .. tostring(base) .. "_" .. tostring(state.widget_counter))
    end

    local function find_object(path)
        local token = Perf.Begin()
        local ok, value = pcall(StaticFindObject, path)
        Perf.End("native.find", token)
        value = unwrap(ok and value or nil)
        return valid(value) and value or nil
    end

    local function resolve_dependencies_once()
        if pool.dependency_attempted then
            if valid(pool.texture) and valid(pool.image_class) then
                return pool.image_class, pool.texture
            end
            return nil, nil
        end
        pool.dependency_attempted = true
        pool.metrics.dependency_attempts = pool.metrics.dependency_attempts + 1
        local started = os.clock()
        pool.image_class = find_object(IMAGE_CLASS_PATH)
        pool.texture = find_object(TRACKER_TEXTURE_PATH)
        pool.metrics.dependency_cpu_ms = pool.metrics.dependency_cpu_ms
            + (os.clock() - started) * 1000.0
        pool.asset_state = valid(pool.texture) and "resident" or "unavailable"
        if not valid(pool.image_class) or not valid(pool.texture) then return nil, nil end
        return pool.image_class, pool.texture
    end

    local function marker_size()
        return math.max(16, math.floor(tonumber(Config.TrackerIconSize) or 28))
    end

    local function visible_count()
        local count = 0
        for index = 0, MAX_TRACKERS - 1 do
            if ensure_entry(index).visible then count = count + 1 end
        end
        return count
    end

    local function set_visible(item, visible)
        visible = visible == true
        if item.visible == visible then return true end
        local image = item.refs.image
        if not valid(image) then return false end
        local ok = pcall(image.SetVisibility, image,
            visible and VIS_HIT_TEST_INVISIBLE or VIS_COLLAPSED)
        if ok then
            item.visible = visible
            pool.metrics.visibility_writes = pool.metrics.visibility_writes + 1
        end
        return ok
    end

    local function set_render_size(item, rendered_size)
        rendered_size = tonumber(rendered_size)
        if rendered_size == nil or rendered_size <= 0 then return false end
        if item.last_render_size == rendered_size then return true end
        local slot = item.refs.slot
        if not valid(slot) then return false end
        item.size_value.X, item.size_value.Y = rendered_size, rendered_size
        local ok = pcall(slot.SetSize, slot, item.size_value)
        if ok then
            item.last_render_size = rendered_size
            pool.metrics.size_writes = pool.metrics.size_writes + 1
            return true
        end
        if not item.size_error_logged then
            item.size_error_logged = true
            log("Tracker pool size write failed index=" .. tostring(item.index)
                .. "; marker hidden and the size write will retry")
        end
        return false
    end

    local function log_projection_transition(item, reason, player_x, player_y,
        offset_x, offset_y, standard_inside, display_visible, distance_meters,
        frame_limit, mode, rendered_size, boundary_distance, display_x,
        display_y, anchor_limit, size_scale, size_progress)
        local scale = Projection.Scale(Config.Size, Config.ZoomMeters)
        local target_x, target_y = tonumber(item.target.x), tonumber(item.target.y)
        if scale == nil or target_x == nil or target_y == nil then return end
        log(string.format(
            "Tracker transition reason=%s index=%d actor=%s player=(%.3f,%.3f) target=(%.3f,%.3f) deltaMeters=(%.3f,%.3f) distance=%.3fm nativeScale=%.6fpxm trueOffset=(%.3f,%.3f) displayOffset=(%.3f,%.3f) frameLimit=%.3f edgeAnchorLimit=%.3f boundaryDistance=%.3fm mode=%s standardInside=%s displayVisible=%s renderedSize=%.0f sizeScale=%.3f sizeProgress=%.3f",
            tostring(reason), item.index, tostring(item.target.actor_id),
            player_x, player_y, target_x, target_y,
            (target_x - player_x) / 100.0, (target_y - player_y) / 100.0,
            distance_meters, scale * 100.0, offset_x, offset_y,
            display_x or 0.0, display_y or 0.0, frame_limit, anchor_limit,
            boundary_distance or 0.0, Projection.ModeName(mode),
            tostring(standard_inside), tostring(display_visible), rendered_size,
            size_scale, size_progress))
    end

    local function clear_target(item)
        if item.target.index ~= nil then
            pool.metrics.target_transitions = pool.metrics.target_transitions + 1
            log(string.format(
                "Tracker transition reason=target-cleared index=%d actor=%s lastMode=%s lastStandardInside=%s",
                item.index, tostring(item.target.actor_id),
                Projection.ModeName(item.last_mode),
                tostring(item.last_standard_inside)))
        end
        item.target = {}
        item.last_x, item.last_y = nil, nil
        item.last_standard_inside = nil
        item.last_mode = nil
        item.pending_target_log = false
        set_visible(item, false)
    end

    local function drop_refs()
        for index = 0, MAX_TRACKERS - 1 do
            local item = ensure_entry(index)
            item.refs = {}
            item.target = {}
            item.ready = false
            item.visible = false
            item.last_x, item.last_y = nil, nil
            item.last_standard_inside = nil
            item.last_mode = nil
            item.last_render_size = nil
            item.pending_target_log = false
            item.write_error_logged = false
            item.size_error_logged = false
        end
        pool.ready = false
        pool.active_count = 0
        pool.no_map_hidden = false
    end

    local function update_entry(item, player_x, player_y, base_size,
        context, relevant_radius_sq)
        if not item.ready or tonumber(item.target.x) == nil
            or tonumber(item.target.y) == nil then return true end
        local slot, image = item.refs.slot, item.refs.image
        if not valid(slot) or not valid(image) then return false end

        pool.metrics.entries_examined = pool.metrics.entries_examined + 1
        local delta_x = tonumber(item.target.x) - player_x
        local delta_y = tonumber(item.target.y) - player_y
        if relevant_radius_sq ~= nil
            and delta_x * delta_x + delta_y * delta_y > relevant_radius_sq then
            pool.metrics.broad_phase_rejects = pool.metrics.broad_phase_rejects + 1
            if item.last_mode ~= nil and item.last_mode ~= Projection.MODE_HIDDEN then
                pool.metrics.mode_transitions = pool.metrics.mode_transitions + 1
            end
            item.last_mode = Projection.MODE_HIDDEN
            item.last_standard_inside = false
            pool.metrics.offscreen_updates = pool.metrics.offscreen_updates + 1
            pool.metrics.hidden_updates = pool.metrics.hidden_updates + 1
            set_visible(item, false)
            return true
        end
        pool.metrics.projections_executed = pool.metrics.projections_executed + 1

        local x, y, offset_x, offset_y, standard_inside, display_visible,
            distance_meters, frame_limit, mode, rendered_size,
            boundary_distance, display_x, display_y, anchor_limit,
            size_scale, size_progress = Projection.PositionPrepared(
                context,
                player_x, player_y, item.target.x, item.target.y,
                base_size,
                Config.ShowTrackerEdgeIndicators,
                Config.TrackerEdgeMaxDistance, Config.TrackerEdgeMinScale,
                base_size, base_size)
        if x == nil or standard_inside == nil or display_visible == nil
            or mode == nil or rendered_size == nil then return false end

        local mode_changed = item.last_mode ~= nil and item.last_mode ~= mode
        local frame_changed = item.last_standard_inside ~= nil
            and item.last_standard_inside ~= standard_inside
        if mode_changed then
            pool.metrics.mode_transitions = pool.metrics.mode_transitions + 1
        end
        if frame_changed then
            pool.metrics.frame_transitions = pool.metrics.frame_transitions + 1
        end

        local transition_reason = nil
        if item.pending_target_log then
            transition_reason = "target-acquired"
            item.pending_target_log = false
            pool.metrics.target_transitions = pool.metrics.target_transitions + 1
        elseif mode_changed then
            transition_reason = "mode-" .. Projection.ModeName(item.last_mode)
                .. "-to-" .. Projection.ModeName(mode)
        elseif frame_changed then
            transition_reason = standard_inside and "frame-enter" or "frame-exit"
        end
        if transition_reason ~= nil then
            log_projection_transition(item, transition_reason, player_x, player_y,
                offset_x, offset_y, standard_inside, display_visible,
                distance_meters, frame_limit, mode, rendered_size,
                boundary_distance, display_x, display_y, anchor_limit,
                size_scale, size_progress)
        end
        item.last_standard_inside = standard_inside
        item.last_mode = mode

        if not standard_inside then
            pool.metrics.offscreen_updates = pool.metrics.offscreen_updates + 1
        end
        if mode == Projection.MODE_EDGE then
            pool.metrics.persistent_updates = pool.metrics.persistent_updates + 1
        end
        if not display_visible then
            pool.metrics.hidden_updates = pool.metrics.hidden_updates + 1
            set_visible(item, false)
            return true
        end

        if not set_render_size(item, rendered_size) then
            set_visible(item, false)
            return false
        end

        local dx = item.last_x ~= nil and x - item.last_x or 0.0
        local dy = item.last_y ~= nil and y - item.last_y or 0.0
        if item.last_x ~= nil and dx * dx + dy * dy < POSITION_EPSILON_SQ then
            pool.metrics.position_skips = pool.metrics.position_skips + 1
            return set_visible(item, true)
        end

        item.position_value.X, item.position_value.Y = x, y
        local ok = pcall(slot.SetPosition, slot, item.position_value)
        if not ok then
            set_visible(item, false)
            if not item.write_error_logged then
                item.write_error_logged = true
                log("Tracker pool slot write failed index=" .. tostring(item.index)
                    .. "; marker hidden and the direct slot write will retry")
            end
            return false
        end
        item.last_x, item.last_y = x, y
        pool.metrics.position_writes = pool.metrics.position_writes + 1
        return set_visible(item, true)
    end

    function runtime.DropWorldReferencesUnread()
        pool.build_token = pool.build_token + 1
        drop_refs()
        pool.no_map_hidden = false
    end

    function runtime.UpdatePlayer(player_x, player_y, context)
        pool.metrics.update_calls = pool.metrics.update_calls + 1
        if not pool.ready then return false end
        player_x, player_y = tonumber(player_x), tonumber(player_y)
        if player_x == nil or player_y == nil then return false end
        if state.area_map_available == false then
            if pool.no_map_hidden then
                pool.metrics.no_map_latch_skips = pool.metrics.no_map_latch_skips + 1
                return true
            end
            for index = 0, MAX_TRACKERS - 1 do
                set_visible(ensure_entry(index), false)
            end
            pool.no_map_hidden = true
            return true
        end
        pool.no_map_hidden = false
        context = context or Projection.Prepare(
            Config.Size, Config.ZoomMeters, state.map_rotation_angle,
            Config.MapShape, Config.EdgeVisibility)
        if type(context) ~= "table" then return false end
        pool.metrics.update_runs = pool.metrics.update_runs + 1
        local sample_timing = pool.metrics.update_runs % 120 == 1
        local started = sample_timing and os.clock() or nil
        local success = true
        local base_size = marker_size()
        local relevant_radius_sq = Projection.RelevantRadiusSquared(
            context, base_size * math.sqrt(2.0) / 2.0,
            Config.ShowTrackerEdgeIndicators,
            Config.TrackerEdgeMaxDistance)
        for index = 0, MAX_TRACKERS - 1 do
            if not update_entry(ensure_entry(index), player_x, player_y, base_size,
                context, relevant_radius_sq) then
                success = false
            end
        end
        if started ~= nil then
            local elapsed = (os.clock() - started) * 1000.0
            pool.metrics.update_cpu_ms = pool.metrics.update_cpu_ms + elapsed
            pool.metrics.max_update_cpu_ms = math.max(pool.metrics.max_update_cpu_ms, elapsed)
            pool.metrics.update_timing_samples = pool.metrics.update_timing_samples + 1
        end
        return success
    end

    function runtime.SyncTrackers(trackers)
        pool.no_map_hidden = false
        trackers = type(trackers) == "table" and trackers or {}
        local active_count = 0
        for index = 0, MAX_TRACKERS - 1 do
            local item = ensure_entry(index)
            local record = trackers[index]
            if type(record) == "table" and tonumber(record.x) ~= nil
                and tonumber(record.y) ~= nil then
                active_count = active_count + 1
                local changed = item.target.index ~= index
                    or item.target.actor_id ~= record.actor_id
                    or item.target.x ~= record.x or item.target.y ~= record.y
                item.target = {
                    index = index,
                    actor_id = record.actor_id,
                    x = record.x,
                    y = record.y,
                }
                if changed then
                    item.last_x, item.last_y = nil, nil
                    item.last_standard_inside = nil
                    item.last_mode = nil
                    item.pending_target_log = true
                end
            else
                clear_target(item)
            end
        end

        local ignored = 0
        for index, record in pairs(trackers) do
            local number = tonumber(index)
            if type(record) == "table" and (number == nil or number < 0
                or number >= MAX_TRACKERS or number ~= math.floor(number)) then
                ignored = ignored + 1
            end
        end
        pool.active_count = active_count
        pool.metrics.ignored_trackers = pool.metrics.ignored_trackers + ignored
        pool.metrics.syncs = pool.metrics.syncs + 1
        runtime.UpdatePlayer(state.map_center_world_x, state.map_center_world_y)
        return true
    end

    function runtime.Build()
        if pool.ready then return true end
        local frame = state.retained and state.retained.frame or nil
        if not state.built or not valid(frame) then return false end
        local image_class, texture = resolve_dependencies_once()
        if image_class == nil or texture == nil then
            pool.metrics.build_failures = pool.metrics.build_failures + 1
            log("Tracker pool unavailable asset=" .. tostring(pool.asset_state)
                .. "; native minimap continues without tracker markers")
            return false
        end

        local refs = {}
        local size = marker_size()
        local build_started = os.clock()
        local ok, build_error = pcall(function()
            for index = 0, MAX_TRACKERS - 1 do
                local image = unwrap(StaticConstructObject(
                    image_class, frame, make_name("Tracker" .. tostring(index))))
                assert(valid(image), "tracker image construction failed index=" .. tostring(index))
                refs[index] = { image = image }
                image:SetBrushFromTexture(texture, false)
                pcall(image.SetDesiredSizeOverride, image, { X = size, Y = size })
                local slot = unwrap(frame:AddChildToCanvas(image))
                assert(valid(slot), "tracker slot failed index=" .. tostring(index))
                refs[index].slot = slot
                slot:SetPosition({ X = -10000, Y = -10000 })
                slot:SetSize({ X = size, Y = size })
                pcall(slot.SetZOrder, slot, 5 + index)
                image:SetVisibility(VIS_COLLAPSED)
            end
        end)
        local build_elapsed = (os.clock() - build_started) * 1000.0
        pool.metrics.build_cpu_ms = pool.metrics.build_cpu_ms + build_elapsed
        pool.metrics.max_build_cpu_ms = math.max(
            pool.metrics.max_build_cpu_ms, build_elapsed)
        if not ok then
            for index = 0, MAX_TRACKERS - 1 do
                local item = refs[index]
                if type(item) == "table" and valid(item.image) then
                    pcall(item.image.RemoveFromParent, item.image)
                end
            end
            pool.metrics.build_failures = pool.metrics.build_failures + 1
            log("Tracker pool build failed: " .. tostring(build_error)
                .. "; native minimap continues without tracker markers")
            return false
        end

        for index = 0, MAX_TRACKERS - 1 do
            local item = ensure_entry(index)
            item.refs = refs[index]
            item.ready = true
            item.visible = false
            item.last_render_size = size
            item.size_value.X, item.size_value.Y = size, size
        end
        pool.ready = true
        pool.metrics.builds = pool.metrics.builds + 1
        pool.metrics.images_constructed = pool.metrics.images_constructed + MAX_TRACKERS
        runtime.SyncTrackers(type(ctx.Registry) == "table"
            and ctx.Registry.State.trackers or nil)
        log(string.format(
            "Tracker pool ready asset=%s dependencyCpuMs=%.3f buildCpuMs=%.3f pool=%d constructed=%d active=%d visible=%d baseSize=%d persistentEdges=%s edgeRange=%.0fm edgeMinScale=%.2f edgeVisibility=%d%% directSlots=true objectiveMarkers=capped-revealed-pool",
            tostring(pool.asset_state), pool.metrics.dependency_cpu_ms, build_elapsed,
            MAX_TRACKERS, MAX_TRACKERS, pool.active_count, visible_count(), size,
            tostring(Config.ShowTrackerEdgeIndicators),
            Config.TrackerEdgeMaxDistance, Config.TrackerEdgeMinScale,
            math.floor(tonumber(Config.EdgeVisibility) or 50)))
        return true
    end

    function runtime.OnRendererReady()
        pool.build_token = pool.build_token + 1
        local token = pool.build_token
        local generation = type(state.poi) == "table" and state.poi.generation or 0
        return WorkBudget.Schedule(100, function()
            if pool.build_token == token and type(state.poi) == "table"
                and state.poi.generation == generation and not state.world_quarantined then
                runtime.Build()
            end
        end, "tracker.build")
    end

    function runtime.ApplyLiveSetting(setting)
        if not pool.ready or type(setting) ~= "table" then return end
        if setting.apply ~= "zoom" and setting.apply ~= "tracker-presentation"
            and setting.apply ~= "edge-presentation" then
            return
        end
        pool.no_map_hidden = false
        for index = 0, MAX_TRACKERS - 1 do
            local item = ensure_entry(index)
            item.last_x, item.last_y = nil, nil
            item.last_standard_inside = nil
            item.last_mode = nil
            if setting.key == "TrackerIconSize" then
                item.last_render_size = nil
            end
        end
        runtime.UpdatePlayer(state.map_center_world_x, state.map_center_world_y)
    end

    function runtime.EmitSummary(reason)
        local metrics = pool.metrics
        log(string.format(
            "Tracker pool summary reason=%s ready=%s asset=%s pool=%d active=%d visible=%d baseSize=%d persistentEdges=%s edgeRange=%.0fm edgeMinScale=%.2f edgeVisibility=%d%% builds=%d failures=%d imagesConstructed=%d buildCpuMs=%.3f maxBuildCpuMs=%.3f dependencyAttempts=%d dependencyCpuMs=%.3f syncs=%d positionWrites=%d positionSkips=%d sizeWrites=%d visibilityWrites=%d offscreenUpdates=%d persistentUpdates=%d hiddenUpdates=%d ignoredTrackers=%d targetTransitions=%d frameTransitions=%d modeTransitions=%d directSlots=true objectiveMarkers=capped-revealed-pool",
            tostring(reason or "manual"), tostring(pool.ready),
            tostring(pool.asset_state), MAX_TRACKERS, pool.active_count,
            visible_count(), marker_size(),
            tostring(Config.ShowTrackerEdgeIndicators),
            Config.TrackerEdgeMaxDistance, Config.TrackerEdgeMinScale,
            math.floor(tonumber(Config.EdgeVisibility) or 50), metrics.builds, metrics.build_failures,
            metrics.images_constructed, metrics.build_cpu_ms,
            metrics.max_build_cpu_ms, metrics.dependency_attempts,
            metrics.dependency_cpu_ms, metrics.syncs,
            metrics.position_writes, metrics.position_skips,
            metrics.size_writes, metrics.visibility_writes,
            metrics.offscreen_updates, metrics.persistent_updates,
            metrics.hidden_updates, metrics.ignored_trackers,
            metrics.target_transitions, metrics.frame_transitions,
            metrics.mode_transitions))
        log(string.format(
            "Tracker pool performance reason=%s updateCalls=%d updateRuns=%d noMapLatchSkips=%d entriesExamined=%d broadPhaseRejects=%d projections=%d timingSamples=%d sampledUpdateCpuMs=%.3f sampledMaxUpdateCpuMs=%.3f squaredDistanceGate=true summaryOnly=true",
            tostring(reason or "manual"), metrics.update_calls,
            metrics.update_runs, metrics.no_map_latch_skips,
            metrics.entries_examined, metrics.broad_phase_rejects,
            metrics.projections_executed, metrics.update_timing_samples,
            metrics.update_cpu_ms,
            metrics.max_update_cpu_ms))
        for index = 0, MAX_TRACKERS - 1 do
            local item = ensure_entry(index)
            if item.target.index ~= nil then
                log(string.format(
                    "Tracker pool slot index=%d actor=%s visible=%s mode=%s renderedSize=%s target=(%s,%s) lastSlot=(%s,%s) standardInside=%s",
                    index, tostring(item.target.actor_id), tostring(item.visible),
                    Projection.ModeName(item.last_mode),
                    tostring(item.last_render_size), tostring(item.target.x),
                    tostring(item.target.y), tostring(item.last_x),
                    tostring(item.last_y), tostring(item.last_standard_inside)))
            end
        end
    end

    runtime.Capacity = MAX_TRACKERS
    runtime.EdgeVisibility = function() return tonumber(Config.EdgeVisibility) or 50 end
    return runtime
end

return Factory
