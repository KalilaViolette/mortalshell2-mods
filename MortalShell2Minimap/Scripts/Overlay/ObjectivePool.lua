-- Capped plain-UImage pool for all revealed map objectives. Registry changes
-- trigger coalesced target synchronization; normal movement only performs a
-- bounded projection pass with epsilon/state-gated writes. Exact texture loads
-- and image construction are sliced outside the movement path.

local Factory = {}

function Factory.New(ctx)
    local state = assert(ctx.State, "Overlay.ObjectivePool requires State")
    local Config = assert(ctx.Config, "Overlay.ObjectivePool requires Config")
    local Object = assert(ctx.Object, "Overlay.ObjectivePool requires Core.Object")
    local Projection = assert(ctx.TrackerProjection,
        "Overlay.ObjectivePool requires Overlay.TrackerProjection")
    local IconResolver = assert(ctx.IconResolver,
        "Overlay.ObjectivePool requires POI.IconResolver")
    local WorkBudget = assert(ctx.WorkBudget,
        "Overlay.ObjectivePool requires Runtime.WorkBudget")
    local log = assert(ctx.Log, "Overlay.ObjectivePool requires Log")
    local Perf = type(ctx.Perf) == "table" and ctx.Perf
        or { Begin = function() return nil end, End = function() end, Count = function() end }
    local unwrap, valid = Object.Unwrap, Object.Valid

    local IMAGE_CLASS_PATH = "/Script/UMG.Image"
    local VIS_COLLAPSED = 1
    local VIS_HIT_TEST_INVISIBLE = 3
    -- Legacy positional argument retained for TrackerProjection compatibility;
    -- Config.EdgeVisibility now owns the actual edge-depth policy.
    local EDGE_INSET_SCALE = 0.0
    local POSITION_EPSILON_SQ = 0.001 * 0.001
    local CONSTRUCTION_BATCH = 4
    local CONSTRUCTION_DELAY_MS = 50
    local ASSET_DELAY_MS = 30

    local runtime = {}
    state.objective_pool = state.objective_pool or {
        entries = {},
        by_record = {},
        pending_targets = {},
        assets = {},
        asset_status = {},
        ready = false,
        dependency_started = false,
        build_blocked = false,
        active_count = 0,
        desired_count = 0,
        overflow_count = 0,
        build_token = 0,
        sync_token = 0,
        sync_pending = false,
        no_map_hidden = false,
        image_class = nil,
        metrics = {
            asset_attempts = 0,
            asset_resident = 0,
            asset_loaded = 0,
            asset_failures = 0,
            asset_cpu_ms = 0.0,
            builds = 0,
            build_failures = 0,
            images_constructed = 0,
            build_cpu_ms = 0.0,
            max_build_slice_ms = 0.0,
            syncs = 0,
            sync_requests = 0,
            sync_coalesced = 0,
            eligible_seen = 0,
            unresolved_skipped = 0,
            overflow_dropped = 0,
            position_writes = 0,
            position_skips = 0,
            size_writes = 0,
            visibility_writes = 0,
            texture_writes = 0,
            on_map_updates = 0,
            persistent_updates = 0,
            hidden_updates = 0,
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
    local pool = state.objective_pool
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

    local function load_exact_asset(path)
        local object = find_object(path)
        if object ~= nil then return object, "resident" end
        if type(LoadAsset) == "function" then
            local token = Perf.Begin()
            pcall(LoadAsset, path)
            Perf.End("native.load", token)
        end
        object = find_object(path)
        return object, object ~= nil and "loaded" or "unavailable"
    end

    local function capacity()
        return math.max(32, math.min(192,
            math.floor(tonumber(Config.POIMaxIcons) or 192)))
    end

    local function config_value(category, suffix, fallback)
        if type(category) ~= "table" then return fallback end
        local key = type(category.config_keys) == "table"
            and category.config_keys[suffix] or nil
        local value = nil
        if key ~= nil then value = Config[key] end
        if value == nil then return fallback end
        return value
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

    local function set_render_size(item, rendered_width, rendered_height)
        rendered_width, rendered_height = tonumber(rendered_width), tonumber(rendered_height)
        if rendered_width == nil or rendered_height == nil
            or rendered_width <= 0 or rendered_height <= 0 then return false end
        if item.last_render_width == rendered_width
            and item.last_render_height == rendered_height then return true end
        local slot = item.refs.slot
        if not valid(slot) then return false end
        item.size_value.X, item.size_value.Y = rendered_width, rendered_height
        local ok = pcall(slot.SetSize, slot, item.size_value)
        if ok then
            item.last_render_width, item.last_render_height = rendered_width, rendered_height
            pool.metrics.size_writes = pool.metrics.size_writes + 1
        end
        return ok
    end

    local function clear_target(item)
        if type(item.target) == "table" and item.target.record_id ~= nil then
            pool.by_record[item.target.record_id] = nil
        end
        item.target = nil
        item.last_x, item.last_y = nil, nil
        item.last_mode = nil
        item.last_standard_inside = nil
        item.last_render_width, item.last_render_height = nil, nil
        set_visible(item, false)
    end

    local function assign_target(item, target)
        local changed = type(item.target) ~= "table"
            or item.target.record_id ~= target.record_id
            or item.target.x ~= target.x or item.target.y ~= target.y
            or item.target.texture_path ~= target.texture_path
            or item.target.category_key ~= target.category_key
            or item.target.presentation_signature ~= target.presentation_signature
        local texture = pool.assets[target.texture_path]
            or pool.assets[IconResolver.FallbackPath]
        if not valid(texture) then return false end
        if item.texture_path ~= target.texture_path then
            local ok = pcall(item.refs.image.SetBrushFromTexture,
                item.refs.image, texture, false)
            if not ok then return false end
            item.texture_path = target.texture_path
            pool.metrics.texture_writes = pool.metrics.texture_writes + 1
        end
        item.target = target
        pool.by_record[target.record_id] = item
        if changed then
            item.last_x, item.last_y = nil, nil
            item.last_mode = nil
            item.last_standard_inside = nil
            item.last_render_width, item.last_render_height = nil, nil
        end
        return true
    end

    local function construct_entry()
        local frame = state.retained and state.retained.frame or nil
        if not valid(frame) or not valid(pool.image_class) then
            return nil, "renderer-frame-or-image-class-unavailable"
        end
        local index = #pool.entries + 1
        local refs = {}
        local ok, build_error = pcall(function()
            local image = unwrap(StaticConstructObject(
                pool.image_class, frame, make_name("Objective" .. tostring(index))))
            assert(valid(image), "objective image construction failed index=" .. tostring(index))
            refs.image = image
            local slot = unwrap(frame:AddChildToCanvas(image))
            assert(valid(slot), "objective slot failed index=" .. tostring(index))
            refs.slot = slot
            slot:SetPosition({ X = -10000, Y = -10000 })
            slot:SetSize({ X = 1, Y = 1 })
            pcall(slot.SetZOrder, slot, 4)
            image:SetVisibility(VIS_COLLAPSED)
        end)
        if not ok then
            if valid(refs.image) then pcall(refs.image.RemoveFromParent, refs.image) end
            return nil, tostring(build_error)
        end
        local item = {
            index = index,
            refs = refs,
            target = nil,
            visible = false,
            texture_path = nil,
            last_x = nil,
            last_y = nil,
            last_mode = nil,
            last_standard_inside = nil,
            last_render_width = nil,
            last_render_height = nil,
            position_value = { X = -10000, Y = -10000 },
            size_value = { X = 1, Y = 1 },
            write_error_logged = false,
        }
        pool.entries[index] = item
        return item, nil
    end

    local function set_mode(item, mode, standard_inside)
        if item.last_mode ~= nil and item.last_mode ~= mode then
            pool.metrics.mode_transitions = pool.metrics.mode_transitions + 1
        end
        item.last_mode = mode
        item.last_standard_inside = standard_inside
        if mode == Projection.MODE_MAP then
            pool.metrics.on_map_updates = pool.metrics.on_map_updates + 1
        elseif mode == Projection.MODE_EDGE then
            pool.metrics.persistent_updates = pool.metrics.persistent_updates + 1
        else
            pool.metrics.hidden_updates = pool.metrics.hidden_updates + 1
        end
    end

    local function update_entry(item, player_x, player_y, context)
        local target = item.target
        if type(target) ~= "table" then return true end
        local presentation = target.presentation
        if type(presentation) ~= "table" then
            set_visible(item, false)
            return false
        end
        pool.metrics.entries_examined = pool.metrics.entries_examined + 1
        local delta_x = target.x - player_x
        local delta_y = target.y - player_y
        if target.broad_phase_revision ~= context.range_revision then
            target.broad_phase_radius_sq = Projection.RelevantRadiusSquared(
                context, presentation.marker_radius_pixels,
                presentation.edge_enabled, presentation.edge_max_distance)
            target.broad_phase_revision = context.range_revision
        end
        local radius_sq = target.broad_phase_radius_sq
        if radius_sq ~= nil and delta_x * delta_x + delta_y * delta_y > radius_sq then
            pool.metrics.broad_phase_rejects = pool.metrics.broad_phase_rejects + 1
            set_mode(item, Projection.MODE_HIDDEN, false)
            set_visible(item, false)
            return true
        end
        pool.metrics.projections_executed = pool.metrics.projections_executed + 1
        local x, y, _, _, standard_inside, display_visible, _, _, mode,
            rendered_size = Projection.PositionPrepared(
                context,
                player_x, player_y, target.x, target.y,
                presentation.base_size, presentation.edge_enabled,
                presentation.edge_max_distance, presentation.edge_min_scale,
                presentation.base_width, presentation.base_height)
        if x == nil or mode == nil or rendered_size == nil then return false end
        set_mode(item, mode, standard_inside)
        if not display_visible then
            set_visible(item, false)
            return true
        end
        local marker_scale = rendered_size / presentation.base_size
        local rendered_width = presentation.base_width * marker_scale
        local rendered_height = presentation.base_height * marker_scale
        if rendered_width == nil or rendered_height == nil
            or not set_render_size(item, rendered_width, rendered_height) then
            set_visible(item, false)
            return false
        end
        -- Projection returns the top-left of the conservative maximum-extent square.
        -- Recenter the aspect-preserved native artwork inside that same footprint.
        x = x + (rendered_size - rendered_width) / 2.0
        y = y + (rendered_size - rendered_height) / 2.0
        local dx = item.last_x ~= nil and x - item.last_x or 0.0
        local dy = item.last_y ~= nil and y - item.last_y or 0.0
        if item.last_x ~= nil and dx * dx + dy * dy < POSITION_EPSILON_SQ then
            pool.metrics.position_skips = pool.metrics.position_skips + 1
            return set_visible(item, true)
        end
        item.position_value.X, item.position_value.Y = x, y
        local ok = pcall(item.refs.slot.SetPosition,
            item.refs.slot, item.position_value)
        if not ok then
            set_visible(item, false)
            if not item.write_error_logged then
                item.write_error_logged = true
                log("Objective pool slot write failed index=" .. tostring(item.index)
                    .. "; marker hidden and the direct slot write will retry")
            end
            return false
        end
        item.last_x, item.last_y = x, y
        pool.metrics.position_writes = pool.metrics.position_writes + 1
        return set_visible(item, true)
    end

    function runtime.UpdatePlayer(player_x, player_y, context)
        pool.metrics.update_calls = pool.metrics.update_calls + 1
        player_x, player_y = tonumber(player_x), tonumber(player_y)
        if not pool.ready or player_x == nil or player_y == nil then return false end
        if state.area_map_available == false then
            if pool.no_map_hidden then
                pool.metrics.no_map_latch_skips = pool.metrics.no_map_latch_skips + 1
                return true
            end
            for _, item in ipairs(pool.entries) do set_visible(item, false) end
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
        for _, item in ipairs(pool.entries) do
            if item.target ~= nil and not update_entry(item, player_x, player_y, context) then
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

    local build_pending_slice
    local function arm_pending_build()
        if pool.build_blocked or #pool.pending_targets == 0 then return false end
        pool.build_token = pool.build_token + 1
        local token = pool.build_token
        local generation = type(state.poi) == "table" and state.poi.generation or 0
        return WorkBudget.Schedule(1, function()
            if pool.build_token == token and not state.world_quarantined
                and type(state.poi) == "table" and state.poi.generation == generation then
                build_pending_slice(token, generation)
            end
        end, "objective.build-arm")
    end

    build_pending_slice = function(token, generation)
        if pool.build_token ~= token or state.world_quarantined
            or type(state.poi) ~= "table" or state.poi.generation ~= generation then return end
        local started, built = os.clock(), 0
        while built < CONSTRUCTION_BATCH and #pool.pending_targets > 0
            and #pool.entries < capacity() do
            local item, build_error = construct_entry()
            if item == nil then
                pool.build_blocked = true
                pool.metrics.build_failures = pool.metrics.build_failures + 1
                log("Objective pool construction stopped: " .. tostring(build_error)
                    .. "; already-built icons remain active")
                break
            end
            local target = table.remove(pool.pending_targets, 1)
            if not assign_target(item, target) then
                clear_target(item)
                pool.metrics.build_failures = pool.metrics.build_failures + 1
            end
            built = built + 1
            pool.metrics.images_constructed = pool.metrics.images_constructed + 1
        end
        local elapsed = (os.clock() - started) * 1000.0
        pool.metrics.build_cpu_ms = pool.metrics.build_cpu_ms + elapsed
        pool.metrics.max_build_slice_ms = math.max(pool.metrics.max_build_slice_ms, elapsed)
        if built > 0 then pool.metrics.builds = pool.metrics.builds + 1 end
        runtime.UpdatePlayer(state.map_center_world_x, state.map_center_world_y)
        if #pool.pending_targets > 0 and not pool.build_blocked then
            WorkBudget.Schedule(CONSTRUCTION_DELAY_MS, function()
                if pool.build_token == token and not state.world_quarantined
                    and type(state.poi) == "table" and state.poi.generation == generation then
                    build_pending_slice(token, generation)
                end
            end, "objective.build-slice")
        end
    end

    local function eligible_target(record)
        if not Config.ShowPOIs or type(record) ~= "table"
            or record.enabled ~= true or record.save_loaded ~= true
            or tonumber(record.world_x) == nil or tonumber(record.world_y) == nil then
            return nil
        end
        local category = IconResolver.Category(record.icon_category)
        if category == nil or config_value(category, "Visible", true) ~= true then
            return nil
        end
        local discovery_mode = tostring(category.discovery_mode or "only")
        local discovered = record.visible == true or record.revealed == true
        if discovery_mode == "only" then
            local discovered_only = config_value(category, "DiscoveredOnly",
                category.discovery_default == true) == true
            if discovered_only and not discovered then return nil end
        elseif discovery_mode == "hidden" then
            local discovered_hidden = config_value(
                category, "DiscoveredHidden", category.discovery_default == true) == true
            if discovered_hidden and discovered then return nil end
        end
        if category.hide_when_completed == true and record.completed == true then
            return nil
        end
        local texture_path = record.completed == true
            and record.icon_completed_path or record.icon_default_path
        if type(texture_path) ~= "string" then return nil end
        if not valid(pool.assets[texture_path])
            and not valid(pool.assets[IconResolver.FallbackPath]) then
            pool.metrics.unresolved_skipped = pool.metrics.unresolved_skipped + 1
            return nil
        end
        local base_size = math.max(16, math.floor(tonumber(
            config_value(category, "IconSize", category.size)) or category.size))
        local edge_enabled = config_value(
            category, "EdgeIndicators", category.edge) == true
        local edge_max_distance = tonumber(config_value(
            category, "EdgeMaxDistance", category.edge_max_distance))
        local edge_min_scale = tonumber(config_value(
            category, "EdgeMinScale", category.edge_min_scale))
        local base_width, base_height = IconResolver.FitSize(texture_path, base_size)
        if base_width == nil or base_height == nil then return nil end
        local presentation_signature = table.concat({
            tostring(base_size), tostring(edge_enabled),
            tostring(edge_max_distance), tostring(edge_min_scale),
            tostring(base_width), tostring(base_height),
        }, "|")
        return {
            record_id = record.id,
            x = tonumber(record.world_x),
            y = tonumber(record.world_y),
            category_key = category.key,
            category_index = category.index,
            texture_path = texture_path,
            completed = record.completed == true,
            presentation_signature = presentation_signature,
            presentation = {
                base_size = base_size,
                base_width = base_width,
                base_height = base_height,
                marker_radius_pixels = math.sqrt(
                    base_width * base_width + base_height * base_height) / 2.0,
                edge_enabled = edge_enabled,
                edge_max_distance = edge_max_distance,
                edge_min_scale = edge_min_scale,
            },
        }
    end

    function runtime.SyncObjectives(records)
        if not pool.ready then pool.sync_pending = true; return false end
        pool.no_map_hidden = false
        records = type(records) == "table" and records or {}
        local targets = {}
        for _, record in pairs(records) do
            local target = eligible_target(record)
            if target ~= nil then targets[#targets + 1] = target end
        end
        table.sort(targets, function(a, b)
            if a.category_index ~= b.category_index then
                return a.category_index < b.category_index
            end
            return tostring(a.record_id) < tostring(b.record_id)
        end)
        pool.metrics.eligible_seen = pool.metrics.eligible_seen + #targets
        pool.desired_count = #targets
        local max_icons = capacity()
        pool.overflow_count = math.max(0, #targets - max_icons)
        pool.metrics.overflow_dropped = pool.metrics.overflow_dropped + pool.overflow_count
        while #targets > max_icons do table.remove(targets) end

        local desired = {}
        for _, target in ipairs(targets) do desired[target.record_id] = target end
        local free = {}
        for _, item in ipairs(pool.entries) do
            local record_id = type(item.target) == "table" and item.target.record_id or nil
            local target = record_id ~= nil and desired[record_id] or nil
            if target ~= nil then
                assign_target(item, target)
                desired[record_id] = nil
            else
                clear_target(item)
                free[#free + 1] = item
            end
        end

        pool.pending_targets = {}
        for _, target in ipairs(targets) do
            if desired[target.record_id] ~= nil then
                local item = table.remove(free)
                if item ~= nil then
                    assign_target(item, target)
                else
                    pool.pending_targets[#pool.pending_targets + 1] = target
                end
                desired[target.record_id] = nil
            end
        end
        pool.active_count = #targets
        pool.metrics.syncs = pool.metrics.syncs + 1
        pool.sync_pending = false
        runtime.UpdatePlayer(state.map_center_world_x, state.map_center_world_y)
        arm_pending_build()
        return true
    end

    function runtime.RequestSync(reason)
        pool.metrics.sync_requests = pool.metrics.sync_requests + 1
        if pool.sync_pending then
            pool.metrics.sync_coalesced = pool.metrics.sync_coalesced + 1
        end
        pool.sync_pending = true
        pool.sync_token = pool.sync_token + 1
        local token = pool.sync_token
        local generation = type(state.poi) == "table" and state.poi.generation or 0
        if not pool.ready then return true end
        return WorkBudget.Schedule(150, function()
            if pool.sync_token == token and not state.world_quarantined
                and type(state.poi) == "table" and state.poi.generation == generation then
                runtime.SyncObjectives(state.poi.records)
                if reason == "hook:deathSpoils.GiveGloom" then
                    log(string.format(
                        "Objective pickup sync applied generation=%d active=%d pending=%d",
                        generation, pool.active_count, #pool.pending_targets))
                end
            end
        end, "objective.sync")
    end

    local function resolve_assets_step(paths, index, token, generation)
        if pool.build_token ~= token or state.world_quarantined
            or type(state.poi) ~= "table" or state.poi.generation ~= generation then return end
        if index > #paths then
            pool.ready = true
            pool.dependency_started = false
            local available = 0
            for _, path in ipairs(paths) do
                if valid(pool.assets[path]) then available = available + 1 end
            end
            log(string.format(
                "Objective pool assets ready exact=%d/%d failures=%d cap=%d slicedLoads=true cdoReads=0 softWrapperReads=0",
                available, #paths, pool.metrics.asset_failures, capacity()))
            runtime.SyncObjectives(type(state.poi) == "table" and state.poi.records or nil)
            return
        end
        local path = paths[index]
        local started = os.clock()
        local asset, status = load_exact_asset(path)
        local elapsed = (os.clock() - started) * 1000.0
        pool.metrics.asset_attempts = pool.metrics.asset_attempts + 1
        pool.metrics.asset_cpu_ms = pool.metrics.asset_cpu_ms + elapsed
        pool.assets[path] = asset
        pool.asset_status[path] = status
        if status == "resident" then
            pool.metrics.asset_resident = pool.metrics.asset_resident + 1
        elseif status == "loaded" then
            pool.metrics.asset_loaded = pool.metrics.asset_loaded + 1
        else
            pool.metrics.asset_failures = pool.metrics.asset_failures + 1
        end
        WorkBudget.Schedule(ASSET_DELAY_MS, function()
            resolve_assets_step(paths, index + 1, token, generation)
        end, "objective.asset-step")
    end

    function runtime.OnRendererReady()
        if pool.dependency_started or pool.ready then return true end
        local frame = state.retained and state.retained.frame or nil
        if not state.built or not valid(frame) then return false end
        pool.image_class = find_object(IMAGE_CLASS_PATH)
        if not valid(pool.image_class) then
            pool.metrics.build_failures = pool.metrics.build_failures + 1
            log("Objective pool unavailable: UImage class not resident; native minimap continues")
            return false
        end
        pool.dependency_started = true
        pool.build_token = pool.build_token + 1
        local token = pool.build_token
        local generation = type(state.poi) == "table" and state.poi.generation or 0
        local paths = IconResolver.Paths()
        return WorkBudget.Schedule(100, function()
            resolve_assets_step(paths, 1, token, generation)
        end, "objective.asset-start")
    end

    function runtime.ApplyLiveSetting(setting)
        if type(setting) ~= "table" then return end
        if setting.apply == "poi-presentation" then
            pool.no_map_hidden = false
            for _, item in ipairs(pool.entries) do
                item.last_x, item.last_y = nil, nil
                item.last_mode, item.last_standard_inside = nil, nil
                item.last_render_width, item.last_render_height = nil, nil
            end
            runtime.RequestSync("settings")
        elseif setting.apply == "edge-presentation" then
            pool.no_map_hidden = false
            for _, item in ipairs(pool.entries) do
                item.last_x, item.last_y = nil, nil
                item.last_mode, item.last_standard_inside = nil, nil
            end
            runtime.UpdatePlayer(state.map_center_world_x, state.map_center_world_y)
        elseif setting.apply == "zoom" then
            pool.no_map_hidden = false
            for _, item in ipairs(pool.entries) do
                item.last_x, item.last_y = nil, nil
                item.last_mode, item.last_standard_inside = nil, nil
            end
            runtime.UpdatePlayer(state.map_center_world_x, state.map_center_world_y)
        end
    end

    function runtime.DropWorldReferencesUnread()
        pool.build_token = pool.build_token + 1
        pool.sync_token = pool.sync_token + 1
        pool.entries = {}
        pool.by_record = {}
        pool.pending_targets = {}
        pool.assets = {}
        pool.asset_status = {}
        pool.ready = false
        pool.dependency_started = false
        pool.build_blocked = false
        pool.active_count = 0
        pool.desired_count = 0
        pool.overflow_count = 0
        pool.sync_pending = false
        pool.no_map_hidden = false
        pool.image_class = nil
    end

    local function visible_count()
        local count = 0
        for _, item in ipairs(pool.entries) do
            if item.visible then count = count + 1 end
        end
        return count
    end

    function runtime.EmitSummary(reason)
        local category_counts = {}
        for _, category in ipairs(IconResolver.Categories) do
            category_counts[category.key] = { active = 0, visible = 0 }
        end
        for _, item in ipairs(pool.entries) do
            if type(item.target) == "table" then
                local counts = category_counts[item.target.category_key]
                if counts ~= nil then
                    counts.active = counts.active + 1
                    if item.visible then counts.visible = counts.visible + 1 end
                end
            end
        end
        local category_text = {}
        for _, category in ipairs(IconResolver.Categories) do
            local counts = category_counts[category.key]
            category_text[#category_text + 1] = string.format(
                "%s:%d/%d", category.key, counts.visible, counts.active)
        end
        local metrics = pool.metrics
        log(string.format(
            "Objective pool summary reason=%s ready=%s cap=%d desired=%d active=%d built=%d visible=%d pending=%d overflow=%d categories=%s assets=%d resident=%d loaded=%d assetFailures=%d assetCpuMs=%.3f buildSlices=%d buildFailures=%d buildCpuMs=%.3f maxBuildSliceMs=%.3f syncs=%d syncRequests=%d syncCoalesced=%d positionWrites=%d positionSkips=%d sizeWrites=%d visibilityWrites=%d textureWrites=%d onMapUpdates=%d persistentUpdates=%d hiddenUpdates=%d modeTransitions=%d edgeVisibility=%d%% exactPaths=true directSlots=true",
            tostring(reason or "manual"), tostring(pool.ready), capacity(),
            pool.desired_count, pool.active_count, #pool.entries, visible_count(),
            #pool.pending_targets, pool.overflow_count,
            table.concat(category_text, "|"), metrics.asset_attempts,
            metrics.asset_resident, metrics.asset_loaded, metrics.asset_failures,
            metrics.asset_cpu_ms, metrics.builds, metrics.build_failures,
            metrics.build_cpu_ms, metrics.max_build_slice_ms, metrics.syncs,
            metrics.sync_requests, metrics.sync_coalesced,
            metrics.position_writes, metrics.position_skips, metrics.size_writes,
            metrics.visibility_writes, metrics.texture_writes,
            metrics.on_map_updates, metrics.persistent_updates,
            metrics.hidden_updates, metrics.mode_transitions,
            math.floor(tonumber(Config.EdgeVisibility) or 50)))
        log(string.format(
            "Objective pool performance reason=%s updateCalls=%d updateRuns=%d noMapLatchSkips=%d entriesExamined=%d broadPhaseRejects=%d projections=%d timingSamples=%d sampledUpdateCpuMs=%.3f sampledMaxUpdateCpuMs=%.3f cachedPresentation=true cachedAspect=true squaredDistanceGate=true summaryOnly=true",
            tostring(reason or "manual"), metrics.update_calls,
            metrics.update_runs, metrics.no_map_latch_skips,
            metrics.entries_examined, metrics.broad_phase_rejects,
            metrics.projections_executed, metrics.update_timing_samples,
            metrics.update_cpu_ms,
            metrics.max_update_cpu_ms))
    end

    runtime.EdgeVisibility = function() return tonumber(Config.EdgeVisibility) or 50 end
    return runtime
end

return Factory
