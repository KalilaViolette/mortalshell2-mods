-- Footstep trail: fading breadcrumbs along the path the player walked (v0.11.0).
--
-- Sampling is distance-gated, so standing still costs one squared-distance test per
-- pose tick and nothing else. Marks are Lua primitives; the pooled images are ours,
-- parented to the retained frame and dropped unread with it at LoadMap PRE. The
-- first constructed image pins the texture (its brush holds the engine reference),
-- so later images reuse that wrapper instead of paying ~3 ms per StaticFindObject.

local Factory = {}

function Factory.New(ctx)
    local state = assert(ctx.State, "Overlay.TrailPool requires State")
    local Config = assert(ctx.Config, "Overlay.TrailPool requires Config")
    local Object = assert(ctx.Object, "Overlay.TrailPool requires Core.Object")
    local Projection = assert(ctx.TrackerProjection, "Overlay.TrailPool requires Overlay.TrackerProjection")
    local Classifier = assert(ctx.LocalClassifier, "Overlay.TrailPool requires Local.Classifier")
    local log = assert(ctx.Log, "Overlay.TrailPool requires Log")
    local Perf = type(ctx.Perf) == "table" and ctx.Perf
        or { Begin = function() return nil end, End = function() end, Count = function() end }
    local unwrap, valid = Object.Unwrap, Object.Valid

    local IMAGE_CLASS_PATH = "/Script/UMG.Image"
    local VIS_COLLAPSED = 1
    local VIS_HIT_TEST_INVISIBLE = 3
    local SPACING = 150.0            -- centimetres between breadcrumbs (1.5 m), the FLOOR
    local TELEPORT_SQ = 3000.0 * 3000.0 -- 30 m in one tick: a load or fast travel
    -- v0.18.28. 1.5 m is right when the map is zoomed in and wrong everywhere else, because
    -- the spacing was in WORLD units while the thing she looks at is in PIXELS. At her saved
    -- range (750 m) sixteen crumbs land 8.2 px apart under a 22 px mark: a solid overlapping
    -- smear, not a trail -- and the shipped default range is 1000 m, where they are 6.1 px
    -- apart. So a crumb is placed when the LAST one is this many mark-widths away on screen.
    local SCREEN_GAP_FACTOR = 1.15
    -- And a ceiling, because the range slider goes to 50 km: without it the wanted spacing
    -- grows past the 30 m teleport break, every real step reads as fast travel, and the
    -- trail can never place a second crumb at all.
    local SPACING_CEILING = 2500.0   -- 25 m, comfortably inside TELEPORT_SQ
    local MARK_SCALE = 0.55          -- of the local icon size
    local OPACITY_STEPS = 8          -- quantised, so age fading is not a write per frame
    local MAX_MARKS = 48

    state.trail_pool = state.trail_pool or {
        marks = {}, entries = {}, texture = nil, image_class = nil,
        asset_ok = false, ready = false, dirty = false,
        last_x = nil, last_y = nil,
        metrics = {
            marks_added = 0, marks_dropped = 0, resets = 0, teleport_breaks = 0,
            images_built = 0, build_failures = 0, texture_finds = 0,
            position_writes = 0, opacity_writes = 0, angle_writes = 0,
            visibility_writes = 0, updates = 0, samples = 0, sample_skips = 0,
        },
    }
    local pool = state.trail_pool

    local function capacity()
        local requested = math.floor(tonumber(Config.FootstepTrail) or 0)
        if requested <= 0 then return 0 end
        return math.max(4, math.min(MAX_MARKS, requested))
    end

    local function marker_size()
        local base = math.max(12, math.min(48,
            math.floor(tonumber(Config.LocalInteractableIconSize) or 18)))
        -- v0.16.8: "Footstep trail size" (MAP tab), a percentage of the base size.
        local scale = math.max(25, math.min(200, tonumber(Config.FootstepTrailSize) or 100)) / 100.0
        return math.max(4.0, base * MARK_SCALE * scale)
    end

    -- Arithmetic only, on numbers the config already holds: one divide per pose tick,
    -- which is what invariant 0l demands of anything that runs while standing still.
    local function sample_spacing()
        if type(Projection.Scale) ~= "function" then return SPACING end
        local scale = Projection.Scale(Config.Size, Config.ZoomMeters)
        if type(scale) ~= "number" or scale <= 0 then return SPACING end
        local wanted = marker_size() * SCREEN_GAP_FACTOR / scale
        if wanted < SPACING then return SPACING end
        if wanted > SPACING_CEILING then return SPACING_CEILING end
        return wanted
    end

    local function make_name(base)
        state.widget_counter = (tonumber(state.widget_counter) or 0) + 1
        return FName("MS2Minimap_" .. tostring(base) .. "_" .. tostring(state.widget_counter))
    end

    local function find_object(path)
        local token = Perf.Begin()
        local ok, value = pcall(StaticFindObject, path)
        Perf.End("native.find", token)
        value = unwrap(ok and value or nil)
        return valid(value) and value or nil
    end

    -- The texture stays alive because the first image's brush references it.
    local function footstep_texture()
        if pool.texture ~= nil then return pool.texture end
        local path = Classifier.FootstepIconPath
        pool.metrics.texture_finds = pool.metrics.texture_finds + 1
        local texture = find_object(path)
        if texture == nil and type(LoadAsset) == "function" then
            local token = Perf.Begin()
            pcall(LoadAsset, path)
            Perf.End("native.load", token)
            texture = find_object(path)
        end
        return texture
    end

    local function set_visible(entry, visible)
        visible = visible == true
        if entry.visible == visible then return true end
        if not valid(entry.image) then return false end
        local ok = pcall(entry.image.SetVisibility, entry.image,
            visible and VIS_HIT_TEST_INVISIBLE or VIS_COLLAPSED)
        if ok then
            entry.visible = visible
            pool.metrics.visibility_writes = pool.metrics.visibility_writes + 1
        end
        return ok
    end

    local function construct_entry()
        local frame = state.retained and state.retained.frame or nil
        if not valid(frame) or not valid(pool.image_class) then return nil end
        local texture = footstep_texture()
        if texture == nil then
            pool.metrics.build_failures = pool.metrics.build_failures + 1
            return nil
        end
        local entry = { visible = false, angle = nil, opacity_step = nil,
            position_value = { X = -10000, Y = -10000 }, size_value = { X = 1, Y = 1 } }
        local ok, err = pcall(function()
            local image = unwrap(StaticConstructObject(pool.image_class, frame,
                make_name("Footstep" .. tostring(#pool.entries + 1))))
            assert(valid(image), "footstep image construction failed")
            entry.image = image
            local slot = unwrap(frame:AddChildToCanvas(image))
            assert(valid(slot), "footstep slot failed")
            entry.slot = slot
            slot:SetPosition({ X = -10000, Y = -10000 })
            slot:SetSize({ X = 1, Y = 1 })
            pcall(slot.SetZOrder, slot, 2) -- under every marker, over the tiles
            image:SetVisibility(VIS_COLLAPSED)
            image:SetBrushFromTexture(texture, false)
        end)
        if not ok then
            if entry.image ~= nil and valid(entry.image) then
                pcall(entry.image.RemoveFromParent, entry.image)
            end
            pool.metrics.build_failures = pool.metrics.build_failures + 1
            log("Footstep trail image failed: " .. tostring(err))
            return nil
        end
        -- First image pins the texture for the rest of this world.
        pool.texture = texture
        pool.entries[#pool.entries + 1] = entry
        pool.metrics.images_built = pool.metrics.images_built + 1
        return entry
    end

    function pool.Clear(reason)
        pool.marks = {}
        pool.last_x, pool.last_y = nil, nil
        pool.dirty = true
        pool.metrics.resets = pool.metrics.resets + 1
        for _, entry in ipairs(pool.entries) do set_visible(entry, false) end
        if reason ~= nil and Config.DebugLog == true then
            log("Footstep trail cleared reason=" .. tostring(reason))
        end
    end

    -- Called every pose tick: one distance test while standing still.
    function pool.Sample(player_x, player_y)
        pool.metrics.samples = pool.metrics.samples + 1
        local cap = capacity()
        if cap <= 0 then
            if #pool.marks > 0 then pool.Clear("disabled") end
            pool.metrics.sample_skips = pool.metrics.sample_skips + 1
            return false
        end
        player_x, player_y = tonumber(player_x), tonumber(player_y)
        if player_x == nil or player_y == nil then return false end
        local last_x, last_y = pool.last_x, pool.last_y
        if last_x ~= nil then
            local dx, dy = player_x - last_x, player_y - last_y
            local distance_sq = dx * dx + dy * dy
            local spacing = sample_spacing()
            pool.metrics.last_spacing = spacing
            if distance_sq < spacing * spacing then
                pool.metrics.sample_skips = pool.metrics.sample_skips + 1
                return false
            end
            if distance_sq > TELEPORT_SQ then
                -- Fast travel or a load: a straight line of crumbs across the map
                -- would be a lie, so start a new trail.
                pool.metrics.teleport_breaks = pool.metrics.teleport_breaks + 1
                pool.Clear("teleport")
                pool.last_x, pool.last_y = player_x, player_y
                return false
            end
            pool.marks[#pool.marks + 1] = { x = player_x, y = player_y,
                angle = math.deg(math.atan(dy, dx)) }
        else
            pool.marks[#pool.marks + 1] = { x = player_x, y = player_y, angle = 0.0 }
        end
        pool.last_x, pool.last_y = player_x, player_y
        pool.metrics.marks_added = pool.metrics.marks_added + 1
        while #pool.marks > cap do
            table.remove(pool.marks, 1)
            pool.metrics.marks_dropped = pool.metrics.marks_dropped + 1
        end
        pool.dirty = true
        return true
    end

    function pool.UpdatePlayer(player_x, player_y, context)
        if not pool.ready then return false end
        local cap = capacity()
        if cap <= 0 then
            for _, entry in ipairs(pool.entries) do set_visible(entry, false) end
            return true
        end
        player_x, player_y = tonumber(player_x), tonumber(player_y)
        if player_x == nil or player_y == nil then return false end
        context = context or Projection.Prepare(Config.Size, Config.ZoomMeters,
            state.map_rotation_angle, Config.MapShape, Config.EdgeVisibility)
        if type(context) ~= "table" then return false end
        pool.metrics.updates = pool.metrics.updates + 1
        local size = marker_size()
        local radius_sq = Projection.RelevantRadiusSquared(
            context, size * math.sqrt(2.0) / 2.0, false, 0)
        local map_angle = tonumber(state.map_rotation_angle) or 0.0
        local count = #pool.marks
        for index = 1, math.max(count, #pool.entries) do
            local mark = pool.marks[index]
            local entry = pool.entries[index]
            if mark == nil then
                if entry ~= nil then set_visible(entry, false) end
            else
                if entry == nil then entry = construct_entry() end
                if entry == nil then break end
                local dx, dy = mark.x - player_x, mark.y - player_y
                if radius_sq ~= nil and dx * dx + dy * dy > radius_sq then
                    set_visible(entry, false)
                else
                    local x, y, _, _, _, display_visible, _, _, mode, rendered_size =
                        Projection.PositionPrepared(context, player_x, player_y,
                            mark.x, mark.y, size, false, 0, 1.0, size, size)
                    if x == nil or mode == nil or rendered_size == nil or not display_visible then
                        set_visible(entry, false)
                    else
                        -- Newest mark is brightest; the oldest fades out.
                        local age = count > 1 and (count - index) / (count - 1) or 0.0
                        local step = math.max(1, math.min(OPACITY_STEPS,
                            math.floor((1.0 - age) * OPACITY_STEPS + 0.5)))
                        if entry.opacity_step ~= step then
                            if pcall(entry.image.SetRenderOpacity, entry.image,
                                0.15 + 0.55 * (step / OPACITY_STEPS)) then
                                entry.opacity_step = step
                                pool.metrics.opacity_writes = pool.metrics.opacity_writes + 1
                            end
                        end
                        local angle = mark.angle + map_angle
                        if entry.angle == nil or math.abs(entry.angle - angle) > 1.0 then
                            if pcall(entry.image.SetRenderTransformAngle, entry.image, angle) then
                                entry.angle = angle
                                pool.metrics.angle_writes = pool.metrics.angle_writes + 1
                            end
                        end
                        -- The footstep smear is wide and short; keep its shape.
                        local nw, nh = Classifier.IconSize(Classifier.FootstepIconPath)
                        local longest = math.max(nw, nh)
                        local w, h = rendered_size * nw / longest, rendered_size * nh / longest
                        entry.size_value.X, entry.size_value.Y = w, math.max(2.0, h)
                        entry.position_value.X = x + (rendered_size - w) / 2.0
                        entry.position_value.Y = y + (rendered_size - h) / 2.0
                        if pcall(entry.slot.SetSize, entry.slot, entry.size_value)
                            and pcall(entry.slot.SetPosition, entry.slot, entry.position_value) then
                            pool.metrics.position_writes = pool.metrics.position_writes + 1
                            set_visible(entry, true)
                        else
                            set_visible(entry, false)
                        end
                    end
                end
            end
        end
        pool.dirty = false
        return true
    end

    function pool.OnRendererReady()
        if pool.ready then return true end
        local frame = state.retained and state.retained.frame or nil
        if not state.built or not valid(frame) then return false end
        pool.image_class = find_object(IMAGE_CLASS_PATH)
        if not valid(pool.image_class) then
            log("Footstep trail unavailable: UImage class not resident")
            return false
        end
        pool.asset_ok = footstep_texture() ~= nil
        if not pool.asset_ok then
            log("Footstep trail unavailable: " .. tostring(Classifier.FootstepIconPath))
            return false
        end
        pool.ready = true
        return true
    end

    function pool.ApplyLiveSetting(setting)
        if type(setting) ~= "table" then return end
        if setting.apply == "trail" then
            if capacity() <= 0 then pool.Clear("setting") end
            for _, entry in ipairs(pool.entries) do
                entry.opacity_step, entry.angle = nil, nil
            end
            pool.dirty = true
        elseif setting.apply == "zoom" or setting.apply == "orientation"
            or setting.apply == "edge-presentation" or setting.apply == "local-presentation" then
            pool.dirty = true
        end
    end

    function pool.DropWorldReferencesUnread()
        pool.entries = {}
        pool.marks = {}
        pool.texture = nil
        pool.image_class = nil
        pool.ready = false
        pool.asset_ok = false
        pool.last_x, pool.last_y = nil, nil
        pool.dirty = false
    end

    function pool.EmitSummary(reason)
        local m = pool.metrics
        local visible = 0
        for _, entry in ipairs(pool.entries) do if entry.visible then visible = visible + 1 end end
        -- v0.18.28: the three numbers that say whether a trail can READ as a trail at the
        -- range she is playing at -- how far apart the crumbs are in the world, how big one
        -- is on screen, and how far apart they land there. A gap smaller than the mark is a
        -- smear, which is what "the footsteps stopped" looked like at 750 m.
        local spacing = sample_spacing()
        local scale = Projection.Scale(Config.Size, Config.ZoomMeters)
        local mark_px = marker_size()
        local gap_px = type(scale) == "number" and scale > 0 and spacing * scale or -1.0
        log(string.format(
            "Footstep trail summary reason=%s ready=%s cap=%d marks=%d images=%d visible=%d spacingM=%.1f markPx=%.1f gapPx=%.1f marksAdded=%d marksDropped=%d resets=%d teleportBreaks=%d buildFailures=%d textureFinds=%d samples=%d sampleSkips=%d updates=%d positionWrites=%d opacityWrites=%d angleWrites=%d visibilityWrites=%d",
            tostring(reason or "manual"), tostring(pool.ready), capacity(), #pool.marks,
            #pool.entries, visible, spacing / 100.0, mark_px, gap_px,
            m.marks_added, m.marks_dropped,
            m.resets, m.teleport_breaks, m.build_failures, m.texture_finds,
            m.samples, m.sample_skips, m.updates, m.position_writes, m.opacity_writes,
            m.angle_writes, m.visibility_writes))
    end

    return pool
end

return Factory
