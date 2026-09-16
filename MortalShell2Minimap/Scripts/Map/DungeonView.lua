-- Live orthographic top-down capture, drawn where the game's world map has no tiles.
--
-- Mortal Shell II ships no dungeon map data at all -- dungeons are the fog on the world
-- map -- so there is nothing to reuse and nothing cheaper than rendering the place. This
-- module attaches an orthographic SceneCapture2D above the player, pointed straight down,
-- cuts the ceiling away with the capture's near clip plane, and draws the resulting render
-- target into the minimap frame in place of the tile map.
--
-- WHAT THE PROBE ESTABLISHED (MortalShell2DungeonViewProbe v0.1.0 -> v0.5.0, 2026-09-13;
-- Evidence/V0201..V0205, DUNGEON_VIEW_RESEARCH.md). Three separate one-value fixes, none
-- of them guessable from documentation, each found by measuring exported pixels:
--
--   * RenderTargetFormat = 3 (RGBA8_SRGB) -- brightness. BaseColor is linear albedo;
--     a linear target reads ~3x too dark (max luminance 58/255 vs 131/255).
--   * UnlitViewmode = 1 -- legibility. A lit capture photographs the darkness: mean
--     luminance 1.4/255 in a dungeon. Lighting is the enemy here.
--     CORRECTED 2026-09-13 (probe v0.8.0, Evidence/V0148): this attribution was WRONG.
--     UnlitViewmode has no measurable effect on source 3 -- a capture with it off is
--     pixel-identical to one with it on, inside and out. The 1.4/255 figure was
--     FinalColorLDR under the player's exposure; the legible picture comes from scene
--     color being pre-exposure-scaled radiance in an sRGB target. The flag is still
--     written because it is harmless and removing a proven-crash-free write for tidiness
--     is not worth a run. But the capture is LIT, and always was.
--   * CaptureSource = 3 (SceneColorSceneDepth) -- ALPHA, and this is the one that took
--     three generations. Every other readable source writes alpha 0, and a UMG Image
--     brush blends with texture alpha, so the picture would draw as nothing. Source 3
--     packs scene color in RGB and normalised depth in A; in an 8-bit target the depth
--     term saturates to 255 across the whole frame. The clamping that made plain
--     SceneDepth useless as a picture is exactly what makes this source usable as a mask.
--
-- Dead ends, so nobody re-walks them: the render target's clear-color alpha (the capture
-- overwrites the target, it does not blend into it); FinalColorLDR/FinalToneCurveHDR with
-- UnlitViewmode (the flag does nothing to the final-color path -- three unlit runs came
-- back numerically identical to the lit ones); SceneColorHDRNoAlpha (the name means "does
-- not output alpha", not "alpha = 1"); and SceneColorHDR, which does carry a real binary
-- coverage mask that survives unlit but is INVERTED -- opaque exactly where there is no
-- geometry, 0.0 % overlap between "lit" and "opaque". That one looks plausible on screen
-- and is completely wrong; only per-pixel measurement caught it.
--
-- THE THREAD RULE. Probe v0.1.0 crashed the game 3/3 with an access violation on
-- RenderThread 0 inside FScene::UpdateSceneCaptureContents, purely because CaptureScene
-- was called from the UE4SS key-bind thread. Every render-touching call in here runs from
-- the pose tick, which is already a game-thread callback. Nothing in this module may be
-- called from a hotkey handler. See ARCHITECTURE.txt invariant 0n.
--
-- COST (measured, 5 Hz, 72 s): ~0.33 ms of frame time, 112 -> 108 fps, and -- the number
-- that matters for our budgets -- NOTHING on the game thread: tick.interval gapMax was
-- unchanged with the capture on (28-47 ms) vs off (27-41 ms). The bill is render-thread
-- and GPU, so a capture never competes with WorkBudget, the hook governor or any other
-- [PERF] section. The Lua side of a capture (dungeon.capture) is a single native call and
-- should read ~0 ms; if it ever does not, something has changed.

local Factory = {}

function Factory.New(ctx)
    local state = assert(ctx.State, "Map.DungeonView requires State")
    local Config = assert(ctx.Config, "Map.DungeonView requires Config")
    local Object = assert(ctx.Object, "Map.DungeonView requires Core.Object")
    local MapScale = assert(ctx.MapScale, "Map.DungeonView requires Map.Scale")
    local log = assert(ctx.Log, "Map.DungeonView requires Log")
    local debug_log = assert(ctx.DebugLog, "Map.DungeonView requires DebugLog")
    local Perf = type(ctx.Perf) == "table" and ctx.Perf
        or { Begin = function() return nil end, End = function() end,
             Count = function() end, Mark = function() end }
    local unwrap = Object.Unwrap
    local valid = Object.Valid
    -- Injected so the rate limiter is testable; main.lua passes os.clock, which has 1 ms
    -- resolution on Windows -- far finer than the 2-15 Hz cadences this gates.
    local clock = type(ctx.Clock) == "function" and ctx.Clock or os.clock

    local CLASS = {
        image = "/Script/UMG.Image",
        scene_capture = "/Script/Engine.SceneCapture2D",
        rendering_library = "/Script/Engine.Default__KismetRenderingLibrary",
        system_library = "/Script/Engine.Default__KismetSystemLibrary",
    }

    -- THE CAPTURE TAB (v0.15.0, 2026-09-13). Every parameter of the capture is a settings
    -- row on its own tab, so the exposure question can be worked by turning knobs and
    -- watching the map, rather than by shipping a new preset list every round. This
    -- replaces the v0.14.5-v0.14.9 preset rows, on the user's ask.
    --
    -- The shipped defaults reproduce the v0.14.x capture exactly: source 3 into RGBA8_SRGB,
    -- tint 1.0, post process muted. Everything below that is tuning; the ini remembers it.
    --
    -- WHAT FIVE ROUNDS OF EVIDENCE SAY ABOUT THESE KNOBS (Evidence/V0144..V0149):
    --
    --   * The capture is LIT HDR scene color. "Unlit" does nothing to source 3 -- pixel-
    --     identical with it on or off -- and the flag is kept only because removing a
    --     proven-crash-free write is not worth a run. Sunlit ground exceeds 1.0 and an 8-bit
    --     target clips it; that is the whole open-world white-out. Not haze, not post
    --     process, not particles, not camera distance: each was switched off in turn.
    --   * RGBA16f (format 6) holds the range. With the tint at 0.15 it drew the sunlit gate
    --     readably for the first time. The tint is a real exposure on a float target and a
    --     dimmer on an 8-bit one.
    --   * Post-process overrides are INERT on the scene-color sources (0/1/3): they are
    --     taken before the tonemapper. They APPLY on the final-color sources (2/8/9):
    --     manual +6 was measurably lighter than 0. So the exposure rows below do nothing
    --     unless the source is one of those.
    --   * FinalColorLDR (2) came out light and flat at every exposure tried; whether that is
    --     overexposure through the filmic shoulder or the double display encode on a UMG
    --     Image is what a darker manual bias will tell. FinalColorHDR (8) is exposed,
    --     linear and un-encoded, so Slate encodes it once; its alpha is unmeasured.
    --   * BaseColor (7) is immune to light and writes alpha 0 in every pixel, so it draws
    --     nothing. Sources 2 and 9 write alpha 255. 4/5/6 are depth and normals.
    --
    -- Writes go through apply_post_process, which writes the struct back and reads it back
    -- off the component; the log line for every build carries ppVerified=, and only that
    -- number is evidence that a row reached the engine. ARCHITECTURE invariant 0b.
    local function knob_number(key, fallback)
        local value = tonumber(Config[key])
        if value == nil then return fallback end
        return value
    end
    local function knob_bool(key, fallback)
        local value = Config[key]
        if value == nil then return fallback end
        return value == true
    end

    -- Assemble the post-process override table from the rows. Off means "not a single
    -- field", so the shipped build never goes near the struct.
    local function post_process_from_config()
        if not knob_bool("DungeonCapturePostProcess", false) then return nil end
        local pp = {
            bOverride_AutoExposureMethod = true,
            AutoExposureMethod = math.floor(knob_number("DungeonCaptureExposureMethod", 0)),
            bOverride_AutoExposureBias = true,
            AutoExposureBias = knob_number("DungeonCaptureExposureBias", 0.0),
            bOverride_AutoExposureMinBrightness = true,
            AutoExposureMinBrightness = knob_number("DungeonCaptureExposureMin", -10.0),
            bOverride_AutoExposureMaxBrightness = true,
            AutoExposureMaxBrightness = knob_number("DungeonCaptureExposureMax", 20.0),
            bOverride_AutoExposureSpeedUp = true,
            AutoExposureSpeedUp = knob_number("DungeonCaptureExposureSpeed", 100.0),
            bOverride_AutoExposureSpeedDown = true,
            AutoExposureSpeedDown = knob_number("DungeonCaptureExposureSpeed", 100.0),
            bOverride_AutoExposureApplyPhysicalCameraExposure = true,
            AutoExposureApplyPhysicalCameraExposure = knob_bool("DungeonCapturePhysicalCamera", false),
        }
        -- Bloom and vignette: "off" overrides them to zero; "on" leaves the world's own
        -- settings alone rather than inventing a value.
        if not knob_bool("DungeonCaptureBloom", false) then
            pp.bOverride_BloomIntensity = true
            pp.BloomIntensity = 0.0
        end
        if not knob_bool("DungeonCaptureVignette", false) then
            pp.bOverride_VignetteIntensity = true
            pp.VignetteIntensity = 0.0
        end
        return pp
    end

    -- The complete description of the capture the rows currently ask for. One table, read
    -- at build time, so a build and its log line always agree.
    local function capture_config()
        return {
            source = math.floor(knob_number("DungeonCaptureSource", 3)),
            format = math.floor(knob_number("DungeonCaptureFormat", 3)),
            unlit = knob_bool("DungeonCaptureUnlit", true) and 1 or 0,
            lod = knob_number("DungeonCaptureLOD", 4.0),
            tint = knob_number("DungeonCaptureTint", 1.0),
            persist = knob_bool("DungeonCapturePersist", true),
            pp = post_process_from_config(),
        }
    end

    -- A short, greppable description of the active knobs for the build line and the
    -- Ctrl+Delete summary, so a screenshot can be tied to exactly what was set.
    local function describe(config)
        local pp = config.pp
        local exposure = "off"
        if pp ~= nil then
            exposure = string.format("%s/bias%+.1f/ev%g..%g/spd%g/phys%s/bloom%s/vig%s",
                ({ [0] = "hist", [1] = "basic", [2] = "manual" })[pp.AutoExposureMethod] or "?",
                pp.AutoExposureBias, pp.AutoExposureMinBrightness, pp.AutoExposureMaxBrightness,
                pp.AutoExposureSpeedUp,
                pp.AutoExposureApplyPhysicalCameraExposure and "on" or "off",
                pp.BloomIntensity == 0.0 and "off" or "on",
                pp.VignetteIntensity == 0.0 and "off" or "on")
        end
        return string.format("src%d/fmt%d/tint%.2f/unlit%d/lod%g/persist%s/pp=%s",
            config.source, config.format, config.tint, config.unlit, config.lod,
            config.persist and "on" or "off", exposure)
    end

    -- Apply the CAPTURE tab's post-process overrides and then PROVE they landed, because
    -- v0.14.5 proved they did not. This is the one PROVEN shape for writing a struct
    -- property on this UE4SS build; the regression exercises it directly, and the next
    -- person who needs to write into a struct on a component should start here. That build counted every write pcall accepted and reported
    -- ppApplied=4 -- yet four genuinely different exposure configurations (pinned 1.0,
    -- pinned 0.25, bias -4, manual) produced captures the player could not tell apart,
    -- twice, in two different rooms. Four different exposures cannot render identically.
    -- The writes were going into a copy of the struct, not into the component.
    --
    -- This mod has already paid for this lesson once. Overlay/Labels.lua reads an
    -- FSlateFontInfo into plain values and assigns it back AS A WHOLE STRUCT, with the
    -- regression pinning it as fontApply=whole-struct, for exactly this reason: on this
    -- UE4SS build, member writes to a struct property do not necessarily reach the object.
    -- The same rule applies to FPostProcessSettings and nobody applied it here.
    --
    -- So: write the members, write the whole struct back (UE4SS may hand out a detached
    -- copy of a struct property; assigning it back is the only way to be sure, and is
    -- harmless if the members were live all along), then re-read from the component and
    -- compare. ppVerified counts fields that read back as what we asked for. Only that
    -- number is evidence -- ARCHITECTURE invariant 0b, no unproven native call shape.
    local function pp_equal(wanted, got)
        if type(wanted) == "number" and type(got) == "number" then
            return math.abs(got - wanted) < 1.0e-3
        end
        return got == wanted
    end

    local function apply_post_process(component, pp)
        if type(pp) ~= "table" then return 0, 0, "none" end
        -- A blend weight of 0 makes the component's own settings inert, which is how the
        -- default build ends up inheriting the player's adaptation in the first place.
        pcall(function() component.PostProcessBlendWeight = 1.0 end)
        local ok, settings = pcall(function() return component.PostProcessSettings end)
        if not ok or settings == nil then return 0, 0, "unreadable" end
        local applied = 0
        for key, value in pairs(pp) do
            -- Independent writes: one refused property must not take the rest down.
            if pcall(function() settings[key] = value end) then applied = applied + 1 end
        end
        local path = "in-place"
        if pcall(function() component.PostProcessSettings = settings end) then
            path = "write-back"
        end
        local verified = 0
        local ok_read, check = pcall(function() return component.PostProcessSettings end)
        if ok_read and check ~= nil then
            for key, value in pairs(pp) do
                local ok_field, got = pcall(function() return check[key] end)
                if ok_field and pp_equal(value, got) then verified = verified + 1 end
            end
        end
        return applied, verified, path
    end

    -- The shipping configuration, exactly as the probe proved it -- source 3, unlit flag 1,
    -- RGBA8_SRGB -- lives as the CAPTURE tab defaults in Config/Runtime.lua and as the
    -- fallbacks in capture_config() above.
    local PROJECTION_ORTHOGRAPHIC = 1

    local VIS_COLLAPSED = 1
    local VIS_HIT_TEST_INVISIBLE = 3
    local SQRT_TWO = math.sqrt(2.0)

    -- ORIENTATION, calibrated 2026-09-13 against an overworld capture taken beside the
    -- Ruins of Nochte and the same frame of the user's own minimap.
    --
    -- A UE camera at pitch -90, yaw 0 has up = world +X and right = world +Y. The game's
    -- map frame is up = world +Y, right = world -X (Map/Scale.lua: map_x = -(world_x -
    -- 38050.05), map_y = -(world_y + 134391.87)). Taking one basis to the other is a 90
    -- degree counter-clockwise rotation of the image, and UMG render-transform angles are
    -- clockwise-positive, so the constant is -90.
    --
    -- Checked the other way round too: the raw capture matched the user's on-screen
    -- minimap exactly (same portrait structure, stair-hatched wall on the same side, no
    -- mirroring) while her map carried a +90 rotation, which puts the unrotated capture at
    -- north-up minus 90. Two independent routes, same answer.
    local CAPTURE_YAW_OFFSET_DEGREES = -90.0
    local ROTATION_IDLE_EPSILON_DEGREES = 0.25

    -- Capture only when the picture would actually differ: a quarter metre of movement, or
    -- a slow idle refresh so a door that opened while you stood still still shows up.
    local MOVE_EPSILON_UNITS = 25.0
    local IDLE_REFRESH_SECONDS = 3.0

    -- After a teardown, wait for the frame to hold still before spawning anything, so a run
    -- of rebuilds does not spawn and destroy a capture actor for each step of a drag the user
    -- is still making.
    --
    -- v0.18.41 (MEASURED, her 03:55 torture-test video): this was 0.30, and it was the single
    -- largest part of the visible blink. The log gives the same shape on all thirteen
    -- rebuilds in that clip -- teardown, then the widget back at +130 ms (ring, compass and
    -- player arrow return together), then the PICTURE back at +445 ms. That second gap is
    -- this constant almost exactly: 300 ms of waiting plus about 15 ms of building.
    --
    -- The 0.30 was sized for a world where Lifecycle tore down on the very next tick, so a
    -- held arrow key handed this module a fresh frame every ~130 ms. v0.18.40's debounce
    -- removed that world: a rebuild cannot now arrive sooner than the 300 ms debounce plus
    -- the teardown, so roughly 430 ms apart at worst, and her torture test measured 700 ms
    -- to 1000 ms in practice. The reason for a 300 ms settle moved upstream, so the settle
    -- follows it down. 0.10 still absorbs the told-and-self-detected double notification and
    -- any same-frame churn, and Validation/Regression.lua pins it BELOW the debounce, which
    -- is the relationship that makes it safe rather than merely smaller.
    local REBUILD_SETTLE_SECONDS = 0.10

    -- v0.18.42: how long a live capture-span change (Map range, orientation, the capture
    -- rows) waits for the next one before the capture is actually torn down and rebuilt.
    -- Matches Lifecycle's REBUILD_DEBOUNCE_SECONDS on purpose: these are the same gesture,
    -- a user stepping a row, and they should feel the same whichever row it is. Unlike the
    -- settle above, the map keeps DRAWING through this one -- the old capture is still on
    -- screen and still correct for the setting that is still in force.
    local CAPTURE_COALESCE_SECONDS = 0.30

    local view = {
        ready = false,
        built = false,
        active = false,
        unavailable_reason = nil,
        captures = 0,
        -- v0.18.45: span changes applied in place, no teardown. A rising count here with a
        -- flat capture-build count is the fix working.
        respans = 0,
        capture_failures = 0,
        -- v0.18.42: a pending coalesced capture rebuild. nil means nothing is waiting.
        capture_rebuild_deadline = nil,
        capture_rebuild_observed = 0,
        build_failures = 0,
        brush_ok = false,
        last_capture_clock = nil,
        last_x = nil, last_y = nil, last_z = nil,
        angle = nil,
        ortho_width_cm = nil,
        surface_px = nil,
    }
    -- Exposed so Validation/DungeonViewRegression.lua can exercise the proven struct-write
    -- helper against a fake component directly; nothing in the runtime calls it by this
    -- name.
    view.ApplyPostProcess = apply_post_process

    local function find_object(path)
        local token = Perf.Begin()
        local ok, value = pcall(StaticFindObject, path)
        Perf.End("native.find", token)
        value = unwrap(ok and value or nil)
        return valid(value) and value or nil
    end

    ---------------------------------------------------------------------------
    -- Settings
    ---------------------------------------------------------------------------

    local function background_mode()
        local mode = tostring(Config.NoMapBackground or "dungeon"):lower()
        if mode ~= "transparent" and mode ~= "cloud" then return "dungeon" end
        return mode
    end

    local function wanted_where_unmapped()
        return background_mode() == "dungeon"
    end

    local function wanted_everywhere()
        return Config.DungeonViewEverywhere == true
    end

    -- True when the user's settings ask for the capture here, regardless of whether it
    -- has managed to build yet. Renderer presentation asks this; capture asks Active().
    function view.Wanted()
        if state.area_map_available == false then return wanted_where_unmapped() end
        return wanted_everywhere()
    end

    -- True when the capture is wanted AND actually usable. A build failure, a missing
    -- class or a refused brush write all fall back to the ordinary presentation rather
    -- than leaving a black square over the map.
    function view.Active()
        return view.Wanted() and view.built and view.brush_ok
    end

    local function capture_interval_seconds()
        local hz = tonumber(Config.DungeonViewRate) or 10
        if hz < 1 then hz = 1 elseif hz > 60 then hz = 60 end
        return 1.0 / hz
    end

    ---------------------------------------------------------------------------
    -- Brightness
    --
    -- Corrected 2026-09-13 (V0148 ablation, V0150 recorder): the capture is LIT scene
    -- color, not unlit albedo -- the UnlitViewmode flag does nothing on the shipped
    -- source, and the v0.14.0 wording here was wrong. What blows the picture out is the
    -- zone's own lighting profile (a 200-lux sun, sky x10, blue fog x10 at Desolate Keep),
    -- which the v0.15.1 map lighting now swaps out for the capture only. What is left for
    -- these two rows is the residual palette split: exterior ground under even the map
    -- lighting is higher-albedo than dungeon stone, so one fixed factor keyed on "is there
    -- a real map here" still earns its keep, and a user multiplier on top of it covers the
    -- rest (a pale marble dungeon, say).
    --
    -- What this deliberately is NOT: a measurement. Reading the render target back to
    -- detect blown-out pixels means a GPU-to-CPU readback, and every route to one
    -- (ReadRenderTargetPixel, ReadRenderTargetPixelArea) flushes the rendering commands --
    -- a game-thread stall of up to a frame, on the one thread this whole suite exists to
    -- protect. It would also be an unproven call shape twice over (the read itself, and
    -- marshalling a TArray<FColor> back through UE4SS). That is a probe cycle, not a fix;
    -- it is written up in DUNGEON_VIEW_RESEARCH.md as a costed option rather than done here.
    ---------------------------------------------------------------------------

    -- Two independent values rather than one multiplied by a constant: each row controls
    -- the place it names, so lowering the dungeon one cannot silently darken the open world
    -- or the reverse. The open-world default is 0.55 because that is what the 11:34 run
    -- measured -- exterior capture reached max luminance ~255 with heavy white speckle,
    -- against ~106 for the dungeon that reads correctly. 0.55 brings it into the same range
    -- rather than to the same number, which is what keeps it looking like one feature.
    local function brightness()
        local value
        if state.area_map_available == false then
            -- Unmapped ground: the dungeon case the feature exists for.
            value = tonumber(Config.DungeonViewBrightness) or 1.00
        else
            -- Anywhere the game has a real map is the open world, and that is the one
            -- that glares: sunlit ground is far higher albedo than dungeon stone.
            value = tonumber(Config.DungeonViewOpenWorldBrightness) or 0.55
        end
        if value < 0.2 then value = 0.2 elseif value > 2.0 then value = 2.0 end
        -- The CAPTURE tab's exposure tint multiplies the place rows. On a float target it is
        -- a true exposure; on an 8-bit one it only dims. Down to 2 % so a sunlit courtyard
        -- can be brought into range without the place row's own floor in the way.
        return value * knob_number("DungeonCaptureTint", 1.0)
    end

    local function apply_brightness()
        if not valid(view.image) then return end
        local value = brightness()
        if view.tint ~= nil and math.abs(value - view.tint) < 0.001 then return end
        if pcall(view.image.SetColorAndOpacity, view.image,
            { R = value, G = value, B = value, A = 1.0 }) then
            view.tint = value
        end
    end

    local function rotating_square()
        local shape = tostring(Config.MapShape or "square"):lower()
        local orientation = tostring(Config.MapOrientation or "north"):lower()
        return shape ~= "circle" and (orientation == "camera" or orientation == "player")
    end

    -- The capture has to cover the same ground as the tile map or every marker drifts
    -- against it, so the ortho width is derived from the map's own effective visible
    -- span, oversized by the diagonal when a rotating square viewport needs its corners.
    local function surface_and_ortho()
        local size = tonumber(Config.Size) or 280.0
        local viewport = math.max(1.0, size - 4.0)
        local surface = rotating_square() and math.ceil(viewport * SQRT_TWO) or viewport
        local visible = MapScale.EffectiveVisibleMeters(size, Config.ZoomMeters)
        if visible == nil or visible <= 0 then visible = 40.0 end
        local ortho_m = visible * surface / viewport
        -- Below a few metres the capture is a texture swatch; above a couple of hundred a
        -- 256-pixel target is mush and the render cost climbs for nothing.
        if ortho_m < 5.0 then ortho_m = 5.0 elseif ortho_m > 400.0 then ortho_m = 400.0 end
        return surface, ortho_m * 100.0
    end

    local function target_pixels()
        local px = math.floor(tonumber(Config.DungeonViewPixels) or 256)
        if px < 64 then px = 64 elseif px > 1024 then px = 1024 end
        return px
    end

    local function slice_cm()
        return math.max(25.0, (tonumber(Config.DungeonViewSliceMeters) or 2.5) * 100.0)
    end

    -- The camera's height above the pawn. Orthographic, so it changes nothing about the
    -- picture's footprint or what the near plane cuts -- the near plane sits at
    -- pawn + slice regardless. It changes only how much air the capture looks through,
    -- and v0.14.7 measured that to make no visible difference from 3 m to 60 m. It is a
    -- CAPTURE tab row now; the camera stays at least half a metre above the near plane so
    -- the plane can never sit behind it.
    local function camera_height_cm()
        local meters = tonumber(Config.DungeonViewHeightMeters) or 30.0
        return math.max(slice_cm() + 50.0, meters * 100.0)
    end

    ---------------------------------------------------------------------------
    -- AUTO CEILING CUT (v0.16.11, user: "for when I'm in tight spaces the camera comes
    -- in closer, but when I'm in wide open ones it lifts up revealing more of the
    -- terrain so it doesn't get cut off"). The capture is orthographic, so the camera's
    -- height changes nothing visible; what decides the picture is the near plane at
    -- pawn + slice. Auto measures the headroom -- five line traces straight up from
    -- head height, one over the pawn and four 3 m out, the HIGHEST ceiling wins so a
    -- doorway arch inside a hall does not flatten the hall -- and puts the cut just
    -- under it, between the fixed cut (floor) and DungeonViewCeilingMaxMeters. Raises
    -- fast, lowers slowly (her call: favour open). One trace is microseconds; five per
    -- capture tick at 10 Hz is nothing. The near plane is a property write on our own
    -- capture component before CaptureScene, so no rebuild. Unproven (0c) until a run
    -- says the trace's out-param reads; twenty straight failures with no success
    -- disable it for the session and the fixed cut stands (0b), logged once.
    ---------------------------------------------------------------------------
    local CEILING_TRACE_START_CM = 120.0     -- above the pawn's location (its capsule centre)
    local CEILING_TRACE_MARGIN_CM = 40.0     -- the cut sits this far under the ceiling
    local CEILING_TRACE_MIN_HIT_CM = 50.0    -- a nearer hit means the ray began inside a wall
    local CEILING_RAISE_FRACTION = 0.5       -- per capture tick, towards a higher target
    local CEILING_LOWER_FRACTION = 0.15      -- per capture tick, towards a lower target
    local CEILING_DISABLE_AFTER_FAILURES = 20
    local CEILING_RAY_OFFSETS = { { 0, 0 }, { 300, 0 }, { -300, 0 }, { 0, 300 }, { 0, -300 } }
    local TRACE_TYPE_VISIBILITY = 0          -- ETraceTypeQuery::TraceTypeQuery1
    local DRAW_DEBUG_NONE = 0

    local ceiling = {
        slice_cm = nil, headroom_cm = nil, trace_ok = 0, trace_failures = 0,
        rays_hit = 0, rays_open = 0, rays_blocked = 0, disabled_reason = nil,
        applied_cm = nil, library = nil, logged_first = false,
    }

    local function ceiling_auto_enabled()
        return Config.DungeonViewCeilingAuto ~= false
    end

    local function ceiling_max_cm()
        local meters = tonumber(Config.DungeonViewCeilingMaxMeters) or 25.0
        local max_cm = math.max(slice_cm(), meters * 100.0)
        -- The camera stays at least half a metre above the near plane.
        return math.min(max_cm, camera_height_cm() - 50.0)
    end

    -- The hit distance from a trace's out-param, whichever shape UE4SS hands back:
    -- the struct under the parameter's name, or the fields on the table itself.
    local function hit_distance(out, start_z)
        local candidates = {}
        if out.OutHit ~= nil then candidates[#candidates + 1] = out.OutHit end
        candidates[#candidates + 1] = out
        for _, candidate in ipairs(candidates) do
            if candidate ~= nil then
                local distance = nil
                pcall(function() distance = tonumber(unwrap(candidate.Distance)) end)
                if distance ~= nil and distance > 0 then return distance end
                local z = nil
                pcall(function()
                    local point = unwrap(candidate.ImpactPoint) or unwrap(candidate.Location)
                    if point ~= nil then z = tonumber(unwrap(point.Z)) end
                end)
                if z ~= nil then return z - start_z end
            end
        end
        return nil
    end

    -- Headroom above the pawn's location in cm, or nil, reason. Open sky counts as the
    -- reach of the ray, which is above the maximum cut and so clamps to it.
    local function trace_headroom(pawn)
        local library = ceiling.library
        if not valid(library) then
            library = find_object(CLASS.system_library)
            ceiling.library = library
        end
        if not valid(library) then return nil, "kismet-system-library-missing" end
        local px, py, pz = state.player_world_x, state.player_world_y, state.player_world_z
        if px == nil or py == nil or pz == nil then return nil, "player-pose-unavailable" end
        local reach = ceiling_max_cm() + 200.0
        local best = nil
        for _, offset in ipairs(CEILING_RAY_OFFSETS) do
            local start_z = pz + CEILING_TRACE_START_CM
            local out = {}
            local ok, blocking = pcall(function()
                return unwrap(library:LineTraceSingle(pawn,
                    { X = px + offset[1], Y = py + offset[2], Z = start_z },
                    { X = px + offset[1], Y = py + offset[2], Z = start_z + reach },
                    TRACE_TYPE_VISIBILITY, false, {}, DRAW_DEBUG_NONE, out, true,
                    { R = 1.0, G = 0.0, B = 0.0, A = 1.0 }, { R = 0.0, G = 1.0, B = 0.0, A = 1.0 }, 0.0))
            end)
            if not ok then return nil, tostring(blocking) end
            if blocking == true then
                local distance = hit_distance(out, start_z)
                if distance == nil then return nil, "hit-distance-unreadable" end
                if distance >= CEILING_TRACE_MIN_HIT_CM then
                    ceiling.rays_hit = ceiling.rays_hit + 1
                    local headroom = distance + CEILING_TRACE_START_CM
                    if best == nil or headroom > best then best = headroom end
                else
                    ceiling.rays_blocked = ceiling.rays_blocked + 1
                end
            else
                ceiling.rays_open = ceiling.rays_open + 1
                local open = reach + CEILING_TRACE_START_CM
                if best == nil or open > best then best = open end
            end
        end
        if best == nil then return nil, "every-ray-began-inside-geometry" end
        return best
    end

    local function write_near_plane(slice)
        if not valid(view.component) then return false end
        local plane = camera_height_cm() - slice
        if ceiling.applied_cm ~= nil and math.abs(ceiling.applied_cm - plane) < 1.0 then return true end
        local ok = pcall(function() view.component.CustomNearClippingPlane = plane end)
        if ok then ceiling.applied_cm = plane end
        return ok
    end

    -- Called once per capture tick, before CaptureScene. Returns the slice in use.
    local function update_ceiling(pawn)
        if not ceiling_auto_enabled() or ceiling.disabled_reason ~= nil then
            if ceiling.slice_cm ~= nil then
                ceiling.slice_cm = nil
                write_near_plane(slice_cm())
            end
            return slice_cm()
        end
        local token = Perf.Begin()
        local headroom, reason = trace_headroom(pawn)
        Perf.End("dungeon.ceiling", token)
        if headroom == nil then
            ceiling.trace_failures = ceiling.trace_failures + 1
            if ceiling.trace_ok == 0 and ceiling.trace_failures >= CEILING_DISABLE_AFTER_FAILURES then
                ceiling.disabled_reason = tostring(reason or "trace-failed")
                log("Dungeon view auto ceiling cut disabled for this session: " .. ceiling.disabled_reason
                    .. " (the fixed cut of " .. string.format("%.2f", slice_cm() / 100.0) .. " m stands)")
                ceiling.slice_cm = nil
                write_near_plane(slice_cm())
            end
            return ceiling.slice_cm or slice_cm()
        end
        ceiling.trace_ok = ceiling.trace_ok + 1
        ceiling.headroom_cm = headroom
        local floor_cm, max_cm = slice_cm(), ceiling_max_cm()
        local target = headroom - CEILING_TRACE_MARGIN_CM
        if target < floor_cm then target = floor_cm elseif target > max_cm then target = max_cm end
        local current = ceiling.slice_cm or floor_cm
        if target > current then
            current = current + (target - current) * CEILING_RAISE_FRACTION
        else
            current = current - (current - target) * CEILING_LOWER_FRACTION
        end
        ceiling.slice_cm = current
        write_near_plane(current)
        if not ceiling.logged_first then
            ceiling.logged_first = true
            debug_log(string.format("Dungeon view auto ceiling cut first reading headroom=%.2fm cut=%.2fm floor=%.2fm max=%.2fm",
                headroom / 100.0, current / 100.0, floor_cm / 100.0, max_cm / 100.0))
        end
        return current
    end
    view.CeilingState = ceiling

    ---------------------------------------------------------------------------
    -- Build and teardown
    ---------------------------------------------------------------------------

    ---------------------------------------------------------------------------
    -- MAP LIGHTING (v0.15.1). The level has ONE lighting rig -- a DirectionalLight, a
    -- SkyLight, a SkyAtmosphere and an ExponentialHeightFog component on one Blueprint
    -- actor -- and the game rewrites it with each zone's profile (Evidence/V0150: sun
    -- 0 -> 200 lux, sky x2, sky luminance x10, fog inscatter x10, 0.9 s after a teleport).
    -- Up-facing ground under a bright profile exceeds what any capture can hold, and there
    -- is no per-capture lighting override in the engine.
    --
    -- But CaptureScene() renders immediately and flushes pending light-state changes
    -- first. So, in one game-thread call: read the rig, set map-lighting values through the
    -- Blueprint SETTERS (a raw property write does not mark the render state dirty; the
    -- setters do), capture, restore through the same setters. The capture renders under
    -- map lighting; the player's view renders at the end of the same frame under the
    -- restored rig. Probe v0.10.0 ran this 25 times at 5 Hz: control capture 255 in every
    -- pixel, every map-lit capture mean 152 with nothing clipped, identical to the decimal,
    -- rig read back as the game's values after every restore, and no flicker on her screen.
    --
    -- SAFETY. Restore runs on every path, including a capture error. If any of the four
    -- reads fails, the override is skipped for that capture rather than restored from a
    -- guess -- a wrong restore would leave the world dark, and that must be impossible.
    -- The rig components are game-owned; they are validated before every use, re-found at
    -- most once per RIG_REFIND_SECONDS when invalid, and dropped at LoadMap PRE with
    -- everything else (invariant 0).
    local RIG_REFIND_SECONDS = 5.0
    -- v0.18.35 (user): the leashes v0.18.31 put on this cache are GONE, and they should
    -- never have been here. They were added for a crash this was not causing -- the
    -- MinimapPOIProbe dev mod was -- and the cost of them was visible in play: her 184314
    -- run dropped the rig six times in forty-five seconds, and because a re-find is
    -- throttled to RIG_REFIND_SECONDS, 430 captures in that run ran with no map lighting
    -- at all. That is the map flashing bright and back every few seconds near anything
    -- being destroyed. Her words: "it's jarring and I don't like it, make it the behavior
    -- it was before we were trying to debug this."
    --
    -- The original risk is real and stays written down: these are the LEVEL's components,
    -- and a streamed-out level takes them while this cache still points at them. It has
    -- never been seen to fault. If it ever is, the fix is not a leash that costs a visible
    -- flicker -- it is to stop touching the world's lighting and set the CAPTURE's own
    -- show flags instead, on our own component, the way the 18 post-process values
    -- already are.
    local RIG_CLASSES = {
        sun = "DirectionalLightComponent", sky = "SkyLightComponent",
        atmo = "SkyAtmosphereComponent", fog = "ExponentialHeightFogComponent",
    }
    local rig = { parts = nil, next_find_clock = nil, skipped = 0, applied = 0, misses = {} }

    -- v0.18.30 CRASH BREADCRUMB. v0.18.29's tick-stage trail named this stage: her
    -- 17:32:27 run ends on "Tick stage=dungeon" with nothing after it, at the same spot
    -- that crashed at 21:09:00Z and 21:22:34Z. This stage is the only one that touches
    -- GAME-OWNED objects held between ticks -- the four map-lighting rig components -- and
    -- it reads and writes their properties through exactly the UE4SS reflection path that
    -- faults at +0x36562e. These name the step. Same flag as the discovery breadcrumbs.
    local function crumb(step, extra)
        if Config.LocalDiscoveryTrace ~= true then return end
        log("Dungeon crumb step=" .. tostring(step)
            .. (extra ~= nil and (" " .. tostring(extra)) or ""))
    end

    local function rig_enabled()
        return knob_bool("DungeonCaptureRig", true)
    end

    local function first_component(class_name)
        if type(FindAllOf) ~= "function" then return nil end
        local token = Perf.Begin()
        local ok, list = pcall(FindAllOf, class_name)
        Perf.End("native.findall", token)
        if not ok or type(list) ~= "table" then return nil end
        for _, item in ipairs(list) do
            local component = unwrap(item)
            if valid(component) then return component end
        end
        return nil
    end

    local function rig_parts(now)
        local parts = rig.parts
        -- THE SUSPECT. These four are game-owned components cached across ticks, and when
        -- an area streams out the level that owns them goes with it. valid() is a raw
        -- pointer dereference through UE4SS, so on a freed component the CHECK ITSELF can
        -- be the faulting read -- which is why the crumb goes before it, not after.
        crumb("rig-validate", "cached=" .. tostring(parts ~= nil))
        if parts ~= nil and valid(parts.sun) and valid(parts.sky) and valid(parts.atmo)
            and valid(parts.fog) then
            crumb("rig-validate-ok")
            return parts
        end
        crumb("rig-refind")
        rig.parts = nil
        if rig.next_find_clock ~= nil and now < rig.next_find_clock then return nil end
        rig.next_find_clock = now + RIG_REFIND_SECONDS
        local found = {}
        local missing = {}
        for key, class_name in pairs(RIG_CLASSES) do
            found[key] = first_component(class_name)
            if found[key] == nil then missing[#missing + 1] = key end
        end
        if #missing > 0 then
            table.sort(missing)
            local signature = table.concat(missing, ",")
            if rig.misses[signature] == nil then
                rig.misses[signature] = true
                log("Dungeon view map lighting: rig incomplete, missing " .. signature
                    .. "; captures use the game's lighting until it appears")
            end
            return nil
        end
        rig.parts = found
        debug_log("Dungeon view map lighting: rig found")
        return found
    end

    local function read_number(object, key)
        local ok, value = pcall(function() return object[key] end)
        if not ok then return nil end
        return tonumber(value)
    end
    local function read_color(object, key)
        local ok, value = pcall(function() return object[key] end)
        if not ok or value == nil then return nil end
        local ok_c, r, g, b, a = pcall(function() return value.R, value.G, value.B, value.A end)
        if not ok_c or r == nil then return nil end
        r, g, b, a = tonumber(r), tonumber(g), tonumber(b), tonumber(a)
        if r == nil or g == nil or b == nil then return nil end
        return { R = r, G = g, B = b, A = a or 1.0 }
    end

    local function read_rig(parts)
        local values = {
            sun = read_number(parts.sun, "Intensity"),
            sky = read_number(parts.sky, "Intensity"),
            factor = read_color(parts.atmo, "SkyLuminanceFactor"),
            fog = read_color(parts.fog, "FogInscatteringLuminance"),
        }
        if values.sun == nil or values.sky == nil or values.factor == nil or values.fog == nil then
            return nil
        end
        return values
    end

    -- The four setters. Each returns whether the engine accepted the call; the caller
    -- treats any refusal on the SET side as a reason to restore immediately.
    local function write_rig(parts, values)
        local ok = true
        ok = pcall(parts.sun.SetIntensity, parts.sun, values.sun) and ok
        ok = pcall(parts.sky.SetIntensity, parts.sky, values.sky) and ok
        ok = pcall(parts.atmo.SetSkyLuminanceFactor, parts.atmo, values.factor) and ok
        local fog_ok = pcall(parts.fog.SetFogInscatteringColor, parts.fog, values.fog)
        if not fog_ok then
            fog_ok = pcall(parts.fog.SetFogInscatteringLuminance, parts.fog, values.fog)
        end
        return ok and fog_ok
    end

    local function map_lighting_values()
        local fog = knob_number("DungeonCaptureRigFog", 0.4)
        local factor = knob_number("DungeonCaptureRigSkyFactor", 1.0)
        return {
            sun = knob_number("DungeonCaptureRigSun", 0.0),
            sky = knob_number("DungeonCaptureRigSky", 1.0),
            factor = { R = factor, G = factor, B = factor, A = 1.0 },
            fog = { R = fog, G = fog, B = fog, A = 1.0 },
        }
    end

    -- Run `capture` under map lighting. Returns the capture's own result and whether the
    -- rig was applied. Restore is unconditional once the set has been attempted.
    local function with_map_lighting(now, capture)
        if not rig_enabled() then
            crumb("capture-no-rig")
            local r = capture()
            crumb("capture-no-rig-done")
            return r, false
        end
        local parts = rig_parts(now)
        if parts == nil then
            rig.skipped = rig.skipped + 1
            crumb("capture-rig-missing")
            local r = capture()
            crumb("capture-rig-missing-done")
            return r, false
        end
        crumb("rig-read")
        local before = read_rig(parts)
        if before == nil then
            rig.skipped = rig.skipped + 1
            crumb("capture-rig-unreadable")
            local r = capture()
            crumb("capture-rig-unreadable-done")
            return r, false
        end
        crumb("rig-set")
        local token = Perf.Begin()
        local set_ok = write_rig(parts, map_lighting_values())
        Perf.End("dungeon.rig.set", token)
        local ok_capture, result = true, false
        if set_ok then
            crumb("capture-scene")
            ok_capture, result = pcall(capture)
        end
        crumb("rig-restore")
        token = Perf.Begin()
        local restored = write_rig(parts, before)
        Perf.End("dungeon.rig.restore", token)
        if not restored then
            -- Try once more; a rig left dark is the one outcome this must not produce.
            restored = write_rig(parts, before)
            if not restored then
                log("Dungeon view map lighting: RESTORE REFUSED; disabling the override")
                Config.DungeonCaptureRig = false
            end
        end
        if not set_ok then rig.skipped = rig.skipped + 1; return capture(), false end
        if not ok_capture then error(result, 0) end
        rig.applied = rig.applied + 1
        return result, true
    end

    local function destroy_capture_actor()
        -- Only ever called while the world is alive (a settings rebuild). LoadMap PRE
        -- goes through DropWorldReferencesUnread instead and never touches these.
        if valid(view.actor) then
            pcall(view.actor.K2_DestroyActor, view.actor)
        end
        view.actor, view.component = nil, nil
    end

    -- Forget everything this world's frame owned, without reading any of it. The Image is
    -- only unparented when the frame it belongs to is still the live one -- calling
    -- RemoveFromParent on a widget whose canvas has already been destroyed is itself the
    -- dereference this whole function exists to avoid.
    local function release_widgets(frame_is_live)
        if frame_is_live and valid(view.image) then
            pcall(view.image.RemoveFromParent, view.image)
        end
        view.image, view.slot = nil, nil
        view.angle = nil
        view.tint = nil
        view.brush_ok = false
        view.built = false
        view.active = false
        view.target = nil
        view.last_capture_clock = nil
        view.last_x, view.last_y, view.last_z = nil, nil, nil
        view.ortho_width_cm = nil
        view.surface_px = nil
        view.rebuild_after_clock = clock() + REBUILD_SETTLE_SECONDS
    end

    -- The renderer tears its whole widget down and rebuilds it for any setting marked
    -- rebuild (map size, shape, tile budget, LOD bias, icon cap). Lifecycle tells us, but
    -- this module does not rely on being told: if the frame under us is not the frame we
    -- built into, everything we hold is garbage and must go before it is touched.
    local function frame_changed()
        local frame = state.retained and state.retained.frame or nil
        return view.built and (not valid(frame) or frame ~= view.frame)
    end

    local function build_capture(controller, pawn)
        local active = capture_config()
        local capture_class = find_object(CLASS.scene_capture)
        local library = find_object(CLASS.rendering_library)
        if capture_class == nil or library == nil then
            view.unavailable_reason = "scene-capture classes not resident"
            return false
        end
        view.rendering_library = library

        local surface, ortho_cm = surface_and_ortho()
        local px = target_pixels()
        local ok_target, target = pcall(function()
            return unwrap(library:CreateRenderTarget2D(controller, px, px,
                active.format,
                { R = 0.0, G = 0.0, B = 0.0, A = 1.0 }, false, false))
        end)
        target = ok_target and target or nil
        if not valid(target) then
            view.unavailable_reason = "render target creation failed"
            return false
        end
        view.target = target

        local world = nil
        pcall(function() world = unwrap(pawn:GetWorld()) end)
        if not valid(world) then
            view.unavailable_reason = "world unavailable"
            return false
        end
        local x, y, z = state.player_world_x, state.player_world_y, state.player_world_z
        if x == nil or y == nil or z == nil then
            view.unavailable_reason = "player pose unavailable"
            return false
        end
        local ok_spawn, actor = pcall(function()
            return unwrap(world:SpawnActor(capture_class,
                { X = x, Y = y, Z = z + camera_height_cm() },
                { Pitch = -90.0, Yaw = 0.0, Roll = 0.0 }))
        end)
        actor = ok_spawn and actor or nil
        if not valid(actor) then
            view.unavailable_reason = "capture actor spawn failed"
            return false
        end
        view.actor = actor

        local component = nil
        pcall(function() component = unwrap(actor.CaptureComponent2D) end)
        if not valid(component) then
            view.unavailable_reason = "capture component missing"
            destroy_capture_actor()
            return false
        end
        view.component = component

        local height = camera_height_cm()
        local writes = {
            { "TextureTarget", target },
            { "bCaptureEveryFrame", false },
            { "bCaptureOnMovement", false },
            { "ProjectionType", PROJECTION_ORTHOGRAPHIC },
            { "OrthoWidth", ortho_cm },
            { "bAutoCalculateOrthoPlanes", false },
            { "bOverride_CustomNearClippingPlane", true },
            { "CustomNearClippingPlane", height - slice_cm() },
            { "CaptureSource", active.source },
            { "UnlitViewmode", active.unlit },
            { "MaxViewDistanceOverride", ortho_cm },
            { "LODDistanceFactor", active.lod },
            { "PostProcessBlendWeight", 0.0 },
            { "bIgnoreScreenPercentage", true },
            -- The capture stays world-fixed; the picture is turned by the Image's render
            -- transform, so the pawn's yaw must never rotate the camera.
            { "bAbsoluteRotation", true },
            -- A histogram exposure needs its history kept between one-shot captures, or
            -- every capture starts from scratch. Harmless when post process is off.
            { "bAlwaysPersistRenderingState", active.persist == true },
        }
        local all_ok = true
        for _, write in ipairs(writes) do
            all_ok = pcall(function() component[write[1]] = write[2] end) and all_ok
        end
        -- v0.16.11: a fresh component carries the fixed cut; the auto cut re-applies
        -- itself on the next capture tick.
        ceiling.applied_cm = nil
        local pp_applied, pp_verified, pp_path = apply_post_process(component, active.pp)
        view.pp_verified = pp_verified
        view.pp_path = pp_path
        pcall(function()
            component:K2_SetRelativeRotation({ Pitch = -90.0, Yaw = 0.0, Roll = 0.0 },
                false, {}, true)
        end)
        local attached = pcall(function()
            actor:K2_AttachToActor(pawn, FName("None"), 1, 1, 1, false)
        end)
        view.ortho_width_cm = ortho_cm
        view.surface_px = surface
        view.target_px = px
        view.capture_description = describe(active)
        log(string.format(
            "Dungeon view capture built capture=%s ppApplied=%d ppVerified=%d ppPath=%s ortho=%.1fm slice=%.2fm height=%.1fm target=%dpx surface=%dpx writes=%s attached=%s",
            view.capture_description, pp_applied, pp_verified, pp_path,
            ortho_cm / 100.0, slice_cm() / 100.0, height / 100.0, px, surface,
            tostring(all_ok), tostring(attached)))
        return true
    end

    local function build_image()
        local frame = state.retained and state.retained.frame or nil
        if not valid(frame) then
            view.unavailable_reason = "minimap frame unavailable"
            return false
        end
        local image_class = find_object(CLASS.image)
        if not valid(image_class) then
            view.unavailable_reason = "UImage class not resident"
            return false
        end
        state.widget_counter = (tonumber(state.widget_counter) or 0) + 1
        local ok, err = pcall(function()
            local image = unwrap(StaticConstructObject(image_class, frame,
                FName("MS2Minimap_DungeonView_" .. tostring(state.widget_counter))))
            assert(valid(image), "dungeon-view Image construction failed")
            view.image = image
            local slot = unwrap(frame:AddChildToCanvas(image))
            assert(valid(slot), "dungeon-view slot failed")
            view.slot = slot
            view.frame = frame
            -- Z 2 is the tile-map layer. The tile map is collapsed wherever this draws,
            -- so the two never contend; every overlay pool sits above.
            pcall(slot.SetZOrder, slot, 2)
            pcall(image.SetRenderTransformPivot, image, { X = 0.5, Y = 0.5 })
            image:SetVisibility(VIS_COLLAPSED)
        end)
        if not ok then
            view.unavailable_reason = "dungeon-view Image failed: " .. tostring(err)
            return false
        end
        -- A UTextureRenderTarget2D is a UTexture, so the proven SetBrushFromTexture call
        -- shape takes it. SetBrushResourceObject is the documented alternative and has no
        -- precedent anywhere in this suite, so it is only the fallback (invariant 0b).
        view.brush_ok = pcall(view.image.SetBrushFromTexture, view.image, view.target, false)
        if not view.brush_ok then
            view.brush_ok = pcall(view.image.SetBrushResourceObject, view.image, view.target)
        end
        if not view.brush_ok then
            view.unavailable_reason = "render target would not bind to the Image brush"
            return false
        end
        return true
    end

    local function apply_layout()
        if not view.built or not valid(view.slot) then return end
        local size = tonumber(Config.Size) or 280.0
        local surface = view.surface_px or math.max(1.0, size - 4.0)
        pcall(view.slot.SetPosition, view.slot,
            { X = (size - surface) / 2.0, Y = (size - surface) / 2.0 })
        pcall(view.slot.SetSize, view.slot, { X = surface, Y = surface })
    end

    -- v0.18.45: a span change in place, no teardown. Called from ApplyLiveSetting for the
    -- three rows that change only how much world a pixel covers -- Size, Map range and
    -- orientation. Returns false if it could not run, and the caller falls back to the
    -- coalesced rebuild rather than leaving the picture wrong.
    --
    -- valid(view.component) is the same wrapper read the capture path already does every
    -- tick behind crumb("component-valid"), so this adds no exposure invariant 0 does not
    -- already carry here; it is reached from the settings apply, which runs inside the pose
    -- tick, so it is on the game thread like every other engine touch in this module.
    local function apply_span_live()
        if not view.built or not valid(view.component) then return false end
        local surface, ortho_cm = surface_and_ortho()
        local ok = pcall(function() view.component.OrthoWidth = ortho_cm end)
        -- Written together at build and kept together here: the view distance is the span,
        -- so leaving it behind would clip the far edge of a widened capture.
        ok = pcall(function() view.component.MaxViewDistanceOverride = ortho_cm end) and ok
        if not ok then return false end
        view.ortho_width_cm = ortho_cm
        view.surface_px = surface
        apply_layout()
        -- Draw at the new span on the next tick instead of waiting for the move gate.
        view.last_capture_clock = nil
        view.respans = (tonumber(view.respans) or 0) + 1
        return true
    end

    -- One attempt per call, from the pose tick. A failure is recorded and retried on the
    -- next world, never in a loop: a missing class or a refused spawn will not fix itself
    -- mid-world, and the fallback presentation is already correct.
    local function try_build()
        -- `ready` is set only by OnRendererReady, so a view dropped at LoadMap PRE cannot
        -- rebuild itself against the departing world's frame. The tick already gates on
        -- the renderer being built; this makes the module safe on its own terms too.
        if not view.ready then return false end
        if view.built or view.build_failures > 0 then return view.built end
        local after = view.rebuild_after_clock
        if after ~= nil and clock() < after then return false end
        local controller = state.controller
        local pawn = state.player
        if not valid(controller) or not valid(pawn) then return false end
        local token = Perf.Begin()
        local ok = build_capture(controller, pawn) and build_image()
        Perf.End("dungeon.build", token)
        if not ok then
            view.build_failures = view.build_failures + 1
            destroy_capture_actor()
            view.target = nil
            log("Dungeon view unavailable: " .. tostring(view.unavailable_reason)
                .. "; unmapped areas fall back to the Transparent background")
            return false
        end
        view.built = true
        view.last_capture_clock = nil
        view.last_x, view.last_y, view.last_z = nil, nil, nil
        apply_layout()
        log(string.format("Dungeon view ready ortho=%.1fm target=%dpx rate=%sHz",
            (view.ortho_width_cm or 0) / 100.0, view.target_px or 0,
            tostring(Config.DungeonViewRate)))
        return true
    end

    ---------------------------------------------------------------------------
    -- Per-tick update. Called from the pose tick only -- see the thread rule.
    ---------------------------------------------------------------------------

    local function moved_enough()
        if view.last_x == nil then return true end
        local x, y = state.player_world_x, state.player_world_y
        if x == nil or y == nil then return false end
        local dx, dy = x - view.last_x, y - view.last_y
        return (dx * dx + dy * dy) >= (MOVE_EPSILON_UNITS * MOVE_EPSILON_UNITS)
    end

    local function due_for_capture(now)
        local last = view.last_capture_clock
        if last == nil then return true end
        if (now - last) < capture_interval_seconds() then return false end
        if moved_enough() then return true end
        -- Standing still costs nothing until the idle refresh comes round, which exists
        -- so a door opened from where you stand still reaches the picture.
        return (now - last) >= IDLE_REFRESH_SECONDS
    end

    local function apply_rotation()
        if not valid(view.image) then return end
        local desired = (tonumber(state.map_rotation_angle) or 0.0)
            + CAPTURE_YAW_OFFSET_DEGREES
        desired = MapScale.NormalizeDegrees(desired)
        if view.angle ~= nil
            and math.abs(((desired - view.angle + 180.0) % 360.0) - 180.0)
                < ROTATION_IDLE_EPSILON_DEGREES then
            return
        end
        if pcall(view.image.SetRenderTransformAngle, view.image, desired) then
            view.angle = desired
        end
    end

    function view.Update(pan_due)
        -- v0.18.32. FOUR crashes now, all the same 25-frame stack at UE4SS+0x36562e, and
        -- the fourth came WITH the rig leashed -- so the map-lighting cache was not the
        -- whole story, and she was right to doubt it ("I know 100% I ran past this area
        -- before... and the lighting option 100% was turned on").
        --
        -- What the fourth crash narrows: its log ends on "Tick stage=dungeon" with NO
        -- capture crumb after it, so the fault is in this function BEFORE crumb("ceiling").
        -- Everything in that stretch is untraced, and one line of it is the same kind of
        -- mistake as the rig -- `valid(view.component)`, a wrapper to an actor this mod
        -- spawned, held across ticks, where a streamed-out level takes the actor and the
        -- validity check becomes a read of freed memory.
        --
        -- So every step gets a crumb. These only run while the view is ACTIVE and only
        -- while LocalDiscoveryTrace is on; the run that answers this can afford them.
        crumb("enter")
        if frame_changed() then
            -- Same world, new frame: the capture actor is still alive and ours, so this
            -- is the one path that may destroy it rather than drop it unread.
            view.capture_rebuild_deadline, view.capture_rebuild_observed = nil, 0
            destroy_capture_actor()
            release_widgets(false)
            debug_log("Dungeon view released: the minimap frame was rebuilt")
        end
        -- v0.18.42: the coalesced capture rebuild. See ApplyLiveSetting's "zoom" branch --
        -- Map range and orientation change how much world a pixel covers, so the capture has
        -- to be rebuilt against the new span, and the teardown waits here until the stepping
        -- stops. Until then the existing capture keeps drawing at its old span, which is the
        -- correct picture for the setting still in force.
        crumb("capture-rebuild-due")
        if view.capture_rebuild_deadline ~= nil and clock() >= view.capture_rebuild_deadline then
            local observed = math.floor(tonumber(view.capture_rebuild_observed) or 0)
            view.capture_rebuild_deadline, view.capture_rebuild_observed = nil, 0
            if view.built then
                destroy_capture_actor()
                -- A live setting, so the frame is still alive and the Image can be
                -- unparented properly rather than merely forgotten. This also arms
                -- rebuild_after_clock, so the rebuild follows one settle later.
                release_widgets(true)
                view.build_failures = 0
            end
            if observed > 1 then
                log(string.format(
                    "Dungeon capture rebuild coalesced observed=%d into=1 debounceMs=%d",
                    observed, math.floor(CAPTURE_COALESCE_SECONDS * 1000)))
            end
        end
        crumb("wanted")
        local wanted = view.Wanted()
        if wanted and not view.built then crumb("build"); try_build(); crumb("build-done") end
        crumb("active")
        local active = view.Active()
        if active ~= view.active then
            view.active = active
            crumb("active-changed", "active=" .. tostring(active))
            if valid(view.image) then
                pcall(view.image.SetVisibility, view.image,
                    active and VIS_HIT_TEST_INVISIBLE or VIS_COLLAPSED)
            end
            crumb("refresh-area")
            -- The renderer owns backdrop/cloud/tile visibility and has to be told the
            -- dungeon layer came or went.
            if type(ctx.Renderer) == "table"
                and type(ctx.Renderer.RefreshAreaPresentation) == "function" then
                ctx.Renderer.RefreshAreaPresentation()
            end
            debug_log("Dungeon view " .. (active and "engaged" or "released")
                .. " noMap=" .. tostring(state.area_map_available == false)
                .. " mode=" .. background_mode())
        end
        if not active then return false end
        crumb("rotation")
        apply_rotation()
        -- Cached: this writes only when the multiplier actually changes, which is a
        -- settings edit or crossing the mapped/unmapped boundary.
        crumb("brightness")
        apply_brightness()
        local now = clock()
        crumb("due")
        if not due_for_capture(now) then return false end
        -- THE SUSPECT. Our own spawned capture component, held between ticks. If a level
        -- unload took the actor with it, this check is the faulting read -- not the code
        -- after it, which is why the crumb goes before.
        crumb("component-valid")
        if not valid(view.component) then
            view.capture_failures = view.capture_failures + 1
            return false
        end
        Perf.Mark("dungeon.capture.interval")
        -- v0.16.11: the ceiling cut for this capture, from the headroom above the pawn.
        crumb("ceiling")
        pcall(update_ceiling, unwrap(state.player))
        crumb("ceiling-done")
        local token = Perf.Begin()
        -- with_map_lighting returns the capture's own verdict; the outer pcall only guards
        -- the rig handling, and a failure there counts as a failed capture too.
        local ok_wrap, ok = pcall(with_map_lighting, now, function()
            return pcall(view.component.CaptureScene, view.component)
        end)
        ok = ok_wrap and ok == true
        crumb("capture-done", "ok=" .. tostring(ok))
        Perf.End("dungeon.capture", token)
        if ok then
            view.captures = view.captures + 1
            view.last_capture_clock = now
            view.last_x, view.last_y, view.last_z =
                state.player_world_x, state.player_world_y, state.player_world_z
        else
            view.capture_failures = view.capture_failures + 1
            if view.capture_failures == 1 then
                log("Dungeon view capture refused; the picture will hold its last frame")
            end
        end
        return ok
    end

    ---------------------------------------------------------------------------
    -- Lifecycle
    ---------------------------------------------------------------------------

    function view.OnRendererReady()
        -- A frame exists now, and it may be a different frame from the one we last built
        -- into (a settings rebuild). Anything we still hold belongs to the old one.
        -- v0.18.42: a widget rebuild supersedes any pending capture-span rebuild. The
        -- capture is going anyway and comes back against whatever the settings now say.
        view.capture_rebuild_deadline, view.capture_rebuild_observed = nil, 0
        if view.built or view.actor ~= nil then
            -- An actor still here means the world never changed, so destroying it is safe
            -- and necessary; after LoadMap PRE it is already nil and nothing is touched.
            destroy_capture_actor()
            release_widgets(false)
        end
        -- Unconditionally, not only when something was held: a run of rebuilds (the user
        -- dragging the map-size slider) hands us a fresh frame every ~130 ms, and only the
        -- first of those has anything to release. The window has to restart on each one or
        -- the delay elapses in the middle of the drag and we spawn into a doomed frame.
        view.rebuild_after_clock = clock() + REBUILD_SETTLE_SECONDS
        view.ready = true
        view.build_failures = 0
        view.unavailable_reason = nil
        return true
    end

    function view.DropWorldReferencesUnread()
        -- LoadMap PRE: primitives only, no UObject touched. The capture actor belongs to
        -- the departing world and is destroyed with it.
        view.actor, view.component, view.target = nil, nil, nil
        view.image, view.slot, view.rendering_library = nil, nil, nil
        view.frame = nil
        -- v0.18.42: a pending capture rebuild belongs to the departing world.
        view.capture_rebuild_deadline, view.capture_rebuild_observed = nil, 0
        rig.parts, rig.next_find_clock = nil, nil
        view.tint = nil
        view.rebuild_after_clock = nil
        view.built = false
        view.active = false
        view.ready = false
        view.brush_ok = false
        view.build_failures = 0
        view.unavailable_reason = nil
        view.last_capture_clock = nil
        view.last_x, view.last_y, view.last_z = nil, nil, nil
        view.angle = nil
        view.ortho_width_cm = nil
        view.surface_px = nil
        ceiling.slice_cm, ceiling.headroom_cm, ceiling.applied_cm, ceiling.library = nil, nil, nil, nil
    end

    function view.ApplyLiveSetting(setting)
        local apply = setting and setting.apply or nil
        if apply == "dungeon-brightness" then
            view.tint = nil
            apply_brightness()
        elseif apply == "dungeon-ceiling" then
            -- v0.16.11: Auto/Fixed or the auto maximum changed. No rebuild: the next
            -- capture tick re-reads the headroom (or restores the fixed cut) and writes
            -- the near plane. A session-disabled auto gets one more chance.
            ceiling.slice_cm = nil
            ceiling.disabled_reason = nil
            ceiling.trace_failures = 0
            ceiling.logged_first = false
            if not ceiling_auto_enabled() then write_near_plane(slice_cm()) end
        elseif apply == "area-presentation" or apply == "dungeon" then
            -- Engagement is re-evaluated on the next tick. Clearing the cached state
            -- forces that comparison to fire even if the answer is unchanged.
            view.active = nil
        elseif apply == "zoom" or apply == "orientation" or apply == "size" then
            -- SPAN ONLY. These three change how much world one pixel covers and nothing
            -- else, and v0.18.45 stopped rebuilding the capture for them.
            --
            -- The history, because it is three corrections deep and each one was measured.
            -- v0.18.42: this used to tear the capture down HERE, on the press, so holding
            -- Map range's arrow rebuilt it every 130-200 ms (38 capture rebuilds against 9
            -- widget rebuilds in her 04:12 capture). That became a coalesced teardown, one
            -- per burst. v0.18.44's video then measured what was left: five blank windows of
            -- 100-133 ms, one per coalesced rebuild, the widget itself never leaving.
            --
            -- And the teardown was never needed. A span change touches exactly two component
            -- properties, OrthoWidth and MaxViewDistanceOverride, both derived from
            -- surface_and_ortho. It does NOT touch the render target: target_pixels() reads
            -- DungeonViewPixels and the format comes from the CAPTURE rows, so neither moves
            -- when Size, Map range or orientation do. The same target, the same actor and the
            -- same component serve the new span. So they are written in place, the Image slot
            -- is re-laid out by apply_layout, and the next tick captures.
            --
            -- Forcing that capture matters: standing still in a settings menu, moved_enough()
            -- is false, so without it the picture would keep its old framing until the 3 s
            -- idle refresh -- correct span, stale picture, stretched into the new slot. One
            -- capture per changed step is still far cheaper than the spawn-and-destroy it
            -- replaces, and the rate limiter still caps it.
            --
            -- If the live path cannot run -- no component, or a refused write -- it falls
            -- back to the coalesced rebuild below, which is the v0.18.42 behaviour.
            local respanned = false
            if view.built then
                local token = Perf.Begin()
                respanned = apply_span_live()
                Perf.End("dungeon.respan", token)
            end
            if view.built and not respanned then
                view.capture_rebuild_deadline = clock() + CAPTURE_COALESCE_SECONDS
                view.capture_rebuild_observed =
                    math.floor(tonumber(view.capture_rebuild_observed) or 0) + 1
            end
        elseif apply == "dungeon-capture" then
            -- The CAPTURE rows are different in kind and keep the coalesced rebuild: the
            -- format row changes the render target's pixel format and the resolution row
            -- changes its size, so the target itself has to be recreated, which is the one
            -- thing a re-span cannot do. They are Advanced rows and nobody holds an arrow
            -- on them, so the teardown costs nothing that matters.
            if view.built then
                view.capture_rebuild_deadline = clock() + CAPTURE_COALESCE_SECONDS
                view.capture_rebuild_observed =
                    math.floor(tonumber(view.capture_rebuild_observed) or 0) + 1
            end
        end
    end

    function view.Summary()
        return string.format(
            "dungeonView=%s capture=%s ppVerified=%s ppPath=%s mapLighting=%s rigApplied=%d rigSkipped=%d mode=%s everywhere=%s built=%s captures=%d respans=%d failures=%d ortho=%.1fm target=%dpx rate=%sHz tint=%.2f reason=%s",
            tostring(view.Active()), tostring(view.capture_description or describe(capture_config())),
            tostring(view.pp_verified or 0), tostring(view.pp_path or "none"),
            rig_enabled() and (rig.parts ~= nil and "on" or "on(no-rig)") or "off",
            rig.applied, rig.skipped,
            background_mode(),
            tostring(wanted_everywhere()),
            tostring(view.built), view.captures, math.floor(tonumber(view.respans) or 0), view.capture_failures,
            (view.ortho_width_cm or 0) / 100.0, view.target_px or 0,
            tostring(Config.DungeonViewRate), view.tint or brightness(),
            tostring(view.unavailable_reason or "none"))
            .. string.format(" ceiling=%s headroom=%.1fm cut=%.2fm traces=%d/%d rays=%d/%d/%d",
                ceiling.disabled_reason ~= nil and ("disabled:" .. ceiling.disabled_reason)
                    or (ceiling_auto_enabled() and "auto" or "fixed"),
                (ceiling.headroom_cm or 0) / 100.0, (ceiling.slice_cm or slice_cm()) / 100.0,
                ceiling.trace_ok, ceiling.trace_failures,
                ceiling.rays_hit, ceiling.rays_open, ceiling.rays_blocked)
    end

    return view
end

return Factory
