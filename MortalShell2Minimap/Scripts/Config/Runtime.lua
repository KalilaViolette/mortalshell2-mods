-- Owns MortalShell2Minimap configuration defaults, normalization, persistence,
-- and the single mutable Values table shared with the composition root.

local Factory = {}

function Factory.New(options)
    options = type(options) == "table" and options or {}
    local config_path = tostring(options.config_path or "MinimapConfig.ini")
    local log = type(options.log) == "function" and options.log or function() end
    local categories = type(options.categories) == "table" and options.categories or {}
    -- v0.10.11 local-interactable categories (Local.Classifier.CategoryList()).
    -- v0.18.3: this fallback had drifted seven categories behind the classifier, so a
    -- run that reached it would silently lose the config keys for Barrel through
    -- Thestus. It is now a mirror of CategoryList(), scales included; if the two ever
    -- disagree again, Validation/Regression.lua fails on the category count.
    local local_categories = type(options.local_categories) == "table" and options.local_categories or {
        { key = "Lore" }, { key = "Chest" }, { key = "ShellGhost" }, { key = "Pickup" },
        { key = "Other" }, { key = "NPC" }, { key = "Merchant" }, { key = "Service" },
        { key = "Movement" }, { key = "Trap", scale = 0.60 }, { key = "Boss", scale = 0.85 },
        { key = "Enemy", scale = 0.50 }, { key = "Secret", scale = 1.10 },
        { key = "Barrel" }, { key = "Loot" }, { key = "Rest", scale = 0.90 },
        { key = "MapFragment", scale = 2.00 }, { key = "LockedDoor" },
        { key = "GloomSiphon" }, { key = "Thestus", scale = 1.50 },
    }
    -- v0.11.7: per-category size lives here rather than only in the ini. `scale` comes
    -- from Classifier.CategoryList(); anything without one draws at the shared size.
    -- A lower-cased string from a fixed set, else the default. An empty set keeps
    -- the default: a category with one icon has nothing to choose.
    local function one_of(value, allowed, default)
        value = tostring(value or ""):lower()
        if type(allowed) == "table" then
            for _, candidate in ipairs(allowed) do
                if tostring(candidate):lower() == value then return value end
            end
        end
        return tostring(default)
    end

    local function category_scale_default(category)
        local scale = tonumber(category.scale)
        if scale == nil then return 1.0 end
        return math.max(0.25, math.min(2.0, scale))
    end

    local Values = {
        Enabled = true,
        Size = 300,
        OffsetX = 28,
        OffsetY = 28,
        -- Runtime testing established that the native map's calibrated visible
        -- span is much smaller than this user-facing control. 2000 is the tested
        -- current baseline; the expanded ceiling reaches roughly a
        -- full native world-map span at the expanded 50,000 ceiling.
        ZoomMeters = 1000,
        -- v0.18.3: Ctrl+Shift+M never worked as a shipped default. The game's own
        -- input handling sees that chord first and swallows the whole press, so the
        -- window would not open at all. These two are the binds that were actually
        -- played on, and they are clear of anything the game claims.
        MenuKeybind = "LeftControl+Period",
        ControllerMenuBind = "Gamepad_LeftThumbstick+Gamepad_FaceButton_Bottom",
        ModifierSidesEquivalent = true,
        TrackerIconSize = 48,
        ShowTrackerEdgeIndicators = true,
        TrackerEdgeMaxDistance = 150,
        TrackerEdgeMinScale = 0.40,
        -- Global persistent-edge presentation. 50 keeps the accepted v0.9.8
        -- midpoint-on-boundary behavior; lower values allow more clipping and
        -- higher values keep more of each actual rendered marker inside.
        EdgeVisibility = 75,
        ShowPOIs = true,
        POIMaxIcons = 192,
        -- Event-driven local interactables discovered from the game's own
        -- interaction lifecycle. No recurring world scan is used.
        ShowLocalInteractables = true,
        LocalInteractableIconSize = 20,
        LocalInteractableBudget = 64,
        -- v0.11.0 local presentation. Plates are the soft black disc the game itself
        -- puts behind its night-mode moon icon; height markers are the chevron for
        -- markers well above or below the player. v0.18.1: the threshold is a row
        -- (user request 2026-09-14), the chevron has a size, and a marker beyond the
        -- threshold fades -- icon, plate and chevron together -- from FadeStart at the
        -- threshold down to FadeMin over FadeRange metres, so an icon on another
        -- level reads as one at a glance and never disappears.
        LocalIconPlates = true,
        LocalHeightMarkers = true,
        LocalHeightThresholdMeters = 3.0,
        LocalHeightMarkerSize = 60,
        LocalHeightFade = true,
        LocalHeightFadeStart = 75,
        LocalHeightFadeMin = 35,
        LocalHeightFadeRange = 15,
        -- Footstep trail: 0 off, otherwise the number of breadcrumbs kept.
        FootstepTrail = 16,
        -- v0.16.8: each mark's size as a percentage of the base local icon size.
        FootstepTrailSize = 100,
        -- Map labels: 0 none, 1 area name, 2 cardinals, 3 both. v0.16.8 ships both
        -- (user decision 2026-09-14); the off default dated from when label text was
        -- unproven (v0.11.3), and it has been proven since v0.12.x.
        MapLabels = 3,
        -- v0.11.3, both ini-only. EnemyRefreshHooks gates the four unproven AI
        -- refresh hooks without disabling the spawn-sourced enemy layer.
        -- LocalDiscoveryTrace logs one line per step of the v0.11.2 hooks so a crash
        -- names the call that faulted. v0.16.7 (first public release): ships OFF --
        -- her five-minute session wrote 1,199 breadcrumb lines -- and is turned on in
        -- MinimapConfig.ini when a bug report needs the call that faulted.
        EnemyRefreshHooks = true,
        LocalDiscoveryTrace = false,
        -- v0.16.8: the CAPTURE tab and the expert rows show only when this is on.
        AdvancedSettings = false,
        -- v0.11.3b: the letters are drawn in the map's ink; set this to 0 for plain
        -- white if the tinted ones are hard to read.
        MapLabelInk = true,
        -- v0.11.5, all ini-only. MapLabelSize is an explicit point size (0 = scale it
        -- from the map). MapLabelCardinals is 1 for north only or 4 for all four.
        -- MapLabelInset pulls the compass in from the map edge; 0 straddles it.
        MapLabelSize = 16,
        MapLabelCardinals = 1,
        MapLabelInset = 0.0,
        -- v0.17.1 label style rows (MAP tab). Font keys are Overlay/Labels FONT_CHOICES.
        MapLabelFont = "trajanbold",
        MapLabelColor = "white",
        MapLabelOutline = 0,
        MapLabelShadow = false,
        -- v0.11.6: the dark fog plate behind each label, the same art the icons use.
        MapLabelPlate = true,
        -- v0.12.0 two-line area label. Line one is the outer area, line two the
        -- sub-area (a dungeon, or a beacon you are standing at).
        MapAreaSubLabel = true,
        -- 60, not 18: v0.12.1 raised the module's own default and left this one, and
        -- this one wins, so her hub run still logged beaconRadiusM=18.
        MapAreaBeaconRadiusMeters = 60.0,
        LocalSettingsCategory = 1,
        POISettingsCategory = 1,
        PauseGameWhileSettingsOpen = true,
        Opacity = 0.90,
        -- Circle mode applies Opacity through a RetainerBox, which fades its own
        -- surface as well as the children it renders into it, and the circle
        -- effect material dims it again, so the visible result is Opacity^curve.
        -- Map/NativeWidget compensates with Opacity^(1/curve). 5.70 is measured,
        -- not guessed: two screenshots of the same spot at the same Opacity,
        -- Circle vs Square, aligned (ncc 0.997) and compared on map contrast in
        -- seven regions (2026-09-11): curve 6.00 read 3.9% too opaque, so the ideal sits
        -- near 5.7. The user then settled on 5.80 by eye, inside that measurement.
        -- Confirmed 2026-09-11: with 5.80 the user could not tell Circle from Square
        -- anywhere between 20% and 100%, so the temporary settings row was removed.
        -- Square mode is always linear. 1.00 disables the compensation entirely.
        -- Ini-only now: edit MinimapConfig.ini with the game closed to change it.
        CircleOpacityCurve = 5.8,
        MaxResidentTiles = 8,
        -- v0.18.5 (user): the tuned profile runs 3. Two is one step back from that,
        -- because her evidence for 3 is hours at the default 300 px map and a player who
        -- immediately drags the size to 500 sees coarser tiles over more screen. Higher
        -- bias also makes the fixed 8-tile budget cover more ground, so a slow disk
        -- churns less while you move. No side-by-side measurement exists; this is the one
        -- row here that wants her eyes rather than an argument.
        LODBias = 2,
        -- v0.18.5 (user: "Arrow can be 30"). Both go back to 30, and the pan rate is the
        -- one that matters: a pan is what marks the geometry changed, and a geometry
        -- change is what re-runs the icon projection -- the most expensive recurring loop
        -- in the mod (her run examined 395,456 objective entries across 2,531 overlay
        -- runs). Halving the pan rate roughly halves that. A 300 px map moves slowly
        -- enough on screen that 30 Hz reads as smooth.
        PanUpdatesPerSecond = 30,
        ArrowUpdatesPerSecond = 30,
        -- v0.9.6 promotes the old RotateWithCamera boolean into a three-state
        -- orientation while preserving migration from v0.9.5 configs. The legacy
        -- boolean remains hidden/persisted only for rollback compatibility.
        MapOrientation = "camera", -- north | camera | player
        MapShape = "circle", -- square | circle
        -- v0.17.0 map frame (user decision 2026-09-14: on by default, one row cycling
        -- every style, a color row under it). off | line | vector | ornate.
        MapFrame = "vector",
        MapFrameColor = "bronze", -- bronze | white | red | blue | green
        -- v0.18.0 COMBAT tab (user decision 2026-09-14): what the minimap does while the
        -- game's own music state says you are fighting (Runtime/CombatState.lua). Fresh
        -- install: dims to half, same size, never hidden. Opacity and size are fractions
        -- of the normal look; the transition is the fade between the two looks; the
        -- restore delay is how long after combat ends the normal look comes back.
        CombatHide = false,
        -- v0.18.5 (user): "make it 90% opacity 90% size as default for combat". The
        -- tuned profile has both at 100%, which turns the feature off; this is a dim and
        -- a shrink you notice without the map getting out of your way uninvited.
        CombatOpacity = 0.90,
        CombatSize = 0.90,
        CombatTransition = 0.5,
        CombatRestoreDelay = 2.0,
        RotateWithCamera = true,
        ShowArrow = true,
        TransparentNoMapBackground = true,
        -- v0.14.0 dungeon view. NoMapBackground supersedes the boolean above, which is
        -- kept only so an old ini migrates (see normalize) and a rollback still reads.
        NoMapBackground = "dungeon", -- dungeon | transparent | cloud
        -- v0.18.37 (user, pre-release): OFF. v0.18.5 shipped it ON as part of the
        -- performance cluster, but the schema's own detail text has always said "it is
        -- off by default and limited to dungeons otherwise", so the code and the row a
        -- user reads disagreed. Off is the honest one: the open-world capture is frame
        -- time every default user pays for a view the game already draws a map for.
        DungeonViewEverywhere = false,
        -- How bright the capture is drawn, per context. Two independent values, not one
        -- multiplied by a constant, so each row controls the place it names. 0.55 outdoors
        -- is measured: exterior capture hit max luminance ~255 against ~106 for a dungeon.
        DungeonViewBrightness = 1.00,
        DungeonViewOpenWorldBrightness = 0.40,
        -- v0.18.5 (user): 30 Hz. The tuned profile runs 60; the old default was 10 but
        -- only ever inside dungeons. NOTE (v0.18.37): the "runs everywhere" reason for
        -- 30 no longer holds now that DungeonViewEverywhere ships off, so this only
        -- costs inside a dungeon again. Left at 30 pending her call; the schema row
        -- still claims 10 is the default, which is a second code/doc mismatch.
        DungeonViewRate = 30,
        -- v0.15.0 CAPTURE tab. Every parameter of the live capture as a row. The defaults
        -- ARE the v0.14.x shipped capture: source 3 (SceneColorSceneDepth) into RGBA8_SRGB
        -- (3), tint 1, unlit flag on, LOD factor 4, post process muted. Everything else is
        -- the user's tuning and persists here. See Map/DungeonView.lua for what each does
        -- and what five rounds of evidence say about it.
        DungeonCaptureSource = 9,
        DungeonCaptureFormat = 9,
        DungeonCaptureTint = 1.0,
        DungeonCaptureUnlit = true,
        DungeonCaptureLOD = 4.0,
        DungeonCapturePersist = true,
        DungeonCapturePostProcess = true,
        DungeonCaptureExposureMethod = 0, -- 0 histogram, 1 basic, 2 manual
        DungeonCaptureExposureBias = 0.0,
        DungeonCaptureExposureMin = -10.0, -- EV100, the game's own range
        DungeonCaptureExposureMax = 20.0,
        DungeonCaptureExposureSpeed = 100.0,
        DungeonCapturePhysicalCamera = false,
        DungeonCaptureBloom = false,
        DungeonCaptureVignette = false,
        -- v0.15.1 MAP LIGHTING. Around each capture the level's one lighting rig is set to
        -- these values through the engine's own setters and restored before the player's
        -- view renders (Map/DungeonView.lua, Evidence/V0150). The defaults are the profile
        -- of the zone that read correctly: no sun, sky light 1, sky luminance x1, dim fog.
        -- v0.18.34: back ON, because it was never the crash. v0.18.31 switched this off
        -- on a wrong diagnosis; the 2026-09-15 crashes were the MinimapPOIProbe dev mod
        -- scanning the object array, proven by disabling that mod and walking the same
        -- ground clean. The leashes added in v0.18.31 stay -- holding the level's lighting
        -- components between captures is still an invariant 0 violation worth bounding,
        -- just not the thing that was taking the game down.
        DungeonCaptureRig = true,
        DungeonCaptureRigSun = 1,
        DungeonCaptureRigSky = 1.0,
        DungeonCaptureRigSkyFactor = 1.0,
        DungeonCaptureRigFog = 0,
        -- The probe measured 256 px at 40 m; a wider map range spreads the same pixels over
        -- more ground, so raise this if the plan reads mushy. All three are CAPTURE rows.
        -- v0.18.5 (user: "somewhere in the middle"). 512 is the middle of the row, and
        -- it is also the first size that is not upscaled: the capture covers about 72 m
        -- and the map draws it at 300 px, so 256 is below the display size and reads
        -- soft. Cost rises with the square, so this is a quarter of the profile's 1024.
        DungeonViewPixels = 512,
        DungeonViewHeightMeters = 8,
        DungeonViewSliceMeters = 3,
        -- v0.16.11 (user): the ceiling cut follows the headroom above you -- low in a
        -- corridor, high in a hall -- between the fixed cut (the floor) and this ceiling.
        DungeonViewCeilingAuto = true,
        DungeonViewCeilingMaxMeters = 25.0,
        DebugLog = false,
        -- v0.13.0: per-section CPU/count summaries every 10 s ([PERF] lines). Off is
        -- free. Also switches the shared ModUI host's logging on. PERFORMANCE_LOGGING.md.
        LogPerformance = false,
    }

    for _, category in ipairs(categories) do
        local prefix = tostring(category.config_prefix or ("POI" .. tostring(category.key or "")))
        Values[prefix .. "Visible"] = true
        -- v0.9.3 makes discovery policy explicit per family: ordinary families get
        -- DiscoveredOnly, equipment families get an independent DiscoveredHidden key
        -- so old v0.9.2 values cannot silently invert meaning. Small Beacon
        -- intentionally has no filter. v0.18.3 moves the shipped value itself onto
        -- the category as `discovery_default`, adopted from the author's own config,
        -- rather than deriving it from show_when_enabled -- which is a resolution
        -- rule about the game's state gate and was never a statement about defaults.
        local discovery_mode = tostring(category.discovery_mode or "only")
        if discovery_mode == "hidden" then
            Values[prefix .. "DiscoveredHidden"] = category.discovery_default == true
        elseif discovery_mode == "only" then
            Values[prefix .. "DiscoveredOnly"] = category.discovery_default == true
        end
        Values[prefix .. "IconSize"] = tonumber(category.size) or 30
        Values[prefix .. "EdgeIndicators"] = category.edge == true
        Values[prefix .. "EdgeMaxDistance"] = tonumber(category.edge_max_distance) or 750
        Values[prefix .. "EdgeMinScale"] = tonumber(category.edge_min_scale) or 0.50
    end

    -- Every local category starts ON: "if I can interact with it, show it unless
    -- I say otherwise" (user, 2026-09-11).
    for _, category in ipairs(local_categories) do
        Values["LocalShow" .. tostring(category.key)] = true
        Values["LocalIconScale" .. tostring(category.key)] = category_scale_default(category)
        -- v0.17.0: which of the category's icons, and which of that icon's colors
        -- (Classifier.CategoryList: `icon` / `color` defaults, `icons` / `colors` sets).
        Values["LocalIcon" .. tostring(category.key)] = tostring(category.icon or "default")
        Values["LocalIconColor" .. tostring(category.key)] = tostring(category.color or "white")
    end

    -- Immutable default snapshot. Settings pages can reset only their own keys
    -- without rebuilding or replacing the shared Values table.
    local Defaults = {}
    for key, value in pairs(Values) do Defaults[key] = value end

    local function clamp(value, minimum, maximum, fallback)
        local number = tonumber(value)
        if number == nil or number ~= number then return fallback end
        if number < minimum then return minimum end
        if number > maximum then return maximum end
        return number
    end

    -- v0.18.3: a value that is not a boolean at all -- a hand-edited ini, a key the
    -- loader could not parse -- goes back to the shipped default rather than to a
    -- hardcoded true/false that may no longer be the default. `Values.X ~= false`
    -- silently answered "true" for garbage, which is how several rows stopped
    -- resetting to what they actually ship as.
    local function boolean(value, fallback)
        if type(value) == "boolean" then return value end
        return fallback == true
    end

    local function parse_bool(value, fallback)
        value = tostring(value or ""):lower()
        if value == "true" or value == "1" or value == "yes" or value == "on" then return true end
        if value == "false" or value == "0" or value == "no" or value == "off" then return false end
        return fallback
    end

    local function normalize()
        Values.Enabled = boolean(Values.Enabled, Defaults.Enabled)
        Values.Size = math.floor(clamp(Values.Size, 160, 500, Defaults.Size) + 0.5)
        Values.OffsetX = math.floor(clamp(Values.OffsetX, 0, 2000, Defaults.OffsetX) + 0.5)
        Values.OffsetY = math.floor(clamp(Values.OffsetY, 0, 2000, Defaults.OffsetY) + 0.5)
        Values.ZoomMeters = clamp(Values.ZoomMeters, 25, 50000, Defaults.ZoomMeters)
        local function binding(value, fallback)
            value = tostring(value or ""):match("^%s*(.-)%s*$")
            if value == "" then return fallback end
            value = value:gsub("[\r\n]", "")
            if #value > 160 then value = value:sub(1, 160) end
            return value
        end
        Values.MenuKeybind = binding(Values.MenuKeybind, "LeftControl+Period")
        Values.ControllerMenuBind = binding(
            Values.ControllerMenuBind, "Gamepad_LeftThumbstick+Gamepad_FaceButton_Bottom")
        Values.ModifierSidesEquivalent = boolean(Values.ModifierSidesEquivalent, Defaults.ModifierSidesEquivalent)
        Values.TrackerIconSize = math.floor(clamp(Values.TrackerIconSize, 12, 128, Defaults.TrackerIconSize) + 0.5)
        Values.ShowTrackerEdgeIndicators = boolean(Values.ShowTrackerEdgeIndicators, Defaults.ShowTrackerEdgeIndicators)
        Values.TrackerEdgeMaxDistance = clamp(Values.TrackerEdgeMaxDistance, 10, 5000, Defaults.TrackerEdgeMaxDistance)
        Values.TrackerEdgeMinScale = clamp(Values.TrackerEdgeMinScale, 0.20, 1.0, Defaults.TrackerEdgeMinScale)
        Values.EdgeVisibility = math.floor(clamp(Values.EdgeVisibility, 0, 100, Defaults.EdgeVisibility) + 0.5)
        Values.ShowPOIs = boolean(Values.ShowPOIs, Defaults.ShowPOIs)
        Values.POIMaxIcons = math.floor(clamp(Values.POIMaxIcons, 16, 192, Defaults.POIMaxIcons) + 0.5)
        Values.ShowLocalInteractables = boolean(Values.ShowLocalInteractables, Defaults.ShowLocalInteractables)
        Values.LocalInteractableIconSize = math.floor(clamp(Values.LocalInteractableIconSize, 12, 48, Defaults.LocalInteractableIconSize) + 0.5)
        Values.LocalInteractableBudget = math.floor(clamp(Values.LocalInteractableBudget, 8, 64, Defaults.LocalInteractableBudget) + 0.5)
        Values.POISettingsCategory = math.floor(clamp(Values.POISettingsCategory, 1, math.max(1, #categories), Defaults.POISettingsCategory) + 0.5)
        Values.LocalSettingsCategory = math.floor(clamp(Values.LocalSettingsCategory, 1, math.max(1, #local_categories), Defaults.LocalSettingsCategory) + 0.5)
        for _, category in ipairs(local_categories) do
            local key = "LocalShow" .. tostring(category.key)
            Values[key] = boolean(Values[key], Defaults[key])
            local scale_key = "LocalIconScale" .. tostring(category.key)
            Values[scale_key] = clamp(Values[scale_key], 0.25, 2.0,
                category_scale_default(category))
            local icon_key = "LocalIcon" .. tostring(category.key)
            Values[icon_key] = one_of(Values[icon_key], category.icons, category.icon or "default")
            local color_key = "LocalIconColor" .. tostring(category.key)
            Values[color_key] = one_of(Values[color_key], category.colors, category.color or "white")
        end
        local frame = tostring(Values.MapFrame or Defaults.MapFrame):lower()
        if frame ~= "off" and frame ~= "line" and frame ~= "vector" and frame ~= "ornate" then
            frame = Defaults.MapFrame
        end
        Values.MapFrame = frame
        Values.MapFrameColor = one_of(Values.MapFrameColor,
            { "bronze", "white", "red", "blue", "green" }, Defaults.MapFrameColor)
        Values.CombatHide = boolean(Values.CombatHide, Defaults.CombatHide)
        Values.CombatOpacity = clamp(Values.CombatOpacity, 0.10, 1.0, Defaults.CombatOpacity)
        Values.CombatSize = clamp(Values.CombatSize, 0.50, 1.0, Defaults.CombatSize)
        Values.CombatTransition = clamp(Values.CombatTransition, 0.0, 2.0, Defaults.CombatTransition)
        Values.CombatRestoreDelay = clamp(Values.CombatRestoreDelay, 0.0, 15.0, Defaults.CombatRestoreDelay)
        for _, category in ipairs(categories) do
            local prefix = tostring(category.config_prefix or ("POI" .. tostring(category.key or "")))
            Values[prefix .. "Visible"] = boolean(Values[prefix .. "Visible"], Defaults[prefix .. "Visible"])
            local discovery_mode = tostring(category.discovery_mode or "only")
            if discovery_mode == "hidden" then
                Values[prefix .. "DiscoveredHidden"] = boolean(Values[prefix .. "DiscoveredHidden"], Defaults[prefix .. "DiscoveredHidden"])
            elseif discovery_mode == "only" then
                Values[prefix .. "DiscoveredOnly"] = boolean(Values[prefix .. "DiscoveredOnly"], Defaults[prefix .. "DiscoveredOnly"])
            end
            Values[prefix .. "IconSize"] = math.floor(clamp(
Values[prefix .. "IconSize"], 12, 128, Defaults[prefix .. "IconSize"]) + 0.5)
            Values[prefix .. "EdgeIndicators"] = boolean(Values[prefix .. "EdgeIndicators"], Defaults[prefix .. "EdgeIndicators"])
            Values[prefix .. "EdgeMaxDistance"] = clamp(
Values[prefix .. "EdgeMaxDistance"], 10, 5000, Defaults[prefix .. "EdgeMaxDistance"])
            Values[prefix .. "EdgeMinScale"] = clamp(
Values[prefix .. "EdgeMinScale"], 0.20, 1.0, Defaults[prefix .. "EdgeMinScale"])
        end
        Values.PauseGameWhileSettingsOpen = boolean(Values.PauseGameWhileSettingsOpen, Defaults.PauseGameWhileSettingsOpen)
        Values.Opacity = clamp(Values.Opacity, 0.20, 1.0, Defaults.Opacity)
        Values.CircleOpacityCurve = clamp(Values.CircleOpacityCurve, 1.0, 15.0, Defaults.CircleOpacityCurve)
        Values.LocalIconPlates = boolean(Values.LocalIconPlates, Defaults.LocalIconPlates)
        Values.LocalHeightMarkers = boolean(Values.LocalHeightMarkers, Defaults.LocalHeightMarkers)
        Values.LocalHeightThresholdMeters = clamp(Values.LocalHeightThresholdMeters, 1.0, 50.0, Defaults.LocalHeightThresholdMeters)
        Values.LocalHeightMarkerSize = math.floor(clamp(Values.LocalHeightMarkerSize, 25, 200, Defaults.LocalHeightMarkerSize) + 0.5)
        Values.LocalHeightFade = boolean(Values.LocalHeightFade, Defaults.LocalHeightFade)
        Values.LocalHeightFadeStart = math.floor(clamp(Values.LocalHeightFadeStart, 10, 100, Defaults.LocalHeightFadeStart) + 0.5)
        Values.LocalHeightFadeMin = math.floor(clamp(Values.LocalHeightFadeMin, 10, 100, Defaults.LocalHeightFadeMin) + 0.5)
        Values.LocalHeightFadeRange = math.floor(clamp(Values.LocalHeightFadeRange, 1, 100, Defaults.LocalHeightFadeRange) + 0.5)
        Values.FootstepTrail = math.floor(clamp(Values.FootstepTrail, 0, 48, Defaults.FootstepTrail) + 0.5)
        Values.FootstepTrailSize = math.floor(clamp(Values.FootstepTrailSize, 25, 200, Defaults.FootstepTrailSize) + 0.5)
        Values.MapLabels = math.floor(clamp(Values.MapLabels, 0, 3, Defaults.MapLabels) + 0.5)
        Values.EnemyRefreshHooks = boolean(Values.EnemyRefreshHooks, Defaults.EnemyRefreshHooks)
        Values.LocalDiscoveryTrace = boolean(Values.LocalDiscoveryTrace, Defaults.LocalDiscoveryTrace)
        Values.AdvancedSettings = boolean(Values.AdvancedSettings, Defaults.AdvancedSettings)
        Values.MapLabelInk = boolean(Values.MapLabelInk, Defaults.MapLabelInk)
        Values.MapLabelSize = math.floor(clamp(Values.MapLabelSize, 0, 28, Defaults.MapLabelSize) + 0.5)
        Values.MapLabelCardinals = math.floor(clamp(Values.MapLabelCardinals, 1, 4, Defaults.MapLabelCardinals) + 0.5)
        Values.MapLabelInset = clamp(Values.MapLabelInset, -40.0, 60.0, Defaults.MapLabelInset)
        Values.MapLabelFont = one_of(Values.MapLabelFont,
            { "trajan", "trajanbold", "trajansub", "crimson", "crimsonsemi", "crimsonbold",
              "crimsonitalic", "game" }, Defaults.MapLabelFont)
        Values.MapLabelColor = one_of(Values.MapLabelColor,
            { "white", "gold", "bronze", "red", "blue", "green", "grey", "black" }, Defaults.MapLabelColor)
        Values.MapLabelOutline = math.floor(clamp(Values.MapLabelOutline, 0, 3, Defaults.MapLabelOutline) + 0.5)
        Values.MapLabelShadow = boolean(Values.MapLabelShadow, Defaults.MapLabelShadow)
        Values.MapLabelPlate = boolean(Values.MapLabelPlate, Defaults.MapLabelPlate)
        Values.MapAreaSubLabel = boolean(Values.MapAreaSubLabel, Defaults.MapAreaSubLabel)
        Values.MapAreaBeaconRadiusMeters = clamp(Values.MapAreaBeaconRadiusMeters, 2.0, 200.0, Defaults.MapAreaBeaconRadiusMeters)
        Values.MaxResidentTiles = math.floor(clamp(Values.MaxResidentTiles, 2, 32, Defaults.MaxResidentTiles) + 0.5)
        Values.LODBias = clamp(Values.LODBias, 0, 5, Defaults.LODBias)
        Values.PanUpdatesPerSecond = math.floor(clamp(Values.PanUpdatesPerSecond, 5, 60, Defaults.PanUpdatesPerSecond) + 0.5)
        Values.ArrowUpdatesPerSecond = math.floor(clamp(Values.ArrowUpdatesPerSecond, 5, 60, Defaults.ArrowUpdatesPerSecond) + 0.5)
        local orientation = tostring(Values.MapOrientation or Defaults.MapOrientation):lower()
        if orientation ~= "north" and orientation ~= "camera" and orientation ~= "player" then
            orientation = Defaults.MapOrientation
        end
        Values.MapOrientation = orientation
        local shape = tostring(Values.MapShape or Defaults.MapShape):lower()
        if shape ~= "square" and shape ~= "circle" then shape = Defaults.MapShape end
        Values.MapShape = shape
        -- Hidden legacy compatibility key for rollback to v0.9.5. Player-heading
        -- cannot be represented by the old boolean, so rollback safely becomes North up.
        Values.RotateWithCamera = orientation == "camera"
        Values.ShowArrow = boolean(Values.ShowArrow, Defaults.ShowArrow)
        Values.TransparentNoMapBackground = boolean(Values.TransparentNoMapBackground, Defaults.TransparentNoMapBackground)
        -- v0.14.0: the two-way no-map background became a three-way one. The migration
        -- from an ini written before this version happens in load(); this only sanitises.
        local background = tostring(Values.NoMapBackground or Defaults.NoMapBackground):lower()
        if background ~= "transparent" and background ~= "cloud" then
            background = Defaults.NoMapBackground
        end
        Values.NoMapBackground = background
        -- Keep the legacy key consistent so a rollback to v0.13.x lands somewhere sensible.
        Values.TransparentNoMapBackground = background ~= "cloud"
        Values.DungeonViewEverywhere = boolean(Values.DungeonViewEverywhere, Defaults.DungeonViewEverywhere)
        Values.DungeonViewBrightness = clamp(Values.DungeonViewBrightness, 0.2, 2.0, Defaults.DungeonViewBrightness)
        Values.DungeonViewOpenWorldBrightness =
            clamp(Values.DungeonViewOpenWorldBrightness, 0.2, 2.0, Defaults.DungeonViewOpenWorldBrightness)
        Values.DungeonViewRate = math.floor(clamp(Values.DungeonViewRate, 1, 60, Defaults.DungeonViewRate))
        -- v0.15.0 CAPTURE tab. Enums are whitelisted, numbers clamped, booleans coerced.
        -- (The v0.14.5-v0.14.9 DungeonViewPreset key is gone; an old ini's value is ignored.)
        local sources = { [0] = true, [1] = true, [2] = true, [3] = true, [4] = true,
            [5] = true, [6] = true, [7] = true, [8] = true, [9] = true }
        local source = math.floor(tonumber(Values.DungeonCaptureSource) or Defaults.DungeonCaptureSource)
        Values.DungeonCaptureSource = sources[source] and source or Defaults.DungeonCaptureSource
        local formats = { [2] = true, [3] = true, [6] = true, [9] = true, [10] = true }
        local format = math.floor(tonumber(Values.DungeonCaptureFormat) or Defaults.DungeonCaptureFormat)
        Values.DungeonCaptureFormat = formats[format] and format or Defaults.DungeonCaptureFormat
        Values.DungeonCaptureTint = clamp(Values.DungeonCaptureTint, 0.02, 2.0, Defaults.DungeonCaptureTint)
        Values.DungeonCaptureUnlit = boolean(Values.DungeonCaptureUnlit, Defaults.DungeonCaptureUnlit)
        Values.DungeonCaptureLOD = clamp(Values.DungeonCaptureLOD, 0.25, 16, Defaults.DungeonCaptureLOD)
        Values.DungeonCapturePersist = boolean(Values.DungeonCapturePersist, Defaults.DungeonCapturePersist)
        Values.DungeonCapturePostProcess = boolean(Values.DungeonCapturePostProcess, Defaults.DungeonCapturePostProcess)
        local method = math.floor(tonumber(Values.DungeonCaptureExposureMethod) or 0)
        Values.DungeonCaptureExposureMethod = (method >= 0 and method <= 2) and method or 0
        Values.DungeonCaptureExposureBias = clamp(Values.DungeonCaptureExposureBias, -15, 15, Defaults.DungeonCaptureExposureBias)
        Values.DungeonCaptureExposureMin = clamp(Values.DungeonCaptureExposureMin, -10, 20, Defaults.DungeonCaptureExposureMin)
        Values.DungeonCaptureExposureMax = clamp(Values.DungeonCaptureExposureMax, -10, 20, Defaults.DungeonCaptureExposureMax)
        if Values.DungeonCaptureExposureMax < Values.DungeonCaptureExposureMin then
            Values.DungeonCaptureExposureMax = Values.DungeonCaptureExposureMin
        end
        Values.DungeonCaptureExposureSpeed = clamp(Values.DungeonCaptureExposureSpeed, 0.5, 1000, Defaults.DungeonCaptureExposureSpeed)
        Values.DungeonCapturePhysicalCamera = boolean(Values.DungeonCapturePhysicalCamera, Defaults.DungeonCapturePhysicalCamera)
        Values.DungeonCaptureBloom = boolean(Values.DungeonCaptureBloom, Defaults.DungeonCaptureBloom)
        Values.DungeonCaptureVignette = boolean(Values.DungeonCaptureVignette, Defaults.DungeonCaptureVignette)
        Values.DungeonCaptureRig = boolean(Values.DungeonCaptureRig, Defaults.DungeonCaptureRig)
        Values.DungeonCaptureRigSun = clamp(Values.DungeonCaptureRigSun, 0, 400, Defaults.DungeonCaptureRigSun)
        Values.DungeonCaptureRigSky = clamp(Values.DungeonCaptureRigSky, 0, 8, Defaults.DungeonCaptureRigSky)
        Values.DungeonCaptureRigSkyFactor = clamp(Values.DungeonCaptureRigSkyFactor, 0.1, 20, Defaults.DungeonCaptureRigSkyFactor)
        Values.DungeonCaptureRigFog = clamp(Values.DungeonCaptureRigFog, 0, 10, Defaults.DungeonCaptureRigFog)
        Values.DungeonViewPixels = math.floor(clamp(Values.DungeonViewPixels, 64, 1024, Defaults.DungeonViewPixels))
        Values.DungeonViewHeightMeters = clamp(Values.DungeonViewHeightMeters, 2, 200, Defaults.DungeonViewHeightMeters)
        Values.DungeonViewSliceMeters = clamp(Values.DungeonViewSliceMeters, 0.25, 20, Defaults.DungeonViewSliceMeters)
        Values.DungeonViewCeilingAuto = boolean(Values.DungeonViewCeilingAuto, Defaults.DungeonViewCeilingAuto)
        Values.DungeonViewCeilingMaxMeters = clamp(Values.DungeonViewCeilingMaxMeters, 3, 60, Defaults.DungeonViewCeilingMaxMeters)
        Values.DebugLog = boolean(Values.DebugLog, Defaults.DebugLog)
        Values.LogPerformance = boolean(Values.LogPerformance, Defaults.LogPerformance)
    end

    -- Set by main.lua once the profiler exists (config loads before it does).
    local perf_holder = { perf = nil }

    local function load()
        local perf = perf_holder.perf
        local token = perf ~= nil and perf.Begin() or nil
        local file = io.open(config_path, "r")
        if file == nil then
            normalize()
            return false
        end
        local saw_map_orientation = false
        local saw_no_map_background = false
        local saw_advanced = false
        for line in file:lines() do
            local key, value = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
            if key ~= nil and value ~= nil then
                if key == "MapOrientation" then saw_map_orientation = true end
                if key == "NoMapBackground" then saw_no_map_background = true end
                if key == "AdvancedSettings" then saw_advanced = true end
                if type(Values[key]) == "boolean" then
                    Values[key] = parse_bool(value, Values[key])
                elseif type(Values[key]) == "string" then
                    Values[key] = value
                elseif Values[key] ~= nil then
                    Values[key] = tonumber(value) or Values[key]
                end
            end
        end
        file:close()
        -- v0.9.5 migration: preserve the user's accepted camera-heading choice
        -- when the new three-state key does not yet exist.
        if not saw_map_orientation then
            Values.MapOrientation = Values.RotateWithCamera == true and "camera" or "north"
        end
        -- v0.16.8 migration: an ini written before the Advanced switch existed belongs
        -- to someone who has seen every tab; keep them visible rather than hide the
        -- CAPTURE tab on an update. A fresh install has no ini and starts hidden.
        if not saw_advanced then Values.AdvancedSettings = true end
        -- v0.14.0 migration: an ini from v0.13.x and earlier has only the boolean. Cloud
        -- was an explicit choice and is preserved as Cloud; Transparent was the shipped
        -- default, so it becomes the dungeon view -- the thing that default stood in for
        -- while there was nothing better to draw. One row changes it back.
        if not saw_no_map_background then
            Values.NoMapBackground = Values.TransparentNoMapBackground == false
                and "cloud" or "dungeon"
        end
        normalize()
        if perf ~= nil then perf.End("io.config.load", token) end
        return true
    end

    local function save()
        local perf = perf_holder.perf
        local token = perf ~= nil and perf.Begin() or nil
        local file, open_error = io.open(config_path, "w")
        if file == nil then
            log("Could not save settings: " .. tostring(open_error))
            return false
        end
        file:write("# MortalShell2Minimap settings; managed by MortalShell2ModUI.\n")
        file:write("Enabled=" .. tostring(Values.Enabled) .. "\n")
        file:write("Size=" .. tostring(Values.Size) .. "\n")
        file:write("OffsetX=" .. tostring(Values.OffsetX) .. "\n")
        file:write("OffsetY=" .. tostring(Values.OffsetY) .. "\n")
        file:write("ZoomMeters=" .. tostring(Values.ZoomMeters) .. "\n")
        file:write("MenuKeybind=" .. tostring(Values.MenuKeybind) .. "\n")
        file:write("ControllerMenuBind=" .. tostring(Values.ControllerMenuBind) .. "\n")
        file:write("ModifierSidesEquivalent=" .. tostring(Values.ModifierSidesEquivalent) .. "\n")
        file:write("TrackerIconSize=" .. tostring(Values.TrackerIconSize) .. "\n")
        file:write("ShowTrackerEdgeIndicators=" .. tostring(Values.ShowTrackerEdgeIndicators) .. "\n")
        file:write("TrackerEdgeMaxDistance=" .. tostring(Values.TrackerEdgeMaxDistance) .. "\n")
        file:write("TrackerEdgeMinScale=" .. string.format("%.2f", Values.TrackerEdgeMinScale) .. "\n")
        file:write("EdgeVisibility=" .. tostring(Values.EdgeVisibility) .. "\n")
        file:write("ShowPOIs=" .. tostring(Values.ShowPOIs) .. "\n")
        file:write("POIMaxIcons=" .. tostring(Values.POIMaxIcons) .. "\n")
        file:write("ShowLocalInteractables=" .. tostring(Values.ShowLocalInteractables) .. "\n")
        file:write("LocalInteractableIconSize=" .. tostring(Values.LocalInteractableIconSize) .. "\n")
        file:write("LocalInteractableBudget=" .. tostring(Values.LocalInteractableBudget) .. "\n")
        file:write("LocalSettingsCategory=" .. tostring(Values.LocalSettingsCategory) .. "\n")
        for _, category in ipairs(local_categories) do
            local key = "LocalShow" .. tostring(category.key)
            file:write(key .. "=" .. tostring(Values[key]) .. "\n")
            local scale_key = "LocalIconScale" .. tostring(category.key)
            file:write(scale_key .. "=" .. string.format("%.2f", Values[scale_key]) .. "\n")
            local icon_key = "LocalIcon" .. tostring(category.key)
            file:write(icon_key .. "=" .. tostring(Values[icon_key]) .. "\n")
            local color_key = "LocalIconColor" .. tostring(category.key)
            file:write(color_key .. "=" .. tostring(Values[color_key]) .. "\n")
        end
        file:write("POISettingsCategory=" .. tostring(Values.POISettingsCategory) .. "\n")
        for _, category in ipairs(categories) do
            local prefix = tostring(category.config_prefix or ("POI" .. tostring(category.key or "")))
            file:write(prefix .. "Visible=" .. tostring(Values[prefix .. "Visible"]) .. "\n")
            local discovery_mode = tostring(category.discovery_mode or "only")
            if discovery_mode == "hidden" then
                file:write(prefix .. "DiscoveredHidden="
                    .. tostring(Values[prefix .. "DiscoveredHidden"]) .. "\n")
            elseif discovery_mode == "only" then
                file:write(prefix .. "DiscoveredOnly="
                    .. tostring(Values[prefix .. "DiscoveredOnly"]) .. "\n")
            end
            file:write(prefix .. "IconSize=" .. tostring(Values[prefix .. "IconSize"]) .. "\n")
            file:write(prefix .. "EdgeIndicators=" .. tostring(Values[prefix .. "EdgeIndicators"]) .. "\n")
            file:write(prefix .. "EdgeMaxDistance=" .. tostring(Values[prefix .. "EdgeMaxDistance"]) .. "\n")
            file:write(prefix .. "EdgeMinScale=" .. string.format(
                "%.2f", Values[prefix .. "EdgeMinScale"]) .. "\n")
        end
        file:write("PauseGameWhileSettingsOpen=" .. tostring(Values.PauseGameWhileSettingsOpen) .. "\n")
        file:write("Opacity=" .. string.format("%.2f", Values.Opacity) .. "\n")
        file:write("CircleOpacityCurve=" .. string.format(
            "%.2f", Values.CircleOpacityCurve) .. "\n")
        file:write("LocalIconPlates=" .. tostring(Values.LocalIconPlates) .. "\n")
        file:write("LocalHeightMarkers=" .. tostring(Values.LocalHeightMarkers) .. "\n")
        file:write("LocalHeightThresholdMeters=" .. string.format(
            "%.1f", Values.LocalHeightThresholdMeters) .. "\n")
        file:write("LocalHeightMarkerSize=" .. tostring(Values.LocalHeightMarkerSize) .. "\n")
        file:write("LocalHeightFade=" .. tostring(Values.LocalHeightFade) .. "\n")
        file:write("LocalHeightFadeStart=" .. tostring(Values.LocalHeightFadeStart) .. "\n")
        file:write("LocalHeightFadeMin=" .. tostring(Values.LocalHeightFadeMin) .. "\n")
        file:write("LocalHeightFadeRange=" .. tostring(Values.LocalHeightFadeRange) .. "\n")
        file:write("FootstepTrail=" .. tostring(Values.FootstepTrail) .. "\n")
        file:write("FootstepTrailSize=" .. tostring(Values.FootstepTrailSize) .. "\n")
        file:write("MapLabels=" .. tostring(Values.MapLabels) .. "\n")
        file:write("EnemyRefreshHooks=" .. tostring(Values.EnemyRefreshHooks) .. "\n")
        file:write("LocalDiscoveryTrace=" .. tostring(Values.LocalDiscoveryTrace) .. "\n")
        file:write("AdvancedSettings=" .. tostring(Values.AdvancedSettings) .. "\n")
        file:write("MapLabelInk=" .. tostring(Values.MapLabelInk) .. "\n")
        file:write("MapLabelSize=" .. tostring(Values.MapLabelSize) .. "\n")
        file:write("MapLabelCardinals=" .. tostring(Values.MapLabelCardinals) .. "\n")
        file:write("MapLabelInset=" .. string.format("%.1f", Values.MapLabelInset) .. "\n")
        file:write("MapLabelFont=" .. tostring(Values.MapLabelFont) .. "\n")
        file:write("MapLabelColor=" .. tostring(Values.MapLabelColor) .. "\n")
        file:write("MapLabelOutline=" .. tostring(Values.MapLabelOutline) .. "\n")
        file:write("MapLabelShadow=" .. tostring(Values.MapLabelShadow) .. "\n")
        file:write("MapLabelPlate=" .. tostring(Values.MapLabelPlate) .. "\n")
        file:write("MapAreaSubLabel=" .. tostring(Values.MapAreaSubLabel) .. "\n")
        file:write("MapAreaBeaconRadiusMeters="
            .. string.format("%.1f", Values.MapAreaBeaconRadiusMeters) .. "\n")
        file:write("MaxResidentTiles=" .. tostring(Values.MaxResidentTiles) .. "\n")
        file:write("LODBias=" .. tostring(Values.LODBias) .. "\n")
        file:write("PanUpdatesPerSecond=" .. tostring(Values.PanUpdatesPerSecond) .. "\n")
        file:write("ArrowUpdatesPerSecond=" .. tostring(Values.ArrowUpdatesPerSecond) .. "\n")
        file:write("MapOrientation=" .. tostring(Values.MapOrientation) .. "\n")
        file:write("MapShape=" .. tostring(Values.MapShape) .. "\n")
        file:write("MapFrame=" .. tostring(Values.MapFrame) .. "\n")
        file:write("MapFrameColor=" .. tostring(Values.MapFrameColor) .. "\n")
        file:write("CombatHide=" .. tostring(Values.CombatHide) .. "\n")
        file:write("CombatOpacity=" .. string.format("%.2f", Values.CombatOpacity) .. "\n")
        file:write("CombatSize=" .. string.format("%.2f", Values.CombatSize) .. "\n")
        file:write("CombatTransition=" .. string.format("%.2f", Values.CombatTransition) .. "\n")
        file:write("CombatRestoreDelay=" .. string.format("%.1f", Values.CombatRestoreDelay) .. "\n")
        file:write("RotateWithCamera=" .. tostring(Values.MapOrientation == "camera") .. "\n")
        file:write("ShowArrow=" .. tostring(Values.ShowArrow) .. "\n")
        file:write("TransparentNoMapBackground="
            .. tostring(Values.TransparentNoMapBackground) .. "\n")
        file:write("NoMapBackground=" .. tostring(Values.NoMapBackground) .. "\n")
        file:write("DungeonViewEverywhere=" .. tostring(Values.DungeonViewEverywhere) .. "\n")
        file:write("DungeonViewBrightness="
            .. string.format("%.2f", Values.DungeonViewBrightness) .. "\n")
        file:write("DungeonViewOpenWorldBrightness="
            .. string.format("%.2f", Values.DungeonViewOpenWorldBrightness) .. "\n")
        file:write("DungeonViewRate=" .. tostring(Values.DungeonViewRate) .. "\n")
        file:write("DungeonCaptureSource=" .. tostring(Values.DungeonCaptureSource) .. "\n")
        file:write("DungeonCaptureFormat=" .. tostring(Values.DungeonCaptureFormat) .. "\n")
        file:write("DungeonCaptureTint=" .. string.format("%.3f", Values.DungeonCaptureTint) .. "\n")
        file:write("DungeonCaptureUnlit=" .. tostring(Values.DungeonCaptureUnlit) .. "\n")
        file:write("DungeonCaptureLOD=" .. tostring(Values.DungeonCaptureLOD) .. "\n")
        file:write("DungeonCapturePersist=" .. tostring(Values.DungeonCapturePersist) .. "\n")
        file:write("DungeonCapturePostProcess=" .. tostring(Values.DungeonCapturePostProcess) .. "\n")
        file:write("DungeonCaptureExposureMethod=" .. tostring(Values.DungeonCaptureExposureMethod) .. "\n")
        file:write("DungeonCaptureExposureBias=" .. tostring(Values.DungeonCaptureExposureBias) .. "\n")
        file:write("DungeonCaptureExposureMin=" .. tostring(Values.DungeonCaptureExposureMin) .. "\n")
        file:write("DungeonCaptureExposureMax=" .. tostring(Values.DungeonCaptureExposureMax) .. "\n")
        file:write("DungeonCaptureExposureSpeed=" .. tostring(Values.DungeonCaptureExposureSpeed) .. "\n")
        file:write("DungeonCapturePhysicalCamera=" .. tostring(Values.DungeonCapturePhysicalCamera) .. "\n")
        file:write("DungeonCaptureBloom=" .. tostring(Values.DungeonCaptureBloom) .. "\n")
        file:write("DungeonCaptureVignette=" .. tostring(Values.DungeonCaptureVignette) .. "\n")
        file:write("DungeonCaptureRig=" .. tostring(Values.DungeonCaptureRig) .. "\n")
        file:write("DungeonCaptureRigSun=" .. tostring(Values.DungeonCaptureRigSun) .. "\n")
        file:write("DungeonCaptureRigSky=" .. tostring(Values.DungeonCaptureRigSky) .. "\n")
        file:write("DungeonCaptureRigSkyFactor=" .. tostring(Values.DungeonCaptureRigSkyFactor) .. "\n")
        file:write("DungeonCaptureRigFog=" .. tostring(Values.DungeonCaptureRigFog) .. "\n")
        file:write("DungeonViewPixels=" .. tostring(Values.DungeonViewPixels) .. "\n")
        file:write("DungeonViewHeightMeters="
            .. tostring(Values.DungeonViewHeightMeters) .. "\n")
        file:write("DungeonViewSliceMeters="
            .. tostring(Values.DungeonViewSliceMeters) .. "\n")
        file:write("DungeonViewCeilingAuto=" .. tostring(Values.DungeonViewCeilingAuto) .. "\n")
        file:write("DungeonViewCeilingMaxMeters=" .. tostring(Values.DungeonViewCeilingMaxMeters) .. "\n")
        file:write("DebugLog=" .. tostring(Values.DebugLog) .. "\n")
        file:write("LogPerformance=" .. tostring(Values.LogPerformance) .. "\n")
        file:close()
        if perf ~= nil then perf.End("io.config.save", token) end
        return true
    end

    local runtime = {
        Values = Values,
        Defaults = Defaults,
        Normalize = normalize,
        Load = load,
        Save = save,
        Default = function(key) return Defaults[tostring(key or "")] end,
        SetPerf = function(perf) perf_holder.perf = type(perf) == "table" and perf or nil end,
        ResetKey = function(key)
            key = tostring(key or "")
            if Defaults[key] == nil then return false end
            Values[key] = Defaults[key]
            return true
        end,
    }
    load()
    return runtime
end

return Factory
