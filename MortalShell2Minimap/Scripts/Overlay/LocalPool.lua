-- Capped plain-UImage pool for event-discovered local interactables.
-- Targets are primitive records supplied by Local.Discovery. The pool performs
-- no UObject discovery and no world scan; it only projects the bounded active set.
-- Texture lifetime (v0.10.13/v0.10.14): a cached wrapper to a texture nothing
-- references can be garbage-collected and then read from scheduled work, which
-- is the v0.10.9 crash family. v0.10.13 therefore re-found every texture with
-- StaticFindObject at brush-write time, but that costs ~3 ms per call in UE4SS
-- (the v0.10.13 run: buildCpuMs 712 vs 2, one 78 ms slice). v0.10.14 pins each
-- resolved texture with a collapsed "keeper" UImage of our own whose brush holds
-- the engine reference; the cached wrapper is then as safe as our own widgets and
-- is dropped unread with them at LoadMap PRE. Unpinned paths fall back to the
-- v0.10.13 fresh lookup. Icons keep their native aspect ratio.

local Factory = {}

function Factory.New(ctx)
    local state = assert(ctx.State, "Overlay.LocalPool requires State")
    local Config = assert(ctx.Config, "Overlay.LocalPool requires Config")
    local Object = assert(ctx.Object, "Overlay.LocalPool requires Core.Object")
    local Projection = assert(ctx.TrackerProjection, "Overlay.LocalPool requires Overlay.TrackerProjection")
    local Classifier = assert(ctx.LocalClassifier, "Overlay.LocalPool requires Local.Classifier")
    local WorkBudget = assert(ctx.WorkBudget, "Overlay.LocalPool requires Runtime.WorkBudget")
    local log = assert(ctx.Log, "Overlay.LocalPool requires Log")
    local Perf = type(ctx.Perf) == "table" and ctx.Perf
        or { Begin = function() return nil end, End = function() end, Count = function() end }

    -- v0.11.3 crash breadcrumb, same key as Local/Discovery.lua. The 2026-09-12
    -- access violations were entered through UE4SS's Lua dispatcher with the last
    -- discovery breadcrumb already complete, so the next thing to run -- this pool's
    -- scheduled widget construction, fed by a burst of thirty enemy records -- has to
    -- leave a trail too. Coarse on purpose: a few lines per sync, not per item.
    local function trace(phase, extra)
        if Config.LocalDiscoveryTrace == false then return end
        log("Local pool trace phase=" .. tostring(phase)
            .. (extra ~= nil and (" " .. tostring(extra)) or ""))
    end
    local unwrap, valid = Object.Unwrap, Object.Valid

    local IMAGE_CLASS_PATH = "/Script/UMG.Image"
    -- v0.11.0 decorations. The plate is a soft black smoke disc drawn under an icon
    -- for legibility (the game does the same behind its night-mode moon); the chevron
    -- marks a marker that is well above or below the player.
    local PLATE_SCALE = 1.75
    -- v0.18.1: the chevron's size is a row (LocalHeightMarkerSize, percent of the icon;
    -- 60 is the old fixed 0.62); see chevron_scale below.
    local WHITE_TINT = { R = 1.0, G = 1.0, B = 1.0, A = 1.0 }
    local VIS_COLLAPSED = 1
    local VIS_HIT_TEST_INVISIBLE = 3
    local POSITION_EPSILON_SQ = 0.001 * 0.001
    local CONSTRUCTION_BATCH = 4
    local CONSTRUCTION_DELAY_MS = 50
    local ASSET_DELAY_MS = 30
    local RESELECT_MOVE_EPSILON_SQ = 1000.0 * 1000.0 -- 10 m; primitive-only reselection

    state.local_pool = state.local_pool or {
        entries = {}, by_record = {}, pending_targets = {}, asset_ok = {},
        ready = false, dependency_started = false, build_blocked = false,
        image_class = nil, active_count = 0, desired_count = 0, overflow_count = 0,
        build_token = 0, sync_token = 0, sync_pending = false,
        selection_center_x = nil, selection_center_y = nil, reselecting = false,
        metrics = {
            asset_attempts = 0, asset_resident = 0, asset_loaded = 0,
            asset_failures = 0, asset_cpu_ms = 0.0,
            tint_writes = 0, plate_writes = 0, chevron_writes = 0,
            plates_built = 0, chevrons_built = 0, decoration_failures = 0,
            opacity_writes = 0, faded_markers = 0,
            texture_finds = 0, texture_reloads = 0, texture_fallbacks = 0,
            build_slices = 0, build_failures = 0, images_constructed = 0,
            build_cpu_ms = 0.0, max_build_slice_ms = 0.0,
            syncs = 0, sync_requests = 0, sync_coalesced = 0,
            eligible_seen = 0, overflow_dropped = 0,
            range_prefilter_rejects = 0, movement_reselections = 0,
            position_writes = 0, position_skips = 0,
            size_writes = 0, visibility_writes = 0, texture_writes = 0,
            update_calls = 0, update_runs = 0, entries_examined = 0,
            broad_phase_rejects = 0, projections_executed = 0,
            update_cpu_ms = 0.0, max_update_cpu_ms = 0.0, update_timing_samples = 0,
        },
    }
    local pool = state.local_pool
    -- v0.10.12 and earlier kept texture wrappers in pool.assets; drop any left
    -- over from a hot reload so nothing can read them.
    pool.assets = nil
    pool.asset_ok = pool.asset_ok or {}
    -- path -> { keeper = own collapsed UImage, texture = wrapper pinned by it }
    pool.pinned = pool.pinned or {}
    for key, value in pairs({ texture_finds = 0, texture_reloads = 0, texture_fallbacks = 0,
        texture_pinned_hits = 0, pin_failures = 0, tint_writes = 0, plate_writes = 0,
        chevron_writes = 0, plates_built = 0, chevrons_built = 0, decoration_failures = 0,
        opacity_writes = 0, faded_markers = 0 }) do
        if pool.metrics[key] == nil then pool.metrics[key] = value end
    end

    local function capacity()
        return math.max(8, math.min(64,
            math.floor(tonumber(Config.LocalInteractableBudget) or 32)))
    end

    local function marker_size()
        return math.max(12, math.min(48,
            math.floor(tonumber(Config.LocalInteractableIconSize) or 18)))
    end

    -- Per-category multiplier on the shared marker size. `LocalInteractableIconSize`
    -- is one number for every local icon, which is what the user ran into when
    -- shrinking bear traps shrank everything; this is the per-icon dimension.
    local function category_scale(category)
        local key = tostring(category or "")
        local override = tonumber(Config["LocalIconScale" .. key])
        local scale = override
        if scale == nil and type(Classifier.CategoryScale) == "function" then
            scale = Classifier.CategoryScale(key)
        end
        return math.max(0.25, math.min(2.0, tonumber(scale) or 1.0))
    end

    -- v0.17.0: the art a category draws with comes from the LOCAL tab's icon and
    -- color rows, resolved once per category and kept until a local-presentation
    -- change; a record's own texture_path is only the fallback for a category the
    -- Classifier does not know. Every candidate texture is in Classifier.Paths(), so
    -- the choice never waits on a load.
    local art_cache = {}
    local function category_art(category, record)
        local key = tostring(category or "")
        local cached = art_cache[key]
        if cached ~= nil then return cached end
        local path, tint = nil, nil
        if type(Classifier.ResolveArt) == "function" then
            path, tint = Classifier.ResolveArt(key, Config["LocalIcon" .. key], Config["LocalIconColor" .. key])
        end
        if path == nil then
            path = type(record) == "table" and record.texture_path or nil
            tint = type(record) == "table" and record.tint or nil
        end
        cached = { path = path, tint = tint }
        art_cache[key] = cached
        return cached
    end
    local function invalidate_art() art_cache = {} end

    local function plates_enabled()
        return Config.LocalIconPlates == true and pool.asset_ok[Classifier.PlateIconPath] == true
    end

    local function height_markers_enabled()
        return Config.LocalHeightMarkers == true
            and pool.asset_ok[Classifier.ChevronIconPath] == true
    end

    -- Centimetres of height difference before a marker is called above/below.
    local function height_threshold()
        return 100.0 * math.max(1.0, math.min(50.0,
            tonumber(Config.LocalHeightThresholdMeters) or 3.0))
    end

    -- v0.18.1: the chevron's box as a fraction of the icon's.
    local function chevron_scale()
        return math.max(0.25, math.min(2.0,
            (tonumber(Config.LocalHeightMarkerSize) or 60) / 100.0))
    end

    local function fraction(value, default)
        return math.max(0.10, math.min(1.0, (tonumber(value) or default) / 100.0))
    end

    -- v0.18.1 height fade (user request 2026-09-14: "if the object is above me the
    -- icon on the map would be a little bit transparent ... more transparent the
    -- further above/below it is, stopping at a % point so its not invisible").
    -- Opacity for a marker |delta| cm from the player's height: 1 below the
    -- threshold; FadeStart at it; down to FadeMin over FadeRange metres beyond it;
    -- FadeMin from there on. Quantised to whole percent so a marker that drifts a
    -- few centimetres does not rewrite its opacity every frame.
    local function height_fade(delta_abs)
        if Config.LocalHeightFade == false or delta_abs == nil then return 1.0 end
        local threshold = height_threshold()
        if delta_abs < threshold then return 1.0 end
        local start = fraction(Config.LocalHeightFadeStart, 75)
        local floor = math.min(start, fraction(Config.LocalHeightFadeMin, 35))
        local range = 100.0 * math.max(1.0, math.min(100.0, tonumber(Config.LocalHeightFadeRange) or 15))
        local t = math.min(1.0, (delta_abs - threshold) / range)
        local opacity = start + (floor - start) * t
        return math.floor(opacity * 100.0 + 0.5) / 100.0
    end

    -- One opacity for the icon and whichever decorations it has. Written only on a
    -- change; a decoration built after the icon faded catches up in place_decoration.
    local function write_opacity(holder, image, opacity)
        if holder == nil or holder.opacity == opacity or not valid(image) then return false end
        if pcall(image.SetRenderOpacity, image, opacity) then
            holder.opacity = opacity
            pool.metrics.opacity_writes = pool.metrics.opacity_writes + 1
            return true
        end
        return false
    end

    local function set_item_opacity(item, opacity)
        write_opacity(item, item.refs.image, opacity)
        local plate, chevron = item.refs.plate, item.refs.chevron
        if plate ~= nil then write_opacity(plate, plate.image, opacity) end
        if chevron ~= nil then write_opacity(chevron, chevron.image, opacity) end
    end

    local function current_center()
        if state.area_map_available == false then
            return tonumber(state.player_world_x), tonumber(state.player_world_y)
        end
        return tonumber(state.map_center_world_x) or tonumber(state.player_world_x),
            tonumber(state.map_center_world_y) or tonumber(state.player_world_y)
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

    local function set_visible(item, visible)
        visible = visible == true
        if item.visible == visible then return true end
        if not valid(item.refs.image) then return false end
        local ok = pcall(item.refs.image.SetVisibility, item.refs.image,
            visible and VIS_HIT_TEST_INVISIBLE or VIS_COLLAPSED)
        if ok then
            item.visible = visible
            pool.metrics.visibility_writes = pool.metrics.visibility_writes + 1
        end
        return ok
    end

    -- Texture for immediate use. Pinned textures come from the keeper table;
    -- anything else is looked up fresh and must not be stored by the caller.
    local function fetch_texture(path)
        local pin = pool.pinned[path]
        if pin ~= nil then
            pool.metrics.texture_pinned_hits = pool.metrics.texture_pinned_hits + 1
            return pin.texture
        end
        pool.metrics.texture_finds = pool.metrics.texture_finds + 1
        local object = find_object(path)
        if object ~= nil then return object end
        if type(LoadAsset) == "function" then
            pool.metrics.texture_reloads = pool.metrics.texture_reloads + 1
            local token = Perf.Begin()
            pcall(LoadAsset, path)
            Perf.End("native.load", token)
            object = find_object(path)
        end
        return object
    end

    -- Fit the icon's native shape inside a size x size square.
    local function fitted(item, size)
        local nw, nh = tonumber(item.native_w) or 1, tonumber(item.native_h) or 1
        if nw <= 0 or nh <= 0 then nw, nh = 1, 1 end
        local longest = math.max(nw, nh)
        return size * nw / longest, size * nh / longest
    end

    local function set_size(item, size)
        size = tonumber(size)
        if size == nil or size <= 0 then return false end
        if item.last_size == size then return true end
        if not valid(item.refs.slot) then return false end
        item.size_value.X, item.size_value.Y = fitted(item, size)
        local ok = pcall(item.refs.slot.SetSize, item.refs.slot, item.size_value)
        if ok then
            item.last_size = size
            pool.metrics.size_writes = pool.metrics.size_writes + 1
        end
        return ok
    end

    -- Forward declaration: clear_target runs before the decoration helpers exist.
    local hide_decorations

    local function clear_target(item)
        if type(item.target) == "table" and item.target.record_id ~= nil then
            pool.by_record[item.target.record_id] = nil
        end
        item.target = nil
        item.last_x, item.last_y, item.last_size = nil, nil, nil
        set_visible(item, false)
        hide_decorations(item)
    end

    local function assign_target(item, target)
        local changed = type(item.target) ~= "table"
            or item.target.record_id ~= target.record_id
            or item.target.texture_path ~= target.texture_path
        if item.texture_path ~= target.texture_path then
            if not valid(item.refs.image) then return false end
            local path = target.texture_path
            local texture = fetch_texture(path)
            if texture == nil and path ~= Classifier.GenericIconPath then
                -- Unpinned category art vanished since resolution: fall back for good.
                pool.asset_ok[path] = false
                pool.metrics.texture_fallbacks = pool.metrics.texture_fallbacks + 1
                path = Classifier.GenericIconPath
                target.texture_path = path
                if item.texture_path ~= path then texture = fetch_texture(path) end
            end
            if item.texture_path ~= path then
                if texture == nil then return false end
                local ok = pcall(item.refs.image.SetBrushFromTexture, item.refs.image, texture, false)
                texture = nil
                if not ok then return false end
                item.texture_path = path
                item.native_w, item.native_h = Classifier.IconSize(path)
                item.last_size = nil
                pool.metrics.texture_writes = pool.metrics.texture_writes + 1
            end
        end
        -- Category tint (multiply). The enemy dot is white art tinted red.
        local tint = target.tint
        local tint_key = tint ~= nil
            and string.format("%.3f,%.3f,%.3f", tint.R or 1, tint.G or 1, tint.B or 1) or "white"
        if item.tint_key ~= tint_key and valid(item.refs.image) then
            if pcall(item.refs.image.SetColorAndOpacity, item.refs.image, tint or WHITE_TINT) then
                item.tint_key = tint_key
                pool.metrics.tint_writes = pool.metrics.tint_writes + 1
            end
        end
        item.target = target
        pool.by_record[target.record_id] = item
        if changed then item.last_x, item.last_y, item.last_size = nil, nil, nil end
        return true
    end

    -- A collapsed image of our own whose brush references the texture, so the
    -- engine cannot collect it while this world's widgets exist.
    local function pin_texture(path, texture)
        local frame = state.retained and state.retained.frame or nil
        if texture == nil or not valid(frame) or not valid(pool.image_class) then return false end
        local keeper = nil
        local ok = pcall(function()
            keeper = unwrap(StaticConstructObject(pool.image_class, frame,
                make_name("LocalIconKeeper")))
            assert(valid(keeper), "keeper image construction failed")
            local slot = unwrap(frame:AddChildToCanvas(keeper))
            assert(valid(slot), "keeper slot failed")
            slot:SetPosition({ X = -10000, Y = -10000 })
            slot:SetSize({ X = 1, Y = 1 })
            keeper:SetVisibility(VIS_COLLAPSED)
            keeper:SetBrushFromTexture(texture, false)
        end)
        if not ok then
            if keeper ~= nil and valid(keeper) then pcall(keeper.RemoveFromParent, keeper) end
            pool.metrics.pin_failures = pool.metrics.pin_failures + 1
            return false
        end
        pool.pinned[path] = { keeper = keeper, texture = texture }
        return true
    end

    -- Decorations are built only when a record first needs one, so a run without
    -- plates or height markers pays nothing. They are our own widgets, parented to
    -- the retained frame exactly like the markers, and dropped with them.
    local function ensure_decoration(item, kind)
        local existing = item.refs[kind]
        if existing ~= nil then return valid(existing.image) and existing or nil end
        local frame = state.retained and state.retained.frame or nil
        if not valid(frame) or not valid(pool.image_class) then return nil end
        local path, native_w, native_h = Classifier.Decoration(kind == "plate" and "Plate" or "Chevron")
        local texture = path ~= nil and fetch_texture(path) or nil
        if texture == nil then
            pool.metrics.decoration_failures = pool.metrics.decoration_failures + 1
            return nil
        end
        local refs = {}
        local ok, err = pcall(function()
            local image = unwrap(StaticConstructObject(pool.image_class, frame,
                make_name((kind == "plate" and "LocalPlate" or "LocalChevron")
                    .. tostring(item.index))))
            assert(valid(image), "decoration image construction failed")
            refs.image = image
            local slot = unwrap(frame:AddChildToCanvas(image))
            assert(valid(slot), "decoration slot failed")
            refs.slot = slot
            slot:SetPosition({ X = -10000, Y = -10000 })
            slot:SetSize({ X = 1, Y = 1 })
            pcall(slot.SetZOrder, slot, kind == "plate" and 3 or 5)
            image:SetVisibility(VIS_COLLAPSED)
            image:SetBrushFromTexture(texture, false)
        end)
        texture = nil
        if not ok then
            if refs.image ~= nil and valid(refs.image) then
                pcall(refs.image.RemoveFromParent, refs.image)
            end
            pool.metrics.decoration_failures = pool.metrics.decoration_failures + 1
            log("Local decoration construction failed kind=" .. tostring(kind)
                .. " error=" .. tostring(err))
            return nil
        end
        refs.native_w, refs.native_h = native_w or 1, native_h or 1
        refs.visible, refs.angle, refs.opacity = false, nil, 1.0
        refs.position_value = { X = -10000, Y = -10000 }
        refs.size_value = { X = 1, Y = 1 }
        item.refs[kind] = refs
        if kind == "plate" then pool.metrics.plates_built = pool.metrics.plates_built + 1
        else pool.metrics.chevrons_built = pool.metrics.chevrons_built + 1 end
        return refs
    end

    local function set_decoration_visible(refs, visible)
        if refs == nil then return end
        visible = visible == true
        if refs.visible == visible then return end
        if not valid(refs.image) then return end
        if pcall(refs.image.SetVisibility, refs.image,
            visible and VIS_HIT_TEST_INVISIBLE or VIS_COLLAPSED) then
            refs.visible = visible
        end
    end

    hide_decorations = function(item)
        set_decoration_visible(item.refs.plate, false)
        set_decoration_visible(item.refs.chevron, false)
    end

    -- Centre-anchored placement for a decoration, aspect-fitted like the markers.
    local function place_decoration(refs, center_x, center_y, box, angle)
        if refs == nil or not valid(refs.slot) then return false end
        local nw = tonumber(refs.native_w) or 1
        local nh = tonumber(refs.native_h) or 1
        local longest = math.max(nw, nh)
        local w, h = box * nw / longest, box * nh / longest
        refs.size_value.X, refs.size_value.Y = w, h
        refs.position_value.X, refs.position_value.Y = center_x - w / 2.0, center_y - h / 2.0
        local ok = pcall(refs.slot.SetSize, refs.slot, refs.size_value)
            and pcall(refs.slot.SetPosition, refs.slot, refs.position_value)
        if ok and angle ~= nil and refs.angle ~= angle then
            if pcall(refs.image.SetRenderTransformAngle, refs.image, angle) then
                refs.angle = angle
            end
        end
        return ok
    end

    local function construct_entry()
        local frame = state.retained and state.retained.frame or nil
        if not valid(frame) or not valid(pool.image_class) then
            return nil, "renderer-frame-or-image-class-unavailable"
        end
        local index = #pool.entries + 1
        local refs = {}
        -- v0.18.29: per-call breadcrumbs. Her two reproducible crashes both fault inside
        -- UE4SS's reflection path with the pool building in the same slice, and "coarse on
        -- purpose" is exactly what stops this file naming the call. These are five lines
        -- per constructed image, only while LocalDiscoveryTrace is on.
        local ok, err = pcall(function()
            trace("construct-new", "index=" .. tostring(index))
            local image = unwrap(StaticConstructObject(pool.image_class, frame,
                make_name("LocalInteractable" .. tostring(index))))
            assert(valid(image), "local interactable image construction failed")
            refs.image = image
            trace("construct-canvas", "index=" .. tostring(index))
            local slot = unwrap(frame:AddChildToCanvas(image))
            assert(valid(slot), "local interactable canvas slot failed")
            refs.slot = slot
            trace("construct-slot", "index=" .. tostring(index))
            slot:SetPosition({ X = -10000, Y = -10000 })
            slot:SetSize({ X = 1, Y = 1 })
            pcall(slot.SetZOrder, slot, 4)
            trace("construct-visibility", "index=" .. tostring(index))
            image:SetVisibility(VIS_COLLAPSED)
            trace("construct-done", "index=" .. tostring(index))
        end)
        if not ok then
            if valid(refs.image) then pcall(refs.image.RemoveFromParent, refs.image) end
            return nil, tostring(err)
        end
        local item = {
            index = index, refs = refs, target = nil, visible = false,
            texture_path = nil, native_w = 1, native_h = 1, tint_key = nil,
            last_x = nil, last_y = nil, last_size = nil, opacity = 1.0,
            position_value = { X = -10000, Y = -10000 }, size_value = { X = 1, Y = 1 },
            write_error_logged = false,
        }
        pool.entries[index] = item
        return item
    end

    local function eligible_target(record, player_x, player_y, radius_sq)
        if Config.ShowLocalInteractables ~= true or type(record) ~= "table"
            or tonumber(record.x) == nil or tonumber(record.y) == nil
            or type(record.texture_path) ~= "string" then return nil end
        -- v0.10.11: only while interactable and visible, and only if the user
        -- has not switched the category off (LOCAL -> Local category).
        if record.suppressed == true then
            pool.metrics.suppressed_rejects = (pool.metrics.suppressed_rejects or 0) + 1
            return nil, "suppressed"
        end
        if Config["LocalShow" .. tostring(record.category or "")] == false then
            pool.metrics.category_rejects = (pool.metrics.category_rejects or 0) + 1
            return nil, "category-off"
        end
        local art = category_art(record.category, record)
        local texture_path = art.path or record.texture_path
        if pool.asset_ok[texture_path] ~= true then texture_path = Classifier.GenericIconPath end
        if pool.asset_ok[texture_path] ~= true then return nil end
        local record_x, record_y = tonumber(record.x), tonumber(record.y)
        local dx = player_x ~= nil and (record_x - player_x) or 0.0
        local dy = player_y ~= nil and (record_y - player_y) or 0.0
        local distance_sq = player_x ~= nil and (dx * dx + dy * dy) or math.huge
        if radius_sq ~= nil and distance_sq > radius_sq then
            return nil, "out-of-range"
        end
        return {
            record_id = record.id,
            x = record_x, y = record_y, z = tonumber(record.z),
            category = tostring(record.category or "Unknown"),
            priority = tonumber(record.priority) or 100,
            distance_sq = distance_sq,
            texture_path = texture_path,
            tint = type(art.tint) == "table" and art.tint or nil,
        }
    end

    -- Runs only when the marker itself moved, so decorations cost nothing while the
    -- map is still. center_x/center_y are the icon's centre in frame space.
    local function update_decorations(item, center_x, center_y, box)
        local target = item.target
        if plates_enabled() and Config["LocalPlate" .. tostring(target.category or "")] ~= false then
            local plate = ensure_decoration(item, "plate")
            if plate ~= nil and place_decoration(plate, center_x, center_y, box * PLATE_SCALE) then
                pool.metrics.plate_writes = pool.metrics.plate_writes + 1
                set_decoration_visible(plate, true)
            else
                set_decoration_visible(item.refs.plate, false)
            end
        else
            set_decoration_visible(item.refs.plate, false)
        end

        local player_z = tonumber(state.player_world_z)
        local target_z = tonumber(target.z)
        local delta = (height_markers_enabled() and player_z ~= nil and target_z ~= nil)
            and (target_z - player_z) or nil
        local opacity = 1.0
        if delta ~= nil and math.abs(delta) >= height_threshold() then
            local chevron = ensure_decoration(item, "chevron")
            -- T_UI_InteractIndicator points down; 180 degrees turns it into "above".
            local angle = delta > 0 and 180.0 or 0.0
            local scale = chevron_scale()
            -- The arrow's inner edge stays 0.31 box from the icon's centre, whatever
            -- its size (the v0.11.0 placement at the old fixed 0.62 scale).
            local offset = box * (0.31 + scale * 0.5)
            if chevron ~= nil and place_decoration(chevron, center_x,
                center_y + (delta > 0 and -offset or offset), box * scale, angle) then
                pool.metrics.chevron_writes = pool.metrics.chevron_writes + 1
                set_decoration_visible(chevron, true)
            else
                set_decoration_visible(item.refs.chevron, false)
            end
            opacity = height_fade(math.abs(delta))
            if opacity < 1.0 then pool.metrics.faded_markers = pool.metrics.faded_markers + 1 end
        else
            set_decoration_visible(item.refs.chevron, false)
        end
        -- v0.18.1: icon, plate and chevron fade together past the threshold.
        set_item_opacity(item, opacity)
    end

    local function update_entry(item, player_x, player_y, context, size, radius_sq)
        local target = item.target
        if type(target) ~= "table" then return true end
        pool.metrics.entries_examined = pool.metrics.entries_examined + 1
        local dx, dy = target.x - player_x, target.y - player_y
        if radius_sq ~= nil and dx * dx + dy * dy > radius_sq then
            pool.metrics.broad_phase_rejects = pool.metrics.broad_phase_rejects + 1
            set_visible(item, false)
            hide_decorations(item)
            return true
        end
        pool.metrics.projections_executed = pool.metrics.projections_executed + 1
        local x, y, _, _, _, display_visible, _, _, mode, rendered_size =
            Projection.PositionPrepared(context, player_x, player_y,
                target.x, target.y, size, false, 0, 1.0, size, size)
        if x == nil or mode == nil or rendered_size == nil then return false end
        if not display_visible then
            set_visible(item, false)
            hide_decorations(item)
            return true
        end
        -- The category multiplier shrinks the artwork inside the projected square, so
        -- the marker stays exactly where the projection put it.
        local drawn_size = rendered_size * category_scale(target.category)
        if not set_size(item, drawn_size) then
            set_visible(item, false)
            hide_decorations(item)
            return false
        end
        -- Projection returns the top-left of the size x size square; recenter the
        -- aspect-fitted artwork inside it (as ObjectivePool v0.9.7).
        local fit_w, fit_h = fitted(item, drawn_size)
        x = x + (rendered_size - fit_w) / 2.0
        y = y + (rendered_size - fit_h) / 2.0
        local ddx = item.last_x ~= nil and x - item.last_x or 0.0
        local ddy = item.last_y ~= nil and y - item.last_y or 0.0
        if item.last_x ~= nil and ddx * ddx + ddy * ddy < POSITION_EPSILON_SQ then
            pool.metrics.position_skips = pool.metrics.position_skips + 1
            return set_visible(item, true)
        end
        item.position_value.X, item.position_value.Y = x, y
        local ok = pcall(item.refs.slot.SetPosition, item.refs.slot, item.position_value)
        if not ok then
            set_visible(item, false)
            if not item.write_error_logged then
                item.write_error_logged = true
                log("Local interactable slot write failed index=" .. tostring(item.index))
            end
            return false
        end
        item.last_x, item.last_y = x, y
        pool.metrics.position_writes = pool.metrics.position_writes + 1
        update_decorations(item, x + fit_w / 2.0, y + fit_h / 2.0, drawn_size)
        return set_visible(item, true)
    end

    function pool.UpdatePlayer(player_x, player_y, context)
        pool.metrics.update_calls = pool.metrics.update_calls + 1
        if pool.deep_trace then trace("update-enter", "entries=" .. tostring(#pool.entries)) end
        if not pool.ready then return false end
        player_x, player_y = tonumber(player_x), tonumber(player_y)
        if player_x == nil or player_y == nil then return false end
        context = context or Projection.Prepare(Config.Size, Config.ZoomMeters,
            state.map_rotation_angle, Config.MapShape, Config.EdgeVisibility)
        if type(context) ~= "table" then return false end
        if not pool.reselecting and pool.selection_center_x ~= nil
            and type(ctx.LocalDiscovery) == "table"
            and type(ctx.LocalDiscovery.Records) == "function" then
            local sdx = player_x - pool.selection_center_x
            local sdy = player_y - pool.selection_center_y
            if sdx * sdx + sdy * sdy >= RESELECT_MOVE_EPSILON_SQ then
                pool.metrics.movement_reselections = pool.metrics.movement_reselections + 1
                pool.reselecting = true
                local synced = pool.SyncRecords(ctx.LocalDiscovery.Records(),
                    "player-moved", context, player_x, player_y)
                pool.reselecting = false
                return synced
            end
        end
        pool.metrics.update_runs = pool.metrics.update_runs + 1
        if pool.active_count <= 0 then return true end
        local sample = pool.metrics.update_runs % 120 == 1
        local started = sample and os.clock() or nil
        local size = marker_size()
        local radius_sq = Projection.RelevantRadiusSquared(
            context, size * math.sqrt(2.0) / 2.0, false, 0)
        local success = true
        for index, item in ipairs(pool.entries) do
            if item.target ~= nil then
                -- v0.18.29: which ENTRY. update_entry writes a brush, a position, a size
                -- and a visibility per marker, and if one of those is the faulting call
                -- then the entry index and the record behind it are the whole answer.
                -- Only inside a build slice: both crashes clustered there, and tracing
                -- every entry on every pose tick is ~460 unbuffered writes a second, which
                -- is enough to move the timing it is trying to observe (invariant 0l).
                if pool.deep_trace then
                    trace("update-entry", "n=" .. tostring(index)
                        .. " id=" .. tostring(item.target.record_id or "?"))
                end
                if not update_entry(item, player_x, player_y, context, size, radius_sq) then
                    success = false
                end
            end
        end
        if pool.deep_trace then trace("update-exit", "entries=" .. tostring(#pool.entries)) end
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
        local epoch = state.lifecycle_epoch
        return WorkBudget.Schedule(1, function()
            if pool.build_token == token and state.lifecycle_epoch == epoch
                and not state.world_quarantined then build_pending_slice(token, epoch) end
        end, "local.build-arm")
    end

    build_pending_slice = function(token, epoch)
        if pool.build_token ~= token or state.lifecycle_epoch ~= epoch
            or state.world_quarantined then return end
        local started, built = os.clock(), 0
        trace("build-enter", "pending=" .. tostring(#pool.pending_targets)
            .. " entries=" .. tostring(#pool.entries))
        while built < CONSTRUCTION_BATCH and #pool.pending_targets > 0
            and #pool.entries < capacity() do
            trace("build-construct", "n=" .. tostring(built))
            local item, err = construct_entry()
            if item == nil then
                pool.build_blocked = true
                pool.metrics.build_failures = pool.metrics.build_failures + 1
                log("Local interactable pool construction stopped: " .. tostring(err))
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
        trace("build-assigned", "built=" .. tostring(built))
        local elapsed = (os.clock() - started) * 1000.0
        pool.metrics.build_slices = pool.metrics.build_slices + 1
        pool.metrics.build_cpu_ms = pool.metrics.build_cpu_ms + elapsed
        pool.metrics.max_build_slice_ms = math.max(pool.metrics.max_build_slice_ms, elapsed)
        local center_x, center_y = current_center()
        pool.deep_trace = true
        pool.UpdatePlayer(center_x, center_y)
        pool.deep_trace = false
        trace("build-exit", "built=" .. tostring(built))
        if #pool.pending_targets > 0 and not pool.build_blocked then
            WorkBudget.Schedule(CONSTRUCTION_DELAY_MS, function()
                if pool.build_token == token and state.lifecycle_epoch == epoch
                    and not state.world_quarantined then build_pending_slice(token, epoch) end
            end, "local.build-slice")
        end
    end

    function pool.SyncRecords(records, reason, prepared_context, center_x, center_y)
        if not pool.ready then pool.sync_pending = true; return false end
        records = type(records) == "table" and records or {}
        trace("sync-enter", "reason=" .. tostring(reason))
        local px, py = tonumber(center_x), tonumber(center_y)
        if px == nil or py == nil then px, py = current_center() end
        local context = prepared_context or Projection.Prepare(Config.Size, Config.ZoomMeters,
            state.map_rotation_angle, Config.MapShape, Config.EdgeVisibility)
        local size = marker_size()
        local radius_sq = px ~= nil and py ~= nil and type(context) == "table"
            and Projection.RelevantRadiusSquared(
                context, size * math.sqrt(2.0) / 2.0, false, 0) or nil
        local targets = {}
        for _, record in pairs(records) do
            local target, reject_reason = eligible_target(record, px, py, radius_sq)
            if target ~= nil then
                targets[#targets + 1] = target
            elseif reject_reason == "out-of-range" then
                pool.metrics.range_prefilter_rejects = pool.metrics.range_prefilter_rejects + 1
            end
        end
        pool.selection_center_x, pool.selection_center_y = px, py
        table.sort(targets, function(a, b)
            if a.priority ~= b.priority then return a.priority < b.priority end
            if a.distance_sq ~= b.distance_sq then return a.distance_sq < b.distance_sq end
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
                -- Prefer a free image already wearing this texture: fewer brush
                -- writes and fewer re-finds (v0.10.13).
                local pick = #free
                for i = #free, 1, -1 do
                    if free[i].texture_path == target.texture_path then pick = i; break end
                end
                local item = pick > 0 and table.remove(free, pick) or nil
                if item ~= nil then assign_target(item, target)
                else pool.pending_targets[#pool.pending_targets + 1] = target end
                desired[target.record_id] = nil
            end
        end
        pool.active_count = #targets
        pool.metrics.syncs = pool.metrics.syncs + 1
        pool.sync_pending = false
        pool.UpdatePlayer(px, py, context)
        arm_pending_build()
        return true
    end

    function pool.RequestSync(reason)
        pool.metrics.sync_requests = pool.metrics.sync_requests + 1
        if pool.sync_pending then pool.metrics.sync_coalesced = pool.metrics.sync_coalesced + 1 end
        pool.sync_pending = true
        pool.sync_token = pool.sync_token + 1
        local token = pool.sync_token
        local epoch = state.lifecycle_epoch
        if not pool.ready then return true end
        return WorkBudget.Schedule(100, function()
            if token == pool.sync_token and epoch == state.lifecycle_epoch
                and not state.world_quarantined and type(ctx.LocalDiscovery) == "table" then
                pool.SyncRecords(ctx.LocalDiscovery.Records(), reason)
            end
        end, "local.sync")
    end

    function pool.UpdateRecordPosition(record)
        if type(record) ~= "table" or record.id == nil then return false end
        local item = pool.by_record[record.id]
        if type(item) ~= "table" or type(item.target) ~= "table" then return false end
        item.target.x, item.target.y = tonumber(record.x), tonumber(record.y)
        item.last_x, item.last_y = nil, nil
        return true
    end

    local function resolve_assets_step(paths, index, token, epoch)
        if token ~= pool.build_token or epoch ~= state.lifecycle_epoch
            or state.world_quarantined then return end
        if index > #paths then
            pool.ready = pool.asset_ok[Classifier.GenericIconPath] == true
            pool.dependency_started = false
            if pool.ready then
                local records = type(ctx.LocalDiscovery) == "table" and ctx.LocalDiscovery.Records() or {}
                pool.SyncRecords(records, "assets-ready")
            else
                log("Local interactable pool disabled: generic marker texture unavailable")
            end
            return
        end
        local path = paths[index]
        local started = os.clock()
        local asset, status = load_exact_asset(path)
        local elapsed = (os.clock() - started) * 1000.0
        pool.metrics.asset_attempts = pool.metrics.asset_attempts + 1
        pool.metrics.asset_cpu_ms = pool.metrics.asset_cpu_ms + elapsed
        pool.asset_ok[path] = asset ~= nil
        -- Pin it in the same step, before the engine can collect it (see header).
        if asset ~= nil then pin_texture(path, asset) end
        asset = nil
        if status == "unavailable" then
            log("Local interactable texture unavailable (generic fallback): " .. tostring(path))
        end
        if status == "resident" then pool.metrics.asset_resident = pool.metrics.asset_resident + 1
        elseif status == "loaded" then pool.metrics.asset_loaded = pool.metrics.asset_loaded + 1
        else pool.metrics.asset_failures = pool.metrics.asset_failures + 1 end
        WorkBudget.Schedule(ASSET_DELAY_MS, function()
            resolve_assets_step(paths, index + 1, token, epoch)
        end, "local.asset-step")
    end

    function pool.OnRendererReady()
        if pool.dependency_started or pool.ready then return true end
        local frame = state.retained and state.retained.frame or nil
        if not state.built or not valid(frame) then return false end
        pool.image_class = find_object(IMAGE_CLASS_PATH)
        if not valid(pool.image_class) then
            pool.metrics.build_failures = pool.metrics.build_failures + 1
            log("Local interactable pool unavailable: UImage class not resident")
            return false
        end
        pool.dependency_started = true
        pool.build_token = pool.build_token + 1
        local token = pool.build_token
        local epoch = state.lifecycle_epoch
        local paths = Classifier.Paths()
        return WorkBudget.Schedule(100, function()
            resolve_assets_step(paths, 1, token, epoch)
        end, "local.asset-start")
    end

    function pool.ApplyLiveSetting(setting)
        if type(setting) ~= "table" then return end
        if setting.apply == "local-presentation" then
            invalidate_art()
            for _, item in ipairs(pool.entries) do
                item.last_x, item.last_y, item.last_size = nil, nil, nil
            end
            pool.RequestSync("settings")
        elseif setting.apply == "zoom" or setting.apply == "orientation"
            or setting.apply == "edge-presentation" then
            for _, item in ipairs(pool.entries) do item.last_x, item.last_y = nil, nil end
            local center_x, center_y = current_center()
            pool.UpdatePlayer(center_x, center_y)
        end
    end

    function pool.DropWorldReferencesUnread()
        invalidate_art()
        pool.build_token = pool.build_token + 1
        pool.sync_token = pool.sync_token + 1
        pool.entries, pool.by_record, pool.pending_targets, pool.asset_ok = {}, {}, {}, {}
        pool.pinned = {}
        pool.ready, pool.dependency_started, pool.build_blocked = false, false, false
        pool.image_class = nil
        pool.active_count, pool.desired_count, pool.overflow_count = 0, 0, 0
        pool.sync_pending = false
        pool.selection_center_x, pool.selection_center_y = nil, nil
        pool.reselecting = false
    end

    local function visible_count()
        local n = 0
        for _, item in ipairs(pool.entries) do if item.visible then n = n + 1 end end
        return n
    end

    function pool.EmitSummary(reason)
        local categories, visible_categories = {}, {}
        for _, item in ipairs(pool.entries) do
            if type(item.target) == "table" then
                local key = tostring(item.target.category or "Unknown")
                categories[key] = (categories[key] or 0) + 1
                if item.visible then visible_categories[key] = (visible_categories[key] or 0) + 1 end
            end
        end
        local category_parts = {}
        for _, key in ipairs(Classifier.Categories()) do
            category_parts[#category_parts + 1] = string.format("%s:%d/%d", key,
                visible_categories[key] or 0, categories[key] or 0)
        end
        local category_text = table.concat(category_parts, "|")
        local m = pool.metrics
        local assets_ok, assets_total = 0, 0
        local pinned_count = 0
        for _ in pairs(pool.pinned) do pinned_count = pinned_count + 1 end
        for _, ok in pairs(pool.asset_ok) do
            assets_total = assets_total + 1
            if ok == true then assets_ok = assets_ok + 1 end
        end
        log(string.format(
            "Local pool summary reason=%s ready=%s enabled=%s cap=%d desired=%d active=%d built=%d visible=%d pending=%d overflow=%d categories=%s suppressedRejects=%d categoryRejects=%d iconSize=%d assets=%d resident=%d loaded=%d assetFailures=%d assetCpuMs=%.3f buildSlices=%d buildFailures=%d buildCpuMs=%.3f maxBuildSliceMs=%.3f syncs=%d syncRequests=%d syncCoalesced=%d rangePrefilterRejects=%d movementReselections=%d positionWrites=%d positionSkips=%d sizeWrites=%d visibilityWrites=%d textureWrites=%d textureFinds=%d textureReloads=%d textureFallbacks=%d assetsOk=%d/%d pinnedTextures=%d pinnedHits=%d pinFailures=%d unpinnedTextureRefs=0 tintWrites=%d plates=%d/%d chevrons=%d/%d decorationFailures=%d heightThresholdM=%.1f chevronScale=%.2f heightFade=%s(start=%d min=%d rangeM=%d) opacityWrites=%d fadedMarkers=%d",
            tostring(reason or "manual"), tostring(pool.ready),
            tostring(Config.ShowLocalInteractables == true), capacity(),
            pool.desired_count, pool.active_count, #pool.entries, visible_count(),
            #pool.pending_targets, pool.overflow_count,
            category_text, tonumber(pool.metrics.suppressed_rejects) or 0,
            tonumber(pool.metrics.category_rejects) or 0,
            marker_size(), m.asset_attempts, m.asset_resident, m.asset_loaded,
            m.asset_failures, m.asset_cpu_ms, m.build_slices, m.build_failures,
            m.build_cpu_ms, m.max_build_slice_ms, m.syncs, m.sync_requests,
            m.sync_coalesced, m.range_prefilter_rejects, m.movement_reselections,
            m.position_writes, m.position_skips, m.size_writes,
            m.visibility_writes, m.texture_writes, m.texture_finds, m.texture_reloads,
            m.texture_fallbacks, assets_ok, assets_total, pinned_count,
            m.texture_pinned_hits, m.pin_failures, m.tint_writes,
            m.plates_built, m.plate_writes, m.chevrons_built, m.chevron_writes,
            m.decoration_failures, height_threshold() / 100.0, chevron_scale(),
            tostring(Config.LocalHeightFade ~= false),
            math.floor(tonumber(Config.LocalHeightFadeStart) or 75),
            math.floor(tonumber(Config.LocalHeightFadeMin) or 35),
            math.floor(tonumber(Config.LocalHeightFadeRange) or 15),
            m.opacity_writes, m.faded_markers))
        log(string.format(
            "Local pool performance reason=%s updateCalls=%d updateRuns=%d entriesExamined=%d broadPhaseRejects=%d projections=%d timingSamples=%d sampledUpdateCpuMs=%.3f sampledMaxUpdateCpuMs=%.3f eventDiscovery=true recurringWorldScan=0 fixedPool=true noEdgeIndicators=true",
            tostring(reason or "manual"), m.update_calls, m.update_runs,
            m.entries_examined, m.broad_phase_rejects, m.projections_executed,
            m.update_timing_samples, m.update_cpu_ms, m.max_update_cpu_ms))
    end

    return pool
end

return Factory
