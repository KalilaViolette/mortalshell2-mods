-- Owns native map assets, UMG construction, retained render objects, world-to-map
-- projection, smooth rate-limited panning, and player-heading presentation.

local Factory = {}

function Factory.New(ctx)
    local state = assert(ctx.State, "Map.NativeWidget requires State")
    local Config = assert(ctx.Config, "Map.NativeWidget requires Config")
    local Object = assert(ctx.Object, "Map.NativeWidget requires Core.Object")
    local MapScale = assert(ctx.MapScale, "Map.NativeWidget requires Map.Scale")
    local log = assert(ctx.Log, "Map.NativeWidget requires Log")
    local Perf = type(ctx.Perf) == "table" and ctx.Perf
        or { Begin = function() return nil end, End = function() end, Count = function() end }
    local debug_log = assert(ctx.DebugLog, "Map.NativeWidget requires DebugLog")
    local unwrap = Object.Unwrap
    local valid = Object.Valid

    local ASSET = {
        tile_set = "/Game/Sparta/UI/World/Map/Blueprints/DT_MapTiles.DT_MapTiles",
        tile_material = "/Game/Sparta/UI/World/Map/Materials/MI_SpartaMapTile.MI_SpartaMapTile",
        global_mask = "/Game/Sparta/UI/World/Map/Textures/T_UI_MapGlobalMask.T_UI_MapGlobalMask",
        cloud_material = "/Game/Sparta/UI/World/Map/Materials/MI_UI_MapFog.MI_UI_MapFog",
        cloud_texture = "/Game/Sparta/UI/World/Map/Textures/T_UI_Map_Fog.T_UI_Map_Fog",
        -- Native UI-domain circle material. The game already uses RetainerBox
        -- effect materials for map masking; this material exposes the standard
        -- Texture parameter expected by UMG retained rendering.
        circle_effect = "/Game/Sparta/UI/Common/Materials/Master/Mat_UI_Circle_Background_Inst.Mat_UI_Circle_Background_Inst",
        player_arrow = "/Game/Sparta/UI/World/Map/Textures/T_UI_Icon_Map_PlayerIndicator.T_UI_Icon_Map_PlayerIndicator",
    }

    local CLASS = {
        widget_library = "/Script/UMG.Default__WidgetBlueprintLibrary",
        user_widget = "/Script/UMG.UserWidget",
        widget_tree = "/Script/UMG.WidgetTree",
        canvas = "/Script/UMG.CanvasPanel",
        image = "/Script/UMG.Image",
        retainer_box = "/Script/UMG.RetainerBox",
        sparta_map_widget = "/Script/Sparta.SpartaMapWidget",
    }

    local VIS_COLLAPSED = 1
    local VIS_HIT_TEST_INVISIBLE = 3

    -- Runtime-proven BP_WorldMapSettings_2D calibration lives in Map.Scale so
    -- rendering and closed-map area classification use one exact coordinate model.
    local WORLD_SPAN_UNITS = MapScale.WORLD_SPAN_UNITS
    local PLAYER_ARROW_ANGLE_OFFSET = -90.0
    -- Native WBP_WMI_Player centers a 40px rotating root while translating the
    -- asymmetric indicator art upward by 3px. A single Image reproduces that
    -- geometry with a 0.575 vertical pivot and a compensating slot offset so
    -- the circular part's center remains exactly on the minimap center.
    local PLAYER_ARROW_PIVOT_X = 0.500
    local PLAYER_ARROW_PIVOT_Y = 0.575
    local PAN_IDLE_EPSILON_PIXELS = 0.001
    local MAP_ROTATION_IDLE_EPSILON_DEGREES = 0.25
    local SQRT_TWO = math.sqrt(2.0)

    local runtime = {}

    local function no_map()
        return state.area_map_available == false
    end

    -- v0.14.0: the no-map background is a three-way choice (Dungeon map / Transparent /
    -- Cloud) rather than a boolean. The dungeon layer is owned by Map/DungeonView.lua and
    -- may decline -- a missing class, a refused spawn, a brush the engine will not take --
    -- so "Dungeon map" falls back to Transparent here rather than leaving a black square.
    local function background_mode()
        local mode = tostring(Config.NoMapBackground or "dungeon"):lower()
        if mode ~= "transparent" and mode ~= "cloud" then return "dungeon" end
        return mode
    end

    local function dungeon_view_active()
        return type(ctx.DungeonView) == "table"
            and type(ctx.DungeonView.Active) == "function"
            and ctx.DungeonView.Active() == true
    end

    local function transparent_no_map_background()
        if not no_map() then return false end
        if background_mode() == "cloud" then return false end
        -- Dungeon mode that has not engaged is Transparent, which is what the setting
        -- defaulted to before this feature existed.
        return not dungeon_view_active()
    end

    local function cloud_no_map_background()
        return no_map() and background_mode() == "cloud"
    end

    local function circular_map_enabled()
        return tostring(Config.MapShape or "square"):lower() == "circle"
    end

    local function circle_mask_passthrough_required()
        -- RetainerBox effect materials need an opaque retained surface to mask.
        -- In a no-map Transparent area our subtree is intentionally alpha-empty;
        -- the native circle effect then exposes the retainer's black clear color.
        -- Unreal's retain-rendering=false mode is a direct child pass-through, so
        -- bypass only that effect while preserving the user's Circle preference.
        return circular_map_enabled() and transparent_no_map_background()
    end

    -- v0.10.14: circle opacity. The native circle effect material draws the
    -- retained surface's color but ignores its alpha, so a translucent frame
    -- inside it only gets darker (the retainer surface is premultiplied). In
    -- Circle mode the frame stays opaque and the user's opacity is applied by an
    -- outer, effect-less RetainerBox, whose own paint path premultiplies its tint
    -- (i.e. honours RenderOpacity). The outer box only retains (costs a render
    -- target) while opacity < 1; at full opacity it is a pass-through.
    -- v0.10.15/v0.10.16: a RetainerBox fades both the children it renders into
    -- its surface and the surface it then draws, and the circle effect material
    -- dims it again, so the visible result is opacity^curve (user, 2026-09-11:
    -- "each step is doubled", invisible at 50% uncompensated; still too dim with
    -- a square-root correction). Circle mode asks the box for opacity^(1/curve),
    -- where curve is Config.CircleOpacityCurve (1.00-15.00, default 5.80, measured
    -- from a Circle-vs-Square screenshot comparison; see Config/Runtime.lua).
    -- Square mode applies opacity once, on the frame, and stays linear.
    local OPAQUE_EPSILON = 0.999
    local function apply_opacity()
        if not state.built or state.retained.frame == nil then return end
        local opacity = math.max(0.0, math.min(1.0, tonumber(Config.Opacity) or 1.0))
        local box = state.retained.opacity_box
        if box == nil then
            pcall(state.retained.frame.SetRenderOpacity, state.retained.frame, opacity)
            return
        end
        pcall(state.retained.frame.SetRenderOpacity, state.retained.frame, 1.0)
        local curve = math.max(1.0, math.min(15.0, tonumber(Config.CircleOpacityCurve) or 5.8))
        local applied = opacity ^ (1.0 / curve)
        local translucent = opacity < OPAQUE_EPSILON
        local changed = state.circle_opacity_retained ~= translucent
            or state.circle_opacity_applied ~= applied
        pcall(box.SetRetainRendering, box, translucent)
        pcall(box.SetRenderOpacity, box, applied)
        state.circle_opacity_retained = translucent
        state.circle_opacity_applied = applied
        if changed then
            if translucent then pcall(box.RequestRender, box) end
            debug_log(string.format(
                "Circle opacity mode=%s requested=%.2f applied=%.3f curve=%.2f",
                translucent and "outer-retained" or "pass-through", opacity, applied, curve))
        end
    end

    local function apply_area_presentation()
        if not state.built then return end
        local transparent = transparent_no_map_background()
        local cloud = cloud_no_map_background()
        -- A confirmed/fallback no-map area must never keep the global tiled map
        -- alive visually: out-of-bounds pan clamps to an unrelated map corner. The
        -- dungeon layer replaces the tiles wherever it is drawing, which includes
        -- mapped ground when the user has asked for it everywhere.
        local map_visibility = (no_map() or dungeon_view_active())
            and VIS_COLLAPSED or VIS_HIT_TEST_INVISIBLE
        local backdrop_visibility = transparent and VIS_COLLAPSED or VIS_HIT_TEST_INVISIBLE
        local cloud_visibility = cloud and VIS_HIT_TEST_INVISIBLE or VIS_COLLAPSED
        if state.retained.backdrop ~= nil then
            pcall(state.retained.backdrop.SetVisibility,
                state.retained.backdrop, backdrop_visibility)
        end
        if state.retained.cloud ~= nil then
            pcall(state.retained.cloud.SetVisibility,
                state.retained.cloud, cloud_visibility)
        end
        if state.retained.map_widget ~= nil then
            pcall(state.retained.map_widget.SetVisibility,
                state.retained.map_widget, map_visibility)
        end
        local retainer = state.retained.retainer
        if retainer ~= nil then
            local retain_rendering = not circle_mask_passthrough_required()
            local changed = state.circle_retainer_retained ~= retain_rendering
            pcall(retainer.SetRetainRendering, retainer, retain_rendering)
            state.circle_retainer_retained = retain_rendering
            if changed and retain_rendering then
                -- Force the first restored circular frame to contain current child state.
                pcall(retainer.RequestRender, retainer)
            end
            if changed then
                debug_log("Circle retainer mode="
                    .. (retain_rendering and "masked-retained" or "transparent-pass-through")
                    .. " noMap=" .. tostring(no_map())
                    .. " background=" .. (transparent and "Transparent" or (cloud and "Cloud" or "Map")))
            end
        else
            state.circle_retainer_retained = nil
        end
    end

    -- Map/DungeonView.lua calls this when its layer engages or releases, because the
    -- backdrop, cloud plate and tile widget it displaces are owned here.
    function runtime.RefreshAreaPresentation()
        apply_area_presentation()
        state.overlay_refresh_requested = true
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

    local function load_asset(path)
        local object = find_object(path)
        if object ~= nil then return object end
        local token = Perf.Begin()
        pcall(LoadAsset, path)
        Perf.End("native.load", token)
        return find_object(path)
    end

    local function umg_classes()
        local classes = {}
        for key, path in pairs(CLASS) do
            classes[key] = find_object(path)
            if classes[key] == nil then return nil, "class unavailable: " .. key end
        end
        return classes
    end

    local function set_centered_slot(slot, width, height)
        slot:SetPosition({ X = (Config.Size - width) / 2.0, Y = (Config.Size - height) / 2.0 })
        slot:SetSize({ X = width, Y = height })
    end

    local function player_arrow_layout(container_size, arrow_size)
        container_size = tonumber(container_size) or tonumber(Config.Size) or 280.0
        arrow_size = tonumber(arrow_size) or 0.0
        return container_size / 2.0 - arrow_size * PLAYER_ARROW_PIVOT_X,
            container_size / 2.0 - arrow_size * PLAYER_ARROW_PIVOT_Y,
            PLAYER_ARROW_PIVOT_X, PLAYER_ARROW_PIVOT_Y
    end

    local function orientation_mode()
        local mode = tostring(Config.MapOrientation or "north"):lower()
        if mode ~= "camera" and mode ~= "player" then return "north" end
        return mode
    end

    local function orientation_label()
        local mode = orientation_mode()
        if mode == "camera" then return "camera-heading-up" end
        if mode == "player" then return "player-heading-up" end
        return "north-up"
    end

    local function rotating_map_enabled() return orientation_mode() ~= "north" end
    local function camera_heading_enabled() return orientation_mode() == "camera" end
    local function map_surface_size()
        local normal = math.max(1.0, (tonumber(Config.Size) or 280.0) - 4.0)
        if not rotating_map_enabled() or circular_map_enabled() then return normal end
        -- A rotating square viewport needs the diagonal to cover its corners.
        -- A circular viewport only exposes the square's inscribed circle, so
        -- rotation does not require the extra surface area.
        return math.ceil(normal * SQRT_TWO)
    end

    local function apply_orientation_layout()
        if not state.built then return end
        local map_widget = state.retained.map_widget
        local map_slot = state.retained.map_slot
        if map_widget == nil or map_slot == nil then return end
        local surface = map_surface_size()
        set_centered_slot(map_slot, surface, surface)
        pcall(map_widget.SetRenderTransformPivot, map_widget, { X = 0.5, Y = 0.5 })
        if not rotating_map_enabled() then
            pcall(map_widget.SetRenderTransformAngle, map_widget, 0.0)
            state.map_rotation_angle = 0.0
            state.last_map_rotation_angle = 0.0
        else
            -- The final gameplay camera yaw is sampled on the normal pose path;
            -- force its first value to be written on the next pan-rate tick.
            state.last_map_rotation_angle = nil
        end
        state.last_yaw = nil
        state.overlay_refresh_requested = true
    end

    -- v0.18.43 (her 04:21 video, MEASURED): Size used to be a rebuild row, and the whole
    -- widget tree went with it. That cost ~490 ms of missing map per change before v0.18.41,
    -- and once v0.18.40 coalesced the rebuild it produced a worse-looking artefact she caught
    -- at once: "the label and icons moving with the sizing while the minimap was frozen
    -- waiting to resize." Her 43-step hold shows it -- the circle holds its old size for the
    -- whole hold while the region name climbs up over the bottom of the map, then everything
    -- snaps together when the rebuild lands. The cause is that Config.Size is read live, every
    -- tick, by everything that DRAWS (Labels, all four icon pools, TrailPool, CombatState,
    -- DungeonView), and only the widget waited.
    --
    -- Nothing about the size was ever baked into a constructed object. Every size-dependent
    -- line in build() is a slot property write -- SetSize, SetPosition, SetDesiredSizeOverride
    -- -- on widgets this mod owns, which is the same call shape apply_orientation_layout has
    -- used since v0.15. So the size is applied in place instead, the split closes because
    -- the widget now moves on the same tick as its overlays, and the most-stepped row in the
    -- mod stops tearing the map down at all.
    local function apply_size_layout()
        if not state.built then return false end
        local retained = state.retained
        if retained == nil or retained.frame == nil then return false end
        local size = math.max(1.0, tonumber(Config.Size) or 280.0)
        local outer_slot = retained.outer_slot
        if outer_slot ~= nil then
            pcall(outer_slot.SetSize, outer_slot, { X = size, Y = size })
            pcall(outer_slot.SetPosition, outer_slot,
                { X = Config.OffsetX, Y = Config.OffsetY })
        end
        -- In circle mode the frame sits inside the retainer and has no canvas slot of its
        -- own; in square mode frame_slot IS outer_slot and was written just above.
        local frame_slot = retained.frame_slot
        if frame_slot ~= nil and frame_slot ~= outer_slot then
            pcall(frame_slot.SetSize, frame_slot, { X = size, Y = size })
        end
        if retained.backdrop_slot ~= nil then
            pcall(set_centered_slot, retained.backdrop_slot, size, size)
        end
        if retained.cloud_slot ~= nil then
            pcall(retained.cloud_slot.SetPosition, retained.cloud_slot, { X = 2, Y = 2 })
            pcall(retained.cloud_slot.SetSize, retained.cloud_slot,
                { X = size - 4, Y = size - 4 })
        end
        if retained.arrow ~= nil and retained.arrow_slot ~= nil then
            local arrow_size = math.max(20, math.floor(size * 0.095 + 0.5))
            pcall(retained.arrow.SetDesiredSizeOverride, retained.arrow,
                { X = arrow_size, Y = arrow_size })
            local arrow_x, arrow_y, pivot_x, pivot_y = player_arrow_layout(size, arrow_size)
            pcall(retained.arrow_slot.SetPosition, retained.arrow_slot,
                { X = arrow_x, Y = arrow_y })
            pcall(retained.arrow_slot.SetSize, retained.arrow_slot,
                { X = arrow_size, Y = arrow_size })
            pcall(retained.arrow.SetRenderTransformPivot, retained.arrow,
                { X = pivot_x, Y = pivot_y })
        end
        -- The map surface is sized from Config.Size AND the orientation rule (a rotating
        -- square needs its diagonal), so it goes through the one function that knows both.
        -- That also clears the rotation and pan caches and asks for an overlay refresh.
        apply_orientation_layout()
        state.last_pan_x, state.last_pan_y = nil, nil
        state.overlay_refresh_requested = true
        state.local_overlay_refresh_requested = true
        return true
    end
    runtime.ApplySizeLayout = apply_size_layout

    function runtime.ApplyLiveSetting(setting)
        if setting.apply == "size" then
            -- The frame ring is drawn per size, so it is rebuilt rather than stretched;
            -- Overlay/Frame.lua already owns that path for the map-frame rows.
            if apply_size_layout() and type(ctx.Frame) == "table"
                and type(ctx.Frame.ApplyLiveSetting) == "function" then
                ctx.Frame.ApplyLiveSetting({ apply = "map-frame" })
            end
        elseif setting.apply == "zoom" and state.built and state.retained.map_widget ~= nil then
            local zoom = MapScale.NativeZoom(Config.ZoomMeters)
            pcall(state.retained.map_widget.SetZoom, state.retained.map_widget, zoom)
            state.last_pan_x, state.last_pan_y = nil, nil
            state.overlay_refresh_requested = true
        elseif setting.apply == "opacity" and state.built and state.retained.frame ~= nil then
            apply_opacity()
        elseif setting.apply == "orientation" then
            apply_orientation_layout()
        elseif setting.apply == "arrow" and state.built and state.retained.arrow ~= nil then
            pcall(state.retained.arrow.SetVisibility, state.retained.arrow,
                Config.ShowArrow and VIS_HIT_TEST_INVISIBLE or VIS_COLLAPSED)
        elseif setting.apply == "area-presentation" then
            apply_area_presentation()
            state.overlay_refresh_requested = true
        end
        if type(ctx.TrackerPool) == "table"
            and type(ctx.TrackerPool.ApplyLiveSetting) == "function" then
            ctx.TrackerPool.ApplyLiveSetting(setting)
        end
        if type(ctx.ObjectivePool) == "table"
            and type(ctx.ObjectivePool.ApplyLiveSetting) == "function" then
            ctx.ObjectivePool.ApplyLiveSetting(setting)
        end
        if type(ctx.LocalPool) == "table"
            and type(ctx.LocalPool.ApplyLiveSetting) == "function" then
            ctx.LocalPool.ApplyLiveSetting(setting)
        end
        -- v0.18.20: discovery needs the local-presentation applies too, because its seed
        -- now asks the category switches BEFORE it enumerates. Turning one back on has to
        -- seed; the pool alone only redraws what discovery already admitted.
        if type(ctx.LocalDiscovery) == "table"
            and type(ctx.LocalDiscovery.ApplyLiveSetting) == "function" then
            ctx.LocalDiscovery.ApplyLiveSetting(setting)
        end
        if type(ctx.TrailPool) == "table"
            and type(ctx.TrailPool.ApplyLiveSetting) == "function" then
            ctx.TrailPool.ApplyLiveSetting(setting)
        end
        if type(ctx.Labels) == "table"
            and type(ctx.Labels.ApplyLiveSetting) == "function" then
            ctx.Labels.ApplyLiveSetting(setting)
        end
        if type(ctx.Frame) == "table"
            and type(ctx.Frame.ApplyLiveSetting) == "function" then
            ctx.Frame.ApplyLiveSetting(setting)
        end
        if type(ctx.Combat) == "table"
            and type(ctx.Combat.ApplyLiveSetting) == "function" then
            ctx.Combat.ApplyLiveSetting(setting)
        end
        if type(ctx.DungeonView) == "table"
            and type(ctx.DungeonView.ApplyLiveSetting) == "function" then
            ctx.DungeonView.ApplyLiveSetting(setting)
        end
    end

    function runtime.DropWorldReferencesUnread()
        state.retained = {}
        state.built = false
        state.visible = false
        state.hide_reason = "world"
        state.player = nil
        state.controller = nil
        state.camera_manager = nil
        state.camera_yaw = nil
        state.camera_heading_source = "unavailable"
        state.camera_heading_error_logged = false
        state.player_yaw = nil
        state.map_rotation_angle = 0.0
        state.last_map_rotation_angle = nil
        state.circle_retainer_retained = nil
        state.circle_opacity_retained = nil
        state.circle_opacity_applied = nil
        state.player_world_x = nil
        state.player_world_y = nil
        state.player_world_z = nil
        state.map_center_world_x = nil
        state.map_center_world_y = nil
        state.last_pan_x = nil
        state.last_pan_y = nil
        state.last_yaw = nil
        state.pose_error_streak = 0
        state.pose_error_logged = false
        state.engine_write_error_logged = false
        state.build_retry_countdown = 2
        state.build_retry_failures = 0
        state.rebuild_requested = false
        -- v0.18.40: a pending debounce belongs to the frame that is going away. Letting it
        -- come due after a teardown would tear down whatever replaced it for no reason.
        state.rebuild_deadline = nil
        state.rebuild_coalesced = 0
        state.overlay_refresh_requested = true
        state.pan_update_phase = 0
        state.arrow_update_phase = 0
        state.pan_position_value = state.pan_position_value or { X = 0.5, Y = 0.5 }
        state.pan_position_value.X, state.pan_position_value.Y = 0.5, 0.5
    end

    function runtime.TeardownStable(reason)
        if state.built and state.retained.widget ~= nil then
            pcall(state.retained.widget.RemoveFromParent, state.retained.widget)
        end
        runtime.DropWorldReferencesUnread()
        state.world_ready = true
        state.world_quarantined = false
        debug_log("Stable teardown reason=" .. tostring(reason))
    end

    local function resolve_player()
        local token = Perf.Begin()
        local ok_controller, value = pcall(FindFirstOf, "BP_PlayerController_C")
        Perf.End("native.findfirst", token)
        local controller = unwrap(ok_controller and value or nil)
        if not valid(controller) then return nil, nil end
        local ok_pawn, pawn = pcall(controller.GetPawn, controller)
        pawn = unwrap(ok_pawn and pawn or nil)
        if not valid(pawn) then
            token = Perf.Begin()
            local ok_find, value = pcall(FindFirstOf, "BP_PlayerCharacter_C")
            Perf.End("native.findfirst", token)
            pawn = unwrap(ok_find and value or nil)
        end
        if not valid(pawn) then return controller, nil end
        return controller, pawn
    end

    local function resolve_camera_manager(controller)
        if not valid(controller) then return nil end
        local manager = nil
        pcall(function() manager = unwrap(controller.PlayerCameraManager) end)
        return valid(manager) and manager or nil
    end

    -- v0.18.39: the two early returns below used to be silent. Every other failure path in
    -- this function already reports through `last_build_status`, so a bundle could say
    -- "Build waiting: native map assets unavailable" but never "there is no PlayerController
    -- here" -- which is the one that actually fired. Her 02:57 log has 80 failed attempts
    -- and not one line saying why, and working that out took a code read instead of a grep.
    -- Same change-only idiom as the rest: one line per distinct reason, not one per attempt.
    local function build_waiting(status)
        if state.last_build_status ~= status then log("Build waiting: " .. tostring(status)) end
        state.last_build_status = status
        return false
    end

    function runtime.Build()
        -- Already built is not a failure and must not set a status or count against the
        -- backoff ladder; it is the ordinary answer once the map exists.
        if state.built then return false end
        if state.world_quarantined then return build_waiting("world quarantined") end
        if not state.world_ready then return build_waiting("world not ready") end
        local controller, player = resolve_player()
        if not valid(controller) then return build_waiting("player controller unavailable") end
        if not valid(player) then return build_waiting("player pawn unavailable") end
        local u, class_error = umg_classes()
        if u == nil then return build_waiting(class_error) end

        local tile_set = load_asset(ASSET.tile_set)
        local tile_material = load_asset(ASSET.tile_material)
        local global_mask = load_asset(ASSET.global_mask)
        local cloud_material = load_asset(ASSET.cloud_material)
        local cloud_texture = load_asset(ASSET.cloud_texture)
        local circle_effect = circular_map_enabled() and load_asset(ASSET.circle_effect) or nil
        local arrow_texture = load_asset(ASSET.player_arrow)
        if not (valid(tile_set) and valid(tile_material) and valid(global_mask) and valid(arrow_texture))
            or (circular_map_enabled() and not valid(circle_effect)) then
            return build_waiting("native map assets unavailable")
        end

        local retained = {}
        local ok, build_error = pcall(function()
            local widget = unwrap(u.widget_library:Create(controller, u.user_widget, controller))
            assert(valid(widget), "Create returned no UUserWidget")
            retained.widget = widget
            local tree = unwrap(widget.WidgetTree)
            if not valid(tree) then
                tree = unwrap(StaticConstructObject(u.widget_tree, widget, make_name("Tree")))
                assert(valid(tree), "WidgetTree construction failed")
                widget.WidgetTree = tree
            end
            retained.tree = tree

            local root = unwrap(StaticConstructObject(u.canvas, tree, make_name("Root")))
            assert(valid(root), "root CanvasPanel construction failed")
            tree.RootWidget = root
            retained.root = root

            local frame_parent = root
            local outer_slot = nil
            local retainer = nil
            if circular_map_enabled() then
                -- Outer effect-less box: carries the user's opacity (see apply_opacity).
                local opacity_box = unwrap(StaticConstructObject(
                    u.retainer_box, root, make_name("CircleOpacity")))
                assert(valid(opacity_box), "circle opacity RetainerBox construction failed")
                pcall(opacity_box.SetRetainRendering, opacity_box, false)
                outer_slot = unwrap(root:AddChildToCanvas(opacity_box))
                assert(valid(outer_slot), "circle opacity RetainerBox slot failed")
                outer_slot:SetPosition({ X = Config.OffsetX, Y = Config.OffsetY })
                outer_slot:SetSize({ X = Config.Size, Y = Config.Size })
                retained.opacity_box = opacity_box
                retainer = unwrap(StaticConstructObject(
                    u.retainer_box, opacity_box, make_name("CircleMask")))
                assert(valid(retainer), "circle RetainerBox construction failed")
                local effect_ok = pcall(retainer.SetEffectMaterial, retainer, circle_effect)
                if not effect_ok then
                    effect_ok = pcall(function() retainer.EffectMaterial = circle_effect end)
                end
                assert(effect_ok, "circle effect material assignment failed")
                pcall(function() retainer.TextureParameter = FName("Texture") end)
                local mask_slot = unwrap(opacity_box:AddChild(retainer))
                assert(valid(mask_slot), "circle RetainerBox slot failed")
                frame_parent = retainer
                retained.retainer = retainer
                retained.circle_effect = circle_effect
            end

            local frame = unwrap(StaticConstructObject(u.canvas, frame_parent, make_name("Frame")))
            assert(valid(frame), "frame CanvasPanel construction failed")
            retained.frame = frame
            pcall(function() frame.Clipping = 1 end)
            -- Circle mode keeps the frame opaque; apply_opacity() runs after build.
            pcall(frame.SetRenderOpacity, frame, retained.opacity_box ~= nil and 1.0 or Config.Opacity)
            local frame_slot = nil
            if retainer ~= nil then
                frame_slot = unwrap(retainer:AddChild(frame))
                assert(valid(frame_slot), "circle frame content slot failed")
            else
                frame_slot = unwrap(root:AddChildToCanvas(frame))
                assert(valid(frame_slot), "frame slot failed")
                frame_slot:SetPosition({ X = Config.OffsetX, Y = Config.OffsetY })
                frame_slot:SetSize({ X = Config.Size, Y = Config.Size })
                outer_slot = frame_slot
            end

            local backdrop = unwrap(StaticConstructObject(u.image, frame, make_name("Backdrop")))
            assert(valid(backdrop), "backdrop Image construction failed")
            pcall(backdrop.SetColorAndOpacity, backdrop, { R = 0.015, G = 0.015, B = 0.015, A = 0.80 })
            local backdrop_slot = unwrap(frame:AddChildToCanvas(backdrop))
            assert(valid(backdrop_slot), "backdrop slot failed")
            set_centered_slot(backdrop_slot, Config.Size, Config.Size)
            pcall(backdrop_slot.SetZOrder, backdrop_slot, 0)
            retained.backdrop_slot = backdrop_slot

            local cloud = nil
            if valid(cloud_material) or valid(cloud_texture) then
                cloud = unwrap(StaticConstructObject(u.image, frame, make_name("NoMapCloud")))
                assert(valid(cloud), "no-map cloud Image construction failed")
                local brush_ok = false
                if valid(cloud_material) then
                    brush_ok = pcall(cloud.SetBrushFromMaterial, cloud, cloud_material)
                end
                if not brush_ok and valid(cloud_texture) then
                    brush_ok = pcall(cloud.SetBrushFromTexture, cloud, cloud_texture, false)
                end
                local cloud_slot = unwrap(frame:AddChildToCanvas(cloud))
                assert(valid(cloud_slot), "no-map cloud slot failed")
                cloud_slot:SetPosition({ X = 2, Y = 2 })
                cloud_slot:SetSize({ X = Config.Size - 4, Y = Config.Size - 4 })
                pcall(cloud_slot.SetZOrder, cloud_slot, 1)
                retained.cloud_slot = cloud_slot
                cloud:SetVisibility(VIS_COLLAPSED)
                if not brush_ok then
                    debug_log("Native no-map fog brush unavailable; Cloud mode will use backdrop only")
                end
            else
                debug_log("Native no-map fog assets unavailable; Cloud mode will use backdrop only")
            end

            local map_widget = unwrap(StaticConstructObject(u.sparta_map_widget, frame, make_name("NativeTiles")))
            assert(valid(map_widget), "SpartaMapWidget construction failed")
            local map_slot = unwrap(frame:AddChildToCanvas(map_widget))
            assert(valid(map_slot), "map slot failed")
            map_slot:SetPosition({ X = 2, Y = 2 })
            map_slot:SetSize({ X = Config.Size - 4, Y = Config.Size - 4 })
            pcall(map_slot.SetZOrder, map_slot, 2)
            pcall(map_widget.SetRenderTransformPivot, map_widget, { X = 0.5, Y = 0.5 })

            local arrow = unwrap(StaticConstructObject(u.image, frame, make_name("PlayerArrow")))
            assert(valid(arrow), "player-arrow Image construction failed")
            arrow:SetBrushFromTexture(arrow_texture, false)
            local arrow_size = math.max(20, math.floor(Config.Size * 0.095 + 0.5))
            pcall(arrow.SetDesiredSizeOverride, arrow, { X = arrow_size, Y = arrow_size })
            local arrow_slot = unwrap(frame:AddChildToCanvas(arrow))
            assert(valid(arrow_slot), "player-arrow slot failed")
            local arrow_x, arrow_y, pivot_x, pivot_y = player_arrow_layout(
                Config.Size, arrow_size)
            arrow_slot:SetPosition({ X = arrow_x, Y = arrow_y })
            arrow_slot:SetSize({ X = arrow_size, Y = arrow_size })
            pcall(arrow.SetRenderTransformPivot, arrow, { X = pivot_x, Y = pivot_y })
            pcall(arrow_slot.SetZOrder, arrow_slot, 10)
            retained.arrow_slot = arrow_slot
            arrow:SetVisibility(Config.ShowArrow and VIS_HIT_TEST_INVISIBLE or VIS_COLLAPSED)

            widget:SetVisibility(VIS_COLLAPSED)
            widget:AddToViewport(40)

            -- These exact native fields and methods are source-supported by the object dump.
            map_widget.MaxResidentTiles = Config.MaxResidentTiles
            map_widget.LODBias = Config.LODBias
            map_widget.bAllowMouseInput = false
            map_widget.bExternalZoomAndPan = true
            map_widget.TileMaterial = tile_material
            map_widget:SetTileSet(tile_set)
            map_widget:SetGlobalAlphaMask(global_mask)
            map_widget:SetRegionBounds({ X = 0.5, Y = 0.5 }, { X = 1.0, Y = 1.0 })
            map_widget:SetRevealAmount(1.0)
            map_widget:SetZoom(MapScale.NativeZoom(Config.ZoomMeters))
            state.pan_position_value = state.pan_position_value or { X = 0.5, Y = 0.5 }
            state.pan_position_value.X, state.pan_position_value.Y = 0.5, 0.5
            map_widget:SetPanCenterNormalized(state.pan_position_value)

            retained.widget = widget
            retained.tree = tree
            retained.root = root
            retained.frame = frame
            retained.frame_slot = frame_slot
            retained.outer_slot = outer_slot
            retained.backdrop = backdrop
            retained.cloud = cloud
            retained.map_widget = map_widget
            retained.map_slot = map_slot
            retained.arrow = arrow
            retained.tile_set = tile_set
            retained.tile_material = tile_material
            retained.global_mask = global_mask
            retained.cloud_material = cloud_material
            retained.cloud_texture = cloud_texture
            retained.circle_effect = circle_effect
            retained.arrow_texture = arrow_texture
        end)
        if not ok then
            if valid(retained.widget) then pcall(retained.widget.RemoveFromParent, retained.widget) end
            local status = tostring(build_error)
            if state.last_build_status ~= status then log("Build failed: " .. status) end
            state.last_build_status = status
            return false
        end

        state.retained = retained
        state.controller = controller
        state.player = player
        state.camera_manager = resolve_camera_manager(controller)
        state.camera_yaw = nil
        state.camera_heading_source = state.camera_manager ~= nil
            and "PlayerCameraManager:GetCameraRotation" or "unavailable"
        state.camera_heading_error_logged = false
        state.player_yaw = nil
        state.map_rotation_angle = 0.0
        state.last_map_rotation_angle = nil
        state.built = true
        state.visible = false
        state.last_pan_x, state.last_pan_y, state.last_yaw = nil, nil, nil
        state.map_center_world_x, state.map_center_world_y = nil, nil
        state.last_build_status = nil
        state.visible_step_count = 0
        state.pan_update_phase = 0
        state.arrow_update_phase = 0
        state.overlay_refresh_requested = true
        apply_orientation_layout()
        apply_area_presentation()
        state.circle_opacity_retained, state.circle_opacity_applied = nil, nil
        apply_opacity()
        local native_zoom = MapScale.NativeZoom(Config.ZoomMeters)
        local native_scale = MapScale.NativePixelsPerWorldUnit(Config.ZoomMeters)
        local effective_span = MapScale.EffectiveVisibleMeters(Config.Size, Config.ZoomMeters)
        log(string.format(
            "Ready nativeTiles=true size=%d range=%.0fm nativeZoom=%.6f logicalMapPixels=%.0f tileSurfacePixels=%.0f nativeScale=%.9f effectiveSpan=%.3fm tileBudget=%d lodBias=%.1f panHz=%d arrowHz=%d orientation=%s",
            Config.Size, Config.ZoomMeters, native_zoom,
            MapScale.MAP_LOGICAL_PIXELS, MapScale.NATIVE_TILE_SURFACE_PIXELS,
            native_scale, effective_span,
            Config.MaxResidentTiles, Config.LODBias,
            Config.PanUpdatesPerSecond, Config.ArrowUpdatesPerSecond,
            orientation_label()))
        return true
    end

    function runtime.SetAreaMapAvailable(available, reason)
        if available ~= nil then available = available == true end
        local changed = state.area_map_available ~= available
        state.area_map_available = available
        state.area_map_reason = tostring(reason or "unspecified")
        if changed and available == true then
            -- Force the retained native surface to jump from any old/clamped
            -- center to the current player position on its next normal pan tick.
            state.last_pan_x, state.last_pan_y = nil, nil
            state.last_map_rotation_angle = nil
        end
        apply_area_presentation()
        if changed then
            state.overlay_refresh_requested = true
            local background = available == false
                and (transparent_no_map_background() and "transparent" or "native-fog")
                or "native-map"
            debug_log("AreaMapAvailable=" .. tostring(available)
                .. " reason=" .. state.area_map_reason
                .. " source=" .. tostring(state.area_map_source or "unknown")
                .. " area=" .. tostring(state.area_map_area_id or "unknown")
                .. " background=" .. background)
        end
    end

    local function widget_visibility(widget)
        if widget == nil then return "nil" end
        local ok, value = pcall(widget.GetVisibility, widget)
        if not ok then return "unavailable" end
        return tostring(value)
    end

    function runtime.EmitSummary(reason)
        local no_map_state = no_map()
        local transparent = transparent_no_map_background()
        local cloud = cloud_no_map_background()
        local expected_map = no_map_state and VIS_COLLAPSED or VIS_HIT_TEST_INVISIBLE
        local expected_backdrop = transparent and VIS_COLLAPSED or VIS_HIT_TEST_INVISIBLE
        local expected_cloud = cloud and VIS_HIT_TEST_INVISIBLE or VIS_COLLAPSED
        local expected_arrow = Config.ShowArrow and VIS_HIT_TEST_INVISIBLE or VIS_COLLAPSED
        log(string.format(
            "Renderer diagnostic areaDiagSeq=%d reason=%s built=%s visible=%s hideReason=%s areaAvailable=%s noMap=%s mode=%s orientation=%s shape=%s circleRetain=%s circleOpacity=%s opacity=%.2f appliedOpacity=%.3f playerYaw=%s cameraYaw=%s mapAngle=%s cameraSource=%s cameraManager=%s mapSurface=%s expectedVis(widget=%s frame=%s backdrop=%d cloud=%d map=%d arrow=%d) actualVis(widget=%s frame=%s backdrop=%s cloud=%s map=%s arrow=%s) retainedCloud=%s cloudMaterial=%s cloudTexture=%s player=(%s,%s,%s) mapCenter=(%s,%s) lastPan=(%s,%s) widgetCounter=%d",
            tonumber(state.area_map_diag_sequence) or 0,
            tostring(reason or "manual"), tostring(state.built), tostring(state.visible),
            tostring(state.hide_reason), tostring(state.area_map_available),
            tostring(no_map_state), Config.TransparentNoMapBackground ~= false and "Transparent" or "Cloud",
            orientation_label(), tostring(Config.MapShape or "square"),
            tostring(state.circle_retainer_retained),
            state.retained.opacity_box ~= nil
                and (state.circle_opacity_retained and "outer-retained" or "pass-through") or "frame",
            tonumber(Config.Opacity) or 1.0,
            tonumber(state.circle_opacity_applied) or tonumber(Config.Opacity) or 1.0,
            tostring(state.player_yaw or "unknown"), tostring(state.camera_yaw or "unknown"),
            tostring(state.map_rotation_angle or 0.0), tostring(state.camera_heading_source or "unknown"),
            tostring(valid(state.camera_manager)), tostring(map_surface_size()),
            tostring(state.visible and VIS_HIT_TEST_INVISIBLE or VIS_COLLAPSED),
            tostring(state.built and VIS_HIT_TEST_INVISIBLE or VIS_COLLAPSED),
            expected_backdrop, expected_cloud, expected_map, expected_arrow,
            widget_visibility(state.retained.widget), widget_visibility(state.retained.frame),
            widget_visibility(state.retained.backdrop), widget_visibility(state.retained.cloud),
            widget_visibility(state.retained.map_widget), widget_visibility(state.retained.arrow),
            tostring(state.retained.cloud ~= nil), tostring(valid(state.retained.cloud_material)),
            tostring(valid(state.retained.cloud_texture)),
            tostring(state.player_world_x or "unknown"),
            tostring(state.player_world_y or "unknown"),
            tostring(state.player_world_z or "unknown"),
            tostring(state.map_center_world_x or "unknown"),
            tostring(state.map_center_world_y or "unknown"),
            tostring(state.last_pan_x or "unknown"), tostring(state.last_pan_y or "unknown"),
            tonumber(state.widget_counter) or 0))
        local performance = state.performance or {}
        log(string.format(
            "Renderer performance reason=%s poseCalls=%d poseSuccesses=%d panDue=%d arrowDue=%d panWrites=%d panSkips=%d rotationWrites=%d rotationSkips=%d arrowWrites=%d arrowSkips=%d geometryChanges=%d overlayRuns=%d overlaySkips=%d projectionContextUpdates=%d retainedPanValue=true summaryOnly=true",
            tostring(reason or "manual"),
            tonumber(performance.pose_calls) or 0,
            tonumber(performance.pose_successes) or 0,
            tonumber(performance.pan_due) or 0,
            tonumber(performance.arrow_due) or 0,
            tonumber(performance.pan_writes) or 0,
            tonumber(performance.pan_skips) or 0,
            tonumber(performance.rotation_writes) or 0,
            tonumber(performance.rotation_skips) or 0,
            tonumber(performance.arrow_writes) or 0,
            tonumber(performance.arrow_skips) or 0,
            tonumber(performance.map_geometry_changes) or 0,
            tonumber(performance.overlay_update_runs) or 0,
            tonumber(performance.overlay_update_skips) or 0,
            tonumber(performance.projection_context_updates) or 0))
        return true
    end

    function runtime.SetVisibility(hide, reason)
        local visible = not hide
        if visible == state.visible and reason == state.hide_reason then return end
        if visible ~= state.visible and state.retained.widget ~= nil then
            pcall(state.retained.widget.SetVisibility, state.retained.widget,
                visible and VIS_HIT_TEST_INVISIBLE or VIS_COLLAPSED)
        end
        if visible ~= state.visible then
            debug_log("Visibility=" .. tostring(visible) .. " reason=" .. tostring(reason))
        end
        state.visible = visible
        state.hide_reason = reason
    end

    local function read_pose(player)
        local location = player:K2_GetActorLocation()
        local rotation = player:K2_GetActorRotation()
        return tonumber(location.X), tonumber(location.Y), tonumber(location.Z),
            tonumber(rotation.Yaw)
    end

    local function angle_delta(a, b)
        return ((a - b + 180.0) % 360.0) - 180.0
    end

    local function read_camera_yaw()
        local manager = state.camera_manager
        if not valid(manager) then
            manager = resolve_camera_manager(state.controller)
            state.camera_manager = manager
        end
        if not valid(manager) then
            state.camera_heading_source = "PlayerCameraManager unavailable"
            return nil
        end
        local ok_rotation, rotation = pcall(manager.GetCameraRotation, manager)
        local camera_yaw = ok_rotation and rotation ~= nil and tonumber(rotation.Yaw) or nil
        if camera_yaw == nil then
            state.camera_heading_source = "GetCameraRotation unavailable"
            return nil
        end
        state.camera_yaw = camera_yaw
        state.camera_heading_source = "PlayerCameraManager:GetCameraRotation"
        state.camera_heading_error_logged = false
        return camera_yaw
    end

    function runtime.UpdatePose()
        local performance = state.performance or {}
        state.performance = performance
        performance.pose_calls = (tonumber(performance.pose_calls) or 0) + 1
        local ok, world_x, world_y, world_z, yaw = pcall(read_pose, state.player)
        if not ok or world_x == nil or world_y == nil or yaw == nil then
            local pawn_ok, pawn = pcall(state.controller.GetPawn, state.controller)
            pawn = unwrap(pawn_ok and pawn or nil)
            if pawn ~= nil then
                state.player = pawn
                ok, world_x, world_y, world_z, yaw = pcall(read_pose, state.player)
            end
        end
        if not ok or world_x == nil or world_y == nil or yaw == nil then
            state.pose_error_streak = state.pose_error_streak + 1
            if state.pose_error_streak >= 90 and not state.pose_error_logged then
                state.pose_error_logged = true
                log("Pose unavailable for 90 consecutive updates; preserving the native widget until recovery or LoadMap")
            end
            return false, false, false
        end
        state.pose_error_streak = 0
        state.pose_error_logged = false
        state.player_world_x = world_x
        state.player_world_y = world_y
        state.player_world_z = world_z
        state.player_yaw = yaw
        if type(ctx.AreaMapState) == "table"
            and type(ctx.AreaMapState.ObservePose) == "function" then
            ctx.AreaMapState.ObservePose(world_x, world_y, world_z)
        end
        state.visible_step_count = state.visible_step_count + 1

        -- Retained-controller refresh handles legitimate in-world pawn replacement without scans.
        if state.visible_step_count % 150 == 1 then
            local pawn_ok, pawn = pcall(state.controller.GetPawn, state.controller)
            pawn = unwrap(pawn_ok and pawn or nil)
            if pawn ~= nil then state.player = pawn end
            if camera_heading_enabled() and not valid(state.camera_manager) then
                state.camera_manager = resolve_camera_manager(state.controller)
            end
        end

        -- Fractional phase scheduling makes every offered 5..60 Hz choice real.
        -- Lifecycle supplies a 16/17 ms cadence at 60 Hz and analogous fractional
        -- cadences below it; each channel independently skips base-rate ticks.
        local base_hz = math.max(5, math.min(60, math.max(
            tonumber(Config.PanUpdatesPerSecond) or 30,
            tonumber(Config.ArrowUpdatesPerSecond) or 30)))
        state.pan_update_phase = (tonumber(state.pan_update_phase) or 0)
            + math.max(1, math.min(60, tonumber(Config.PanUpdatesPerSecond) or 30))
        local pan_due = state.pan_update_phase >= base_hz
        if pan_due then state.pan_update_phase = state.pan_update_phase - base_hz end
        if pan_due then performance.pan_due = (tonumber(performance.pan_due) or 0) + 1 end

        state.arrow_update_phase = (tonumber(state.arrow_update_phase) or 0)
            + math.max(1, math.min(60, tonumber(Config.ArrowUpdatesPerSecond) or 30))
        local arrow_due = state.arrow_update_phase >= base_hz
        if arrow_due then state.arrow_update_phase = state.arrow_update_phase - base_hz end
        if arrow_due then performance.arrow_due = (tonumber(performance.arrow_due) or 0) + 1 end

        local map_geometry_changed = state.overlay_refresh_requested == true

        local camera_yaw = nil
        if camera_heading_enabled() and (pan_due or arrow_due) then
            camera_yaw = read_camera_yaw()
            if camera_yaw == nil and not state.camera_heading_error_logged then
                state.camera_heading_error_logged = true
                log("Camera heading unavailable; Camera heading up will retain the last valid orientation until PlayerCameraManager recovers")
            end
        end

        -- Apply one map-surface rotation at the same bounded rate as native panning.
        -- POI/pin projection receives this exact successfully-applied angle on the
        -- same scheduler step, keeping the retained native surface and overlays aligned.
        if pan_due and state.retained.map_widget ~= nil then
            local desired_map_angle = 0.0
            local mode = orientation_mode()
            if mode == "camera" then
                desired_map_angle = camera_yaw ~= nil
                    and MapScale.CameraHeadingMapAngle(camera_yaw)
                    or tonumber(state.map_rotation_angle) or 0.0
            elseif mode == "player" then
                desired_map_angle = MapScale.PlayerHeadingMapAngle(yaw) or 0.0
            end
            if state.last_map_rotation_angle == nil
                or math.abs(angle_delta(desired_map_angle,
                    state.last_map_rotation_angle)) >= MAP_ROTATION_IDLE_EPSILON_DEGREES then
                local write_ok = pcall(state.retained.map_widget.SetRenderTransformAngle,
                    state.retained.map_widget, desired_map_angle)
                if write_ok then
                    state.map_rotation_angle = desired_map_angle
                    state.last_map_rotation_angle = desired_map_angle
                    map_geometry_changed = true
                    performance.rotation_writes = (tonumber(performance.rotation_writes) or 0) + 1
                elseif not state.engine_write_error_logged then
                    state.engine_write_error_logged = true
                    log("Native map rotation write failed; retaining the last synchronized orientation until the next LoadMap boundary")
                end
            else
                performance.rotation_skips = (tonumber(performance.rotation_skips) or 0) + 1
            end
        end

        if pan_due and state.retained.map_widget ~= nil
            and state.area_map_available ~= false then
            local pan_x, pan_y = MapScale.WorldPanNormalized(world_x, world_y)
            local world_units_per_pixel = (Config.ZoomMeters * 100.0) / Config.Size
            local threshold = (world_units_per_pixel * PAN_IDLE_EPSILON_PIXELS) / WORLD_SPAN_UNITS
            local delta_x = state.last_pan_x ~= nil and pan_x - state.last_pan_x or 0.0
            local delta_y = state.last_pan_y ~= nil and pan_y - state.last_pan_y or 0.0
            if state.last_pan_x == nil or delta_x * delta_x + delta_y * delta_y >= threshold * threshold then
                state.pan_position_value = state.pan_position_value or { X = 0.5, Y = 0.5 }
                state.pan_position_value.X, state.pan_position_value.Y = pan_x, pan_y
                local write_ok = pcall(state.retained.map_widget.SetPanCenterNormalized,
                    state.retained.map_widget, state.pan_position_value)
                if write_ok then
                    state.last_pan_x, state.last_pan_y = pan_x, pan_y
                    state.map_center_world_x, state.map_center_world_y = world_x, world_y
                    map_geometry_changed = true
                    performance.pan_writes = (tonumber(performance.pan_writes) or 0) + 1
                elseif not state.engine_write_error_logged then
                    state.engine_write_error_logged = true
                    log("Native map pan write failed; rendering retained until the next LoadMap boundary")
                end
            else
                performance.pan_skips = (tonumber(performance.pan_skips) or 0) + 1
            end
        end

        if Config.ShowArrow and arrow_due and state.retained.arrow ~= nil then
            -- North-up: playerYaw-90. Camera-heading-up yields playerYaw-cameraYaw.
            -- Player-heading-up adds 90-playerYaw, keeping the arrow straight up.
            local angle = MapScale.NormalizeDegrees(
                yaw + PLAYER_ARROW_ANGLE_OFFSET + (tonumber(state.map_rotation_angle) or 0.0))
            if state.last_yaw == nil or math.abs(angle_delta(angle, state.last_yaw)) >= 0.5 then
                local write_ok = pcall(state.retained.arrow.SetRenderTransformAngle, state.retained.arrow, angle)
                if write_ok then
                    state.last_yaw = angle
                    performance.arrow_writes = (tonumber(performance.arrow_writes) or 0) + 1
                elseif not state.engine_write_error_logged then
                    state.engine_write_error_logged = true
                    log("Player-arrow write failed; rendering retained until the next LoadMap boundary")
                end
            else
                performance.arrow_skips = (tonumber(performance.arrow_skips) or 0) + 1
            end
        end
        performance.pose_successes = (tonumber(performance.pose_successes) or 0) + 1
        if map_geometry_changed then
            performance.map_geometry_changes =
                (tonumber(performance.map_geometry_changes) or 0) + 1
        end
        return true, map_geometry_changed, pan_due
    end

    runtime.PlayerArrowPivotX = PLAYER_ARROW_PIVOT_X
    runtime.PlayerArrowPivotY = PLAYER_ARROW_PIVOT_Y
    runtime.PlayerArrowLayout = player_arrow_layout

    return runtime
end

return Factory
