-- Map/FogLayer.lua -- fog of war for the minimap. v0.20.4.
--
-- WHAT THIS DRAWS
--   Nothing. It owns a render target and keeps a REVEAL MASK in it: white where the
--   player may see the map, black where the fog should cover it. Two other things,
--   both already in the widget tree, do the actual drawing:
--
--     * the map widget is masked down to that target (NativeWidget binds it as
--       GlobalAlphaMask during Build), so the map is simply absent where it is fogged;
--     * the cloud plate at ZOrder 1, which already exists for the "no map" background,
--       sits behind the map and shows through wherever the map is masked away.
--
--   So fog is not a layer painted over the top. The map is cut away and the plate
--   behind it is what you see. That matters for one reason above all: every operation
--   needed to build a reveal mask is ADDITIVE, and additive is the only canvas blend
--   mode that was proven to work.
--
-- WHY NOT PAINT FOG OVER THE MAP
--   A fog overlay needs per-pixel alpha of (1 - reveal), which means inverting a mask.
--   The canvas blend modes available through K2_DrawTexture are Opaque, Masked,
--   Translucent, Additive and Modulate. None of them subtract, none of them invert, and
--   the game ships no inverted fragment. Every arrangement of an overlay runs into that
--   wall. Building the reveal mask instead needs no inversion at all: the fragments are
--   already white-where-revealed and the peek circle is already white-in-the-middle, so
--   the union of them IS the mask, drawn additively, which is the one thing measured to
--   work (probe v1.5.0, proven by bounding box and not by a pixel count).
--
-- WHY THE ON/OFF SWITCH REBUILDS AND THE RADIUS DOES NOT
--   SpartaMapWidget reads GlobalAlphaMask while it builds its tile brushes and never
--   re-reads it. Probes v1.11 through v1.13 set RegionMask, RevealAmount and
--   GlobalAlphaMask on the live widget, verified every one of them by property readback,
--   and not one changed a pixel. Binding therefore has to happen inside Build.
--
--   But a UTextureRenderTarget2D is a live object. Once the widget holds a reference to
--   ours, redrawing the target's CONTENTS changes what the widget samples, with no
--   property write and no rebuild. That is the whole reason this design is affordable:
--   the expensive step happens once, when fog is switched on.
--
-- WHAT v0.19.0 GOT WRONG, MEASURED
--   Update() read discovery BEFORE testing whether anything had changed, so every tick
--   paid FindAllOf("SpartaItemManagerComponent") plus eleven StaticFindObject calls plus
--   eleven GetItemStacksByClass calls -- and then resolved every texture again from
--   scratch inside redraw(). The profiler was unambiguous: tick.pose went to 29.53 ms
--   average across 178 of 178 ticks, and the mod's share of the frame went from 0.2% to
--   108.6%. That is the whole FPS collapse, and the crash sat inside the same stage.
--
--   The three rules that came out of it, and that this file now keeps:
--     1. No engine call happens before the change test. Movement and radius are plain
--        arithmetic on numbers we already hold; they decide whether to go further.
--     2. Discovery runs on its own slow clock, not the tick's. Map pieces are picked up
--        a handful of times in a playthrough; polling that at 18 Hz is absurd.
--     3. A texture is resolved once and kept. load_texture falls through to LoadAsset,
--        which is a disk-backed call, and v0.19.0 could reach it thirteen times a tick.
--
-- COST
--   Measured, not estimated. Eight K2_DrawTexture calls inside one
--   Begin/Draw/EndDrawCanvasToRenderTarget cycle cost 0.05 ms of game-thread time
--   against a 16.67 ms frame (probe v1.6.0, timed with no readback and no logging
--   inside the loop, because v1.5.0's timings were contaminated by exactly that).
--   A full redraw here is one clear plus at most thirteen draws, and is now capped at
--   REDRAW_MIN_SECONDS apart.
--
-- WHAT IS STILL UNPROVEN, AND MUST BE TREATED AS SUCH
--   That binding a render target as GlobalAlphaMask at BUILD time masks the map at all.
--   Everything above is measured; this one step is reasoned. It is reasoned from a real
--   observation -- NativeWidget already calls SetGlobalAlphaMask(global_mask) during
--   Build and the minimap is visibly masked -- but "the mod already does this and
--   something masks the map" is not the same as "our target will mask it".
--
--   So: Fog ships OFF, every failure here degrades to no fog rather than no minimap, and
--   nothing in this module is allowed to fail the build. If the mask does not take, the
--   user sees an unmasked minimap and a line in the log, which is the correct outcome
--   for a feature whose central mechanism has not been seen working yet.

local Factory = {}

function Factory.New(ctx)
    local Config = ctx.Config
    local log = ctx.Log or function() end
    local debug_log = ctx.DebugLog or function() end
    local Object = assert(ctx.Object, "Map.FogLayer requires Core.Object")
    local valid = Object.Valid
    -- Same shape as every other module's fallback: Begin returns nil, End ignores it.
    local perf = type(ctx.Perf) == "table" and ctx.Perf
        or { Begin = function() return nil end, End = function() end }
    local clock = type(ctx.Clock) == "function" and ctx.Clock or os.clock

    local TEX_ROOT = "/Game/Sparta/UI/World/Map/Textures/"
    local ITEM_ROOT = "/Game/Sparta/Items/Map/"

    local ASSET = {
        -- The eleven collectable regions.
        fragments = {
            "City_1", "City_2", "City_3", "City_4", "City_5", "City_6",
            "Forest_1", "Forest_2", "Forest_3", "Forest_4", "Forest_5",
        },
        -- The tutorial area walking up to the hub. ALWAYS revealed: it is not an item,
        -- it has no entry under /Game/Sparta/Items/Map/, and a new save shows it from
        -- the first frame. Unioned unconditionally.
        default_fragment = "T_UI_MapFragment_Default",
        -- A white circle on black, 1024x1024. The peek hole, already in the game and
        -- already loaded by NativeWidget for its own use.
        peek = "T_UI_MapGlobalMask",
    }

    local RENDER_LIB = "/Script/Engine.Default__KismetRenderingLibrary"

    -- v0.20.4. 2048, and 512 was indefensible.
    --
    -- 512 was chosen against the FRAGMENTS -- the largest is 512, the other ten are 256 --
    -- which is the right way to size a mask you are going to look at whole. The minimap
    -- never looks at it whole. At her settings (size 500, range 750) the visible span is
    -- 90.8 m of a 3155 m world, so the minimap samples 512 * 0.0288 = FOURTEEN POINT SEVEN
    -- TEXELS across the entire circle. One mask texel covers 34 screen pixels.
    --
    -- At that magnification bilinear filtering turns the mask into a few enormous soft
    -- gradients, and any sub-texel movement at all -- a float wobble in the player's
    -- position, a fraction of a degree of camera rotation -- slides those gradients across
    -- a third of the minimap. That is what "the masked windows are sweeping over me and
    -- I'm not even moving" looks like from the inside.
    --
    -- 2048 gives 59 texels across the view instead of 15. It cannot add detail the source
    -- fragments do not have, and it should not: fog edges belong soft. What it buys is
    -- that the softness stops moving.
    local TARGET_PIXELS = 2048

    -- Icons reveal at this multiple of the fog radius, so there is ONE radius to set and
    -- the "half make something out through the fog before you reach it" gap holds at
    -- every value. User decision 2026-09-16: tied to the fog radius, not its own row.
    local ICON_RADIUS_SCALE = 1.2

    ------------------------------------------------------------------
    -- Cadence. Every one of these exists because v0.19.0 had none of them.
    ------------------------------------------------------------------

    -- How often the held map pieces are re-read. Picking one up is a handful of events
    -- in a playthrough, and two seconds late to notice is imperceptible; eighteen times
    -- a second cost 29 ms a tick.
    local DISCOVERY_POLL_SECONDS = 2.0
    -- A hard ceiling on redraws, whatever else is true. Ten a second is already far more
    -- than a fog edge needs, and it bounds the worst case no matter how fast the player
    -- moves. Discovery and radius changes bypass it: those are single events and have to
    -- land on the frame they happen.
    local REDRAW_MIN_SECONDS = 0.1

    -- WARMING THE TEXTURE CACHE OFF THE HITCH. v0.23.4.
    --
    -- A cold redraw resolves up to thirteen fragment textures, and resolve_texture is
    -- StaticFindObject -> LoadAsset -> StaticFindObject -> LoadAsset -> StaticFindObject:
    -- disk-backed and synchronous on the game thread. Measured on her machine, all of it
    -- inside one frame: fog.redraw 272 ms for a single call.
    --
    -- Eight milliseconds is the budget per pose step. When the textures are already
    -- resident -- which is every redraw after the first -- the whole set is walked in
    -- well under it and nothing is deferred. When they are not, the frame pays 8 ms
    -- instead of 272 and the redraw waits for the next step.
    local TEXTURE_WARM_BUDGET_MS = 8.0

    -- THE SESSION TRAIL. v0.23.5. Her specification, 2026-09-17, in her own words:
    --
    --   "The fog trail should have a quick ramp up from 0% to 15%, and then a gradual ramp
    --   from 15% to 100% fog visible. I might have those flipped around but the idea is
    --   you'll have a short path of crystal clear map behind you, so you forget the finer
    --   details after a short time, and then forget where you've been after awhile. The
    --   path shouldn't disappear instantly if you step out in revealed areas, it still
    --   fades what was behind you with every step you take."
    --
    -- THE AGE OF A TRAIL MARK IS MEASURED IN METRES WALKED, NOT SECONDS. That is the line
    -- "it still fades what was behind you with every step you take", and it is the part
    -- that makes the feature feel like memory rather than like a timer: standing still to
    -- read the map neither erases the trail nor preserves it, and the behaviour does not
    -- change with frame rate or with how fast the player happens to move.
    --
    -- TWO PHASES, because one linear ramp would read as a torch beam with a soft edge --
    -- the eye finds the corner. The first phase is short and takes the mark from fully
    -- clear to 85% clear: the fine detail goes while the shape of the route stays. The
    -- second is long and takes it the rest of the way: forgetting the route itself.
    -- HER CURVE, IN HER WORDS. v0.23.28.
    --
    -- "I want the first 25 meters to go from 100% visibility to 70% visibility quickly,
    -- then from 25 meters until the end of the tail it gradually goes down to 0%
    -- visibility. If for some reason the trail is shorter than 40 meters then you just
    -- will skip that first part and go from 100% to 0% visibility within that very short
    -- trail under 40, but if over 40 you use my logic."
    --
    -- Named in VISIBILITY rather than in fog, because that is how she describes it, and
    -- the old name -- fog at crisp -- inverted the number every time anyone read it.
    local TRAIL_CRISP_METRES = 25.0
    local TRAIL_REVEAL_AT_CRISP = 0.70
    -- Below this the two-phase shape has no room: a 25 m first phase inside a 30 m trail
    -- leaves 5 m for the whole remaining fade, which is a cliff rather than a fade.
    local TRAIL_SHORT_TRAIL_METRES = 40.0

    -- A path, not a swathe. The width is its OWN setting in metres (FogTrailWidthMeters),
    -- not a fraction of the reveal radius -- her decision, 2026-09-17, and she is right.
    -- A trail is somewhere you walked, so its width is a real-world width; the reveal
    -- radius is how far out you must zoom before fog appears at all. Tying them together
    -- looked fine at a 50 m reveal (a 17.5 m path) and became nonsense at 200 m, where it
    -- would have been a 70 m stamp -- wider than the entire minimap view, so the "trail"
    -- would have been a clear blob with no direction in it.
    --
    -- Spacing stays a fraction of the width, so the circles overlap into a continuous
    -- line rather than a row of dots.
    local TRAIL_SPACING_FRACTION = 0.6

    -- The cost ceiling, and the reason the trail length is capped at all. Each mark is one
    -- K2_DrawTexture in the same additive pass as the peek, and the peek is ONE. This
    -- number is what a redraw can afford; the trail length setting is clamped to whatever
    -- it buys at the current radius, rather than the other way round.
    local TRAIL_MAX_MARKS = 48
    -- Movement worth redrawing for, as a fraction of the reveal radius, floored so a
    -- small radius does not redraw constantly. At 50 m that is 6 m -- one mask texel.
    -- Below one texel the redraw cannot change a single pixel, so it is pure waste.
    local MOVE_FRACTION_OF_RADIUS = 0.12
    local MOVE_MIN_METERS = 3.0

    -- World span, in Unreal units, from Map/Scale.lua. One mask texel is 6.16 m at 512.
    local MapScale = ctx.MapScale
    -- The SHARED runtime state, not this file's private `state` table a few lines below.
    -- Only one field is read from it -- area_map_available -- and it is read rather than
    -- pushed so there is no window where the fog is drawing and the dungeon signal has
    -- not arrived yet. Optional: the regression builds a fog layer without it.
    local shared = type(ctx.State) == "table" and ctx.State or nil
    -- v0.23.51. The baked discovery shapes. Absent, or present and refused, means
    -- every query answers nil and the peek keeps the always-on behaviour it had
    -- before this existed. Optional by construction, like the dungeon view.
    local RevealedGround = type(ctx.RevealedGround) == "table" and ctx.RevealedGround or nil

    -- v0.19.5: ALPHA 1, and this is why "Show the mask" showed nothing.
    --
    -- v0.19.4 cleared to alpha ZERO. A render target cleared transparent and then drawn
    -- into with additive colour is still transparent, so the keeper Image -- brush bound,
    -- visible, sized to the whole minimap, sitting above the map -- drew absolutely
    -- nothing. The mask was there the whole time and could not be seen.
    --
    -- Map/DungeonView.lua has always created its target with A = 1.0. It is the one
    -- render target in this mod that has been visible on screen for months.
    local CLEAR_BLACK = { R = 0.0, G = 0.0, B = 0.0, A = 1.0 }
    -- THE MASK'S REVEAL LIVES IN ITS ALPHA. v0.23.11.
    --
    -- The first composite came back as a crisp bright circle of map on a field of pure
    -- BLACK instead of fog, and the reason is one number. The mask target was cleared to
    -- CLEAR_BLACK, whose alpha is 1, and every shape is stamped with a tint whose alpha is
    -- 1 -- so the mask's alpha was 1 EVERYWHERE and only its colour carried the reveal.
    -- The composite's translucent pass weighs the source by its alpha, so it replaced the
    -- fog with clear-times-mask over the whole view: the map inside the circle, black
    -- outside it.
    --
    -- Cleared transparent instead, the alpha accumulates exactly where the additive stamps
    -- land, which is the reveal -- and the same texture then carries the reveal twice, as
    -- colour for the modulate pass and as alpha for the translucent one. No third target
    -- and no inverse mask, which this engine has refused twice.
    local CLEAR_TRANSPARENT = { R = 0.0, G = 0.0, B = 0.0, A = 0.0 }
    -- Black and fully opaque. As a TINT this is "take the alpha, drop the colour": the
    -- draw multiplies the source by it, so an additive pass with this tint moves a mask
    -- into a target's alpha channel and leaves the colour alone. The one way found to
    -- write alpha on a canvas that offers no channel mask.
    local ALPHA_ONLY = { R = 0.0, G = 0.0, B = 0.0, A = 1.0 }
    local WHITE = { R = 1.0, G = 1.0, B = 1.0, A = 1.0 }
    local UV_ORIGIN = { X = 0.0, Y = 0.0 }
    local UV_FULL = { X = 1.0, Y = 1.0 }
    -- SUBTRACT_TINT is gone with the pass that used it (v0.23.4). Kept in the record
    -- rather than the code: a tint of { -1, -1, -1, 0 } with additive blending was the
    -- route to an inverted mask, and the engine clamps it to zero. Measured, not
    -- reasoned. Do not try it again.
    local BLEND_ADDITIVE = 3
    -- 0, 1 and 2 are last-draw-wins (probe v1.5.0). For a single blit that is exactly
    -- what is wanted: the target becomes the source, cropped.
    local BLEND_OPAQUE = 0
    -- 2 = Translucent: src*srcAlpha + dst*(1-srcAlpha). It respects the SOURCE TEXTURE's
    -- alpha, which is what lets a shape be stamped rather than a rectangle.
    local BLEND_TRANSLUCENT = 2
    -- MODULATE (4) IS NOT HERE, and that is a measurement rather than an omission. It
    -- multiplies the ALPHA as well as the colour, so modulating the clear map over the
    -- mask multiplied the reveal by the painting's own alpha -- which is zero -- and the
    -- minimap came back fogged edge to edge with no hole at all. Recorded here rather
    -- than kept as a constant nothing calls: unused code that looks alive is the
    -- expensive kind, and this file has paid that bill once already.
    local BLACK_OPAQUE = { R = 0.0, G = 0.0, B = 0.0, A = 1.0 }

    -- v0.22.2. THE VIEW-SPACE TARGETS.
    --
    -- Everything above this line lives in WORLD uv: the mask spans the whole 3155 m
    -- world, because fog you can zoom past is not fog. The overlay material, however,
    -- draws on a plain UImage that samples its textures across the whole quad, and
    -- MapUVScaleOffset does not change that -- measured 2026-09-17, the value lands in
    -- the material to five decimals and the overlay still shows the entire world:
    --
    --   Fog UV write=true wanted=0.02878,... readback=0.02878,... visibleMeters=90.8
    --
    -- That parameter belongs to the game's tile widget, which feeds each tile its own uv
    -- region. Outside that widget it means nothing, whatever it accepts.
    --
    -- So the crop happens here instead, where this file already owns a canvas and has
    -- been drawing with explicit uv coordinates since v0.19.1. K2_DrawTexture takes
    -- CoordinatePosition and CoordinateSize; handing it the view window blits the slice
    -- under the player into a target the material can sample edge to edge. The material
    -- is then left doing only the one thing it has been proven to do, which is mask one
    -- texture by another.
    --
    -- 1024 for a 500 px minimap: two device pixels per minimap pixel, so the crop has
    -- headroom at the largest size without paying for a second 2048 target.
    local VIEW_PIXELS = 1024

    local state = {
        target = nil,
        -- v0.20.0. The reveal mask says where the map may be SEEN. The fog overlay needs
        -- the opposite -- where the fog must be PAINTED -- and no canvas blend mode
        -- inverts, so it is built as its own target: cleared white, with every revealed
        -- shape SUBTRACTED out of it. Subtraction is additive blending with a negative
        -- tint; FLinearColor is four floats and nothing stops them being below zero.
        -- If that turns out not to work the target stays white, the whole minimap fogs
        -- over, and the failure names itself rather than looking like a subtle bug.
        inverse_target = nil,
        -- The session trail: { x, y, at } where `at` is the cumulative metres walked when
        -- the mark was laid. Never saved, never carried across a world -- see Forget().
        trail = {},
        walked_meters = 0.0,
        trail_last_x = nil,
        trail_last_y = nil,
        -- How many marks the LAST redraw actually stamped. Reported by Summary(): the
        -- difference between "no marks were laid" and "marks were laid and none of them
        -- reached the canvas" is the whole diagnosis, and a screenshot cannot tell them
        -- apart.
        trail_marks_drawn = 0,
        -- THE PEEK STATE MACHINE. v0.23.51, her four rules.
        --
        -- peek_active starts TRUE so a build with no baked grids -- and a session before
        -- the first position is known -- behaves exactly as every build before this one.
        -- fog_walk_mark is the metres-walked reading from the last moment she was
        -- standing in fog; nil means "not since the world loaded".
        peek_active = true,
        fog_walk_mark = nil,
        revealed_here = nil,
        reveal_test_x = nil,
        reveal_test_y = nil,
        -- Marker answers, keyed by a cell of the world. Markers do not move and there can
        -- be two hundred of them, so the per-frame cost must not scale with how many.
        reveal_memo = {},
        reveal_memo_count = 0,
        library = nil,
        held = nil,
        held_signature = nil,
        last_center_x = nil,
        last_center_y = nil,
        last_radius_meters = nil,
        next_discovery_at = nil,
        next_redraw_at = nil,
        redraws = 0,
        discovery_polls = 0,
        failures = 0,
        drawing = false,
        disabled_reason = nil,
        announced_bind = false,
        announced_draw = false,
    }

    -- name -> texture, or false for "asked and it is not there". The negative entry is
    -- the important half: without it a missing asset reaches LoadAsset on every redraw.
    -- Cleared whenever the held set changes, because a freshly collected region's
    -- texture may not have been resident the last time we looked.
    local texture_cache = {}

    local fog = {}

    -- A DUNGEON GETS NO FOG AT ALL. v0.23.39.
    --
    -- Her screenshot of Castigator's Keep shows the grey wash and the peek circle drawn
    -- over the world tiles, and her instruction was "trail logic shouldn't be active in a
    -- dungeon, as it doesn't have fog logic atm". Asked how far to take that, she chose
    -- the whole layer: in a dungeon the minimap looks exactly as it did before fog
    -- existed.
    --
    -- The signal is state.area_map_available == false, which is the same one
    -- DungeonView.Wanted() reads -- "this area has no world map", which is what a dungeon
    -- IS here. Deliberately not DungeonView.Active(), because that is false when the
    -- capture merely failed to build, and a failed capture falling back to world tiles
    -- would then get fog again. She is in a dungeon either way.
    function fog.Suppressed()
        return shared ~= nil and shared.area_map_available == false
    end

    -- enabled() is the single gate: MaskForBuild returns nil (which means "build the
    -- minimap exactly as it was before fog existed"), Update bails before any engine
    -- call, trail_enabled() goes false so trail_sample clears the marks on the first tick
    -- inside, and MarkerVisibility returns 1.0 so no icon is faded by fog that is not
    -- being drawn.
    local function enabled()
        return Config.FogEnabled == true and not fog.Suppressed()
    end

    -- v0.19.3 support switch. "hide" fills the mask solid black -- reveal nothing -- which
    -- makes the answer to "does binding this mask do anything at all" a thing you can see
    -- rather than a thing to reason about. "show" is handled in NativeWidget, which makes
    -- the keeper Image visible so the mask itself is drawn over the minimap.
    -- v0.23.50. This carried its OWN list of the values it knew about -- show, hide and
    -- material -- and answered "off" for everything else. That made it a FOURTH place a
    -- new diagnostic had to be registered, after the Schema's values, the Schema's labels
    -- and Config/Runtime.lua's one_of, and it is why the readback probe never fired even
    -- after the row could finally reach it: the setting was live (her log says
    -- "Setting FogDiagnostic=readback via=change"), Summary asked this function, and this
    -- function said "off".
    --
    -- one_of is the ONE list that decides which values exist. This reads what it produced.
    local function diagnostic()
        return tostring(Config.FogDiagnostic or "off"):lower()
    end

    -- The three modes that REPLACE the fog layers outright. Under those the trail numbers
    -- in the full summary describe a layer that is not on screen, so the summary says what
    -- is running instead. Every other value is a probe that leaves the fog drawing
    -- normally and keeps the full summary, which is the behaviour every fog measurement
    -- since v0.20 was taken under -- naming the three here rather than inverting the test
    -- is what keeps that true.
    local LAYER_OVERRIDE = { show = true, hide = true, material = true }

    ------------------------------------------------------------------
    -- Assets. Resolve by LOADING, never by finding -- then keep the result.
    --
    -- v1.3.0 of the probe reported two real assets as missing because it used
    -- StaticFindObject, which only finds what is ALREADY RESIDENT. The fragments are not
    -- resident until something loads them, and the world map screen is the only thing
    -- that normally does. "Does not resolve" is not "does not exist".
    ------------------------------------------------------------------

    local function resolve_texture(name)
        local path = TEX_ROOT .. name .. "." .. name
        local ok, object = pcall(StaticFindObject, path)
        if ok and object ~= nil and valid(object) then return object end
        if type(LoadAsset) ~= "function" then return nil end
        -- Both spellings, because the package path and the object path are not always
        -- interchangeable and a failed load here is indistinguishable from a bad name.
        local bare = path:match("^(.-)%.[^%.]+$") or path
        for _, spelling in ipairs({ path, bare }) do
            if not pcall(LoadAsset, spelling) then return nil end
            local found_ok, found = pcall(StaticFindObject, path)
            if found_ok and found ~= nil and valid(found) then return found end
        end
        return nil
    end

    -- v0.19.5. Set by NativeWidget at build time. A texture this module resolves through
    -- LoadAsset has NO owner in the engine's object graph -- the same hole the render
    -- target fell through -- so the collector is free to take it back, and the next draw
    -- goes through a dead pointer. Her 15:55:35 crash has "Asset loaded" sitting between
    -- "Tick stage=build" and the silence, which is this module going back to LoadAsset
    -- for a texture it thought it already had.
    --
    -- Overlay/LocalPool.lua solved this in v0.10.14 with a collapsed keeper Image per
    -- texture, and has been stable since. This uses the same pattern rather than a new one.
    local pin_texture = nil

    -- CRUMBS INSIDE THE VIEW REFRESH. v0.23.29.
    --
    -- The pose crumbs named the FUNCTION -- her log ends at "Pose crumb step=fog-refresh"
    -- with no -done, three crashes running. These name the CALL inside it.
    --
    -- The tree guard added in v0.23.27 did not stop it, and the log says why it should not
    -- have: the last build finished 62 seconds before the crash with no teardown between,
    -- and no settings window was open. So this is not a stale widget tree; something in
    -- here dereferences null while everything it is built on is still alive.
    --
    -- print(), not debug_log(): an access violation kills the process without unwinding, so
    -- only what has already reached the log survives. Gated on the same switch as every
    -- other crumb -- one boolean per call, and off is shipped (invariant 0l).
    local function view_crumb(name)
        -- v0.23.43: TraceHotPaths, not LocalDiscoveryTrace. MEASURED over her 502 s
        -- session: this family alone printed 257,049 lines, 512 per second, and the
        -- crash hunt these were written for is done. Invariant 0l -- a diagnostic
        -- is held to the same performance rules as the thing it diagnoses -- and a
        -- per-frame print on the pose path fails that now it has stopped earning
        -- its keep. The scheduler and Tick stage crumbs stay on the old flag
        -- because they are 1% of the volume and they are what is currently
        -- instrumenting the OPEN death-and-reload crash.
        if Config.TraceHotPaths == true then
            print("[MortalShell2Minimap] View crumb step=" .. tostring(name) .. "\n")
        end
    end

    local function load_texture(name)
        local cached = texture_cache[name]
        if cached == false then return nil end
        -- CRUMBED. v0.23.34. This line's own comment has said for versions that a cached
        -- handle "is still a pointer into a world the game may have torn down" -- and the
        -- crash that has been killing her turned out to be exactly that, one function
        -- along: valid() on a collected wrapper, which is fatal rather than false.
        view_crumb("tex:" .. tostring(name))
        -- valid() on every hit, not just on the miss: a cached handle is still a pointer
        -- into a world the game may have torn down, and drawing through a dead one is a
        -- native fault that pcall does not catch.
        if cached ~= nil and valid(cached) then return cached end
        local resolved = resolve_texture(name)
        if resolved ~= nil and pin_texture ~= nil then
            -- Pinned before it is cached, so nothing is ever cached unpinned.
            pcall(pin_texture, resolved, name)
        end
        texture_cache[name] = resolved or false
        return resolved
    end

    -- Every texture the next redraw will want. Built only while the cache is cold; once
    -- state.textures_warm is set this function is not reached at all.
    local function needed_texture_names(held)
        local names = { ASSET.default_fragment }
        for _, short in ipairs(held or {}) do
            names[#names + 1] = "T_UI_MapFragment_" .. short
        end
        names[#names + 1] = ASSET.peek
        return names
    end

    -- True when the redraw can go ahead without paying for a disk load. See
    -- TEXTURE_WARM_BUDGET_MS above for why this exists.
    local function warm_textures(held)
        if state.textures_warm then return true end
        local started = clock()
        for _, name in ipairs(needed_texture_names(held)) do
            if texture_cache[name] == nil then
                load_texture(name)
                state.texture_warm_loads = (state.texture_warm_loads or 0) + 1
                if (clock() - started) * 1000.0 >= TEXTURE_WARM_BUDGET_MS then
                    state.texture_warm_steps = (state.texture_warm_steps or 0) + 1
                    return false
                end
            end
        end
        state.textures_warm = true
        return true
    end

    local function forget_missing_textures()
        for name, entry in pairs(texture_cache) do
            if entry == false then texture_cache[name] = nil end
        end
    end

    ------------------------------------------------------------------
    -- Discovery. Read from the player's own item manager, any time, map closed.
    -- Expensive: one FindAllOf measured at about 10 ms. Never call this from a tick
    -- without a clock in front of it.
    ------------------------------------------------------------------

    -- v0.19.2. Measured in game at 31 ms A POLL, which at one poll every two seconds is a
    -- visible hitch rather than a collapse, but a hitch the player feels. Almost all of it
    -- is the two reflection walks: FindAllOf over every component in the level, and eleven
    -- StaticFindObject lookups for item classes that never move.
    --
    -- Both are now resolved once and kept. The item classes are UClass objects and are
    -- effectively permanent; the manager is a component on the player and is not, so it
    -- is revalidated on every use and re-found when it goes stale. Both are dropped by
    -- Forget() on a world change, which is invariant 0.
    local item_class_cache = nil
    local manager_cache = nil

    local function item_classes()
        if item_class_cache ~= nil then return item_class_cache end
        local resolved = {}
        for _, short in ipairs(ASSET.fragments) do
            local id = "ID_MapPiece_" .. short
            local ok, item_class = pcall(StaticFindObject, ITEM_ROOT .. id .. "." .. id .. "_C")
            if ok and item_class ~= nil and valid(item_class) then
                resolved[#resolved + 1] = { short = short, class = item_class }
            end
        end
        -- Only cache a complete answer. A partial resolve means the items were not
        -- resident yet, and caching that would freeze the player out of regions they
        -- later collect.
        if #resolved == #ASSET.fragments then item_class_cache = resolved end
        return resolved
    end

    local function find_item_manager()
        local ok, list = pcall(FindAllOf, "SpartaItemManagerComponent")
        if not ok or list == nil then return nil end
        local fallback = nil
        for _, candidate in ipairs(list) do
            if valid(candidate) then
                local name_ok, full = pcall(function() return candidate:GetFullName() end)
                local name = name_ok and tostring(full) or ""
                -- A class default object is a live pointer with dead innards. Reading one
                -- took the game down once already (probe v1.0.0, access violation at
                -- 0x10): valid() says the pointer is good, not that anything inside it
                -- was ever initialised.
                if name:find("Default__", 1, true) == nil then
                    if fallback == nil then fallback = candidate end
                    if name:find("PlayerCharacter", 1, true) ~= nil then return candidate end
                end
            end
        end
        return fallback
    end

    local function item_manager()
        -- valid() on the cached handle every time, never on trust: it is a component on
        -- the player and the player can be destroyed under us.
        if manager_cache ~= nil and valid(manager_cache) then return manager_cache end
        manager_cache = find_item_manager()
        return manager_cache
    end

    -- Returns a list of region short names and a signature string. The signature is what
    -- decides whether the mask needs rebuilding, so it must change when and only when
    -- the held set changes.
    local function held_regions()
        local manager = item_manager()
        if manager == nil then return nil, nil end
        local classes = item_classes()
        if #classes == 0 then return nil, nil end
        local held, parts = {}, {}
        for _, entry in ipairs(classes) do
            -- Attempted, never gated on. `type(manager.GetItemStacksByClass)` is
            -- FALSE even when the function exists -- UE4SS reaches UFunctions through
            -- __index and they do not report as Lua functions until called. Probe
            -- v1.1.0 asked nothing at all because of that gate.
            local call_ok, count = pcall(function()
                return manager:GetItemStacksByClass(entry.class)
            end)
            local n = call_ok and tonumber(count) or nil
            if n ~= nil and n > 0 then
                held[#held + 1] = entry.short
                parts[#parts + 1] = entry.short
            end
        end
        return held, table.concat(parts, ",")
    end

    -- Reads discovery at most once every DISCOVERY_POLL_SECONDS. Returns whether the
    -- held set changed. `force` is for the two moments that cannot wait: the first read
    -- after fog is switched on, and a rebuild.
    local function poll_discovery(now, force)
        if not force and state.next_discovery_at ~= nil and now < state.next_discovery_at then
            return false
        end
        state.next_discovery_at = now + DISCOVERY_POLL_SECONDS
        local token = perf.Begin()
        local held, signature = held_regions()
        perf.End("fog.discovery", token)
        state.discovery_polls = state.discovery_polls + 1
        if signature == nil then return false end
        local changed = signature ~= state.held_signature
        state.held = held
        state.held_signature = signature
        if changed then forget_missing_textures() end
        return changed
    end

    ------------------------------------------------------------------
    -- The mask
    ------------------------------------------------------------------

    local function rendering_library()
        if valid(state.library) then return state.library end
        local ok, lib = pcall(StaticFindObject, RENDER_LIB)
        if ok and lib ~= nil and valid(lib) then state.library = lib end
        return valid(state.library) and state.library or nil
    end

    local function ensure_target(context)
        if valid(state.target) then return state.target end
        local library = rendering_library()
        if library == nil or not valid(context) then return nil end
        local ok, made = pcall(function()
            return library:CreateRenderTarget2D(context, TARGET_PIXELS, TARGET_PIXELS, 3,
                CLEAR_BLACK, false, false)
        end)
        if ok and made ~= nil and valid(made) then
            state.target = made
            debug_log(string.format("Fog mask target created %dx%d", TARGET_PIXELS, TARGET_PIXELS))
        end
        return valid(state.target) and state.target or nil
    end

    -- v0.20.0. The companion target holding 1 - reveal. Cleared WHITE rather than black,
    -- because everything starts fogged and the discovered shapes are taken out of it.
    --
    -- THE SIXTH HANDLE. v0.23.37.
    --
    -- Her v0.23.36 log ends at "View crumb step=rd-inverse" with no -done, and the only
    -- thing between those two crumbs is this function. Its first line is valid() on a
    -- handle that was created once, held on `state`, and NEVER PINNED -- the world
    -- target gets a keeper in NativeWidget, the view targets get keepers at build, every
    -- texture is pinned as it is resolved, and this one was made by the same
    -- CreateRenderTarget2D and then simply kept. The v0.23.4 note below says "the handle
    -- still gets made, once" and moves on. It was made once and owned by nobody, and
    -- eleven seconds of not touching it was enough for the collector to take it.
    --
    -- The shape matches every bundle she has sent: 67 world redraws fine, the 68th dead
    -- after the longest gap in the session; "the moment I moved"; a settings visit in
    -- the gap. A render target is not a cooked asset and nothing about it "cannot go
    -- away". Invariant 0x, which claimed five handles when there were six.
    --
    -- So it is pinned the moment it exists, through the same keeper every texture uses,
    -- and it is not made at all when there is no pinner to own it -- an unowned target is
    -- the bug, not a fallback.
    local function ensure_inverse_target(context)
        if valid(state.inverse_target) then return state.inverse_target end
        if pin_texture == nil then return nil end
        local library = rendering_library()
        if library == nil or not valid(context) then return nil end
        local ok, made = pcall(function()
            return library:CreateRenderTarget2D(context, TARGET_PIXELS, TARGET_PIXELS, 3,
                WHITE, false, false)
        end)
        if ok and made ~= nil and valid(made) then
            -- Pinned before it is kept, so it is never held unowned for even one frame.
            -- The pinner returns false on a failed keeper rather than raising, so both
            -- the call and its answer have to be true.
            local pin_ok, pinned = pcall(pin_texture, made, "inverse-target")
            if pin_ok and pinned == true then
                state.inverse_target = made
                debug_log(string.format("Fog inverse target created %dx%d and pinned",
                    TARGET_PIXELS, TARGET_PIXELS))
            end
        end
        return valid(state.inverse_target) and state.inverse_target or nil
    end

    local function ensure_view_target(context, key, clear_color)
        if valid(state[key]) then return state[key] end
        local library = rendering_library()
        if library == nil or not valid(context) then return nil end
        local ok, made = pcall(function()
            return library:CreateRenderTarget2D(context, VIEW_PIXELS, VIEW_PIXELS, 3,
                clear_color, false, false)
        end)
        if ok and made ~= nil and valid(made) then
            state[key] = made
            debug_log(string.format("Fog view target %s created %dx%d",
                tostring(key), VIEW_PIXELS, VIEW_PIXELS))
        end
        return valid(state[key]) and state[key] or nil
    end

    -- v0.19.1. Two reasons this exists, and the first one is a bug v0.19.0 shipped.
    --
    --   1. BeginDrawCanvasToRenderTarget does not clear. Additive draws onto an uncleared
    --      target only ever accumulate, so the peek circle would have painted a permanent
    --      trail behind the player. The agreed design is explicit that it must not:
    --      "the peek is a moving porthole, not a paint brush. It does not permanently
    --      reveal." Permanent reveal means owning explored state across saves, which is a
    --      different feature. So every redraw starts from black.
    --   2. White is the fail-open state. A mask of all white reveals everything, which is
    --      exactly the minimap as it was before fog existed.
    local function clear_target(context, target, color)
        local library = rendering_library()
        if library == nil or target == nil then return false end
        return pcall(function()
            library:ClearRenderTarget2D(context, target, color)
        end)
    end

    -- The peek circle's size in mask pixels. The mask spans the whole world, so a radius
    -- in metres converts through the world span and nothing else -- deliberately NOT
    -- through the current zoom. Fog you can zoom past is not fog.
    local function peek_pixels(radius_meters)
        local span = (MapScale and MapScale.WORLD_SPAN_METERS) or 3155.52
        if span <= 0 then return 0 end
        return (radius_meters / span) * TARGET_PIXELS
    end

    -- TRAIL: the geometry, the sampler and the fade. v0.23.5.

    local function trail_enabled()
        return enabled() and Config.FogTrail ~= false
    end

    local function trail_radius_meters()
        -- ZERO MEANS "MATCH THE PEEK". v0.23.23, and it is what she asked for once she
        -- had finally seen the trail working: "I would like to ask that the trail start
        -- off as the same width as the peek hole."
        --
        -- The row stays its own setting rather than becoming a fraction of the reveal --
        -- that was her earlier decision and the reasoning still holds, a trail is
        -- somewhere you walked so its width is a real-world width. What changes is the
        -- DEFAULT: zero follows the peek, and any explicit width still overrides it.
        --
        -- Matching means the path leaves the circle at the circle's own width instead of
        -- stepping in, so the two read as one shape rather than a disc with a thinner tail
        -- stuck to it.
        --
        -- Half, because the setting is the path's WIDTH and the stamp takes a radius --
        -- and the peek's radius is already a radius, so it is used as it is.
        local width = tonumber(Config.FogTrailWidthMeters) or 0
        if width <= 0 then
            return math.max(2.0, tonumber(Config.FogRevealMeters) or 20)
        end
        return math.max(2.0, width / 2.0)
    end

    -- How far back the trail is remembered, in metres walked. Clamped to what
    -- TRAIL_MAX_MARKS can actually draw at the current spacing, so the cost ceiling
    -- governs the setting rather than the setting governing the cost.
    local function trail_forget_meters()
        local wanted = tonumber(Config.FogTrailMeters) or 500
        local spacing = trail_radius_meters() * TRAIL_SPACING_FRACTION
        if spacing <= 0 then return 0 end
        return math.min(wanted, spacing * TRAIL_MAX_MARKS)
    end

    -- Her curve. `walked` is metres walked since the mark was laid, and the return is how
    -- REVEALED the mark still is: 1.0 crystal clear, 0.0 fully fogged again.
    --
    -- Phase one is short and shallow (1.0 -> 0.85), phase two long and deep (0.85 -> 0.0).
    -- Smoothstep on the second so the trail does not end on a visible edge.
    local function trail_reveal(walked, forget_meters)
        if walked <= 0 then return 1.0 end
        if forget_meters <= 0 or walked >= forget_meters then return 0.0 end

        -- SHORT TRAIL: one straight ramp, her rule. Nothing stays crisp for long when
        -- there is not much trail to be crisp in.
        if forget_meters < TRAIL_SHORT_TRAIL_METRES then
            return 1.0 - (walked / forget_meters)
        end

        -- PHASE ONE, short and steep: 100% down to 70% over the first 25 m. This is the
        -- "you forget the finer details after a short time" half, and it is an ABSOLUTE
        -- distance -- it does not stretch when the memory setting grows, which is what
        -- made a 500 m trail read crystal clear end to end.
        if walked <= TRAIL_CRISP_METRES then
            return 1.0 - (1.0 - TRAIL_REVEAL_AT_CRISP) * (walked / TRAIL_CRISP_METRES)
        end

        -- PHASE TWO: 70% down to nothing, straight, across whatever trail is left. LINEAR
        -- rather than the smoothstep this used to be. Smoothstep is nearly flat near the
        -- player, so the near half of a long trail had no gradient at all -- her report was
        -- "it looks crystal clear all the way through", and the curve's own shape was half
        -- the reason.
        local span = forget_meters - TRAIL_CRISP_METRES
        if span <= 0 then return 0.0 end
        return TRAIL_REVEAL_AT_CRISP * (1.0 - ((walked - TRAIL_CRISP_METRES) / span))
    end

    ------------------------------------------------------------------
    -- REVEALED GROUND, AND THE PEEK STATE MACHINE. v0.23.51.
    --
    -- Her four rules, in her words:
    --   1. "If I'm in a completely revealed map tile there is no need for peek to run."
    --   2. "If I enter the fog then peek activates."
    --   3. "If I exit the fog into a clearing that is revealed, peek and its trail still
    --       run like normal until the entire trail is out of the fog, once that happens
    --       then it terminates itself and stops running."
    --   4. "If I exit the fog, then enter it before my trail fully exits the fog, then the
    --       trail never stops and continues like normal."
    --
    -- Rules 3 and 4 need no search. The trail only ever holds the last FogTrailMeters of
    -- walking, so "the entire trail is out of the fog" is exactly "she has walked a full
    -- trail length since the last time she stood in fog" -- one subtraction against a
    -- watermark, not a scan of the marks. Re-entering fog rewrites the watermark, which
    -- IS rule 4: the countdown restarts and the trail never stops.
    --
    -- Rule 1 is the only one that needs to know where the fog is, and it asks about an
    -- AREA rather than a point: one grid cell is 12.3 m, so a point test alone would call
    -- the last cell before a fog edge clear and drop the peek with half the circle still
    -- in the dark.
    ------------------------------------------------------------------

    -- 512 cells across the world is 6.2 m, finer than the 12.3 m grids underneath, so the
    -- memo can never merge two patches the grids would answer differently.
    local REVEAL_MEMO_CELLS = 512
    -- Every entry is one boolean for one patch of ground she has had a marker on. Cleared
    -- whenever the held set changes and with the world; the ceiling is only there so a
    -- twelve-hour session cannot grow it without bound.
    local REVEAL_MEMO_CEILING = 8192
    -- Standing still cannot change the answer, and neither can a step across half a cell.
    local REVEAL_RETEST_METERS = 2.0

    local function forget_reveal_memo()
        if state.reveal_memo_count == 0 then return end
        state.reveal_memo = {}
        state.reveal_memo_count = 0
    end

    -- nil means "no opinion" -- no grids, or no position. Callers must test for `true`,
    -- never for truthiness, or a build without the baked data reads as fog everywhere.
    local function revealed_ground_available()
        return RevealedGround ~= nil and RevealedGround.Available() == true
    end

    -- For MARKERS: memoised, because this is called once per marker per frame and a
    -- marker does not move.
    local function revealed_marker(map_x, map_y)
        if not revealed_ground_available() then return nil end
        if map_x == nil or map_y == nil or map_x ~= map_x or map_y ~= map_y then return nil end
        local cell = math.floor(map_y * REVEAL_MEMO_CELLS) * REVEAL_MEMO_CELLS
            + math.floor(map_x * REVEAL_MEMO_CELLS)
        local cached = state.reveal_memo[cell]
        if cached ~= nil then return cached end
        local answer = RevealedGround.RevealedAtNormalized(map_x, map_y, state.held)
        if answer == nil then return nil end
        if state.reveal_memo_count >= REVEAL_MEMO_CEILING then forget_reveal_memo() end
        state.reveal_memo[cell] = answer
        state.reveal_memo_count = state.reveal_memo_count + 1
        return answer
    end

    -- For the PLAYER: not memoised. It runs once per update rather than once per marker,
    -- and memoising a position that changes every step would only fill the table.
    local function update_peek_state(center_x, center_y, discovery_changed)
        if not revealed_ground_available() then
            state.revealed_here = nil
            return
        end
        if center_x == nil or center_y == nil then return end
        local span = (MapScale and MapScale.WORLD_SPAN_METERS) or 3155.52
        local last_x, last_y = state.reveal_test_x, state.reveal_test_y
        if not discovery_changed and last_x ~= nil and state.revealed_here ~= nil then
            local dx, dy = (center_x - last_x) * span, (center_y - last_y) * span
            if (dx * dx + dy * dy) < (REVEAL_RETEST_METERS * REVEAL_RETEST_METERS) then
                return
            end
        end
        state.reveal_test_x, state.reveal_test_y = center_x, center_y

        local radius = math.max(1.0, tonumber(Config.FogRevealMeters) or 20)
        local revealed = RevealedGround.RevealedAroundNormalized(center_x, center_y,
            radius, state.held)
        -- v0.23.52. The ground answer is worth a line when it CHANGES, and only then:
        -- crossing into fog, crossing out of it, or a map piece revealing the ground she
        -- is already standing on -- which is the case that had no evidence at all.
        if revealed ~= state.revealed_here then
            debug_log(string.format("Ground under her: %s -> %s (peek=%s walked=%.0fm)",
                state.revealed_here == nil and "unknown"
                    or (state.revealed_here == true and "revealed" or "fog"),
                revealed == nil and "unknown"
                    or (revealed == true and "revealed" or "fog"),
                state.peek_active ~= false and "on" or "off", state.walked_meters))
        end
        state.revealed_here = revealed
        if revealed == nil then return end

        if revealed ~= true then
            -- Rule 2, and the watermark rules 3 and 4 both read.
            state.fog_walk_mark = state.walked_meters
            if state.peek_active ~= true then
                state.peek_active = true
                debug_log("Peek on: standing in fog")
            end
            return
        end
        -- Standing on revealed ground. Rule 3: the peek and the trail keep running until
        -- a whole trail length has been walked since the last moment in fog.
        if state.peek_active ~= true then return end
        local forget = trail_forget_meters()
        if state.fog_walk_mark ~= nil
            and (state.walked_meters - state.fog_walk_mark) < forget then
            return
        end
        state.peek_active = false
        debug_log(string.format(
            "Peek off: revealed ground and the trail is clear of the fog (walked=%.0fm mark=%s forget=%.0fm)",
            state.walked_meters,
            state.fog_walk_mark ~= nil and string.format("%.0fm", state.fog_walk_mark) or "never",
            forget))
    end

    local function peek_active()
        return state.peek_active ~= false
    end


    -- WHAT AN ICON CAN SEE. v0.23.39, and it is her spec almost word for word:
    -- "If an icon is inside my peek circle then it's fully visible, if it's in the trail
    -- then it borrows the opacity of the trail circle its in, if its outside of my peek
    -- circle and not in my trail then it needs a fade logic, like fully invisible 5m
    -- outside of my circle, starts fading the moment it hits the edge of my peek circle."
    --
    -- Returns 0..1 for a WORLD position, because world x/y is what every caller already
    -- has (LocalPool's target.x/y, ObjectivePool's record.world_x/y). The conversion to
    -- the normalised space the trail is stored in happens here, once, so no caller can
    -- get the space wrong -- and the sign flip in WorldPanNormalized cancels in a
    -- difference, which is the whole reason this is safe to do by subtraction.
    --
    -- 1.0 whenever fog is not being drawn -- off, suppressed in a dungeon, or disabled by
    -- a failure -- so nothing is ever faded by fog that is not on screen.
    --
    -- The player centre is state.trail_last_x/y, which trail_sample refreshes every
    -- Update from the same number the peek is stamped at. Reading it rather than taking
    -- the player as an argument is what keeps the fade and the circle on screen agreeing:
    -- one source, so they cannot drift.
    --
    -- COST. This runs per marker per overlay refresh against a trail that holds about 80
    -- marks at her 1000 m memory, so the scan is bounded three ways and the common case
    -- never reaches it at all:
    --   1. Inside the peek: returns immediately, no scan.
    --   2. Beyond peek + tail with an empty trail: returns 0, no scan.
    --   3. The scan runs NEWEST FIRST, and trail_reveal falls monotonically with age, so
    --      a mark whose own reveal cannot beat the best found so far means no older mark
    --      can either -- break, not continue. A box test rejects distant marks before the
    --      squared distance, and nothing here takes a square root.
    function fog.MarkerVisibility(world_x, world_y)
        if not enabled() or state.disabled_reason ~= nil then return 1.0 end
        world_x, world_y = tonumber(world_x), tonumber(world_y)
        local px, py = state.trail_last_x, state.trail_last_y
        if world_x == nil or world_y == nil or px == nil or py == nil then return 1.0 end
        if MapScale == nil or type(MapScale.WorldPanNormalized) ~= "function" then
            return 1.0
        end
        local map_x, map_y = MapScale.WorldPanNormalized(world_x, world_y)
        if map_x == nil or map_y == nil then return 1.0 end

        -- GROUND SHE HAS ALREADY UNCOVERED SHOWS ITS MARKERS. v0.23.51, and it is the
        -- report that started the whole revealed-ground line of work: "the icon reveal in
        -- areas I have the map uncovered. I don't see icons like I did before we
        -- implemented fog, and they are slowly fading in as I approach them."
        --
        -- The fade below is about the FOG: it exists so a marker under fog is hidden and
        -- half-visible at the edge of what she can see. A marker standing on map she has
        -- collected is not under fog at all, so none of it applies and it is simply
        -- visible, exactly as it was before the fog existed.
        --
        -- Memoised: this runs once per marker per frame and there can be two hundred.
        if revealed_marker(map_x, map_y) == true then return 1.0 end

        local span = (MapScale and MapScale.WORLD_SPAN_METERS) or 3155.52
        if span <= 0 then return 1.0 end
        local peek = math.max(0.0, tonumber(Config.FogRevealMeters) or 20)
        local dx, dy = (map_x - px) * span, (map_y - py) * span
        local distance_sq = dx * dx + dy * dy
        if distance_sq <= peek * peek then return 1.0 end

        -- The ramp. Zero tail is a hard cut at the peek edge, which is what the setting's
        -- minimum is for.
        local tail = math.max(0.0, tonumber(Config.FogMarkerFadeMeters) or 5)
        local best = 0.0
        if tail > 0 then
            local outer = peek + tail
            if distance_sq < outer * outer then
                best = 1.0 - ((math.sqrt(distance_sq) - peek) / tail)
                if best >= 1.0 then return 1.0 end
                if best < 0.0 then best = 0.0 end
            end
        end

        if not trail_enabled() then return best end
        local marks = state.trail
        local count = #marks
        if count == 0 then return best end
        local forget = trail_forget_meters()
        if forget <= 0 then return best end
        local trail_r = trail_radius_meters()
        if trail_r <= 0 then return best end

        -- Nowhere near anywhere she has been: four compares and done. This is the case
        -- the loop below is worst at, and it is also the common one.
        local min_x, max_x = state.trail_min_x, state.trail_max_x
        if min_x == nil then return best end
        local pad = trail_r / span
        if map_x < min_x - pad or map_x > max_x + pad
            or map_y < state.trail_min_y - pad or map_y > state.trail_max_y + pad then
            return best
        end

        local walked = state.walked_meters
        for index = count, 1, -1 do
            local mark = marks[index]
            -- The BOX FIRST, at the mark's largest possible radius, because reveal is at
            -- most 1. Four subtractions and four compares reject a distant mark without
            -- ever evaluating the fade curve, which is the expensive half.
            local mdx, mdy = (map_x - mark.x) * span, (map_y - mark.y) * span
            if mdx < trail_r and mdx > -trail_r and mdy < trail_r and mdy > -trail_r then
                local reveal = trail_reveal(walked - mark.at, forget)
                -- The monotonic break: reveal only falls with age, and a mark can
                -- contribute at most its own reveal, so nothing older can beat what we
                -- already have. Still correct after the box test above -- the marks it
                -- skipped had HIGHER reveal and did not contain the point, so they could
                -- not have raised `best` either.
                if reveal <= best then break end
                -- Her cone: a mark at r% visibility is r% of its full width, so the
                -- circle a marker has to be inside is the DRAWN one, not the full one.
                local radius = trail_r * reveal
                if (mdx * mdx + mdy * mdy) <= radius * radius then
                    best = reveal
                    if best >= 1.0 then return 1.0 end
                end
            end
        end
        return best
    end

    -- THE TRAIL'S BOUNDING BOX, in normalised map units. MEASURED, and it is the reason
    -- this exists: without it a marker out in the fog cost 17 microseconds, because
    -- `best` stays at zero so the monotonic break below never fires and all 167 marks of
    -- a 1000 m trail get scanned. Sixty markers a refresh made that a full millisecond of
    -- game thread, which is not a price a visual nicety gets to charge (invariant 0l).
    --
    -- Recomputed only when the trail CHANGES -- once every six metres walked -- so the
    -- amortised cost is nothing and the common "nowhere near where she has been" answer
    -- becomes four compares.
    local function refresh_trail_bounds()
        local marks = state.trail
        local count = #marks
        if count == 0 then
            state.trail_min_x, state.trail_max_x = nil, nil
            state.trail_min_y, state.trail_max_y = nil, nil
            return
        end
        local min_x, max_x = marks[1].x, marks[1].x
        local min_y, max_y = marks[1].y, marks[1].y
        for index = 2, count do
            local mark = marks[index]
            if mark.x < min_x then min_x = mark.x elseif mark.x > max_x then max_x = mark.x end
            if mark.y < min_y then min_y = mark.y elseif mark.y > max_y then max_y = mark.y end
        end
        state.trail_min_x, state.trail_max_x = min_x, max_x
        state.trail_min_y, state.trail_max_y = min_y, max_y
    end

    -- Called once per Update with the player's NORMALISED world position -- the same
    -- number the peek uses, so a faked debug position moves the trail with everything
    -- else rather than leaving it behind.
    local function trail_sample(center_x, center_y)
        -- peek_active is part of the gate rather than a separate branch because rule 3
        -- switches the peek and the trail off together -- "it terminates itself and stops
        -- running" is one event, not two. The clear below is what makes it one.
        if not trail_enabled() or not peek_active() then
            if #state.trail > 0 then state.trail = {} end
            state.trail_last_x, state.trail_last_y = center_x, center_y
            return
        end
        if center_x == nil or center_y == nil then return end
        local span = (MapScale and MapScale.WORLD_SPAN_METERS) or 3155.52
        local last_x, last_y = state.trail_last_x, state.trail_last_y
        state.trail_last_x, state.trail_last_y = center_x, center_y
        if last_x == nil or last_y == nil then return end

        local dx, dy = (center_x - last_x) * span, (center_y - last_y) * span
        local step = math.sqrt(dx * dx + dy * dy)
        if step <= 0 then return end

        -- A load or a fast travel is not a walk. Without this the trail would draw a
        -- straight clear line across the world between where she was and where she is --
        -- the same lie Overlay/TrailPool.lua breaks its breadcrumbs for.
        if step > trail_forget_meters() then
            state.trail = {}
            return
        end

        state.walked_meters = state.walked_meters + step
        local spacing = trail_radius_meters() * TRAIL_SPACING_FRACTION
        local marks = state.trail
        local newest = marks[#marks]
        if newest ~= nil and (state.walked_meters - newest.at) < spacing then return end
        marks[#marks + 1] = { x = center_x, y = center_y, at = state.walked_meters }

        -- Drop from the FRONT: the oldest marks are the faintest, so the cap costs the
        -- least visible part of the trail rather than truncating the part nearest her.
        local forget = trail_forget_meters()
        while #marks > 0 and (state.walked_meters - marks[1].at) >= forget do
            table.remove(marks, 1)
        end
        while #marks > TRAIL_MAX_MARKS do table.remove(marks, 1) end
        refresh_trail_bounds()
    end

    -- How far the player must move, in normalised world units, before a redraw can show
    -- a different pixel. Scales with the radius so one setting governs both.
    local function move_threshold(radius_meters)
        local span = (MapScale and MapScale.WORLD_SPAN_METERS) or 3155.52
        if span <= 0 then return 1.0 end
        local meters = radius_meters * MOVE_FRACTION_OF_RADIUS
        if meters < MOVE_MIN_METERS then meters = MOVE_MIN_METERS end
        return meters / span
    end

    -- Redraws the mask. `center_x`/`center_y` are the player's normalised world position
    -- in the same 0..1 space the tile map pans through (Map/Scale.WorldPanNormalized), so
    -- the peek circle lands on the player and not near them.
    local function redraw(context, held, center_x, center_y, radius_meters)
        -- A canvas cycle left open by a fault is the one state this module cannot
        -- recover from, so it never starts a second one on top of the first.
        if state.drawing then return false, "re-entered" end
        -- CRUMBED THROUGHOUT. v0.23.36, and it exists because v0.23.35 read the last
        -- crumb in her log as the failing call when the crumb sits at the TOP of
        -- load_texture and this entire function had none of its own. Everything from the
        -- texture loads to the end of the canvas cycle was a blind spot several hundred
        -- lines wide, and the crash lives somewhere inside it.
        view_crumb("rd-enter")
        local library = rendering_library()
        local target = ensure_target(context)
        if library == nil or target == nil then return false, "no-target" end
        view_crumb("rd-target")

        local textures = {}
        -- Default first and unconditionally: the tutorial area is revealed on a new save
        -- and is not an item, so it can never come back from the held set.
        local default_texture = load_texture(ASSET.default_fragment)
        if default_texture ~= nil then textures[#textures + 1] = default_texture end
        for _, short in ipairs(held or {}) do
            local texture = load_texture("T_UI_MapFragment_" .. short)
            if texture ~= nil then textures[#textures + 1] = texture end
        end
        local peek = load_texture(ASSET.peek)

        -- Back to black before the additive pass, or the porthole becomes a paint brush.
        --
        -- OPAQUE, AND v0.19.5 WAS RIGHT. v0.23.20.
        --
        -- v0.23.11 cleared this transparent on the reasoning that the alpha should carry
        -- the reveal, which meant overriding a pin that had cost a round trip in v0.19.4.
        -- MEASURED 2026-09-17: with it transparent the viewmask diagnostic -- which paints
        -- this mask straight onto the minimap -- came back near black at mean 18.6, centre
        -- 12.6, with no white disc anywhere. The shapes stopped reaching it. The same
        -- diagnostic on the opaque version had shown a bright peek circle with a soft rim,
        -- measured at 13 to 18 m against a 20 m setting.
        --
        -- So the old pin stands and the reveal has to become an alpha somewhere else. The
        -- reasoning that overrode it was mine and it was not measured first, which is the
        -- whole of invariant 0t pointed back at me.
        view_crumb("rd-clear")
        clear_target(context, target, CLEAR_BLACK)
        view_crumb("rd-clear-done")

        -- "Hide everything": stop here, with the mask solid black. If the minimap still
        -- shows its map after this, the mask is not reaching it and nothing downstream of
        -- the mask can possibly matter.
        if diagnostic() == "hide" then
            state.redraws = state.redraws + 1
            if not state.announced_draw then
                state.announced_draw = true
                log("Fog diagnostic: the mask is filled solid black. "
                    .. "The minimap's map should now be completely hidden. If it is not, "
                    .. "the mask is not reaching the map widget.")
            end
            return true, 0
        end

        local canvas_out, size_out, context_out = {}, {}, {}
        state.drawing = true
        -- FIVE arguments. The function's own error said so when it was called with two:
        -- "UFunction expected 5 parameters, received 2". Canvas comes back on the passed
        -- table's `Canvas` field.
        view_crumb("rd-begin")
        local began = pcall(function()
            library:BeginDrawCanvasToRenderTarget(context, target, canvas_out, size_out, context_out)
        end)
        view_crumb("rd-begin-done")
        if not began then
            state.drawing = false
            return false, "begin-failed"
        end

        local canvas = canvas_out.Canvas or canvas_out[1]
        local drawn = 0
        if canvas ~= nil and valid(canvas) then
            local span = { X = TARGET_PIXELS * 1.0, Y = TARGET_PIXELS * 1.0 }
            view_crumb("rd-tiles")
            for _, texture in ipairs(textures) do
                -- Blend 3. Additive is the ONLY mode that unions: 0, 1 and 2 are
                -- last-draw-wins, proven by bounding box in probe v1.5.0.
                if valid(texture) and pcall(function()
                    canvas:K2_DrawTexture(texture, UV_ORIGIN, span, UV_ORIGIN, UV_FULL,
                        WHITE, BLEND_ADDITIVE, 0.0, UV_ORIGIN)
                end) then drawn = drawn + 1 end
            end
            view_crumb("rd-tiles-done")

            -- THE TRAIL, under the peek and in the same additive pass. v0.23.5.
            --
            -- Additive multiplies the source by the tint before adding it, so a tint of
            -- {r,r,r} adds r of white -- which IS the fade. No second pass, no second
            -- texture: the same peek circle at a smaller radius and a lower tint.
            --
            -- Drawn before the peek so the full-strength circle around her lands on top
            -- of the freshest trail marks rather than under them. Additive unions either
            -- way; this only decides which one is visible where they overlap, and a
            -- brighter peek over a slightly dimmer mark is the right answer.
            -- Zero FIRST, and unconditionally. Without this the counter keeps the
            -- number from the last redraw that did stamp, so a trail that has stopped
            -- drawing still reports marks -- the diagnostic lying in exactly the case it
            -- exists for.
            state.trail_marks_drawn = 0
            view_crumb("rd-trail")
            if peek ~= nil and valid(peek) and trail_enabled() then
                local forget = trail_forget_meters()
                local trail_r = peek_pixels(trail_radius_meters())
                if trail_r > 0.5 and forget > 0 then
                    for _, mark in ipairs(state.trail) do
                        local reveal = trail_reveal(state.walked_meters - mark.at, forget)
                        -- Below this a stamp costs a draw call and changes nothing a
                        -- player could see; the mask is 8 bit.
                        -- THE CONE. v0.23.30, and it is her image rather than mine:
                        -- "think of it as the fog closing in, it's not just obscuring
                        -- getting thicker, but the sides are closing in. it can be tied to
                        -- visibility easily, the 5% visibility is 5% of the size it was,
                        -- 50% is 50% the size it was."
                        --
                        -- So the mark's RADIUS scales by exactly the same number as its
                        -- brightness. Both, not either: she said the obscuring still gets
                        -- thicker, the sides close in as well. A mark therefore dims and
                        -- narrows together, and the path reads as a wedge running back from
                        -- the player instead of a stripe that merely gets dimmer.
                        --
                        -- The floor is on the drawn RADIUS rather than on the reveal now.
                        -- Below half a pixel a stamp costs a draw call and changes nothing
                        -- a player could see, and with the radius scaling that threshold
                        -- arrives sooner than the old flat 2% did.
                        local mark_r = trail_r * reveal
                        if reveal > 0.02 and mark_r >= 0.5 then
                            local tint = { R = reveal, G = reveal, B = reveal, A = 1.0 }
                            local left = mark.x * TARGET_PIXELS - mark_r
                            local top = mark.y * TARGET_PIXELS - mark_r
                            if pcall(function()
                                canvas:K2_DrawTexture(peek, { X = left, Y = top },
                                    { X = mark_r * 2.0, Y = mark_r * 2.0 },
                                    UV_ORIGIN, UV_FULL, tint, BLEND_ADDITIVE, 0.0, UV_ORIGIN)
                            end) then
                                drawn = drawn + 1
                                state.trail_marks_drawn = state.trail_marks_drawn + 1
                            end
                        end
                    end
                    -- stamped, not held: a mark below the reveal floor is held and not
                    -- drawn, and that distinction is the point of the counter.
                end
            end
            view_crumb("rd-trail-done")

            -- The peek circle, added on top of the discovery mask in the same additive
            -- pass, so a revealed region and the peek hole simply union.
            view_crumb("rd-peek")
            -- Rule 1: on ground she has already uncovered there is nothing for the peek
            -- to uncover, so it is not drawn at all rather than drawn over clear map.
            if peek ~= nil and valid(peek) and center_x ~= nil and center_y ~= nil
                and peek_active() then
                local r = peek_pixels(radius_meters)
                if r > 0.5 then
                    local left = center_x * TARGET_PIXELS - r
                    local top = center_y * TARGET_PIXELS - r
                    if pcall(function()
                        canvas:K2_DrawTexture(peek, { X = left, Y = top },
                            { X = r * 2.0, Y = r * 2.0 }, UV_ORIGIN, UV_FULL,
                            WHITE, BLEND_ADDITIVE, 0.0, UV_ORIGIN)
                    end) then drawn = drawn + 1 end
                end
            end
            view_crumb("rd-peek-done")
        end
        view_crumb("rd-end")
        pcall(function() library:EndDrawCanvasToRenderTarget(context, context_out) end)
        view_crumb("rd-end-done")

        -- The handle still gets made, once. ensure_inverse_target returns immediately
        -- when the target is already valid, so this is one valid() call per redraw and
        -- the fallback that Map/NativeWidget.lua reaches for keeps existing.
        view_crumb("rd-inverse")
        ensure_inverse_target(context)
        view_crumb("rd-inverse-done")

        -- v0.20.0's SECOND PASS IS GONE. v0.23.4.
        --
        -- It cleared a second 2048x2048 target to white and then redrew every fragment
        -- and the peek into it with a tint of -1, to build "1 - reveal" by subtraction.
        -- The engine clamps negative tints, which this file has recorded as MEASURED
        -- since v0.20.0: "state.inverse_target has been a plain white rectangle since
        -- v0.20.0". So the pass produced a white rectangle, at the cost of a full-target
        -- clear, a BeginDraw/EndDraw canvas cycle and up to thirteen full-target blits,
        -- on EVERY redraw.
        --
        -- The target itself stays, because its one consumer still wants a handle:
        -- Map/NativeWidget.lua's `mask_source = view_white or fog_mask or inverse` reads
        -- it as a third-choice fallback and never reads its contents. It is created
        -- white and left alone, which is the same rectangle for none of the work.
        --
        -- Found by profiling rather than by reading: one cold fog redraw cost 196 ms of
        -- game thread in a single frame on her machine during a load, and this was about
        -- half of it. The code had said in writing for three versions that the pass did
        -- nothing; nobody had added up what the nothing cost.
        state.drawing = false

        if canvas == nil or drawn == 0 then return false, "nothing-drawn" end
        state.redraws = state.redraws + 1
        if not state.announced_draw then
            state.announced_draw = true
            -- Not debug_log. This is the one line that says the mechanism ran at all,
            -- and it has to survive a session with diagnostics off -- the v0.19.0 log
            -- had no fog line in it anywhere, which is why that run proved nothing.
            log(string.format(
                "Fog mask drawn: %d texture%s, peek %.1f px of %d, %d region%s held.",
                drawn, drawn == 1 and "" or "s", peek_pixels(radius_meters), TARGET_PIXELS,
                #(held or {}), #(held or {}) == 1 and "" or "s"))
        end
        return true, drawn
    end

    ------------------------------------------------------------------
    -- Public surface
    ------------------------------------------------------------------

    -- NativeWidget calls this during Build and binds the result as GlobalAlphaMask.
    -- Returns nil when fog is off or anything is unavailable, and nil must always mean
    -- "build the minimap exactly as it was before fog existed".
    -- `pinner(texture, name)` is supplied by NativeWidget and keeps each resolved texture
    -- alive by holding it in a collapsed Image inside the widget tree being built. Its
    -- lifetime is the tree's, which is why DropTarget clears the texture cache with it.
    function fog.MaskForBuild(context, pinner)
        pin_texture = type(pinner) == "function" and pinner or nil
        if not enabled() then return nil end
        if state.disabled_reason ~= nil then return nil end
        local target = ensure_target(context)
        if target == nil then
            state.disabled_reason = "no-render-target"
            log("Fog unavailable: a render target could not be created. The minimap is unaffected.")
            return nil
        end
        -- Seed it before the widget ever samples it, so the first frame after a rebuild
        -- is not a fully black mask with the whole map cut away.
        poll_discovery(clock(), true)

        local ok
        if state.held_signature == nil and diagnostic() ~= "hide" then
            -- Discovery could not be read even once. Drawing a mask now would fog over
            -- regions the player has already earned, which is worse than no fog at all,
            -- so the mask starts fully revealed. It is still bound and still live, so the
            -- first poll that succeeds paints the real fog into it with no rebuild.
            ok = clear_target(context, target, WHITE)
            log("Fog is on but the player's map pieces could not be read yet; "
                .. "the minimap stays fully revealed until they can.")
        else
            ok = redraw(context, state.held or {}, state.last_center_x, state.last_center_y,
                tonumber(Config.FogRevealMeters) or 50)
            if not ok then
                debug_log("Fog mask seeded empty; the first tick will redraw it")
            end
        end
        if not state.announced_bind then
            state.announced_bind = true
            log(string.format("Fog mask bound to the map widget (%dx%d, seeded=%s).",
                TARGET_PIXELS, TARGET_PIXELS, tostring(ok == true)))
        end
        return target
    end

    -- Called from the tick. The ordering here is the point of this file: nothing that
    -- touches the engine runs before the change test, and the change test is arithmetic
    -- on numbers already in hand.
    function fog.Update(context, center_x, center_y)
        -- A DUNGEON FORGETS THE TRAIL, ON THE WAY IN. v0.23.39, her words: "When entering
        -- a dungeon it should forget it's trail".
        --
        -- It has to happen HERE, above the enabled() bail, because enabled() is already
        -- false by the time we are inside -- so trail_sample, which is what normally
        -- clears the marks when the trail is off, is never reached. Without this the
        -- marks would sit untouched for the whole dungeon and reappear on the way out.
        --
        -- trail_last_x/y go to nil as well, so the first sample after leaving re-seeds
        -- from the exit rather than drawing one clear line from where she went in --
        -- the same break the teleport guard makes.
        if fog.Suppressed() then
            if #state.trail > 0 or state.walked_meters ~= 0.0
                or state.trail_last_x ~= nil then
                state.trail = {}
                state.walked_meters = 0.0
                state.trail_marks_drawn = 0
                state.trail_last_x, state.trail_last_y = nil, nil
                state.trail_min_x, state.trail_max_x = nil, nil
                state.trail_min_y, state.trail_max_y = nil, nil
                debug_log("Fog suppressed in a dungeon; the trail is forgotten")
            end
            return false
        end
        if not enabled() or state.disabled_reason ~= nil then return false end
        if not valid(state.target) then return false end

        local token = perf.Begin()
        local now = clock()
        local radius = tonumber(Config.FogRevealMeters) or 50

        -- The trail is sampled on EVERY update, before the change tests, because it is
        -- driven by distance walked rather than by whether a redraw is due. Costs one
        -- square root when the player moved and a comparison when she did not.
        view_crumb("upd-trail")
        trail_sample(center_x, center_y)

        -- 1. Free tests.
        local radius_changed = state.last_radius_meters ~= radius
        local threshold = move_threshold(radius)
        local moved = state.last_center_x == nil or state.last_center_y == nil
            or center_x == nil or center_y == nil
            or math.abs(state.last_center_x - center_x) > threshold
            or math.abs(state.last_center_y - center_y) > threshold

        -- 2. The expensive read, behind its own clock. Two seconds late to notice a map
        --    piece is invisible; eighteen times a second is 29 ms of every frame.
        view_crumb("upd-poll")
        local discovery_changed = poll_discovery(now, false)
        view_crumb("upd-poll-done")
        -- A new region means a fragment that may not be resolved yet.
        if discovery_changed then
            state.textures_warm = false
            -- Picking up a map piece changes the answer for ground she is nowhere near,
            -- so every memoised marker answer is stale at once.
            local dropped = state.reveal_memo_count
            forget_reveal_memo()
            -- v0.23.52. THE ONE MOMENT THAT LEFT NO TRACE. She picked up a fragment to
            -- test exactly this path and the log had nothing to say about it: the fog
            -- notices the new region, throws away its cached marker answers and rebuilds,
            -- all silently, so "did the pickup register" could not be answered afterwards.
            --
            -- Fires only when the held set actually changes -- eleven times in a whole
            -- playthrough -- so it is a string.format on an event, not on a frame
            -- (invariant 0l). It names the set rather than the count, because "she picked
            -- one up" and "one stopped resolving" both change the count.
            debug_log(string.format(
                "Map pieces changed: held=[%s] cachedMarkerAnswersDropped=%d",
                state.held_signature or "none", dropped))
        end

        -- THE PEEK STATE MACHINE. Placed after the discovery poll because a map piece
        -- picked up while standing still is the one way the answer changes without her
        -- moving, and after trail_sample because it reads the metres that call just added.
        view_crumb("upd-peek-state")
        update_peek_state(center_x, center_y, discovery_changed)
        view_crumb("upd-peek-state-done")

        -- Until discovery answers once, the mask is the fully-revealed white one that
        -- MaskForBuild left behind. Painting fog from an unknown held set would hide
        -- regions the player has already earned, so nothing is drawn. The moment the
        -- signature goes from nil to anything, discovery_changed is true and the real
        -- mask lands on that tick.
        if state.held_signature == nil and diagnostic() ~= "hide" then
            perf.End("fog.update", token)
            return false
        end

        -- WARM BEFORE DRAWING, AND BEFORE THE CHANGE TESTS. v0.23.4.
        --
        -- Deliberately above the "did anything change" gate, so the disk loads happen
        -- during the seconds after a load when the player is standing still and nothing
        -- has changed yet -- and the first redraw that does matter is instant. Below the
        -- gate it would warm only when the player moved, which is the worst moment.
        --
        -- Not a failure, so it does not count toward the nine-strike disable: nothing is
        -- broken, the textures are simply not resident yet. Returning without touching
        -- last_center/last_radius leaves every change flag set, so the next step tries
        -- again on its own.
        view_crumb("upd-warm")
        if not warm_textures(state.held or {}) then
            perf.End("fog.update", token)
            return false
        end

        -- NO SEPARATE TRAIL TRIGGER, and the suite is why. v0.23.5.
        --
        -- The first version added "the trail is fading" as a fourth reason to redraw, and
        -- FogRegression failed on "sub-threshold movement does not redraw" -- correctly.
        -- Any movement at all advances walked_meters, so that condition was true on every
        -- step, and a walking player would have redrawn at the 10 Hz ceiling forever
        -- instead of only when she crossed the move threshold.
        --
        -- It is also unnecessary, which is the nicer half. The trail ages by DISTANCE
        -- WALKED, and `moved` above is a distance test on the same movement -- so every
        -- step big enough to change the trail visibly is already a step big enough to
        -- redraw. Below that threshold the trail has aged by less than the threshold too,
        -- which against 250 m of memory is invisible. Her "it fades with every step you
        -- take" falls out of the cadence that was already there.
        if not (moved or discovery_changed or radius_changed) then
            perf.End("fog.update", token)
            return false
        end

        -- 3. A ceiling on redraws. An event that happened once -- a new region, a new
        --    radius -- goes through immediately; walking waits its turn.
        if not (discovery_changed or radius_changed)
            and state.next_redraw_at ~= nil and now < state.next_redraw_at then
            perf.End("fog.update", token)
            return false
        end
        state.next_redraw_at = now + REDRAW_MIN_SECONDS

        view_crumb("upd-redraw")
        local draw_token = perf.Begin()
        local ok, note = redraw(context, state.held or {}, center_x, center_y, radius)
        view_crumb("upd-redraw-done")
        perf.End("fog.redraw", draw_token)

        if ok then
            state.last_center_x, state.last_center_y = center_x, center_y
            state.last_radius_meters = radius
            if discovery_changed then
                local n = #(state.held or {})
                log(string.format("Fog discovery changed: %d region%s held",
                    n, n == 1 and "" or "s"))
            end
            perf.End("fog.update", token)
            return true
        end

        state.failures = state.failures + 1
        -- Nine consecutive failures is a broken mechanism, not a bad frame. Stop rather
        -- than spend the rest of the session retrying something that will not work --
        -- the v0.18.46 lesson about a retry that ate a frame every second forever.
        if state.failures >= 9 then
            state.disabled_reason = tostring(note)
            log("Fog disabled after repeated redraw failures (" .. tostring(note)
                .. "). The minimap is unaffected.")
        end
        perf.End("fog.update", token)
        return false
    end

    ------------------------------------------------------------------
    -- View-space crop (v0.22.2)
    ------------------------------------------------------------------

    -- One texture, world uv in, view uv out. The whole crop is the two coordinate
    -- arguments; everything else is a full-target blit.
    local function library_for_view() return rendering_library() end

    local function blit_view(context, source, target, u0, v0, span, tint, blend)
        -- CRUMBED TO THE INDIVIDUAL ENGINE CALL. v0.23.32.
        --
        -- Her crash log ends at "View crumb step=blit-painting", so the process dies inside
        -- THIS function on the first crop after she moves. Three engine calls happen here
        -- and they fail for different reasons, so they get different crumbs:
        --
        --   begin  -> BeginDrawCanvasToRenderTarget(context, target). Blames the world
        --             context (a retained player controller) or the render target.
        --   draw   -> K2_DrawTexture(source). Blames the SOURCE -- for the painting blit
        --             that is state.fog_painting, a cooked asset NativeWidget retains
        --             "for this build's lifetime", which is exactly the kind of handle
        --             invariant 0e is about.
        --   end    -> the canvas cycle closing.
        --
        -- Note what is already ruled out: clear_target ran on the SAME context moments
        -- earlier and survived, so a simply-dead controller does not fit on its own.
        local library = rendering_library()
        if library == nil or source == nil or target == nil then return false end
        if not valid(source) or not valid(target) then return false end
        tint = tint or WHITE
        blend = blend or BLEND_OPAQUE
        local out, size_out, ctx_out = {}, {}, {}
        view_crumb("begin")
        local began = pcall(function()
            library:BeginDrawCanvasToRenderTarget(context, target, out, size_out, ctx_out)
        end)
        view_crumb("begin-done")
        if not began then return false end
        local canvas = out.Canvas or out[1]
        local drew = false
        if canvas ~= nil and valid(canvas) then
            view_crumb("draw")
            drew = pcall(function()
                canvas:K2_DrawTexture(source, UV_ORIGIN,
                    { X = VIEW_PIXELS * 1.0, Y = VIEW_PIXELS * 1.0 },
                    { X = u0, Y = v0 }, { X = span, Y = span },
                    tint, blend, 0.0, UV_ORIGIN)
            end)
            view_crumb("draw-done")
        end
        view_crumb("end")
        pcall(function() library:EndDrawCanvasToRenderTarget(context, ctx_out) end)
        view_crumb("end-done")
        return drew
    end

    -- One texture at a placed position and size inside a view-sized target. Used to stamp
    -- the peek at the view's centre; kept separate from blit_full (which always covers the
    -- whole target) so neither can inherit the other's geometry by accident.
    local function blit_centered(context, source, target, left, top, size, tint, blend)
        local library = rendering_library()
        if library == nil or source == nil or target == nil then return false end
        if not valid(source) or not valid(target) then return false end
        local out, size_out, ctx_out = {}, {}, {}
        if not pcall(function()
            library:BeginDrawCanvasToRenderTarget(context, target, out, size_out, ctx_out)
        end) then return false end
        local canvas = out.Canvas or out[1]
        local drew = false
        if canvas ~= nil and valid(canvas) then
            drew = pcall(function()
                canvas:K2_DrawTexture(source, { X = left, Y = top }, { X = size, Y = size },
                    UV_ORIGIN, UV_FULL, tint or WHITE, blend or BLEND_ADDITIVE, 0.0, UV_ORIGIN)
            end)
        end
        pcall(function() library:EndDrawCanvasToRenderTarget(context, ctx_out) end)
        return drew
    end

    -- A whole-texture draw into a view-sized target. blit_view exists to CROP a
    -- world-space texture; this one copies a view-space texture that is already the right
    -- size, so it takes a blend instead of a window. Keeping them separate means the
    -- composite cannot accidentally inherit a crop.
    -- THE MASK AND THE PEEK SHARE ONE CANVAS CYCLE. v0.23.43, from the performance audit.
    --
    -- Both write view_mask, and they were doing it through two separate
    -- BeginDrawCanvasToRenderTarget / EndDrawCanvasToRenderTarget pairs. Opening a canvas
    -- on a target you already have open is two engine calls for nothing.
    --
    -- MEASURED before the change, over her 502 s session: fog.view cost 0.654 ms per call
    -- across 7164 calls, and fog.view.clear -- one pcall'd engine call with no crumbs in
    -- it -- measured 0.026 ms, which is the per-engine-call yardstick this uses. Dropping
    -- a Begin and an End is about 0.05 ms of the crop.
    --
    -- The peek is optional: when it will not be drawn this behaves exactly like the old
    -- blit_view, so there is no path where the mask blit gets worse.
    local function blit_mask_with_peek(context, source, target, u0, v0, span,
                                       peek, peek_left, peek_size)
        local library = rendering_library()
        if library == nil or source == nil or target == nil then return false end
        if not valid(source) or not valid(target) then return false end
        local out, size_out, ctx_out = {}, {}, {}
        view_crumb("begin")
        local began = pcall(function()
            library:BeginDrawCanvasToRenderTarget(context, target, out, size_out, ctx_out)
        end)
        view_crumb("begin-done")
        if not began then return false end
        local canvas = out.Canvas or out[1]
        local drew = false
        if canvas ~= nil and valid(canvas) then
            view_crumb("draw")
            drew = pcall(function()
                canvas:K2_DrawTexture(source, UV_ORIGIN,
                    { X = VIEW_PIXELS * 1.0, Y = VIEW_PIXELS * 1.0 },
                    { X = u0, Y = v0 }, { X = span, Y = span },
                    WHITE, BLEND_OPAQUE, 0.0, UV_ORIGIN)
            end)
            view_crumb("draw-done")
            -- Second draw, same open canvas. Additive over the mask exactly as the
            -- separate stamp was, so the picture is unchanged.
            if peek ~= nil and valid(peek) and peek_size ~= nil then
                view_crumb("peek-stamp")
                pcall(function()
                    canvas:K2_DrawTexture(peek, { X = peek_left, Y = peek_left },
                        { X = peek_size, Y = peek_size },
                        UV_ORIGIN, UV_FULL, WHITE, BLEND_ADDITIVE, 0.0, UV_ORIGIN)
                end)
            end
        end
        view_crumb("end")
        pcall(function() library:EndDrawCanvasToRenderTarget(context, ctx_out) end)
        view_crumb("end-done")
        return drew
    end

    local function blit_full(context, source, target, tint, blend)
        local library = rendering_library()
        if library == nil or source == nil or target == nil then return false end
        if not valid(source) or not valid(target) then return false end
        local out, size_out, ctx_out = {}, {}, {}
        if not pcall(function()
            library:BeginDrawCanvasToRenderTarget(context, target, out, size_out, ctx_out)
        end) then return false end
        local canvas = out.Canvas or out[1]
        local drew = false
        if canvas ~= nil and valid(canvas) then
            drew = pcall(function()
                canvas:K2_DrawTexture(source, UV_ORIGIN,
                    { X = VIEW_PIXELS * 1.0, Y = VIEW_PIXELS * 1.0 },
                    UV_ORIGIN, UV_FULL, tint or WHITE, blend or BLEND_OPAQUE, 0.0, UV_ORIGIN)
            end)
        end
        pcall(function() library:EndDrawCanvasToRenderTarget(context, ctx_out) end)
        return drew
    end

    -- The two targets the overlay material samples. Made once, then refreshed in place,
    -- so the material's texture parameters are written at build time and never again --
    -- a per-tick SetTextureParameterValue would be the expensive way to do nothing.
    -- fogged painting, discovery mask, clear painting, solid-white mask.
    function fog.ViewTargets(context)
        if not enabled() then return nil, nil, nil, nil end
        return ensure_view_target(context, "view_painting", CLEAR_BLACK),
               ensure_view_target(context, "view_mask", CLEAR_BLACK),
               ensure_view_target(context, "view_clear", CLEAR_BLACK),
               ensure_view_target(context, "view_white", WHITE)
    end

    -- NativeWidget owns asset loading, so it hands the clear painting down once.
    function fog.SetClearPainting(texture)
        state.clear_painting = texture
    end

    -- THE COMPOSITE, DONE BY US. v0.23.10.
    --
    -- MEASURED 2026-09-17, one variable, both paintings blitted, only the mask forced:
    -- maskwhite and maskblack are PIXEL-IDENTICAL over the whole minimap. Those are
    -- opposites -- reveal everything, reveal nothing. A mask that cannot change the
    -- picture is not masking, so MI_SpartaMapTile's mask inputs do nothing on a plain
    -- UImage. Not the parameter NAME either: the game's own instance overrides exactly
    -- one texture, RegionMask, and we set that one too. The likeliest reason is the same
    -- one that killed MapUVScaleOffset in v0.22.2 -- the material samples its mask
    -- through tile uvs the widget feeds it, and a plain Image has none.
    --
    -- v0.22.8 wrote down what to do if this ever measured out: "the entire
    -- material-masking approach is dead and the compositing has to become ours". It has,
    -- so it does. Three Images and their materials collapse to ONE Image with a plain
    -- texture brush -- and a texture brush on an Image is already proven, because the
    -- viewmask diagnostic renders one perfectly.
    --
    -- ONE canvas pass, no material, no inverse mask, and the compositing left to UMG.
    -- The pass and the three blend modes it had to stop using are documented inside
    -- compose_view, at the lines that do the work.
    --
    -- WHAT DO THE CANVAS BLEND MODES ACTUALLY DO? v0.23.22.
    --
    -- Five versions were lost guessing at this, each one producing a different convincing
    -- wrong picture. What is measured so far, all of it the hard way:
    --     OPAQUE      writes alpha 1 rather than carrying the source's
    --     MODULATE    multiplies the alpha as well as the colour
    --     TRANSLUCENT replaces the destination's alpha rather than blending it
    --     ADDITIVE    unknown -- possibly (One,One), possibly (SrcAlpha,One)
    --
    -- Guessing the fifth time would be indefensible, so this draws the question instead.
    -- A view-sized target is cleared to a known destination, then the SAME known source is
    -- drawn into four horizontal bands, one per blend mode, and the result is shown on the
    -- minimap. Every band's colour then says what that mode did, and the alpha says itself
    -- by whether the band is opaque, partly there, or invisible over the map beneath.
    --
    -- The source is the peek circle texture, because it is the one asset whose shape is
    -- unambiguous at a glance and whose alpha is the actual unknown in the composite.
    -- Drawing it at band size makes "did the colour arrive" and "did the alpha arrive" two
    -- different, visible questions.
    --
    -- Read the result as: a band showing the circle means the colour arrived; a band you
    -- can see the map through means the alpha did not become 1; a band that is invisible
    -- means the mode dropped the draw entirely.
    local function blend_probe(context)
        local target = ensure_view_target(context, "view_probe", CLEAR_BLACK)
        local source = load_texture(ASSET.peek)
        if target == nil or source == nil or not valid(source) then return false, "no-source" end

        -- A known destination: mid grey, fully opaque. Anything that survives a draw is
        -- then legible against it, and so is anything that eats it.
        clear_target(context, target, { R = 0.5, G = 0.5, B = 0.5, A = 1.0 })

        local library = rendering_library()
        if library == nil then return false, "no-library" end
        local out, size_out, ctx_out = {}, {}, {}
        if not pcall(function()
            library:BeginDrawCanvasToRenderTarget(context, target, out, size_out, ctx_out)
        end) then return false, "begin-failed" end
        local canvas = out.Canvas or out[1]
        local drawn = 0
        if canvas ~= nil and valid(canvas) then
            local band = VIEW_PIXELS / 4.0
            local modes = { BLEND_OPAQUE, BLEND_TRANSLUCENT, BLEND_ADDITIVE, 5 }
            for i, blend in ipairs(modes) do
                local top = (i - 1) * band
                if pcall(function()
                    canvas:K2_DrawTexture(source, { X = 0.0, Y = top },
                        { X = VIEW_PIXELS * 1.0, Y = band }, UV_ORIGIN, UV_FULL,
                        WHITE, blend, 0.0, UV_ORIGIN)
                end) then drawn = drawn + 1 end
            end
        end
        pcall(function() library:EndDrawCanvasToRenderTarget(context, ctx_out) end)
        if not state.announced_probe then
            state.announced_probe = true
            log(string.format(
                "Fog blend probe: %d of 4 bands drawn onto opaque mid grey, top to bottom "
                .. "OPAQUE(0), TRANSLUCENT(2), ADDITIVE(3), ALPHACOMPOSITE(5). A band "
                .. "showing the circle means the colour arrived; a band you can see the "
                .. "map through means the alpha did not.", drawn))
        end
        return drawn > 0, nil
    end

    function fog.ProbeTarget()
        return valid(state.view_probe) and state.view_probe or nil
    end

    local function compose_view(context)
        local masked = ensure_view_target(context, "view_masked_clear", CLEAR_TRANSPARENT)
        local clear_view = state.view_clear
        local mask_view = state.view_mask
        if masked == nil then return false, "no-target" end
        if not (valid(clear_view) and valid(mask_view)) then return false, "no-source" end

        -- ONE PASS, ONE TEXTURE: the clear map in RGB, the reveal in ALPHA.
        --
        -- NOTHING HERE IS OPAQUE, AND NOTHING COMPOSITES. Both of those cost a version:
        --   * an OPAQUE canvas draw writes alpha 1 rather than carrying the source's, so
        --     laying the clear map down opaque gave this target alpha 1 before the mask
        --     was added, and adding to 1 saturates -- reveal 1 everywhere, which is the
        --     clear map edge to edge with no fog (v0.23.18).
        --   * a TRANSLUCENT canvas draw REPLACES the destination's alpha rather than
        --     blending it, so composing the two pictures here left the result transparent
        --     and the minimap drew nothing at all -- measured flat at 80.81, the same
        --     number as building no fog layers whatsoever (v0.23.19).
        -- MODULATE multiplies the alpha too, which zeroed the reveal against a painting
        -- whose alpha is zero. Three blend modes, three versions, three different
        -- convincing wrong pictures.
        --
        -- So: the colour is ADDED onto a transparent target, which carries RGB and
        -- contributes no alpha of its own, and the reveal is ADDED afterwards through a
        -- tint that is black and fully opaque -- "take the alpha, drop the colour", the
        -- one way found to write an alpha channel on a canvas with no channel mask.
        --
        -- The compositing then belongs to UMG, which blends two Images by alpha correctly
        -- every frame for every widget in the game. NativeWidget puts the fogged painting
        -- on the lower Image and this target on the upper one. A texture brush on an Image
        -- is already proven here: it is how the viewmask diagnostic renders.
        clear_target(context, masked, CLEAR_TRANSPARENT)
        local ok_clear = blit_full(context, clear_view, masked, WHITE, BLEND_ADDITIVE)
        local ok_mask = blit_full(context, mask_view, masked, ALPHA_ONLY, BLEND_ADDITIVE)

        if not state.announced_compose then
            state.announced_compose = true
            log(string.format(
                "Fog composite (ours, one texture, UMG blends it): clearMap=%s reveal=%s. "
                .. "RGB is the clear map, alpha is the reveal. A minimap with no fog means "
                .. "the alpha is 1 everywhere; one with no reveal means it is 0.",
                tostring(ok_clear), tostring(ok_mask)))
        end
        return ok_clear and ok_mask, nil
    end

    -- The upper Image's brush: the clear map with the reveal in its alpha. The lower one
    -- takes fog.ViewTargets()' painting, which NativeWidget already holds.
    function fog.CompositeTarget()
        return valid(state.view_masked_clear) and state.view_masked_clear or nil
    end

    -- Refresh both crops for the current view. `painting` is the game's fogged world
    -- painting; the mask is this module's own inverse target.
    --
    -- pan_x/pan_y are the view CENTRE in world uv, span is its width, both as the map
    -- widget already computes them. The window is clamped to the world, so standing at a
    -- corner crops a corner rather than sampling off the edge.
    function fog.RefreshView(context, painting, pan_x, pan_y, span)
        if not enabled() then return false, "disabled" end
        span = tonumber(span) or 0.0
        if span <= 0.0 then return false, "no-span" end
        if span > 1.0 then span = 1.0 end
        view_crumb("targets")
        local view_painting, view_mask = fog.ViewTargets(context)
        view_crumb("targets-done")
        if view_painting == nil or view_mask == nil then return false, "no-target" end

        -- "world" is the same machinery with the window opened all the way: span 1.0 at
        -- the origin IS the whole world, so the painting is the full map and the stamped
        -- holes are every area she has revealed, tutorial included, in one picture. Her
        -- request, and it needs no second code path -- which is the point of having moved
        -- the crop into our own hands.
        if tostring(Config.FogDiagnostic or "off") == "world" then
            span, pan_x, pan_y = 1.0, 0.5, 0.5
        end

        local limit = 1.0 - span
        if limit < 0.0 then limit = 0.0 end
        local u0 = (tonumber(pan_x) or 0.5) - span * 0.5
        local v0 = (tonumber(pan_y) or 0.5) - span * 0.5
        if u0 < 0.0 then u0 = 0.0 elseif u0 > limit then u0 = limit end
        if v0 < 0.0 then v0 = 0.0 elseif v0 > limit then v0 = limit end

        -- INVERTED IN VIEW SPACE. v0.22.5.
        --
        -- MEASURED: the disc IS the peek circle, and it is filled with fog instead of
        -- cleared. Reveal radius 10/20/30 m puts its edge at 84/183/246 px against a
        -- predicted 102/205/307 -- a constant 0.8 ratio, which is what a feathered edge
        -- read at a 50%% threshold looks like. She had been saying exactly this for weeks.
        --
        -- (I had "proved" the opposite an hour earlier by comparing 50 m and 300 m. The
        -- minimap's visible RADIUS is 45.4 m, so both of those swallow the whole view and
        -- look identical. A negative result from an instrument that cannot register the
        -- signal is not a negative result.)
        --
        -- So the material paints where its mask is WHITE, and the discovery mask is white
        -- exactly where she has been. The mask handed to it has to be white where she has
        -- NOT been.
        --
        -- Built here rather than taken from state.inverse_target, because that target is
        -- made by an additive draw with a negative tint -- a trick this codebase has
        -- never confirmed the engine honours. Doing it in view space makes the outcome
        -- legible either way: if negative tints work, fog appears everywhere EXCEPT the
        -- circle, which is the goal. If the engine clamps them at zero the view mask
        -- stays solid white and the whole minimap fogs over uniformly -- an unmistakable
        -- failure rather than a subtle one, and a different picture from the disc, which
        -- is what makes this an experiment instead of another guess.
        -- White is the fail-open state: a mask of all white reveals everything, which is
        -- the minimap exactly as it was before fog existed. The blit below is blend 0 and
        -- overwrites every channel, so this only ever shows when the blit fails.
        local token_inv = perf.Begin()
        clear_target(context, view_mask, WHITE)
        perf.End("fog.view.clear", token_inv)

        -- THE DISCOVERY MASK, NOT THE INVERSE. v0.22.3.
        --
        -- v0.20.0 fed the overlay the inverse -- white where fog belongs -- on the
        -- reasoning that fog goes where the player has not been. The reasoning was right
        -- and the mask was backwards, which only became visible once the crop was fixed
        -- and there was a real map to see it against: her 02:17 screenshots show a disc
        -- of fog sitting exactly on the peek circle, fogging the one place she HAD been
        -- and leaving the rest of the map clear.
        --
        -- So the material draws TileTexture where its mask is DARK. The discovery target
        -- is white where she has been and black where she has not, which puts the
        -- painting in the unexplored ground and leaves the explored ground alone.
        -- Measured from the picture, not reasoned from the parameter name -- the names on
        -- this material have been wrong three times now.
        -- v0.23.0 TWO LAYERS, AND NOTHING IS INVERTED.
        --
        -- Every route to an inverted mask is now closed, both by measurement:
        --   * Negative tints are clamped, so "subtract the shapes out of white" leaves
        --     white. state.inverse_target has been a plain white rectangle since v0.20.0.
        --   * The fragment textures carry their shape in RGB, not alpha, so stamping one
        --     black with a translucent draw blackens the whole rectangle. Seven stamps
        --     took the mask to 97.7%% black and removed the fog entirely.
        --
        -- What DOES work, measured: white mask = fog (95.5%% of the map), black = clear
        -- (1.4%%), and additive white on black builds correct shapes -- which is how the
        -- discovery mask is already made, and it is right.
        --
        -- So stop inverting. Two layers, each using the mask in the direction that works:
        --
        --   A. the FOGGED painting through a solid WHITE mask   -> fog everywhere
        --   B. the CLEAR painting through the discovery mask    -> her collected tiles
        --      punched back through, because that mask is white exactly where she has been
        --
        -- Net result is her world map, and no step asks the engine for anything it has
        -- refused.

        -- Layer A's mask never changes: solid white, made once.
        local white_mask = ensure_view_target(context, "view_white", WHITE)
        if white_mask ~= nil and not state.view_white_ready then
            state.view_white_ready = clear_target(context, white_mask, WHITE)
        end

        -- v0.22.8 THE ONE QUESTION LEFT: does the mask reach the shader at all?
        --
        -- Everything else is now measured. The scalars land exactly (High wanted=1.000
        -- got=1.000, Density got=200.000). The disc is the PAINTING's own content -- the
        -- fogged world map has a bright soft blob at her world position, luma 105 at the
        -- centre falling to 62 at the edge of the crop, which composited over the map
        -- reads as a grey circle. No parameter moves it because nothing is drawing a
        -- circle; the fog is already covering the whole view.
        --
        -- So the only thing that has never actually been demonstrated is whether
        -- GlobalMask/RegionMask do ANYTHING on a plain Image. MapUVScaleOffset did not.
        -- If they do not either, the entire material-masking approach is dead and the
        -- compositing has to become ours -- which is a big decision to take on inference.
        --
        -- "maskblack" makes it a measurement: the view mask is cleared to solid black and
        -- nothing is blitted into it. Fog vanishes => the mask works and the fix is to
        -- invert it. Fog unchanged => the mask is inert and the material is a dead end.
        -- Two outcomes, both unambiguous, one run.
        local probe = tostring(Config.FogDiagnostic or "off")
        if probe == "maskblack" or probe == "maskwhite" then
            -- THE PROBE USED TO CHANGE TWO THINGS. v0.23.9.
            --
            -- It forced the mask AND skipped the clear painting's blit, so view_clear
            -- stayed black -- and layer B draws view_clear. Both settings therefore
            -- produced a layer B with nothing in it, and maskwhite came back identical to
            -- maskblack, which reads as "the mask does nothing" when it only ever meant
            -- "there was nothing to reveal either way". Two variables, one picture, no
            -- measurement. Third instrument today to answer confidently while broken.
            --
            -- Now it changes exactly one thing: both paintings are blitted normally and
            -- only the mask is forced. maskwhite should then be the clear map edge to
            -- edge and maskblack solid fog, and if those two are still identical the
            -- mask really is inert.
            local token_p = perf.Begin()
            local ok_paint_p = blit_view(context, painting, view_painting, u0, v0, span)
            local clear_probe = ensure_view_target(context, "view_clear", CLEAR_BLACK)
            local ok_clear_p = false
            if clear_probe ~= nil and state.clear_painting ~= nil then
                ok_clear_p = blit_view(context, state.clear_painting, clear_probe, u0, v0, span)
            end
            clear_target(context, view_mask, probe == "maskblack" and CLEAR_BLACK or WHITE)
            perf.End("fog.view", token_p)
            if not state.announced_view then
                state.announced_view = true
                log("Fog view crop: MASK PROBE " .. probe
                    .. " -- both paintings blitted, ONLY the mask is forced. painting="
                    .. tostring(ok_paint_p) .. " clear=" .. tostring(ok_clear_p))
            end
            return ok_paint_p, nil
        end

        local token = perf.Begin()
        view_crumb("blit-painting")
        local ok_paint = blit_view(context, painting, view_painting, u0, v0, span)
        -- BACK TO A PLAIN COPY. v0.23.21.
        --
        -- v0.23.15 made this additive onto a transparent clear so the mask's alpha would
        -- survive the crop. MEASURED after the world mask went back to opaque: viewmask,
        -- which paints THIS target straight onto the minimap, became identical to fog-off
        -- (mean difference 0.08) -- the Image draws nothing at all. The additive crop is
        -- not delivering the mask, whatever it does to the alpha.
        --
        -- So the crop is a plain copy again, which is the form that rendered a bright peek
        -- circle with a soft rim every time it was asked to. Getting the reveal into an
        -- alpha channel is a separate problem and it does not get to break the mask on the
        -- way past.
        --
        -- THE OLD REASONING, kept because it is still true and still a trap: blend 0 on a
        -- canvas WRITES alpha 1 rather than carrying the source's.
        --
        -- This was a plain blend-0 copy, and blend 0 on a canvas writes alpha 1 -- so the
        -- mask arrived in view space fully opaque whatever its own alpha had been, and the
        -- composite's reveal came out 1 everywhere. MEASURED: the minimap showed the clear
        -- map edge to edge with no fog at all, which is exactly what "revealed everywhere"
        -- looks like.
        --
        -- Cleared transparent and added instead, so both the colour AND the alpha arrive
        -- as they were drawn. Additive is known to carry source alpha -- that is the same
        -- fact that made the reveal 1 everywhere when it added an opaque mask.
        -- v0.23.43: the peek is RESOLVED first and then drawn inside the mask's own
        -- canvas cycle, instead of opening a second one on the same target.
        view_crumb("peek-resolve")
        local peek_left, peek_size = nil, nil
        local peek_view = peek_active() and load_texture(ASSET.peek) or nil
        if peek_view ~= nil and valid(peek_view) and span > 0 then
            local visible_meters = span * ((MapScale and MapScale.WORLD_SPAN_METERS) or 3155.52)
            local radius_meters = tonumber(Config.FogRevealMeters) or 20
            if visible_meters > 0 then
                local r = (radius_meters / visible_meters) * VIEW_PIXELS
                if r > 0.5 then
                    peek_left = VIEW_PIXELS * 0.5 - r
                    peek_size = r * 2.0
                end
            end
        end

        view_crumb("blit-mask")
        local ok_mask = blit_mask_with_peek(context, state.target, view_mask, u0, v0, span,
            peek_view, peek_left, peek_size)

        -- THE PEEK IS STAMPED IN VIEW SPACE, AT THE VIEW'S CENTRE, EVERY CROP. v0.23.26.
        --
        -- HER REPORT: "the ring around the player for the fog wasn't updating as often as
        -- I'd like. It should be the same rate as the player ring update rate, or maybe
        -- its the map update rate ... currently it's not synced so it's jumpy and jarring."
        --
        -- She is right and it is the map's rate. The peek is also drawn into the WORLD
        -- mask, and that mask only redraws once the player has moved past the move
        -- threshold -- max(radius x 0.12, 3.0) metres, so 3 m at her reveal of 20 -- and no
        -- faster than the 10 Hz redraw ceiling. The CROP, meanwhile, follows the pan at
        -- about a third of a view pixel. So the map slid smoothly while the circle's
        -- position updated in 3 m steps: it drifts off centre and snaps back, which is
        -- exactly "jumpy and jarring".
        --
        -- Stamping it here fixes both halves at once. The crop runs whenever the view
        -- moves, so the ring now moves with the map rather than with a movement budget --
        -- and because it is drawn at the CENTRE of the view target by construction, it can
        -- no longer be off centre at all. That also retires the "off centre" complaint,
        -- which turned out to be this same lag rather than a geometry error.
        --
        -- The world-space stamp is deliberately LEFT ALONE rather than removed. It is
        -- additive white over additive white, so drawing the circle twice saturates to the
        -- same pixels and costs nothing visible; and the world mask is what the rest of the
        -- pipeline has always been measured against. Removing it would be a second change
        -- riding along with this one, which is how a fix becomes two bugs.
        --
        -- Cost: one K2_DrawTexture on a 1024 target per crop, against the three blits
        -- already there.
        local ok_clear = false
        view_crumb("blit-clear")
        local clear_target_tex = ensure_view_target(context, "view_clear", CLEAR_BLACK)
        if clear_target_tex ~= nil and state.clear_painting ~= nil then
            ok_clear = blit_view(context, state.clear_painting, clear_target_tex, u0, v0, span)
        end
        -- OUR OWN COMPOSITE, behind its diagnostic until a run says modulate works.
        -- Costs four canvas draws on a view-sized target and only when asked for.
        local diag = tostring(Config.FogDiagnostic or "off")
        if diag == "composite" then
            local token_c = perf.Begin()
            compose_view(context)
            perf.End("fog.compose", token_c)
        elseif diag == "blends" then
            local token_b = perf.Begin()
            blend_probe(context)
            perf.End("fog.blendprobe", token_b)
        end
        view_crumb("refresh-done")
        perf.End("fog.view", token)

        state.view_refreshes = (state.view_refreshes or 0) + 1
        if not state.announced_view then
            state.announced_view = true
            -- Said once, out loud. This is the line that distinguishes "the crop ran"
            -- from "the crop is a no-op", and the previous approach logged neither.
            log(string.format(
                "Fog view crop: fogged=%s clear=%s mask=%s window=%.5f,%.5f span=%.5f target=%dpx",
                tostring(ok_paint), tostring(ok_clear), tostring(ok_mask),
                u0, v0, span, VIEW_PIXELS))
        end
        return ok_paint and ok_mask, nil
    end

    function fog.ViewRefreshes() return state.view_refreshes or 0 end

    -- The radius icons reveal at. One radius setting drives both.
    function fog.IconRevealMeters()
        if not enabled() then return nil end
        return (tonumber(Config.FogRevealMeters) or 50) * ICON_RADIUS_SCALE
    end

    -- NOTE, 2026-09-17. A distance-based icon fade was written here and removed the same
    -- hour, unused: the design doc's "icons fade in as you approach ... with fog on there
    -- are no edge-of-frame icons at all" was superseded by her decision that fog filters
    -- POIs by DISCOVERY instead, and that discovered POIs keep their edge indicators.
    -- Overlay/ObjectivePool.lua's eligible_target is where that lives now.
    --
    -- Written down rather than left in as "might be useful later", because this file spent
    -- three versions carrying an inverse-mask pass that did nothing and cost half of every
    -- redraw. Unused code that looks alive is the expensive kind.
    --
    -- IconRevealMeters() below is older than that decision and also has no caller. It is
    -- kept because the Summary reports it and the suite pins it, and because a second
    -- radius may yet be wanted -- but it is not doing anything today either.

    function fog.Enabled() return enabled() end

    -- v0.19.4. The render target's life belongs to the WIDGET TREE, not to this module.
    --
    -- Its only owner is the keeper Image that NativeWidget puts in the tree. A rebuild --
    -- which is what any settings change does -- tears that tree down and with it the
    -- keeper, leaving the target unreferenced; the next Build then cleared and drew into
    -- it. Her 15:50:19 log is that exact sequence: "Tick stage=teardown", then
    -- "Tick stage=build", then nothing at all. The process was gone before the first fog
    -- crumb of the new build could be written.
    --
    -- So the target is dropped at teardown and a fresh one is made by the next Build,
    -- owned by that build's keeper. Discovery is deliberately KEPT: it belongs to the
    -- world, not the tree, and keeping it means the rebuilt mask has the player's real
    -- regions on its first frame instead of failing open to white and flashing.
    -- The fog overlay's mask: white where fog belongs, black where the player has been.
    function fog.InverseTarget()
        return valid(state.inverse_target) and state.inverse_target or nil
    end

    function fog.DropTarget()
        state.target = nil
        state.inverse_target = nil
        -- v0.22.2: the view targets go the same way, and for the same reason. They are
        -- owned by the keeper Images in the tree that is being torn down, so holding the
        -- handles past this point is holding pointers to objects with no owner. That
        -- exact omission crashed v0.19.x three times.
        state.view_painting = nil
        state.view_mask = nil
        state.view_clear = nil
        state.view_white = nil
        state.view_masked_clear = nil
        state.view_white_ready = false
        state.clear_painting = nil
        state.announced_view = false
        state.announced_compose = false
        state.announced_probe = false
        state.view_probe = nil
        state.library = nil
        state.last_center_x, state.last_center_y = nil, nil
        state.last_radius_meters = nil
        state.next_redraw_at = nil
        state.drawing = false
        -- v0.19.5: the textures are pinned by keeper Images inside the tree that is going
        -- away, so their pins die with it. Keeping the handles would be keeping pointers
        -- to objects with no owner, which is the bug this pair of releases is about.
        texture_cache = {}
        state.textures_warm = false
        pin_texture = nil
    end

    -- Invariant 0: nothing live is retained across a world change. The target, the
    -- library and every cached texture belong to the world they were resolved in, so
    -- they are dropped without being read.
    function fog.Forget()
        state.target = nil
        state.inverse_target = nil
        state.view_painting = nil
        state.view_mask = nil
        state.view_clear = nil
        state.view_white = nil
        state.view_masked_clear = nil
        state.view_white_ready = false
        state.clear_painting = nil
        state.announced_view = false
        state.announced_compose = false
        state.announced_probe = false
        state.view_probe = nil
        state.view_refreshes = 0
        state.library = nil
        state.held = nil
        state.held_signature = nil
        state.last_center_x, state.last_center_y = nil, nil
        state.last_radius_meters = nil
        state.next_discovery_at = nil
        state.next_redraw_at = nil
        state.drawing = false
        state.announced_bind = false
        state.announced_draw = false
        -- THE PEEK STATE MACHINE GOES BACK TO ITS OPENING POSITION. A new world has a new
        -- held set and a new position, and the watermark is metres walked in the world
        -- that just ended. Starting ON is the safe half of the fail-closed rule: the peek
        -- switches itself off on the first update that finds revealed ground, whereas
        -- carrying `false` across a load would leave it off in fog until she moved.
        state.peek_active = true
        state.fog_walk_mark = nil
        state.revealed_here = nil
        state.reveal_test_x, state.reveal_test_y = nil, nil
        state.reveal_memo = {}
        state.reveal_memo_count = 0
        texture_cache = {}
        state.textures_warm = false
        item_class_cache = nil
        manager_cache = nil
        -- The trail is a memory of THIS world. Carrying it across a load would draw a
        -- clear path through ground she has never walked in the world she is now in.
        state.trail = {}
        state.walked_meters = 0.0
        state.trail_marks_drawn = 0
        state.trail_last_x, state.trail_last_y = nil, nil
    end

    function fog.Status()
        return {
            enabled = enabled(),
            bound = valid(state.target),
            redraws = state.redraws,
            discoveryPolls = state.discovery_polls,
            failures = state.failures,
            disabled = state.disabled_reason,
            regions = state.held_signature,
            peekPixels = peek_pixels(tonumber(Config.FogRevealMeters) or 50),
            iconRevealMeters = fog.IconRevealMeters(),
            trailEnabled = trail_enabled(),
            trailMarks = #state.trail,
            trailMarksDrawn = tonumber(state.trail_marks_drawn) or 0,
            trailWalkedMeters = state.walked_meters,
            trailStampPixels = peek_pixels(trail_radius_meters()),
            trailForgetMeters = trail_forget_meters(),
        }
    end

    -- One line for the summary hotkey and the startup banner. Short on purpose.
    -- CAN WE ASK THE MASK WHETHER SHE IS ON REVEALED GROUND? v0.23.45, a PROBE.
    --
    -- Her report: in areas she has already uncovered, icons are gated and fade in as she
    -- approaches, which they should not -- there is no fog there to hide them. Her rule:
    -- "If I'm in a completely revealed map tile there is no need for peek to run."
    --
    -- Nothing in the game answers "is this world position revealed". The eleven fragments
    -- are irregular textures with no world bounds in DT_MapTiles, in BP_WorldMapSettings
    -- or anywhere else I could find, and held_regions() only says which map-piece ITEMS
    -- she owns, which is not spatial. The one exact source is the mask we draw ourselves.
    --
    -- So this reads it back, and it is a PROBE rather than a feature because two things
    -- are genuinely unknown and this project has paid for assuming either:
    --   1. COST. ReadRenderTargetPixel stalls the render thread to fetch one texel. It is
    --      sampled here rather than guessed at, over REPEATS, and reported with min/avg/max
    --      so the state machine can be budgeted rather than hoped for (invariant 0l).
    --   2. CONTAMINATION, and this one is the reason the probe reads more than one point.
    --      The peek and the trail are stamped INTO this same mask, so a read at the player
    --      is white whether or not the GROUND is revealed -- the peek put it there. The
    --      offsets below step outside the peek radius so the difference is visible in the
    --      log instead of being reasoned about. If near reads white while far reads black,
    --      the contamination is real and the state machine needs a discovery-only source.
    --
    -- Costs nothing when the diagnostic is off: one string compare in Summary.
    local READBACK_SAMPLES = 20

    local function readback_probe()
        local library = rendering_library()
        if library == nil then return "readback=no-library" end
        if not valid(state.target) then return "readback=no-target" end
        local px, py = state.trail_last_x, state.trail_last_y
        if px == nil or py == nil then return "readback=no-player-position" end
        -- The world context NativeWidget already retains and passes to every fog call.
        -- Read rather than stashed: one owner for that handle, and this probe does not
        -- get to be the reason a second one exists (invariant 0).
        local context = shared ~= nil and shared.controller or nil
        if context == nil or not valid(context) then return "readback=no-context" end

        local span = (MapScale and MapScale.WORLD_SPAN_METERS) or 3155.52
        local peek_m = math.max(1.0, tonumber(Config.FogRevealMeters) or 20)
        -- Two peek radii out is comfortably outside the stamped circle, and still close
        -- enough to be the same ground she is standing on.
        local step = (peek_m * 2.0) / span

        local function sample(u, v, label)
            u = math.max(0.0, math.min(1.0, u))
            v = math.max(0.0, math.min(1.0, v))
            local x = math.floor(u * (TARGET_PIXELS - 1))
            local y = math.floor(v * (TARGET_PIXELS - 1))
            local ok, colour = pcall(function()
                return library:ReadRenderTargetPixel(context, state.target, x, y)
            end)
            if not ok or colour == nil then
                return label .. "=refused"
            end
            -- FLinearColor comes back 0..1 and an FColor 0..255; report whichever it is
            -- rather than assuming, because "it returned zeros" and "it returned 0.0 to 1.0
            -- and I printed it as an int" look identical in a log.
            local r = nil
            pcall(function() r = tonumber(colour.R) end)
            if r == nil then return label .. "=unreadable" end
            return string.format("%s=%.3f", label, r)
        end

        local started = clock()
        local first = sample(px, py, "atPlayer")
        local one_ms = (clock() - started) * 1000.0

        local worst, total = 0.0, 0.0
        for _ = 1, READBACK_SAMPLES do
            local t0 = clock()
            sample(px, py, "x")
            local ms = (clock() - t0) * 1000.0
            total = total + ms
            if ms > worst then worst = ms end
        end

        return string.format(
            "readback=%s %s %s %s centre=%s firstMs=%.3f avgMs=%.3f maxMs=%.3f n=%d "
            .. "peekM=%.0f (255=revealed-or-peeked, 0=fogged; if atPlayer is high and the "
            .. "offsets are low the peek is contaminating the read)",
            first,
            sample(px + step, py, "east"), sample(px - step, py, "west"),
            sample(px, py + step, "south"),
            sample(0.5, 0.5, "c"),
            one_ms, total / READBACK_SAMPLES, worst, READBACK_SAMPLES, peek_m)
    end

    function fog.Summary()
        if not enabled() then return "fog=off" end
        if diagnostic() == "readback" then return readback_probe() end
        if LAYER_OVERRIDE[diagnostic()] then
            return string.format("fog=on DIAGNOSTIC=%s redraws=%d bound=%s",
                diagnostic(), state.redraws, tostring(valid(state.target)))
        end
        -- THE TRAIL REPORTS ITSELF. v0.23.6.
        --
        -- "The trail did not draw" has three causes that look identical in a screenshot:
        -- no marks were laid, marks were laid but all of them had faded past the draw
        -- floor, or marks were stamped and are too small or too dim to see. marks/walked
        -- separates the first, drawn separates the second, stamp separates the third.
        -- One string.format when a hotkey or a plan asks for it, never per frame
        -- (invariant 0l).
        local trail = "trail=off"
        if trail_enabled() then
            -- THE LAST POSITION THE FOG ACTUALLY SAW. v0.23.16.
            --
            -- The square's west leg reported the same marks, the same walked distance and
            -- even the same discovery poll count as the north leg before it -- so either
            -- the east/west offset never reached fog.Update, or it reached it and the
            -- sampler ignored the x axis. Those need different fixes and the picture
            -- cannot tell them apart, so the position is reported directly. It is the
            -- number trail_sample stores every Update, before any gate.
            trail = string.format(
                "trail=on marks=%d drawn=%d walked=%.0fm stamp=%.1fpx forget=%.0fm "
                .. "sawXY=%s,%s",
                #state.trail, tonumber(state.trail_marks_drawn) or 0,
                tonumber(state.walked_meters) or 0.0,
                peek_pixels(trail_radius_meters()), trail_forget_meters(),
                state.trail_last_x ~= nil and string.format("%.5f", state.trail_last_x) or "nil",
                state.trail_last_y ~= nil and string.format("%.5f", state.trail_last_y) or "nil")
        end
        -- v0.23.51. "The peek stopped" is now a legitimate outcome rather than a fault,
        -- so the summary has to say which one it is: whether the grids answered at all,
        -- what they said about the ground under her, and how far she still has to walk
        -- before rule 3 lets go.
        local ground = " peekState=always-on(no-baked-grids)"
        if revealed_ground_available() then
            local remaining = ""
            if state.peek_active ~= false and state.fog_walk_mark ~= nil then
                remaining = string.format(" clearIn=%.0fm",
                    math.max(0.0, trail_forget_meters() - (state.walked_meters - state.fog_walk_mark)))
            end
            ground = string.format(" peek=%s ground=%s%s",
                state.peek_active ~= false and "on" or "off",
                state.revealed_here == nil and "unknown"
                    or (state.revealed_here == true and "revealed" or "fog"),
                remaining)
        end
        return string.format("fog=on radius=%dm peek=%.1fpx redraws=%d polls=%d failures=%d bound=%s %s%s" .. ground,
            math.floor(tonumber(Config.FogRevealMeters) or 50),
            peek_pixels(tonumber(Config.FogRevealMeters) or 50),
            state.redraws, state.discovery_polls, state.failures,
            tostring(valid(state.target)), trail,
            state.disabled_reason ~= nil and (" disabled=" .. state.disabled_reason) or "")
    end

    fog.TARGET_PIXELS = TARGET_PIXELS
    fog.ICON_RADIUS_SCALE = ICON_RADIUS_SCALE
    fog.DISCOVERY_POLL_SECONDS = DISCOVERY_POLL_SECONDS
    fog.REDRAW_MIN_SECONDS = REDRAW_MIN_SECONDS
    fog.PeekPixelsForTest = peek_pixels
    fog.MoveThresholdForTest = move_threshold

    return fog
end

return Factory
