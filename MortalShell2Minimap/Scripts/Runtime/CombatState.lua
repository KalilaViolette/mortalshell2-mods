-- Runtime.CombatState -- v0.18.0. Whether the player is fighting, and what the
-- minimap does about it (the COMBAT tab: hide, opacity, size, transition, restore delay).
--
-- THE SIGNAL
--
-- The game keeps one music state machine on its music manager, and that machine is
-- the game's own definition of "in combat": it moves to Combat when an enemy engages,
-- to BossCombat for a boss, to PostCombat when the fight is over and back to
-- Exploration. It ignores enemies that are merely nearby (that is PreCombat). The
-- 2026-09-14 object dump has the whole thing:
--
--     SpartaGameInstance.MusicManager           -> BP_MusicManager_C (one, lives with the game instance)
--     SpartaMusicManager.m_CurrentState         -> the live SpartaMusicState
--     BP_MusicState_Combat_C:Enter / :Exit      Blueprint overrides (hookable, the proven kind)
--     BP_MusicState_BossCombat_C                no Blueprint Enter/Exit of its own; it runs the
--                                               native SpartaMusicState:Enter, which this mod
--                                               does not hook (native hooking is unproven here)
--
-- So two sources, neither trusted alone:
--   * hooks on the Combat state's Blueprint Enter/Exit -- instant, but blind to bosses;
--   * a governed poll (every POLL_INTERVAL_MS, one property read and a class name
--     compare on an object we already hold) of m_CurrentState -- sees every state
--     including BossCombat, and corrects the hooks if they ever disagree.
-- No world scan: the manager is reached once through GameplayStatics:GetGameInstance
-- from the player controller the renderer already holds, and re-resolved only when the
-- handle stops validating.
--
-- THE LOOK
--
-- One render transform and one opacity on the renderer's ROOT canvas, which every
-- minimap element (map box, frame, labels) hangs from, so the whole thing fades and
-- shrinks together about the map's own centre. Nothing is rebuilt and no module
-- other than this one writes for it. "Hide" fades to zero and then asks the
-- lifecycle to collapse the widget (Lifecycle.should_hide -> WantsHide), which also
-- stops the overlay work while hidden. The restore delay keeps the combat look for a
-- moment after the music says the fight is over, so a stray pull does not flicker it.
--
-- While the COMBAT tab's look rows are selected in the settings window the combat look
-- is previewed, the same way every other visual row previews live.

local Factory = {}

function Factory.New(ctx)
    local state = assert(ctx.State, "Runtime.CombatState requires State")
    local Config = assert(ctx.Config, "Runtime.CombatState requires Config")
    local Object = assert(ctx.Object, "Runtime.CombatState requires Core.Object")
    local log = assert(ctx.Log, "Runtime.CombatState requires Log")
    local global_runtime = assert(ctx.GlobalRuntime, "Runtime.CombatState requires GlobalRuntime")
    local instance_generation = assert(ctx.InstanceGeneration, "Runtime.CombatState requires InstanceGeneration")
    local Perf = type(ctx.Perf) == "table" and ctx.Perf
        or { Begin = function() return nil end, End = function() end }
    local clock = type(ctx.Clock) == "function" and ctx.Clock or os.clock

    local COMBAT_STATE_CLASS = "/Game/Sparta/Core/Audio/Music/States/BP_MusicState_Combat.BP_MusicState_Combat_C"
    local GAMEPLAY_STATICS_PATH = "/Script/Engine.Default__GameplayStatics"
    local LAYOUT_LIBRARY_PATH = "/Script/UMG.Default__WidgetLayoutLibrary"
    local POLL_INTERVAL_S = 0.5
    local RESOLVE_RETRY_S = 5.0
    local PREVIEW_KEYS = { CombatHide = true, CombatOpacity = true, CombatSize = true }

    local combat = {
        in_combat = false, boss = false, source = "none", state_name = "",
        since = nil,               -- clock when the current combat began
        ended_at = nil,            -- clock when the last combat ended (restore delay runs from here)
        hooks = {}, hook_specs = 2,
        manager = nil, manager_status = "unresolved", next_resolve = 0.0, next_poll = 0.0,
        -- What is drawn now, what is wanted, and the animation between them.
        look = { opacity = 1.0, scale = 1.0 },
        target = { opacity = 1.0, scale = 1.0, hide = false },
        from = { opacity = 1.0, scale = 1.0 },
        anim_start = nil, anim_duration = 0.0,
        hidden = false, phase = "normal", preview = false,
        pivot = nil, pivot_status = "unset",
        applied = { opacity = nil, scale = nil },
        metrics = {
            enters = 0, exits = 0, polls = 0, poll_changes = 0, poll_corrections = 0,
            resolves = 0, resolve_failures = 0, opacity_writes = 0, scale_writes = 0,
            pivot_writes = 0, transitions = 0, hides = 0, restores = 0,
        },
    }
    state.combat = combat

    local function unwrap(value) return Object.Unwrap(value) end
    local function valid(value) return Object.Valid(value) end

    local function find_object(path)
        local ok, value = pcall(StaticFindObject, path)
        value = unwrap(ok and value or nil)
        return valid(value) and value or nil
    end

    local function clamp01(value)
        value = tonumber(value) or 1.0
        if value < 0.0 then return 0.0 end
        if value > 1.0 then return 1.0 end
        return value
    end

    -- "BP_MusicState_Combat_C" and "BP_MusicState_BossCombat_C" are combat;
    -- "...PreCombat_C" / "...PostCombat_C" are not (the class names are the dump's).
    local function classify(name)
        name = tostring(name or "")
        if name == "" then return false, false end
        local lowered = name:lower()
        if not lowered:find("combat", 1, true) then return false, false end
        if lowered:find("precombat", 1, true) or lowered:find("postcombat", 1, true) then
            return false, false
        end
        return true, lowered:find("bosscombat", 1, true) ~= nil
    end

    local function set_combat(active, boss, source, name)
        local now = clock()
        combat.source = tostring(source or "none")
        if name ~= nil then combat.state_name = tostring(name) end
        combat.boss = boss == true
        if active == combat.in_combat then return false end
        combat.in_combat = active
        if active then
            combat.since = now
            combat.ended_at = nil
        else
            combat.ended_at = now
        end
        if Config.DebugLog == true then
            log(string.format("Combat %s source=%s state=%s boss=%s",
                active and "begin" or "end", combat.source, combat.state_name, tostring(combat.boss)))
        end
        return true
    end

    -- Hooks --------------------------------------------------------------------

    local function on_enter(context)
        combat.metrics.enters = combat.metrics.enters + 1
        local name = Object.ClassShortName(context) or "BP_MusicState_Combat_C"
        local active, boss = classify(name)
        if active then set_combat(true, boss, "hook", name) end
    end

    local function on_exit(context)
        combat.metrics.exits = combat.metrics.exits + 1
        local name = Object.ClassShortName(context) or "BP_MusicState_Combat_C"
        set_combat(false, false, "hook", name)
    end

    local HOOK_SPECS = {
        { label = "combat.enter", path = COMBAT_STATE_CLASS .. ":Enter", on = on_enter },
        { label = "combat.exit", path = COMBAT_STATE_CLASS .. ":Exit", on = on_exit },
    }
    combat.hook_specs = #HOOK_SPECS

    local runtime = {}

    function runtime.Arm()
        if type(RegisterHook) ~= "function" then return 0, #HOOK_SPECS end
        local armed = 0
        for _, spec in ipairs(HOOK_SPECS) do
            if combat.hooks[spec.path] == nil then
                local handler = spec.on
                local section = "hook." .. spec.label
                local ok, pre_id, post_id = pcall(RegisterHook, spec.path, function(context)
                    if global_runtime.generation ~= instance_generation then return end
                    local token = Perf.Begin()
                    pcall(handler, context)
                    Perf.End(section, token)
                end)
                if ok and (pre_id ~= nil or post_id ~= nil) then
                    combat.hooks[spec.path] = { pre = pre_id, post = post_id, label = spec.label }
                    log("Combat hook label=" .. spec.label .. " state=armed")
                end
            end
            if combat.hooks[spec.path] ~= nil then armed = armed + 1 end
        end
        return armed, #HOOK_SPECS
    end

    function runtime.HooksArmed()
        local armed = 0
        for _ in pairs(combat.hooks) do armed = armed + 1 end
        return armed, #HOOK_SPECS
    end

    -- Poll ---------------------------------------------------------------------

    local function resolve_manager(now)
        if now < combat.next_resolve then return nil end
        combat.next_resolve = now + RESOLVE_RETRY_S
        combat.metrics.resolves = combat.metrics.resolves + 1
        local controller = unwrap(state.controller)
        if not valid(controller) then
            combat.manager_status = "no-controller"
            combat.metrics.resolve_failures = combat.metrics.resolve_failures + 1
            return nil
        end
        local statics = find_object(GAMEPLAY_STATICS_PATH)
        if statics == nil then
            combat.manager_status = "no-gameplay-statics"
            combat.metrics.resolve_failures = combat.metrics.resolve_failures + 1
            return nil
        end
        local instance = nil
        pcall(function() instance = unwrap(statics:GetGameInstance(controller)) end)
        if not valid(instance) then
            combat.manager_status = "no-game-instance"
            combat.metrics.resolve_failures = combat.metrics.resolve_failures + 1
            return nil
        end
        local manager = nil
        pcall(function() manager = unwrap(instance.MusicManager) end)
        if not valid(manager) then
            combat.manager_status = "no-music-manager"
            combat.metrics.resolve_failures = combat.metrics.resolve_failures + 1
            return nil
        end
        combat.manager = manager
        combat.manager_status = "resolved"
        if Config.DebugLog == true then
            log("Combat music manager resolved class=" .. tostring(Object.ClassShortName(manager)))
        end
        return manager
    end

    local function poll(now)
        if now < combat.next_poll then return end
        combat.next_poll = now + POLL_INTERVAL_S
        local manager = combat.manager
        if manager == nil or not valid(manager) then
            combat.manager = nil
            manager = resolve_manager(now)
            if manager == nil then return end
        end
        combat.metrics.polls = combat.metrics.polls + 1
        local current = nil
        local ok = pcall(function() current = unwrap(manager.m_CurrentState) end)
        if not ok then
            combat.manager_status = "state-read-failed"
            return
        end
        local name = valid(current) and (Object.ClassShortName(current) or "") or ""
        if name ~= combat.state_name then
            combat.metrics.poll_changes = combat.metrics.poll_changes + 1
        end
        local active, boss = classify(name)
        if active ~= combat.in_combat and combat.source == "hook" then
            combat.metrics.poll_corrections = combat.metrics.poll_corrections + 1
        end
        set_combat(active, boss, "poll", name)
    end

    -- Presentation -------------------------------------------------------------

    local function root_canvas()
        local retained = state.retained
        if type(retained) ~= "table" then return nil end
        local root = retained.root
        return valid(root) and root or nil
    end

    local function selected_preview()
        if state.settings_open ~= true then return false end
        local UI = ctx.UI
        if type(UI) ~= "table" or type(UI.SelectedSettingKey) ~= "function" then return false end
        local ok, key = pcall(UI.SelectedSettingKey)
        return ok and PREVIEW_KEYS[tostring(key or "")] == true
    end

    -- The combat look applies while fighting and for CombatRestoreDelay after.
    local function combat_look_wanted(now)
        if combat.in_combat then return true, "combat" end
        if combat.ended_at ~= nil then
            local delay = math.max(0.0, tonumber(Config.CombatRestoreDelay) or 0.0)
            if now - combat.ended_at < delay then return true, "restore-delay" end
        end
        return false, "normal"
    end

    local function wanted_target(now)
        local preview = selected_preview()
        combat.preview = preview
        local wanted, phase = combat_look_wanted(now)
        if preview then wanted, phase = true, "preview" end
        if not wanted then
            return { opacity = 1.0, scale = 1.0, hide = false }, phase
        end
        local hide = Config.CombatHide == true
        return {
            opacity = hide and 0.0 or clamp01(Config.CombatOpacity),
            scale = math.max(0.5, math.min(1.0, tonumber(Config.CombatSize) or 1.0)),
            hide = hide,
        }, phase
    end

    local function same_target(a, b)
        return math.abs(a.opacity - b.opacity) < 0.0005 and math.abs(a.scale - b.scale) < 0.0005
            and a.hide == b.hide
    end

    -- Pivot of the root canvas that sits on the map's centre: the root fills the
    -- viewport, so its local size is the viewport in pixels over the UI scale.
    local function refresh_pivot()
        local controller = unwrap(state.controller)
        local library = find_object(LAYOUT_LIBRARY_PATH)
        if not valid(controller) or library == nil then
            combat.pivot, combat.pivot_status = nil, "layout-library-unavailable"
            return nil
        end
        local width, height, scale = nil, nil, nil
        pcall(function()
            local size = library:GetViewportSize(controller)
            width, height = tonumber(size.X), tonumber(size.Y)
        end)
        pcall(function() scale = tonumber(library:GetViewportScale(controller)) end)
        if width == nil or height == nil or width <= 1 or height <= 1 then
            combat.pivot, combat.pivot_status = nil, "viewport-size-unavailable"
            return nil
        end
        if scale == nil or scale <= 0.0 then scale = 1.0 end
        local size = tonumber(Config.Size) or 280
        local cx = (tonumber(Config.OffsetX) or 0) + size / 2.0
        local cy = (tonumber(Config.OffsetY) or 0) + size / 2.0
        combat.pivot = { X = cx / (width / scale), Y = cy / (height / scale) }
        combat.pivot_status = string.format("%.3f,%.3f@%dx%d/%.2f", combat.pivot.X, combat.pivot.Y,
            math.floor(width), math.floor(height), scale)
        return combat.pivot
    end

    local PIVOT_RETRY_S = 2.0
    local function pivot_retry_due(now)
        return combat.pivot == nil and combat.look.scale < 0.9995 and now >= (combat.next_pivot_try or 0.0)
    end

    local function apply_look(root, now)
        local look = combat.look
        if combat.applied.opacity == nil or math.abs(combat.applied.opacity - look.opacity) > 0.002 then
            if pcall(root.SetRenderOpacity, root, look.opacity) then
                combat.applied.opacity = look.opacity
                combat.metrics.opacity_writes = combat.metrics.opacity_writes + 1
            end
        end
        -- The pivot is looked up when a scale first needs it, and again every
        -- PIVOT_RETRY_S while it is still missing, never every tick.
        if look.scale < 0.9995 and combat.pivot == nil and now >= (combat.next_pivot_try or 0.0) then
            combat.next_pivot_try = now + PIVOT_RETRY_S
            refresh_pivot()
        end
        if combat.pivot ~= nil and combat.applied.pivot ~= combat.pivot_status then
            if pcall(root.SetRenderTransformPivot, root, combat.pivot) then
                combat.applied.pivot = combat.pivot_status
                combat.metrics.pivot_writes = combat.metrics.pivot_writes + 1
            end
        end
        -- Without a pivot the map would scale about the screen corner; keep the size.
        local scale = combat.pivot ~= nil and look.scale or 1.0
        if combat.applied.scale == nil or math.abs(combat.applied.scale - scale) > 0.002 then
            if pcall(root.SetRenderScale, root, { X = scale, Y = scale }) then
                combat.applied.scale = scale
                combat.metrics.scale_writes = combat.metrics.scale_writes + 1
            end
        end
    end

    local function begin_transition(target, now)
        combat.from.opacity, combat.from.scale = combat.look.opacity, combat.look.scale
        combat.target = target
        combat.anim_duration = math.max(0.0, tonumber(Config.CombatTransition) or 0.0)
        combat.anim_start = now
        combat.metrics.transitions = combat.metrics.transitions + 1
    end

    -- Called from the pose tick, hidden or not. Cheap when nothing is moving: one
    -- clock read, a poll every POLL_INTERVAL_S, and a target compare.
    function runtime.Update()
        if not state.built then return false end
        local now = clock()
        poll(now)
        local target, phase = wanted_target(now)
        combat.phase = phase
        if not same_target(target, combat.target) then begin_transition(target, now) end
        -- Leaving hidden: show first, then fade in from wherever the look is.
        if combat.hidden and not target.hide then
            combat.hidden = false
            combat.metrics.restores = combat.metrics.restores + 1
        end
        local moving = combat.anim_start ~= nil
        if moving then
            local t = combat.anim_duration <= 0.0 and 1.0
                or math.min(1.0, (now - combat.anim_start) / combat.anim_duration)
            local ease = t * t * (3.0 - 2.0 * t)
            combat.look.opacity = combat.from.opacity + (combat.target.opacity - combat.from.opacity) * ease
            combat.look.scale = combat.from.scale + (combat.target.scale - combat.from.scale) * ease
            if t >= 1.0 then
                combat.anim_start = nil
                combat.look.opacity, combat.look.scale = combat.target.opacity, combat.target.scale
                if combat.target.hide and not combat.hidden then
                    combat.hidden = true
                    combat.metrics.hides = combat.metrics.hides + 1
                end
            end
        end
        local root = root_canvas()
        if root ~= nil and (moving or combat.applied.opacity == nil or pivot_retry_due(now)) then
            apply_look(root, now)
        end
        return moving
    end

    -- Lifecycle.should_hide: the widget is collapsed only once the fade to zero is done.
    function runtime.WantsHide()
        return combat.hidden and Config.CombatHide == true and not combat.preview
    end

    function runtime.InCombat() return combat.in_combat end

    function runtime.ApplyLiveSetting(setting)
        if type(setting) ~= "table" then return end
        if setting.apply == "combat" then
            -- Re-evaluated on the next tick; a changed size or offset moves the pivot.
            combat.pivot = nil
            combat.applied.pivot = nil
            combat.next_pivot_try = 0.0
        end
    end

    function runtime.OnRendererReady()
        combat.applied = { opacity = nil, scale = nil, pivot = nil }
        combat.pivot = nil
        combat.next_pivot_try = 0.0
        combat.look.opacity, combat.look.scale = 1.0, 1.0
        combat.target = { opacity = 1.0, scale = 1.0, hide = false }
        combat.anim_start = nil
        combat.hidden = false
        return true
    end

    -- The root canvas is torn down with the renderer; the manager lives with the game
    -- instance but is re-resolved on the next poll rather than trusted across worlds.
    function runtime.DropWorldReferencesUnread()
        combat.manager = nil
        combat.manager_status = "dropped"
        combat.next_resolve = 0.0
        combat.applied = { opacity = nil, scale = nil, pivot = nil }
        combat.pivot = nil
        combat.next_pivot_try = 0.0
        combat.look.opacity, combat.look.scale = 1.0, 1.0
        combat.target = { opacity = 1.0, scale = 1.0, hide = false }
        combat.anim_start = nil
        combat.hidden = false
        combat.in_combat, combat.boss = false, false
        combat.since, combat.ended_at = nil, nil
        combat.source = "none"
    end

    function runtime.Summary()
        local armed, total = runtime.HooksArmed()
        local m = combat.metrics
        return string.format(
            "inCombat=%s boss=%s source=%s state=%s phase=%s hooks=%d/%d enters=%d exits=%d polls=%d pollChanges=%d pollCorrections=%d manager=%s resolves=%d resolveFailures=%d look(opacity=%.2f scale=%.2f hidden=%s preview=%s) pivot=%s writes(opacity=%d scale=%d pivot=%d) transitions=%d hides=%d restores=%d config(hide=%s opacity=%.2f size=%.2f transition=%.2f restore=%.1f)",
            tostring(combat.in_combat), tostring(combat.boss), combat.source, combat.state_name, combat.phase,
            armed, total, m.enters, m.exits, m.polls, m.poll_changes, m.poll_corrections,
            combat.manager_status, m.resolves, m.resolve_failures,
            combat.look.opacity, combat.look.scale, tostring(combat.hidden), tostring(combat.preview),
            combat.pivot_status, m.opacity_writes, m.scale_writes, m.pivot_writes,
            m.transitions, m.hides, m.restores,
            tostring(Config.CombatHide == true), tonumber(Config.CombatOpacity) or 0,
            tonumber(Config.CombatSize) or 0, tonumber(Config.CombatTransition) or 0,
            tonumber(Config.CombatRestoreDelay) or 0)
    end

    function runtime.EmitSummary(reason)
        log("Combat summary reason=" .. tostring(reason) .. " " .. runtime.Summary())
    end

    function runtime.State() return combat end

    return runtime
end

return Factory
