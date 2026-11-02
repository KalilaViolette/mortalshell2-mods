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

    -- v0.19.2. Same mechanism as Runtime/Lifecycle's tick stages and gated by the same
    -- switch, because it answers the same question: a native access violation kills the
    -- process without unwinding, pcall cannot catch it, and the only thing left is the
    -- last line that reached the log. Used around the class-default write below, where a
    -- crash would otherwise be indistinguishable from a crash anywhere else in Build.
    -- One boolean test per call when the switch is off.
    local function crumb(name)
        if Config.LocalDiscoveryTrace == true then
            print("[MortalShell2Minimap] Build crumb step=" .. tostring(name) .. "\n")
        end
    end

    -- THE POSE PATH HAD NO CRUMBS, AND THAT COST A DIAGNOSIS. v0.23.24.
    --
    -- 2026-09-17: a crash during her manual play ended with "Tick stage=pose" as the last
    -- line in the log and nothing after it. Every other tick stage leaves a trail of
    -- crumbs; pose, which is the one that writes to retained engine objects every frame,
    -- left none -- so the log named the stage and stopped, and the minidump only said
    -- "null read at +0x40 somewhere inside UE4SS".
    --
    -- An access violation kills the process without unwinding, so pcall cannot catch it
    -- and the ONLY evidence is the last line that reached the log. That makes a crumb
    -- before each native call the difference between a named call and a shrug.
    --
    -- Gated on the same switch as the build crumbs (Config.LocalDiscoveryTrace), which is
    -- one boolean test per call when it is off -- and off is the shipped default, so this
    -- costs nothing in normal play. Invariant 0l: a diagnostic is held to the same
    -- performance rules as the thing it diagnoses.
    local function pose_crumb(name)
        -- v0.23.43: TraceHotPaths, not LocalDiscoveryTrace. MEASURED over her 502 s
        -- session: this family alone printed 68,644 lines, 137 per second, and the
        -- crash hunt these were written for is done. Invariant 0l -- a diagnostic
        -- is held to the same performance rules as the thing it diagnoses -- and a
        -- per-frame print on the pose path fails that now it has stopped earning
        -- its keep. The scheduler and Tick stage crumbs stay on the old flag
        -- because they are 1% of the volume and they are what is currently
        -- instrumenting the OPEN death-and-reload crash.
        if Config.TraceHotPaths == true then
            print("[MortalShell2Minimap] Pose crumb step=" .. tostring(name) .. "\n")
        end
    end

    local ASSET = {
        tile_set = "/Game/Sparta/UI/World/Map/Blueprints/DT_MapTiles.DT_MapTiles",
        tile_material = "/Game/Sparta/UI/World/Map/Materials/MI_SpartaMapTile.MI_SpartaMapTile",
        -- v0.19.11. The game's own fogged world painting, 4096 square. Used only by the
        -- "Masked map test" diagnostic, as something unmistakable to mask.
        map_full_fog = "/Game/Sparta/UI/World/Map/Textures/T_UI_Map_Full_Fog.T_UI_Map_Full_Fog",
        -- v0.23.0: the CLEAR world painting. Layer B draws this through the discovery
        -- mask, which is white exactly where she has been -- so her collected tiles are
        -- punched back through the fog without anything being inverted.
        map_full_nofog = "/Game/Sparta/UI/World/Map/Textures/T_UI_Map_Full_NoFog.T_UI_Map_Full_NoFog",
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
        -- v0.19.2. The class default object for the above. Writing GlobalAlphaMask here
        -- and constructing immediately afterwards is the only way to have the property
        -- already set when the widget's own constructor reads it -- see the long note at
        -- the construction site. Restored the instant the widget exists.
        sparta_map_widget_cdo = "/Script/Sparta.Default__SpartaMapWidget",
        -- v0.19.7. UKismetMaterialLibrary, for CreateDynamicMaterialInstance.
        material_library = "/Script/Engine.Default__KismetMaterialLibrary",
    }

    -- v0.20.3. M_SpartaMapTile animates its fog, and MI_SpartaMapTile ships these values.
    -- They are tuned for the full-screen world map, where a UV drift of 0.005 a second
    -- across the whole world is a slow, atmospheric crawl. The minimap crops that world
    -- to about a fortieth, so the same numbers become roughly forty times faster relative
    -- to what is on screen -- a churn rather than a drift. Scaling them by the visible
    -- span puts the apparent speed back where the artists set it.
    local FOG_MOTION = {
        { name = "Distortion_Speed_X", value = 0.005 },
        { name = "Distortion_Speed_Y", value = 0.005 },
        { name = "DistortionAmount", value = 0.05 },
        { name = "Wind_Speed", value = 0.05 },
        -- v0.20.4: these two as well. Her 17:15 log has "Fog motion applied mode=off
        -- factor=0.0000" and the fog still moved, so zeroing the four speed and amount
        -- scalars is not enough on its own -- something else in the graph is reading
        -- time. WindFactor multiplies the wind and RandomizeTime is named for exactly
        -- what it sounds like. Zeroing them costs nothing if they turn out to be
        -- innocent.
        { name = "WindFactor", value = 2.0 },
        { name = "RandomizeTime", value = 1.0 },
    }

    -- THE GAME'S OWN VALUES, read out of MI_SpartaMapTile's cooked export. v0.22.7.
    --
    --     Density 200.0   Low 0.0   High 0.55   RevealAmount 1.0
    --
    -- Two things fall out of that list. Density is 200, and the probe that set it to 1.0
    -- made the fog vanish completely -- not subtly wrong, 200 times too weak. And High is
    -- 0.55, which is exactly where the mystery disc's edge was measured (0.55 to 0.59 of
    -- the radius, across every run). A parameter whose shipped value matches the observed
    -- radius to two figures is not a coincidence: High is the extent, and the "radial
    -- falloff of unknown origin" was this material doing precisely what it was tuned to
    -- do for a full-screen world map.
    --
    -- High is raised to 1.0 here because our quad IS the view: the fog should reach the
    -- edge of the minimap and be carved back by the mask, not stop at 55%% of it.
    -- Everything else is the game's own number.
    local FOG_FALLOFF = {
        { name = "Low", value = 0.0 },
        { name = "High", value = 1.0 },
        { name = "Density", value = 200.0 },
    }

    local function fog_motion_factor(span)
        local mode = tostring(Config.FogMotion or "off"):lower()
        if mode == "full" then return 1.0 end
        if mode == "gentle" then
            span = tonumber(span) or 0.04
            return span > 0 and span or 0.04
        end
        return 0.0
    end

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
    -- CANVAS STACKING. v0.23.3: named, and renumbered to make room.
    --
    -- Layer C (the clear world under the fog) has to sit between the game's own tile
    -- widget and our fog, and SetZOrder takes an integer, so the two layers above it move
    -- up one. They were scattered as bare 3 and 4 with comments saying "above the fog at
    -- 3", which is the kind of thing that survives exactly until someone inserts a layer.
    local Z_MAP = 2            -- the game's own SpartaMapWidget
    local Z_FOG_UNDERLAY = 3   -- layer C: the CLEAR world. Only drawn when fog opacity < 1
    local Z_FOG = 4            -- layer A: the fog
    local Z_FOG_REVEAL = 5     -- layer B: ground she has already discovered, drawn back
    local Z_ARROW = 10

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

    -- FOG OPACITY. v0.23.3.
    --
    -- Render opacity on the fog layer's own keeper widget. SetRenderOpacity is the same
    -- lever Config.Opacity has used on the frame since v0.9, so it is not a new bet: it
    -- is applied by Slate to the whole widget, which means it works on a MATERIAL brush
    -- where a brush tint's alpha may or may not survive the shader.
    --
    -- Layer A only. The clear ground she has already discovered is a separate widget one
    -- ZOrder above, and it stays at 1.0 -- otherwise turning the fog down would also fade
    -- the explored map, which is the opposite of the point.
    --
    -- A diagnostic always draws at full. Invariant 0l says a diagnostic is held to the
    -- same performance rules as the thing it diagnoses; the same reasoning applies to its
    -- honesty. A mask inspected at 40% opacity looks like a weak mask, and the whole
    -- reason these modes exist is that a fog bug and a fog that is merely faint have
    -- looked identical all week.
    -- FOG IS OFF IN A DUNGEON. v0.23.39, her decision 2026-09-17 after a screenshot of
    -- Castigator's Keep with the grey wash and the peek circle sitting over the world
    -- tiles: "trail logic shouldn't be active in a dungeon, as it doesn't have fog logic
    -- atm", and then, asked how far to take it, the whole layer.
    --
    -- Asked of FogLayer rather than decided here, so one module owns the answer and the
    -- trail, the redraws and the marker fade all agree with what is on screen. A dungeon
    -- is state.area_map_available == false: the same signal DungeonView.Wanted() uses.
    local function fog_suppressed()
        return type(ctx.Fog) == "table" and type(ctx.Fog.Suppressed) == "function"
            and ctx.Fog.Suppressed() == true
    end

    local function fog_opacity_target()
        -- Zero is the suppressed marker, not an opacity: apply_fog_opacity collapses the
        -- layers at zero rather than drawing three full-size Images at opacity 0, which
        -- costs the same as drawing them.
        if fog_suppressed() then return 0.0 end
        if tostring(Config.FogDiagnostic or "off") ~= "off" then return 1.0 end
        return math.max(0.10, math.min(1.0, tonumber(Config.FogOpacity) or 1.0))
    end

    -- `keeper` is passed in ONLY from the build, which holds the live one in a local.
    -- state.retained is not that table yet: Build() works in a fresh `retained` and only
    -- publishes it at the very end, so reading state.retained mid-build hands back the
    -- PREVIOUS build's widgets -- dead wrappers into a torn-down tree (invariant 0e).
    -- Everywhere else the published table is correct and the argument is omitted.
    -- At 1.00 the fog is opaque and the clear layer beneath it can contribute nothing, so
    -- it is COLLAPSED rather than drawn and thrown away. That is what keeps the shipped
    -- default costing nothing: a widget in memory and not one drawn pixel.
    -- How finely the fog view crop follows the pan, in samples per DISPLAYED pixel.
    -- 2 is half a pixel. See the long note at the crop gate for why this is not 3072.
    local VIEW_CROP_SAMPLES_PER_PIXEL = 2.0

    local FOG_OPAQUE_EPSILON = 0.999

    local function apply_fog_opacity(keeper, underlay)
        keeper = keeper or (state.retained and state.retained.fog_keeper)
        underlay = underlay or (state.retained and state.retained.fog_underlay_keeper)
        if keeper == nil or not valid(keeper) then return false end
        local target = fog_opacity_target()
        if state.fog_opacity_applied == target then return true end
        local suppressed = target <= 0.0
        -- Collapsed, not transparent. FogDiagnostic=nolayers measured the minimap with
        -- every fog Image removed as IDENTICAL to fog-off (0.16 mean against a 1.8 noise
        -- floor), which is exactly the picture a dungeon should get.
        local shown = suppressed and VIS_COLLAPSED or VIS_HIT_TEST_INVISIBLE
        pcall(keeper.SetVisibility, keeper, shown)
        local reveal = state.retained and state.retained.fog_reveal_keeper or nil
        if valid(reveal) then pcall(reveal.SetVisibility, reveal, shown) end
        local overlay = state.retained and state.retained.fog_overlay or nil
        if valid(overlay) then pcall(overlay.SetVisibility, overlay, shown) end
        local ok = pcall(keeper.SetRenderOpacity, keeper, suppressed and 1.0 or target)
        if ok then state.fog_opacity_applied = target end
        if valid(underlay) then
            pcall(underlay.SetVisibility, underlay,
                (not suppressed and target < FOG_OPAQUE_EPSILON)
                    and VIS_HIT_TEST_INVISIBLE or VIS_COLLAPSED)
        end
        -- Read it back. Invariant 0b: a pcall that returned true is not evidence the
        -- value landed, and this one is cheap to check because UWidget exposes it.
        local ok_read, got = pcall(keeper.GetRenderOpacity, keeper)
        -- log, not debug_log. This call is NEW and unproven, it runs once per change
        -- rather than per frame, and the first run of it produced a sweep of five
        -- screenshots that were identical to the pixel with no way to tell whether the
        -- write had landed or the write had landed and done nothing. Those need
        -- completely different fixes. It goes back to debug_log once it is proven.
        log(string.format("Fog opacity wanted=%.2f set=%s got=%s underlay=%s%s",
            target, tostring(ok),
            (ok_read and got ~= nil) and string.format("%.2f", tonumber(got) or -1) or "unreadable",
            valid(underlay) and ((target < FOG_OPAQUE_EPSILON) and "drawn" or "collapsed") or "absent",
            tostring(Config.FogDiagnostic or "off") ~= "off" and " (forced to 1.00: a diagnostic is running)" or ""))
        return ok
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
        -- THE FOG LAYERS STAND DOWN WITH THE TILES. v0.23.54.
        --
        -- v0.23.39 made the fog suppress itself in a dungeon and it never once happened,
        -- because fog_suppressed() is a LIVE condition and nothing re-evaluated it.
        -- apply_fog_opacity() was reachable from exactly two places: a build, and the
        -- user moving the fog-opacity row. Entering a dungeon is neither -- it is a
        -- pose-bounds crossing -- so the three fog Images stayed at full opacity on top
        -- of the dungeon capture.
        --
        -- Her report: "just entered a dungeon and its not using dungeon view ... maybe
        -- our fog mask is rendering over dungeon view". It was. And her own workaround
        -- proves the diagnosis: toggling FogDiagnostic off -> show -> off fixed it,
        -- because a settings change is one of the two things that DID reach this call.
        -- MEASURED in her log: the last "Fog opacity" line is 13:56:20 and the dungeon
        -- engaged at 13:57:51, with nothing in between.
        --
        -- Here, because this function is already the one moment the area map flips --
        -- SetAreaMapAvailable writes the shared flag and then calls it, so Suppressed()
        -- reads the new value -- and because the tiles standing down and the fog standing
        -- down are the same decision. Free when nothing changed: apply_fog_opacity()
        -- returns on a target it has already applied.
        apply_fog_opacity()
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

    -- THE FOG IS AS BIG AS THE MAP SURFACE, NOT AS BIG AS THE FRAME. v0.23.40.
    --
    -- Her report, camera-heading-up with a square map: "the fog doesn't extend far enough
    -- to cover the corners", and the screenshot shows the map's own artwork through all
    -- four corners around a grey diamond.
    --
    -- map_surface_size() already knows this: a rotating SQUARE viewport needs its
    -- DIAGONAL to cover the corners, so it returns normal * SQRT_TWO. The map widget got
    -- that. The fog layers were built at {2,2} and Size-4 -- the frame, not the surface --
    -- so they were always a rotating square inscribed in the frame, and rotating one
    -- exposes the corners by construction.
    --
    -- The fog cannot simply be made bigger, though: the crop that fills it is taken at a
    -- span matching what the map SHOWS. Stretch the widget without widening the crop and
    -- the peek circle grows by the same factor and stops matching the world. So the two
    -- move together through this one number, and the crop span below is multiplied by it.
    local function fog_surface_scale()
        local normal = math.max(1.0, (tonumber(Config.Size) or 280.0) - 4.0)
        local surface = map_surface_size()
        if surface <= 0 or normal <= 0 then return 1.0 end
        return surface / normal
    end

    -- ONE WRITER FOR THE MAP'S ANGLE. v0.23.40.
    --
    -- HER SCREENSHOT IS THE PROOF, and square shape is what made it visible: a grey
    -- DIAMOND sitting on a square minimap, rotated about 45 degrees, with the map's own
    -- artwork showing in the corners the diamond no longer covered. A circle hides this
    -- completely -- a rotated circle is the same circle -- which is why it survived every
    -- previous look.
    --
    -- The fault: the fog layers rotate with the map, and TWO code paths wrote that angle.
    -- The per-tick block wrote the map widget AND the three fog keepers.
    -- apply_orientation_layout wrote ONLY the map widget, and then set
    -- last_map_rotation_angle = 0 -- which makes the per-tick block skip its write as
    -- "nothing changed". So on a live switch from camera-heading to north the map snapped
    -- to 0 and the fog kept whatever angle the camera happened to be at, forever.
    --
    -- Her log says exactly that: booted orientation=camera, ran camera-heading-up for
    -- ninety seconds, then "Setting MapOrientation=north via=change" at 11:54:40. The
    -- "odd angle" she could not pin down is the camera yaw at the instant she flipped the
    -- setting, frozen.
    --
    -- It also explains the rest of her report without needing a second bug: the arrow
    -- reads state.map_rotation_angle, which IS 0, so the arrow was right; the icons never
    -- rotate, so they were right; and what she read as "the map tile" was mostly the fog
    -- wash and the revealed shapes painted into its mask, which are the things that were
    -- actually turned.
    --
    -- This is the SAME failure mode as the resize bug fixed hours ago: a set of widgets
    -- that one code path knows about and another does not. So the angle now has exactly
    -- one writer, and the suite asserts that SetRenderTransformAngle is never called on a
    -- fog keeper anywhere else.
    local function write_map_angle(angle)
        local retained = state.retained
        if retained == nil then return false end
        local map_widget = retained.map_widget
        if map_widget == nil or not valid(map_widget) then return false end
        local ok = pcall(map_widget.SetRenderTransformAngle, map_widget, angle)
        if not ok then return false end
        -- v0.20.2: the fog turns with the map, or it is painted onto the screen instead
        -- of onto the world. v0.23.3 made that all three layers. v0.23.40 makes it the
        -- same call as the map's, so they cannot come apart again.
        for _, widget in ipairs({ retained.fog_keeper, retained.fog_reveal_keeper,
                                  retained.fog_underlay_keeper }) do
            if valid(widget) then
                pcall(widget.SetRenderTransformAngle, widget, angle)
            end
        end
        return true
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
            -- The fog layers go to zero WITH the map. Writing only the map here, and then
            -- recording 0 as the last written angle, is what left the fog turned.
            write_map_angle(0.0)
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
    -- Every canvas slot that is built at the cloud slot's geometry and must therefore
    -- follow Config.Size. A new fog layer adds its slot key HERE and nowhere else; the
    -- suite asserts this list covers every retained.fog_*_slot the builder assigns.
    -- The fog view crop only re-runs when the quantised window or the span CHANGES, so a
    -- setting that moves the picture without moving the player has to say so. Both size
    -- and range do: span is EffectiveVisibleMeters(Size, ZoomMeters), which is a function
    -- of BOTH. Clearing the window forces the next pose tick to crop rather than trusting
    -- a comparison against numbers from the old layout.
    local function invalidate_fog_view()
        state.fog_view_qx, state.fog_view_qy, state.fog_view_span = nil, nil, nil
    end

    local FOG_SIZED_SLOTS = {
        "fog_keeper_slot",
        "fog_underlay_slot",
        "fog_reveal_slot",
        "fog_composite_slot",
    }

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
        -- AND THE FOG LAYERS. v0.23.39, her report: "resizing the map and changing the
        -- range offsets your fog to where it was being drawn previously screen x, y
        -- position ... you can see the edge of the fog layer being dragged in to where it
        -- shouldn't be seen."
        --
        -- Every fog Image is built at ({2,2}, Size-4) -- the cloud slot's geometry, four
        -- lines up -- and NONE of them was relaid out here. So the map, the frame, the
        -- backdrop, the cloud and the arrow all followed the new size and four full-size
        -- Images stayed at the old one, still centred where the old circle was. Her
        -- screenshot is a 320 px minimap with the wash from the larger size hanging off it.
        --
        -- Listed in one loop rather than five copies of the same two calls, because the
        -- reason this bug existed is that adding a fog layer meant remembering to add a
        -- line here, and three releases of fog layers did not.
        -- v0.23.40: at the MAP SURFACE's size and centred the way the map slot is, not
        -- at the frame's. A rotating square needs its diagonal or its corners show.
        local fog_surface = map_surface_size()
        for _, slot_key in ipairs(FOG_SIZED_SLOTS) do
            local slot = retained[slot_key]
            if slot ~= nil then
                pcall(set_centered_slot, slot, fog_surface, fog_surface)
            end
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
        invalidate_fog_view()
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
            -- Range changes the span the crop is taken at, and she reported the fog
            -- staying put for this as well as for size.
            invalidate_fog_view()
            state.overlay_refresh_requested = true
        elseif setting.apply == "opacity" and state.built and state.retained.frame ~= nil then
            apply_opacity()
        elseif setting.apply == "orientation" then
            apply_orientation_layout()
        elseif setting.apply == "arrow" and state.built and state.retained.arrow ~= nil then
            pcall(state.retained.arrow.SetVisibility, state.retained.arrow,
                Config.ShowArrow and VIS_HIT_TEST_INVISIBLE or VIS_COLLAPSED)
        elseif setting.apply == "fog-motion" then
            if state.built and state.fog_overlay_material ~= nil
                and valid(state.fog_overlay_material) then
                local span = (tonumber(
                    MapScale.EffectiveVisibleMeters(Config.Size, Config.ZoomMeters))
                    or 121.0) / MapScale.WORLD_SPAN_METERS
                local motion = fog_motion_factor(span)
                pcall(function()
                    for _, p in ipairs(FOG_MOTION) do
                        state.fog_overlay_material:SetScalarParameterValue(
                            FName(p.name), p.value * motion)
                    end
                end)
                log("Fog motion applied mode=" .. tostring(Config.FogMotion)
                    .. " factor=" .. string.format("%.4f", motion))
            end
        elseif setting.apply == "fog-opacity" then
            -- Live, and free when nothing changed: apply_fog_opacity() returns early on
            -- a value it has already set, so a rebuild that re-runs it costs one compare.
            apply_fog_opacity()
        elseif setting.apply == "fog-mask" then
            -- v0.19.9. Live on purpose: RevealAmount's direction is not knowable from the
            -- cooked asset -- the shipped material carries no expression graph, only its
            -- parameter list -- so the value has to be found by sweeping it and watching
            -- the minimap. A row that needs a rebuild per step would make that a chore.
            local strength = tonumber(Config.FogMaskStrength) or 0.0
            if state.built and state.fog_overlay_material ~= nil
                and valid(state.fog_overlay_material) then
                pcall(function()
                    state.fog_overlay_material:SetScalarParameterValue(
                        FName("RevealAmount"), strength)
                end)
            end
            if state.built and valid(state.retained.fog_tile_material) then
                pcall(function()
                    state.retained.fog_tile_material:SetScalarParameterValue(
                        FName("RevealAmount"), strength)
                end)
            end
            if state.built and state.retained.map_widget ~= nil then
                pcall(state.retained.map_widget.SetRevealAmount,
                    state.retained.map_widget, strength)
            end
            log("Fog mask strength applied strength=" .. tostring(strength)
                .. " (live; the value that matters is the one present at the next build)")
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
        -- v0.19.4: the fog render target is owned by the keeper Image inside the tree
        -- that is being dropped right now. Letting the fog layer keep its handle across
        -- that boundary is what killed the 15:50:19 session -- teardown, build, silence.
        -- Every build makes its own target and its own keeper.
        if type(ctx.Fog) == "table" and type(ctx.Fog.DropTarget) == "function" then
            pcall(ctx.Fog.DropTarget)
        end
        state.fog_overlay_material = nil
        state.fog_uv_scale, state.fog_uv_x, state.fog_uv_y = nil, nil, nil
        -- v0.22.2: and the view-crop bookkeeping. state.fog_painting is a handle into the
        -- tree that is going away, and the quantised window must not survive a rebuild --
        -- a stale qx/qy would suppress the first refresh and leave the new build's targets
        -- showing whatever the uncleared memory held.
        state.fog_painting = nil
        state.fog_reveal_material = nil
        -- v0.23.3: layer C's material and the opacity that was written onto layer A's
        -- keeper. state.retained is replaced below, so the widgets go with it; these two
        -- live on `state` and would otherwise survive into the next build -- the material
        -- as a handle into a tree that no longer exists (invariant 0e), and the applied
        -- opacity as a value that makes the next build's first write look unnecessary and
        -- skip itself.
        state.fog_underlay_material = nil
        state.fog_opacity_applied = nil
        state.fog_view_cropped = false
        state.fog_view_qx, state.fog_view_qy, state.fog_view_span = nil, nil, nil
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

        -- "params" (v0.23.8): PRINT THE MATERIAL'S REAL PARAMETER NAMES.
        --
        -- The names on this material have been wrong three times, and every correction so
        -- far was a guess that happened to be checkable. TileTexture, GlobalMask,
        -- RegionMask and MapUVScaleOffset were all read off the widget's own usage rather
        -- than off the material, and the last measurement says the mask inputs do nothing
        -- on a plain UImage: maskwhite and maskblack, which are opposites, came back
        -- pixel-identical.
        --
        -- A material instance's own overrides ARE readable at runtime -- they are plain
        -- UPROPERTY arrays, not editor-only reflection -- so the game's instance names
        -- every parameter the game itself sets. Walking the Parent chain gets the ones an
        -- intermediate instance sets too. If GlobalMask is not in that list, the name was
        -- never right; if it is, the name is right and the UImage path is what ignores it,
        -- and those need different fixes.
        --
        -- Once per build, and only when asked for. No caller on the normal path.
        if tostring(Config.FogDiagnostic or "off") == "params" then
            local function dump_parameters(material, label, depth)
                if depth > 4 or not valid(material) then return end
                local name = "?"
                pcall(function() name = material:GetFullName() end)
                log(string.format("Fog material params [%s depth=%d] %s", label, depth, name))
                for _, field in ipairs({ "TextureParameterValues", "ScalarParameterValues",
                    "VectorParameterValues" }) do
                    local names = {}
                    pcall(function()
                        local array = material[field]
                        if array == nil then return end
                        array:ForEach(function(_, element)
                            local entry = element:get()
                            local pname = tostring(entry.ParameterInfo.Name:ToString())
                            names[#names + 1] = pname
                        end)
                    end)
                    log(string.format("  %s (%d): %s", field, #names,
                        #names > 0 and table.concat(names, ", ") or "none"))
                end
                local parent = nil
                pcall(function() parent = material.Parent end)
                if parent ~= nil and valid(parent) then
                    dump_parameters(parent, label, depth + 1)
                end
            end
            dump_parameters(tile_material, "MI_SpartaMapTile", 0)
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

            -- v0.19.2 FOG: BIND THE MASK BEFORE THE WIDGET EXISTS.
            --
            -- v0.19.0 and v0.19.1 called SetGlobalAlphaMask a few lines BELOW this one,
            -- after StaticConstructObject had already returned and after AddToViewport.
            -- That is the exact situation probes v1.11 through v1.13 measured and found
            -- dead: the property sticks under readback and not one pixel changes. So the
            -- "bind at build" step was never really tested -- it was tested at the same
            -- moment as the probes, which was already known not to work.
            --
            -- v0.19.1 proved the rest of the chain is sound. Its log says
            -- "Fog mask drawn: 7 textures, peek 8.1 px of 512, 6 regions held" and
            -- "Fog mask bound to the map widget (512x512, seeded=true)", and an offline
            -- composite of those same seven textures is 84% black -- if that mask were
            -- being applied, five sixths of the minimap would be gone. Nothing changed
            -- on screen. The mask is right; the moment of binding was wrong.
            --
            -- So: write the mask onto the CLASS DEFAULT OBJECT, construct, restore. A new
            -- UObject copies its class defaults during construction, which puts the value
            -- in place before the constructor can read it. The restore runs immediately
            -- and unconditionally, because the game's own world map screen constructs
            -- from the same CDO and must not inherit a minimap's mask.
            local fog_mask, map_cdo, saved_cdo_mask = nil, nil, nil

            -- v0.19.5. Same keeper pattern Overlay/LocalPool.lua has used since v0.10.14.
            -- A texture pulled in by LoadAsset has no owner in the engine's object graph,
            -- so the collector can take it back and the next draw goes through a dead
            -- pointer. A collapsed Image parked off screen, whose brush holds the texture,
            -- is a real reference from an object the viewport keeps alive.
            local pinned_fog_textures = 0
            local function pin_fog_texture(texture)
                if texture == nil or not valid(frame) then return false end
                local keeper = nil
                local ok = pcall(function()
                    keeper = unwrap(StaticConstructObject(u.image, frame,
                        make_name("FogTextureKeeper")))
                    assert(valid(keeper), "fog texture keeper construction failed")
                    local slot = unwrap(frame:AddChildToCanvas(keeper))
                    assert(valid(slot), "fog texture keeper slot failed")
                    slot:SetPosition({ X = -10000, Y = -10000 })
                    slot:SetSize({ X = 1, Y = 1 })
                    keeper:SetVisibility(VIS_COLLAPSED)
                    keeper:SetBrushFromTexture(texture, false)
                end)
                if not ok then
                    if keeper ~= nil and valid(keeper) then
                        pcall(keeper.RemoveFromParent, keeper)
                    end
                    return false
                end
                pinned_fog_textures = pinned_fog_textures + 1
                return true
            end

            if type(ctx.Fog) == "table" and type(ctx.Fog.MaskForBuild) == "function" then
                local fog_ok, mask = pcall(ctx.Fog.MaskForBuild, controller, pin_fog_texture)
                if fog_ok and mask ~= nil and valid(mask) then fog_mask = mask end
            end
            -- v0.19.3 ROOT THE RENDER TARGET, AND THIS IS THE CRASH.
            --
            -- Three sessions in a row died a minute or two in, always mid
            -- "Tick stage=pose", always with no fault marker of any kind. The cause was
            -- not the fog code being wrong; it was the fog target having no owner.
            --
            -- CreateRenderTarget2D hands back a UObject that nothing in the engine's
            -- object graph points at. A Lua handle is not a reference as far as Unreal's
            -- garbage collector is concerned, and SetGlobalAlphaMask evidently is not
            -- holding one either. So the collector reclaims it on its own schedule, and
            -- the next redraw writes into freed memory: access violation, no unwind,
            -- nothing in the log. The delay before each crash is the GC interval.
            --
            -- Map/DungeonView.lua has never had this problem because its target is owned
            -- twice over -- by an Image's brush and by the capture component's
            -- TextureTarget. This does the same thing the first way: a collapsed Image in
            -- our own tree, whose Brush.ResourceObject is a real UPROPERTY reference from
            -- an object the viewport already keeps alive. It draws nothing (unless the
            -- fog diagnostic asks it to); it exists to hold the reference.
            if fog_mask ~= nil then
                crumb("fog-keeper")
                -- One number for every fog layer built below, so a new layer cannot
                -- be given the frame's size by accident.
                local fog_layer_surface = map_surface_size()
                local keeper = unwrap(StaticConstructObject(u.image, frame, make_name("FogMaskKeeper")))
                if valid(keeper) then
                    -- A UTextureRenderTarget2D is a UTexture, so the proven
                    -- SetBrushFromTexture shape takes it; SetBrushResourceObject is the
                    -- documented alternative. Same two-step DungeonView uses.
                    local brush_ok = pcall(keeper.SetBrushFromTexture, keeper, fog_mask, false)
                    if not brush_ok then
                        brush_ok = pcall(keeper.SetBrushResourceObject, keeper, fog_mask)
                    end
                    local keeper_slot = unwrap(frame:AddChildToCanvas(keeper))
                    if valid(keeper_slot) then
                        -- v0.23.40: the MAP SURFACE's size, centred like the map slot. At the
                        -- frame's size a rotating square map shows its corners through the fog.
                        set_centered_slot(keeper_slot, fog_layer_surface, fog_layer_surface)
                        -- Above the map and the clear underlay, below the player arrow.
                        pcall(keeper_slot.SetZOrder, keeper_slot, Z_FOG)
                        retained.fog_keeper_slot = keeper_slot
                    end
                    -- Visible only when the diagnostic asks for it, which is how you see
                    -- the mask the fog layer actually built.
                    local diagnostic_mode = tostring(Config.FogDiagnostic or "off"):lower()
                    local show_mask = diagnostic_mode == "show" or diagnostic_mode == "material"

                    -- v0.19.11. THE LAST QUESTION, ASKED THE OTHER WAY ROUND.
                    --
                    -- v0.19.10 proved the widget KEEPS our material: after SetTileSet,
                    -- map_widget.TileMaterial reads back as our own
                    -- MaterialInstanceDynamic. The full sweep of RevealAmount then ran --
                    -- 0.0, 0.1, 0.25, 0.5, 0.75, 0.9, 1.0, each with its own rebuild --
                    -- and the minimap did not change by a single measurable pixel. So the
                    -- widget takes our material as a template and builds its own children
                    -- per tile, setting the mask inputs from its own state. We cannot
                    -- reach the tiles through it, the same way we could not reach them
                    -- through GlobalAlphaMask.
                    --
                    -- But the material itself is not the problem, and MI_SpartaMapTile
                    -- masks a texture by a mask for a living. So: put it on an Image of
                    -- OURS, feed it the game's fogged world painting as TileTexture and
                    -- the fog target as the mask, and look. If the painting appears only
                    -- inside the revealed shapes, the mechanism works and the fog layer
                    -- becomes two Images of our own -- the fogged map below, the clear map
                    -- masked above -- which is exactly what the game's own world map does.
                    -- If it does not, materials are finished too and the answer is an
                    -- overlay we draw ourselves.
                    -- v0.20.0 THE FOG OVERLAY, no longer a diagnostic.
                    --
                    -- Everything under this is now proven rather than hoped for. The
                    -- material masks a texture by our render target (one frame of her
                    -- 16:37 recording showed it doing exactly that, and v0.19.12 held it
                    -- still). The tile map keeps drawing the clear map underneath, with
                    -- its own LOD and its own pan, because we never needed to replace it
                    -- -- only to put fog on top of it.
                    --
                    -- So: an Image above the map, drawing the game's own fogged painting
                    -- through the INVERSE mask, so fog lands where the player has not
                    -- been. MapUVScaleOffset crops both to the view, so the fog moves
                    -- with the map instead of sitting in world space behind it.
                    -- "nolayers" (v0.23.8): build NONE of our own fog Images. The
                    -- minimap then shows the game's own tile widget and nothing else.
                    --
                    -- WHY IT EXISTS. maskwhite and maskblack came back PIXEL-IDENTICAL
                    -- (mean|diff| 0.00 over the whole minimap, 2026-09-17), and those two
                    -- are opposites: one says reveal everything, the other reveal
                    -- nothing. A mask that cannot change the picture is not masking, so
                    -- either the material ignores its mask inputs on a plain UImage or
                    -- our Images are not drawing at all. This mode separates those: if
                    -- the minimap still looks fogged with every one of our layers gone,
                    -- the fog on screen is the game's own widget and our three layers
                    -- have been decoration.
                    local fog_layers_off = diagnostic_mode == "nolayers"
                    if fog_layers_off then
                        log("Fog diagnostic NOLAYERS: none of the mod's own fog Images "
                            .. "are being built. Whatever fog is on screen after this is "
                            .. "the game's own map widget.")
                    end
                    local fog_overlay_ready = false
                    if not fog_layers_off and valid(u.material_library) and type(ctx.Fog) == "table"
                        and type(ctx.Fog.InverseTarget) == "function" then
                        crumb("fog-overlay")
                        local inverse = ctx.Fog.InverseTarget()
                        local painting = load_asset(ASSET.map_full_fog)
                        local overlay_mid = nil
                        if inverse ~= nil and valid(painting) then
                            pcall(function()
                                overlay_mid = unwrap(u.material_library:CreateDynamicMaterialInstance(
                                    controller, tile_material, make_name("FogOverlay"), 0))
                            end)
                        end
                        if valid(overlay_mid) then
                            local motion_span = (tonumber(
                                MapScale.EffectiveVisibleMeters(Config.Size, Config.ZoomMeters))
                                or 121.0) / MapScale.WORLD_SPAN_METERS
                            -- v0.23.40. The CROP span is not the motion span. The fog
                            -- widget is the map surface's size -- the diagonal when a
                            -- square map rotates -- so it must be filled from that much
                            -- more world or the peek circle comes out 1.414x too big.
                            -- The motion factor keeps reading the VISIBLE span, because
                            -- it is about how fast the material's fog drifts and that has
                            -- nothing to do with how much surface it is drawn on.
                            local crop_span = motion_span * fog_surface_scale()
                            if crop_span > 1.0 then crop_span = 1.0 end
                            local motion = fog_motion_factor(motion_span)
                            -- v0.22.2. THE MATERIAL IS FED THE VIEW, NOT THE WORLD.
                            --
                            -- Both of these used to be world-space: the whole 3155 m
                            -- painting and the whole-world mask, with MapUVScaleOffset
                            -- expected to crop them. It does not -- measured, the value
                            -- reads back exact and the overlay still draws the entire
                            -- world over the real minimap. That parameter belongs to the
                            -- game's tile widget.
                            --
                            -- So FogLayer crops both onto its own targets with the
                            -- canvas uv arguments it has used since v0.19.1, and the
                            -- material samples them edge to edge. Bound ONCE here: the
                            -- targets are stable objects whose CONTENTS change, so there
                            -- is nothing to rewrite per tick.
                            local view_painting, view_mask = nil, nil
                            local view_clear, view_white = nil, nil
                            if type(ctx.Fog.ViewTargets) == "function" then
                                local ok_v, vp, vm, vc, vw = pcall(ctx.Fog.ViewTargets, controller)
                                if ok_v then
                                    view_painting, view_mask = vp, vm
                                    view_clear, view_white = vc, vw
                                end
                            end
                            -- The clear painting is loaded here, where asset loading lives,
                            -- and handed down once.
                            local clear_painting = load_asset(ASSET.map_full_nofog)
                            if type(ctx.Fog.SetClearPainting) == "function" then
                                pcall(ctx.Fog.SetClearPainting, clear_painting)
                            end
                            -- "world" (v0.22.4): deliberately NOT cropped. Her idea --
                            -- show the whole world painting through the whole-world
                            -- discovery mask, so every area's revealed holes can be
                            -- checked in one picture, tutorial area included, without
                            -- travelling to any of them. It is exactly what the overlay
                            -- did by accident before the crop was fixed; the difference
                            -- is that now it is asked for.
                            -- "world" goes through the SAME view targets now. FogLayer
                            -- opens its crop window to the whole world for that mode, so
                            -- the picture is the full map with every revealed hole stamped
                            -- into it -- rather than the raw uncropped textures, which
                            -- could only ever show the mask as a flat grey.
                            local tile_source = valid(view_painting) and view_painting or painting
                            -- LAYER A's mask is solid WHITE: fog everywhere, measured at
                            -- 95.5%% coverage. The discovery mask belongs to layer B.
                            local mask_source = valid(view_white) and view_white or (fog_mask or inverse)
                            state.fog_view_cropped = valid(view_painting) and valid(view_mask)
                            local whole_world = diagnostic_mode == "world"
                            -- Held for the tick, which re-crops it as the player moves.
                            -- Safe to retain: it is a cooked asset, not a world object,
                            -- and load_asset already pins it for this build's lifetime.
                            state.fog_painting = painting
                            if whole_world then
                                log("Fog diagnostic WORLD: the overlay is showing the "
                                    .. "entire world painting through the whole-world "
                                    .. "discovery mask. Every area's revealed holes are "
                                    .. "visible at once; this is not what fog looks like "
                                    .. "in normal play.")
                            end
                            -- "viewmask" (v0.22.10): the keeper's brush is set straight
                            -- from the view mask texture, no material in the way, so what
                            -- is on screen IS the mask. Built because the composite cannot
                            -- distinguish "the holes are correct and this area really is
                            -- explored" from "the holes are far too big" -- both look like
                            -- a clear map. Every fog bug this week has been a thing that
                            -- could not be seen directly.
                            if diagnostic_mode == "viewmask" and valid(view_mask) then
                                local shown = pcall(keeper.SetBrushFromTexture, keeper, view_mask, false)
                                if not shown then
                                    shown = pcall(keeper.SetBrushResourceObject, keeper, view_mask)
                                end
                                -- 3 = HitTestInvisible: on screen, not clickable. VIS_VISIBLE does not exist in
                                -- this file and would have been a nil global (invariant 0c).
                                pcall(keeper.SetVisibility, keeper, VIS_HIT_TEST_INVISIBLE)
                                log("Fog diagnostic VIEWMASK: the minimap is showing the "
                                    .. "view mask itself, brush=" .. tostring(shown)
                                    .. ". White is fog, black is a revealed hole.")
                            end
                            if state.fog_view_cropped then
                                -- THE PAINTINGS NEED OWNERS TOO. v0.23.33.
                                --
                                -- This is the crash, and four rounds of breadcrumbs found
                                -- it. Her log ends at "View crumb step=blit-painting" with
                                -- NO "begin" crumb after it -- so the process dies before
                                -- the canvas is even opened, in the handful of lines
                                -- between them. Those lines are the validity checks.
                                -- ASKING whether the source texture is still alive is what
                                -- kills the process, which only happens when the object
                                -- behind the wrapper has already been collected.
                                --
                                -- And the reason is right here: the two RENDER TARGETS were
                                -- pinned and the two cooked PAINTINGS were not. The fogged
                                -- world map is handed to RefreshView on every crop and the
                                -- clear one is blitted beside it, both from handles held
                                -- across frames with nothing owning them. Invariant 0, in
                                -- the one place nobody had looked: "a cooked asset, not a
                                -- world object" was treated as meaning it could not go
                                -- away, and garbage collection does not care about that
                                -- distinction.
                                --
                                -- It explains the shape of it too. GC timing is why it was
                                -- intermittent, why it hit "the moment I moved" and on a
                                -- zoom change -- both are simply the first crop after a
                                -- collection -- and why the signature goes back to when the
                                -- view crop first landed.
                                pin_fog_texture(painting)
                                pin_fog_texture(clear_painting)
                                -- AND THE PEEK CIRCLE. v0.23.35.
                                --
                                -- Her next crash named it outright: the log ends at
                                -- "View crumb step=tex:T_UI_MapGlobalMask", so the fatal
                                -- valid() was on the cached peek texture. It is the
                                -- busiest texture in the whole layer -- every redraw stamps
                                -- the peek with it and every trail mark is another stamp of
                                -- the same asset -- and it was relying on FogLayer's own
                                -- pin, which is created inside a keeper owned by the frame
                                -- and therefore has the same lifetime problem the paintings
                                -- had.
                                --
                                -- Pinned HERE as well, at build, beside the paintings. Two
                                -- owners for one texture costs one collapsed Image and
                                -- removes a whole class of "is it still there" from the
                                -- per-redraw path.
                                pin_fog_texture(global_mask)
                                pin_fog_texture(view_painting)
                                pin_fog_texture(view_mask)
                                -- Filled before the first frame, so the overlay never
                                -- shows one frame of an uncleared target.
                                pcall(ctx.Fog.RefreshView, controller, painting,
                                    state.fog_uv_x or 0.5, state.fog_uv_y or 0.5,
                                    crop_span)
                            end
                            fog_overlay_ready = pcall(function()
                                overlay_mid:SetTextureParameterValue(FName("TileTexture"), tile_source)
                                overlay_mid:SetTextureParameterValue(FName("GlobalMask"), mask_source)
                                overlay_mid:SetTextureParameterValue(FName("RegionMask"), mask_source)
                                overlay_mid:SetScalarParameterValue(FName("RevealAmount"),
                                    tonumber(Config.FogMaskStrength) or 0.75)
                                for _, p in ipairs(FOG_MOTION) do
                                    overlay_mid:SetScalarParameterValue(FName(p.name),
                                        p.value * motion)
                                end
                                -- v0.22.6. THE SCALARS THIS CODE HAS NEVER SET.
                                --
                                -- After the crop was fixed and the mask inverted, a disc
                                -- remains that is ~0.55 of the quad and does NOT track
                                -- the reveal radius or respond to the mask at all. The
                                -- only things left that could draw a fixed-radius soft
                                -- circle are M_SpartaMapTile's own scalars, which
                                -- MI_SpartaMapTile ships tuned for a full-screen world
                                -- map and which nothing here has ever written.
                                --
                                -- Low/High read as a remap range, Density as a strength,
                                -- FeatherMipBias as the softness of an edge. Set wide
                                -- open: if the disc moves or vanishes the material is
                                -- steerable and this becomes the fix. If it does not
                                -- move, the material cannot be made to mask on a plain
                                -- Image and the compositing has to become ours.
                                for _, p in ipairs(FOG_FALLOFF) do
                                    overlay_mid:SetScalarParameterValue(FName(p.name), p.value)
                                end
                            end)
                            -- READ THEM BACK. Invariant 0b, and the move that cracked
                            -- MapUVScaleOffset: High was raised from the game's 0.55 to
                            -- 1.0 and the fog disc did not move off 0.55 of the radius.
                            -- Either the write is not landing or High is not the extent,
                            -- and those need completely different fixes. A pcall that
                            -- returned true has never distinguished them.
                            local readback = {}
                            for _, p in ipairs(FOG_FALLOFF) do
                                local ok_r, got = pcall(function()
                                    return overlay_mid:K2_GetScalarParameterValue(FName(p.name))
                                end)
                                readback[#readback + 1] = string.format("%s wanted=%.3f got=%s",
                                    p.name, p.value,
                                    (ok_r and got ~= nil) and string.format("%.3f", tonumber(got) or -1)
                                        or "unreadable")
                            end
                            local ok_rev, rev = pcall(function()
                                return overlay_mid:K2_GetScalarParameterValue(FName("RevealAmount"))
                            end)
                            readback[#readback + 1] = string.format("RevealAmount got=%s",
                                (ok_rev and rev ~= nil) and string.format("%.3f", tonumber(rev) or -1)
                                    or "unreadable")
                            log("Fog falloff readback: " .. table.concat(readback, "  "))
                            -- viewmask wins. The material brush is set AFTER the
                            -- diagnostic's texture brush, so without this guard the
                            -- diagnostic silently lost and showed the composite -- which
                            -- is what it exists to be an alternative to.
                            -- "composite" (v0.23.10): the keeper shows the picture
                            -- FogLayer assembled itself, as a plain texture brush with no
                            -- material anywhere in the path.
                            --
                            -- This is the replacement for the whole material-masking
                            -- approach, put on screen before it is trusted. A texture
                            -- brush on an Image is already proven -- viewmask renders one
                            -- perfectly -- so the only untested thing left is whether the
                            -- canvas honours modulate, and that fails as an unmistakable
                            -- picture rather than a subtle one: no fog at all instead of
                            -- fog with a hole in it.
                            -- "composite" (v0.23.19): TWO IMAGES, AND UMG BLENDS THEM.
                            --
                            -- The lower one is the fogged painting, opaque, so fog covers
                            -- the view. The upper one is FogLayer's masked clear map --
                            -- the clear world in RGB, the reveal in ALPHA -- so the engine
                            -- draws the explored ground over the fog exactly where the
                            -- alpha says to.
                            --
                            -- Composing these two on a canvas cost three versions and
                            -- three different convincing wrong pictures, because each of
                            -- the blend modes does something to alpha that is not written
                            -- down anywhere: opaque writes 1, modulate multiplies, and
                            -- translucent REPLACES. UMG has blended two Images by alpha
                            -- correctly for every widget in this game since it shipped, so
                            -- it does this one too.
                            --
                            -- Both brushes are plain textures, which is the one brush kind
                            -- proven to render here: it is how viewmask draws.
                            -- "blends" (v0.23.22): the probe's own target on the keeper.
                            -- Four bands, one per canvas blend mode, over a known opaque
                            -- grey. Five versions were lost guessing what these modes do
                            -- to alpha; this asks them.
                            if diagnostic_mode == "blends" then
                                local probe = nil
                                if type(ctx.Fog.ProbeTarget) == "function" then
                                    probe = ctx.Fog.ProbeTarget()
                                end
                                local shown = false
                                if probe ~= nil and valid(probe) then
                                    shown = pcall(keeper.SetBrushFromTexture, keeper, probe, false)
                                    if not shown then
                                        shown = pcall(keeper.SetBrushResourceObject, keeper, probe)
                                    end
                                    pcall(keeper.SetVisibility, keeper, VIS_HIT_TEST_INVISIBLE)
                                end
                                log("Fog diagnostic BLENDS: four bands, top to bottom "
                                    .. "OPAQUE, TRANSLUCENT, ADDITIVE, ALPHACOMPOSITE, "
                                    .. "over opaque mid grey. brush=" .. tostring(shown))
                            end
                            if diagnostic_mode == "composite" then
                                local composed = nil
                                if type(ctx.Fog.CompositeTarget) == "function" then
                                    composed = ctx.Fog.CompositeTarget()
                                end
                                local function brush_texture(image, texture)
                                    if image == nil or not valid(image) or texture == nil
                                        or not valid(texture) then return false end
                                    local ok = pcall(image.SetBrushFromTexture, image, texture, false)
                                    if not ok then
                                        ok = pcall(image.SetBrushResourceObject, image, texture)
                                    end
                                    pcall(image.SetVisibility, image, VIS_HIT_TEST_INVISIBLE)
                                    return ok
                                end
                                -- The lower Image is the fog keeper itself.
                                local lower = brush_texture(keeper, view_painting)
                                -- The upper one is built here rather than reusing layer
                                -- B's, because layer B is a material Image and this needs
                                -- a texture one. Same slot geometry and the same Z, so it
                                -- sits exactly where the reveal layer would have.
                                local upper_ok = false
                                pcall(function()
                                    local upper = unwrap(StaticConstructObject(u.image, frame,
                                        make_name("FogCompositeUpper")))
                                    assert(valid(upper), "composite upper image construction failed")
                                    local slot = unwrap(frame:AddChildToCanvas(upper))
                                    assert(valid(slot), "composite upper slot failed")
                                    -- v0.23.40: the MAP SURFACE's size, centred like the map slot. At the
                                    -- frame's size a rotating square map shows its corners through the fog.
                                    set_centered_slot(slot, fog_layer_surface, fog_layer_surface)
                                    pcall(slot.SetZOrder, slot, Z_FOG_REVEAL)
                                    upper_ok = brush_texture(upper, composed)
                                    retained.fog_composite_upper = upper
                                    retained.fog_composite_slot = slot
                                    pcall(upper.SetRenderTransformPivot, upper, { X = 0.5, Y = 0.5 })
                                end)
                                log("Fog diagnostic COMPOSITE: two Images, UMG blends them. "
                                    .. "lower(fogged painting)=" .. tostring(lower)
                                    .. " upper(clear map with the reveal in alpha)="
                                    .. tostring(upper_ok)
                                    .. " target=" .. tostring(composed ~= nil and valid(composed)))
                            end
                            if fog_overlay_ready and diagnostic_mode ~= "viewmask"
                                and diagnostic_mode ~= "composite"
                                and diagnostic_mode ~= "blends" then
                                pcall(keeper.SetBrushFromMaterial, keeper, overlay_mid)
                                retained.fog_overlay = overlay_mid
                                state.fog_overlay_material = overlay_mid
                            end

                            -- LAYER B: the clear map, above the fog, through the discovery
                            -- mask. Nothing here is inverted -- the mask is white where she
                            -- has been and white is what the shader draws, so her collected
                            -- tiles come back through the fog and nothing else does.
                            -- "nolayerb" builds layer A only. The two results that do not
                            -- agree are: at 20 km the collected tiles show clear against
                            -- fog, and at 750 m everything is fogged except the peek. Both
                            -- cannot be right. If turning layer B off changes nothing then
                            -- it is not drawing at this zoom and something else is making
                            -- the peek hole; if the peek disappears, layer B is drawing and
                            -- the question becomes why it draws the peek but not the rest
                            -- of the revealed ground.
                            if fog_overlay_ready
                                and (diagnostic_mode == "off" or diagnostic_mode == "nolayerb")
                                and diagnostic_mode ~= "nolayerb"
                                and diagnostic_mode ~= "composite"
                                and valid(view_clear) and valid(view_mask) then
                                local reveal_mid = nil
                                pcall(function()
                                    reveal_mid = unwrap(u.material_library:CreateDynamicMaterialInstance(
                                        controller, tile_material, make_name("FogReveal"), 0))
                                end)
                                local reveal_ok = false
                                if valid(reveal_mid) then
                                    reveal_ok = pcall(function()
                                        reveal_mid:SetTextureParameterValue(FName("TileTexture"), view_clear)
                                        reveal_mid:SetTextureParameterValue(FName("GlobalMask"), view_mask)
                                        reveal_mid:SetTextureParameterValue(FName("RegionMask"), view_mask)
                                        reveal_mid:SetScalarParameterValue(FName("RevealAmount"), 1.0)
                                        for _, fp in ipairs(FOG_FALLOFF) do
                                            reveal_mid:SetScalarParameterValue(FName(fp.name), fp.value)
                                        end
                                        for _, mp in ipairs(FOG_MOTION) do
                                            reveal_mid:SetScalarParameterValue(FName(mp.name), 0.0)
                                        end
                                    end)
                                end
                                local reveal_keeper = nil
                                if reveal_ok then
                                    pcall(function()
                                        reveal_keeper = unwrap(StaticConstructObject(u.image, frame,
                                            make_name("FogRevealKeeper")))
                                        assert(valid(reveal_keeper), "reveal keeper construction failed")
                                        local slot = unwrap(frame:AddChildToCanvas(reveal_keeper))
                                        assert(valid(slot), "reveal keeper slot failed")
                                        -- v0.23.40: the MAP SURFACE's size, centred like the map slot. At the
                                        -- frame's size a rotating square map shows its corners through the fog.
                                        set_centered_slot(slot, fog_layer_surface, fog_layer_surface)
                                        -- Above the fog, below everything else.
                                        pcall(slot.SetZOrder, slot, Z_FOG_REVEAL)
                                        reveal_keeper:SetBrushFromMaterial(reveal_mid)
                                        retained.fog_reveal_slot = slot
                                    end)
                                end
                                if valid(reveal_keeper) then
                                    retained.fog_reveal = reveal_mid
                                    -- v0.23.3: the WIDGET, not only its material and slot.
                                    -- Without it the rotation pass below could not reach
                                    -- layer B, so in camera orientation the fog turned
                                    -- with the map and the ground punched back through it
                                    -- did not. On world north, which is where she has it,
                                    -- the angle is always 0 and the bug is invisible.
                                    retained.fog_reveal_keeper = reveal_keeper
                                    pcall(reveal_keeper.SetRenderTransformPivot, reveal_keeper,
                                        { X = 0.5, Y = 0.5 })
                                    state.fog_reveal_material = reveal_mid
                                end
                                log("Fog reveal layer: material=" .. tostring(valid(reveal_mid))
                                    .. " params=" .. tostring(reveal_ok)
                                    .. " keeper=" .. tostring(valid(reveal_keeper))
                                    .. " clearPainting=" .. tostring(valid(clear_painting)))

                                -- LAYER C: THE CLEAR WORLD, UNDER THE FOG. v0.23.3.
                                --
                                -- Fog opacity did nothing, and now it is known why rather
                                -- than suspected. The readback says the write lands
                                -- ("Fog opacity wanted=0.30 set=true got=0.30") and the
                                -- two screenshots either side of it are identical to the
                                -- pixel -- mean absolute difference 0.00 over the whole
                                -- minimap, maximum 1. So layer A is drawing an image that
                                -- is identical to what sits behind it: the game's own
                                -- tile widget, showing the same fogged world painting.
                                -- Fading a picture to reveal the same picture cannot look
                                -- like anything.
                                --
                                -- So the fade needs something different underneath, and
                                -- that is the CLEAR painting -- the same view_clear layer
                                -- B already uses, through a solid white mask so it covers
                                -- the whole view instead of only the discovered parts.
                                -- At 100% opacity the fog hides it completely and it is
                                -- COLLAPSED, so the shipped default costs a widget and
                                -- not one drawn pixel. Turn the fog down and unexplored
                                -- ground reads faintly through it, which is the whole
                                -- point of the row.
                                --
                                -- No new render target: view_clear is already built and
                                -- already re-blitted every time the view moves, for layer
                                -- B. This is one more Image pointed at a texture that
                                -- exists.
                                local under_mid = nil
                                pcall(function()
                                    under_mid = unwrap(u.material_library:CreateDynamicMaterialInstance(
                                        controller, tile_material, make_name("FogUnderlay"), 0))
                                end)
                                local under_ok = false
                                if valid(under_mid) then
                                    under_ok = pcall(function()
                                        under_mid:SetTextureParameterValue(FName("TileTexture"), view_clear)
                                        under_mid:SetTextureParameterValue(FName("GlobalMask"), mask_source)
                                        under_mid:SetTextureParameterValue(FName("RegionMask"), mask_source)
                                        under_mid:SetScalarParameterValue(FName("RevealAmount"), 1.0)
                                        for _, fp in ipairs(FOG_FALLOFF) do
                                            under_mid:SetScalarParameterValue(FName(fp.name), fp.value)
                                        end
                                        -- Still, always. The drift belongs to the fog.
                                        for _, mp in ipairs(FOG_MOTION) do
                                            under_mid:SetScalarParameterValue(FName(mp.name), 0.0)
                                        end
                                    end)
                                end
                                local under_keeper = nil
                                if under_ok then
                                    pcall(function()
                                        under_keeper = unwrap(StaticConstructObject(u.image, frame,
                                            make_name("FogUnderlayKeeper")))
                                        assert(valid(under_keeper), "underlay keeper construction failed")
                                        local slot = unwrap(frame:AddChildToCanvas(under_keeper))
                                        assert(valid(slot), "underlay keeper slot failed")
                                        -- v0.23.40: the MAP SURFACE's size, centred like the map slot. At the
                                        -- frame's size a rotating square map shows its corners through the fog.
                                        set_centered_slot(slot, fog_layer_surface, fog_layer_surface)
                                        -- Between the game's map and our fog.
                                        pcall(slot.SetZOrder, slot, Z_FOG_UNDERLAY)
                                        under_keeper:SetBrushFromMaterial(under_mid)
                                        pcall(under_keeper.SetRenderTransformPivot, under_keeper,
                                            { X = 0.5, Y = 0.5 })
                                        retained.fog_underlay_slot = slot
                                    end)
                                end
                                if valid(under_keeper) then
                                    retained.fog_underlay = under_mid
                                    retained.fog_underlay_keeper = under_keeper
                                    state.fog_underlay_material = under_mid
                                end
                                log("Fog underlay layer (clear world, revealed as the fog "
                                    .. "is faded): material=" .. tostring(valid(under_mid))
                                    .. " params=" .. tostring(under_ok)
                                    .. " keeper=" .. tostring(valid(under_keeper))
                                    .. " zOrder=" .. tostring(Z_FOG_UNDERLAY))
                            end
                        end
                        log("Fog overlay: material=" .. tostring(valid(overlay_mid))
                            .. " inverseMask=" .. tostring(inverse ~= nil)
                            .. " painting=" .. tostring(valid(painting))
                            .. " viewCropped=" .. tostring(state.fog_view_cropped == true)
                            .. " ready=" .. tostring(fog_overlay_ready)
                            .. " strength=" .. tostring(tonumber(Config.FogMaskStrength) or 0.75))
                        crumb("fog-overlay-done")
                    end

                    if diagnostic_mode == "material" and valid(u.material_library) then
                        crumb("fog-material-test")
                        local painting = load_asset(ASSET.map_full_fog)
                        local test_mid = nil
                        local made = pcall(function()
                            test_mid = unwrap(u.material_library:CreateDynamicMaterialInstance(
                                controller, tile_material, make_name("FogMaskTest"), 0))
                        end)
                        local applied, apply_error = false, nil
                        if made and valid(test_mid) and valid(painting) then
                            applied, apply_error = pcall(function()
                                test_mid:SetTextureParameterValue(FName("TileTexture"), painting)
                                test_mid:SetTextureParameterValue(FName("GlobalMask"), fog_mask)
                                test_mid:SetTextureParameterValue(FName("RegionMask"), fog_mask)
                                test_mid:SetScalarParameterValue(FName("RevealAmount"),
                                    tonumber(Config.FogMaskStrength) or 0.0)
                                -- Scale 1, offset 0: the painting and the mask both span
                                -- the whole world, so they line up without a transform.
                                test_mid:SetVectorParameterValue(FName("MapUVScaleOffset"),
                                    { R = 1.0, G = 1.0, B = 0.0, A = 0.0 })
                            end)
                            if applied then
                                pcall(keeper.SetBrushFromMaterial, keeper, test_mid)
                                retained.fog_material_test = test_mid
                            end
                        end
                        -- v0.19.12. The v0.19.11 test DID work, and the reason it was
                        -- almost invisible is the reason it proves the point.
                        --
                        -- Exactly one frame of a 46 second recording showed it: the
                        -- minimap black, with the game's fogged painting appearing only
                        -- inside the discovered shapes, the peek circle among them. That
                        -- frame sits immediately after a rebuild -- the one moment when
                        -- the tile map widget has been torn down and has not drawn yet.
                        --
                        -- Our keeper sits ABOVE the map at ZOrder 3 and is transparent
                        -- wherever the mask is black. So for every other frame, the map
                        -- widget underneath simply showed through the holes and the whole
                        -- thing read as an ordinary minimap. The masking was working the
                        -- entire time and had nothing to be seen against.
                        --
                        -- So the test now hides the map widget while it runs. That is not
                        -- a trick to make the test pass: it IS the shipping design. The
                        -- game's own world map does the same thing -- two paintings, the
                        -- fragments as the mask between them -- and once this is
                        -- confirmed, the layer underneath becomes the fogged painting
                        -- instead of black.
                        state.fog_map_hidden = true
                        log("Fog masked-map test: material=" .. tostring(valid(test_mid))
                            .. " painting=" .. tostring(valid(painting))
                            .. " applied=" .. tostring(applied)
                            .. (applied and "" or (" error=" .. tostring(apply_error)))
                            .. " maskStrength=" .. tostring(tonumber(Config.FogMaskStrength) or 0.0)
                            .. " -- the minimap should show the game's fogged world painting "
                            .. "ONLY inside the shapes you have discovered")
                        crumb("fog-material-test-done")
                    end

                    -- Same pivot as the map widget, so the two rotate about the same
                    -- point rather than about their own corners.
                    pcall(keeper.SetRenderTransformPivot, keeper, { X = 0.5, Y = 0.5 })
                    keeper:SetVisibility((show_mask or fog_overlay_ready)
                        and VIS_HIT_TEST_INVISIBLE or VIS_COLLAPSED)
                    retained.fog_keeper = keeper
                    -- v0.23.3. This is a NEW keeper, so whatever opacity the last one
                    -- carried is not a reason to skip the write.
                    state.fog_opacity_applied = nil
                    apply_fog_opacity(keeper, retained.fog_underlay_keeper)
                                -- v0.23.3: this said `show_mask`, which is the DIAGNOSTIC switch, not
                    -- the visibility that was just written. So a perfectly visible fog
                    -- layer logged "visible=false" and cost an hour of reading the line as
                    -- evidence that layer A was collapsed. A log line that names a
                    -- variable must name the one that decided the thing it claims to
                    -- report.
                    log("Fog mask keeper attached (brush=" .. tostring(brush_ok)
                        .. ", visible=" .. tostring(show_mask or fog_overlay_ready)
                        .. ", showMaskDiagnostic=" .. tostring(show_mask)
                        .. ", pinnedTextures=" .. tostring(pinned_fog_textures)
                        .. "). The render target and its textures now have owners.")
                else
                    log("Fog mask keeper could not be constructed; the render target is "
                        .. "unowned and fog has been left off for this build.")
                    fog_mask = nil
                end
                crumb("fog-keeper-done")
            end

            if fog_mask ~= nil then
                crumb("fog-cdo-find")
                -- v0.19.6. The class default object was in hand the whole time and I
                -- threw it away. `u` is the RESOLVED class table: umg_classes() runs
                -- find_object over every path in CLASS and refuses to build at all if any
                -- one of them misses, so u.sparta_map_widget_cdo is the object itself, not
                -- a path. v0.19.2 through v0.19.5 passed that object back into
                -- StaticFindObject, which naturally found nothing, and the two fallbacks
                -- repeated the same mistake with u.sparta_map_widget. Three strategies,
                -- one error, "via=none" in every log.
                --
                -- That the builds succeeded is itself the proof the object is there:
                -- umg_classes() would have failed the whole minimap otherwise.
                local cdo, cdo_via = u.sparta_map_widget_cdo, "resolved"
                if cdo == nil or not valid(cdo) then
                    cdo, cdo_via = nil, "none"
                    -- Only now is a lookup worth doing, and only with a real path.
                    local all_token = Perf.Begin()
                    local all_ok, list = pcall(FindAllOf, "SpartaMapWidget")
                    Perf.End("native.findall", all_token)
                    if all_ok and type(list) == "table" then
                        for _, candidate in ipairs(list) do
                            if valid(candidate) then
                                local name_ok, full = pcall(function() return candidate:GetFullName() end)
                                if name_ok and tostring(full):find("Default__", 1, true) ~= nil then
                                    cdo, cdo_via = candidate, "findall"
                                    break
                                end
                            end
                        end
                    end
                end
                log("Fog class-default lookup via=" .. tostring(cdo_via))
                if cdo ~= nil and valid(cdo) then
                    -- Reading a CDO's innards through a UFunction took the game down in
                    -- probe v1.0.0. This only reads and writes a UObject property, which
                    -- is a different operation, but it is still a CDO, so it is crumbed
                    -- on both sides: a crash between these two lines names itself.
                    crumb("fog-cdo-write")
                    local write_ok = pcall(function()
                        saved_cdo_mask = cdo.GlobalAlphaMask
                        cdo.GlobalAlphaMask = fog_mask
                    end)
                    if write_ok then
                        map_cdo = cdo
                        log("Fog mask staged on the SpartaMapWidget class default.")
                    else
                        saved_cdo_mask = nil
                        log("Fog mask could not be written to the class default; the "
                            .. "construction-time binding will not happen this build.")
                    end
                    crumb("fog-cdo-written")
                end
            end

            local map_widget = unwrap(StaticConstructObject(u.sparta_map_widget, frame, make_name("NativeTiles")))

            -- Restore before anything can fail. The CDO is shared with the game.
            if map_cdo ~= nil then
                -- Read it back off the NEW widget first. This is the whole question the
                -- last six builds have been circling: did the class default reach the
                -- instance at construction? One line in the log now answers it, whatever
                -- the minimap looks like afterwards.
                crumb("fog-cdo-readback")
                local read_ok, inherited = pcall(function()
                    local value = map_widget.GlobalAlphaMask
                    if value == nil then return "none" end
                    local name_ok, full = pcall(function() return value:GetFullName() end)
                    return name_ok and tostring(full) or "unnamed"
                end)
                log("Fog construction-time binding readback: "
                    .. (read_ok and tostring(inherited) or "unreadable")
                    .. " (a RenderTarget here means the mask reached the widget)")
                crumb("fog-cdo-restore")
                pcall(function() map_cdo.GlobalAlphaMask = saved_cdo_mask end)
                crumb("fog-cdo-restored")
            end

            assert(valid(map_widget), "SpartaMapWidget construction failed")
            local map_slot = unwrap(frame:AddChildToCanvas(map_widget))
            assert(valid(map_slot), "map slot failed")
            map_slot:SetPosition({ X = 2, Y = 2 })
            map_slot:SetSize({ X = Config.Size - 4, Y = Config.Size - 4 })
            pcall(map_slot.SetZOrder, map_slot, Z_MAP)
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
            pcall(arrow_slot.SetZOrder, arrow_slot, Z_ARROW)
            retained.arrow_slot = arrow_slot
            arrow:SetVisibility(Config.ShowArrow and VIS_HIT_TEST_INVISIBLE or VIS_COLLAPSED)

            widget:SetVisibility(VIS_COLLAPSED)
            widget:AddToViewport(40)

            -- These exact native fields and methods are source-supported by the object dump.
            map_widget.MaxResidentTiles = Config.MaxResidentTiles
            map_widget.LODBias = Config.LODBias
            map_widget.bAllowMouseInput = false
            map_widget.bExternalZoomAndPan = true
            -- v0.19.7. FEED THE SHADER DIRECTLY, AND STOP ASKING THE WIDGET.
            --
            -- Six builds tried to reach the map through SpartaMapWidget's GlobalAlphaMask
            -- property. v0.19.6 finally tested the one untested way of setting it -- on
            -- the class default, before construction -- and read the answer straight off
            -- the new widget: "Fog construction-time binding readback: nil". The property
            -- does not inherit from the class default, and setting it afterwards has been
            -- measured dead since probe v1.11. There is no third way to set it.
            --
            -- But the property was never where the masking happens. The tiles are drawn
            -- with MI_SpartaMapTile, and its parent M_SpartaMapTile exposes the real
            -- inputs: TileTexture, MapUVScaleOffset, RegionMask, RevealAmount and --
            -- the one that matters -- GlobalMask. GlobalAlphaMask was only ever the
            -- widget's way of filling GlobalMask in.
            --
            -- We already own TileMaterial: the widget draws every tile with whatever is
            -- in it. So a dynamic instance with GlobalMask set to the fog target puts the
            -- mask into the shader itself, with no property on the widget involved.
            --
            -- RevealAmount is set to 0. The shipped instance carries
            -- RegionMask = T_UI_MapFragment_Forest_3 with RevealAmount = 1.0, and the
            -- minimap has always drawn the whole map -- so 1.0 means "ignore the mask".
            -- If 0 turns out to be the wrong end of that range the minimap goes dark
            -- rather than foggy, which is still contact, and still an answer.
            local tile_material_for_widget = tile_material
            if fog_mask ~= nil and valid(u.material_library) then
                crumb("fog-mid")
                -- v0.19.8. v0.19.7 called this with three arguments and it failed on
                -- every build, silently as far as the log was concerned -- "could not be
                -- created" with no reason attached, which is exactly the kind of line
                -- that wastes a session. UE5's signature is
                -- (WorldContextObject, Parent, OptionalName, CreationFlags): FOUR. The
                -- design note recorded that months ago and the call did not match it.
                --
                -- Both shapes are tried, newest first, and whatever the engine says when
                -- one fails now reaches the log instead of being swallowed.
                local mid, made_via, made_error = nil, "none", nil
                for _, attempt in ipairs({
                    { name = "4-arg", call = function()
                        return u.material_library:CreateDynamicMaterialInstance(
                            controller, tile_material, make_name("FogTileMaterial"), 0)
                    end },
                    { name = "3-arg", call = function()
                        return u.material_library:CreateDynamicMaterialInstance(
                            controller, tile_material, make_name("FogTileMaterial"))
                    end },
                }) do
                    local ok, result = pcall(attempt.call)
                    if ok then
                        local candidate = unwrap(result)
                        if valid(candidate) then
                            mid, made_via = candidate, attempt.name
                            break
                        end
                        made_error = attempt.name .. " returned nothing"
                    else
                        made_error = attempt.name .. ": " .. tostring(result)
                    end
                end

                if valid(mid) then
                    -- v0.19.10: RegionMask as well as GlobalMask. The shipped instance
                    -- overrides RegionMask (with T_UI_MapFragment_Forest_3, a template
                    -- leftover) and leaves GlobalMask alone, which is weak evidence that
                    -- RegionMask is the input this material actually reads. Setting both
                    -- costs one call and removes the guess.
                    local set_ok, set_error = pcall(function()
                        mid:SetTextureParameterValue(FName("GlobalMask"), fog_mask)
                        mid:SetTextureParameterValue(FName("RegionMask"), fog_mask)
                        mid:SetScalarParameterValue(FName("RevealAmount"),
                            tonumber(Config.FogMaskStrength) or 0.0)
                    end)
                    if set_ok then
                        tile_material_for_widget = mid
                        retained.fog_tile_material = mid
                    end
                    -- Readback, because v1.7.0's lesson was that SetTextureParameterValue
                    -- writes into the instance's own override list under ANY name, so a
                    -- successful call proves nothing on its own. These two names come
                    -- from M_SpartaMapTile's own parameter list, not from guessing.
                    local read_ok, reveal = pcall(function()
                        return mid:K2_GetScalarParameterValue(FName("RevealAmount"))
                    end)
                    log("Fog tile material: created via=" .. tostring(made_via)
                        .. " parametersSet=" .. tostring(set_ok)
                        .. (set_ok and "" or (" error=" .. tostring(set_error)))
                        .. " revealAmountReadback=" .. (read_ok and tostring(reveal) or "unreadable")
                        .. " (GlobalMask is the shader's world-space mask input)")
                else
                    log("Fog tile material instance could not be created ("
                        .. tostring(made_error) .. "); the tiles will draw with the stock "
                        .. "material and fog will not show.")
                end
                crumb("fog-mid-done")
            end
            map_widget.TileMaterial = tile_material_for_widget
            -- v0.19.2: the fog mask is already on the widget, copied from the class
            -- default during construction, so this call is now belt and braces rather
            -- than the mechanism. Setting it again costs nothing and keeps the property
            -- correct under readback whether or not the construction-time copy took.
            --
            -- Falls back to the game's own mask whenever fog is off or anything the fog
            -- layer needs is unavailable. nil from MaskForBuild must always mean "build
            -- exactly as though fog had never been written".
            local alpha_mask = global_mask
            if fog_mask ~= nil then
                alpha_mask = fog_mask
                retained.fog_mask = fog_mask
            end
            map_widget:SetGlobalAlphaMask(alpha_mask)
            -- SetTileSet moved BELOW the mask in v0.19.2. If the widget builds its tile
            -- brushes here -- which is what "reads GlobalAlphaMask while it builds its
            -- tile brushes" would mean -- then every previous version set the mask after
            -- the brushes already existed. The tile set is unchanged; only the order is,
            -- and the order is free to fix.
            map_widget:SetTileSet(tile_set)
            -- v0.19.10. The question no readback has answered yet: does the widget draw
            -- its tiles with the material we handed it, or does it build its own and
            -- throw ours away? If this comes back as our FogTileMaterial instance, the
            -- parameters are reaching the shader and only their values are wrong. If it
            -- comes back as MI_SpartaMapTile, the widget replaced it and feeding the
            -- material is a dead end in the same way the widget property was.
            if fog_mask ~= nil then
                local held_ok, held = pcall(function()
                    local value = map_widget.TileMaterial
                    if value == nil then return "none" end
                    local name_ok, full = pcall(function() return value:GetFullName() end)
                    return name_ok and tostring(full) or "unnamed"
                end)
                log("Fog tile material after SetTileSet: "
                    .. (held_ok and tostring(held) or "unreadable")
                    .. " maskStrength=" .. tostring(tonumber(Config.FogMaskStrength) or 0.0))
            end
            map_widget:SetRegionBounds({ X = 0.5, Y = 0.5 }, { X = 1.0, Y = 1.0 })
            -- v0.19.9. THIS LINE WAS THE OVERRIDE.
            --
            -- v0.19.8 finally got the dynamic material instance made ("created via=4-arg
            -- parametersSet=true revealAmountReadback=0.0"), put our fog target into the
            -- shader's GlobalMask, and set RevealAmount to 0 -- and the map still drew in
            -- full. Four lines further down, this one told the widget RevealAmount is 1.0,
            -- and the widget pushes its own value into the tiles. We were setting the
            -- parameter and then immediately un-setting it.
            --
            -- Which end of the range masks is still unknown, and cannot be read from the
            -- asset: the cooked material ships its parameter list and no expression graph.
            -- So it is a setting now, swept live from the FOG tab, and whichever value
            -- makes fog appear becomes the shipped default.
            map_widget:SetRevealAmount(fog_mask ~= nil
                and (tonumber(Config.FogMaskStrength) or 0.0) or 1.0)
            map_widget:SetZoom(MapScale.NativeZoom(Config.ZoomMeters))
            state.pan_position_value = state.pan_position_value or { X = 0.5, Y = 0.5 }
            state.pan_position_value.X, state.pan_position_value.Y = 0.5, 0.5
            map_widget:SetPanCenterNormalized(state.pan_position_value)

            -- v0.19.12. Collapse the game's tile map while the masked-map test runs, so
            -- there is nothing behind the holes in our mask. Only ever true when the
            -- diagnostic is on, and it is restored by the next build like everything else
            -- in this tree.
            if state.fog_map_hidden == true then
                pcall(map_widget.SetVisibility, map_widget, VIS_COLLAPSED)
                log("Fog masked-map test: the game's tile map is collapsed for this test, "
                    .. "so what you see is entirely our own masked painting.")
            end
            state.fog_map_hidden = nil

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
                -- v0.23.40: the same writer apply_orientation_layout uses, so the map
                -- and the fog layers can never be given different angles by two paths.
                local write_ok = write_map_angle(desired_map_angle)
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
            -- THE DEBUG FAKE POSITION IS OUT OF THIS CHAIN. v0.23.25.
            --
            -- Her instruction: "disable that logic, don't need to delete it, and make sure
            -- you remove the fake logic link in the chain so player position doesn't have
            -- another if statement to go through."
            --
            -- It earned its removal. Every automated fog and trail test today ran through
            -- this rig, and the rig does not reproduce what real walking does -- her clip
            -- of actual play shows the peek and the trail following her correctly, while
            -- the same settings under a faked offset showed nothing. So it was not a
            -- cheaper way to walk; it was a different thing that looked like walking, and
            -- it cost a day of measuring the wrong picture.
            --
            -- The offset arithmetic is kept in Map/Scale.lua's terms and the config keys
            -- still exist, so bringing it back is a small edit rather than a rewrite -- but
            -- nothing on the per-frame player-position path tests for it any more. Two
            -- comparisons and two branches per pan, gone.
            --
            -- The settings rows are gone with it. A row that is still listed and no longer
            -- does anything is a setting that lies about itself, and this file has paid for
            -- that kind of thing more than once.
            local pan_x, pan_y = MapScale.WorldPanNormalized(world_x, world_y)

            -- v0.19.0 fog. Driven from here because this is where the player's
            -- normalised world position already exists and the cadence is already rate
            -- limited by pan_due. Deliberately OUTSIDE the pan-threshold test below: the
            -- held map pieces can change while standing still, and a settings change to
            -- the radius has to take effect without waiting for the player to walk.
            --
            -- Fog.Update does its own change detection and returns immediately when
            -- nothing moved, which is most ticks. The widget is the mod's own, so using
            -- it as the world context retains nothing the game can destroy.
            if type(ctx.Fog) == "table" and type(ctx.Fog.Update) == "function"
                and valid(state.retained.widget) then
                -- pan_y already carries the debug offset when one is set, so the fog
                -- needs no special case: it sees whatever position the map is showing.
                pose_crumb("fog-update")
                pcall(ctx.Fog.Update, state.retained.widget, pan_x, pan_y)
                pose_crumb("fog-update-done")
            end

            -- v0.20.0. Crop the fog overlay to the same window the map is showing.
            --
            -- The mask and the painting both span the whole world; the minimap shows a
            -- slice of it. MapUVScaleOffset is what the game's own tiles use to do this,
            -- and the conventional reading of a ScaleOffset vector is
            -- uv' = uv * Scale + Offset, so the scale is the visible fraction of the
            -- world and the offset puts the player in the middle of it.
            --
            -- If that reading is wrong the fog will be visibly offset or wrongly sized
            -- rather than absent, which is a much easier thing to correct than silence.
            -- THE CROP IS NOT THE OVERLAY'S. v0.23.7.
            --
            -- This test used to be `state.fog_overlay_material ~= nil`, and the viewmask
            -- diagnostic is the one mode that deliberately does NOT create that material
            -- -- it puts the raw mask texture on the keeper instead. So viewmask switched
            -- off the very re-crop it exists to show: the mask froze at the build-time
            -- window (pan 0.5, target still seeded white) and every viewmask frame came
            -- back solid white, which reads exactly like "the mask is empty".
            --
            -- MEASURED 2026-09-17: a viewmask frame at reveal 20 m with two trail marks
            -- in hand was pure white edge to edge. That is not a finding about the mask;
            -- it is this guard.
            --
            -- The crop belongs to the view TARGETS, so it is gated on those. A diagnostic
            -- that disables the thing it measures is worse than no diagnostic, because it
            -- answers confidently.
            if state.fog_view_cropped or (state.fog_overlay_material ~= nil
                and valid(state.fog_overlay_material)) then
                -- v0.20.2. THE SPAN WAS SIX TIMES TOO WIDE, WHICH IS THE WAVE.
                --
                -- v0.20.0 used ZoomMeters / WORLD_SPAN_METERS, reading the Map range row
                -- as though it were the visible span. It is not: at size 500 / range 750
                -- the map actually shows 90.8 m of a 3155.52 m world, so the overlay was
                -- being cropped to roughly a quarter of the world instead of a fortieth.
                local visible = MapScale.EffectiveVisibleMeters(Config.Size, Config.ZoomMeters)
                -- v0.23.40: the fog widget is the map SURFACE's size, which is the
                -- diagonal when a square map rotates, so it shows that much more world.
                -- Widening the crop by the same factor is what keeps the peek circle the
                -- radius she set instead of that radius times 1.414.
                local span = ((tonumber(visible) or 121.0) * fog_surface_scale())
                    / MapScale.WORLD_SPAN_METERS
                if span > 1.0 then span = 1.0 end
                if span < 0.0005 then span = 0.0005 end

                -- v0.22.2. THE CROP MOVED OUT OF THE MATERIAL.
                --
                -- What used to be here was a SetVectorParameterValue on
                -- MapUVScaleOffset, once per changed pan. It landed perfectly and did
                -- nothing: 2026-09-17, readback 0.02878 against wanted 0.02878, and the
                -- overlay still drew the whole world on top of the real minimap. The
                -- parameter belongs to the game's tile widget, which feeds per-tile uvs;
                -- a plain UImage samples its material's textures across the whole quad
                -- whatever that vector says.
                --
                -- So FogLayer blits the painting and the mask into view-space targets
                -- and the material samples those edge to edge. The material's texture
                -- parameters were bound at build and are not touched here: only the
                -- CONTENTS of those targets change.
                --
                -- Gated on a QUANTISED window, not on pan changing at all. The old
                -- condition was an exact float comparison, so sub-millimetre jitter
                -- re-fired it up to 60 times a second.
                --
                -- v0.23.43, FROM THE AUDIT, and the old comment here was wrong about the
                -- one thing that mattered. It said a third of a view-target pixel is "the
                -- smallest movement that can change the picture". The view TARGET is 1024
                -- px, but it is DISPLAYED at Config.Size -- 360 on her machine -- so a
                -- target pixel is not a visible pixel and a third of one certainly is not.
                --
                -- MEASURED on her 502 s session: span 86.914 m at size 360, so the old
                -- quantum was 86.914 / 3072 = 2.83 cm of world movement, while one pixel
                -- she can actually see is 86.914 / 360 = 24.1 cm. The crop was re-running
                -- 8.5 times per pixel of visible change, and it is the most expensive
                -- recurring thing the mod does: fog.view, 0.654 ms x 7164 calls = 4687 ms,
                -- 23% of the mod's entire game-thread cost.
                --
                -- Quantised to HALF a displayed pixel now. Half rather than one because
                -- the crop feeds a material that can magnify it, and because a visible
                -- seam would cost far more than the remaining calls save -- Nyquist, not
                -- bravery. That is ~4x fewer crops at her settings rather than the 8.5x
                -- a full pixel would give, and unlike the old fixed 3072 it SCALES: a
                -- bigger minimap shows more pixels and re-crops proportionally more often,
                -- which is the behaviour that was missing.
                if state.fog_view_cropped and type(ctx.Fog.RefreshView) == "function" then
                    local displayed = math.max(64.0, tonumber(Config.Size) or 280.0)
                    local quantum = span / (displayed * VIEW_CROP_SAMPLES_PER_PIXEL)
                    local qx = math.floor(pan_x / quantum)
                    local qy = math.floor(pan_y / quantum)
                    -- THE TREE HAS TO STILL BE OURS. v0.23.27.
                    --
                    -- MEASURED 2026-09-17, and it is the crumbs from v0.23.24 that named
                    -- it: her log's last line is "Pose crumb step=fog-refresh" with no
                    -- matching -done, so the process died INSIDE this call. Twice before
                    -- that, without crumbs, the same crash ended at "Tick stage=pose" --
                    -- and every one of them came on the first pose tick after the settings
                    -- window closed, which is a teardown.
                    --
                    -- FogLayer's own DropTarget already says why: the view targets "are
                    -- owned by the keeper Images in the tree that is being torn down, so
                    -- holding the handles past this point is holding pointers to objects
                    -- with no owner. That exact omission crashed v0.19.x three times."
                    -- This is the fourth, reached by a route that skips DropTarget.
                    --
                    -- An access violation is not catchable: pcall does not help, because
                    -- the process is gone before it can. The only defence is not making
                    -- the call, so the refresh now requires the build to be current and
                    -- the frame that owns those targets to still be valid. Two tests on a
                    -- path that already runs only when the view has moved.
                    local tree_is_ours = state.built == true
                        and state.retained ~= nil and valid(state.retained.frame)
                    if not tree_is_ours then
                        -- Said once per teardown rather than per tick: this is the normal
                        -- state for a frame or two after any rebuild, not a fault.
                        if state.fog_refresh_skipped ~= true then
                            state.fog_refresh_skipped = true
                            debug_log("Fog view refresh skipped: the widget tree that owns "
                                .. "the view targets is not current")
                        end
                    elseif state.fog_view_qx ~= qx or state.fog_view_qy ~= qy
                        or state.fog_view_span ~= span then
                        state.fog_refresh_skipped = false
                        state.fog_view_qx, state.fog_view_qy = qx, qy
                        state.fog_view_span = span
                        state.fog_uv_x, state.fog_uv_y = pan_x, pan_y
                        -- state.controller: the retained player controller the tick
                        -- already uses as its world context. There is no local
                        -- `controller` in this scope, and a nil world context would make
                        -- every blit fail silently -- which is exactly the class of bug
                        -- this whole change exists to stop repeating.
                        -- state.controller is a RETAINED player controller used as the
                        -- world context for render-target work. If the world replaced it,
                        -- this is where a dead pointer reaches native code (invariant 0e).
                        pose_crumb("fog-refresh")
                        pcall(ctx.Fog.RefreshView, state.controller, state.fog_painting,
                            pan_x, pan_y, span)
                        pose_crumb("fog-refresh-done")
                    end
                end
            end

            local world_units_per_pixel = (Config.ZoomMeters * 100.0) / Config.Size
            local threshold = (world_units_per_pixel * PAN_IDLE_EPSILON_PIXELS) / WORLD_SPAN_UNITS
            local delta_x = state.last_pan_x ~= nil and pan_x - state.last_pan_x or 0.0
            local delta_y = state.last_pan_y ~= nil and pan_y - state.last_pan_y or 0.0
            if state.last_pan_x == nil or delta_x * delta_x + delta_y * delta_y >= threshold * threshold then
                state.pan_position_value = state.pan_position_value or { X = 0.5, Y = 0.5 }
                state.pan_position_value.X, state.pan_position_value.Y = pan_x, pan_y
                pose_crumb("pan-write")
                local write_ok = pcall(state.retained.map_widget.SetPanCenterNormalized,
                    state.retained.map_widget, state.pan_position_value)
                pose_crumb("pan-write-done")
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
                pose_crumb("arrow-write")
                local write_ok = pcall(state.retained.arrow.SetRenderTransformAngle, state.retained.arrow, angle)
                pose_crumb("arrow-write-done")
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
