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
    -- Core/Timeline.lua, soft (see Runtime/Lifecycle.lua for why).
    local Timeline = ctx.Timeline or { Stamp = function() end }
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
    -- v0.23.4: a BUDGET, not a fixed one-per-timer. Measured on her machine, the local
    -- sweep cost 244 ms over 30 scheduled steps -- 8 ms of work per step and 30 ms of
    -- waiting between them, so nearly a second of wall clock to resolve 45 textures that
    -- together cost a quarter of that. The delay was sized for the worst case (a texture
    -- that needs a disk load) and paid on every case, including the resident ones that
    -- take a fraction of a millisecond.
    --
    -- Now each step keeps resolving until it has spent ASSET_BUDGET_MS, then yields for
    -- one frame instead of one-and-a-half. Residents fly through many per step; a real
    -- load takes its step alone and yields immediately after. Same per-frame ceiling,
    -- roughly half the wall clock, and it self-tunes to her machine rather than to a
    -- number somebody picked.
    local ASSET_DELAY_MS = 16
    local ASSET_BUDGET_MS = 8.0

    local runtime = {}
    state.objective_pool = state.objective_pool or {
        entries = {},
        by_record = {},
        pending_targets = {},
        assets = {},
        -- v0.23.46: path -> { keeper = our collapsed UImage, texture = the wrapper it
        -- owns }. Without this pool.assets was a plain Lua table of textures with no
        -- owner in the engine's object graph, and valid() on a collected one is fatal.
        pinned = {},
        asset_status = {},
        -- v0.23.57: what one asset load has been costing, so a step can stop
        -- BEFORE one that will not fit its budget. Decayed, never a permanent
        -- high-water mark, and dropped with the assets on a world change because
        -- a new world's textures are a different disk.
        asset_step_cost_ms = 0.0,
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
        -- v0.23.4: /Script/ paths come from the shared memo in Core/Object.lua. Engine
        -- classes and CDOs live for the process, are not part of any world and are not
        -- touched by LoadMap, so they are the one thing this codebase is allowed to hold
        -- across a world change -- and they were being resolved once per module.
        -- "/Script/UMG.Image" alone was found eight times in a single build, at about
        -- 3 ms a call. The memo validates on the way out, so a stale entry misses and
        -- re-finds rather than handing back a dead wrapper. Everything else is unchanged.
        if type(Object.FindEngineClass) == "function" then
            local memoized = Object.FindEngineClass(path, Perf, "native.find")
            if memoized ~= nil then return memoized end
        end
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

    -- v0.23.5. This pool has only ever had visibility, never opacity -- it did not need
    -- one until icons had to FADE in through fog rather than appear at a boundary.
    -- Written only on a change, like every other property write in this file.
    local function set_item_opacity(item, opacity)
        if item.opacity == opacity then return true end
        local image = item.refs.image
        if not valid(image) then return false end
        if pcall(image.SetRenderOpacity, image, opacity) then
            item.opacity = opacity
            pool.metrics.opacity_writes = (pool.metrics.opacity_writes or 0) + 1
            return true
        end
        return false
    end

    -- v0.23.39. The fog layer owns the number; this only asks. 1.0 when fog is off,
    -- suppressed in a dungeon, or unavailable, so a player with fog off sees exactly what
    -- this pool has always shown.
    local function fog_visibility(world_x, world_y)
        if type(ctx.Fog) ~= "table" or type(ctx.Fog.MarkerVisibility) ~= "function" then
            return 1.0
        end
        local ok, value = pcall(ctx.Fog.MarkerVisibility, world_x, world_y)
        if not ok then return 1.0 end
        value = tonumber(value)
        if value == nil then return 1.0 end
        if value < 0.0 then return 0.0 elseif value > 1.0 then return 1.0 end
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

    -- THE OBJECTIVE ICONS HAD NO OWNER. v0.23.46, and it is invariant 0x for the fourth
    -- time today.
    --
    -- HER CRASH, and the crumbs that found it. v0.23.44 bracketed every engine call in
    -- construct_entry, and her next trail came back with every family BALANCED at 238/238
    -- and the log ending on "c-done" for entry 66. So construction completes and is
    -- exonerated -- the instrument proved the innocence of the thing it instrumented.
    --
    -- That left exactly one uncrumbed span: what runs after construct_entry returns and
    -- before the next c-guard. Reading it, the only engine work in there is assign_target,
    -- and assign_target's FIRST engine-touching line is valid(texture) on pool.assets.
    --
    -- pool.assets is a plain Lua table of LoadAsset'd textures held across frames with NO
    -- owner in the engine's object graph. Overlay/LocalPool.lua has pinned its icons into
    -- keeper Images since v0.10.14 and Map/FogLayer.lua learned the same lesson three
    -- times today; this pool never did. valid() on a collected wrapper is FATAL rather
    -- than false, which is why the signature is an access violation reading 0x40 in a
    -- SAFETY CHECK, and why it lands after a fast travel or a death reload: those are
    -- where the collector runs.
    --
    -- It also explains the shape exactly. 238 constructions succeed because construction
    -- never touches pool.assets; the first assign_target after the collection dies.
    --
    -- Same keeper pattern as LocalPool's pin_texture, deliberately not a shared helper:
    -- the two pools own different widget trees and different image classes, and merging
    -- them would be a second change riding along with a crash fix.
    local function pin_asset(path, texture)
        if texture == nil or pool.pinned[path] ~= nil then return false end
        local frame = state.retained and state.retained.frame or nil
        if not valid(frame) or not valid(pool.image_class) then return false end
        local keeper = nil
        local ok = pcall(function()
            keeper = unwrap(StaticConstructObject(pool.image_class, frame,
                make_name("ObjectiveIconKeeper")))
            assert(valid(keeper), "objective keeper image construction failed")
            local slot = unwrap(frame:AddChildToCanvas(keeper))
            assert(valid(slot), "objective keeper slot failed")
            slot:SetPosition({ X = -10000, Y = -10000 })
            slot:SetSize({ X = 1, Y = 1 })
            keeper:SetVisibility(VIS_COLLAPSED)
            keeper:SetBrushFromTexture(texture, false)
        end)
        if not ok then
            if keeper ~= nil and valid(keeper) then pcall(keeper.RemoveFromParent, keeper) end
            pool.metrics.pin_failures = (pool.metrics.pin_failures or 0) + 1
            return false
        end
        pool.pinned[path] = { keeper = keeper, texture = texture }
        pool.metrics.pins = (pool.metrics.pins or 0) + 1
        return true
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

    -- SPLITTING THE SLICE. v0.23.41.
    --
    -- Her death-and-reload crash on v0.23.39 ends at "Work crumb step=objective.build-slice"
    -- with no -done, 0.3 ms after "Loading screen completed". 128 slices finished, the
    -- 129th died. v0.23.38's scheduler crumbs did their job and named the slice.
    --
    -- But invariant 0y says a crumb names a REGION when more than one engine call sits
    -- behind it, and this slice does two unrelated things: it CONSTRUCTS widgets, and then
    -- it calls runtime.UpdatePlayer over every entry. Those fail for different reasons and
    -- would need different fixes, so they get different crumbs rather than a guess.
    --
    -- Why UpdatePlayer is newly interesting at exactly this moment: state.map_center_world_x
    -- is written on the pose path, and the pose path does not run while the loading screen
    -- has the map hidden. So for all 128 earlier slices UpdatePlayer was handed nil and
    -- returned immediately. The first slice after the map became visible is the first one
    -- that ever walked the entries in this world.
    local function slice_crumb(name)
        if Config.LocalDiscoveryTrace == true then
            print("[MortalShell2Minimap] Objective crumb step=" .. tostring(name) .. "\n")
        end
    end

    -- INSIDE THE CONSTRUCTION, ONE ENGINE CALL AT A TIME. v0.23.44.
    --
    -- v0.23.41 split the slice and it worked on the first try: her fast-travel crash on
    -- v0.23.42 ends at "Objective crumb step=construct" with no -done, and the slice
    -- before it reads "update-player x=nil y=nil entries=64" -- which also confirms the
    -- prediction that UpdatePlayer is handed nil during a load and returns at once. So it
    -- is the construction, not the update.
    --
    -- Two theories died on the way here, both of which looked obvious:
    --   1. "The slice does not guard on state.built, so the frame is a dead wrapper."
    --      DEAD: DropWorldReferencesUnread sets state.retained = {} as well as
    --      state.built = false, so frame is NIL after a world drop, and valid(nil) is
    --      false rather than fatal.
    --   2. "Fast travel tore the tree down under it." DEAD: her log has a complete
    --      rebuild at 12:15:39.51 ("Ready nativeTiles=true"), 3.4 SECONDS before the
    --      crash. The frame was alive.
    --
    -- So "construct" is still a region -- two valid() checks, a StaticConstructObject, an
    -- AddChildToCanvas and the property writes -- and invariant 0y says name the call
    -- before fixing anything. These crumbs carry the entry INDEX, because "it dies on the
    -- first one" and "it dies on the sixty-fifth" are different bugs.
    local function construct_entry()
        local index = #pool.entries + 1
        slice_crumb("c-guard n=" .. tostring(index))
        local frame = state.retained and state.retained.frame or nil
        if not valid(frame) or not valid(pool.image_class) then
            return nil, "renderer-frame-or-image-class-unavailable"
        end
        slice_crumb("c-guard-done")
        local refs = {}
        local ok, build_error = pcall(function()
            slice_crumb("c-new")
            local image = unwrap(StaticConstructObject(
                pool.image_class, frame, make_name("Objective" .. tostring(index))))
            slice_crumb("c-new-done")
            assert(valid(image), "objective image construction failed index=" .. tostring(index))
            refs.image = image
            slice_crumb("c-slot")
            local slot = unwrap(frame:AddChildToCanvas(image))
            slice_crumb("c-slot-done")
            assert(valid(slot), "objective slot failed index=" .. tostring(index))
            refs.slot = slot
            slot:SetPosition({ X = -10000, Y = -10000 })
            slot:SetSize({ X = 1, Y = 1 })
            -- ABOVE THE FOG. v0.23.31.
            --
            -- HER REPORT: "I can't see icons inside of my peek hole or trail behind me,
            -- like enemies, items, etc. poi markers and local markers both. The only icon
            -- i do see rendered is the height indicator."
            --
            -- She is right and the Z orders say so plainly. The fog is layer A at 4 and
            -- layer B at 5 (Map/NativeWidget.lua), and these markers were sitting at 3, 4
            -- and 5 -- level with the fog or beneath it. Fog became default-ON in v0.23.x
            -- and quietly buried every marker with it; the height chevrons survived only
            -- because they happened to be parented higher.
            --
            -- Markers belong ON TOP of the fog, which is also her instruction: "they can
            -- sit on top like the elevation arrows do". What a marker means -- here is a
            -- thing, and how far away it is -- is not something fog should be able to
            -- swallow. Whether a marker should DIM with fog depth is a separate question
            -- and a separate change; this one only stops them being hidden outright.
            --
            -- Kept below Z_ARROW (10) so the player marker still wins, and below the
            -- labels (59/60) which have always drawn above everything.
            pcall(slot.SetZOrder, slot, 7)
            slice_crumb("c-visibility")
            image:SetVisibility(VIS_COLLAPSED)
            slice_crumb("c-done")
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
        -- v0.23.39. Only sight_only targets pay for this, so the common case -- a
        -- discovered POI, or any POI with fog off -- costs one boolean test. Culled
        -- before the projection, like the broad phase above it.
        if target.sight_only == true then
            local seen = fog_visibility(target.x, target.y)
            if seen <= 0.0 then
                set_mode(item, Projection.MODE_HIDDEN, false)
                set_visible(item, false)
                return true
            end
            set_item_opacity(item, seen)
        elseif item.opacity ~= nil and item.opacity ~= 1.0 then
            -- It stopped being sight-only (she discovered it, or turned fog off) and is
            -- still carrying the last fade it was drawn at. One write, once.
            set_item_opacity(item, 1.0)
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
        slice_crumb("construct")
        while built < CONSTRUCTION_BATCH and #pool.pending_targets > 0
            and #pool.entries < capacity() do
            local item, build_error = construct_entry()
            if item == nil then
                -- v0.23.5. "NOT YET" IS NOT "NEVER", and conflating them cost every POI
                -- icon on the map.
                --
                -- construct_entry returns this reason when the widget tree is mid-rebuild:
                -- state.retained.frame is replaced wholesale at the END of Build(), so for
                -- the moment in between there is no frame to parent an Image to. That is a
                -- transient state and the correct response is to come back next slice.
                --
                -- It used to latch build_blocked instead, and build_blocked is cleared
                -- ONLY by a world change -- so one unlucky slice during a rebuild removed
                -- every objective icon for the rest of the session, with no way back
                -- except reloading the game. Measured on her machine 2026-09-17:
                -- "desired=169 active=169 built=0 pending=169 buildFailures=1", three
                -- screenshots with no icons at all, and the fog filter wrongly suspected
                -- first because it was the newest thing.
                --
                -- This was always latent. Cutting the world-release settle from 5000 ms to
                -- 250 made it easy to hit, because builds now land in a busier window.
                if build_error == "renderer-frame-or-image-class-unavailable" then
                    pool.metrics.build_deferrals = (pool.metrics.build_deferrals or 0) + 1
                    break
                end
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
            -- First icon of this load. Stamp() on a key it already holds returns at once,
            -- so this costs one table index per icon built and nothing at all once the
            -- line has been reported.
            Timeline.Stamp("poi_first_icon")
        end
        local elapsed = (os.clock() - started) * 1000.0
        pool.metrics.build_cpu_ms = pool.metrics.build_cpu_ms + elapsed
        pool.metrics.max_build_slice_ms = math.max(pool.metrics.max_build_slice_ms, elapsed)
        if built > 0 then pool.metrics.builds = pool.metrics.builds + 1 end
        slice_crumb("construct-done")
        -- Crumbed with the arguments, because "UpdatePlayer was called with nil" and
        -- "UpdatePlayer was called and died" are the two readings this whole round is
        -- about, and the log should not need me to infer which.
        slice_crumb("update-player x=" .. tostring(state.map_center_world_x)
            .. " y=" .. tostring(state.map_center_world_y)
            .. " entries=" .. tostring(#pool.entries))
        runtime.UpdatePlayer(state.map_center_world_x, state.map_center_world_y)
        slice_crumb("update-player-done")
        -- Re-armed whether the slice built anything or deferred: a deferral that did not
        -- reschedule would be the same permanent stall wearing a different name.
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

        -- FOG SHOWS DISCOVERED POIs ONLY. v0.23.5, her decision 2026-09-17:
        -- "while in fog it only displays discovered poi, the discover poi can still use
        -- edge of frame, and we will always show user pins and death spoils."
        --
        -- This supersedes the design doc, which said fog would remove edge indicators
        -- entirely. It does not: an edge arrow for a POI you have already discovered gives
        -- nothing away, so the arrows stay and the FILTER does the work.
        --
        -- Fog forces DiscoveredOnly on for every category that has the setting at all,
        -- whatever the player set it to -- an undiscovered marker sitting on top of fog is
        -- the fog telling you what it is hiding. The two always-visible families need
        -- nothing here: death spoils and small beacons carry discovery_mode = "none" and
        -- never reach this branch, and user pins are the TrackerPool, a different module
        -- with no discovery gate of any kind.
        --
        -- The per-category setting is not overwritten, only overridden while fog is on, so
        -- turning fog off gives every category back exactly what she chose.
        local fog_on = type(ctx.Fog) == "table" and type(ctx.Fog.Enabled) == "function"
            and ctx.Fog.Enabled() == true

        -- v0.23.39 SUPERSEDES THE PARAGRAPH ABOVE, and it is her spec of 2026-09-17:
        -- "POI under the icons tab, if it can be discovered only then enforce it, the
        -- exception is user pins and death spoils. If it can be discovered hidden and it
        -- hasn't been discovered then it shouldn't be shown unless you're within reveal
        -- distance. If it can't be discovered hidden and it hasn't been discovered then
        -- it will be the same thing, won't be shown until within reveal distance."
        --
        -- So the two discovery modes stop disagreeing about the undiscovered case. With
        -- fog on, whatever the mode:
        --   DISCOVERED   -> shown, and EXEMPT from the fog fade. Her words: "Exempt,
        --                   still follow frame edge fading logic just like if you were
        --                   not in a fogged area." A discovered POI is map knowledge, not
        --                   eyesight, so edge indicators keep working at any range.
        --   UNDISCOVERED -> sight only: shown within the reveal radius and the trail, at
        --                   fog opacity, and not at all beyond it.
        --
        -- What CHANGED in each direction, because it is not symmetric:
        --   "only" categories (Hub, Dungeon, EvilStatue, MapStation) previously had
        --   DiscoveredOnly FORCED on by fog, so an undiscovered one was hidden even while
        --   she stood on top of it. That is now a reveal-distance rule instead: walk into
        --   it and you see it.
        --   "hidden" categories (Shell, Sidearm, Weapon) had no fog rule at all, so an
        --   undiscovered pickup drew map-wide through the fog. That was the leak behind
        --   "too many icons showing up in the fog", and it is closed.
        --
        -- Untouched: DiscoveredHidden still hides a pickup once she has taken it, which
        -- is a different question from what fog conceals. And categories with no
        -- discovery concept at all -- death spoils, small beacons -- never enter this
        -- branch, exactly as before; user pins are TrackerPool and have no gate anywhere.
        local sight_only = false
        if fog_on then
            if discovery_mode ~= "none" and not discovered then sight_only = true end
            if discovery_mode == "hidden" then
                local discovered_hidden = config_value(
                    category, "DiscoveredHidden", category.discovery_default == true) == true
                if discovered_hidden and discovered then return nil end
            end
        elseif discovery_mode == "only" then
            local discovered_only = config_value(category, "DiscoveredOnly",
                category.discovery_default == true) == true
            if discovered_only and not discovered then return nil end
        elseif discovery_mode == "hidden" then
            local discovered_hidden = config_value(
                category, "DiscoveredHidden", category.discovery_default == true) == true
            if discovered_hidden and discovered then return nil end
        end
        -- A marker the fog has fully hidden is not built at all. Checked here, in the
        -- same pass that already has the record, rather than per frame in the update.
        if sight_only and fog_visibility(record.world_x, record.world_y) <= 0.0 then
            return nil
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
        -- EDGE INDICATORS STAY ON UNDER FOG. Her decision, 2026-09-17, superseding the
        -- design doc's "with fog on there are no edge-of-frame icons at all": that idea
        -- was dropped. A POI that fog lets you see at all is a POI you have discovered,
        -- and an edge indicator for something you already know about gives nothing away.
        -- The filtering is done by DISCOVERY, below, not by hiding the arrows.
        local edge_enabled = config_value(
            category, "EdgeIndicators", category.edge) == true
        local edge_max_distance = tonumber(config_value(
            category, "EdgeMaxDistance", category.edge_max_distance))
        local edge_min_scale = tonumber(config_value(
            category, "EdgeMinScale", category.edge_min_scale))
        local base_width, base_height = IconResolver.FitSize(texture_path, base_size)
        if base_width == nil or base_height == nil then return nil end
        local presentation_signature = table.concat({
            -- v0.23.39: in the signature so that discovering a POI, which flips it from
            -- sight-only to exempt, counts as a presentation change rather than a target
            -- that merely looks the same as the one already on screen.
            tostring(sight_only),
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
            -- v0.23.39. True only for an UNDISCOVERED POI under fog: the one family whose
            -- presence is eyesight rather than map knowledge, and so the only one the fog
            -- fade touches. A discovered POI never carries this and is never faded.
            sight_only = sight_only,
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
            Timeline.Stamp("poi_assets")
            log(string.format(
                "Objective pool assets ready exact=%d/%d failures=%d cap=%d slicedLoads=true cdoReads=0 softWrapperReads=0",
                available, #paths, pool.metrics.asset_failures, capacity()))
            runtime.SyncObjectives(type(state.poi) == "table" and state.poi.records or nil)
            return
        end
        -- As many as fit in ASSET_BUDGET_MS, not exactly one. See the constant above:
        -- the 30 ms delay was sized for a texture that needs a disk load and was paid on
        -- every texture, including the resident ones that cost a fraction of a
        -- millisecond. Residents now fly through many per step and a real load takes its
        -- step alone. Same per-frame ceiling, roughly half the wall clock.
        local step_started = os.clock()
        -- v0.23.57: PREDICT the next load rather than discovering afterwards that it did
        -- not fit. The `until` below tested time ALREADY SPENT, so every step ran to its
        -- 8 ms budget and then paid for one more load on top -- and "a real load takes its
        -- step alone" means that one can be twenty milliseconds of disk. Her session
        -- measured this slice at avg 22.88 ms against the 8 ms budget, max 51, while she
        -- was feeling "a hitch every 2-3 seconds" at 77 fps (a 13 ms frame).
        --
        -- The estimate decays, so one slow texture cannot make every later step timid.
        -- repeat/until still runs at least one load per step, so the chain always advances
        -- and the resolve always terminates.
        local expected = pool.asset_step_cost_ms or 0.0
        repeat
            local path = paths[index]
            local started = os.clock()
            local asset, status = load_exact_asset(path)
            local elapsed = (os.clock() - started) * 1000.0
            pool.metrics.asset_attempts = pool.metrics.asset_attempts + 1
            pool.metrics.asset_cpu_ms = pool.metrics.asset_cpu_ms + elapsed
            -- Pinned BEFORE it is stored, so nothing is ever in pool.assets without an
            -- owner -- not even for one frame, which is all a collection needs.
            if asset ~= nil then pin_asset(path, asset) end
            pool.assets[path] = asset
            pool.asset_status[path] = status
            if status == "resident" then
                pool.metrics.asset_resident = pool.metrics.asset_resident + 1
            elseif status == "loaded" then
                pool.metrics.asset_loaded = pool.metrics.asset_loaded + 1
            else
                pool.metrics.asset_failures = pool.metrics.asset_failures + 1
            end
            expected = elapsed > expected and elapsed or (expected * 0.90)
            index = index + 1
        until index > #paths
            or ((os.clock() - step_started) * 1000.0 + expected) >= ASSET_BUDGET_MS
        pool.asset_step_cost_ms = expected
        WorkBudget.Schedule(ASSET_DELAY_MS, function()
            resolve_assets_step(paths, index, token, generation)
        end, "objective.asset-step")
    end

    function runtime.OnRendererReady()
        -- v0.23.5: a NEW widget tree, so whatever blocked construction against the old
        -- one is not evidence about this one. Cleared before the early return below,
        -- because on a rebuild `ready` is already true and the early return is the path
        -- that runs -- which is exactly how a latched block used to survive a rebuild
        -- that had just fixed the thing it was latched on.
        if pool.build_blocked then
            pool.build_blocked = false
            pool.metrics.build_unblocks = (pool.metrics.build_unblocks or 0) + 1
            log("Objective pool construction unblocked by a fresh widget tree; "
                .. tostring(#pool.pending_targets) .. " icon(s) still pending")
        end
        if pool.ready and #pool.pending_targets > 0 then arm_pending_build() end
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
        -- The keepers live in the widget tree that is going away, so their pins die with
        -- it. Keeping the handles would be keeping pointers to objects with no owner --
        -- exactly the bug this table exists to prevent (Map/FogLayer.lua DropTarget says
        -- the same thing about its texture cache, for the same reason).
        pool.pinned = {}
        pool.asset_status = {}
        pool.asset_step_cost_ms = 0.0
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
            "Objective pool summary reason=%s ready=%s cap=%d desired=%d active=%d built=%d visible=%d pending=%d overflow=%d categories=%s assets=%d resident=%d loaded=%d assetFailures=%d assetPins=%d assetCpuMs=%.3f buildSlices=%d buildFailures=%d buildCpuMs=%.3f maxBuildSliceMs=%.3f syncs=%d syncRequests=%d syncCoalesced=%d positionWrites=%d positionSkips=%d sizeWrites=%d visibilityWrites=%d textureWrites=%d onMapUpdates=%d persistentUpdates=%d hiddenUpdates=%d modeTransitions=%d edgeVisibility=%d%% exactPaths=true directSlots=true",
            tostring(reason or "manual"), tostring(pool.ready), capacity(),
            pool.desired_count, pool.active_count, #pool.entries, visible_count(),
            #pool.pending_targets, pool.overflow_count,
            table.concat(category_text, "|"), metrics.asset_attempts,
            metrics.asset_resident, metrics.asset_loaded, metrics.asset_failures,
            -- v0.23.53. THE FIX'S OWN COUNTER, WHICH NOTHING EVER PRINTED.
            --
            -- v0.23.46 pinned every icon texture through a collapsed keeper -- the fix for
            -- the fast-travel crash -- and counted every pin into metrics.pins. That number
            -- went nowhere. So after a clean fast-travel test the evidence was "nothing
            -- crashed", which is also what a fix that never ran looks like on a run that
            -- happened not to collect. A fix whose instrument is invisible is a fix nobody
            -- can confirm, only hope about.
            metrics.pins or 0,
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
