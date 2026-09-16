-- MortalShell2TTS UI.SettingsSession
-- Pass 169 owns the complete Settings session/shell lifecycle: native input teardown,
-- shell cache/foundation retirement, host/fallback open, close quarantine, and fail-closed rollback.

local M = {}

function M.Install(options)
    options = type(options) == "table" and options or {}
    local dd = options.dd
    local ui = options.ui
    local config = options.config
    local VERSION = tostring(options.version or "")
    local unwrap = options.unwrap
    local valid = options.valid
    local object_name = options.object_name
    local diag = options.diag or function() end
    local log = options.log or function() end
    local restore_settings_input = options.restore_settings_input
    local set_ui_text = options.set_ui_text
    local create_native_input_bridge = options.create_native_input_bridge
    local current_tab = options.current_tab
    local save_config = options.save_config
    local refresh_voices = options.refresh_voices
    local runtime_diagnostics = options.runtime_diagnostics
    local acquire_settings_input = options.acquire_settings_input
    local schedule_close_finalize = options.schedule_close_finalize
    local schedule_shell_cache_expiry = options.schedule_shell_cache_expiry
    local StaticFindObject = options.static_find_object
    local CLOSE_QUARANTINE_MS = math.max(0, math.floor(tonumber(options.close_quarantine_ms) or 225))
    local SHELL_REUSE_MS = math.floor(tonumber(options.shell_reuse_ms) or -1)
    local CONSUMER_NATIVE_LISTENER_TRANSITION_ISOLATION = options.consumer_native_listener_transition_isolation == true
    local WIDGET_BLUEPRINT_LIBRARY_CDO = tostring(options.widget_blueprint_library_cdo or "/Script/UMG.Default__WidgetBlueprintLibrary")
    local settings_widget_object_name = nil

    if type(dd) ~= "table" then return nil, "dd missing" end
    if type(ui) ~= "table" then return nil, "ui missing" end
    if type(config) ~= "table" then return nil, "config missing" end
    if type(unwrap) ~= "function" then return nil, "unwrap missing" end
    if type(valid) ~= "function" then return nil, "valid missing" end
    if type(object_name) ~= "function" then return nil, "object_name missing" end
    if type(restore_settings_input) ~= "function" then return nil, "restore_settings_input missing" end
    if type(set_ui_text) ~= "function" then return nil, "set_ui_text missing" end
    if type(create_native_input_bridge) ~= "function" then return nil, "create_native_input_bridge missing" end
    if type(current_tab) ~= "function" then return nil, "current_tab missing" end
    if type(save_config) ~= "function" then return nil, "save_config missing" end
    if type(refresh_voices) ~= "function" then return nil, "refresh_voices missing" end
    if type(runtime_diagnostics) ~= "table" then return nil, "runtime_diagnostics missing" end
    if type(acquire_settings_input) ~= "function" then return nil, "acquire_settings_input missing" end
    if type(schedule_close_finalize) ~= "function" then return nil, "schedule_close_finalize missing" end
    if type(schedule_shell_cache_expiry) ~= "function" then return nil, "schedule_shell_cache_expiry missing" end
    if StaticFindObject == nil then return nil, "static_find_object missing" end

    local function disable_native_ui_input()
        -- v0.9.17: intentionally mapping-neutral. IMC_Menu_Default is shared by
        -- native HUD/menu widgets, so TTS never removes it during teardown.
        ui.native_ui_input_enabled = false
        log("native UI shared mapping left untouched on close ownership=game")
    end

    local function disable_settings_input_bridge()
        local listener = unwrap(ui.native_input_bridge or ui.native_listener)
        local handler = unwrap(ui.native_ui_handler)
        if ui.native_host_listener_primary == true then
            if type(dd.write_modui_host_native_input_request) == "function" then
                pcall(dd.write_modui_host_native_input_request, false, nil, ui.active_generation)
            end
            if type(_G.MortalShell2TTSRuntime) == "table" then
                _G.MortalShell2TTSRuntime.modui_host_native_input_hook_ready = false
            end
            disable_native_ui_input()
            dd.release_native_modal_isolation("settings host-owned input bridge disabled")
            diag("input.disable.hostPrimary", {
                status = "released", generation = ui.active_generation,
                sharedHost = true, singlePhysicalHost = true,
            })
            ui.native_host_listener_primary = false
            ui.native_host_listener_address = ""
            ui.native_host_listener_fallback_scheduled = false
            ui.native_listener = nil
            ui.native_input_bridge = nil
            ui.native_bridge_lease = nil
            ui.native_bridge_session = nil
            ui.native_bridge_activation = nil
            ui.native_listener_enabled = false
            ui.native_route_by_enum = {}
            ui.native_route_by_action = {}
            ui.native_action_name_by_enum = {}
            ui.native_verified_accepted_inputs = {}
            ui.native_gamepad_probe_warned = false
            diag("input.disable.end", { status = "complete-host-primary", sharedHost = true, singlePhysicalHost = true })
            return
        end
        local bridge_session = type(ui.native_bridge_session) == "table" and ui.native_bridge_session or nil
        local shared_input_bridge_session = bridge_session ~= nil and bridge_session.sharedInputBridgeSession == true
        local lease_hook_spec_owned = type(ui.native_bridge_lease) == "table"
            and ui.native_bridge_lease.hookSpecOwned == true

        diag("input.disable.begin", {
            listener = valid(listener) and object_name(listener) or "<invalid>",
            enabledFlag = ui.native_listener_enabled,
            sharedHost = true,
            sharedConstruction = true,
            sharedLeaseHookSpec = lease_hook_spec_owned,
            sharedInputBridgeSession = shared_input_bridge_session,
        })

        local teardown_plan = nil
        local shared_teardown_plan = false
        local shared_teardown_ticket = false
        local shared_teardown_transaction = false
        local function completion_barrier()
            disable_native_ui_input()
            dd.release_native_modal_isolation("settings input bridge disabled")
            diag("input.disable.barrier", {
                status = "complete",
                sharedRuntime = true,
                sharedHost = true,
                sharedTeardownTicket = shared_teardown_ticket,
                sharedTeardownTransaction = shared_teardown_transaction,
                sharedTeardownPlan = shared_teardown_plan,
                sharedInputBridgeSession = shared_input_bridge_session,
                sharedTeardownBarrier = true,
                barrierCompleted = true,
            })
            return true
        end

        local deactivate_result
        local teardown_session
        deactivate_result, teardown_plan, teardown_session = dd.deactivate_native_input_host(
            listener, handler, "settings input bridge disabled", "disable",
            completion_barrier, "modal-isolation-released-after-close-quarantine"
        )
        if type(teardown_session) == "table" and teardown_session.sharedInputBridgeSession == true then
            bridge_session = teardown_session
            shared_input_bridge_session = true
        end
        deactivate_result = type(deactivate_result) == "table" and deactivate_result
            or { ok = false, status = "invalid-result" }
        local teardown_transaction = type(teardown_plan) == "table" and teardown_plan.transaction or nil
        local teardown_ticket = type(teardown_transaction) == "table" and teardown_transaction.ticket or nil
        shared_teardown_ticket = type(teardown_ticket) == "table" and teardown_ticket.sharedTeardownTicket == true
        shared_teardown_transaction = type(teardown_transaction) == "table" and teardown_transaction.sharedTeardownTransaction == true
        shared_teardown_plan = type(teardown_plan) == "table" and teardown_plan.sharedTeardownPlan == true

        -- TTS still owns the 225 ms generation-guarded close quarantine and decides
        -- when this post-quarantine sequence may begin. Pass 75 keeps the exact successful
        -- Open listener/lease/activation and the Pass-74 teardown plan inside one shared
        -- session; TTS still decides when session completion is safe to run.
        local teardown_completion = nil
        local teardown_authorization = nil
        local remove_result = nil
        if valid(listener) then
            if shared_input_bridge_session then
                teardown_completion = dd.ModUI.Runtime.InputBridge.CompleteSessionTeardown(bridge_session)
            else
                teardown_completion = dd.ModUI.Runtime.InputBridge.CompleteTeardownPlan(teardown_plan)
            end
            teardown_completion = type(teardown_completion) == "table" and teardown_completion
                or { ok = false, status = "invalid-result" }
            teardown_authorization = type(teardown_completion.authorization) == "table"
                and teardown_completion.authorization or { ok = false, status = "invalid-result" }
            remove_result = type(teardown_completion.retirement) == "table"
                and teardown_completion.retirement or { ok = false, status = "invalid-result" }

            diag("input.disable.authorize", {
                status = teardown_authorization.ok and "ok" or "failed",
                error = teardown_authorization.error or (teardown_authorization.ok and nil or teardown_authorization.status),
                sharedRuntime = true,
                sharedHost = true,
                sharedTeardownTicket = teardown_authorization.sharedTeardownTicket == true,
                sharedTeardownTransaction = teardown_completion.sharedTeardownTransaction == true,
                sharedTeardownPlan = teardown_completion.sharedTeardownPlan == true,
                sharedInputBridgeSession = teardown_completion.sharedInputBridgeSession == true or shared_input_bridge_session,
                sharedTeardownAuthorization = teardown_authorization.sharedTeardownAuthorization == true,
                sharedTeardownCompletion = teardown_completion.sharedTeardownCompletion == true,
                sharedTeardownBarrier = teardown_completion.sharedTeardownBarrier == true,
                barrierCompleted = teardown_completion.barrierCompleted == true,
                retirementAuthorized = teardown_authorization.retirementAuthorized == true,
                lifecycleRoute = teardown_authorization.lifecycleRoute,
            })

            diag("input.disable.remove", {
                status = remove_result.ok and "ok" or "failed",
                error = remove_result.error or (remove_result.ok and nil or remove_result.status),
                sharedRuntime = true,
                sharedHost = true,
                sharedConstruction = true,
                sharedLease = remove_result.sharedLease == true,
                sharedLeaseHookSpec = lease_hook_spec_owned,
                sharedLeaseRouter = remove_result.sharedLeaseRouter == true,
                sharedLeaseTeardownOptions = deactivate_result.sharedLeaseTeardownOptions == true,
                teardownOptionRoute = deactivate_result.teardownOptionRoute,
                legacyOptionsFactoryCalled = deactivate_result.legacyOptionsFactoryCalled == true,
                sharedLeaseTeardownActivation = deactivate_result.sharedLeaseTeardownActivation == true,
                teardownActivationRoute = deactivate_result.teardownActivationRoute,
                legacyActivationFactoryCalled = deactivate_result.legacyActivationFactoryCalled == true,
                sharedTeardownTicket = remove_result.sharedTeardownTicket == true,
                sharedTeardownTransaction = teardown_completion.sharedTeardownTransaction == true,
                sharedTeardownPlan = teardown_completion.sharedTeardownPlan == true,
                sharedInputBridgeSession = teardown_completion.sharedInputBridgeSession == true or shared_input_bridge_session,
                sharedTeardownAuthorization = remove_result.sharedTeardownAuthorization == true,
                sharedTeardownCompletion = teardown_completion.sharedTeardownCompletion == true,
                sharedTeardownBarrier = teardown_completion.sharedTeardownBarrier == true,
                barrierCompleted = teardown_completion.barrierCompleted == true,
                retirementAuthorized = remove_result.retirementAuthorized == true,
                lifecycleRoute = remove_result.lifecycleRoute,
            })
        else
            -- Preserve the historical invalid-listener compatibility path exactly:
            -- release TTS-owned modal state even though there is no valid listener to
            -- authorize/retire through the shared ticket host.
            disable_native_ui_input()
            dd.release_native_modal_isolation("settings input bridge disabled")
            diag("input.disable.barrier", {
                status = "legacy-invalid-listener",
                sharedRuntime = true,
                sharedHost = true,
                sharedTeardownTicket = shared_teardown_ticket,
                sharedTeardownTransaction = shared_teardown_transaction,
                sharedTeardownPlan = shared_teardown_plan,
                sharedInputBridgeSession = shared_input_bridge_session,
                sharedTeardownBarrier = false,
                barrierCompleted = true,
            })
        end

        ui.native_listener = nil
        ui.native_host_listener_primary = false
        ui.native_host_listener_fallback_scheduled = false
        ui.native_input_bridge = nil
        ui.native_bridge_lease = nil
        ui.native_bridge_session = nil
        ui.native_bridge_activation = nil
        ui.native_last_source = ""
        ui.native_route_by_enum = {}
        ui.native_route_by_action = {}
        ui.native_action_name_by_enum = {}
        ui.native_verified_accepted_inputs = {}
        ui.native_gamepad_probe_warned = false

        diag("input.disable.end", {
            status = "complete",
            sharedHost = true,
            sharedConstruction = true,
            sharedLeaseHookSpec = lease_hook_spec_owned,
            sharedLeaseRouter = true,
            sharedLeaseTeardownOptions = deactivate_result.sharedLeaseTeardownOptions == true,
            teardownOptionRoute = deactivate_result.teardownOptionRoute,
            legacyOptionsFactoryCalled = deactivate_result.legacyOptionsFactoryCalled == true,
            sharedLeaseTeardownActivation = deactivate_result.sharedLeaseTeardownActivation == true,
            teardownActivationRoute = deactivate_result.teardownActivationRoute,
            legacyActivationFactoryCalled = deactivate_result.legacyActivationFactoryCalled == true,
            sharedTeardownTicket = shared_teardown_ticket,
            sharedTeardownTransaction = shared_teardown_transaction,
            sharedTeardownPlan = shared_teardown_plan,
            sharedInputBridgeSession = type(teardown_completion) == "table" and teardown_completion.sharedInputBridgeSession == true or shared_input_bridge_session,
            sharedTeardownAuthorization = type(teardown_authorization) == "table" and teardown_authorization.sharedTeardownAuthorization == true or false,
            sharedTeardownCompletion = type(teardown_completion) == "table" and teardown_completion.sharedTeardownCompletion == true or false,
            sharedTeardownBarrier = type(teardown_completion) == "table" and teardown_completion.sharedTeardownBarrier == true or false,
            barrierCompleted = type(teardown_completion) == "table" and teardown_completion.barrierCompleted == true or false,
            retirementAuthorized = type(teardown_authorization) == "table" and teardown_authorization.retirementAuthorized == true or false,
            authorizationStatus = type(teardown_authorization) == "table" and teardown_authorization.status or "not-run",
        })
    end

    local function destroy_native_ui_foundation()
        -- These four UUserWidgets are children of the borrowed reader's Overlay_Prompt,
        -- so they are never detached individually. v0.9.45 releases their one root as
        -- a coherent graph and clears Lua references before another session can open.
        -- Creation-failure paths still detach incomplete children locally.
        ui.native_details_divider = nil
        ui.native_details_widget = nil
        ui.native_tabs_widget = nil
        ui.native_tabs_text = nil
        ui.native_tabs_slot = nil
        ui.native_labels_widget = nil
        ui.native_labels_text = nil
        ui.native_labels_slot = nil
        ui.native_values_widget = nil
        ui.native_values_text = nil
        ui.native_values_slot = nil
        ui.native_prompt_box = nil
        ui.native_background = nil
        ui.native_source_body = nil
        ui.window_profile = "main"
        ui.native_details_container = nil
        ui.native_details_overlay = nil
        ui.native_details_slot = nil
        ui.native_read_text_size_box = nil
        ui.native_read_text_scale_box = nil
        ui.native_read_text_root_child = nil
        ui.native_read_text_chain = ""
    end

    local SHELL_CACHE_REF_FIELDS = {
        "widget",
        "header_widget",
        "body_widget",
        "page_widget",
        "native_details_widget",
        "native_tabs_widget",
        "native_tabs_text",
        "native_tabs_slot",
        "native_labels_widget",
        "native_labels_text",
        "native_labels_slot",
        "native_values_widget",
        "native_values_text",
        "native_values_slot",
        "native_prompt_box",
        "native_background",
        "native_source_body",
        "native_details_container",
        "native_details_overlay",
        "native_details_slot",
        "native_read_text_size_box",
        "native_read_text_scale_box",
        "native_read_text_root_child",
        "native_reader_vb_data",
    }

    local function expire_cached_settings_shell(expected_token, reason)
        local cache = ui.shell_cache
        if type(cache) ~= "table" then return false end
        if expected_token ~= nil and tonumber(cache.token) ~= tonumber(expected_token) then return false end
        if ui.open then return false end

        -- Never let a delayed/future cache-expiry path dereference an old-world shell.
        -- Process-retained reuse is currently non-expiring, but keeping this guard here
        -- makes the ownership invariant authoritative if the reuse policy changes later.
        if tonumber(cache.worldScopeEpoch) ~= (tonumber(dd.world_scope_epoch) or 0) then
            local token = cache.token
            local prior_generation = cache.generation
            ui.shell_cache = nil
            if type(dd.publish_modui_host_menu_shell) == "function" then
                pcall(dd.publish_modui_host_menu_shell, "retired", prior_generation,
                    tostring(cache.shell_address or ""), false, tonumber(token) or 0, "expiry-world-scope-changed")
            end
            diag("shell.cache.discard", {
                status = "expiry-world-scope-changed-no-deref",
                token = token,
                priorGeneration = prior_generation,
                cacheEpoch = cache.worldScopeEpoch,
                currentEpoch = tonumber(dd.world_scope_epoch) or 0,
            })
            return true
        end

        local widget = unwrap(cache.widget)
        local removed = true
        local remove_error = nil
        if valid(widget) then
            removed, remove_error = pcall(function() widget:RemoveFromParent() end)
        end
        ui.shell_cache = nil
        if type(dd.publish_modui_host_menu_shell) == "function" then
            pcall(dd.publish_modui_host_menu_shell, removed and "retired" or "retained", cache.generation,
                tostring(cache.shell_address or ""), false, tonumber(cache.token) or 0,
                removed and tostring(reason or "expired") or "cache-remove-failed")
        end
        diag("shell.cache.expire", {
            status = removed and "released" or "remove-failed",
            reason = tostring(reason or "expired"),
            token = cache.token,
            generation = cache.generation,
            error = removed and nil or remove_error,
        })
        return removed
    end

    local function stash_settings_shell_cache(controller)
        if SHELL_REUSE_MS == 0 then return false, nil end
        controller = unwrap(controller)
        if not valid(controller) or ui.presentation_mode ~= "rails" or not valid(ui.widget) then return false, nil end

        local required = {
            ui.header_widget,
            ui.body_widget,
            ui.native_details_widget,
            ui.native_tabs_widget,
            ui.native_tabs_text,
            ui.native_labels_widget,
            ui.native_labels_text,
            ui.native_values_widget,
            ui.native_values_text,
            ui.native_reader_vb_data,
        }
        for _, value in ipairs(required) do
            if not valid(value) then return false, nil end
        end

        if not dd.native_presentation.SetNativeVisibility(ui.widget, 1) then return false, nil end

        ui.shell_cache_token = (tonumber(ui.shell_cache_token) or 0) + 1
        local cache = {
            token = ui.shell_cache_token,
            generation = ui.active_generation,
            worldScopeEpoch = tonumber(dd.world_scope_epoch) or 0,
            controller = controller,
            controller_address = tostring(dd.native_ui_runtime.ObjectAddress(controller) or ""),
            presentation_mode = ui.presentation_mode,
            native_read_text_chain = ui.native_read_text_chain,
            shell_address = tostring(dd.native_ui_runtime.ObjectAddress(ui.widget) or ""),
            render_text_cache = {},
        }
        for key, value in pairs(ui.render_text_cache or {}) do cache.render_text_cache[key] = value end
        for _, field in ipairs(SHELL_CACHE_REF_FIELDS) do cache[field] = ui[field] end
        ui.shell_cache = cache
        diag("shell.cache.store", {
            status = "cached-collapsed",
            token = cache.token,
            generation = cache.generation,
            ttlMs = SHELL_REUSE_MS,
            root = object_name(cache.widget),
            controllerAddress = cache.controller_address,
        })
        return true, cache.token
    end

    local function restore_cached_settings_shell(controller)
        if SHELL_REUSE_MS == 0 then
            if type(ui.shell_cache) == "table" then
                expire_cached_settings_shell(ui.shell_cache.token, "reuse-disabled")
            end
            return nil, false
        end
        controller = unwrap(controller)
        local cache = ui.shell_cache
        if type(cache) ~= "table" then return nil, false end

        -- A controller outage is an authoritative world/session boundary for this
        -- borrowed GameInstance-owned shell. Never dereference an old-world UObject
        -- graph after returning from the main menu; UE4SS IsValid/RemoveFromParent
        -- can cross into freed native state before Lua pcall can protect us.
        if tonumber(cache.worldScopeEpoch) ~= (tonumber(dd.world_scope_epoch) or 0) then
            local token = cache.token
            local prior_generation = cache.generation
            ui.shell_cache = nil
            if type(dd.publish_modui_host_menu_shell) == "function" then
                pcall(dd.publish_modui_host_menu_shell, "retired", prior_generation,
                    tostring(cache.shell_address or ""), false, tonumber(token) or 0, "world-scope-changed")
            end
            diag("shell.cache.discard", {
                status = "world-scope-changed-no-deref",
                token = token,
                priorGeneration = prior_generation,
                cacheEpoch = cache.worldScopeEpoch,
                currentEpoch = tonumber(dd.world_scope_epoch) or 0,
            })
            return nil, false
        end

        -- Pass 133: if the newly resolved live controller has a different primitive address,
        -- treat that as a world/session boundary BEFORE touching cache.controller/cache.widget.
        -- This covers a stale-but-IsValid controller wrapper and keeps the Pass-29 no-dereference
        -- invariant authoritative even when UE4SS does not invalidate the old wrapper promptly.
        local current_controller_address = valid(controller)
            and tostring(dd.native_ui_runtime.ObjectAddress(controller) or "") or ""
        local cached_controller_address = tostring(cache.controller_address or "")
        if current_controller_address ~= "" and cached_controller_address ~= ""
            and current_controller_address ~= cached_controller_address then
            local token = cache.token
            local prior_generation = cache.generation
            ui.shell_cache = nil
            if type(dd.publish_modui_host_menu_shell) == "function" then
                pcall(dd.publish_modui_host_menu_shell, "retired", prior_generation,
                    tostring(cache.shell_address or ""), false, tonumber(token) or 0,
                    "controller-identity-changed")
            end
            diag("shell.cache.discard", {
                status = "controller-identity-changed-no-deref",
                token = token,
                priorGeneration = prior_generation,
                cachedControllerAddress = cached_controller_address,
                currentControllerAddress = current_controller_address,
                shellAddress = tostring(cache.shell_address or ""),
                currentEpoch = tonumber(dd.world_scope_epoch) or 0,
            })
            return nil, false
        end

        local compatible = valid(controller)
            and valid(cache.controller)
            and dd.native_ui_runtime.SameObject(controller, cache.controller)
            and cache.presentation_mode == "rails"
            and valid(cache.widget)
            and dd.native_presentation.NativeWidgetVisible(cache.widget)
        if compatible then
            for _, field in ipairs(SHELL_CACHE_REF_FIELDS) do
                if field ~= "page_widget" and field ~= "native_read_text_size_box"
                    and field ~= "native_read_text_scale_box" and field ~= "native_read_text_root_child"
                    and not valid(cache[field]) then
                    compatible = false
                    break
                end
            end
        end

        if not compatible then
            expire_cached_settings_shell(cache.token, "reuse-validation-failed")
            return nil, false
        end

        for _, field in ipairs(SHELL_CACHE_REF_FIELDS) do ui[field] = cache[field] end
        ui.presentation_mode = cache.presentation_mode
        ui.native_read_text_chain = cache.native_read_text_chain or ""
        ui.render_text_cache = {}
        for key, value in pairs(cache.render_text_cache or {}) do ui.render_text_cache[key] = value end
        ui.shell_cache = nil

        if not dd.native_presentation.SetNativeVisibility(ui.widget, 0) then
            local failed_widget = ui.widget
            for _, field in ipairs(SHELL_CACHE_REF_FIELDS) do ui[field] = nil end
            ui.presentation_mode = "fallback"
            if valid(failed_widget) then pcall(function() failed_widget:RemoveFromParent() end) end
            diag("shell.cache.reuse", { status = "visibility-restore-failed", token = cache.token })
            return nil, false
        end

        diag("shell.cache.reuse", {
            status = "reused",
            token = cache.token,
            priorGeneration = cache.generation,
            generation = ui.active_generation,
            root = object_name(ui.widget),
        })
        return ui.widget, true
    end

    local function clear_native_widget_refs()
        settings_widget_object_name = nil
        ui.widget = nil
        ui.header_widget = nil
        ui.body_widget = nil
        ui.page_widget = nil
        ui.native_details_divider = nil
        ui.native_details_widget = nil
        ui.native_tabs_widget = nil
        ui.native_tabs_text = nil
        ui.native_tabs_slot = nil
        ui.native_labels_widget = nil
        ui.native_labels_text = nil
        ui.native_labels_slot = nil
        ui.native_values_widget = nil
        ui.native_values_text = nil
        ui.native_values_slot = nil
        ui.native_details_container = nil
        ui.native_details_overlay = nil
        ui.native_details_slot = nil
        ui.native_read_text_size_box = nil
        ui.native_read_text_scale_box = nil
        ui.native_read_text_root_child = nil
        ui.native_read_text_chain = ""
        ui.native_reader_vb_data = nil
        ui.presentation_mode = "fallback"
        ui.native_listener = nil
        ui.native_host_listener_primary = false
        ui.native_host_listener_fallback_scheduled = false
        ui.native_input_bridge = nil
        ui.native_bridge_lease = nil
        ui.native_bridge_session = nil
        ui.native_bridge_activation = nil
        ui.native_listener_enabled = false
        ui.native_interface_input_enabled = false
        ui.native_ui_handler = nil
        ui.native_ui_input_enabled = false
        ui.native_last_source = ""
        ui.native_route_by_enum = {}
        ui.native_route_by_action = {}
        ui.native_action_name_by_enum = {}
        ui.native_verified_accepted_inputs = {}
        ui.native_original_accepted_inputs = nil
        ui.native_accepted_inputs_changed = false
        ui.native_pause_component = nil
        ui.native_pause_bumped = false
        ui.native_pause_bumps = 0
        ui.native_pause_reason = nil
        ui.native_modal_handler = nil
        ui.native_modal_asc = nil
        ui.native_modal_handles = {}
        ui.native_modal_isolation = false
        ui.native_modal_mode = "none"
        ui.native_menu_block_verified = false
        ui.native_gamepad_probe_warned = false
        ui.mouse_input_ready = false
        ui.mouse_click_count = 0
        ui.mouse_last_region = ""
        ui.render_text_cache = {}
        ui.active_generation = 0
        ui.close_generation = 0
        ui.invalid_session_logged = false
        ui.input_dedupe_last_semantic = ""
        ui.input_dedupe_last_source_kind = ""
        ui.input_dedupe_last_clock = -1.0
        if dd.voice_browser ~= nil then
            dd.voice_browser.active = false
            dd.voice_browser.previous_search_down = {}
            dd.voice_browser.nav_hold_ticks = { up = 0, down = 0 }
            dd.voice_browser.square_down = false
            dd.voice_browser.right_page_hold_direction = 0
            dd.voice_browser.right_page_hold_ticks = 0
            dd.voice_browser.page_hold_ticks = { up = 0, down = 0 }
            dd.voice_browser.home_down = false
            dd.voice_browser.end_down = false
        end
    end

    local function retire_settings_visual_shell(widget, handler, stage)
        widget = unwrap(widget)
        handler = unwrap(handler)
        stage = tostring(stage or "retire")
        if not valid(widget) then return end

        -- ObjectDump diagnosis (v0.9.18): WBP_ConfirmationPromptBase tracks itself
        -- through BPC_UserInterfaceHandler.ActiveConfirmations via UpdateOpenState(),
        -- and it implements OnPlayerDeath + bShouldRemoveOnDeath. RemoveFromParent()
        -- alone only detaches Slate; it does not guarantee Mortal Shell's prompt
        -- bookkeeping is retired. Keep this visual-only borrowed prompt out of the
        -- game's death cleanup and authoritative confirmation list.
        local update_method = widget["UpdateOpenState"]
        local update_ok, update_err = false, nil
        if update_method ~= nil then
            update_ok, update_err = pcall(update_method, widget, false)
        end

        -- WBP_ConfirmationPrompt_ReadText also owns BPC_UserInterfaceHandler.ActiveReadText.
        -- If this exact borrowed instance is still active, use the reader's own
        -- Invalidate() first, then only fall back to clearing the field directly.
        local active_before = false
        local active_after = false
        local active_name = "<none>"
        local clear_active = stage ~= "post-construct"
        if valid(handler) then
            local ok_active, active = pcall(function() return unwrap(handler.ActiveReadText) end)
            if ok_active and valid(active) then
                active_name = object_name(active)
                active_before = active == widget or active_name == object_name(widget)
            end
            if clear_active and active_before then
                local invalidate = widget["Invalidate"]
                if invalidate ~= nil then pcall(invalidate, widget) end
                local ok_after, after = pcall(function() return unwrap(handler.ActiveReadText) end)
                if ok_after and valid(after) then
                    active_after = after == widget or object_name(after) == object_name(widget)
                end
                if active_after then
                    pcall(function() handler.ActiveReadText = nil end)
                    local ok_final, final_value = pcall(function() return unwrap(handler.ActiveReadText) end)
                    active_after = ok_final and valid(final_value)
                        and (final_value == widget or object_name(final_value) == object_name(widget))
                end
            else
                active_after = active_before
            end
        end

        local remove_on_death = "<unreadable>"
        local pause_game_flag = "<unreadable>"
        pcall(function() remove_on_death = tostring(unwrap(widget.bShouldRemoveOnDeath)) end)
        pcall(function() pause_game_flag = tostring(unwrap(widget.bPauseGame)) end)

        log("visual settings shell retired stage=" .. stage
            .. " updateOpenStateFalse=" .. tostring(update_ok)
            .. (update_ok and "" or (" error=" .. tostring(update_err)))
            .. " activeReadTextWasSelf=" .. tostring(active_before)
            .. " activeReadTextClearAttempted=" .. tostring(clear_active and active_before)
            .. " activeReadTextStillSelf=" .. tostring(active_after)
            .. " previousActive=" .. tostring(active_name)
            .. " bShouldRemoveOnDeath=" .. remove_on_death
            .. " bPauseGame=" .. pause_game_flag)
    end

    local function destroy_settings_ui(reason)
        reason = tostring(reason or "close")
        local closing_generation = tonumber(ui.active_generation) or 0
        local handler = unwrap(ui.native_ui_handler)
        local controller = unwrap(ui.controller)
        local listener = unwrap(ui.native_listener)
        local closing_shell_address = valid(ui.widget) and tostring(dd.native_ui_runtime.ObjectAddress(ui.widget) or "") or ""

        diag("close.destroy", {
            stage = "begin",
            reason = reason,
            open = ui.open,
            closing = ui.closing,
            widget = valid(ui.widget) and object_name(ui.widget) or "<invalid>",
            listener = valid(listener) and object_name(listener) or "<invalid>",
            pauseBumps = ui.native_pause_bumps,
            isolationMode = ui.native_modal_mode,
            ownedEffectHandles = type(ui.native_modal_handles) == "table" and #ui.native_modal_handles or 0,
            mouseClicks = ui.mouse_click_count,
            generation = ui.active_generation,
            redraws = ui.redraw_sequence,
            textSetCalls = ui.render_set_calls,
            textSetSkips = ui.render_set_skips,
            inputDuplicatesSuppressed = ui.input_dedupe_count,
        })
        if valid(handler) then
            dd.evaluate_native_menu_admission(handler, controller, "close-before-input-release-observe")
            dd.log_handler_active_listeners(handler, listener, "close-before-input-release")
        end
        if valid(listener) then
            dd.log_listener_input_handles(listener, "close-before-input-release")
            dd.log_listener_delegate_bindings(listener, "close-before-input-release")
        end

        if dd.controller_settings_active ~= nil and dd.controller_settings_active()
            and type(dd.shutdown_controller_settings) == "function" then
            pcall(dd.shutdown_controller_settings, "menu-close")
        end

        if dd.voice_browser_active ~= nil and dd.voice_browser_active() then
            local state = dd.voice_browser
            if dd.commit_voice_browser_selection ~= nil and dd.commit_voice_browser_selection("menu-close") then
                save_config()
                log("voice browser selection committed during menu close: " .. tostring(state.chosen))
            end
            state.active = false
            state.previous_search_down = {}
            state.nav_hold_ticks = { up = 0, down = 0 }
            state.square_down = false
            state.right_page_hold_direction = 0
            state.right_page_hold_ticks = 0
            state.page_hold_ticks = { up = 0, down = 0 }
            state.home_down = false
            state.end_down = false
        end
        ui.open = false
        dd.clear_reset_confirmation("menu-closed")
        if dd.bind_capture_active ~= nil and dd.bind_capture_active() then
            diag("input.bindCapture", { status = "aborted-by-menu-close", kind = dd.bind_capture.kind, reason = reason })
            dd.bind_capture = { active = false }
        end
        disable_settings_input_bridge()
        diag("close.destroy", { stage = "after-input-bridge-disable" })
        if valid(handler) then
            dd.log_handler_active_listeners(handler, listener, "close-after-input-release")
        end

        if ui.host_visible_shell == true then
            -- Pass 160 healthy path: standalone ModUI owns UMG/focus/input-mode teardown. TTS owns only
            -- consumer semantics, its bounded native callback bridge, and gameplay/modal isolation.
            ui.host_visible_shell = false
            ui.host_visible_shell_generation = 0
            ui.host_visible_shell_last_status = "closed"
            ui.controller = nil
            ui.widget_library = nil
            ui.native_ui_handler = nil
            clear_native_widget_refs()
            ui.closing = false
            ui.close_reason = nil
            ui.close_quarantine_ticks = 0
            if type(dd.publish_modui_host_menu_shell) == "function" then
                pcall(dd.publish_modui_host_menu_shell, "retired", closing_generation, "", false, 0, reason)
            end
            if type(dd.publish_modui_host_menu_session) == "function" then
                pcall(dd.publish_modui_host_menu_session, "closed", closing_generation, reason)
            end
            diag("close.destroy", { stage = "complete", reason = reason, generation = closing_generation, visibleShellOwner = "MortalShell2ModUI" })
            diag("session.end", { status = "closed", reason = reason, generation = closing_generation, visibleShellOwner = "MortalShell2ModUI" })
            return
        end

        local shell_cached = false
        local shell_cache_token = nil
        local transition_immediate_retire = reason == "load-map-pre"
            or reason == "load-map-pre-active-session"
        if valid(ui.widget) then
            retire_settings_visual_shell(ui.widget, handler, "close")
            diag("close.destroy", { stage = "after-shell-retire" })
            if valid(handler) then
                dd.evaluate_native_menu_admission(handler, controller, "close-after-shell-retire-observe")
            end

            local attached_children = 0
            if valid(ui.native_tabs_widget) then attached_children = attached_children + 1 end
            if valid(ui.native_labels_widget) then attached_children = attached_children + 1 end
            if valid(ui.native_values_widget) then attached_children = attached_children + 1 end
            if valid(ui.native_details_widget) then attached_children = attached_children + 1 end
            if transition_immediate_retire then
                -- LoadMapPreHook runs before old-world teardown. Do not retain a native UMG graph
                -- across that boundary; retire/remove it while its world is still authoritative.
                shell_cached, shell_cache_token = false, nil
                ui.shell_cache = nil
                diag("shell.cache.transition", {
                    status = "pre-load-retire-no-cache", reason = reason, generation = closing_generation,
                    shellAddress = closing_shell_address,
                })
            else
                shell_cached, shell_cache_token = stash_settings_shell_cache(controller)
            end
            log("settings root teardown begin parentOwnedChildren=true childDetach=false attachedChildren=" .. tostring(attached_children)
                .. " rapidReuse=" .. tostring(shell_cached))
            diag("close.rootRemove", {
                stage = "before",
                parentOwnedChildren = true,
                childDetach = false,
                attachedChildren = attached_children,
                root = object_name(ui.widget),
                rapidReuse = shell_cached,
                cacheToken = shell_cache_token,
            })
            local root_remove_ok, root_remove_err = true, nil
            if not shell_cached then
                root_remove_ok, root_remove_err = pcall(function() ui.widget:RemoveFromParent() end)
            end
            log("settings root teardown rootRemove=" .. tostring(not shell_cached and root_remove_ok)
                .. " cachedCollapsed=" .. tostring(shell_cached)
                .. (root_remove_ok and "" or (" error=" .. tostring(root_remove_err))))
            diag("close.rootRemove", {
                stage = "after",
                status = shell_cached and "cached-collapsed" or (root_remove_ok and "ok" or "failed"),
                error = root_remove_ok and nil or root_remove_err,
                cacheToken = shell_cache_token,
            })
        else
            diag("close.rootRemove", { stage = "skip", status = "root-invalid" })
        end

        if type(dd.publish_modui_host_menu_shell) == "function" then
            if shell_cached and closing_shell_address ~= "" then
                pcall(dd.publish_modui_host_menu_shell, "retained", closing_generation,
                    closing_shell_address, false, tonumber(shell_cache_token) or 0, reason)
            else
                pcall(dd.publish_modui_host_menu_shell, "retired", closing_generation,
                    closing_shell_address, false, 0, reason)
            end
        end

        restore_settings_input(reason)
        diag("close.destroy", { stage = "after-modal-input-restore" })

        if valid(handler) then
            dd.evaluate_native_menu_admission(handler, controller, "close-after-modal-restore-observe")
        end

        destroy_native_ui_foundation()
        clear_native_widget_refs()

        if shell_cached then
            if SHELL_REUSE_MS > 0 then
                local scheduled = schedule_shell_cache_expiry ~= nil
                    and schedule_shell_cache_expiry(SHELL_REUSE_MS, shell_cache_token)
                if not scheduled then
                    expire_cached_settings_shell(shell_cache_token, "expiry-scheduler-unavailable")
                end
                diag("shell.cache.expiry", {
                    status = scheduled and "scheduled" or "released-immediately",
                    token = shell_cache_token,
                    delayMs = SHELL_REUSE_MS,
                })
            else
                diag("shell.cache.expiry", {
                    status = "retained-no-expiry",
                    token = shell_cache_token,
                    delayMs = SHELL_REUSE_MS,
                })
            end
        end

        ui.closing = false
        ui.close_reason = nil
        ui.close_quarantine_ticks = 0
        diag("close.destroy", { stage = "complete", reason = reason, generation = closing_generation })
        if type(dd.publish_modui_host_menu_session) == "function" then
            pcall(dd.publish_modui_host_menu_session, "closed", closing_generation, reason)
        end
        diag("session.end", { status = "closed", reason = reason, generation = closing_generation })
    end

    local function request_controller_close_quarantine(reason)
        if not ui.open or ui.closing then
            diag("close.request", {
                status = "ignored",
                reason = reason,
                open = ui.open,
                closing = ui.closing,
            })
            return false
        end

        diag("close.request", {
            status = "accepted",
            reason = reason,
            widget = valid(ui.widget) and object_name(ui.widget) or "<invalid>",
            listener = valid(ui.native_listener) and object_name(ui.native_listener) or "<invalid>",
        })

        ui.closing = true
        ui.close_reason = tostring(reason or "controller back")
        if type(dd.publish_modui_host_menu_session) == "function" then
            pcall(dd.publish_modui_host_menu_session, "closing", ui.active_generation, ui.close_reason)
        end
        if type(dd.publish_modui_host_menu_shell) == "function" and valid(ui.widget) then
            pcall(dd.publish_modui_host_menu_shell, "quarantined", ui.active_generation,
                tostring(dd.native_ui_runtime.ObjectAddress(ui.widget) or ""), false, 0, ui.close_reason)
        end
        ui.close_quarantine_ticks = 0
        ui.close_generation = ui.active_generation

        -- Any close source (controller Back/Circle, Esc, or the configured open bind) may arrive
        -- during Slate/input dispatch. Move to UIOnly immediately, but keep the exact
        -- modal gameplay-effect handles (or compatibility pause fallback) and bridge
        -- alive until the delayed finalizer can unbind input and remove UMG objects
        -- outside the active input callback.
        local controller = unwrap(ui.controller)
        local library = unwrap(ui.widget_library)
        local widget = unwrap(ui.widget)
        local quarantine_mode = "UIOnly-held"

        if ui.host_visible_shell == true then
            quarantine_mode = "host-shell-held"
        elseif valid(controller) and valid(library) and valid(widget) and library["SetInputMode_UIOnlyEx"] ~= nil then
            local ok_mode, mode_error = pcall(library["SetInputMode_UIOnlyEx"], library, controller, widget, 0, true)
            if ok_mode then
                quarantine_mode = "UIOnly"
            else
                log("controller close quarantine UIOnly refresh failed: " .. tostring(mode_error) .. "; holding existing modal isolation")
                diag("close.quarantine", {
                    stage = "input-mode-refresh",
                    status = "failed",
                    error = mode_error,
                })
            end
        end

        local scheduled = schedule_close_finalize ~= nil and schedule_close_finalize(CLOSE_QUARANTINE_MS)
        diag("close.quarantine", {
            stage = "armed",
            mode = quarantine_mode,
            durationMs = CLOSE_QUARANTINE_MS,
            scheduled = scheduled == true,
            reason = ui.close_reason,
            generation = ui.close_generation,
        })
        log("close quarantine armed mode=" .. quarantine_mode
            .. " durationMs=" .. tostring(CLOSE_QUARANTINE_MS)
            .. " scheduled=" .. tostring(scheduled == true)
            .. " reason=" .. ui.close_reason)

        if not scheduled then
            -- Do not destroy the borrowed Unreal widget from the active Back/Esc
            -- event. If possible, return to the working GameAndUI state and leave the
            -- exact modal blockers owned; this avoids a permanently inert UIOnly panel
            -- while preserving the v0.9.6 protection against in-callback UMG teardown.
            local failed_close_reason = ui.close_reason
            local resumed = false
            if ui.host_visible_shell == true then
                resumed = true
            elseif valid(controller) and valid(library) and valid(widget) and library["SetInputMode_GameAndUIEx"] ~= nil then
                resumed = pcall(library["SetInputMode_GameAndUIEx"], library, controller, widget, 0, false, true)
            end
            if resumed then
                ui.closing = false
                ui.close_reason = nil
                ui.close_generation = 0
                ui.status = "Close scheduler unavailable - restart the game to release this panel."
                set_ui_text()
                if type(dd.publish_modui_host_menu_shell) == "function" and valid(ui.widget) then
                    pcall(dd.publish_modui_host_menu_shell, "active", ui.active_generation,
                        tostring(dd.native_ui_runtime.ObjectAddress(ui.widget) or ""), false, 0, "close-scheduler-recovery")
                end
                log("close quarantine finalizer unavailable; active modal panel restored for safe recovery")
            else
                log("close quarantine finalizer unavailable; settings remains safely quarantined")
            end
            diag("close.quarantine", {
                stage = "schedule-failed",
                resumed = resumed,
                reason = failed_close_reason,
            })
        end
        return true
    end


    -- ---------------------------------------------------------------------------
    -- Pass 85: read-only native-widget diagnostics moved to Scripts\UI\Diagnostics.lua.
    -- Runtime widget ownership, creation, mutation, shell lifetime and input behavior remain here.
    -- ---------------------------------------------------------------------------

    local function create_settings_ui(open_source)
        if ui.open then return true end

        ui.session_generation = (tonumber(ui.session_generation) or 0) + 1
        local opening_generation = ui.session_generation
        ui.pending_reset_key = ""
        ui.pending_reset_generation = 0
        ui.render_text_cache = {}
        ui.render_set_calls = 0
        ui.render_set_skips = 0
        ui.redraw_sequence = 0
        ui.input_dedupe_last_semantic = ""
        ui.input_dedupe_last_source_kind = ""
        ui.input_dedupe_last_clock = -1.0
        ui.input_dedupe_count = 0
        ui.invalid_session_logged = false
        -- Pass 171: preserve a primitive rejection classification for Runtime.InputHost.
        -- Expected gameplay/transition admission rejections are not session failures, and a
        -- transition-like native denial may be bridged across an immediately following LoadMap.
        ui.open_rejection_kind = "construction"
        ui.open_rejection_reason = "open-create-failed"
        runtime_diagnostics.BeginSession()
        diag("session.begin", {
            version = VERSION,
            intent = "open-settings",
            renderer = "v0.9.49-distributed-column-rails",
            source = tostring(open_source or "unknown"),
            generation = opening_generation,
            openPollControllerCacheHits = tonumber(dd.open_bind_controller_cache_hits) or 0,
            openPollControllerCacheMisses = tonumber(dd.open_bind_controller_cache_misses) or 0,
        })
        if type(dd.modui_host_registry) == "table" and type(dd.modui_host_registry.SetMenuActiveConsumerRequest) == "function" then
            pcall(dd.modui_host_registry.SetMenuActiveConsumerRequest, "MortalShell2TTS")
        end
        if type(dd.publish_modui_host_menu_session) == "function" then
            pcall(dd.publish_modui_host_menu_session, "opening", opening_generation, tostring(open_source or "unknown"))
        end
        if type(dd.publish_modui_host_menu_shell) == "function" then
            pcall(dd.publish_modui_host_menu_shell, "none", opening_generation, "", false, 0,
                "session-opening:" .. tostring(open_source or "unknown"))
        end

        -- Resolve the authoritative player/controller and Mortal Shell UI handler
        -- BEFORE creating a borrowed prompt. v0.9.41 uses the game's own menu state
        -- as an admission boundary instead of treating the global configurable open bind as
        -- proof that another modal is safe to construct.
        local player, controller = dd.native_presentation.GetPlayerAndController()
        diag("session.player", {
            player = valid(player) and object_name(player) or "<invalid>",
            controller = valid(controller) and object_name(controller) or "<invalid>",
            resolver = tostring(dd.player_controller_resolution_source or "unknown"),
            resolverError = tostring(dd.player_controller_resolution_error or ""),
            controllerAddress = valid(controller) and tostring(dd.native_ui_runtime.ObjectAddress(controller) or "") or "",
        })
        if not valid(player) then
            log("settings UI unavailable: live BP_PlayerCharacter_C was not found")
            if type(dd.publish_modui_host_menu_session) == "function" then
                pcall(dd.publish_modui_host_menu_session, "closed", opening_generation, "open-failed")
            end
            ui.open_rejection_kind = "context-unavailable"
            ui.open_rejection_reason = "player-unavailable"
            diag("session.end", { status = "player-unavailable" })
            return false
        end
        if not valid(controller) then
            log("settings UI unavailable: live local PlayerController was not found")
            if type(dd.publish_modui_host_menu_session) == "function" then
                pcall(dd.publish_modui_host_menu_session, "closed", opening_generation, "open-failed")
            end
            ui.open_rejection_kind = "context-unavailable"
            ui.open_rejection_reason = "controller-unavailable"
            diag("session.end", { status = "controller-unavailable" })
            return false
        end

        local gameplay_ok, gameplay_reason, gameplay_identity = dd.evaluate_gameplay_context(player, controller, nil)
        if not gameplay_ok then
            log("settings UI open blocked outside gameplay: " .. tostring(gameplay_reason))
            if type(dd.publish_modui_host_menu_session) == "function" then
                pcall(dd.publish_modui_host_menu_session, "closed", opening_generation, "open-failed")
            end
            ui.open_rejection_kind = "non-gameplay"
            ui.open_rejection_reason = tostring(gameplay_reason or "blocked-by-gameplay-context")
            diag("session.end", {
                status = "blocked-by-gameplay-context",
                reason = gameplay_reason,
                controller = gameplay_identity.controllerName,
                player = gameplay_identity.playerName,
            })
            return false
        end

        local transition_ok, transition_reason = dd.evaluate_transition_settle_admission(controller)
        if not transition_ok then
            log("settings UI open blocked while world/controller settles: " .. tostring(transition_reason))
            if type(dd.publish_modui_host_menu_session) == "function" then
                pcall(dd.publish_modui_host_menu_session, "closed", opening_generation, "open-failed")
            end
            ui.open_rejection_kind = "transition-settle"
            ui.open_rejection_reason = tostring(transition_reason or "blocked-by-transition-settle")
            diag("session.end", {
                status = "blocked-by-transition-settle",
                reason = transition_reason,
            })
            return false
        end

        local pre_handler = dd.resolve_native_ui_handler(player)
        if not valid(pre_handler) and valid(controller) then
            pre_handler = dd.resolve_native_ui_handler(controller)
        end
        if not valid(pre_handler) then
            local transition_like = dd.note_native_transition_denial("handler-unavailable") == true
            ui.open_rejection_kind = transition_like and "transition-native" or "native-admission"
            ui.open_rejection_reason = "handler-unavailable"
            log("settings UI open blocked by native UI/game state: handler-unavailable")
            if type(dd.publish_modui_host_menu_session) == "function" then
                pcall(dd.publish_modui_host_menu_session, "closed", opening_generation, "open-failed")
            end
            diag("session.end", { status = "blocked-by-native-admission", reason = "handler-unavailable" })
            return false
        end

        local handler_gameplay_ok, handler_gameplay_reason, handler_identity =
            dd.evaluate_gameplay_context(player, controller, pre_handler)
        if not handler_gameplay_ok then
            log("settings UI open blocked outside gameplay UI handler: " .. tostring(handler_gameplay_reason))
            if type(dd.publish_modui_host_menu_session) == "function" then
                pcall(dd.publish_modui_host_menu_session, "closed", opening_generation, "open-failed")
            end
            ui.open_rejection_kind = "non-gameplay"
            ui.open_rejection_reason = tostring(handler_gameplay_reason or "blocked-by-gameplay-context")
            diag("session.end", {
                status = "blocked-by-gameplay-context",
                reason = handler_gameplay_reason,
                controller = handler_identity.controllerName,
                player = handler_identity.playerName,
                handler = handler_identity.handlerName,
            })
            return false
        end

        -- Pass 86: if a previous TTS-owned gameplay-effect removal failed, retry only
        -- those exact handles and only against the exact same live AbilitySystemComponent.
        -- This cannot clear arbitrary native menu/game state.
        dd.retry_pending_native_modal_cleanup(player, "pre-open")

        local admission_ok, admission_reason = dd.evaluate_native_menu_admission(pre_handler, controller, "pre-open")
        if not admission_ok then
            local transition_like = dd.note_native_transition_denial(admission_reason) == true
            ui.open_rejection_kind = transition_like and "transition-native" or "native-admission"
            ui.open_rejection_reason = tostring(admission_reason or "native-admission-blocked")
            dd.log_blocked_native_admission(pre_handler, controller, admission_reason)
            log("settings UI open blocked by native UI/game state: " .. tostring(admission_reason))
            if type(dd.publish_modui_host_menu_session) == "function" then
                pcall(dd.publish_modui_host_menu_session, "closed", opening_generation, "open-failed")
            end
            diag("session.end", {
                status = "blocked-by-native-admission",
                reason = admission_reason,
            })
            return false
        end
        ui.admission_block_signature = ""
        ui.admission_block_repeat_count = 0

        -- Only acquire helper/catalog state after the game has admitted the modal.
        -- This avoids doing voice/status work for a keypress that native UI state
        -- rejects before construction. Opening settings is also a useful bounded
        -- liveness checkpoint: if the helper died since the previous narration, request
        -- recovery before reading its voice/output catalogs. This does not add another
        -- permanent poll and therefore cannot race normal game shutdown on its own.
        local helper_ready = false
        local helper_check_ok, helper_check_error = pcall(function()
            helper_ready = dd.ensure_helper_running("settings-open") == true
        end)
        diag("helper.settingsOpenCheck", {
            status = helper_check_ok and (helper_ready and "fresh" or "recovery-requested") or "error",
            error = helper_check_ok and nil or tostring(helper_check_error),
        })
        refresh_voices(true)
        diag("session.data", {
            voices = #ui.voices,
            engine = config.engine,
            audioOutputs = #ui.audio_outputs,
        })

        local ok_wbl, wbl = pcall(function()
            return unwrap(StaticFindObject(WIDGET_BLUEPRINT_LIBRARY_CDO))
        end)
        if not ok_wbl or not valid(wbl) then
            log("settings UI unavailable: WidgetBlueprintLibrary CDO was not found")
            if type(dd.publish_modui_host_menu_session) == "function" then
                pcall(dd.publish_modui_host_menu_session, "closed", opening_generation, "open-failed")
            end
            diag("session.end", {
                status = "widget-library-unavailable",
                error = wbl,
            })
            return false
        end

        -- A LoadMap hotkey quarantine intentionally invalidates the consumer's cached
        -- readiness mirror. Refresh the current primitive acknowledgement synchronously
        -- before deciding to instantiate the emergency borrowed-reader fallback; otherwise
        -- the first post-zone open can race the delayed acknowledgement poll even though the
        -- standalone ModUI shell is already ready in its own Lua state.
        if type(dd.probe_modui_host_ack) == "function" then
            pcall(dd.probe_modui_host_ack, "settings-open-sync", false)
        end
        if type(_G.MortalShell2TTSRuntime) == "table"
            and _G.MortalShell2TTSRuntime.modui_host_visible_shell_ready == true
            and type(dd.ModUI) == "table" and type(dd.ModUI.Capabilities) == "table"
            and dd.ModUI.Capabilities.hostVisibleShellSingleOwner == true
            and type(dd.modui_host_registry) == "table" and type(dd.modui_host_registry.SetMenuPresentation) == "function" then
            ui.active_generation = opening_generation
            ui.open = true
            ui.host_visible_shell = true
            ui.host_visible_shell_generation = opening_generation
            ui.presentation_mode = "host"
            ui.window_profile = ((dd.voice_browser_active ~= nil and dd.voice_browser_active())
                or (dd.controller_settings_active ~= nil and dd.controller_settings_active())) and "browser" or "main"
            ui.controller = controller
            ui.widget_library = wbl
            ui.native_ui_handler = pre_handler
            ui.native_error_logged = false
            ui.status = "Opening ModUI shared visible shell..."
            settings_widget_object_name = "MortalShell2ModUI.Host.VisibleShell"
            diag("session.shell-ready", {
                object = settings_widget_object_name,
                generation = opening_generation,
                shellReused = false,
                visibleShellOwner = "MortalShell2ModUI",
                presentation = "primitive-cross-state",
            })
            if type(dd.publish_modui_host_menu_shell) == "function" then
                -- The observational shell channel describes consumer-owned fallback shells.
                -- On the healthy host path TTS owns no shell, so publish the protocol-valid
                -- `none` state while the separate visible-shell host remains active.
                pcall(dd.publish_modui_host_menu_shell, "none", opening_generation, "", false, 0, "host-visible-shell-owned-by-modui")
            end

            local isolation_ok = valid(pre_handler) and dd.acquire_native_modal_isolation(player, pre_handler)
            if not isolation_ok then
                ui.open = false
                ui.host_visible_shell = false
                ui.active_generation = 0
                if type(dd.publish_modui_host_menu_session) == "function" then
                    pcall(dd.publish_modui_host_menu_session, "closed", opening_generation, "open-failed")
                end
                diag("session.end", { status = "modal-isolation-acquire-failed", visibleShellOwner = "MortalShell2ModUI" })
                return false
            end

            local post_isolation_ok, post_isolation_result = xpcall(function()
                local bridge_ok = false
                if type(dd.start_modui_host_native_listener_primary) == "function" then
                    pcall(function()
                        bridge_ok = dd.start_modui_host_native_listener_primary(player, controller, wbl, pre_handler, opening_generation) == true
                    end)
                end
                if not bridge_ok then
                    bridge_ok = create_native_input_bridge(player, controller, wbl, pre_handler)
                end
                if bridge_ok then
                    if ui.native_modal_mode == "exact-gameplay-effects-unpaused" then
                        ui.status = "Ready - shared ModUI shell + native input lock active."
                    elseif ui.native_modal_mode == "exact-gameplay-effects+user-pause" then
                        ui.status = "Ready - shared ModUI shell + requested game pause active."
                    else
                        ui.status = "Ready - shared ModUI shell active."
                    end
                else
                    ui.status = "Keyboard only - shared ModUI shell active."
                end
                if dd.refresh_binding_conflicts ~= nil then dd.refresh_binding_conflicts(controller) end
                local redraw_ok = set_ui_text()
                if type(dd.publish_modui_host_menu_session) == "function" then
                    pcall(dd.publish_modui_host_menu_session, "ready", opening_generation, redraw_ok and "host-visible-ready" or "host-visible-redraw-failed")
                end
                diag("session.ready", {
                    status = redraw_ok and "ready" or "redraw-failed",
                    controllerBridge = bridge_ok,
                    mouseBridge = bridge_ok and ui.mouse_input_ready,
                    isolationMode = ui.native_modal_mode,
                    renderer = "MortalShell2ModUI.Host.ShellService",
                    visibleShellOwner = "MortalShell2ModUI",
                    presentationSequence = type(_G.MortalShell2TTSRuntime) == "table" and _G.MortalShell2TTSRuntime.modui_host_presentation_sequence or 0,
                    tab = current_tab().key,
                    generation = opening_generation,
                    shellReused = false,
                })
                return true
            end, function(err) return tostring(err) end)

            if not post_isolation_ok then
                local failure = tostring(post_isolation_result or "unknown host-visible-shell startup failure")
                log("shared ModUI visible-shell startup failed; rolling back modal ownership: " .. failure)
                ui.open = false
                ui.host_visible_shell = false
                pcall(disable_settings_input_bridge)
                if ui.native_modal_isolation == true then pcall(dd.release_native_modal_isolation, "host visible shell startup failure") end
                clear_native_widget_refs()
                ui.controller = nil
                ui.widget_library = nil
                ui.native_ui_handler = nil
                ui.active_generation = 0
                if type(dd.publish_modui_host_menu_session) == "function" then
                    pcall(dd.publish_modui_host_menu_session, "closed", opening_generation, "open-failed")
                end
                diag("session.end", { status = "host-visible-shell-startup-failed", generation = opening_generation, error = failure })
                return false
            end
            return post_isolation_result == true
        end

        -- Bounded fail-soft fallback: if the standalone visible-shell host is unavailable,
        -- preserve the proven Pass-159 local borrowed-reader shell without duplicating it on healthy runs.
        ui.host_visible_shell = false
        ui.host_visible_shell_generation = 0
        ui.presentation_mode = "fallback"
        diag("dependency.moduiVisibleShell", {
            status = "consumer-local-fallback",
            hostReady = type(_G.MortalShell2TTSRuntime) == "table" and _G.MortalShell2TTSRuntime.modui_host_visible_shell_ready == true,
            hostState = type(_G.MortalShell2TTSRuntime) == "table" and tostring(_G.MortalShell2TTSRuntime.modui_host_visible_shell_state or "unavailable") or "unavailable",
        })

        local create = wbl["Create"]
        if create == nil then
            log("settings UI unavailable: WidgetBlueprintLibrary.Create was not exposed")
            if type(dd.publish_modui_host_menu_session) == "function" then
                pcall(dd.publish_modui_host_menu_session, "closed", opening_generation, "open-failed")
            end
            diag("session.end", { status = "widget-create-unavailable" })
            return false
        end

        ui.active_generation = opening_generation
        local widget, shell_reused = restore_cached_settings_shell(controller)
        if not shell_reused then
            -- Pass 160: only the bounded consumer-local fallback is allowed to load/create
            -- the borrowed native Settings shell. The healthy shared-host path returns above
            -- without even resolving this widget class in the TTS Lua state.
            local widget_class = dd.native_presentation.LoadNativeSettingsClass()
            if not valid(widget_class) then
                ui.active_generation = 0
                log("settings UI unavailable: native lore-reader Widget Blueprint class could not be loaded")
                if type(dd.publish_modui_host_menu_session) == "function" then
                    pcall(dd.publish_modui_host_menu_session, "closed", opening_generation, "open-failed")
                end
                diag("session.end", { status = "reader-class-unavailable", renderer = "consumer-local-fallback" })
                return false
            end
            diag("shell.create", {
                stage = "before-create",
                class = object_name(widget_class),
                generation = opening_generation,
            })
            local ok_create, created_widget = pcall(create, wbl, player, widget_class, controller)
            widget = unwrap(created_widget)
            if not ok_create or not valid(widget) then
                ui.active_generation = 0
                log("settings UI unavailable: WidgetBlueprintLibrary.Create failed: " .. tostring(widget))
                if type(dd.publish_modui_host_menu_session) == "function" then
                    pcall(dd.publish_modui_host_menu_session, "closed", opening_generation, "open-failed")
                end
                diag("session.end", {
                    status = "reader-create-failed",
                    error = widget,
                    generation = opening_generation,
                })
                return false
            end
            diag("shell.create", {
                stage = "after-create",
                status = "ok",
                object = object_name(widget),
                address = dd.native_ui_runtime.ObjectAddress(widget) or "<unknown>",
                generation = opening_generation,
            })
        else
            diag("shell.create", {
                stage = "reuse",
                status = "ok",
                object = object_name(widget),
                address = dd.native_ui_runtime.ObjectAddress(widget) or "<unknown>",
                generation = opening_generation,
            })
        end

        -- Death-safe borrowed-prompt policy. WBP_ConfirmationPromptBase has an
        -- OnPlayerDeath path controlled by bShouldRemoveOnDeath. This instance is
        -- only a settings renderer, so it must never participate in death cleanup.
        -- Modal isolation is managed independently through TTS-owned gameplay-effect
        -- handles (including the game-native interaction blocker), with balanced UIPauseGame retained only as a compatibility fallback.
        pcall(function() widget.bShouldRemoveOnDeath = false end)
        pcall(function() widget.bPauseGame = false end)
        local remove_on_death_state, pause_flag_state = "<unreadable>", "<unreadable>"
        pcall(function() remove_on_death_state = tostring(unwrap(widget.bShouldRemoveOnDeath)) end)
        pcall(function() pause_flag_state = tostring(unwrap(widget.bPauseGame)) end)
        log("visual settings shell death policy preConstruct bShouldRemoveOnDeath=" .. remove_on_death_state
            .. " bPauseGame=" .. pause_flag_state)
        diag("shell.policy", {
            stage = "pre-construct",
            bShouldRemoveOnDeath = remove_on_death_state,
            bPauseGame = pause_flag_state,
        })

        -- The ObjectDump shows WBP_IL_ReadText can auto-activate during Construct.
        -- Its WidgetTree child already exists after Create(), so disable auto-activation
        -- before AddToViewport/Construct whenever UE4SS exposes it. This removes even
        -- the brief window where the visual shell could bind its document navigation.
        local reader_listener = dd.native_presentation.NativeWidgetField(widget, "WBP_IL_ReadText")
        if valid(reader_listener) then
            pcall(function() reader_listener.bAutoActivate = false end)
            pcall(function() reader_listener.bEnabled = false end)
            dd.log_listener_delegate_bindings(reader_listener, "live-reader-preconstruct")
            dd.log_listener_input_handles(reader_listener, "live-reader-preconstruct")
        end

        diag("shell.viewport", {
            stage = shell_reused and "reuse-visible" or "before-add",
            object = object_name(widget),
            generation = opening_generation,
        })
        local ok_viewport, viewport_error = true, nil
        if not shell_reused then
            ok_viewport, viewport_error = pcall(function()
                widget:AddToViewport(10000)
            end)
        end
        if not ok_viewport then
            pcall(function() widget:RemoveFromParent() end)
            ui.active_generation = 0
            log("settings UI unavailable: native widget AddToViewport failed: " .. tostring(viewport_error))
            if type(dd.publish_modui_host_menu_session) == "function" then
                pcall(dd.publish_modui_host_menu_session, "closed", opening_generation, "open-failed")
            end
            diag("session.end", {
                status = "reader-add-to-viewport-failed",
                error = viewport_error,
            })
            return false
        end
        diag("shell.viewport", {
            stage = shell_reused and "reused" or "after-add",
            status = "ok",
            object = object_name(widget),
            generation = opening_generation,
        })

        -- Re-resolve after Construct, then force-disable/unbind the visual reader's
        -- embedded listener. It is display-only and must never receive settings input.
        if not valid(reader_listener) then
            reader_listener = dd.native_presentation.NativeWidgetField(widget, "WBP_IL_ReadText")
        end
        local construct_handler = nil
        if valid(reader_listener) then
            pcall(function() reader_listener.bAutoActivate = false end)
            pcall(function() reader_listener:SetEnabledState(false) end)
            pcall(function() reader_listener:UnbindInputs() end)
            pcall(function() reader_listener.bEnabled = false end)
            local ok_handler, value = pcall(function() return unwrap(reader_listener.UserInterfaceComponent) end)
            if ok_handler and valid(value) then construct_handler = value end
            log("visual reader input listener forced disabled preConstruct=true object=" .. object_name(reader_listener))
            dd.log_listener_delegate_bindings(reader_listener, "live-reader-postconstruct-disabled")
            dd.log_listener_input_handles(reader_listener, "live-reader-postconstruct-disabled")
        else
            log("visual reader input listener field unavailable; continuing visual-only")
            diag("shell.readerListener", { status = "unavailable" })
        end

        local handler = valid(construct_handler) and construct_handler or pre_handler
        diag("handler.compare", {
            pre = valid(pre_handler) and object_name(pre_handler) or "<invalid>",
            construct = valid(construct_handler) and object_name(construct_handler) or "<invalid>",
            same = valid(pre_handler) and valid(construct_handler) and dd.native_ui_runtime.SameObject(pre_handler, construct_handler) or false,
            selected = valid(handler) and object_name(handler) or "<invalid>",
        })

        -- From this point onward admission snapshots are diagnostic only: our own
        -- borrowed reader may temporarily participate in ActiveReadText/confirmation
        -- bookkeeping until retire_settings_visual_shell neutralizes it.
        dd.evaluate_native_menu_admission(handler, controller, "post-reader-construct-observe")

        -- Construct/OnMenuOpen on a real confirmation prompt may register the widget
        -- in ActiveConfirmations. It is visual-only for us, so immediately remove
        -- that game-level prompt ownership while leaving the Slate widget visible.
        retire_settings_visual_shell(widget, handler, "post-construct")
        dd.evaluate_native_menu_admission(handler, controller, "post-reader-retire-observe")

        -- Fallback construction has already attached a real lore-reader widget. Protect
        -- input snapshot/acquisition so any future helper regression still retires and
        -- removes that shell instead of leaving an unowned native lore page onscreen.
        local input_acquire_call_ok, input_acquire_result = pcall(
            acquire_settings_input, controller, wbl, widget, handler)
        if not valid(controller) or not input_acquire_call_ok or input_acquire_result ~= true then
            retire_settings_visual_shell(widget, handler, "input-acquire-failed")
            pcall(function() widget:RemoveFromParent() end)
            restore_settings_input("modal input acquisition failed")
            clear_native_widget_refs()
            log("settings UI unavailable: native GameAndUI input ownership could not be acquired"
                .. (input_acquire_call_ok and "" or (": " .. tostring(input_acquire_result))))
            if type(dd.publish_modui_host_menu_session) == "function" then
                pcall(dd.publish_modui_host_menu_session, "closed", opening_generation, "open-failed")
            end
            diag("session.end", {
                status = "modal-input-acquire-failed",
                callOk = input_acquire_call_ok,
                error = input_acquire_call_ok and nil or tostring(input_acquire_result),
            })
            return false
        end

        ui.widget = widget
        if not shell_reused then
            ui.header_widget = dd.native_presentation.NativeWidgetField(widget, "Text_PromptName")
            ui.body_widget = dd.native_presentation.NativeWidgetField(widget, "RTB_ReadText")
            ui.page_widget = dd.native_presentation.NativeWidgetField(widget, "Text_Page_Status")
        end
        ui.open = true
        ui.native_error_logged = false
        ui.status = "Opening native controller bridge..."
        settings_widget_object_name = object_name(widget)
        diag("session.shell-ready", {
            object = settings_widget_object_name,
            header = valid(ui.header_widget),
            body = valid(ui.body_widget),
            page = valid(ui.page_widget),
            generation = opening_generation,
            shellReused = shell_reused,
        })
        if type(dd.publish_modui_host_menu_shell) == "function" then
            pcall(dd.publish_modui_host_menu_shell, "active", opening_generation,
                tostring(dd.native_ui_runtime.ObjectAddress(widget) or ""), shell_reused == true, 0,
                shell_reused and "shell-reused" or "shell-created")
        end

        -- Keep the visually-successful v0.9.40 presentation exactly intact. v0.9.41
        -- adds diagnostics/ownership hardening around it, not another geometry pass.
        local two_column_ok = shell_reused or dd.native_presentation.CreateNativeUIFoundation(player, controller, wbl, widget)

        local renderer_name = ui.presentation_mode == "rails"
            and "native-reader-shell+compact-parent-owned-passive-rails"
            or "native-reader-shell+compact-text-list-fallback"
        log("settings UI opened tab=" .. tostring(current_tab().key)
            .. " renderer=" .. renderer_name
            .. " object=" .. settings_widget_object_name)
        diag("renderer.ready", {
            status = ui.presentation_mode,
            foundation = two_column_ok,
            object = settings_widget_object_name,
            shellReused = shell_reused,
            generation = opening_generation,
        })

        local isolation_ok = valid(handler) and dd.acquire_native_modal_isolation(player, handler)
        if not isolation_ok then
            -- GameAndUI must never be left active without both character-action and
            -- native-menu isolation. In particular, pause alone cannot stop the map
            -- action because that is UI state, not world simulation.
            log("settings UI unavailable: native modal isolation could not be acquired; closing fail-safe")
            diag("session.failure", { stage = "modal-isolation", status = "failed" })
            ui.open = false
            disable_settings_input_bridge()
            if valid(widget) then
                retire_settings_visual_shell(widget, handler, "modal-isolation-acquire-failed")
                pcall(function() widget:RemoveFromParent() end)
            end
            restore_settings_input("modal isolation acquisition failed")
            clear_native_widget_refs()
            if type(dd.publish_modui_host_menu_session) == "function" then
                pcall(dd.publish_modui_host_menu_session, "closed", opening_generation, "open-failed")
            end
            diag("session.end", { status = "modal-isolation-acquire-failed" })
            return false
        end
        diag("modalIsolation.ready", {
            status = "ok",
            mode = ui.native_modal_mode,
            ownedHandles = type(ui.native_modal_handles) == "table" and #ui.native_modal_handles or 0,
            pauseFallbackBumps = ui.native_pause_bumps,
            pauseRequested = config.pause_game_while_menu_open == true,
            pauseReason = ui.native_pause_reason,
            mapVerified = ui.native_menu_block_verified,
            handler = valid(handler) and object_name(handler) or "<invalid>",
        })

        -- Pass 138 corrective: everything after native modal isolation is acquired is a
        -- transaction. Pass 137 proved that an ordinary Lua scope error in this phase can
        -- otherwise strand GameAndUI + gameplay blockers + UIPauseGame while leaving only the
        -- unpopulated native template shell onscreen. Keep the entire listener-activation /
        -- first-redraw phase behind xpcall and fail closed through the proven teardown path.
        local post_isolation_ok, post_isolation_result = xpcall(function()
            local bridge_ok = false
            if CONSUMER_NATIVE_LISTENER_TRANSITION_ISOLATION then
                -- Historical Pass 137/151 safe fallback: do not publish HOST_NATIVE_LISTENER_TOKEN for TTS. Construct the
                -- complete proven consumer bridge instead, then publish its exact numeric address
                -- to the still-active ModUI native-input mirror. Host.InputService explicitly does
                -- not create a second listener for numeric requests, so this remains one physical
                -- WBP_InputListener while isolating only the construction/lifetime owner.
                -- This function is defined before the later composition-root `local runtime`; use
                -- the process-retained table explicitly so Lua lexical scope cannot resolve a nil
                -- global (the Pass-137 target-game failure).
                local listener_runtime = _G.MortalShell2TTSRuntime
                diag("input.listenerOwnership", {
                    status = "consumer-transition-isolation",
                    generation = ui.active_generation,
                    singlePhysicalListener = true,
                    hostMirror = type(listener_runtime) == "table"
                        and listener_runtime.modui_host_native_input_hook_ready == true,
                    hostPrimaryCapability = type(listener_runtime) == "table"
                        and listener_runtime.modui_host_native_listener_primary_ready == true,
                })
                bridge_ok = create_native_input_bridge(player, controller, wbl, handler)
            else
                diag("input.listenerOwnership", {
                    status = "host-owned-listener-host-session-hook",
                    generation = ui.active_generation,
                    singlePhysicalListener = true,
                    processWideHook = false,
                    hostSessionHook = true,
                    localSessionHook = false,
                    hostPrimaryCapability = type(_G.MortalShell2TTSRuntime) == "table"
                        and _G.MortalShell2TTSRuntime.modui_host_native_listener_primary_ready == true,
                })
                if type(dd.start_modui_host_native_listener_primary) == "function" then
                    local ok_primary = false
                    pcall(function() ok_primary = dd.start_modui_host_native_listener_primary(player, controller, wbl, handler, ui.active_generation) == true end)
                    bridge_ok = ok_primary
                end
                if not bridge_ok then
                    bridge_ok = create_native_input_bridge(player, controller, wbl, handler)
                end
            end
            if not bridge_ok then
                log("native controller/mouse bridge unavailable; keyboard navigation remains available while gameplay stays isolated")
            end

            if bridge_ok then
                if ui.native_modal_mode == "exact-gameplay-effects-unpaused" then
                    ui.status = "Ready - unpaused native input lock active."
                elseif ui.native_modal_mode == "exact-gameplay-effects+user-pause" then
                    ui.status = "Ready - native input lock + requested game pause active."
                elseif ui.native_modal_mode == "exact-gameplay-effects-unpaused-pause-request-failed" then
                    ui.status = "Ready - native input lock active; requested game pause unavailable."
                else
                    ui.status = "Ready - native menu lock and compatibility pause active."
                end
            else
                ui.status = "Keyboard only - native input lock remains active."
            end

            dd.log_handler_active_listeners(handler, ui.native_listener, "settings-open")
            dd.evaluate_native_menu_admission(handler, controller, "settings-open-observe")
            if dd.refresh_binding_conflicts ~= nil then dd.refresh_binding_conflicts(controller) end

            local redraw_ok = set_ui_text()
            if type(dd.publish_modui_host_menu_session) == "function" then
                pcall(dd.publish_modui_host_menu_session, "ready", opening_generation, redraw_ok and "ready" or "redraw-failed")
            end
            diag("session.ready", {
                status = redraw_ok and "ready" or "redraw-failed",
                controllerBridge = bridge_ok,
                mouseBridge = bridge_ok and ui.mouse_input_ready,
                isolationMode = ui.native_modal_mode,
                pauseRequested = config.pause_game_while_menu_open == true,
                pauseReason = ui.native_pause_reason,
                renderer = ui.presentation_mode,
                tab = current_tab().key,
                generation = opening_generation,
                shellReused = shell_reused,
            })
            return true
        end, function(err)
            return tostring(err)
        end)

        if not post_isolation_ok then
            local failure = tostring(post_isolation_result or "unknown post-isolation failure")
            local failed_shell_address = valid(widget) and tostring(dd.native_ui_runtime.ObjectAddress(widget) or "") or ""
            log("settings UI post-isolation startup failed; rolling back modal ownership: " .. failure)
            diag("session.failure", {
                stage = "post-isolation-startup",
                status = "lua-error",
                error = failure,
                generation = opening_generation,
            })
            ui.open = false
            local bridge_cleanup_ok = pcall(disable_settings_input_bridge)
            -- Cleanup itself must be fail-soft. If the bridge teardown throws before its
            -- completion barrier releases blockers/pause, fall back directly to the balanced
            -- modal-isolation release path rather than allowing a second exception to strand
            -- the player again. The release function is ownership-counted/idempotent here.
            if not bridge_cleanup_ok or ui.native_modal_isolation == true then
                pcall(dd.release_native_modal_isolation, "post-isolation startup failure fallback")
            end
            if valid(widget) then
                pcall(retire_settings_visual_shell, widget, handler, "post-isolation-startup-failed")
                pcall(function() widget:RemoveFromParent() end)
            end
            pcall(function() restore_settings_input("post-isolation startup failure") end)
            if type(dd.publish_modui_host_menu_shell) == "function" then
                pcall(dd.publish_modui_host_menu_shell, "retired", opening_generation,
                    failed_shell_address, false, 0, "post-isolation-startup-failed")
            end
            pcall(clear_native_widget_refs)
            if type(dd.publish_modui_host_menu_session) == "function" then
                pcall(dd.publish_modui_host_menu_session, "closed", opening_generation, "open-failed")
            end
            diag("session.end", {
                status = "post-isolation-startup-failed",
                generation = opening_generation,
                error = failure,
            })
            return false
        end
        if post_isolation_result == true then
            ui.open_rejection_kind = nil
            ui.open_rejection_reason = nil
            return true
        end
        return false
    end

    function dd.toggle_settings_ui(source)
        if ui.closing then return false end
        if ui.open then
            return request_controller_close_quarantine("toggle key")
        end

        -- Pass 166: opening is one fail-closed transaction. A diagnostic/helper error must
        -- never leave the shared host's primitive session at `opening`, even when the error
        -- happens before ui.open or ui.active_generation is set. This exact stale state was
        -- republished across LoadMap in the v0.9.242 target-game failure and suppressed every
        -- later open hotkey.
        local function rollback_open_attempt(reason, failure, rejection_kind, rejection_reason)
            local failed_generation = math.max(0, math.floor(tonumber(ui.session_generation) or 0))
            local widget = unwrap(ui.widget)
            local handler = unwrap(ui.native_ui_handler)
            local expected_rejection = failure == nil and (
                rejection_kind == "context-unavailable"
                or rejection_kind == "non-gameplay"
                or rejection_kind == "transition-settle"
                or rejection_kind == "transition-native"
                or rejection_kind == "native-admission")

            pcall(diag, expected_rejection and "session.rejected" or "session.failure", {
                stage = "open-transaction", status = reason,
                generation = failed_generation, error = failure,
                rejectionKind = rejection_kind, rejectionReason = rejection_reason,
            })
            if failure ~= nil then
                pcall(log, "settings UI open transaction failed; rolling back shared session: " .. tostring(failure))
            end

            pcall(disable_settings_input_bridge)
            pcall(function()
                if valid(widget) then
                    retire_settings_visual_shell(widget, handler, reason)
                    widget:RemoveFromParent()
                end
            end)
            pcall(dd.release_native_modal_isolation, reason)
            pcall(restore_settings_input, reason)
            pcall(clear_native_widget_refs)

            ui.open = false
            ui.closing = false
            ui.close_reason = nil
            ui.close_quarantine_ticks = 0
            ui.host_visible_shell = false
            ui.host_visible_shell_generation = 0
            ui.active_generation = 0
            pcall(dd.clear_reset_confirmation, reason)

            if type(dd.publish_modui_host_menu_shell) == "function" then
                pcall(dd.publish_modui_host_menu_shell, "retired", failed_generation,
                    "", false, 0, reason)
            end
            if type(dd.publish_modui_host_menu_session) == "function" then
                pcall(dd.publish_modui_host_menu_session, "closed", failed_generation, reason)
            end
            pcall(diag, "session.end", {
                status = reason, generation = failed_generation, error = failure,
            })
        end

        local open_ok, open_result = xpcall(function()
            return create_settings_ui(source)
        end, function(err) return tostring(err) end)
        if not open_ok then
            rollback_open_attempt("open-exception", tostring(open_result or "unknown open error"),
                "open-exception", tostring(open_result or "unknown open error"))
            return false, "open-exception", tostring(open_result or "unknown open error")
        end
        if open_result ~= true then
            -- Individual admission/create branches already publish their specific reason.
            -- Reassert the exact terminal generation so no future early return can poison
            -- the shared host's revision-continuity mirror. Pass 171 also preserves the
            -- primitive rejection class so InputHost can bridge only transition-like native
            -- denials without treating expected admission refusal as a session failure.
            local rejection_kind = tostring(ui.open_rejection_kind or "construction")
            local rejection_reason = tostring(ui.open_rejection_reason or "open-rejected")
            rollback_open_attempt("open-rejected", nil, rejection_kind, rejection_reason)
            return false, rejection_kind, rejection_reason
        end
        return true, nil, nil
    end


    dd.destroy_settings_ui = destroy_settings_ui
    dd.request_controller_close_quarantine = request_controller_close_quarantine
    dd.expire_cached_settings_shell = expire_cached_settings_shell

    return {
        ownership = "settings-session-shell-lifecycle",
        Destroy = destroy_settings_ui,
        RequestClose = request_controller_close_quarantine,
        ExpireCachedShell = expire_cached_settings_shell,
        Create = create_settings_ui,
        Toggle = dd.toggle_settings_ui,
        WidgetObjectName = function() return settings_widget_object_name end,
    }
end

return M
