-- MortalShell2ModUI Runtime.InputHost
-- Pass 175 consumes the shared ModUI Controller.Profile for recorder thresholds and gives the shared
-- Controller Settings calibration/test subview a bounded 10 ms / 100 Hz sampling lane without changing ordinary polling.
-- Pass 171 bridges a transition-like native open rejection immediately before LoadMap into a
-- short-lived primitive intent that may cross only that following LoadMap boundary, while the hard
-- freeze remains UObject-free. Expected admission rejection is no longer a session-failure signal.
-- Pass 170 separates non-gameplay admission from queueable transition/settle admission so one fresh
-- open-hotkey edge during the post-LoadMap safety window is retained and dispatched automatically
-- after the existing settle + full-release gate, without making LoadMap PRE UObject-capable.
-- Pass 167 retains one deliberate open intent observed during the bounded post-LoadMap
-- settle/rearm window. It dispatches only after the incoming controller is fully settled and every
-- configured open-binding token is released, so the first post-zone combo is responsive
-- without allowing a held pre-transition chord to cross the world boundary.
-- Pass 146 adds bounded phase breadcrumbs to the permanent delayed active-menu poll so a
-- native UE4SS failure identifies the last UObject-capable phase without changing cadence.
-- Pass 145 closes two delayed-input races found in the Pass-144 crash bundle. The poll is
-- UObject-free for the entire close quarantine, and every accepted or rejected toggle edge
-- must be followed by a fully neutral physical sample. Host-ownership changes use the same
-- rearm gate, so a still-held chord cannot be re-read locally after the host opened Settings.
-- Pass 144 adds a post-transition quiescence + neutral-edge admission guard. After the
-- Pass-143 LoadMap freeze releases, a newly reacquired controller must remain identity-stable
-- for 2 seconds, then survive another 2-second UObject-free quiescence window; the configured
-- open bindings must also be observed fully released once before a fresh edge may open Settings.
-- Pass 143 adds an explicit UEngine::LoadMap transition freeze: LoadMap prehook drops cached world/controller/shell identities before unload, every scheduled consumer poll becomes UObject-free while frozen, and posthook resumes only after a primitive delayed settle window.
-- Pass 136 adds a consumer-supplied gameplay-context admission gate so front-end/MainMenu
-- PlayerControllers cannot trigger Settings at shaders, credits or the title/start menu.
-- Pass 135 retains the primitive controller-reacquisition settle gate for gameplay map loading.
-- Pass 110 hardens the host-binding republish callback contract after target-game evidence
-- proved controller host events but did not show the expected binding-republish marker.
-- Shared consumer-scoped Settings input runtime. Pass 108 delegates reusable physical
-- binding evaluation to Runtime.PhysicalBinding and can consume standalone Host.InputService
-- open-hotkey events, while retaining capture/browser/details/menu-session mechanics.
--
-- IMPORTANT: Pass 108 migrated open-hotkey physical polling. Pass 111/112 moved RightY
-- through the standalone analog mailbox. Pass 113 consumes the same host-owned mailbox for
-- all stick/trigger axes used by Voice Browser and binding capture. Pass 114 delegates the
-- controller DIGITAL recorder button scan through an on-demand host request while retaining
-- local fail-soft fallback until current capture-session samples arrive. Pass 115 does the
-- same for keyboard recording. Pass 117/118 established the standalone process-wide
-- WBP_InputListener observation hook and exact-listener event ring. Pass 119 can dispatch those
-- host events through a consumer-supplied semantic callback for non-pointer native menu actions;
-- pointer actions intentionally remain on the immediate local callback until cursor-at-event
-- coordinates can also be centralized safely. Pass 116 consumes fixed keyboard navigation events
-- from the standalone ModUI RegisterKeyBind owner. Consumers retain action semantics,
-- shell/world/modal lifetime and TTS/game-specific callbacks.

local M = {}

function M.Install(options)
    options = type(options) == "table" and options or {}
    local dd = options.dd
    local modui = options.modui
    local consumer_menu_label = tostring(options.consumer_menu_label or "Consumer menu")
    local consumer_conflict_source_id = tostring(options.consumer_conflict_source_id or "consumer-menu")
    local ui = options.ui
    local config = options.config
    local runtime = options.runtime
    local unwrap = options.unwrap
    local valid = options.valid
    local object_name = options.object_name
    local object_address = options.object_address
    local text_string = options.text_string
    local trim = options.trim
    local bool_from_string = options.bool_from_string
    local parent_path = options.parent_path
    local mod_dir = options.mod_dir
    local file_exists = options.file_exists
    local read_file = options.read_file
    local get_player_and_controller = options.get_player_and_controller
    local open_context_admission = options.open_context_admission
    local transition_context_admission = options.transition_context_admission
    local active_ui_session_valid = options.active_ui_session_valid
    local set_ui_text = options.set_ui_text
    local diag = options.diag or function() end
    local log = options.log or function() end
    local ExecuteInGameThreadWithDelay = options.execute_in_game_thread_with_delay
    local FName = options.fname -- ordinary Lua adapter supplied by the composition root
    local IsKeyBindRegistered = options.is_keybind_registered
    local global_table = options.global_table or _G
    local host_event_reader = options.host_event_reader
    local host_navigation_reader = options.host_navigation_reader
    local host_native_input_reader = options.host_native_input_reader
    local host_native_input_dispatch = options.host_native_input_dispatch
    local host_axis_reader = options.host_axis_reader
    local host_key_reader = options.host_key_reader
    local host_capture_request_writer = options.host_capture_request_writer
    local controller_profile_revision_reader = options.controller_profile_revision_reader
    local on_binding_changed = options.on_binding_changed
    local on_open_transition_ready = options.on_open_transition_ready
    local on_shell_cache_discard = options.on_shell_cache_discard
    local ControllerProfile = type(modui.Controller) == "table" and modui.Controller.Profile or nil

    if type(dd) ~= "table" then return nil, "dd missing" end
    if type(modui) ~= "table" or type(modui.Input) ~= "table" then return nil, "modui input API missing" end
    if type(ui) ~= "table" then return nil, "ui missing" end
    if type(config) ~= "table" then return nil, "config missing" end
    if type(runtime) ~= "table" then return nil, "runtime missing" end
    if type(unwrap) ~= "function" then return nil, "unwrap missing" end
    if type(valid) ~= "function" then return nil, "valid missing" end
    if type(object_name) ~= "function" then return nil, "object_name missing" end
    if type(object_address) ~= "function" then return nil, "object_address missing" end
    if type(text_string) ~= "function" then return nil, "text_string missing" end
    if type(trim) ~= "function" then return nil, "trim missing" end
    if type(bool_from_string) ~= "function" then return nil, "bool_from_string missing" end
    if type(parent_path) ~= "function" then return nil, "parent_path missing" end
    if type(file_exists) ~= "function" then return nil, "file_exists missing" end
    if type(read_file) ~= "function" then return nil, "read_file missing" end
    if type(get_player_and_controller) ~= "function" then return nil, "get_player_and_controller missing" end
    if type(active_ui_session_valid) ~= "function" then return nil, "active_ui_session_valid missing" end
    if type(set_ui_text) ~= "function" then return nil, "set_ui_text missing" end
    if type(FName) ~= "function" then return nil, "FName missing" end

    dd.open_bind_poll_armed = false
    dd.open_bind_keyboard_latched = false
    dd.open_bind_controller_latched = false
    dd.open_bind_key_cache = {}
    dd.open_bind_poll_fail_logged = false
    dd.bind_capture = { active = false }
    dd.binding_conflicts = {}
    dd.open_bind_sequence_state = {}

    -- Pass 105 retains the proven 50 ms open-bind response cadence but removes a much
    -- more expensive operation from that permanent path. Before this pass every poll
    -- called the shared player/controller resolver, resolved Controller again, and then queried
    -- the two configured binds. PresentMon showed the resulting CPU-side frame tail at roughly
    -- the same cadence. Cache only the PlayerController used for input; validate it before every
    -- use and fall back to the shared authoritative resolver whenever it becomes invalid. When no
    -- controller exists (loading/death/transition), the poll backs off instead of enumerating or
    -- searching for player/controller objects at 20 Hz.
    dd.open_bind_cached_controller = nil
    dd.open_bind_controller_cache_hits = 0
    dd.open_bind_controller_cache_misses = 0
    dd.open_bind_had_live_controller = false
    dd.open_bind_world_missing = false
    dd.world_scope_epoch = tonumber(dd.world_scope_epoch) or 0

    -- Pass 143: do not discover a world transition by calling IsValid() on a wrapper
    -- after UEngine::LoadMap has already begun tearing that world down. The composition
    -- root drives these primitives from UE4SS RegisterLoadMapPreHook/PostHook. While
    -- frozen, scheduled input ticks are allowed to reschedule themselves but may not
    -- unwrap, validate, resolve, or query any PlayerController/UObject.
    dd.open_bind_load_map_frozen = false
    dd.open_bind_load_map_token = tonumber(dd.open_bind_load_map_token) or 0
    dd.open_bind_load_map_resume_ms = 1500

    -- Pass 135 introduced controller-reacquisition settling because native OptionsMenuQuery can
    -- become permissive before the incoming world is safe for our borrowed UMG shell. Pass 144
    -- keeps that exact-identity stage, then adds a second UObject-free quiescence stage before
    -- Settings admission. Delayed callbacks compare only primitive address/token state; they never
    -- capture or dereference an old-world UObject.
    dd.open_bind_controller_address = tostring(dd.open_bind_controller_address or "")
    dd.open_bind_controller_identity_stable = false
    dd.open_bind_controller_settled = false
    dd.open_bind_controller_settle_token = tonumber(dd.open_bind_controller_settle_token) or 0
    dd.open_bind_controller_settle_ms = 2000
    dd.open_bind_post_settle_ms = 2000
    dd.open_bind_transition_neutral_required = true
    dd.open_bind_neutral_mode = "full"
    dd.open_bind_transition_gate_signature = tostring(dd.open_bind_transition_gate_signature or "")
    dd.open_bind_transition_gate_count = tonumber(dd.open_bind_transition_gate_count) or 0
    dd.open_bind_host_managed = nil
    dd.open_bind_pending_intent_kind = ""
    dd.open_bind_pending_intent_source = ""
    dd.open_bind_pending_intent_epoch = -1
    dd.open_bind_preload_intent_kind = ""
    dd.open_bind_preload_intent_source = ""
    dd.open_bind_preload_intent_token = tonumber(dd.open_bind_preload_intent_token) or 0
    dd.open_bind_preload_intent_window_ms = 1500

    local controller_profile_revision_seen = -1
    local controller_profile_cache = nil
    local function current_controller_profile(force)
        if type(ControllerProfile) ~= "table" or type(ControllerProfile.Current) ~= "function" then return nil end
        local revision = controller_profile_revision_seen
        if type(controller_profile_revision_reader) == "function" then
            local ok_revision, value = pcall(controller_profile_revision_reader)
            if ok_revision and tonumber(value) ~= nil then revision = math.max(0, math.floor(tonumber(value) or 0)) end
        end
        if force == true or controller_profile_cache == nil or revision ~= controller_profile_revision_seen then
            if type(ControllerProfile.Reload) == "function" then pcall(ControllerProfile.Reload) end
            controller_profile_cache = ControllerProfile.Current()
            controller_profile_revision_seen = revision
        end
        return controller_profile_cache
    end

    local function controller_address_text(controller)
        controller = unwrap(controller)
        if not valid(controller) then return "" end
        local ok_address, address = pcall(object_address, controller)
        if not ok_address or address == nil then return "" end
        return tostring(address)
    end

    local function arm_controller_settle(controller, reason)
        local address = controller_address_text(controller)
        dd.open_bind_controller_settle_token = (tonumber(dd.open_bind_controller_settle_token) or 0) + 1
        local token = dd.open_bind_controller_settle_token
        dd.open_bind_controller_address = address
        dd.open_bind_controller_identity_stable = false
        dd.open_bind_controller_settled = false
        dd.open_bind_transition_neutral_required = true
        dd.open_bind_neutral_mode = "full"

        if address == "" or type(ExecuteInGameThreadWithDelay) ~= "function" then
            diag("input.openController", {
                status = "transition-settle-unavailable", reason = tostring(reason or "controller-acquired"),
                address = address, token = token, delayMs = dd.open_bind_controller_settle_ms,
            })
            return false
        end

        local ok_schedule, scheduled = pcall(ExecuteInGameThreadWithDelay, dd.open_bind_controller_settle_ms, function()
            if token ~= tonumber(dd.open_bind_controller_settle_token) then return end
            if tostring(dd.open_bind_controller_address or "") ~= address then return end
            if dd.open_bind_world_missing == true then return end
            dd.open_bind_controller_identity_stable = true
            diag("input.openController", {
                status = "transition-identity-stable", reason = tostring(reason or "controller-acquired"),
                address = address, token = token, delayMs = dd.open_bind_controller_settle_ms,
                epoch = tonumber(dd.world_scope_epoch) or 0,
            })

            -- Pass 144: the supplied Pass-143 run showed successful first opens only after an
            -- additional ~2 seconds beyond controller identity stability. Keep this second
            -- callback primitive-only: it captures only token/address strings, never a UObject.
            local post_ok, post_scheduled = pcall(ExecuteInGameThreadWithDelay, dd.open_bind_post_settle_ms, function()
                if token ~= tonumber(dd.open_bind_controller_settle_token) then return end
                if tostring(dd.open_bind_controller_address or "") ~= address then return end
                if dd.open_bind_world_missing == true then return end
                if dd.open_bind_controller_identity_stable ~= true then return end
                dd.open_bind_controller_settled = true
                diag("input.openController", {
                    status = "transition-settled", phase = "post-identity-quiescence",
                    reason = tostring(reason or "controller-acquired"), address = address, token = token,
                    identityDelayMs = dd.open_bind_controller_settle_ms,
                    quiescenceDelayMs = dd.open_bind_post_settle_ms,
                    totalDelayMs = (tonumber(dd.open_bind_controller_settle_ms) or 0) + (tonumber(dd.open_bind_post_settle_ms) or 0),
                    epoch = tonumber(dd.world_scope_epoch) or 0,
                })
            end)
            if not post_ok or post_scheduled == false then
                diag("input.openController", {
                    status = "transition-quiescence-schedule-failed", reason = tostring(reason or "controller-acquired"),
                    address = address, token = token, error = tostring(post_scheduled),
                })
            end
        end)
        if not ok_schedule or scheduled == false then
            diag("input.openController", {
                status = "transition-settle-schedule-failed", reason = tostring(reason or "controller-acquired"),
                address = address, token = token, error = tostring(scheduled),
            })
            return false
        end
        diag("input.openController", {
            status = "transition-settle-armed", reason = tostring(reason or "controller-acquired"),
            address = address, token = token, delayMs = dd.open_bind_controller_settle_ms,
            epoch = tonumber(dd.world_scope_epoch) or 0,
        })
        return true
    end

    function dd.open_bind_transition_settled(controller)
        local address = controller_address_text(controller)
        if address == "" then return false, "controller-address-unavailable" end
        if dd.open_bind_world_missing == true then return false, "world-scope-missing" end
        if tostring(dd.open_bind_controller_address or "") ~= address then
            return false, "controller-identity-not-settled"
        end
        if dd.open_bind_controller_identity_stable ~= true then
            return false, "controller-identity-settling"
        end
        if dd.open_bind_controller_settled ~= true then
            return false, "post-controller-quiescence"
        end
        return true, nil
    end

    function dd.note_open_bind_world_break(reason, preserve_preload_intent)
        if dd.open_bind_world_missing then return false end
        dd.open_bind_world_missing = true
        dd.world_scope_epoch = (tonumber(dd.world_scope_epoch) or 0) + 1
        dd.open_bind_controller_settle_token = (tonumber(dd.open_bind_controller_settle_token) or 0) + 1
        dd.open_bind_controller_address = ""
        dd.open_bind_controller_identity_stable = false
        dd.open_bind_controller_settled = false
        dd.open_bind_transition_neutral_required = true
        dd.open_bind_neutral_mode = "full"
        dd.open_bind_cached_controller = nil
        dd.open_bind_keyboard_latched = false
        dd.open_bind_controller_latched = false
        dd.open_bind_sequence_state.keyboard = nil
        dd.open_bind_sequence_state.controller = nil
        dd.open_bind_pending_intent_kind = ""
        dd.open_bind_pending_intent_source = ""
        dd.open_bind_pending_intent_epoch = -1
        if preserve_preload_intent ~= true then
            dd.open_bind_preload_intent_kind = ""
            dd.open_bind_preload_intent_source = ""
            dd.open_bind_preload_intent_token = (tonumber(dd.open_bind_preload_intent_token) or 0) + 1
        end

        -- Do not call IsValid(), RemoveFromParent(), GetAddress(), or any other
        -- UObject method on the retained cache here. A map/main-menu transition can
        -- invalidate the native object graph while UE4SS still has Lua wrappers.
        -- Dropping our strong Lua reference lets Unreal's own viewport/world teardown
        -- remain authoritative and guarantees the next open constructs a fresh shell.
        if not ui.open and type(ui.shell_cache) == "table" then
            local cache = ui.shell_cache
            local cache_token = tonumber(cache.token) or 0
            local cache_generation = tonumber(cache.generation) or 0
            local cache_shell_address = tostring(cache.shell_address or "")
            ui.shell_cache = nil

            -- Publish only the primitive identity captured before the world break. Never pass
            -- the cached widget/controller Lua wrappers across this callback.
            if type(on_shell_cache_discard) == "function" then
                local publish_ok, publish_err = pcall(on_shell_cache_discard,
                    cache_generation, cache_shell_address, cache_token,
                    tostring(reason or "controller-unavailable"))
                if not publish_ok then
                    diag("shell.cache.retirePublish", {
                        status = "callback-failed",
                        reason = tostring(reason or "controller-unavailable"),
                        error = tostring(publish_err),
                    })
                end
            end

            diag("shell.cache.discard", {
                status = "controller-lost-no-deref",
                reason = tostring(reason or "controller-unavailable"),
                token = cache_token,
                priorGeneration = cache_generation,
                shellAddress = cache_shell_address,
                currentEpoch = dd.world_scope_epoch,
            })
        end
        diag("input.openController", {
            status = "world-scope-break",
            reason = tostring(reason or "controller-unavailable"),
            epoch = dd.world_scope_epoch,
        })
        return true
    end

    function dd.note_load_map_pre(reason)
        reason = tostring(reason or "load-map-pre")
        dd.open_bind_load_map_token = (tonumber(dd.open_bind_load_map_token) or 0) + 1
        dd.open_bind_load_map_frozen = true

        -- Pass 171: capture only primitive state before the world-break reset. A native
        -- admission rejection may arm this intent for a very short window; it crosses a
        -- boundary only when LoadMap PRE actually follows, never merely because Options
        -- were denied. No UObject wrapper is sampled or retained here.
        local preload_kind = tostring(dd.open_bind_preload_intent_kind or "")
        local preload_source = tostring(dd.open_bind_preload_intent_source or "")
        dd.open_bind_preload_intent_kind = ""
        dd.open_bind_preload_intent_source = ""
        dd.open_bind_preload_intent_token = (tonumber(dd.open_bind_preload_intent_token) or 0) + 1

        -- This is deliberately called BEFORE Unreal unloads the old world. It only drops
        -- retained Lua references/primitive state and never validates the old controller.
        dd.note_open_bind_world_break(reason, preload_kind ~= "")
        if preload_kind == "keyboard" or preload_kind == "controller" then
            dd.open_bind_pending_intent_kind = preload_kind
            dd.open_bind_pending_intent_source = "preload-carry:" .. preload_source
            dd.open_bind_pending_intent_epoch = tonumber(dd.world_scope_epoch) or 0
            dd.open_bind_transition_neutral_required = true
            dd.open_bind_neutral_mode = "full"
            diag("input.openPending", {
                status = "carried-across-loadmap", kind = preload_kind,
                source = dd.open_bind_pending_intent_source, epoch = dd.open_bind_pending_intent_epoch,
            })
        end
        dd.open_bind_cached_controller = nil
        dd.open_bind_keyboard_latched = false
        dd.open_bind_controller_latched = false
        dd.open_bind_sequence_state.keyboard = nil
        dd.open_bind_sequence_state.controller = nil

        diag("input.loadMapTransition", {
            status = "pre-freeze", reason = reason,
            token = tonumber(dd.open_bind_load_map_token) or 0,
            epoch = tonumber(dd.world_scope_epoch) or 0,
            pollArmed = dd.open_bind_poll_armed == true,
        })
        return true
    end

    function dd.note_load_map_post(reason)
        reason = tostring(reason or "load-map-post")
        dd.open_bind_load_map_token = (tonumber(dd.open_bind_load_map_token) or 0) + 1
        local token = tonumber(dd.open_bind_load_map_token) or 0
        dd.open_bind_load_map_frozen = true
        dd.open_bind_cached_controller = nil
        dd.open_bind_controller_address = ""
        dd.open_bind_controller_identity_stable = false
        dd.open_bind_controller_settled = false
        dd.open_bind_transition_neutral_required = true
        dd.open_bind_neutral_mode = "full"

        diag("input.loadMapTransition", {
            status = "post-seen-resume-armed", reason = reason, token = token,
            resumeDelayMs = tonumber(dd.open_bind_load_map_resume_ms) or 1500,
            epoch = tonumber(dd.world_scope_epoch) or 0,
        })

        if type(ExecuteInGameThreadWithDelay) ~= "function" then
            diag("input.loadMapTransition", {
                status = "post-resume-unavailable", reason = reason, token = token,
            })
            return false
        end

        local ok_schedule, scheduled = pcall(ExecuteInGameThreadWithDelay,
            tonumber(dd.open_bind_load_map_resume_ms) or 1500, function()
                -- Token/address-free callback: never carry a world UObject across LoadMap.
                if token ~= tonumber(dd.open_bind_load_map_token) then return end
                dd.open_bind_load_map_frozen = false
                diag("input.loadMapTransition", {
                    status = "post-resumed", reason = reason, token = token,
                    epoch = tonumber(dd.world_scope_epoch) or 0,
                })
            end)
        if not ok_schedule or scheduled == false then
            diag("input.loadMapTransition", {
                status = "post-resume-schedule-failed", reason = reason, token = token,
                error = tostring(scheduled),
            })
            return false
        end
        return true
    end

    function dd.get_open_bind_controller()
        if dd.open_bind_load_map_frozen == true or ui.closing == true then
            return nil, false
        end
        local had_cached_wrapper = dd.open_bind_cached_controller ~= nil
        local cached = unwrap(dd.open_bind_cached_controller)
        if valid(cached) then
            dd.open_bind_had_live_controller = true
            dd.open_bind_world_missing = false
            dd.open_bind_controller_cache_hits = dd.open_bind_controller_cache_hits + 1
            return cached, true
        end

        if had_cached_wrapper and dd.open_bind_had_live_controller then
            dd.note_open_bind_world_break("cached-controller-invalid")
        end
        dd.open_bind_cached_controller = nil
        dd.open_bind_controller_cache_misses = dd.open_bind_controller_cache_misses + 1
        local _, controller = get_player_and_controller()
        controller = unwrap(controller)
        if valid(controller) then
            if dd.open_bind_world_missing then
                diag("input.openController", {
                    status = "world-scope-reacquired",
                    epoch = tonumber(dd.world_scope_epoch) or 0,
                })
            end
            local reacquired = dd.open_bind_world_missing == true
            dd.open_bind_world_missing = false
            dd.open_bind_had_live_controller = true
            dd.open_bind_cached_controller = controller
            arm_controller_settle(controller, reacquired and "world-reacquired" or "controller-acquired")
            return controller, true
        end

        if dd.open_bind_had_live_controller then
            dd.note_open_bind_world_break("controller-unavailable")
        end
        return nil, false
    end

    -- Pass 136: open hotkeys are meaningful only in a consumer-approved gameplay context.
    -- This runs before binding evaluation on the closed-menu path, so Main Menu/shader/credits
    -- states cannot create even a blocked Settings session. The callback is consumer supplied;
    -- Runtime.InputHost remains reusable and never hardcodes a game-specific controller class.
    dd.open_bind_context_block_signature = tostring(dd.open_bind_context_block_signature or "")
    dd.open_bind_context_block_count = tonumber(dd.open_bind_context_block_count) or 0

    local function open_context_allowed(controller)
        if type(open_context_admission) ~= "function" then return true, nil end
        local ok_probe, allowed, reason, identity = pcall(open_context_admission, controller)
        if not ok_probe then
            diag("input.openContext", { status = "probe-error", error = tostring(allowed) })
            return false, "context-probe-error"
        end
        if allowed == true then
            if dd.open_bind_context_block_signature ~= "" then
                diag("input.openContext", {
                    status = "gameplay-eligible",
                    priorReason = dd.open_bind_context_block_signature,
                    suppressedPolls = tonumber(dd.open_bind_context_block_count) or 0,
                })
            end
            dd.open_bind_context_block_signature = ""
            dd.open_bind_context_block_count = 0
            return true, nil
        end

        local reason_text = tostring(reason or "non-gameplay-context")
        if reason_text == dd.open_bind_context_block_signature then
            dd.open_bind_context_block_count = (tonumber(dd.open_bind_context_block_count) or 0) + 1
        else
            dd.open_bind_context_block_signature = reason_text
            dd.open_bind_context_block_count = 1
        end
        local count = tonumber(dd.open_bind_context_block_count) or 1
        if count == 1 or count % 20 == 0 then
            local identity_table = type(identity) == "table" and identity or {}
            diag("input.openContext", {
                status = "suppressed-non-gameplay",
                reason = reason_text,
                repeatCount = count,
                controller = tostring(identity_table.controllerName or object_name(controller)),
            })
        end
        return false, reason_text
    end

    -- Every open-binding poll (50 ms idle mailbox, 250 ms frozen/quarantined) runs
    -- through here. It is timed as poll.open-bind and its spacing recorded as
    -- poll.open-bind.interval on the consumer's profiler (modui.Perf), so a consumer's
    -- [PERF] summary shows what the shared input host costs it.
    function dd.schedule_open_bind_poll(delay_ms, callback)
        if type(ExecuteInGameThreadWithDelay) ~= "function" then return false end
        local ok = pcall(function()
            ExecuteInGameThreadWithDelay(delay_ms, function()
                local perf = modui.Perf
                if perf == nil or not perf.enabled then return callback() end
                perf.Mark("poll.open-bind.interval")
                local token = perf.Begin()
                callback()
                perf.End("poll.open-bind", token)
            end)
        end)
        return ok
    end

    local PhysicalBinding = modui.Runtime ~= nil and modui.Runtime.PhysicalBinding or nil
    if type(PhysicalBinding) ~= "table" or type(PhysicalBinding.New) ~= "function" then
        return nil, "modui physical binding API missing"
    end
    local physical, physical_err = PhysicalBinding.New(modui.Input.Binding, {
        unwrap = unwrap,
        valid = valid,
        fname = FName,
        input_time_seconds = function() return dd.input_time_seconds() end,
        diag = diag,
        binding_label = function(value) return dd.binding_label(value, value) end,
        key_cache = dd.open_bind_key_cache,
        sequence_state = dd.open_bind_sequence_state,
        analog_override = function(controller, axis_key)
            if type(host_axis_reader) == "function" then
                local value, source, ready = host_axis_reader(tostring(axis_key or ""))
                if ready and tonumber(value) ~= nil then
                    return true, tonumber(value), "ModUIHost:" .. tostring(source or axis_key)
                end
            end
            -- Fail-soft fallback uses PhysicalBinding.AnalogValue directly. Do not route
            -- through Voice Browser's filtered RightY helper or the profile would be applied twice.
            return false
        end,
        analog_policy = function(axis_key, direction, value, was_active)
            local profile = current_controller_profile(false)
            if type(profile) == "table" and type(ControllerProfile.AxisActive) == "function" then
                return ControllerProfile.AxisActive(axis_key, direction, value, was_active, profile)
            end
            return nil
        end,
    })
    if physical == nil then return nil, physical_err end
    dd.PhysicalBinding = physical
    dd.input_fkey = physical.FKey
    dd.input_key_down = physical.KeyDown
    dd.input_analog_value = physical.AnalogValue
    dd.modifier_equivalent_tokens = physical.ModifierEquivalentTokens

    function dd.capture_analog_value(controller, axis_key)
        axis_key = tostring(axis_key or "")
        if type(host_axis_reader) == "function" then
            local value, source, ready, frame = host_axis_reader(axis_key)
            if ready and tonumber(value) ~= nil then
                return tonumber(value), "ModUIHost:" .. tostring(source or axis_key), true, frame
            end
        end
        if axis_key == "Gamepad_RightY" and dd.right_stick_y ~= nil then
            local value, source = dd.right_stick_y(controller)
            return value, source, false
        end
        local value, source = dd.input_analog_value(controller, axis_key)
        return value, source, false
    end
    function dd.binding_token_active(controller, token)
        return physical.TokenActive(controller, token, config.modifier_sides_equivalent)
    end
    function dd.binding_is_down(controller, value)
        return physical.IsDown(controller, value, config.modifier_sides_equivalent)
    end
    function dd.binding_sequence_triggered(controller, value, kind)
        return physical.SequenceTriggered(controller, value, kind, config.modifier_sides_equivalent)
    end

    -- Pass 144 neutral-edge gate. A held/spammed chord must not fall through on the exact
    -- poll where a transition becomes eligible. This helper checks every physical token in
    -- either chord or sequence without mutating sequence progress.
    function dd.binding_all_tokens_released(controller, value)
        local tokens = modui.Input.Binding.Tokens(value)
        if type(tokens) ~= "table" or #tokens == 0 then return true, nil end
        local seen = {}
        for _, token in ipairs(tokens) do
            token = tostring(token or "")
            if token ~= "" and not seen[token] then
                seen[token] = true
                local active, err = dd.binding_token_active(controller, token)
                if active == nil then return nil, err end
                if active == true then return false, nil end
            end
        end
        return true, nil
    end

    -- Pass 145 makes release/rearm a session invariant rather than a transition-only detail.
    -- A toggle request, a denied request, or a host/local ownership change all require one
    -- fully neutral physical sample before another edge can reach ui_toggle_game.
    -- Pass 173 restores the old modifier-hold/controller-repeat feel without reopening
    -- the Pass-144/145 held-across-world race. Full neutral remains mandatory for LoadMap,
    -- controller identity/ownership changes, capture, and other safety boundaries. During
    -- ordinary settled controller toggles, however, the chord only has to become incomplete
    -- once (for L3+R3, releasing R3 while L3 remains held). The next R3 press is therefore a
    -- demonstrably fresh edge while a continuously-held full chord still cannot retrigger.
    local function arm_open_bind_neutral(reason, mode)
        mode = tostring(mode or "full") == "controller-chord-break" and "controller-chord-break" or "full"
        if mode == "controller-chord-break"
            and dd.binding_is_sequence ~= nil and dd.binding_is_sequence(config.controller_menu_bind) then
            mode = "full"
        end
        local was_required = dd.open_bind_transition_neutral_required == true
        local prior_mode = tostring(dd.open_bind_neutral_mode or "full")
        if was_required and prior_mode == "full" then mode = "full" end
        dd.open_bind_transition_neutral_required = true
        dd.open_bind_neutral_mode = mode
        if not was_required or prior_mode ~= mode then
            diag("input.openNeutral", {
                status = "armed",
                reason = tostring(reason or "toggle-edge"),
                mode = mode,
                epoch = tonumber(dd.world_scope_epoch) or 0,
            })
        end
    end

    local function consume_open_bind_neutral_sample(controller, stage)
        if dd.open_bind_transition_neutral_required ~= true then return true end

        local mode = tostring(dd.open_bind_neutral_mode or "full")
        local keyboard_released, keyboard_release_error = dd.binding_all_tokens_released(controller, config.menu_keybind)
        local controller_released, controller_release_error
        if mode == "controller-chord-break" then
            local controller_down, controller_down_error = dd.binding_is_down(controller, config.controller_menu_bind)
            if controller_down == nil then
                controller_released, controller_release_error = nil, controller_down_error
            else
                controller_released = controller_down ~= true
            end
        else
            controller_released, controller_release_error = dd.binding_all_tokens_released(controller, config.controller_menu_bind)
        end
        if keyboard_released == true and controller_released == true then
            dd.open_bind_transition_neutral_required = false
            dd.open_bind_neutral_mode = "full"
            dd.open_bind_keyboard_latched = false
            dd.open_bind_controller_latched = false
            if dd.PhysicalBinding ~= nil and type(dd.PhysicalBinding.Reset) == "function" then dd.PhysicalBinding.Reset() end
            diag("input.openNeutral", {
                status = mode == "controller-chord-break" and "chord-break-observed" or "neutral-observed",
                mode = mode,
                stage = tostring(stage or "poll"),
                freshEdgeRequired = true,
                epoch = tonumber(dd.world_scope_epoch) or 0,
            })
        elseif keyboard_released == nil or controller_released == nil then
            diag("input.openNeutral", {
                status = "neutral-query-error",
                mode = mode,
                stage = tostring(stage or "poll"),
                error = tostring(keyboard_release_error or controller_release_error),
            })
        end

        -- Even the rearm observation poll is consumed. A later poll must see the new edge.
        return false
    end

    local function clear_preload_open_intent(reason)
        local prior_kind = tostring(dd.open_bind_preload_intent_kind or "")
        local prior_source = tostring(dd.open_bind_preload_intent_source or "")
        dd.open_bind_preload_intent_kind = ""
        dd.open_bind_preload_intent_source = ""
        dd.open_bind_preload_intent_token = (tonumber(dd.open_bind_preload_intent_token) or 0) + 1
        if prior_kind ~= "" then
            diag("input.openPending", {
                status = "preload-cleared", kind = prior_kind, source = prior_source,
                reason = tostring(reason or "cleared"), epoch = tonumber(dd.world_scope_epoch) or 0,
            })
        end
    end

    local function arm_preload_open_intent(kind, source)
        kind = tostring(kind or "")
        if kind ~= "keyboard" and kind ~= "controller" then return false end
        if ui.open == true or ui.closing == true or dd.open_bind_world_missing == true then return false end
        if tostring(dd.open_bind_preload_intent_kind or "") ~= "" then return true end

        dd.open_bind_preload_intent_kind = kind
        dd.open_bind_preload_intent_source = tostring(source or "transition-native-rejection")
        dd.open_bind_preload_intent_token = (tonumber(dd.open_bind_preload_intent_token) or 0) + 1
        local token = tonumber(dd.open_bind_preload_intent_token) or 0
        local window_ms = tonumber(dd.open_bind_preload_intent_window_ms) or 1500
        diag("input.openPending", {
            status = "preload-armed", kind = kind, source = dd.open_bind_preload_intent_source,
            token = token, windowMs = window_ms, epoch = tonumber(dd.world_scope_epoch) or 0,
        })

        -- Primitive-only expiry. If LoadMap PRE does not follow quickly, a native denial was
        -- not enough evidence to carry the user's request into some unrelated future world.
        if type(ExecuteInGameThreadWithDelay) == "function" then
            local ok_schedule, scheduled = pcall(ExecuteInGameThreadWithDelay, window_ms, function()
                if token ~= tonumber(dd.open_bind_preload_intent_token) then return end
                clear_preload_open_intent("preload-window-expired")
            end)
            if not ok_schedule or scheduled == false then
                clear_preload_open_intent("preload-expiry-schedule-failed")
                return false
            end
        else
            clear_preload_open_intent("preload-expiry-unavailable")
            return false
        end
        return true
    end

    local function request_ui_toggle(kind, source, allow_preload_bridge)
        local toggle_ok, toggled, rejection_kind, rejection_reason = pcall(runtime.ui_toggle_game, kind)
        if not toggle_ok then
            diag("input.openToggle", {
                status = "callback-error", kind = tostring(kind or ""), source = tostring(source or ""),
                error = tostring(toggled),
            })
            return false
        end
        if toggled ~= true and allow_preload_bridge == true and rejection_kind == "transition-native" then
            arm_preload_open_intent(kind,
                tostring(source or "open") .. ":" .. tostring(rejection_reason or "transition-native"))
        end
        return toggled == true
    end

    local function clear_pending_open_intent(reason)
        local prior_kind = tostring(dd.open_bind_pending_intent_kind or "")
        local prior_source = tostring(dd.open_bind_pending_intent_source or "")
        dd.open_bind_pending_intent_kind = ""
        dd.open_bind_pending_intent_source = ""
        dd.open_bind_pending_intent_epoch = -1
        if prior_kind ~= "" then
            diag("input.openPending", {
                status = "cleared", kind = prior_kind, source = prior_source,
                reason = tostring(reason or "cleared"), epoch = tonumber(dd.world_scope_epoch) or 0,
            })
        end
    end

    local function pending_open_intent_kind()
        local kind = tostring(dd.open_bind_pending_intent_kind or "")
        if kind == "" then return nil end
        if tonumber(dd.open_bind_pending_intent_epoch) ~= (tonumber(dd.world_scope_epoch) or 0) then
            clear_pending_open_intent("world-epoch-changed")
            return nil
        end
        return kind
    end

    local function queue_pending_open_intent(kind, source)
        kind = tostring(kind or "")
        if kind ~= "keyboard" and kind ~= "controller" then return false end
        if ui.open == true or ui.closing == true or dd.open_bind_world_missing == true then return false end

        local prior = pending_open_intent_kind()
        if prior ~= nil then return true end
        dd.open_bind_pending_intent_kind = kind
        dd.open_bind_pending_intent_source = tostring(source or "transition")
        dd.open_bind_pending_intent_epoch = tonumber(dd.world_scope_epoch) or 0
        dd.open_bind_transition_neutral_required = true
        dd.open_bind_neutral_mode = "full"
        if prior == nil then
            diag("input.openPending", {
                status = "queued", kind = kind, source = dd.open_bind_pending_intent_source,
                epoch = dd.open_bind_pending_intent_epoch,
            })
        end
        return true
    end

    local function dispatch_pending_open_intent(controller, stage)
        local kind = pending_open_intent_kind()
        if kind == nil then return false, false end

        local keyboard_released, keyboard_error = dd.binding_all_tokens_released(controller, config.menu_keybind)
        local controller_released, controller_error = dd.binding_all_tokens_released(controller, config.controller_menu_bind)
        if keyboard_released == true and controller_released == true then
            local source = tostring(dd.open_bind_pending_intent_source or "transition")
            clear_pending_open_intent("released-dispatch")
            dd.open_bind_transition_neutral_required = false
            dd.open_bind_neutral_mode = "full"
            dd.open_bind_keyboard_latched = false
            dd.open_bind_controller_latched = false
            if dd.PhysicalBinding ~= nil and type(dd.PhysicalBinding.Reset) == "function" then dd.PhysicalBinding.Reset() end
            diag("input.openPending", {
                status = "released-dispatch", kind = kind, source = source,
                stage = tostring(stage or "transition-settled"), epoch = tonumber(dd.world_scope_epoch) or 0,
            })
            arm_open_bind_neutral("pending-toggle:" .. kind,
                kind == "controller" and "controller-chord-break" or "full")
            request_ui_toggle(kind, "pending-dispatch", true)
            return true, true
        end
        if keyboard_released == nil or controller_released == nil then
            diag("input.openPending", {
                status = "release-query-error", kind = kind,
                stage = tostring(stage or "transition-settled"),
                error = tostring(keyboard_error or controller_error),
            })
            -- Do not let a failed release query strand the open path behind a pending
            -- request forever. Fall back to the ordinary fresh-neutral admission gate.
            clear_pending_open_intent("release-query-error")
            arm_open_bind_neutral("pending-release-query-error")
            return false, false
        end
        return true, false
    end

    local function sample_transition_open_intent(controller, transition_reason)
        if pending_open_intent_kind() ~= nil then return true end

        -- A keyboard sequence proves a new ordered activation even before the ordinary
        -- neutral sample completes. A simultaneous controller chord remains gated until
        -- one fully released sample has been observed, preserving held-across-LoadMap safety.
        if dd.open_bind_transition_neutral_required == true then
            if dd.binding_is_sequence ~= nil and dd.binding_is_sequence(config.menu_keybind) then
                local sequence_triggered = dd.binding_sequence_triggered(controller, config.menu_keybind, "keyboard")
                if sequence_triggered == true then
                    return queue_pending_open_intent("keyboard", "transition-sequence:" .. tostring(transition_reason or "settling"))
                end
            end
            consume_open_bind_neutral_sample(controller, "transition-intent-rearm")
            return false
        end

        local keyboard_down = false
        local controller_down = false
        if dd.binding_is_sequence ~= nil and dd.binding_is_sequence(config.menu_keybind) then
            keyboard_down = dd.binding_sequence_triggered(controller, config.menu_keybind, "keyboard") == true
        else
            keyboard_down = dd.binding_is_down(controller, config.menu_keybind) == true
        end
        if dd.binding_is_sequence ~= nil and dd.binding_is_sequence(config.controller_menu_bind) then
            controller_down = dd.binding_sequence_triggered(controller, config.controller_menu_bind, "controller") == true
        else
            controller_down = dd.binding_is_down(controller, config.controller_menu_bind) == true
        end

        if keyboard_down and not dd.open_bind_keyboard_latched then
            dd.open_bind_keyboard_latched = true
            return queue_pending_open_intent("keyboard", "transition-edge:" .. tostring(transition_reason or "settling"))
        elseif not keyboard_down then
            dd.open_bind_keyboard_latched = false
        end
        if controller_down and not dd.open_bind_controller_latched then
            dd.open_bind_controller_latched = true
            return queue_pending_open_intent("controller", "transition-edge:" .. tostring(transition_reason or "settling"))
        elseif not controller_down then
            dd.open_bind_controller_latched = false
        end
        return false
    end

    local function observe_open_bind_host_management(active, stage)
        active = active == true
        local prior = dd.open_bind_host_managed
        dd.open_bind_host_managed = active
        if prior ~= nil and prior ~= active then
            arm_open_bind_neutral("host-ownership-change:" .. tostring(stage or "poll"))
            diag("input.openHostOwnership", {
                status = "changed",
                prior = prior,
                active = active,
                stage = tostring(stage or "poll"),
            })
        end
    end

    local function transition_gate_allowed(controller)
        local settled, reason = dd.open_bind_transition_settled(controller)
        if settled == true and type(transition_context_admission) == "function" then
            local ok_probe, allowed, transition_reason = pcall(transition_context_admission, controller)
            if not ok_probe then
                diag("input.openTransitionContext", { status = "probe-error", error = tostring(allowed) })
                settled = false
                reason = "transition-context-probe-error"
            elseif allowed ~= true then
                settled = false
                reason = tostring(transition_reason or "transition-context-not-settled")
            end
        end
        if settled == true then
            if type(on_open_transition_ready) == "function" then
                local notify_ok, notify_result = pcall(on_open_transition_ready, "controller-transition-settled")
                if not notify_ok or notify_result == false then
                    diag("input.openTransitionHostEnable", {
                        status = "deferred-consumer-fallback",
                        error = tostring(notify_ok and "callback-rejected" or notify_result),
                    })
                end
            end
            if dd.open_bind_transition_gate_signature ~= "" then
                diag("input.openTransitionGate", {
                    status = "eligible", priorReason = dd.open_bind_transition_gate_signature,
                    suppressedPolls = tonumber(dd.open_bind_transition_gate_count) or 0,
                    neutralRequired = dd.open_bind_transition_neutral_required == true,
                })
            end
            dd.open_bind_transition_gate_signature = ""
            dd.open_bind_transition_gate_count = 0
            return true, nil
        end
        local text = tostring(reason or "transition-not-settled")
        if text == dd.open_bind_transition_gate_signature then
            dd.open_bind_transition_gate_count = (tonumber(dd.open_bind_transition_gate_count) or 0) + 1
        else
            dd.open_bind_transition_gate_signature = text
            dd.open_bind_transition_gate_count = 1
        end
        local count = tonumber(dd.open_bind_transition_gate_count) or 1
        if count == 1 or count % 20 == 0 then
            diag("input.openTransitionGate", { status = "suppressed", reason = text, repeatCount = count })
        end
        return false, text
    end

    -- v0.9.62 conflict inspection is intentionally read-only. It combines four sources:
    --   1. the consumer's declared/fixed menu controls;
    --   2. Mortal Shell II's currently active EnhancedActionMappings;
    --   3. the built-in UE4SS Keybinds configuration when enabled;
    --   4. UE4SS's IsKeyBindRegistered boolean as a fail-soft registry backstop.
    -- Arbitrary third-party polling loops have no central registry, so the UI says "known"
    -- conflicts rather than claiming exhaustive ownership.
    dd.add_binding_conflict = modui.Input.Conflict.Add

    function dd.binding_component_key_map(value)
        return modui.Input.Conflict.ComponentKeyMap(value, config.modifier_sides_equivalent)
    end

    function dd.internal_menu_conflicts(kind, value, result)
        local components = dd.binding_component_key_map(value)
        if kind == "keyboard" then
            local controls = {
                Up = "Move Up", Down = "Move Down", Left = "Change Value Left", Right = "Change Value Right",
                Enter = "Confirm", Tab = "Next Tab", A = "Previous Tab", D = "Next Tab",
                PageUp = "Scroll Description Up", PageDown = "Scroll Description Down",
            }
            local exact_fingerprints = {}
            if dd.ue4ss_candidate_chords ~= nil then
                for _, chord in ipairs(dd.ue4ss_candidate_chords(value)) do
                    if #(chord.modifier_fields or {}) == 0 then exact_fingerprints[chord.token] = chord.fingerprint end
                end
            end
            for key_name, action in pairs(controls) do
                if components[key_name] ~= nil then
                    dd.add_binding_conflict(
                        result,
                        consumer_menu_label,
                        action .. " also uses " .. components[key_name],
                        consumer_conflict_source_id,
                        exact_fingerprints[key_name]
                    )
                end
            end
        else
            local controls = {
                Gamepad_FaceButton_Bottom = "Confirm",
                Gamepad_LeftShoulder = "Previous Tab", Gamepad_RightShoulder = "Next Tab",
                Gamepad_DPad_Up = "Move Up", Gamepad_DPad_Down = "Move Down",
                Gamepad_DPad_Left = "Change Value Left", Gamepad_DPad_Right = "Change Value Right",
            }
            for _, token in ipairs(dd.binding_tokens(value)) do
                local action = controls[token]
                if action ~= nil then
                    dd.add_binding_conflict(result, consumer_menu_label, action .. " also uses " .. dd.binding_token_label(token), consumer_conflict_source_id)
                elseif tostring(token):match("^axis:Gamepad_Left[XY]:") ~= nil then
                    dd.add_binding_conflict(result, consumer_menu_label, "Left Stick navigation also uses " .. dd.binding_token_label(token), consumer_conflict_source_id)
                elseif tostring(token):match("^axis:Gamepad_RightY:") ~= nil then
                    dd.add_binding_conflict(result, consumer_menu_label, "Right Stick description scrolling also uses " .. dd.binding_token_label(token), consumer_conflict_source_id)
                end
            end
        end
    end

    function dd.input_action_conflict_label(action)
        action = unwrap(action)
        if not valid(action) then return "Unknown action", "<invalid>" end
        local full = object_name(action)
        local description = nil
        pcall(function() description = text_string(action.ActionDescription) end)
        description = trim(description)
        if description ~= "" then return description, full end

        local short = tostring(full):match("%.([^%.%s]+)$") or tostring(full):match("/([^/%s]+)$") or tostring(full)
        short = tostring(short):gsub("^IA_", ""):gsub("_", " ")
        return trim(short), full
    end

    function dd.is_conflict_modifier_key(key_name)
        key_name = tostring(key_name or "")
        return key_name == "LeftControl" or key_name == "RightControl"
            or key_name == "LeftShift" or key_name == "RightShift"
            or key_name == "LeftAlt" or key_name == "RightAlt"
    end

    function dd.scan_game_mapping_conflicts(controller, value, result)
        controller = unwrap(controller)
        if not valid(controller) then
            result.game_scan = "controller-unavailable"
            return false
        end

        local player_input = nil
        pcall(function() player_input = unwrap(controller.PlayerInput) end)
        if not valid(player_input) then
            result.game_scan = "player-input-unavailable"
            return false
        end

        local mappings = nil
        local ok_mappings, mapping_error = pcall(function() mappings = unwrap(player_input.EnhancedActionMappings) end)
        if not ok_mappings or mappings == nil then
            result.game_scan = "mappings-unavailable:" .. tostring(mapping_error)
            return false
        end

        local ok_count, count = pcall(function() return #mappings end)
        if not ok_count then
            result.game_scan = "mapping-count-unavailable:" .. tostring(count)
            return false
        end

        local components = dd.binding_component_key_map(value)
        local matched = 0
        for index = 1, tonumber(count) or 0 do
            local ok_mapping, mapping = pcall(function() return mappings[index] end)
            if ok_mapping and mapping ~= nil then
                local ignored = false
                pcall(function() ignored = mapping.bShouldBeIgnored == true end)
                if not ignored then
                    local key_name = nil
                    pcall(function()
                        local key = mapping.Key
                        if key ~= nil then key_name = dd.native_name_string(key.KeyName) end
                    end)
                    key_name = trim(key_name)
                    -- Modifier-only game mappings are intentionally ignored. Ctrl/Shift/Alt
                    -- are ubiquitous chord ingredients and reporting every action attached to
                    -- the modifier alone obscures the conflicts that actually compete with the
                    -- recorded shortcut's meaningful/base key.
                    local component_label = not dd.is_conflict_modifier_key(key_name) and components[key_name] or nil
                    if component_label ~= nil then
                        local action = nil
                        pcall(function() action = unwrap(mapping.Action) end)
                        local action_label, action_full = dd.input_action_conflict_label(action)
                        -- The consumer shell intentionally activates the game's Menu input actions while
                        -- open. Those are represented separately as consumer menu conflicts;
                        -- skipping them here avoids double-counting one physical use twice.
                        local is_menu_action = tostring(action_full):find("/Actions/Menu/", 1, true) ~= nil
                            or tostring(action_full):find("IA_Menu_", 1, true) ~= nil
                        if not is_menu_action then
                            matched = matched + 1
                            dd.add_binding_conflict(
                                result,
                                "Mortal Shell II",
                                tostring(action_label) .. " uses " .. tostring(component_label),
                                "game-mapping"
                            )
                        end
                    end
                end
            end
        end

        result.game_scan = "ok"
        result.game_mapping_count = tonumber(count) or 0
        result.game_matches = matched
        return true
    end

    dd.ue4ss_key_field_for_token = modui.Input.Conflict.KeyFieldForToken
    dd.ue4ss_candidate_chords = modui.Input.Conflict.CandidateChords

    function dd.ue4ss_chord_label(chord)
        return modui.Input.Conflict.ChordLabel(chord, config.modifier_sides_equivalent)
    end

    function dd.ue4ss_keybinds_mod_enabled()
        local mods_root = parent_path(mod_dir)
        if mods_root == nil then return false end
        if file_exists(mods_root .. "\\Keybinds\\enabled.txt") then return true end
        local content = read_file(mods_root .. "\\mods.txt") or ""
        for raw_line in content:gmatch("[^\r\n]+") do
            local line = raw_line:gsub(";.*$", "")
            local name, enabled = line:match("^%s*([^:]+)%s*:%s*([01])")
            if name ~= nil and trim(name):lower() == "keybinds" then return enabled == "1" end
        end
        return false
    end

    function dd.scan_known_ue4ss_keybinds(value, result)
        if not dd.ue4ss_keybinds_mod_enabled() then return 0 end
        local mods_root = parent_path(mod_dir)
        if mods_root == nil then return 0 end
        local content = read_file(mods_root .. "\\Keybinds\\Scripts\\main.lua")
        if content == nil then return 0 end

        local candidates = {}
        for _, chord in ipairs(dd.ue4ss_candidate_chords(value)) do candidates[chord.fingerprint] = chord end
        local matches = 0
        for raw_line in content:gmatch("[^\r\n]+") do
            local name = raw_line:match('%[%s*["\']([^"\']+)["\']%s*%]')
            local key_field = raw_line:match("Key%.([A-Z0-9_]+)")
            if name ~= nil and key_field ~= nil then
                local mods = {}
                for modifier in raw_line:gmatch("ModifierKey%.([A-Z_]+)") do mods[#mods + 1] = modifier end
                table.sort(mods)
                local parts = {}
                for _, modifier in ipairs(mods) do parts[#parts + 1] = modifier end
                parts[#parts + 1] = key_field
                local fingerprint = table.concat(parts, "+")
                local candidate = candidates[fingerprint]
                if candidate ~= nil then
                    matches = matches + 1
                    dd.add_binding_conflict(
                        result,
                        "UE4SS tool",
                        tostring(name) .. " uses " .. dd.ue4ss_chord_label(candidate),
                        "ue4ss-exact",
                        fingerprint
                    )
                end
            end
        end
        return matches
    end

    dd.ini_section_values = modui.Input.Conflict.IniSectionValues

    function dd.scan_ue4ss_settings_conflicts(value, result)
        local mods_root = parent_path(mod_dir)
        local ue4ss_root = parent_path(mods_root)
        if ue4ss_root == nil then return false end
        local content = read_file(ue4ss_root .. "\\UE4SS-settings.ini")
        if content == nil then return false end

        local candidate_fields = {}
        for _, chord in ipairs(dd.ue4ss_candidate_chords(value)) do candidate_fields[chord.key_field] = chord end
        local general = dd.ini_section_values(content, "General")
        local debug_section = dd.ini_section_values(content, "Debug")

        if bool_from_string(general.enablehotreloadsystem, false) then
            local field = tostring(general.hotreloadkey or ""):upper():gsub("%s+", "_")
            if candidate_fields[field] ~= nil then
                dd.add_binding_conflict(result, "UE4SS", "Hot Reload uses " .. tostring(general.hotreloadkey), "ue4ss-setting")
            end
        end
        if bool_from_string(debug_section.guiconsoleenabled, false) then
            local field = tostring(debug_section.toggleguikey or ""):upper():gsub("%s+", "_")
            if candidate_fields[field] ~= nil then
                dd.add_binding_conflict(result, "UE4SS", "GUI Console toggle uses " .. tostring(debug_section.toggleguikey), "ue4ss-setting")
            end
        end
        return true
    end

    function dd.scan_ue4ss_registry_conflicts(value, result)
        if type(IsKeyBindRegistered) ~= "function" then
            result.registry_scan = "unavailable"
            return false
        end

        local key_table = rawget(global_table, "Key")
        local modifier_table = rawget(global_table, "ModifierKey")
        if key_table == nil or modifier_table == nil then
            result.registry_scan = "enum-tables-unavailable"
            return false
        end

        local queried = 0
        local registered = 0
        for _, chord in ipairs(dd.ue4ss_candidate_chords(value)) do
            local key_value = nil
            local ok_key = pcall(function() key_value = key_table[chord.key_field] end)
            if ok_key and key_value ~= nil then
                local modifiers = {}
                local modifiers_ok = true
                for _, modifier_field in ipairs(chord.modifier_fields or {}) do
                    local modifier_value = nil
                    local ok_modifier = pcall(function() modifier_value = modifier_table[modifier_field] end)
                    if not ok_modifier or modifier_value == nil then
                        modifiers_ok = false
                        break
                    end
                    modifiers[#modifiers + 1] = modifier_value
                end
                if modifiers_ok then
                    queried = queried + 1
                    local ok_registered, is_registered = pcall(IsKeyBindRegistered, key_value, modifiers)
                    if ok_registered and is_registered == true then
                        registered = registered + 1
                        if result.registry_explained == nil or not result.registry_explained[chord.fingerprint] then
                            dd.add_binding_conflict(
                                result,
                                "UE4SS registry",
                                "Another registered shortcut uses " .. dd.ue4ss_chord_label(chord),
                                "ue4ss-registry",
                                chord.fingerprint
                            )
                        end
                    end
                end
            end
        end
        result.registry_scan = "ok"
        result.registry_queries = queried
        result.registry_registered = registered
        return true
    end

    dd.binding_conflict_priority = modui.Input.Conflict.Priority

    function dd.refresh_binding_conflicts(controller, only_kind)
        local kinds = only_kind ~= nil and { tostring(only_kind) } or { "keyboard", "controller" }
        if not valid(controller) then
            local _, resolved_controller = get_player_and_controller()
            controller = resolved_controller
        end

        for _, kind in ipairs(kinds) do
            if kind == "keyboard" or kind == "controller" then
                local value = kind == "keyboard" and tostring(config.menu_keybind) or tostring(config.controller_menu_bind)
                local result = {
                    kind = kind,
                    value = value,
                    items = {},
                    seen = {},
                    registry_explained = {},
                    game_scan = "not-run",
                    registry_scan = kind == "keyboard" and "not-run" or "not-applicable",
                }

                dd.internal_menu_conflicts(kind, value, result)
                if kind == "keyboard" then
                    dd.scan_known_ue4ss_keybinds(value, result)
                    dd.scan_ue4ss_settings_conflicts(value, result)
                    dd.scan_ue4ss_registry_conflicts(value, result)
                end
                dd.scan_game_mapping_conflicts(controller, value, result)

                table.sort(result.items, function(a, b)
                    local pa = dd.binding_conflict_priority(a)
                    local pb = dd.binding_conflict_priority(b)
                    if pa ~= pb then return pa < pb end
                    local aa = tostring(a.source) .. "|" .. tostring(a.detail)
                    local bb = tostring(b.source) .. "|" .. tostring(b.detail)
                    return aa < bb
                end)
                result.count = #result.items
                dd.binding_conflicts[kind] = result

                diag("input.bindConflictScan", {
                    status = "complete",
                    kind = kind,
                    value = value,
                    label = dd.binding_label(value, value),
                    knownConflicts = result.count,
                    gameScan = result.game_scan,
                    gameMappings = result.game_mapping_count or 0,
                    gameMatches = result.game_matches or 0,
                    registryScan = result.registry_scan,
                    registryQueries = result.registry_queries or 0,
                    registryRegistered = result.registry_registered or 0,
                })
                for index, item in ipairs(result.items) do
                    diag("input.bindConflict", {
                        kind = kind,
                        index = index,
                        source = item.source,
                        detail = item.detail,
                        category = item.category,
                    })
                end
            end
        end
        return true
    end

    function dd.binding_conflict_state(kind)
        local expected = kind == "keyboard" and tostring(config.menu_keybind) or tostring(config.controller_menu_bind)
        return modui.Input.Conflict.State(dd.binding_conflicts, kind, expected)
    end

    function dd.binding_conflict_badge(kind)
        return modui.Input.Conflict.Badge(dd.binding_conflict_state(kind))
    end

    function dd.binding_conflict_details(kind)
        return modui.Input.Conflict.Details(dd.binding_conflict_state(kind))
    end

    function dd.binding_conflict_status_suffix(kind)
        return modui.Input.Conflict.StatusSuffix(dd.binding_conflict_state(kind))
    end

    -- Stick directions need more protection than ordinary analog thresholds. A sprung
    -- thumbstick can briefly cross the opposite side (or an orthogonal axis) while it
    -- returns to center. v0.9.68 treated those crossings as new sequence presses. Capture
    -- one dominant cardinal direction at a time, then require three genuinely neutral
    -- capture polls before that same stick can produce another directional step. Pass 174
    -- calibrates those capture polls to the user's two known cardinal sweeps.
    function dd.capture_stick_direction_token(controller, stick_name)
        if not dd.bind_capture_active() then return nil end
        local state = dd.bind_capture
        state.stick_capture = state.stick_capture or {}
        local gate = state.stick_capture[stick_name]
        local profile = type(state.controller_profile) == "table" and state.controller_profile
            or current_controller_profile(false)
            or { stick_activation = 0.12, stick_release = 0.08, stick_neutral = 0.05, dominance_margin = 0.05, neutral_ticks = 3 }
        if type(gate) ~= "table" then
            gate = modui.Input.Capture.NewStickGate(tonumber(profile.neutral_ticks) or 3)
            state.stick_capture[stick_name] = gate
        end

        local prefix = stick_name == "left" and "Gamepad_Left" or "Gamepad_Right"
        local x, x_source, x_host, x_frame = dd.capture_analog_value(controller, prefix .. "X")
        local y, y_source, y_host, y_frame = dd.capture_analog_value(controller, prefix .. "Y")
        x = tonumber(x) or 0.0
        y = tonumber(y) or 0.0

        -- Pass 174 calibration: while hosted controller capture is authoritative, only feed
        -- the cardinal gate a coherent stick frame. The supplied two L1+sweep rounds showed
        -- the old independent-axis mailbox could combine a real ~0.13-0.76 scalar on the
        -- intended axis with a synthetic +/-1 orthogonal fallback. Waiting for one matched
        -- 20 ms frame fixes that race; the lower 0.12 activation reflects the measured
        -- smallest deliberate cardinal scalar while neutral samples were consistently ~0.
        if x_host == true and y_host == true and tonumber(x_frame) ~= nil and tonumber(y_frame) ~= nil
            and tonumber(x_frame) ~= tonumber(y_frame) then
            if gate.incoherent_frame_logged ~= true then
                gate.incoherent_frame_logged = true
                diag("input.bindCaptureAnalog", {
                    status = "waiting-coherent-frame", stick = stick_name,
                    x = string.format("%.3f", x), y = string.format("%.3f", y),
                    xFrame = tonumber(x_frame) or 0, yFrame = tonumber(y_frame) or 0,
                    xSource = tostring(x_source or "unknown"), ySource = tostring(y_source or "unknown"),
                })
            end
            return nil
        end
        gate.incoherent_frame_logged = false

        local raw_x, raw_y = x, y
        if type(ControllerProfile) == "table" and type(ControllerProfile.NormalizeStick) == "function" then
            local normalize_ok, normalized_x, normalized_y = pcall(ControllerProfile.NormalizeStick, stick_name, x, y, profile)
            if normalize_ok and tonumber(normalized_x) ~= nil and tonumber(normalized_y) ~= nil then
                x, y = tonumber(normalized_x), tonumber(normalized_y)
            end
        end

        local token, transition = modui.Input.Capture.ResolveStickDirection(gate, stick_name, x, y, {
            activation = tonumber(profile.stick_activation) or 0.12,
            release = tonumber(profile.stick_release) or 0.08,
            neutral = tonumber(profile.stick_neutral) or 0.05,
            dominance_margin = tonumber(profile.dominance_margin) or 0.05,
            required_neutral_ticks = tonumber(profile.neutral_ticks) or 3,
        })
        if type(transition) == "table" and transition.status ~= nil then
            diag("input.bindCaptureAnalog", {
                status = transition.status,
                stick = stick_name,
                token = transition.token,
                x = string.format("%.3f", x),
                y = string.format("%.3f", y),
                rawX = string.format("%.3f", raw_x),
                rawY = string.format("%.3f", raw_y),
                xSource = tostring(x_source or "unknown"),
                ySource = tostring(y_source or "unknown"),
                xFrame = tonumber(x_frame) or 0,
                yFrame = tonumber(y_frame) or 0,
            })
        end
        return token
    end

    local function set_host_capture_request(kind, active)
        if (kind ~= "controller" and kind ~= "keyboard") or type(host_capture_request_writer) ~= "function" then
            return false, "host-" .. tostring(kind or "unknown") .. "-capture-unavailable"
        end
        local ok, result, detail = pcall(host_capture_request_writer, kind, active == true)
        if not ok then return false, tostring(result) end
        if result ~= true then return false, tostring(detail or result) end
        return true, tostring(detail or (active and kind or "off"))
    end

    local function release_host_capture_request(state, reason)
        if type(state) ~= "table" or state.host_capture_requested ~= true then return false end
        local kind = tostring(state.kind or "controller")
        local ok, detail = set_host_capture_request(kind, false)
        state.host_capture_requested = false
        diag("input.bindCaptureHost", {
            status = ok and "released" or "release-fallback",
            kind = kind,
            reason = tostring(reason or "capture-end"),
            detail = tostring(detail or ""),
        })
        return ok
    end

    function dd.capture_scan_inputs(controller, kind)
        local active = {}
        local host_rising = {}
        if kind == "keyboard" then
            for _, key_name in ipairs(dd.keyboard_capture_keys or {}) do
                local down, source, host_ready = nil, nil, false
                if type(host_key_reader) == "function" then
                    local ok_host, host_down, host_source, ready, press_delta = pcall(host_key_reader, key_name)
                    if ok_host then
                        down, source, host_ready = host_down, host_source, ready == true
                        if host_ready and (tonumber(press_delta) or 0) > 0 then
                            for _ = 1, math.floor(tonumber(press_delta) or 0) do host_rising[#host_rising + 1] = key_name end
                        end
                    end
                end
                if not host_ready or down == nil then
                    down = select(1, dd.input_key_down(controller, key_name))
                    source = key_name
                else
                    source = "ModUIHost:" .. tostring(source or key_name)
                end
                if down == true then
                    active[#active + 1] = key_name
                    local state = dd.bind_capture
                    if type(state) == "table" then
                        state.host_key_evidence = state.host_key_evidence or {}
                        if state.host_key_evidence[key_name] ~= source then
                            state.host_key_evidence[key_name] = source
                            diag("input.bindCaptureDigital", { status = "pressed", key = key_name, source = source })
                        end
                    end
                end
            end
        else
            for _, key_name in ipairs(dd.controller_capture_keys or {}) do
                local down, source, host_ready = nil, nil, false
                if type(host_key_reader) == "function" then
                    local ok_host, host_down, host_source, ready, press_delta = pcall(host_key_reader, key_name)
                    if ok_host then
                        down, source, host_ready = host_down, host_source, ready == true
                        if host_ready and (tonumber(press_delta) or 0) > 0 then
                            for _ = 1, math.floor(tonumber(press_delta) or 0) do host_rising[#host_rising + 1] = key_name end
                        end
                    end
                end
                if not host_ready or down == nil then
                    down = select(1, dd.input_key_down(controller, key_name))
                    source = key_name
                else
                    source = "ModUIHost:" .. tostring(source or key_name)
                end
                if down == true then
                    active[#active + 1] = key_name
                    local state = dd.bind_capture
                    if type(state) == "table" then
                        state.host_key_evidence = state.host_key_evidence or {}
                        if state.host_key_evidence[key_name] ~= source then
                            state.host_key_evidence[key_name] = source
                            diag("input.bindCaptureDigital", { status = "pressed", key = key_name, source = source })
                        end
                    end
                end
            end

            local left_stick = dd.capture_stick_direction_token(controller, "left")
            if left_stick ~= nil then active[#active + 1] = left_stick end
            local right_stick = dd.capture_stick_direction_token(controller, "right")
            if right_stick ~= nil then active[#active + 1] = right_stick end

            -- Triggers are one-sided axes, so spring-center direction reversal is not an
            -- issue. Keep the existing activation/release hysteresis for them.
            for _, axis in ipairs(dd.controller_capture_axes or {}) do
                if tostring(axis.key):find("TriggerAxis", 1, true) ~= nil then
                    local value = select(1, dd.capture_analog_value(controller, axis.key))
                    if value ~= nil then
                        local already_seen = dd.bind_capture_active() and dd.bind_capture.seen ~= nil and dd.bind_capture.seen[axis.token] == true
                        local profile = type(dd.bind_capture.controller_profile) == "table" and dd.bind_capture.controller_profile or {}
                        local is_active = nil
                        if type(ControllerProfile) == "table" and type(ControllerProfile.TriggerActive) == "function" then
                            is_active = select(1, ControllerProfile.TriggerActive(value, already_seen, profile))
                        end
                        if is_active == nil then
                            local threshold = already_seen and (tonumber(profile.trigger_release) or 0.25)
                                or (tonumber(profile.trigger_activation) or 0.60)
                            is_active = value >= threshold
                        end
                        if is_active then active[#active + 1] = axis.token end
                    end
                end
            end
        end
        return active, host_rising
    end

    function dd.capture_inputs_label(inputs)
        return modui.Input.Capture.InputsLabel(inputs, modui.Input.Binding, config.modifier_sides_equivalent)
    end

    function dd.start_bind_capture(kind)
        if kind ~= "keyboard" and kind ~= "controller" then return false end
        if not active_ui_session_valid() then return false end

        local prior_status = tostring(ui.status or "")
        local started_clock, started_clock_source = dd.input_time_seconds()
        local next_capture = modui.Input.Capture.NewState(kind, started_clock, started_clock_source)
        if next_capture == nil then return false end
        if kind == "controller" and type(ControllerProfile) == "table" then
            local profile = current_controller_profile(true)
            if type(profile) == "table" then next_capture.controller_profile = profile end
            diag("input.bindCaptureProfile", {
                status = type(next_capture.controller_profile) == "table" and "loaded" or "defaults",
                activation = type(next_capture.controller_profile) == "table" and next_capture.controller_profile.stick_activation or 0.12,
                release = type(next_capture.controller_profile) == "table" and next_capture.controller_profile.stick_release or 0.08,
                neutral = type(next_capture.controller_profile) == "table" and next_capture.controller_profile.stick_neutral or 0.05,
            })
        end

        -- Publish capture state only inside a guarded startup transaction. Pass 98
        -- exposed why this matters: a presentation exception after active=true but
        -- before the poll was armed left every controller route suppressed forever.
        dd.bind_capture = next_capture
        if kind == "controller" or kind == "keyboard" then
            local host_requested, host_detail = set_host_capture_request(kind, true)
            next_capture.host_capture_requested = host_requested == true
            diag("input.bindCaptureHost", {
                status = host_requested and "requested" or "consumer-fallback",
                kind = kind,
                detail = tostring(host_detail or ""),
            })
        end
        ui.status = kind == "keyboard"
            and "Recorder armed. Release any keyboard keys, then press the combination you want. Release all keys to save. Esc / Circle alone cancels."
            or "Recorder armed. Release any controller inputs, then press buttons and/or move analog controls. Release everything to save. Esc / Circle alone cancels."

        local poll_ok, poll_result = true, true
        if dd.arm_open_bind_poll ~= nil then
            poll_ok, poll_result = pcall(dd.arm_open_bind_poll)
        end
        local render_ok, render_error = pcall(set_ui_text)
        local poll_ready = poll_ok and poll_result ~= false

        if not poll_ready or not render_ok then
            release_host_capture_request(dd.bind_capture, "start-rollback")
            dd.bind_capture = { active = false }
            ui.status = "Binding recorder could not start; previous binding kept."
            diag("input.bindCapture", {
                status = "start-rollback",
                kind = kind,
                pollOk = poll_ok,
                pollReady = poll_ready,
                pollError = poll_ok and nil or tostring(poll_result),
                renderOk = render_ok,
                renderError = render_ok and nil or tostring(render_error),
            })
            log("binding capture startup rolled back kind=" .. tostring(kind)
                .. " pollReady=" .. tostring(poll_ready)
                .. " renderOk=" .. tostring(render_ok)
                .. (render_ok and "" or (" error=" .. tostring(render_error))))
            if not pcall(set_ui_text) then ui.status = prior_status end
            return false
        end

        diag("input.bindCapture", { status = "started", kind = kind })
        log("binding capture started kind=" .. kind)
        return true
    end

    function dd.cancel_bind_capture(source)
        if not dd.bind_capture_active() then return false end
        local kind = dd.bind_capture.kind
        release_host_capture_request(dd.bind_capture, "cancel")
        dd.bind_capture = { active = false }
        ui.status = "Binding recording cancelled; previous " .. (kind == "keyboard" and "keyboard" or "controller") .. " binding kept."
        diag("input.bindCapture", { status = "cancelled", kind = kind, source = tostring(source or "cancel") })
        log("binding capture cancelled kind=" .. tostring(kind) .. " source=" .. tostring(source or "cancel"))
        set_ui_text()
        return true
    end

    function dd.commit_bind_capture()
        if not dd.bind_capture_active() then return false end
        local state = dd.bind_capture
        local resolved = modui.Input.Capture.ResolveCommit(state)
        if resolved == nil then return false end
        if resolved.cancel == true then
            return dd.cancel_bind_capture(resolved.cancel_reason)
        end

        local committed_tokens = resolved.tokens or {}
        local serialized = tostring(resolved.serialized or "")
        local kind = tostring(resolved.kind or state.kind or "")
        local label = dd.binding_label(serialized, serialized)

        release_host_capture_request(state, "commit")
        dd.bind_capture = { active = false }
        if kind == "keyboard" then
            config.menu_keybind = serialized
            dd.sync_open_bind_labels()
            dd.save_mod_setting("captured menu_keybind=" .. serialized)
            dd.open_bind_keyboard_latched = false
            dd.open_bind_sequence_state.keyboard = nil
        else
            config.controller_menu_bind = serialized
            dd.save_mod_setting("captured controller_menu_bind=" .. serialized)
            dd.open_bind_controller_latched = false
            dd.open_bind_sequence_state.controller = nil
        end
        arm_open_bind_neutral("bind-capture-commit:" .. kind)

        if type(on_binding_changed) == "function" then
            local notify_ok, notify_result = pcall(on_binding_changed, kind, serialized)
            if not notify_ok then
                diag("input.hostRegistration", {
                    status = "binding-change-notify-exception",
                    kind = kind,
                    value = serialized,
                    error = tostring(notify_result),
                })
            elseif notify_result == true then
                diag("input.hostRegistration", {
                    status = "binding-change-notify-accepted",
                    kind = kind,
                    value = serialized,
                })
            else
                diag("input.hostRegistration", {
                    status = "binding-change-notify-rejected",
                    kind = kind,
                    value = serialized,
                    result = tostring(notify_result),
                })
            end
        else
            diag("input.hostRegistration", {
                status = "binding-change-notify-unavailable",
                kind = kind,
                value = serialized,
            })
        end

        local _, controller = get_player_and_controller()
        if dd.refresh_binding_conflicts ~= nil then dd.refresh_binding_conflicts(controller, kind) end
        ui.status = (kind == "keyboard" and "Open keybind set to " or "Controller bind set to ")
            .. label .. "." .. (dd.binding_conflict_status_suffix ~= nil and dd.binding_conflict_status_suffix(kind) or "")

        diag("input.bindCapture", {
            status = "committed",
            kind = kind,
            value = serialized,
            label = label,
            mode = tostring(resolved.mode or "chord"),
            steps = tonumber(resolved.steps) or #committed_tokens,
        })
        log("binding capture committed kind=" .. tostring(kind)
            .. " mode=" .. tostring(resolved.mode or "chord")
            .. " value=" .. serialized .. " label=" .. label)
        set_ui_text()
        return true
    end

    function dd.update_bind_capture(controller)
        if not dd.bind_capture_active() then return false end
        local state = dd.bind_capture
        local active, host_rising = dd.capture_scan_inputs(controller, state.kind)
        host_rising = type(host_rising) == "table" and host_rising or {}
        local now, clock_source = dd.input_time_seconds()
        now = tonumber(now)
        clock_source = tostring(clock_source or "unknown")
        if state.clock_source ~= nil and state.clock_source ~= clock_source then
            -- A clock-domain change should never strand the starter debounce. Rebase
            -- its short grace window to the current clock and continue recording.
            state.starter_suppress_until = nil
        end
        state.clock_source = clock_source

        if state.phase == "wait_clear" then
            if #active == 0 then
                state.phase = "waiting"
                state.previous_active = {}
                state.starter_suppress_until = now ~= nil and (now + 0.22) or nil
                ui.status = state.kind == "keyboard"
                    and "Recording keyboard bind: press a chord or repeated-key sequence, then release all keys to save. Esc alone cancels."
                    or "Recording controller bind: press a chord or repeated-button sequence, then release everything to save. Circle alone cancels."
                diag("input.bindCapture", { status = "armed-after-clear", kind = state.kind, starterGraceMs = 220, clock = clock_source })
                set_ui_text()
            end
            return true
        end

        if now ~= nil and state.starter_suppress_until ~= nil and now < state.starter_suppress_until
            and #active == 1 and active[1] == state.starter_token then
            active = {}
            host_rising = {}
        end

        local active_set = {}
        for _, token in ipairs(active) do active_set[token] = true end
        local previous = state.previous_active or {}
        local rising = {}
        local host_rising_counts = {}
        for _, token in ipairs(host_rising) do
            host_rising_counts[token] = (host_rising_counts[token] or 0) + 1
            rising[#rising + 1] = token
        end
        for _, token in ipairs(active) do
            -- Hosted digital pressSequence is authoritative when present. It preserves
            -- a false->true edge even if the consumer reads only after the key is down
            -- again. Analog/fallback inputs retain the ordinary active-set rising edge.
            if host_rising_counts[token] == nil and previous[token] ~= true then
                rising[#rising + 1] = token
            end
        end

        if state.phase == "waiting" then
            if #active == 0 and #host_rising == 0 then
                state.previous_active = active_set
                return true
            end
            -- A complete hosted press/release can occur between consumer polls. A retained
            -- pressSequence edge is sufficient to enter recording even when the latest
            -- physical state is already neutral; the recording can then commit that pulse.
            state.phase = "recording"
        end

        if state.phase == "recording" then
            for _, token in ipairs(active) do
                if not state.seen[token] then
                    state.seen[token] = true
                    state.order[#state.order + 1] = token
                end
            end
            for _, token in ipairs(rising) do
                state.press_order[#state.press_order + 1] = token
            end

            if #active == 0 then
                state.previous_active = active_set
                return dd.commit_bind_capture()
            end

            state.previous_active = active_set
            local display_tokens = #(state.press_order or {}) > 0 and state.press_order or state.order
            local display = dd.capture_inputs_label(display_tokens)
            if display ~= state.last_display then
                state.last_display = display
                ui.status = "Recording: " .. display .. " — release all controls to save. Esc / Circle alone cancels."
                set_ui_text()
            end
        else
            state.previous_active = active_set
        end
        return true
    end

    local function consume_host_native_input_mirror()
        if type(host_native_input_reader) ~= "function" then return 0 end
        local ok, batch, active = pcall(host_native_input_reader)
        if not ok then
            diag("input.hostNativeMirror", { status = "reader-error", error = tostring(batch) })
            return 0
        end
        if active ~= true or type(batch) ~= "table" then return 0 end
        local events = type(batch.events) == "table" and batch.events or {}
        if batch.dropped == true then
            diag("input.hostNativeMirror", { status = "ring-gap", sequence = batch.sequence, count = #events })
        end
        local dispatched = 0
        for _, event in ipairs(events) do
            local source = "ModUIHost:" .. tostring(event.source or "WBP_InputListener")
            diag("input.hostNativeMirror", {
                status = "observed",
                input = event.input,
                source = source,
                sequence = event.sequence,
                requestSequence = event.requestSequence,
                generation = event.generation,
                pointerSnapshot = event.pointerX ~= nil,
                pointerX = event.pointerX,
                pointerY = event.pointerY,
                viewportWidth = event.viewportWidth,
                viewportHeight = event.viewportHeight,
                pointerSource = event.pointerSource,
            })
            if type(host_native_input_dispatch) == "function" then
                local dispatch_ok, handled, detail = pcall(host_native_input_dispatch, event, source)
                if not dispatch_ok then
                    diag("input.hostNativeSemantic", {
                        status = "dispatch-error",
                        input = event.input,
                        source = source,
                        sequence = event.sequence,
                        error = tostring(handled),
                    })
                elseif handled == true then
                    dispatched = dispatched + 1
                    diag("input.hostNativeSemantic", {
                        status = "dispatched",
                        input = event.input,
                        source = source,
                        sequence = event.sequence,
                        detail = detail,
                    })
                elseif tostring(detail or "") ~= "pointer-local" then
                    diag("input.hostNativeSemantic", {
                        status = "ignored",
                        input = event.input,
                        source = source,
                        sequence = event.sequence,
                        detail = detail,
                    })
                end
            end
        end
        return #events, dispatched
    end

    local function consume_host_navigation_events(suppress_reason)
        if type(host_navigation_reader) ~= "function" then return 0 end
        local ok, batch, active = pcall(host_navigation_reader)
        if not ok then
            diag("input.hostNavigation", { status = "reader-error", error = tostring(batch) })
            return 0
        end
        if active ~= true or type(batch) ~= "table" then return 0 end
        local events = type(batch.events) == "table" and batch.events or {}
        if batch.dropped == true then
            diag("input.hostNavigation", {
                status = "ring-gap",
                sequence = batch.sequence,
                count = #events,
            })
        end
        local dispatched = 0
        for _, event in ipairs(events) do
            if suppress_reason ~= nil then
                if suppress_reason ~= "settings-closed" then
                    diag("input.hostNavigation", {
                        status = "consumed-suppressed",
                        reason = tostring(suppress_reason),
                        action = event.action,
                        source = event.source,
                        sequence = event.sequence,
                    })
                end
            elseif ui.open and not ui.closing then
                local action = tostring(event.action or "")
                local callback = nil
                if action == "up" then callback = runtime.ui_up_key
                elseif action == "down" then callback = runtime.ui_down_key
                elseif action == "left" then callback = runtime.ui_left_key
                elseif action == "right" then callback = runtime.ui_right_key
                elseif action == "enter" then callback = runtime.ui_return_key
                elseif action == "tab" then callback = runtime.ui_tab_key
                elseif action == "a" then callback = runtime.ui_a_key
                elseif action == "d" then callback = runtime.ui_d_key
                elseif action == "page-up" then callback = runtime.ui_page_up_key
                elseif action == "page-down" then callback = runtime.ui_page_down_key
                elseif action == "escape" then callback = runtime.ui_escape_key
                elseif action == "reset-row" then callback = runtime.ui_reset_row_key
                end
                if type(callback) == "function" then
                    diag("input.hostNavigation", {
                        status = "triggered",
                        action = action,
                        source = "ModUIHost:" .. tostring(event.source or action),
                        sequence = event.sequence,
                    })
                    callback()
                    dispatched = dispatched + 1
                else
                    diag("input.hostNavigation", {
                        status = "unknown-action",
                        action = action,
                        sequence = event.sequence,
                    })
                end
            end
        end
        return dispatched
    end

    -- Pass 146 bounded callback-identity breadcrumbs. These diagnostics use primitive/Lua
    -- state only and are emitted only for the first bounded set of active-menu phases per
    -- Settings generation. If UE4SS dies inside a native method lookup, the final breadcrumb
    -- identifies the exact delayed-poll phase entered before the uncatchable native AV.
    local delayed_trace_generation = -1
    local delayed_trace_budget = 0
    local delayed_trace_sequence = 0
    local function trace_delayed_active_poll(phase)
        if ui.open ~= true then return end
        local generation = tonumber(ui.active_generation) or 0
        if generation ~= delayed_trace_generation then
            delayed_trace_generation = generation
            delayed_trace_budget = 160
            delayed_trace_sequence = 0
        end
        if delayed_trace_budget <= 0 then return end
        delayed_trace_budget = delayed_trace_budget - 1
        delayed_trace_sequence = delayed_trace_sequence + 1
        diag("input.delayedPollBreadcrumb", {
            phase = tostring(phase or "unknown"),
            generation = generation,
            sequence = delayed_trace_sequence,
            budgetRemaining = delayed_trace_budget,
            closing = ui.closing == true,
            neutralRequired = dd.open_bind_transition_neutral_required == true,
            loadMapFrozen = dd.open_bind_load_map_frozen == true,
        })
    end

    function dd.open_bind_poll_game()
        -- Pass 143 LoadMap hard boundary. A delayed poll can race with map teardown even
        -- when Settings is closed. During the explicit pre/post freeze, this branch is
        -- intentionally primitive-only: do not unwrap/validate/resolve any UObject.
        if dd.open_bind_load_map_frozen == true then
            local scheduled = dd.schedule_open_bind_poll(250, dd.open_bind_poll_game)
            if not scheduled then
                dd.open_bind_poll_armed = false
                log("open-binding LoadMap freeze polling stopped: ExecuteInGameThreadWithDelay unavailable")
            end
            return
        end

        -- Pass 145 close-quarantine hard boundary. The crash bundle symbolized inside
        -- UObject::GetFunctionByNameInChain/IsA from an EngineTick-delayed Lua callback after
        -- a shell was opened and then closed almost immediately. While the shell is quarantined,
        -- reschedule using primitives only: no retained wrapper validation, controller resolution,
        -- or UObject method lookup.
        if ui.closing == true then
            local scheduled = dd.schedule_open_bind_poll(250, dd.open_bind_poll_game)
            if not scheduled then
                dd.open_bind_poll_armed = false
                log("open-binding close-quarantine polling stopped: ExecuteInGameThreadWithDelay unavailable")
            end
            return
        end

        -- Defensive cleanup for any alternate opening path that did not pass through this
        -- module's direct or pending toggle branches.
        if ui.open == true then clear_pending_open_intent("settings-active") end

        -- Pass 131 performance corrective: once the standalone host is acknowledged,
        -- a CLOSED Settings session only needs the tiny cross-state open-event mailbox
        -- plus a drain of fixed keyboard-navigation events. Do not resolve/validate the
        -- PlayerController, sample the native-UI observer, drain native-listener events,
        -- or run Settings/browser/capture work on every idle tick. If an open event
        -- arrives we re-enter the proven controller path before toggling the menu.
        local capture_active = dd.bind_capture_active()
        local browser_active_now = dd.voice_browser_active ~= nil and dd.voice_browser_active()
        if not ui.open and not capture_active and not browser_active_now
            and type(host_event_reader) == "function" then
            local host_ok, host_event, host_active = pcall(host_event_reader)
            if host_ok then
                observe_open_bind_host_management(host_active == true, "settings-closed")
            end
            if host_ok and host_active == true then
                consume_host_navigation_events("settings-closed")

                if type(host_event) == "table" or dd.open_bind_transition_neutral_required == true then
                    -- Revalidate the retained consumer controller only when a real OPEN
                    -- event or release/rearm sample needs to cross into the TTS state. This
                    -- preserves the idle mailbox cost profile outside those bounded windows.
                    local controller, controller_available = dd.get_open_bind_controller()
                    local context_allowed, context_reason = false, "controller-unavailable"
                    if controller_available then
                        context_allowed, context_reason = open_context_allowed(controller)
                    end
                    local transition_allowed, transition_reason = false, "controller-unavailable"
                    if controller_available and context_allowed then
                        transition_allowed, transition_reason = transition_gate_allowed(controller)
                    end

                    local pending_present = false
                    if controller_available and context_allowed and transition_allowed then
                        pending_present = select(1, dispatch_pending_open_intent(controller, "settings-closed-host"))
                    end

                    if not pending_present and controller_available and context_allowed and transition_allowed
                        and consume_open_bind_neutral_sample(controller, "settings-closed-host")
                        and type(host_event) == "table" then
                        diag("input.openHostEvent", {
                            status = "triggered",
                            action = host_event.action,
                            kind = host_event.kind,
                            sequence = host_event.sequence,
                            open = false,
                            idleFastPath = true,
                        })
                        clear_pending_open_intent("direct-host-toggle")
                        arm_open_bind_neutral("host-toggle:" .. tostring(host_event.kind or "host"),
                            tostring(host_event.kind or "") == "controller" and "controller-chord-break" or "full")
                        request_ui_toggle(tostring(host_event.kind or "host"), "closed-host-event", true)
                    elseif not pending_present and type(host_event) == "table" then
                        local suppressed_reason = context_reason
                        if controller_available and context_allowed and not transition_allowed then
                            suppressed_reason = transition_reason
                        elseif controller_available and context_allowed and transition_allowed then
                            suppressed_reason = "neutral-rearm"
                        end
                        local queued = controller_available and context_allowed
                            and queue_pending_open_intent(host_event.kind,
                                "host-event:" .. tostring(suppressed_reason or "controller-unavailable"))
                        diag("input.openHostEvent", {
                            status = queued and "queued" or "suppressed",
                            reason = tostring(suppressed_reason or "controller-unavailable"),
                            sequence = host_event.sequence,
                            idleFastPath = true,
                        })
                        if not queued then
                            arm_open_bind_neutral("host-event-suppressed:" .. tostring(suppressed_reason or "controller-unavailable"))
                        end
                    end
                end

                local scheduled = dd.schedule_open_bind_poll(50, dd.open_bind_poll_game)
                if not scheduled then
                    dd.open_bind_poll_armed = false
                    log("open-binding idle mailbox polling stopped: ExecuteInGameThreadWithDelay unavailable")
                end
                return
            elseif not host_ok then
                diag("input.hostEvent", { status = "reader-error-idle-fallback", error = tostring(host_event) })
            end
        end

        -- Pass 134 transition-crash isolation: when this consumer intentionally opts out of
        -- standalone physical OPEN-HOTKEY ownership, keep the old consumer binding evaluator but
        -- preserve Pass 131's closed-menu cost profile. While Settings/browser/capture are inactive,
        -- do ONLY cached-controller validation + the two configured open bindings; skip native UI
        -- observation, native-listener mirror drains, analog/details work, and capture polling.
        if not ui.open and not capture_active and not browser_active_now then
            consume_host_navigation_events("settings-closed-consumer-hotkey")
            local controller, controller_available = dd.get_open_bind_controller()
            local context_allowed, context_reason = false, "controller-unavailable"
            if controller_available then
                context_allowed, context_reason = open_context_allowed(controller)
            end
            local transition_allowed, transition_reason = false, "controller-unavailable"
            if controller_available and context_allowed then
                transition_allowed, transition_reason = transition_gate_allowed(controller)
            end
            if controller_available and context_allowed and transition_allowed then
                local pending_present = select(1,
                    dispatch_pending_open_intent(controller, "settings-closed-consumer"))
                if pending_present then
                    local scheduled = dd.schedule_open_bind_poll(50, dd.open_bind_poll_game)
                    if not scheduled then
                        dd.open_bind_poll_armed = false
                        log("consumer pending open-intent polling stopped: ExecuteInGameThreadWithDelay unavailable")
                    end
                    return
                end

                if not consume_open_bind_neutral_sample(controller, "settings-closed-consumer") then
                    local scheduled = dd.schedule_open_bind_poll(50, dd.open_bind_poll_game)
                    if not scheduled then
                        dd.open_bind_poll_armed = false
                        log("consumer open-hotkey neutral-edge polling stopped: ExecuteInGameThreadWithDelay unavailable")
                    end
                    return
                end

                local keyboard_down, keyboard_error = false, nil
                local controller_down, controller_error = false, nil
                if dd.binding_is_sequence ~= nil and dd.binding_is_sequence(config.menu_keybind) then
                    keyboard_down, keyboard_error = dd.binding_sequence_triggered(controller, config.menu_keybind, "keyboard")
                else
                    keyboard_down, keyboard_error = dd.binding_is_down(controller, config.menu_keybind)
                end
                if dd.binding_is_sequence ~= nil and dd.binding_is_sequence(config.controller_menu_bind) then
                    controller_down, controller_error = dd.binding_sequence_triggered(controller, config.controller_menu_bind, "controller")
                else
                    controller_down, controller_error = dd.binding_is_down(controller, config.controller_menu_bind)
                end

                if keyboard_down == nil and keyboard_error ~= nil and not dd.open_bind_poll_fail_logged then
                    dd.open_bind_poll_fail_logged = true
                    log("consumer open-hotkey keyboard query unavailable: " .. tostring(keyboard_error))
                elseif controller_down == nil and controller_error ~= nil and not dd.open_bind_poll_fail_logged then
                    dd.open_bind_poll_fail_logged = true
                    log("consumer open-hotkey controller query unavailable: " .. tostring(controller_error))
                elseif keyboard_down ~= nil or controller_down ~= nil then
                    dd.open_bind_poll_fail_logged = false
                end

                local toggle_requested = false
                if keyboard_down and not dd.open_bind_keyboard_latched then
                    dd.open_bind_keyboard_latched = true
                    diag("input.openConsumerFastPath", {
                        status = "triggered", kind = "keyboard", bind = config.menu_keybind,
                        open = false, pass134Isolation = true,
                    })
                    clear_pending_open_intent("direct-consumer-toggle")
                    arm_open_bind_neutral("consumer-toggle:keyboard")
                    request_ui_toggle("keyboard", "closed-consumer-keyboard", true)
                    toggle_requested = true
                elseif not keyboard_down then
                    dd.open_bind_keyboard_latched = false
                end

                if not toggle_requested and controller_down and not dd.open_bind_controller_latched and not ui.closing then
                    dd.open_bind_controller_latched = true
                    diag("input.openConsumerFastPath", {
                        status = "triggered", kind = "controller", bind = config.controller_menu_bind,
                        open = false, pass134Isolation = true,
                    })
                    clear_pending_open_intent("direct-consumer-toggle")
                    arm_open_bind_neutral("consumer-toggle:controller", "controller-chord-break")
                    request_ui_toggle("controller", "closed-consumer-controller", true)
                    toggle_requested = true
                elseif not controller_down then
                    dd.open_bind_controller_latched = false
                end
            else
                if controller_available and context_allowed and not transition_allowed then
                    sample_transition_open_intent(controller, transition_reason)
                else
                    -- Never retain intent across a non-gameplay context or missing controller.
                    clear_pending_open_intent("consumer-context-blocked:" .. tostring(context_reason or "controller-unavailable"))
                    arm_open_bind_neutral("consumer-admission-blocked:" .. tostring(context_reason or transition_reason))
                end
            end

            local scheduled = dd.schedule_open_bind_poll((controller_available and context_allowed) and 50 or 250, dd.open_bind_poll_game)
            if not scheduled then
                dd.open_bind_poll_armed = false
                log("consumer open-hotkey fast polling stopped: ExecuteInGameThreadWithDelay unavailable")
            end
            return
        end

        trace_delayed_active_poll("active-before-controller")
        local controller, controller_available = dd.get_open_bind_controller()
        if controller_available then
            trace_delayed_active_poll("active-controller-ready")
            local host_managed, host_event = false, nil
            if type(host_event_reader) == "function" then
                local host_ok, event, active = pcall(host_event_reader)
                if host_ok then
                    host_managed = active == true
                    host_event = type(event) == "table" and event or nil
                    observe_open_bind_host_management(host_managed, "settings-active")
                else
                    diag("input.hostEvent", { status = "reader-error-fallback", error = tostring(event) })
                end
            end

            if dd.open_bind_transition_neutral_required == true
                and not (dd.bind_capture_active ~= nil and dd.bind_capture_active()) then
                consume_host_navigation_events("open-neutral-rearm")
                if host_event ~= nil then
                    diag("input.hostEvent", {
                        status = "consumed-suppressed", reason = "neutral-rearm",
                        sequence = host_event.sequence, kind = host_event.kind,
                    })
                end
                consume_open_bind_neutral_sample(controller, "settings-active")
                local scheduled = dd.schedule_open_bind_poll(50, dd.open_bind_poll_game)
                if not scheduled then
                    dd.open_bind_poll_armed = false
                    log("open-binding active neutral-edge polling stopped: ExecuteInGameThreadWithDelay unavailable")
                end
                return
            end

            trace_delayed_active_poll("active-before-native-mirror")
            consume_host_native_input_mirror()
            trace_delayed_active_poll("active-after-native-mirror")
            trace_delayed_active_poll("active-before-native-observer")
            local observer_ok, observer_error = pcall(dd.observe_native_ui_state, controller)
            trace_delayed_active_poll("active-after-native-observer")
            if not observer_ok and not dd.native_ui_observer.errorLogged then
                dd.native_ui_observer.errorLogged = true
                log("native UI observer error (open-bind poll preserved): " .. tostring(observer_error))
            end
            if dd.bind_capture_active() then
                consume_host_navigation_events("bind-capture")
                -- Drain any standalone hotkey event generated by controls being recorded so
                -- it cannot toggle the menu immediately after capture commits/cancels.
                if host_event ~= nil then
                    diag("input.hostEvent", { status = "consumed-suppressed", reason = "bind-capture", sequence = host_event.sequence, kind = host_event.kind })
                    arm_open_bind_neutral("host-event-suppressed:bind-capture")
                end
                dd.open_bind_poll_fail_logged = false
                local capture_ok, capture_error = pcall(dd.update_bind_capture, controller)
                if not capture_ok then
                    local failed_kind = tostring(dd.bind_capture.kind or "unknown")
                    release_host_capture_request(dd.bind_capture, "poll-error")
                    dd.bind_capture = { active = false }
                    ui.status = "Binding recording stopped safely after an internal recorder error; previous binding kept."
                    diag("input.bindCapture", { status = "poll-error-rollback", kind = failed_kind, error = tostring(capture_error) })
                    log("binding capture poll error; recorder rolled back kind=" .. failed_kind .. ": " .. tostring(capture_error))
                    pcall(set_ui_text)
                end
            else
                local navigation_suppress_reason = nil
                if not ui.open or ui.closing then navigation_suppress_reason = "settings-closed" end
                consume_host_navigation_events(navigation_suppress_reason)
                local browser_active = dd.voice_browser_active ~= nil and dd.voice_browser_active()
                local controller_settings_active = dd.controller_settings_active ~= nil and dd.controller_settings_active()
                local keyboard_down, keyboard_error = false, nil
                local controller_down, controller_error = false, nil
                if controller_settings_active then
                    local settings_ok, settings_error = pcall(dd.update_controller_settings_poll)
                    if not settings_ok then
                        diag("controller.settings", { status = "poll-error", error = tostring(settings_error) })
                        log("controller settings input poll error: " .. tostring(settings_error))
                    end
                    if host_event ~= nil then
                        diag("input.hostEvent", { status = "consumed-suppressed", reason = "controller-settings", sequence = host_event.sequence, kind = host_event.kind })
                        arm_open_bind_neutral("host-event-suppressed:controller-settings")
                    end
                elseif browser_active then
                    local browser_ok, browser_error = pcall(dd.update_voice_browser_poll, controller)
                    if not browser_ok then
                        diag("voice.browser", { action = "poll-error", error = tostring(browser_error) })
                        log("voice browser input poll error: " .. tostring(browser_error))
                    end
                    if host_event ~= nil then
                        diag("input.hostEvent", { status = "consumed-suppressed", reason = "voice-browser", sequence = host_event.sequence, kind = host_event.kind })
                        arm_open_bind_neutral("host-event-suppressed:voice-browser")
                    end
                elseif host_managed then
                    -- The standalone state owns physical OPEN-HOTKEY reads and the shared
                    -- RightY sample. This consumer poll remains for capture/browser/details
                    -- semantics plus the still-unmigrated physical capture sources.
                    if host_event ~= nil and not ui.closing then
                        diag("input.openHostEvent", { status = "triggered", action = host_event.action, kind = host_event.kind, sequence = host_event.sequence, open = ui.open })
                        arm_open_bind_neutral("host-toggle:" .. tostring(host_event.kind or "host"),
                            tostring(host_event.kind or "") == "controller" and "controller-chord-break" or "full")
                        request_ui_toggle(tostring(host_event.kind or "host"), "active-host-event", false)
                    end
                else
                    trace_delayed_active_poll("active-before-binding-eval")
                    if dd.binding_is_sequence ~= nil and dd.binding_is_sequence(config.menu_keybind) then
                        keyboard_down, keyboard_error = dd.binding_sequence_triggered(controller, config.menu_keybind, "keyboard")
                    else
                        keyboard_down, keyboard_error = dd.binding_is_down(controller, config.menu_keybind)
                    end
                    if dd.binding_is_sequence ~= nil and dd.binding_is_sequence(config.controller_menu_bind) then
                        controller_down, controller_error = dd.binding_sequence_triggered(controller, config.controller_menu_bind, "controller")
                    else
                        controller_down, controller_error = dd.binding_is_down(controller, config.controller_menu_bind)
                    end
                    trace_delayed_active_poll("active-after-binding-eval")
                end

                if keyboard_down == nil or controller_down == nil then
                    if not dd.open_bind_poll_fail_logged then
                        dd.open_bind_poll_fail_logged = true
                        log("open-binding polling query failed: " .. tostring(keyboard_error or controller_error))
                    end
                else
                    dd.open_bind_poll_fail_logged = false
                    local toggle_requested = false
                    if not host_managed and not controller_settings_active and keyboard_down and not dd.open_bind_keyboard_latched and not ui.closing and not dd.voice_browser_active() then
                        dd.open_bind_keyboard_latched = true
                        diag("input.openChord", { status = "triggered", kind = "keyboard", bind = config.menu_keybind, label = dd.keyboard_open_label(), open = ui.open })
                        log("keyboard menu chord fired: " .. dd.keyboard_open_label())
                        arm_open_bind_neutral("consumer-toggle:keyboard")
                        request_ui_toggle("keyboard", "active-consumer-keyboard", false)
                        toggle_requested = true
                    elseif not keyboard_down then
                        dd.open_bind_keyboard_latched = false
                    end

                    if not toggle_requested and not host_managed and not controller_settings_active and controller_down and not dd.open_bind_controller_latched and not ui.closing and not dd.voice_browser_active() then
                        dd.open_bind_controller_latched = true
                        diag("input.openChord", { status = "triggered", kind = "controller", bind = config.controller_menu_bind, label = dd.controller_open_label(), open = ui.open })
                        log("controller menu chord fired: " .. dd.controller_open_label())
                        arm_open_bind_neutral("consumer-toggle:controller", "controller-chord-break")
                        request_ui_toggle("controller", "active-consumer-controller", false)
                        toggle_requested = true
                    elseif not controller_down then
                        dd.open_bind_controller_latched = false
                    end

                    if ui.open and not ui.closing and not controller_down and not controller_settings_active then
                        trace_delayed_active_poll("active-before-details-analog")
                        local analog_ok, analog_error = pcall(dd.update_details_analog_scroll, controller)
                        trace_delayed_active_poll("active-after-details-analog")
                        if not analog_ok then
                            ui.details_scroll_axis_accum = 0.0
                            diag("input.detailsAnalog", { status = "poll-error", error = tostring(analog_error) })
                            log("details analog scroll poll error (poll preserved): " .. tostring(analog_error))
                        end
                    else
                        ui.details_scroll_axis_accum = 0.0
                    end
                end
            end
        elseif not dd.open_bind_poll_fail_logged then
            dd.open_bind_poll_fail_logged = true
            log("open-binding polling waiting for a valid PlayerController")
        end

        -- Preserve the proven 50 ms chord response while a live controller exists.
        -- During loading/death there is no usable input to miss, so a 250 ms backoff
        -- avoids repeated world scans until an authoritative controller reappears.
        trace_delayed_active_poll("active-before-reschedule")
        local controller_settings_sampling = dd.controller_settings_sampling_active ~= nil and dd.controller_settings_sampling_active()
        local next_poll_ms = controller_settings_sampling and controller_available and 10
            or (dd.bind_capture_active() and controller_available and 20
            or (controller_available and 50 or 250))
        local scheduled = dd.schedule_open_bind_poll(next_poll_ms, dd.open_bind_poll_game)
        if not scheduled then
            dd.open_bind_poll_armed = false
            log("open-binding polling stopped: ExecuteInGameThreadWithDelay unavailable")
        end
    end

    function dd.arm_open_bind_poll()
        if dd.open_bind_poll_armed then return true end
        dd.open_bind_poll_armed = true
        local scheduled = dd.schedule_open_bind_poll(250, dd.open_bind_poll_game)
        if not scheduled then dd.open_bind_poll_armed = false end
        return scheduled
    end

    return {
        ownership = "modui-consumer-settings-input-host",
        hostEventDelegation = type(host_event_reader) == "function",
        hostNavigationDelegation = type(host_navigation_reader) == "function",
        hostNativeInputMirrorDelegation = type(host_native_input_reader) == "function",
        hostNativeInputSemanticDelegation = type(host_native_input_reader) == "function"
            and type(host_native_input_dispatch) == "function",
        hostAnalogDelegation = type(host_axis_reader) == "function",
        hostControllerCaptureDelegation = type(host_key_reader) == "function" and type(host_capture_request_writer) == "function",
        hostKeyboardCaptureDelegation = type(host_key_reader) == "function" and type(host_capture_request_writer) == "function",
        bindingChangeDelegation = type(on_binding_changed) == "function",
        openContextAdmission = type(open_context_admission) == "function",
        transitionContextAdmission = type(transition_context_admission) == "function",
        loadMapTransitionFreeze = true,
        loadMapResumeDelayMs = tonumber(dd.open_bind_load_map_resume_ms) or 1500,
        controllerIdentitySettleMs = tonumber(dd.open_bind_controller_settle_ms) or 2000,
        postIdentityQuiescenceMs = tonumber(dd.open_bind_post_settle_ms) or 2000,
        transitionFreshNeutralEdge = true,
        transitionPendingOpenIntent = true,
        transitionIntentPollCadenceMs = 50,
        pollCadenceMs = 50,
        transitionBackoffMs = 250,
        captureTransactional = true,
    }
end

return M
