-- MortalShell2TTS Runtime.ModUIHostClient
-- Pass 168 owns the complete TTS-side client/control-plane integration with the standalone
-- MortalShell2ModUI host: registration/acknowledgement, primitive presentation/session/lease/shell
-- publication, host input mailboxes, native-listener requests, and binding revision continuity.

local M = {}

function M.Install(options)
    options = type(options) == "table" and options or {}
    local dd = options.dd
    local modui = options.modui
    local ui = options.ui
    local config = options.config
    local runtime = options.runtime
    local tabs = options.tabs
    local VERSION = tostring(options.version or "")
    local ModRef = options.mod_ref
    local unwrap = options.unwrap
    local valid = options.valid
    local current_tab = options.current_tab
    local current_rows = options.current_rows
    local settings_tab_text = options.settings_tab_text
    local settings_label_text = options.settings_label_text
    local settings_values_text = options.settings_values_text
    local settings_plain_text = options.settings_plain_text
    local set_ui_text = options.set_ui_text
    local create_native_input_bridge = options.create_native_input_bridge
    local diag = options.diag or function() end
    local dispatch_game_thread = options.dispatch_game_thread
    local schedule_one_shot_game_thread = options.schedule_one_shot_game_thread
    local read_modui_host_axis = nil
    local read_modui_host_right_y = nil

    if type(dd) ~= "table" then return nil, "dd missing" end
    if type(modui) ~= "table" then return nil, "modui missing" end
    if type(ui) ~= "table" then return nil, "ui missing" end
    if type(config) ~= "table" then return nil, "config missing" end
    if type(runtime) ~= "table" then return nil, "runtime missing" end
    if type(tabs) ~= "table" then return nil, "tabs missing" end
    if ModRef == nil then return nil, "ModRef missing" end
    if type(unwrap) ~= "function" then return nil, "unwrap missing" end
    if type(valid) ~= "function" then return nil, "valid missing" end
    if type(current_tab) ~= "function" then return nil, "current_tab missing" end
    if type(current_rows) ~= "function" then return nil, "current_rows missing" end
    if type(settings_tab_text) ~= "function" then return nil, "settings_tab_text missing" end
    if type(settings_label_text) ~= "function" then return nil, "settings_label_text missing" end
    if type(settings_values_text) ~= "function" then return nil, "settings_values_text missing" end
    if type(settings_plain_text) ~= "function" then return nil, "settings_plain_text missing" end
    if type(set_ui_text) ~= "function" then return nil, "set_ui_text missing" end
    if type(create_native_input_bridge) ~= "function" then return nil, "create_native_input_bridge missing" end
    if type(dispatch_game_thread) ~= "function" then return nil, "dispatch_game_thread missing" end
    if type(schedule_one_shot_game_thread) ~= "function" then return nil, "schedule_one_shot_game_thread missing" end

-- Pass 117 stages the native-listener boundary by mirroring the exact active TTS listener's
-- InputTriggeredCallback enum events through the standalone host. The existing local hook
-- remains authoritative for semantics in this pass; the mirror is diagnostic-only.
-- Pass 116 extends the staged standalone input owner to fixed keyboard navigation while retaining the native listener.
-- Pass 107: standalone ModUI host acknowledgement handshake. UE4SS shared variables
-- remain primitive-only; TTS publishes one revisioned descriptor and verifies that the
-- standalone ModUI state saw that exact revision. No callback crosses Lua states and the
-- physical keyboard/controller/mouse poll remains consumer-scoped until this is proven.
local PASS134_CONSUMER_OPEN_HOTKEY_ISOLATION = false
-- Pass 154 cautiously restores checkpoint 4 without reviving Pass-134's cross-world controller
-- lifetime. Hosted OPEN-HOTKEY ownership starts quarantined, is disabled again synchronously at
-- every LoadMap PRE boundary, and is re-enabled only after the proven consumer-side controller
-- identity + post-load quiescence gate reports the incoming gameplay world settled.
runtime.modui_host_hotkey_transition_quarantined = true
local modui_host_registration_ready = false
local modui_host_registration = nil
local modui_host_registration_failure = nil
local modui_host_registry = nil
local modui_host_acknowledged = false
local modui_host_hotkey_ready = false
local modui_host_right_y_ready = false
local modui_host_controller_analog_ready = false
runtime.modui_host_controller_capture_ready = false
runtime.modui_host_keyboard_capture_ready = false
runtime.modui_host_keyboard_navigation_ready = false
runtime.modui_host_native_input_hook_ready = false
runtime.modui_host_native_listener_shadow_ready = false
runtime.modui_host_native_listener_primary_ready = false
runtime.modui_host_menu_control_ready = false
runtime.modui_host_menu_session_observation_ready = false
runtime.modui_host_menu_session_transition_ring_ready = false
runtime.modui_host_menu_lease_ready = false
runtime.modui_host_menu_lease_authority_ready = false
runtime.modui_host_menu_shell_observation_ready = false
runtime.modui_host_visible_shell_ready = false
runtime.modui_host_visible_shell_active = false
runtime.modui_host_presentation_sequence = 0
runtime.modui_host_visible_shell_state = "unavailable"
runtime.modui_host_visible_shell_consumer = ""
runtime.modui_host_visible_shell_address = ""
runtime.modui_host_menu_shell_sequence = 0
runtime.modui_host_menu_shell_state = "none"
runtime.modui_host_menu_shell_generation = 0
runtime.modui_host_menu_shell_address = ""
runtime.modui_host_menu_shell_reused = false
runtime.modui_host_menu_shell_cache_token = 0
runtime.modui_host_menu_shell_reason = "startup"
runtime.modui_host_menu_lease_sequence = 0
runtime.modui_host_menu_lease_active = false
runtime.modui_host_menu_lease_generation = 0
runtime.modui_host_menu_lease_reason = "startup"
runtime.modui_host_menu_session_sequence = 0
runtime.modui_host_menu_session_state = "closed"
runtime.modui_host_menu_session_generation = 0
runtime.modui_host_menu_session_reason = "startup"
runtime.modui_host_pointer_snapshot_ready = false
runtime.modui_host_navigation_sequence = 0
runtime.modui_host_native_input_state = runtime.modui_host_native_input_state or { request_sequence = 0, event_sequence = 0, active = false, generation = 0, host_epoch = "" }
runtime.modui_host_capture_state = { request_sequence = 0, key_sequences = {}, key_values = {}, key_sources = {}, key_press_sequences = {} }
local modui_host_event_sequence = 0
local modui_host_axis_sequences = {}
local modui_host_axis_values = {}
local modui_host_axis_sources = {}
local modui_host_axis_frames = {}
local host_protocol = dd.ModUI ~= nil and dd.ModUI.Host ~= nil and dd.ModUI.Host.Protocol or nil
local host_registry_factory = dd.ModUI ~= nil and dd.ModUI.Host ~= nil and dd.ModUI.Host.Registry or nil
if type(host_protocol) == "table" and type(host_registry_factory) == "table" and type(host_registry_factory.Bind) == "function" then
    local shared_get_adapter = function(name)
        return ModRef:GetSharedVariable(name)
    end
    local shared_set_adapter = function(name, value)
        return ModRef:SetSharedVariable(name, value)
    end
    local bind_ok, host_registry, bind_error = pcall(host_registry_factory.Bind, host_protocol, shared_get_adapter, shared_set_adapter)
    if bind_ok and type(host_registry) == "table" and type(host_registry.Publish) == "function" then
        modui_host_registry = host_registry
        local publish_ok, published, publish_error = pcall(function()
            return host_registry.Publish({
                consumer_id = "MortalShell2TTS",
                display_name = "MortalShell2TTS",
                version = VERSION,
                settings_provider = true,
                visible_shell = true,
                presentation_provider = true,
                menu_order = 100,
                hotkey_provider = not PASS134_CONSUMER_OPEN_HOTKEY_ISOLATION
                    and runtime.modui_host_hotkey_transition_quarantined ~= true,
                open_keyboard = config.menu_keybind,
                open_controller = config.controller_menu_bind,
                modifier_sides_equivalent = config.modifier_sides_equivalent == true,
                keyboard_navigation = true,
                native_input = true,
                actions = "open-settings",
                pages = "MOD,SPEECH,ENGINE",
            })
        end)
        if publish_ok and type(published) == "table" then
            modui_host_registration_ready = true
            modui_host_registration = published
            runtime.modui_host_registration = published
            diag("dependency.moduiHostRegistry", {
                module = "MortalShell2ModUI.Host.Registry",
                protocol = host_protocol.VERSION,
                primitiveOnly = true,
                consumer = published.consumer,
                slot = published.slot,
                probe = published.probe,
                revision = published.revision,
                registryRevision = published.registryRevision,
                hostEpoch = published.hostEpoch,
                hostState = published.hostState,
                hostVersion = published.hostVersion,
                singlePhysicalHost = false,
                status = "published",
            })
        else
            modui_host_registration_failure = tostring(publish_ok and publish_error or published)
        end
    else
        modui_host_registration_failure = tostring(bind_ok and bind_error or host_registry)
    end
else
    modui_host_registration_failure = "host protocol/registry unavailable"
end
if not modui_host_registration_ready then
    diag("dependency.moduiHostRegistry", {
        module = "MortalShell2ModUI.Host.Registry",
        primitiveOnly = true,
        failure = tostring(modui_host_registration_failure),
        singlePhysicalHost = false,
        status = "unavailable-core-continues",
    })
end

dd.modui_host_registry = modui_host_registry
dd.modui_host_registration = modui_host_registration
dd.modui_host_registration_ready = modui_host_registration_ready

function dd.read_modui_controller_profile_revision()
    if type(modui_host_registry) == "table" and type(modui_host_registry.ReadControllerProfileRevision) == "function" then
        local ok, value = pcall(modui_host_registry.ReadControllerProfileRevision)
        if ok and tonumber(value) ~= nil then return math.max(0, math.floor(tonumber(value) or 0)) end
    end
    return 0
end

local modui_controller_profile_revision_seen = -1
local modui_controller_profile_cache = nil
function dd.current_modui_controller_profile(force_reload)
    local profile_api = dd.ModUI and dd.ModUI.Controller and dd.ModUI.Controller.Profile or nil
    if type(profile_api) ~= "table" or type(profile_api.Current) ~= "function" then return nil end
    local revision = dd.read_modui_controller_profile_revision()
    if force_reload == true or modui_controller_profile_cache == nil
        or revision ~= modui_controller_profile_revision_seen then
        local profile = nil
        if type(profile_api.Reload) == "function" then
            local ok, value = pcall(profile_api.Reload)
            if ok and type(value) == "table" then profile = value end
        end
        if type(profile) ~= "table" then profile = profile_api.Current() end
        modui_controller_profile_cache = type(profile) == "table" and profile or nil
        modui_controller_profile_revision_seen = revision
    end
    return modui_controller_profile_cache, modui_controller_profile_revision_seen
end

function dd.publish_modui_controller_profile(profile, reason)
    if not modui_host_registration_ready or type(modui_host_registration) ~= "table"
        or type(modui_host_registry) ~= "table"
        or type(modui_host_registry.PublishControllerProfileState) ~= "function" then
        return false, "controller profile sync unavailable"
    end
    local call_ok, state, publish_err = pcall(
        modui_host_registry.PublishControllerProfileState,
        modui_host_registration.consumer,
        type(profile) == "table" and profile.calibrated == true,
        tostring(reason or "controller-settings"))
    if not call_ok or type(state) ~= "table" then
        return false, tostring(call_ok and publish_err or state)
    end
    diag("dependency.moduiControllerProfile", {
        status = "published", revision = state.revision, source = state.source, calibrated = state.calibrated,
    })
    return true, state
end

function dd.publish_modui_host_menu_presentation()
    if not modui_host_registration_ready or type(modui_host_registration) ~= "table"
        or type(modui_host_registry) ~= "table" or type(modui_host_registry.SetMenuPresentation) ~= "function" then
        return false, "presentation registry unavailable"
    end
    local generation = math.max(0, math.floor(tonumber(ui.active_generation) or 0))
    if generation <= 0 then return false, "presentation generation unavailable" end
    runtime.modui_host_presentation_sequence = math.max(0, math.floor(tonumber(runtime.modui_host_presentation_sequence) or 0)) + 1
    local page_text = type(dd.settings_presentation.PageText) == "function" and dd.settings_presentation.PageText()
        or string.format("%02d/%02d", ui.tab, #tabs)
    local expanded_subview = (dd.voice_browser_active ~= nil and dd.voice_browser_active())
        or (dd.controller_settings_active ~= nil and dd.controller_settings_active())
    local tab_labels, row_kinds, row_progress = {}, {}, {}
    for _, tab in ipairs(tabs) do tab_labels[#tab_labels + 1] = tostring(tab.label or tab.key or "") end
    for _, row in ipairs(current_rows()) do
        local kind = tostring(row.kind or "choice")
        row_kinds[#row_kinds + 1] = (kind == "action") and "action"
            or (kind == "open_keybind" or kind == "controller_open_bind") and "binding"
            or (kind == "int" or kind == "pitch" or kind == "duplicate_window") and "slider"
            or "choice"
        row_progress[#row_progress + 1] = "0"
    end
    local call_ok, result, publish_err = pcall(
        modui_host_registry.SetMenuPresentation,
        modui_host_registration.slot,
        modui_host_registration.consumer,
        modui_host_registration.revision,
        runtime.modui_host_presentation_sequence,
        generation,
        {
            profile = expanded_subview and "browser" or tostring(ui.window_profile or "main"),
            header = type(dd.settings_presentation.HeaderText) == "function" and dd.settings_presentation.HeaderText() or "TEXT TO SPEECH SETTINGS",
            page = page_text,
            tabs = settings_tab_text(),
            tabLabels = table.concat(tab_labels, "\n"),
            selectedTab = math.max(1, math.floor(tonumber(ui.tab) or 1)),
            selectedRow = math.max(1, math.floor(tonumber(ui.selected) or 1)),
            rowKinds = table.concat(row_kinds, "\n"),
            rowProgress = table.concat(row_progress, "\n"),
            labels = settings_label_text(),
            values = settings_values_text(),
            body = settings_plain_text(),
            detailTitle = type(dd.selected_setting_details_title) == "function" and dd.selected_setting_details_title() or tostring(current_tab().label),
            details = dd.details_view_text(dd.native_presentation.SelectedSettingDetailsText()),
        })
    local success = call_ok and type(result) == "table"
    if success then
        ui.host_visible_shell_last_sequence = runtime.modui_host_presentation_sequence
        ui.host_visible_shell_last_status = "published"
    else
        ui.host_visible_shell_last_status = tostring(call_ok and publish_err or result)
    end
    diag("dependency.moduiMenuPresentation", {
        status = success and "published" or "publish-failed",
        generation = generation,
        sequence = runtime.modui_host_presentation_sequence,
        slot = tonumber(modui_host_registration.slot) or -1,
        revision = tonumber(modui_host_registration.revision) or 0,
        profile = expanded_subview and "browser" or tostring(ui.window_profile or "main"),
        error = success and nil or ui.host_visible_shell_last_status,
    })
    return success, ui.host_visible_shell_last_status
end


function dd.publish_modui_host_menu_lease(active, generation, reason)
    active = active == true
    generation = math.max(0, math.floor(tonumber(generation) or 0))
    reason = tostring(reason or "")
    runtime.modui_host_menu_lease_active = active
    runtime.modui_host_menu_lease_generation = generation
    runtime.modui_host_menu_lease_reason = reason
    runtime.modui_host_menu_lease_sequence = math.max(0, math.floor(tonumber(runtime.modui_host_menu_lease_sequence) or 0)) + 1
    if not modui_host_registration_ready or type(modui_host_registration) ~= "table"
        or type(modui_host_registry) ~= "table" or type(modui_host_registry.SetMenuLease) ~= "function" then
        diag("dependency.moduiMenuLease", {
            active = active, generation = generation, sequence = runtime.modui_host_menu_lease_sequence,
            reason = reason, observationOnly = true, status = "publish-unavailable-core-continues",
        })
        return false
    end
    local ok, result, publish_err = pcall(
        modui_host_registry.SetMenuLease,
        modui_host_registration.slot, modui_host_registration.consumer, modui_host_registration.revision,
        runtime.modui_host_menu_lease_sequence, active, generation, reason)
    local success = ok and type(result) == "table"
    local error_text = nil
    if not success then error_text = tostring(ok and publish_err or result) end
    diag("dependency.moduiMenuLease", {
        active = active, generation = generation, sequence = runtime.modui_host_menu_lease_sequence,
        reason = reason, revision = modui_host_registration.revision, slot = modui_host_registration.slot,
        observationOnly = true, status = success and (active and "requested" or "released") or "publish-failed-core-continues",
        error = error_text,
    })
    return success
end


function dd.publish_modui_host_menu_shell(state, generation, shell_address, reused, cache_token, reason)
    state = tostring(state or "none")
    generation = math.max(0, math.floor(tonumber(generation) or 0))
    shell_address = tostring(shell_address or "")
    reused = reused == true
    cache_token = math.max(0, math.floor(tonumber(cache_token) or 0))
    reason = tostring(reason or "")
    runtime.modui_host_menu_shell_state = state
    runtime.modui_host_menu_shell_generation = generation
    runtime.modui_host_menu_shell_address = shell_address
    runtime.modui_host_menu_shell_reused = reused
    runtime.modui_host_menu_shell_cache_token = cache_token
    runtime.modui_host_menu_shell_reason = reason
    runtime.modui_host_menu_shell_sequence = math.max(0, math.floor(tonumber(runtime.modui_host_menu_shell_sequence) or 0)) + 1
    if not modui_host_registration_ready or type(modui_host_registration) ~= "table"
        or type(modui_host_registry) ~= "table" or type(modui_host_registry.SetMenuShell) ~= "function" then
        diag("dependency.moduiMenuShell", {
            state = state, generation = generation, sequence = runtime.modui_host_menu_shell_sequence,
            address = shell_address, reused = reused, cacheToken = cache_token, reason = reason,
            observationOnly = true, status = "publish-unavailable-core-continues",
        })
        return false
    end
    local ok, result, publish_err = pcall(
        modui_host_registry.SetMenuShell,
        modui_host_registration.slot, modui_host_registration.consumer, modui_host_registration.revision,
        runtime.modui_host_menu_shell_sequence, state, generation, shell_address, reused, cache_token, reason)
    local success = ok and type(result) == "table"
    local error_text = nil
    if not success then error_text = tostring(ok and publish_err or result) end
    diag("dependency.moduiMenuShell", {
        state = state, generation = generation, sequence = runtime.modui_host_menu_shell_sequence,
        address = shell_address, reused = reused, cacheToken = cache_token, reason = reason,
        revision = modui_host_registration.revision, slot = modui_host_registration.slot,
        observationOnly = true, status = success and "published" or "publish-failed-core-continues",
        error = error_text,
    })
    return success
end

function dd.publish_modui_host_menu_session(state, generation, reason)
    state = tostring(state or "")
    generation = math.max(0, math.floor(tonumber(generation) or 0))
    reason = tostring(reason or "")
    runtime.modui_host_menu_session_state = state
    runtime.modui_host_menu_session_generation = generation
    runtime.modui_host_menu_session_reason = reason
    runtime.modui_host_menu_session_sequence = math.max(0, math.floor(tonumber(runtime.modui_host_menu_session_sequence) or 0)) + 1
    if not modui_host_registration_ready or type(modui_host_registration) ~= "table"
        or type(modui_host_registry) ~= "table" or type(modui_host_registry.SetMenuSession) ~= "function" then
        diag("dependency.moduiMenuSession", {
            state = state, generation = generation, sequence = runtime.modui_host_menu_session_sequence,
            reason = reason, observationOnly = true, status = "publish-unavailable-core-continues",
        })
        return false
    end
    local ok, result, publish_err = pcall(
        modui_host_registry.SetMenuSession,
        modui_host_registration.slot, modui_host_registration.consumer, modui_host_registration.revision,
        runtime.modui_host_menu_session_sequence, state, generation, reason)
    local success = ok and type(result) == "table"
    local error_text = nil
    if not success then error_text = tostring(ok and publish_err or result) end
    diag("dependency.moduiMenuSession", {
        state = state, generation = generation, sequence = runtime.modui_host_menu_session_sequence,
        reason = reason, revision = modui_host_registration.revision, slot = modui_host_registration.slot,
        observationOnly = true, status = success and "published" or "publish-failed-core-continues",
        error = error_text,
    })
    if state == "opening" and type(dd.publish_modui_host_menu_lease) == "function" then
        pcall(dd.publish_modui_host_menu_lease, true, generation, "session-opening:" .. reason)
    elseif state == "closed" and type(dd.publish_modui_host_menu_lease) == "function" then
        pcall(dd.publish_modui_host_menu_lease, false, generation, "session-closed:" .. reason)
    end
    return success
end

pcall(function() dd.publish_modui_host_menu_session("closed", 0, "startup") end)
pcall(function() dd.publish_modui_host_menu_shell("none", 0, "", false, 0, "startup") end)

local function probe_modui_host_ack(attempt, final_attempt)
    if (modui_host_acknowledged and (PASS134_CONSUMER_OPEN_HOTKEY_ISOLATION
        or runtime.modui_host_hotkey_transition_quarantined == true or modui_host_hotkey_ready) and modui_host_right_y_ready and modui_host_controller_analog_ready
        and runtime.modui_host_controller_capture_ready and runtime.modui_host_keyboard_capture_ready
        and runtime.modui_host_keyboard_navigation_ready
        and dd.ModUI ~= nil and dd.ModUI.Capabilities ~= nil and dd.ModUI.Capabilities.hostSessionNativeInputHook == true
        and runtime.modui_host_native_listener_shadow_ready and runtime.modui_host_native_listener_primary_ready
        and runtime.modui_host_menu_control_ready and runtime.modui_host_menu_session_observation_ready
        and runtime.modui_host_menu_lease_ready and runtime.modui_host_menu_lease_authority_ready
        and runtime.modui_host_menu_shell_observation_ready
        and runtime.modui_host_visible_shell_ready)
        or not modui_host_registration_ready
        or type(modui_host_registry) ~= "table"
        or type(modui_host_registry.ReadAcknowledgement) ~= "function" then
        return
    end
    local ack, ack_error = modui_host_registry.ReadAcknowledgement(
        modui_host_registration.slot,
        modui_host_registration.consumer,
        modui_host_registration.revision
    )
    if type(ack) == "table" then
        modui_host_acknowledged = true
        runtime.modui_host_acknowledged = true
        runtime.modui_host_ack = ack
        local host_metadata = type(modui_host_registry.HostMetadata) == "function" and modui_host_registry.HostMetadata() or {}
        local hotkey_state = type(modui_host_registry.ReadHotkeyState) == "function"
            and modui_host_registry.ReadHotkeyState(ack.slot, ack.consumer, ack.revision, ack.hostEpoch) or nil
        modui_host_hotkey_ready = tostring(host_metadata.physicalHotkeyState or "") == "ready"
            and tostring(host_metadata.epoch or "") == tostring(ack.hostEpoch or "")
            and type(hotkey_state) == "table" and tostring(hotkey_state.state or "") == "ready"
        if PASS134_CONSUMER_OPEN_HOTKEY_ISOLATION then
            modui_host_hotkey_ready = false
            diag("dependency.moduiPhysicalOpenHotkey", {
                status = "consumer-transition-isolation",
                pass = 134,
                physicalHotkeyHost = false,
                hostCapabilityRetained = dd.ModUI ~= nil and dd.ModUI.Capabilities ~= nil
                    and dd.ModUI.Capabilities.hostPhysicalHotkeyInput == true,
            })
        elseif runtime.modui_host_hotkey_transition_quarantined == true then
            modui_host_hotkey_ready = false
            diag("dependency.moduiPhysicalOpenHotkey", {
                status = "transition-quarantined-consumer-fallback",
                pass = 154,
                physicalHotkeyHost = false,
                hostCapabilityRetained = dd.ModUI ~= nil and dd.ModUI.Capabilities ~= nil
                    and dd.ModUI.Capabilities.hostPhysicalHotkeyInput == true,
            })
        end
        modui_host_right_y_ready = tostring(host_metadata.physicalAnalogState or "") == "ready"
            and tostring(host_metadata.epoch or "") == tostring(ack.hostEpoch or "")
            and type(modui_host_registry.ReadAxisSample) == "function"
        modui_host_controller_analog_ready = modui_host_right_y_ready
            and dd.ModUI ~= nil and dd.ModUI.Capabilities ~= nil
            and dd.ModUI.Capabilities.hostPhysicalControllerAnalog == true
        runtime.modui_host_controller_capture_ready = tostring(host_metadata.physicalControllerCaptureState or "") == "ready"
            and tostring(host_metadata.epoch or "") == tostring(ack.hostEpoch or "")
            and dd.ModUI ~= nil and dd.ModUI.Capabilities ~= nil
            and dd.ModUI.Capabilities.hostPhysicalControllerCapture == true
            and type(modui_host_registry.SetCaptureRequest) == "function"
            and type(modui_host_registry.ReadKeySample) == "function"
        runtime.modui_host_keyboard_capture_ready = tostring(host_metadata.physicalKeyboardCaptureState or "") == "ready"
            and tostring(host_metadata.epoch or "") == tostring(ack.hostEpoch or "")
            and dd.ModUI ~= nil and dd.ModUI.Capabilities ~= nil
            and dd.ModUI.Capabilities.hostPhysicalKeyboardCapture == true
            and type(modui_host_registry.SetCaptureRequest) == "function"
            and type(modui_host_registry.ReadKeySample) == "function"
        runtime.modui_host_keyboard_navigation_ready = tostring(host_metadata.physicalKeyboardNavigationState or "") == "ready"
            and tostring(host_metadata.epoch or "") == tostring(ack.hostEpoch or "")
            and dd.ModUI ~= nil and dd.ModUI.Capabilities ~= nil
            and dd.ModUI.Capabilities.hostPhysicalKeyboardNavigation == true
            and type(modui_host_registry.ReadNavigationEvents) == "function"
        runtime.modui_host_native_input_hook_ready = tostring(host_metadata.physicalNativeInputHookState or "") == "session-ready"
            and tostring(host_metadata.epoch or "") == tostring(ack.hostEpoch or "")
            and dd.ModUI ~= nil and dd.ModUI.Capabilities ~= nil
            and dd.ModUI.Capabilities.hostSessionNativeInputHook == true
            and type(modui_host_registry.SetNativeInputRequest) == "function"
            and type(modui_host_registry.ReadNativeInputEvents) == "function"
        runtime.modui_host_native_listener_shadow_ready =
            (tostring(host_metadata.physicalNativeListenerState or "") == "ready"
                or tostring(host_metadata.physicalNativeListenerState or "") == "active")
            and tostring(host_metadata.epoch or "") == tostring(ack.hostEpoch or "")
            and dd.ModUI ~= nil and dd.ModUI.Capabilities ~= nil
            and dd.ModUI.Capabilities.hostPhysicalNativeListenerShadow == true
        runtime.modui_host_native_listener_primary_ready = runtime.modui_host_native_listener_shadow_ready
            and dd.ModUI.Capabilities.hostPhysicalNativeListener == true
            and tostring(host_protocol.HOST_NATIVE_LISTENER_TOKEN or "") ~= ""
        local menu_provider_slot = math.floor(tonumber(host_metadata.menuProviderSlot) or -1)
        local menu_provider_revision = math.max(0, math.floor(tonumber(host_metadata.menuProviderRevision) or 0))
        runtime.modui_host_menu_control_ready = tostring(host_metadata.menuState or "") == "ready"
            and tostring(host_metadata.menuHostEpoch or "") == tostring(ack.hostEpoch or "")
            and tostring(host_metadata.menuProviderConsumer or "") == tostring(ack.consumer or "")
            and menu_provider_slot == math.floor(tonumber(ack.slot) or -1)
            and menu_provider_revision == math.max(0, math.floor(tonumber(ack.revision) or 0))
            and dd.ModUI ~= nil and dd.ModUI.Capabilities ~= nil
            and dd.ModUI.Capabilities.hostMenuService == true
            and dd.ModUI.Capabilities.hostMenuProviderArbitration == true
            and dd.ModUI.Capabilities.hostMenuSessionObservation == true
            and dd.ModUI.Capabilities.hostMenuSessionTransitionRing == true
        runtime.modui_host_hotkey_ready = modui_host_hotkey_ready
        runtime.modui_host_right_y_ready = modui_host_right_y_ready
        runtime.modui_host_controller_analog_ready = modui_host_controller_analog_ready
        local session_state = tostring(host_metadata.menuSessionState or "idle")
        local session_consumer = tostring(host_metadata.menuSessionConsumer or "")
        local session_slot = math.floor(tonumber(host_metadata.menuSessionSlot) or -1)
        local session_revision = math.max(0, math.floor(tonumber(host_metadata.menuSessionRevision) or 0))
        local session_host_epoch = tostring(host_metadata.menuSessionHostEpoch or "")
        runtime.modui_host_menu_session_transition_ring_ready = runtime.modui_host_menu_control_ready
            and dd.ModUI ~= nil and dd.ModUI.Capabilities ~= nil
            and dd.ModUI.Capabilities.hostMenuSessionTransitionRing == true
            and type(modui_host_registry.ReadConsumerMenuSessionEvents) == "function"
        runtime.modui_host_menu_session_observation_ready = runtime.modui_host_menu_session_transition_ring_ready
            and session_host_epoch == tostring(ack.hostEpoch or "")
            and (session_state == "idle"
                or (session_consumer == tostring(ack.consumer or "")
                    and session_slot == math.floor(tonumber(ack.slot) or -1)
                    and session_revision == math.max(0, math.floor(tonumber(ack.revision) or 0))))
        local lease_state = tostring(host_metadata.menuLeaseState or "idle")
        local lease_consumer = tostring(host_metadata.menuLeaseConsumer or "")
        local lease_slot = math.floor(tonumber(host_metadata.menuLeaseSlot) or -1)
        local lease_revision = math.max(0, math.floor(tonumber(host_metadata.menuLeaseRevision) or 0))
        local lease_host_epoch = tostring(host_metadata.menuLeaseHostEpoch or "")
        runtime.modui_host_menu_lease_ready = runtime.modui_host_menu_session_observation_ready
            and dd.ModUI ~= nil and dd.ModUI.Capabilities ~= nil
            and dd.ModUI.Capabilities.hostMenuSessionLease == true
            and dd.ModUI.Capabilities.hostMenuLeaseArbitration == true
            and type(modui_host_registry.SetMenuLease) == "function"
            and lease_host_epoch == tostring(ack.hostEpoch or "")
            and (lease_state == "idle"
                or (lease_state == "granted"
                    and lease_consumer == tostring(ack.consumer or "")
                    and lease_slot == math.floor(tonumber(ack.slot) or -1)
                    and lease_revision == math.max(0, math.floor(tonumber(ack.revision) or 0))))
        runtime.modui_host_menu_lease_authority_ready = runtime.modui_host_menu_lease_ready
            and dd.ModUI ~= nil and dd.ModUI.Capabilities ~= nil
            and dd.ModUI.Capabilities.hostMenuLeaseAuthority == true
            and type(modui_host_registry.ReadMenuLeaseState) == "function"
        local shell_state = tostring(host_metadata.menuShellState or "none")
        local shell_consumer = tostring(host_metadata.menuShellConsumer or "")
        local shell_slot = math.floor(tonumber(host_metadata.menuShellSlot) or -1)
        local shell_revision = math.max(0, math.floor(tonumber(host_metadata.menuShellRevision) or 0))
        local shell_host_epoch = tostring(host_metadata.menuShellHostEpoch or "")
        runtime.modui_host_menu_shell_observation_ready = runtime.modui_host_menu_control_ready
            and dd.ModUI ~= nil and dd.ModUI.Capabilities ~= nil
            and dd.ModUI.Capabilities.hostMenuShellObservation == true
            and type(modui_host_registry.SetMenuShell) == "function"
            and type(modui_host_registry.ReadMenuShellState) == "function"
            and shell_host_epoch == tostring(ack.hostEpoch or "")
            and (shell_state == "none"
                or (shell_consumer == tostring(ack.consumer or "")
                    and shell_slot == math.floor(tonumber(ack.slot) or -1)
                    and shell_revision == math.max(0, math.floor(tonumber(ack.revision) or 0))))
        local visible_shell_state = tostring(host_metadata.visibleShellHostState or "unavailable")
        runtime.modui_host_visible_shell_state = visible_shell_state
        runtime.modui_host_visible_shell_consumer = tostring(host_metadata.visibleShellHostConsumer or "")
        runtime.modui_host_visible_shell_address = tostring(host_metadata.visibleShellHostAddress or "")
        runtime.modui_host_visible_shell_active = visible_shell_state == "active"
            and runtime.modui_host_visible_shell_consumer == tostring(ack.consumer or "")
        runtime.modui_host_visible_shell_ready = runtime.modui_host_menu_control_ready
            and dd.ModUI ~= nil and dd.ModUI.Capabilities ~= nil
            and dd.ModUI.Capabilities.hostVisibleShell == true
            and dd.ModUI.Capabilities.hostVisibleShellSingleOwner == true
            and dd.ModUI.Capabilities.hostMenuPresentation == true
            and type(modui_host_registry.SetMenuPresentation) == "function"
            and (visible_shell_state == "ready" or visible_shell_state == "active")
            and tostring(host_metadata.epoch or "") == tostring(ack.hostEpoch or "")
        diag("dependency.moduiMenuHost", {
            module = "MortalShell2ModUI.Host.MenuService",
            state = tostring(host_metadata.menuState or ""),
            providerCount = tonumber(host_metadata.menuProviderCount) or 0,
            provider = tostring(host_metadata.menuProviderConsumer or ""),
            providerSlot = menu_provider_slot,
            providerRevision = menu_provider_revision,
            providerDisplay = tostring(host_metadata.menuProviderDisplay or ""),
            pages = tostring(host_metadata.menuProviderPages or ""),
            actions = tostring(host_metadata.menuProviderActions or ""),
            hostEpoch = tostring(host_metadata.menuHostEpoch or ""),
            providerMatch = runtime.modui_host_menu_control_ready,
            sessionObservation = runtime.modui_host_menu_session_observation_ready,
            sessionTransitionRing = runtime.modui_host_menu_session_transition_ring_ready,
            sessionState = session_state,
            sessionGeneration = tonumber(host_metadata.menuSessionGeneration) or 0,
            sessionSequence = tonumber(host_metadata.menuSessionSequence) or 0,
            leaseState = lease_state,
            leaseGeneration = tonumber(host_metadata.menuLeaseGeneration) or 0,
            leaseSequence = tonumber(host_metadata.menuLeaseSequence) or 0,
            leaseArbitration = runtime.modui_host_menu_lease_ready,
            leaseAuthority = runtime.modui_host_menu_lease_authority_ready,
            shellObservation = runtime.modui_host_menu_shell_observation_ready,
            shellState = shell_state,
            shellGeneration = tonumber(host_metadata.menuShellGeneration) or 0,
            shellSequence = tonumber(host_metadata.menuShellSequence) or 0,
            shellAddress = tostring(host_metadata.menuShellAddress or ""),
            shellReused = host_metadata.menuShellReused == true,
            shellCacheToken = tonumber(host_metadata.menuShellCacheToken) or 0,
            visibleShellHost = runtime.modui_host_visible_shell_ready,
            visibleShellState = visible_shell_state,
            visibleShellConsumer = runtime.modui_host_visible_shell_consumer,
            visibleShellAddress = runtime.modui_host_visible_shell_address,
            presentationProvider = type(modui_host_registry.SetMenuPresentation) == "function",
            observationOnly = false,
            status = runtime.modui_host_menu_control_ready and "ready-provider-match" or "pending-core-continues",
        })
        diag("dependency.moduiHostAck", {
            module = "MortalShell2ModUI.Host.Service",
            consumer = ack.consumer,
            slot = ack.slot,
            revision = ack.revision,
            hostEpoch = ack.hostEpoch,
            attempt = attempt,
            boundedDiscovery = true,
            physicalHotkeyHost = modui_host_hotkey_ready,
            physicalHotkeyConsumerIsolation = PASS134_CONSUMER_OPEN_HOTKEY_ISOLATION,
            physicalRightStickYHost = modui_host_right_y_ready,
            physicalControllerAnalogHost = modui_host_controller_analog_ready,
            physicalControllerCaptureHost = runtime.modui_host_controller_capture_ready,
            physicalKeyboardCaptureHost = runtime.modui_host_keyboard_capture_ready,
            physicalKeyboardNavigationHost = runtime.modui_host_keyboard_navigation_ready,
            physicalNativeInputHookHost = runtime.modui_host_native_input_hook_ready,
            physicalNativeListenerShadowHost = runtime.modui_host_native_listener_shadow_ready,
            physicalNativeListenerHost = runtime.modui_host_native_listener_primary_ready,
            menuControlHost = runtime.modui_host_menu_control_ready,
            menuSessionObservationHost = runtime.modui_host_menu_session_observation_ready,
            menuSessionTransitionRingHost = runtime.modui_host_menu_session_transition_ring_ready,
            menuSessionLeaseHost = runtime.modui_host_menu_lease_ready,
            menuLeaseArbitrationHost = runtime.modui_host_menu_lease_ready,
            menuLeaseAuthorityHost = runtime.modui_host_menu_lease_authority_ready,
            menuShellObservationHost = runtime.modui_host_menu_shell_observation_ready,
            visibleShellHost = runtime.modui_host_visible_shell_ready,
            visibleShellActive = runtime.modui_host_visible_shell_active,
            singlePhysicalHost = runtime.modui_host_native_listener_primary_ready,
            status = "acknowledged",
        })
        if ui.open and not ui.closing and type(dd.write_modui_host_native_input_request) == "function" then
            -- Pass 153: checkpoint-3 host-owned listener continuity is independent of the
            -- rejected process-wide callback mirror. Reassert the host listener request after
            -- any bounded provider-revision acknowledgement even when external hook hosting is
            -- intentionally disabled. The consumer-listener mirror still requires its historical
            -- process-hook/external-host conditions.
            if ui.native_host_listener_primary == true and runtime.modui_host_native_listener_primary_ready then
                pcall(dd.write_modui_host_native_input_request, true, host_protocol.HOST_NATIVE_LISTENER_TOKEN, ui.active_generation)
            elseif runtime.modui_host_native_input_hook_ready and ui.native_bridge_external_hook == true
                and valid(ui.native_listener) then
                pcall(dd.write_modui_host_native_input_request, true, ui.native_listener, ui.active_generation)
            end
        end
        return
    end
    if final_attempt then
        diag("dependency.moduiHostAck", {
            module = "MortalShell2ModUI.Host.Service",
            consumer = modui_host_registration.consumer,
            slot = modui_host_registration.slot,
            revision = modui_host_registration.revision,
            attempt = attempt,
            boundedDiscovery = true,
            singlePhysicalHost = false,
            error = tostring(ack_error),
            status = "pending-core-continues",
        })
    end
end

-- create_settings_ui is declared earlier in the composition root. Publish the
-- acknowledgement refresh through dd so runtime opens can invoke it without a
-- forward local (and without consuming another main-chunk local slot).
dd.probe_modui_host_ack = probe_modui_host_ack

if modui_host_registration_ready then
    local ack_delays = { 500, 1500, 3500, 5500 }
    for attempt, delay_ms in ipairs(ack_delays) do
        local final_attempt = attempt == #ack_delays
        local game_callback = function()
            probe_modui_host_ack(attempt, final_attempt)
        end
        local async_callback = function()
            dispatch_game_thread(game_callback, "modui-host-ack-" .. tostring(attempt))
        end
        schedule_one_shot_game_thread(delay_ms, game_callback, async_callback, "modui-host-ack-" .. tostring(attempt))
    end
end

local function read_modui_host_event()
    if not (modui_host_acknowledged and modui_host_hotkey_ready)
        or type(modui_host_registry) ~= "table"
        or type(modui_host_registry.ReadEvent) ~= "function"
        or type(modui_host_registration) ~= "table"
        or type(runtime.modui_host_ack) ~= "table" then
        return nil, false
    end
    local event = modui_host_registry.ReadEvent(
        modui_host_registration.slot,
        modui_host_registration.consumer,
        modui_host_registration.revision,
        runtime.modui_host_ack.hostEpoch,
        modui_host_event_sequence
    )
    if type(event) == "table" then
        modui_host_event_sequence = math.max(modui_host_event_sequence, tonumber(event.sequence) or 0)
        return event, true
    end
    return nil, true
end


dd.read_modui_host_navigation_events = function()
    if not (modui_host_acknowledged and runtime.modui_host_keyboard_navigation_ready)
        or type(modui_host_registry) ~= "table"
        or type(modui_host_registry.ReadNavigationEvents) ~= "function"
        or type(modui_host_registration) ~= "table"
        or type(runtime.modui_host_ack) ~= "table" then
        return nil, false
    end
    local batch = modui_host_registry.ReadNavigationEvents(
        modui_host_registration.slot,
        modui_host_registration.consumer,
        modui_host_registration.revision,
        runtime.modui_host_ack.hostEpoch,
        runtime.modui_host_navigation_sequence
    )
    if type(batch) == "table" then
        runtime.modui_host_navigation_sequence = math.max(
            tonumber(runtime.modui_host_navigation_sequence) or 0,
            tonumber(batch.sequence) or 0)
        return batch, true
    end
    return nil, true
end

function dd.write_modui_host_native_input_request(active, listener, generation)
    local state = runtime.modui_host_native_input_state
    if type(state) ~= "table" then
        state = { request_sequence = 0, event_sequence = 0, active = false, generation = 0, host_epoch = "" }
        runtime.modui_host_native_input_state = state
    end
    local can_write = modui_host_acknowledged
        and (runtime.modui_host_native_input_hook_ready or runtime.modui_host_native_listener_primary_ready)
        and type(modui_host_registry) == "table"
        and type(modui_host_registry.SetNativeInputRequest) == "function"
        and type(modui_host_registration) == "table"
        and type(runtime.modui_host_ack) == "table"
    state.request_sequence = (tonumber(state.request_sequence) or 0) + 1
    local request_sequence = state.request_sequence
    if not can_write then
        if active ~= true then state.active = false end
        diag("input.hostNativeRequest", {
            status = "unavailable", active = active == true, sequence = request_sequence,
            generation = tonumber(generation) or 0,
        })
        return false, "native-input-hook-host-unavailable"
    end
    local request_host_epoch = tostring(runtime.modui_host_ack.hostEpoch or "")
    if tostring(state.host_epoch or "") ~= request_host_epoch then
        state.event_sequence = 0
    end
    local listener_address = ""
    if active == true then
        local host_token = tostring(type(host_protocol) == "table" and host_protocol.HOST_NATIVE_LISTENER_TOKEN or "host")
        if type(listener) == "string" and tostring(listener) == host_token then
            listener_address = host_token
        else
            listener = unwrap(listener)
            local address = valid(listener) and tonumber(dd.native_ui_runtime.ObjectAddress(listener)) or nil
            if address == nil then
                state.active = false
                diag("input.hostNativeRequest", { status = "failed", active = true, sequence = request_sequence, error = "listener-address-unavailable" })
                return false, "listener-address-unavailable"
            end
            listener_address = string.format("%.0f", address)
        end
    end
    local request_generation = active == true and (tonumber(generation) or tonumber(ui.active_generation) or 0) or (tonumber(state.generation) or 0)
    local call_ok, set_ok, set_result = pcall(
        modui_host_registry.SetNativeInputRequest,
        modui_host_registration.slot,
        modui_host_registration.consumer,
        request_host_epoch,
        modui_host_registration.revision,
        request_sequence,
        active == true,
        listener_address,
        request_generation
    )
    if not call_ok or set_ok ~= true then
        state.active = false
        diag("input.hostNativeRequest", {
            status = "failed", active = active == true, sequence = request_sequence,
            generation = request_generation, address = listener_address,
            error = tostring(call_ok and set_result or set_ok),
        })
        return false, tostring(call_ok and set_result or set_ok)
    end
    state.active = active == true
    state.generation = request_generation
    state.host_epoch = request_host_epoch
    diag("input.hostNativeRequest", {
        status = active == true and "requested" or "released",
        active = active == true, sequence = request_sequence, generation = request_generation,
        address = listener_address ~= "" and listener_address or nil,
        listenerMode = listener_address == tostring(type(host_protocol) == "table" and host_protocol.HOST_NATIVE_LISTENER_TOKEN or "host") and "host-owned" or "consumer",
        revision = modui_host_registration.revision,
    })
    return true, active == true and "requested" or "released"
end


-- Pass 161 promotes the bounded per-session class hook into standalone ModUI while keeping
-- the rejected process-wide callback mirror hard-isolated. These legacy local-hook helpers are
-- retained only for the complete consumer InputBridge fallback; the healthy host-primary path
-- never calls them. Cross-state ownership remains primitive-address/event-ring only.
function dd.read_modui_host_native_listener_address()
    if type(modui_host_registry) ~= "table" or type(modui_host_registry.HostMetadata) ~= "function" then
        return ""
    end
    local metadata = modui_host_registry.HostMetadata()
    if type(metadata) ~= "table" or tostring(metadata.physicalNativeListenerState or "") ~= "active" then
        return ""
    end
    local address = tostring(metadata.physicalNativeListenerAddress or "")
    return address:match("^%d+$") and address or ""
end

function dd.arm_host_primary_local_hook(generation)
    local native_runtime, callback = dd.ensure_native_input_hook_runtime()
    local result = dd.ModUI.Runtime.Hook.Register(
        native_runtime, dd.NativeInputTriggerFunction, callback, RegisterHook, dd.NativeInputHookFields)
    result = type(result) == "table" and result or { ok = false, status = "invalid-result" }
    diag("input.hostPrimaryLocalHook", {
        status = result.status, generation = tonumber(generation) or 0, ok = result.ok == true,
        cycle = tonumber(result.cycle) or 0, processWideHook = false, localSessionHook = true,
    })
    return result.ok == true, tostring(result.status or "unknown")
end

function dd.retire_host_primary_local_hook(reason)
    local native_runtime = _G.MortalShell2TTSRuntime
    local result = dd.ModUI.Runtime.Hook.Unregister(
        native_runtime, dd.NativeInputTriggerFunction, UnregisterHook, dd.NativeInputHookFields)
    result = type(result) == "table" and result or { ok = false, status = "invalid-result" }
    diag("input.hostPrimaryLocalHook", {
        status = result.status, reason = tostring(reason or "host-primary-release"), ok = result.ok == true,
        cycle = tonumber(result.cycle) or 0, processWideHook = false, localSessionHook = true,
    })
    return result.ok == true, tostring(result.status or "unknown")
end

-- Pass 125 promotes the Pass-124-proven standalone listener from shadow observation to
-- the primary physical native listener. The host request uses an explicit primitive token;
-- no consumer WBP_InputListener is constructed on the healthy path. A bounded delayed check
-- retains the complete Pass-124 consumer bridge as a fail-soft fallback if host construction
-- does not become active in the current Settings generation.
function dd.start_modui_host_native_listener_primary(player, controller, library, handler, generation)
    generation = tonumber(generation) or tonumber(ui.active_generation) or 0
    if generation <= 0 or not ui.open or ui.closing then return false, "session-inactive" end
    if not (modui_host_acknowledged and runtime.modui_host_native_listener_primary_ready
        and dd.ModUI ~= nil and dd.ModUI.Capabilities ~= nil
        and dd.ModUI.Capabilities.hostSessionNativeInputHook == true
        and type(host_protocol) == "table"
        and tostring(host_protocol.HOST_NATIVE_LISTENER_TOKEN or "") ~= ""
        and type(modui_host_registry) == "table"
        and type(modui_host_registry.HostMetadata) == "function") then
        return false, "host-native-listener-primary-unavailable"
    end

    -- Pass 161: healthy-path semantic callback ownership is now standalone ModUI. Do not
    -- register a TTS-local class hook here. The old local hook functions remain available only
    -- to the complete consumer InputBridge fallback below.
    local requested, request_status = dd.write_modui_host_native_input_request(
        true, host_protocol.HOST_NATIVE_LISTENER_TOKEN, generation)
    if requested ~= true then return false, tostring(request_status or "request-failed") end

    runtime.modui_host_native_input_hook_ready = false
    ui.native_host_listener_primary = true
    ui.native_host_listener_address = ""
    ui.native_host_listener_fallback_scheduled = true
    ui.native_listener = nil
    ui.native_input_bridge = nil
    ui.native_bridge_lease = nil
    ui.native_bridge_session = nil
    ui.native_bridge_activation = nil
    ui.native_listener_enabled = true
    ui.mouse_input_ready = true
    ui.native_route_by_enum = {}
    ui.native_route_by_action = {}
    ui.native_action_name_by_enum = {}
    ui.native_verified_accepted_inputs = {}

    diag("input.bridge.begin", {
        status = "host-primary-semantic-requested", generation = generation,
        sharedHost = true, sharedConstruction = true, singlePhysicalHost = true,
        processWideHook = false, hostSessionHook = true, localSessionHook = false,
    })

    local delays = { 100, 300, 750 }
    for attempt, delay_ms in ipairs(delays) do
        local final_attempt = attempt == #delays
        local check = function()
            if ui.native_host_listener_primary ~= true
                or ui.native_host_listener_fallback_scheduled ~= true
                or not ui.open or ui.closing
                or tonumber(ui.active_generation) ~= generation then
                return
            end
            local metadata = modui_host_registry.HostMetadata()
            local listener_state = type(metadata) == "table" and tostring(metadata.physicalNativeListenerState or "") or ""
            local listener_address = type(metadata) == "table" and tostring(metadata.physicalNativeListenerAddress or "") or ""
            local hook_state = type(metadata) == "table" and tostring(metadata.physicalNativeInputHookState or "") or ""
            local host_epoch_match = type(metadata) == "table" and type(runtime.modui_host_ack) == "table"
                and tostring(metadata.epoch or "") == tostring(runtime.modui_host_ack.hostEpoch or "")
            if listener_state == "active" and listener_address:match("^%d+$")
                and hook_state == "session-ready" and host_epoch_match then
                runtime.modui_host_native_input_hook_ready = true
                ui.native_host_listener_address = listener_address
                ui.native_host_listener_fallback_scheduled = false
                diag("input.hostNativeListenerPrimary", {
                    status = "active-host-semantic", generation = generation, attempt = attempt, delayMs = delay_ms,
                    address = listener_address, hookState = hook_state, singlePhysicalHost = true,
                    processWideHook = false, hostSessionHook = true, localSessionHook = false,
                })
                diag("input.hookRestoration", {
                    status = "host-session-hook", generation = generation, processWideHook = false,
                    hostSessionHook = true, localSessionHook = false,
                })
                return
            end
            if not final_attempt then
                diag("input.hostNativeListenerPrimary", {
                    status = "pending-host-semantic", generation = generation, attempt = attempt, delayMs = delay_ms,
                    hostState = listener_state, hookState = hook_state,
                    hostAddress = listener_address ~= "" and listener_address or nil,
                })
                return
            end

            ui.native_host_listener_fallback_scheduled = false
            pcall(dd.write_modui_host_native_input_request, false, nil, generation)
            runtime.modui_host_native_input_hook_ready = false
            ui.native_host_listener_primary = false
            ui.native_host_listener_address = ""
            ui.native_listener_enabled = false
            local fallback_ok = create_native_input_bridge(player, controller, library, handler)
            diag("input.hostNativeListenerPrimary", {
                status = fallback_ok and "consumer-fallback-active" or "consumer-fallback-failed",
                generation = generation, attempt = attempt, delayMs = delay_ms,
                hostState = listener_state, hookState = hook_state, singlePhysicalHost = false,
            })
            if fallback_ok then
                ui.status = "Ready - native semantic host fallback active."
            else
                ui.status = "Keyboard only - standalone native semantic host unavailable."
            end
            if type(set_ui_text) == "function" then pcall(set_ui_text) end
        end
        local async_check = function()
            dispatch_game_thread(check, "host-native-semantic-primary-check-" .. tostring(attempt))
        end
        schedule_one_shot_game_thread(delay_ms, check, async_check,
            "host-native-semantic-primary-check-" .. tostring(attempt))
    end

    diag("input.bridge.end", {
        status = "host-primary-semantic-requested", generation = generation,
        sharedHost = true, sharedConstruction = true, singlePhysicalHost = true,
        processWideHook = false, hostSessionHook = true, localSessionHook = false,
    })
    return true, "host-primary-semantic-requested"
end

function dd.read_modui_host_native_input_events()
    local state = runtime.modui_host_native_input_state
    if type(state) ~= "table" or state.active ~= true then return nil, true end
    if not modui_host_acknowledged
        or type(modui_host_registry) ~= "table"
        or type(modui_host_registry.ReadNativeInputEvents) ~= "function"
        or type(modui_host_registry.HostMetadata) ~= "function"
        or type(modui_host_registration) ~= "table"
        or type(runtime.modui_host_ack) ~= "table" then
        return nil, false
    end
    local metadata = modui_host_registry.HostMetadata()
    runtime.modui_host_native_input_hook_ready = type(metadata) == "table"
        and tostring(metadata.physicalNativeInputHookState or "") == "session-ready"
        and tostring(metadata.epoch or "") == tostring(runtime.modui_host_ack.hostEpoch or "")
        and tostring(metadata.physicalNativeListenerState or "") == "active"
    if runtime.modui_host_native_input_hook_ready ~= true then return nil, false end
    local batch = modui_host_registry.ReadNativeInputEvents(
        modui_host_registration.slot,
        modui_host_registration.consumer,
        modui_host_registration.revision,
        runtime.modui_host_ack.hostEpoch,
        state.request_sequence,
        state.event_sequence
    )
    if type(batch) == "table" then
        state.event_sequence = math.max(tonumber(state.event_sequence) or 0, tonumber(batch.sequence) or 0)
        return batch, true
    end
    return nil, true
end

read_modui_host_axis = function(axis_key)
    axis_key = tostring(axis_key or "")
    if axis_key == "" then return nil, nil, false end
    -- Pass 149: retain Pass-148 producer authority without adding a main-chunk local.
    local capture_kind = tostring(type(runtime.modui_host_capture_state) == "table"
        and runtime.modui_host_capture_state.kind or "")
    local native_state = type(runtime.modui_host_native_input_state) == "table"
        and runtime.modui_host_native_input_state or nil
    local producer_active = ((capture_kind == "controller" or capture_kind == "controller-sampling") and runtime.modui_host_controller_capture_ready == true)
        or (runtime.modui_host_native_input_hook_ready == true
            and type(native_state) == "table" and native_state.active == true)
    if not producer_active then return nil, nil, false end
    if not (modui_host_acknowledged and modui_host_controller_analog_ready)
        or type(modui_host_registry) ~= "table"
        or type(modui_host_registry.ReadAxisSample) ~= "function"
        or type(modui_host_registration) ~= "table"
        or type(runtime.modui_host_ack) ~= "table" then
        return nil, nil, false
    end
    local last_sequence = tonumber(modui_host_axis_sequences[axis_key]) or 0
    local sample = modui_host_registry.ReadAxisSample(
        modui_host_registration.slot,
        modui_host_registration.consumer,
        modui_host_registration.revision,
        runtime.modui_host_ack.hostEpoch,
        axis_key,
        last_sequence
    )
    if type(sample) == "table" then
        local sequence = math.max(last_sequence, tonumber(sample.sequence) or 0)
        modui_host_axis_sequences[axis_key] = sequence
        modui_host_axis_values[axis_key] = tonumber(sample.value)
        modui_host_axis_sources[axis_key] = tostring(sample.source or axis_key)
        modui_host_axis_frames[axis_key] = math.max(0, math.floor(tonumber(sample.frame) or 0))
        runtime.modui_host_axis_sequences = modui_host_axis_sequences
        runtime.modui_host_axis_frames = modui_host_axis_frames
        return modui_host_axis_values[axis_key], modui_host_axis_sources[axis_key], true, modui_host_axis_frames[axis_key]
    end
    if tonumber(modui_host_axis_values[axis_key]) ~= nil then
        return modui_host_axis_values[axis_key], modui_host_axis_sources[axis_key], true, modui_host_axis_frames[axis_key]
    end
    return nil, nil, true
end

function dd.read_modui_host_key(key_name)
    key_name = tostring(key_name or "")
    if key_name == "" then return nil, nil, false end
    local requested_kind = tostring(runtime.modui_host_capture_state.kind or "")
    local capture_ready = requested_kind == "keyboard" and runtime.modui_host_keyboard_capture_ready
        or (requested_kind == "controller" or requested_kind == "controller-sampling") and runtime.modui_host_controller_capture_ready
    if not (modui_host_acknowledged and capture_ready)
        or type(modui_host_registry) ~= "table"
        or type(modui_host_registry.ReadKeySample) ~= "function"
        or type(modui_host_registration) ~= "table"
        or type(runtime.modui_host_ack) ~= "table" then
        return nil, nil, false
    end
    local last_sequence = tonumber(runtime.modui_host_capture_state.key_sequences[key_name]) or 0
    local last_press_sequence = tonumber(runtime.modui_host_capture_state.key_press_sequences[key_name]) or 0
    local sample = modui_host_registry.ReadKeySample(
        modui_host_registration.slot,
        modui_host_registration.consumer,
        modui_host_registration.revision,
        runtime.modui_host_ack.hostEpoch,
        runtime.modui_host_capture_state.request_sequence,
        key_name,
        last_sequence
    )
    if type(sample) == "table" then
        local sequence = math.max(last_sequence, tonumber(sample.sequence) or 0)
        runtime.modui_host_capture_state.key_sequences[key_name] = sequence
        runtime.modui_host_capture_state.key_values[key_name] = sample.down == true
        runtime.modui_host_capture_state.key_sources[key_name] = tostring(sample.source or key_name)
        local press_sequence = math.max(0, math.floor(tonumber(sample.pressSequence) or 0))
        local press_delta = math.max(0, press_sequence - last_press_sequence)
        runtime.modui_host_capture_state.key_press_sequences[key_name] = press_sequence
        return runtime.modui_host_capture_state.key_values[key_name], runtime.modui_host_capture_state.key_sources[key_name], true, press_delta
    end
    if runtime.modui_host_capture_state.key_values[key_name] ~= nil then
        return runtime.modui_host_capture_state.key_values[key_name], runtime.modui_host_capture_state.key_sources[key_name], true, 0
    end
    return nil, nil, true, 0
end

function dd.write_modui_host_capture_request(kind, active)
    kind = tostring(kind or "")
    if kind ~= "controller" and kind ~= "controller-sampling" and kind ~= "keyboard" then return false, "unsupported-capture-kind" end
    local capture_ready = kind == "keyboard" and runtime.modui_host_keyboard_capture_ready
        or (kind == "controller" or kind == "controller-sampling") and runtime.modui_host_controller_capture_ready
    if not (modui_host_acknowledged and capture_ready)
        or type(modui_host_registry) ~= "table"
        or type(modui_host_registry.SetCaptureRequest) ~= "function"
        or type(modui_host_registration) ~= "table"
        or type(runtime.modui_host_ack) ~= "table" then
        return false, tostring(kind) .. "-capture-host-unavailable"
    end
    runtime.modui_host_capture_state.request_sequence = runtime.modui_host_capture_state.request_sequence + 1
    local request_kind = active == true and kind or "off"
    local call_ok, set_ok, set_result = pcall(
        modui_host_registry.SetCaptureRequest,
        modui_host_registration.slot,
        modui_host_registration.consumer,
        runtime.modui_host_ack.hostEpoch,
        modui_host_registration.revision,
        runtime.modui_host_capture_state.request_sequence,
        request_kind,
        active == true
    )
    if not call_ok or set_ok ~= true then
        return false, tostring(call_ok and set_result or set_ok)
    end
    runtime.modui_host_capture_state.kind = active == true and kind or nil
    if active ~= true then
        runtime.modui_host_capture_state.key_sequences = {}
        runtime.modui_host_capture_state.key_values = {}
        runtime.modui_host_capture_state.key_sources = {}
        runtime.modui_host_capture_state.key_press_sequences = {}
        -- Pass 148: host axis publication is capture/request scoped. Do not let the last
        -- capture sample (commonly neutral RightY) remain authoritative after that producer
        -- shuts off; the ordinary browser/details path must immediately use local analog.
        modui_host_axis_sequences = {}
        modui_host_axis_values = {}
        modui_host_axis_sources = {}
        modui_host_axis_frames = {}
        runtime.modui_host_axis_sequences = modui_host_axis_sequences
        runtime.modui_host_axis_frames = modui_host_axis_frames
    else
        runtime.modui_host_capture_state.key_sequences = {}
        runtime.modui_host_capture_state.key_values = {}
        runtime.modui_host_capture_state.key_sources = {}
        runtime.modui_host_capture_state.key_press_sequences = {}
    end
    return true, request_kind
end

read_modui_host_right_y = function()
    if not modui_host_right_y_ready then return nil, nil, false end
    return read_modui_host_axis("Gamepad_RightY")
end

local function republish_modui_host_binding(kind, serialized)
    -- Pass 153: a host-owned physical listener must survive descriptor revision changes.
    -- Pass 130's unconditional pre-release is still correct for consumer-owned native-input
    -- mirroring, but releasing HOST_NATIVE_LISTENER_TOKEN destroys the only physical listener.
    -- Snapshot that ownership before Publish so the same request can move transactionally onto
    -- the new revision without exposing a no-active-native-requests gap.
    local preserve_host_primary_request = ui.native_host_listener_primary == true
        and ui.open and not ui.closing
        and runtime.modui_host_native_input_state.active == true
    if not preserve_host_primary_request
        and runtime.modui_host_native_input_state.active == true
        and type(dd.write_modui_host_native_input_request) == "function" then
        local release_ok, release_result = pcall(dd.write_modui_host_native_input_request, false, nil, ui.active_generation)
        diag("dependency.moduiMenuLeaseAuthority", {
            stage = "pre-republish-native-release", kind = tostring(kind or "binding"),
            status = release_ok and release_result ~= false and "released" or "release-failed-failsoft",
        })
    elseif preserve_host_primary_request then
        diag("dependency.moduiMenuLeaseAuthority", {
            stage = "pre-republish-native-release", kind = tostring(kind or "binding"),
            status = "host-primary-preserved",
        })
    end
    if type(modui_host_registry) ~= "table" or type(modui_host_registry.Publish) ~= "function" then
        modui_host_hotkey_ready = false
        modui_host_right_y_ready = false
        modui_host_controller_analog_ready = false
        runtime.modui_host_hotkey_ready = false
        runtime.modui_host_right_y_ready = false
        runtime.modui_host_controller_analog_ready = false
        runtime.modui_host_controller_capture_ready = false
        runtime.modui_host_keyboard_capture_ready = false
        runtime.modui_host_keyboard_navigation_ready = false
        runtime.modui_host_native_input_hook_ready = false
        runtime.modui_host_native_listener_shadow_ready = false
        runtime.modui_host_native_listener_primary_ready = false
        runtime.modui_host_menu_control_ready = false
        runtime.modui_host_menu_lease_ready = false
        runtime.modui_host_menu_lease_authority_ready = false
        runtime.modui_host_menu_shell_observation_ready = false
        runtime.modui_host_visible_shell_ready = false
        runtime.modui_host_visible_shell_active = false
        runtime.modui_host_visible_shell_state = "unavailable"
        runtime.modui_host_native_input_state.active = false
        diag("dependency.moduiHostRegistry", {
            status = "republish-unavailable-consumer-fallback",
            kind = kind,
            value = serialized,
            error = "registry unavailable",
        })
        return false
    end
    local publish_ok, published, publish_error = pcall(function()
        return modui_host_registry.Publish({
            consumer_id = "MortalShell2TTS", display_name = "MortalShell2TTS", version = VERSION,
            settings_provider = true, visible_shell = true, presentation_provider = true, menu_order = 100,
            hotkey_provider = not PASS134_CONSUMER_OPEN_HOTKEY_ISOLATION
                    and runtime.modui_host_hotkey_transition_quarantined ~= true,
            open_keyboard = config.menu_keybind, open_controller = config.controller_menu_bind,
            modifier_sides_equivalent = config.modifier_sides_equivalent == true,
            keyboard_navigation = true,
            native_input = true,
            actions = "open-settings", pages = "MOD,SPEECH,ENGINE",
        })
    end)
    if not publish_ok or type(published) ~= "table" then
        diag("dependency.moduiHostRegistry", {
            status = "republish-failed-consumer-fallback",
            kind = kind,
            value = serialized,
            error = tostring(publish_ok and publish_error or published),
        })
        modui_host_hotkey_ready = false
        modui_host_right_y_ready = false
        modui_host_controller_analog_ready = false
        runtime.modui_host_hotkey_ready = false
        runtime.modui_host_right_y_ready = false
        runtime.modui_host_controller_analog_ready = false
        runtime.modui_host_controller_capture_ready = false
        runtime.modui_host_keyboard_capture_ready = false
        runtime.modui_host_keyboard_navigation_ready = false
        runtime.modui_host_native_input_hook_ready = false
        runtime.modui_host_native_listener_shadow_ready = false
        runtime.modui_host_native_listener_primary_ready = false
        runtime.modui_host_menu_control_ready = false
        runtime.modui_host_menu_lease_ready = false
        runtime.modui_host_menu_lease_authority_ready = false
        runtime.modui_host_menu_shell_observation_ready = false
        runtime.modui_host_visible_shell_ready = false
        runtime.modui_host_visible_shell_active = false
        runtime.modui_host_visible_shell_state = "unavailable"
        runtime.modui_host_native_input_state.active = false
        return false
    end
    modui_host_registration = published
    runtime.modui_host_registration = published
    dd.modui_host_registration = published
    dd.modui_host_registration_ready = true
    if type(dd.publish_modui_host_menu_session) == "function" then
        pcall(dd.publish_modui_host_menu_session,
            tostring(runtime.modui_host_menu_session_state or "closed"),
            tonumber(runtime.modui_host_menu_session_generation) or 0,
            "revision-republish:" .. tostring(kind or "binding"))
    end
    if type(dd.publish_modui_host_menu_lease) == "function" then
        pcall(dd.publish_modui_host_menu_lease,
            runtime.modui_host_menu_lease_active == true,
            tonumber(runtime.modui_host_menu_lease_generation) or 0,
            "revision-republish:" .. tostring(kind or "binding"))
    end
    if type(dd.publish_modui_host_menu_shell) == "function" then
        pcall(dd.publish_modui_host_menu_shell,
            tostring(runtime.modui_host_menu_shell_state or "none"),
            tonumber(runtime.modui_host_menu_shell_generation) or 0,
            tostring(runtime.modui_host_menu_shell_address or ""),
            runtime.modui_host_menu_shell_reused == true,
            tonumber(runtime.modui_host_menu_shell_cache_token) or 0,
            "revision-republish:" .. tostring(kind or "binding"))
    end
    if ui.open and ui.host_visible_shell == true and type(dd.publish_modui_host_menu_presentation) == "function" then
        pcall(dd.publish_modui_host_menu_presentation)
    end
    -- Pass 153: provider revision changes invalidate revision-bound native-input requests.
    -- Preserve the active host-owned physical listener transactionally by republishing its
    -- HOST_NATIVE_LISTENER_TOKEN request under the new revision while the current host epoch
    -- is still acknowledged. Pass 152 omitted this step, so ModUI retired the only physical
    -- listener as no-active-native-requests immediately after every binding commit.
    if preserve_host_primary_request
        and runtime.modui_host_native_listener_primary_ready == true
        and type(dd.write_modui_host_native_input_request) == "function"
        and type(host_protocol) == "table" then
        local continuity_call_ok, continuity_ok, continuity_status = pcall(
            dd.write_modui_host_native_input_request,
            true, host_protocol.HOST_NATIVE_LISTENER_TOKEN, ui.active_generation)
        diag("input.hostNativeRevisionContinuity", {
            status = continuity_call_ok and continuity_ok == true and "republished" or "republish-failed",
            kind = tostring(kind or "binding"),
            generation = tonumber(ui.active_generation) or 0,
            revision = tonumber(published.revision) or 0,
            detail = tostring(continuity_call_ok and continuity_status or continuity_ok),
        })
    end
    modui_host_acknowledged = false
    modui_host_hotkey_ready = false
    modui_host_right_y_ready = false
    modui_host_controller_analog_ready = false
    runtime.modui_host_acknowledged = false
    runtime.modui_host_hotkey_ready = false
    runtime.modui_host_right_y_ready = false
    runtime.modui_host_controller_analog_ready = false
    runtime.modui_host_controller_capture_ready = false
    runtime.modui_host_keyboard_capture_ready = false
    runtime.modui_host_keyboard_navigation_ready = false
    runtime.modui_host_native_input_hook_ready = false
    runtime.modui_host_native_listener_shadow_ready = false
    runtime.modui_host_native_listener_primary_ready = false
    runtime.modui_host_menu_control_ready = false
    runtime.modui_host_menu_lease_ready = false
    runtime.modui_host_menu_lease_authority_ready = false
    runtime.modui_host_menu_shell_observation_ready = false
    runtime.modui_host_visible_shell_ready = false
    runtime.modui_host_visible_shell_active = false
    runtime.modui_host_visible_shell_state = "unavailable"
    runtime.modui_host_native_input_state.active = false
    runtime.modui_host_ack = nil
    modui_host_event_sequence = 0
    modui_host_axis_sequences = {}
    modui_host_axis_values = {}
    modui_host_axis_sources = {}
    modui_host_axis_frames = {}
    runtime.modui_host_capture_state.key_sequences = {}
    runtime.modui_host_capture_state.key_values = {}
    runtime.modui_host_capture_state.key_sources = {}
    runtime.modui_host_capture_state.key_press_sequences = {}
    runtime.modui_host_axis_sequences = modui_host_axis_sequences
    diag("dependency.moduiHostRegistry", {
        status = "republished-binding", kind = kind, value = serialized,
        slot = published.slot, revision = published.revision, registryRevision = published.registryRevision,
        singlePhysicalHost = false,
    })
    -- Reuse the existing bounded acknowledgement path; the standalone physical poll also
    -- watches RegistryRevision and will scan/ack this update without a second watcher.
    local delays = { 100, 350, 800, 1500 }
    for attempt, delay_ms in ipairs(delays) do
        local final_attempt = attempt == #delays
        local game_callback = function() probe_modui_host_ack("binding-" .. tostring(attempt), final_attempt) end
        local async_callback = function() dispatch_game_thread(game_callback, "modui-host-binding-ack-" .. tostring(attempt)) end
        schedule_one_shot_game_thread(delay_ms, game_callback, async_callback, "modui-host-binding-ack-" .. tostring(attempt))
    end
    return true
end
dd.republish_modui_host_binding = republish_modui_host_binding

    dd.read_modui_host_event = read_modui_host_event
    dd.read_modui_host_axis = read_modui_host_axis
    dd.read_modui_host_right_y = read_modui_host_right_y

    return {
        ownership = "tts-modui-host-client",
        consumerOpenHotkeyIsolation = PASS134_CONSUMER_OPEN_HOTKEY_ISOLATION,
        ReadEvent = read_modui_host_event,
        ReadAxis = read_modui_host_axis,
        RepublishBinding = republish_modui_host_binding,
        ProbeAcknowledgement = probe_modui_host_ack,
        RegistrationReady = function() return modui_host_registration_ready end,
        Acknowledged = function() return modui_host_acknowledged end,
        HotkeyReady = function() return modui_host_hotkey_ready end,
        RightYReady = function() return modui_host_right_y_ready end,
        ControllerAnalogReady = function() return modui_host_controller_analog_ready end,
    }
end

return M
