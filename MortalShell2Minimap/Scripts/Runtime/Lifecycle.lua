-- Owns the scheduler, visibility policy, LoadMap quarantine, settled-world
-- release, and coordination between the renderer and ModUI boundary.

local Factory = {}

function Factory.New(ctx)
    local state = assert(ctx.State, "Runtime.Lifecycle requires State")
    local Config = assert(ctx.Config, "Runtime.Lifecycle requires Config")
    local Object = assert(ctx.Object, "Runtime.Lifecycle requires Core.Object")
    local Renderer = assert(ctx.Renderer, "Runtime.Lifecycle requires Map.NativeWidget")
    local UI = assert(ctx.UI, "Runtime.Lifecycle requires UI.ModUI")
    local global_runtime = assert(ctx.GlobalRuntime, "Runtime.Lifecycle requires GlobalRuntime")
    local instance_generation = assert(ctx.InstanceGeneration, "Runtime.Lifecycle requires InstanceGeneration")
    local log = assert(ctx.Log, "Runtime.Lifecycle requires Log")
    local Perf = type(ctx.Perf) == "table" and ctx.Perf
        or { Begin = function() return nil end, End = function() end, Mark = function() end,
             Tick = function() return false end }

    local runtime = {}

    -- Every ctx module that constructs UMG widgets into state.retained.frame, in the order
    -- they are dropped when that frame is torn down. Adding a widget-owning module without
    -- adding it here is the v0.14.0 settings-rebuild crash; Validation/Regression.lua
    -- fails if this list and the set of modules with DropWorldReferencesUnread diverge.
    -- v0.18.0: Combat constructs nothing, but it writes a render transform and an
    -- opacity to the root canvas and remembers what it wrote; a rebuilt root starts
    -- from scratch, so it forgets with the rest.
    local WIDGET_OWNERS = { "TrackerPool", "ObjectivePool", "LocalPool", "TrailPool",
        "Labels", "DungeonView", "Frame", "Combat" }
    runtime.WIDGET_OWNERS = WIDGET_OWNERS

    -- v0.18.40: how long a rebuild-flagged setting change waits for the next one before the
    -- widget tree is actually torn down. Long enough that a held arrow key (roughly 30
    -- repeats a second) collapses to a single rebuild on release, short enough that one
    -- deliberate press still lands as soon as the finger leaves the key. A rebuild costs
    -- about 700 ms of game thread, so the ratio this buys back is the whole point.
    local REBUILD_DEBOUNCE_SECONDS = 0.30
    runtime.REBUILD_DEBOUNCE_SECONDS = REBUILD_DEBOUNCE_SECONDS

    -- v0.18.29 CRASH BREADCRUMB, TICK LEVEL. Her 2026-09-15 crashes (21:09:00Z and
    -- 21:22:34Z, reproducible at the same spot) both fault inside UE4SS at +0x36562e with
    -- an identical 25-frame stack -- the same reflection family as the v0.11.3 crash at
    -- +0x367445 -- and the discovery breadcrumbs cannot name the call, because the LAST
    -- Lua line differed between the two runs and the per-label budget was actively
    -- suppressing lines ("trace suppressed ... after=120") right where the answer is.
    --
    -- A tick is a dozen stages and only four of them log anything at all, so a crash in
    -- any of the others is invisible. This names the stage as it starts: the last one in
    -- the log is the one that died. Off unless LocalDiscoveryTrace is on, and when it is
    -- off this costs one boolean test per stage.
    local function stage(name)
        if Config.LocalDiscoveryTrace == true then
            print("[MortalShell2Minimap] Tick stage=" .. tostring(name) .. "\n")
        end
        return Perf.Begin()
    end

    local function pose_delay()
        local hz = math.max(5, math.min(60, math.max(
            tonumber(Config.PanUpdatesPerSecond) or 30,
            tonumber(Config.ArrowUpdatesPerSecond) or 30)))
        local exact = (1000.0 / hz) + (tonumber(state.pose_delay_remainder) or 0.0)
        local delay = math.max(1, math.floor(exact))
        state.pose_delay_remainder = exact - delay
        return delay
    end

    -- Every deferred callback in the mod runs through here and is timed as
    -- schedule.<label>. The section name is built once at scheduling time, never in
    -- the callback, so the timed path allocates nothing.
    function runtime.Schedule(delay_ms, callback, label)
        if global_runtime.generation ~= instance_generation or type(callback) ~= "function" then
            return false
        end
        if type(ExecuteInGameThreadWithDelay) ~= "function" then return false end
        local section = "schedule." .. tostring(label or "unlabelled")
        local ok = pcall(ExecuteInGameThreadWithDelay,
            math.max(1, math.floor(tonumber(delay_ms) or 1)), function()
                if global_runtime.generation ~= instance_generation then return end
                local token = Perf.Begin()
                callback()
                Perf.End(section, token)
            end)
        return ok
    end

    local function controller_menu_signal(controller)
        local shown = false
        pcall(function() shown = Object.AsBoolean(controller.bShowMouseCursor) end)
        if shown then return true end
        pcall(function() shown = Object.AsBoolean(controller.bEnableVirtualCursor) end)
        if shown then return true end
        local ok_menu, in_menu = pcall(controller.IsInGameMenu, controller)
        return ok_menu and Object.AsBoolean(in_menu)
    end

    -- v0.18.39 (YoungThaddeus, mods/497 posts 2026-09-16: "quite distracting having no map
    -- for half a second"). He was being generous. Her own log times the gap twice:
    -- close-settling 02:27:35.6266 -> close-settled 02:27:36.6313 is 1004.7 ms, and
    -- 02:34:05.9300 -> 02:34:06.9387 is 1008.7 ms. ModUI's settle_ms is 1000.
    --
    -- The settle window conflated two different things. Not OBSERVING game objects during
    -- a native menu close is the real safety requirement, and it stands. Staying HIDDEN was
    -- only ever a consequence of it, and nothing needs it: Renderer.SetVisibility writes one
    -- property on the mod's own retained UUserWidget inside a pcall (Map/NativeWidget.lua)
    -- and reads nothing from the game, so it is safe in exactly the window where reading a
    -- PlayerController is not.
    --
    -- So the two are split. "settling" shows the map again while the tick still returns
    -- early and observes nothing, which means the map comes back with the rest of the HUD
    -- and holds its last frame for the rest of the cushion. "active" (the menu is genuinely
    -- on screen) and "quarantined" (LoadMap-pre, the world is going away and the widget is
    -- about to be invalid) both still hide.
    local function native_menu_hides_map()
        if not state.native_menu_gate_available then return false end
        if not state.native_menu_active then return false end
        return state.native_menu_state ~= "settling"
    end

    local function should_hide()
        if not Config.Enabled then return true, "disabled" end
        -- Minimap's own settings are a live-preview surface. Keep rendering so
        -- every visual setting can be judged immediately; another mod's shared
        -- shell remains a normal visibility blocker.
        -- v0.18.46 (her 04:50 video, MEASURED): our own close is still our own window.
        -- CloseSettings sets settings_open false and settings_closing true on the same line,
        -- and modui_shell_active is `settings_open or settings_closing`, so for the whole of
        -- the close guard's 225 ms quarantine this fell through to the "modui" branch and
        -- hid a map that had been deliberately visible for the entire session. Four closes
        -- in her capture, 317, 317, 333 and 333 ms, and the log gives the shape exactly:
        -- session closing at 04:50:54.568 is the frame the map goes, session closed at
        -- 54.787 is 219 ms later (the guard), and the map is back 115 ms after that when the
        -- native-menu gate reports settling and v0.18.39's split shows it again.
        --
        -- This is the same mistake v0.18.39 fixed one layer up, in the same shape: a
        -- transition that needs care about OBSERVATION was also being used to decide
        -- VISIBILITY, and nothing needed the second part. Renderer.SetVisibility writes one
        -- property on the mod's own retained widget inside a pcall and reads nothing from
        -- the game, so keeping the map up through our own close is safe for exactly the
        -- reason it was safe through the menu-close cushion.
        --
        -- Another mod's shell still hides us: settings_open and settings_closing are set
        -- only by this mod's own CloseSettings, and a foreign shell reaches
        -- modui_shell_active through the shared host's session/shell fields instead.
        if state.settings_open or state.settings_closing then
            return false, "settings-preview"
        end
        if state.modui_shell_active then return true, "modui" end
        if native_menu_hides_map() then return true, "native-menu" end
        -- The hook gate protects the dangerous opening transition, while the
        -- controller signal remains the long-lived visibility source. The latter
        -- also guarantees recovery after a bounded hook lease expires.
        if controller_menu_signal(state.controller) then return true, "menu" end
        local cinematic = false
        pcall(function() cinematic = Object.AsBoolean(state.controller.bCinematicMode) end)
        if cinematic then return true, "cinematic" end
        -- v0.18.0 "Hide in combat": the combat module has already faded the map to
        -- nothing by the time it asks; collapsing it here also stops the overlay work.
        if type(ctx.Combat) == "table" and type(ctx.Combat.WantsHide) == "function"
            and ctx.Combat.WantsHide() == true then
            return true, "combat"
        end
        return false, "gameplay"
    end

    local function runtime_tick_body()
        state.step_count = state.step_count + 1

        if state.world_quarantined or not state.world_ready then return 250 end

        local visibility_due = not state.visible or state.step_count % 3 == 1
        if visibility_due then
            local token = stage("ui_read")
            UI.ReadActions()
            UI.ReadShellState()
            Perf.End("tick.ui_read", token)
        end

        -- The shared host's hook callbacks publish primitive-only menu state before
        -- native UI transitions. Once active, hide exactly once and perform no
        -- PlayerController, player, tracker, objective, or map-widget observation
        -- until the host has reported a settled close.
        if state.native_menu_gate_available and state.native_menu_active then
            -- v0.18.39: the observation quarantine is unchanged -- this still returns before
            -- any PlayerController, player, tracker, objective or map-widget read. Only the
            -- visibility decision moved: see native_menu_hides_map above.
            local hide = native_menu_hides_map()
            if state.visible == hide then
                Renderer.SetVisibility(hide, hide and "native-menu" or "native-menu-settling")
            end
            return 100
        end

        -- v0.18.40 (her 03:40 crash bundle, MEASURED): every rebuild-flagged row used to tear
        -- the widget tree down on the very next tick, so holding an arrow on Size, Position X
        -- or Position Y meant one full teardown and rebuild PER STEP. Her run stepped
        -- size 300/320 five times in three minutes; the [PERF] window covering two of those
        -- rebuilds put the minimap at busyPct=23.27 against 1.49 in the window before it, and
        -- the sections name where it went: native.find 670 ms over 173 calls (102 of them
        -- spikes), schedule.local.asset-step 374 ms, schedule.objective.asset-step 283 ms,
        -- schedule.audit.step 126 ms. About 700 ms of game thread per rebuild, because a
        -- rebuild re-resolves every asset and re-sweeps the world for the widget classes.
        --
        -- So the request is COALESCED rather than obeyed. Each tick that sees the flag
        -- consumes it and pushes the deadline out; the teardown runs once the user stops
        -- stepping. Ten steps cost one rebuild instead of ten. The old widget keeps
        -- rendering at its old size in the meantime, which is strictly better than the
        -- teardown flash it used to get, and the visible change lands one debounce late.
        --
        -- This is not the crash fix and is not claimed as one: the 0x40 access violation has
        -- five instances now, four of them on builds predating any of this, and the faulting
        -- call is still unnamed. It is the fix for the COST, and it removes the churn that
        -- every one of those five crashes happened during.
        if state.rebuild_requested then
            state.rebuild_requested = false
            local now = tonumber(os.clock())
            if now == nil then
                -- No usable clock: fail open to the old immediate behaviour rather than
                -- retaining a request that can never come due.
                state.rebuild_deadline = nil
                state.rebuild_coalesced = 0
            else
                if state.rebuild_deadline == nil then state.rebuild_coalesced = 0 end
                state.rebuild_coalesced = math.floor(state.rebuild_coalesced or 0) + 1
                state.rebuild_deadline = now + REBUILD_DEBOUNCE_SECONDS
            end
        end

        -- Still settling means fall straight through to the ordinary tick below, which keeps
        -- rendering the current widget. That tick is the live preview, and freezing it here
        -- would make stepping a setting look worse than the thing this replaces.
        local rebuild_due = false
        if state.rebuild_deadline ~= nil then
            local now = tonumber(os.clock())
            rebuild_due = now == nil or now >= state.rebuild_deadline
        end

        if rebuild_due then
            local absorbed = math.floor(state.rebuild_coalesced or 0)
            state.rebuild_deadline = nil
            state.rebuild_coalesced = 0
            if absorbed > 1 then
                -- "observed", not "presses": rebuild_requested is a latch, so two steps
                -- between two ticks are seen once. This is the floor on what was absorbed.
                log(string.format(
                    "Rebuild coalesced observed=%d into=1 debounceMs=%d reason=settings-change",
                    absorbed, math.floor(REBUILD_DEBOUNCE_SECONDS * 1000)))
            end
            -- Every module that parents widgets into state.retained.frame must be dropped
            -- when that frame is torn down. TeardownStable removes the whole widget from
            -- the viewport, so the old frame's children become garbage; a module that kept
            -- its references goes on writing to them until the GC actually collects, and
            -- the write after that faults.
            --
            -- v0.14.0 (2026-09-13 11:15) is the run that proved it: stepping the map-size
            -- slider produced eight "Stable teardown reason=settings-change" cycles, the
            -- dungeon view stopped drawing after the first one, and the process died with
            -- 0xc0000005 reading a freed address under 31 UE4SS reflection frames beneath
            -- FEngineLoop::Tick. Only three of the six widget owners were on this list.
            -- TrailPool and Labels had the same exposure and had simply been lucky.
            for _, owner in ipairs(WIDGET_OWNERS) do
                local module = ctx[owner]
                if type(module) == "table"
                    and type(module.DropWorldReferencesUnread) == "function" then
                    module.DropWorldReferencesUnread()
                end
            end
            local token = stage("teardown")
            Renderer.TeardownStable("settings-change")
            Perf.End("tick.teardown", token)
            state.build_retry_countdown = 0
            state.build_retry_failures = 0
            return 100
        end

        -- v0.18.39 (her 02:57 bundle, measured): this retry used to be flat. The countdown
        -- was set to 1 every time, so with a 500 ms return the tick attempted a full
        -- Renderer.Build() once a SECOND, forever, with no backoff and no cap. Each attempt
        -- calls resolve_player(), which is a FindFirstOf world sweep at ~6.3 ms, so an
        -- unbuildable world cost a 7 ms game-thread hitch every second for as long as it
        -- lasted -- one dropped frame per second, which is exactly what "slight, annoying
        -- stuttering" feels like. Her log has 80 build attempts and 85 sweeps in 80 seconds,
        -- every one of them a [PERF] spike, and the minimap never came back.
        --
        -- The trigger was a world load into a level with nothing in it (discovery seed
        -- found=0, area name volumes=0 beacons=0, area map unresolved). A world with no
        -- PlayerController one second later almost certainly still has none a second after
        -- that, so the ladder doubles: 1 s, 2 s, 4 s, 8 s, capped at 16 s. A world that
        -- becomes buildable is announced by the lifecycle (world release, teardown), and
        -- every one of those paths resets the ladder, so backing off costs no latency on
        -- the case that matters.
        if not state.built then
            if state.build_retry_countdown > 0 then
                state.build_retry_countdown = state.build_retry_countdown - 1
                return 500
            end
            local token = stage("build")
            local built_now = Renderer.Build()
            Perf.End("tick.build", token)
            if built_now then
                state.build_retry_failures = 0
                state.build_retry_countdown = 1
            else
                -- Ticks to skip before the next attempt, each worth 500 ms: 1, 3, 7, 15, 31.
                local failures = math.floor(tonumber(state.build_retry_failures) or 0) + 1
                state.build_retry_failures = failures
                local skip = math.floor(math.min((2 ^ math.min(failures, 5)) - 1, 31))
                state.build_retry_countdown = skip
                -- One line per step of the ladder, not one per attempt. If a bundle shows
                -- this climbing to 31 the world was never going to build and Build's own
                -- "Build waiting:" status says why.
                if failures <= 5 then
                    log(string.format(
                        "Build retry backing off attempt=%d nextDelayMs=%d reason=%s",
                        failures, (skip + 1) * 500,
                        tostring(state.last_build_status or "unreported")))
                end
            end
            if built_now and type(ctx.POI) == "table"
                and type(ctx.POI.OnRendererReady) == "function" then
                token = stage("renderer_ready")
                ctx.POI.OnRendererReady()
                Perf.End("tick.renderer_ready", token)
            end
            return state.built and pose_delay() or 500
        end

        if visibility_due then
            local token = stage("visibility")
            local hide, reason = should_hide()
            Renderer.SetVisibility(hide, reason)
            Perf.End("tick.visibility", token)
        end
        -- v0.18.0 combat look. Runs hidden or not: the poll that ends a combat has to
        -- fire while the map is collapsed for it, and a fade in progress keeps its
        -- clock through a menu. Cheap when nothing moves (Runtime/CombatState.lua).
        if type(ctx.Combat) == "table" and type(ctx.Combat.Update) == "function" then
            local token = stage("combat")
            ctx.Combat.Update()
            Perf.End("tick.combat", token)
        end
        if not state.visible then return 100 end

        local token = stage("pose")
        local pose_ok, geometry_changed, pan_due = Renderer.UpdatePose()
        Perf.End("tick.pose", token)
        if not pose_ok then return pose_delay() end
        local performance = state.performance or {}
        state.performance = performance
        local overlay_due = geometry_changed or state.overlay_refresh_requested
        local local_due = overlay_due or state.local_overlay_refresh_requested
            or (state.area_map_available == false and pan_due == true)
        local projection_context = nil
        if overlay_due or local_due then
            if type(ctx.TrackerProjection) == "table"
                and type(ctx.TrackerProjection.Prepare) == "function" then
                token = stage("projection")
                projection_context = ctx.TrackerProjection.Prepare(
                    Config.Size, Config.ZoomMeters, state.map_rotation_angle,
                    Config.MapShape, Config.EdgeVisibility)
                Perf.End("tick.projection", token)
            end
        end
        if overlay_due then
            local center_x = state.map_center_world_x or state.player_world_x
            local center_y = state.map_center_world_y or state.player_world_y
            if type(ctx.TrackerPool) == "table"
                and type(ctx.TrackerPool.UpdatePlayer) == "function" then
                token = stage("trackers")
                ctx.TrackerPool.UpdatePlayer(center_x, center_y, projection_context)
                Perf.End("tick.trackers", token)
            end
            if type(ctx.ObjectivePool) == "table"
                and type(ctx.ObjectivePool.UpdatePlayer) == "function" then
                token = stage("objectives")
                ctx.ObjectivePool.UpdatePlayer(center_x, center_y, projection_context)
                Perf.End("tick.objectives", token)
            end
            state.overlay_refresh_requested = false
            performance.overlay_update_runs =
                (tonumber(performance.overlay_update_runs) or 0) + 1
        else
            performance.overlay_update_skips =
                (tonumber(performance.overlay_update_skips) or 0) + 1
        end
        if local_due and type(ctx.LocalPool) == "table"
            and type(ctx.LocalPool.UpdatePlayer) == "function" then
            local local_x, local_y
            if state.area_map_available == false then
                local_x, local_y = state.player_world_x, state.player_world_y
            else
                local_x = state.map_center_world_x or state.player_world_x
                local_y = state.map_center_world_y or state.player_world_y
            end
            token = stage("local")
            ctx.LocalPool.UpdatePlayer(local_x, local_y, projection_context)
            Perf.End("tick.local", token)
            state.local_overlay_refresh_requested = false
        end
        -- v0.11.0 footstep trail: sampling is a squared-distance test every pose
        -- tick; drawing only runs when a crumb was added or the map moved.
        if type(ctx.TrailPool) == "table" and type(ctx.TrailPool.Sample) == "function" then
            token = stage("trail")
            local added = ctx.TrailPool.Sample(state.player_world_x, state.player_world_y)
            if added or overlay_due or local_due or ctx.TrailPool.dirty == true then
                local trail_x = state.map_center_world_x or state.player_world_x
                local trail_y = state.map_center_world_y or state.player_world_y
                if state.area_map_available == false then
                    trail_x, trail_y = state.player_world_x, state.player_world_y
                end
                ctx.TrailPool.UpdatePlayer(trail_x, trail_y, projection_context)
            end
            Perf.End("tick.trail", token)
        end
        if (overlay_due or pan_due) and type(ctx.AreaName) == "table"
            and type(ctx.AreaName.Resolve) == "function" then
            -- Pure Lua over cached numbers, and it early-outs unless the player has
            -- actually moved. No native call, no scan.
            token = stage("areaname")
            ctx.AreaName.Resolve(state.player_world_x, state.player_world_y,
                state.player_world_z)
            Perf.End("tick.areaname", token)
        end
        if (overlay_due or pan_due) and type(ctx.Labels) == "table"
            and type(ctx.Labels.Update) == "function" then
            token = stage("labels")
            ctx.Labels.Update()
            Perf.End("tick.labels", token)
        end
        -- v0.14.0 dungeon view. This is the only place the scene capture is issued, and
        -- it matters that it is here: the tick is already a game-thread callback, and
        -- calling CaptureScene from any other thread crashes the renderer outright
        -- (probe v0.1.0, 3/3). See Map/DungeonView.lua and ARCHITECTURE.txt invariant 0n.
        -- The stage runs every tick because it owns its own rate limiter and has to see
        -- engagement changes promptly; the capture itself is gated inside.
        if type(ctx.DungeonView) == "table"
            and type(ctx.DungeonView.Update) == "function" then
            token = stage("dungeon")
            ctx.DungeonView.Update(pan_due)
            Perf.End("tick.dungeon", token)
        end
        return pose_delay()
    end

    -- The pose loop. `tick` is the whole step; `tick.interval` is the spacing between
    -- steps (a max far above 1000/panHz is a hitch, ours or the game's). The profiler
    -- itself is synced and ticked here, so this is also where a summary is emitted.
    local function runtime_tick()
        if global_runtime.generation ~= instance_generation then return 1000 end
        if type(ctx.PerfSync) == "function" then ctx.PerfSync("setting") end
        Perf.Mark("tick.interval")
        local token = Perf.Begin()
        local delay = runtime_tick_body()
        Perf.End("tick", token)
        Perf.Tick()
        return delay
    end

    local scheduled_step
    local function schedule_next(delay_ms)
        if global_runtime.generation ~= instance_generation then return false end
        if type(ExecuteInGameThreadWithDelay) == "function" then
            local ok = pcall(ExecuteInGameThreadWithDelay,
                math.max(1, math.floor(delay_ms or 33)), scheduled_step)
            return ok
        end
        return false
    end

    scheduled_step = function()
        if global_runtime.generation ~= instance_generation then return end
        local ok, next_delay = pcall(runtime_tick)
        if not ok then
            local error_text = tostring(next_delay)
            if error_text ~= state.last_error then log("Runtime error: " .. error_text) end
            state.last_error = error_text
            next_delay = 250
        else
            state.last_error = nil
        end
        schedule_next(tonumber(next_delay) or 33)
    end

    local function release_world_after_settle(epoch, reason)
        local callback = function()
            if global_runtime.generation ~= instance_generation or state.lifecycle_epoch ~= epoch then return end
            if state.world_ready and not state.world_quarantined then return end
            state.world_quarantined = false
            state.world_ready = true
            state.build_retry_countdown = 0
            -- v0.18.39: a released world is the event the backoff ladder exists to wait
            -- for, so it starts again at one attempt per second here.
            state.build_retry_failures = 0
            UI.PublishHotkey(true, reason)
            if type(ctx.POI) == "table" and type(ctx.POI.OnWorldReleased) == "function" then
                ctx.POI.OnWorldReleased(reason)
            end
            log("World released after settle; build may begin reason=" .. tostring(reason))
        end
        if type(ExecuteInGameThreadWithDelay) == "function" then
            pcall(ExecuteInGameThreadWithDelay, 5000, function()
                local token = Perf.Begin()
                callback()
                Perf.End("lifecycle.world-release", token)
            end)
        else
            callback()
        end
    end

    local function load_map_pre()
        if global_runtime.generation ~= instance_generation then return end
        local token = Perf.Begin()
        state.lifecycle_epoch = state.lifecycle_epoch + 1
        state.world_quarantined = true
        state.world_ready = false
        UI.CloseSettings("load-map-pre", true)
        UI.PublishHotkey(false, "load-map-pre")
        if type(ctx.POI) == "table" and type(ctx.POI.OnLoadMapPre) == "function" then
            ctx.POI.OnLoadMapPre()
        end
        Renderer.DropWorldReferencesUnread()
        log("LoadMap PRE: old-world references dropped unread; rendering and hotkey polling quarantined")
        Perf.End("lifecycle.load-map-pre", token)
    end

    local function load_map_post()
        if global_runtime.generation ~= instance_generation then return end
        release_world_after_settle(state.lifecycle_epoch, "load-map-post")
    end

    function runtime.Start()
        global_runtime.scheduled_step = scheduled_step
        global_runtime.load_map_pre = load_map_pre
        global_runtime.load_map_post = load_map_post

        if type(RegisterLoadMapPreHook) == "function" then
            local ok, hook_error = pcall(RegisterLoadMapPreHook, load_map_pre)
            state.load_map_pre_ready = ok
            if not ok then log("LoadMap PRE hook failed: " .. tostring(hook_error)) end
        else
            log("LoadMap PRE hook unavailable; InitGameState fallback transition guard is active")
        end

        if type(RegisterLoadMapPostHook) == "function" then
            local ok, hook_error = pcall(RegisterLoadMapPostHook, load_map_post)
            if not ok then log("LoadMap POST hook failed: " .. tostring(hook_error)) end
        end

        if type(RegisterInitGameStatePostHook) == "function" then
            pcall(RegisterInitGameStatePostHook, function()
                if global_runtime.generation ~= instance_generation then return end
                if not state.load_map_pre_ready and state.world_ready and not state.world_quarantined then
                    state.lifecycle_epoch = state.lifecycle_epoch + 1
                    state.world_quarantined = true
                    state.world_ready = false
                    UI.CloseSettings("init-game-state-transition", true)
                    UI.PublishHotkey(false, "init-game-state-transition")
                    if type(ctx.POI) == "table" and type(ctx.POI.OnLoadMapPre) == "function" then
                        ctx.POI.OnLoadMapPre()
                    end
                    Renderer.DropWorldReferencesUnread()
                    log("InitGameState transition fallback: old-world references dropped unread")
                end
                release_world_after_settle(state.lifecycle_epoch, "init-game-state")
            end)
        end

        -- Covers attaching the mod while already inside a stable gameplay world.
        release_world_after_settle(state.lifecycle_epoch, "startup")

        if not schedule_next(250) and type(LoopInGameThreadAfterFrames) == "function" then
            log("Delayed game-thread scheduler unavailable; using two-frame fallback loop")
            global_runtime.frame_loop = LoopInGameThreadAfterFrames(2, function()
                if global_runtime.generation == instance_generation then runtime_tick() end
            end)
        end
    end

    runtime.Tick = runtime_tick
    runtime.LoadMapPre = load_map_pre
    runtime.LoadMapPost = load_map_post
    return runtime
end

return Factory
