-- MortalShell2TTS UI.SettingsRuntime
-- Pass 170 extraction: owns the complete Settings interaction/runtime composition below the
-- high-level TTS model: native presentation fallback, modal input acquisition/restoration,
-- cross-source navigation dedupe, redraw, native UI observation/admission, pointer routing,
-- gameplay isolation, semantic fallback, native bridge construction, and SettingsSession wiring.
-- The application composition root injects game/application policy and retains only orchestration.

local M = {}

function M.Install(options)
    options = type(options) == "table" and options or {}
    local dd = options.dd
    local ui = options.ui
    local config = options.config
    if type(dd) ~= "table" or type(ui) ~= "table" or type(config) ~= "table" then
        return nil, "dd/ui/config missing"
    end

    local SHELL_REUSE_MS = tonumber(options.shell_reuse_ms) or 12000
    local INPUT_CROSS_SOURCE_DEDUPE_SECONDS = tonumber(options.input_cross_source_dedupe_seconds) or 0.12
    local VERSION = tostring(options.version or "")
    local schedule_close_finalize = options.schedule_close_finalize
    local schedule_shell_cache_expiry = options.schedule_shell_cache_expiry
    local unwrap = options.unwrap
    local valid = options.valid
    local object_name = options.object_name
    local widget_text = options.widget_text
    local scripts_dir = options.scripts_dir
    local runtime_diagnostics = options.runtime_diagnostics
    local log = options.log or function() end
    local diag = options.diag or function() end
    local trim = options.trim
    local clamp = options.clamp
    local save_config = options.save_config
    local tts_command = options.tts_command
    local stop_speech = options.stop_speech
    local engines = options.engines
    local azure_regions = options.azure_regions
    local tabs = options.tabs
    local row_description = options.row_description
    local row_control_hint = options.row_control_hint
    local current_tab = options.current_tab
    local current_rows = options.current_rows
    local active_voice_value = options.active_voice_value
    local refresh_voices = options.refresh_voices
    local refresh_audio_outputs = options.refresh_audio_outputs
    local audio_output_index = options.audio_output_index
    local voice_index = options.voice_index
    local ellipsize_text = options.ellipsize_text
    local row_value = options.row_value
    local settings_tab_text = options.settings_tab_text
    local settings_label_text = options.settings_label_text
    local settings_values_text = options.settings_values_text
    local settings_combined_text = options.settings_combined_text
    local settings_plain_text = options.settings_plain_text
    local read_modui_host_axis = options.read_modui_host_axis

    local required = {
        unwrap = unwrap, valid = valid, object_name = object_name, widget_text = widget_text,
        runtime_diagnostics = runtime_diagnostics, trim = trim, clamp = clamp,
        save_config = save_config, tts_command = tts_command, stop_speech = stop_speech,
        row_description = row_description, row_control_hint = row_control_hint,
        current_tab = current_tab, current_rows = current_rows, active_voice_value = active_voice_value,
        refresh_voices = refresh_voices, refresh_audio_outputs = refresh_audio_outputs,
        audio_output_index = audio_output_index, voice_index = voice_index,
        ellipsize_text = ellipsize_text, row_value = row_value,
        settings_tab_text = settings_tab_text, settings_label_text = settings_label_text,
        settings_values_text = settings_values_text, settings_combined_text = settings_combined_text,
        settings_plain_text = settings_plain_text,
    }
    for name, value in pairs(required) do
        if type(value) ~= "function" and name ~= "runtime_diagnostics" then
            return nil, name .. " missing"
        end
    end
    if type(runtime_diagnostics) ~= "table" then return nil, "runtime_diagnostics missing" end
    if type(scripts_dir) ~= "string" or scripts_dir == "" then return nil, "scripts_dir missing" end
    if type(tabs) ~= "table" or type(engines) ~= "table" or type(azure_regions) ~= "table" then
        return nil, "settings data tables missing"
    end


-- Frozen visual/native constants now live in a data-only TTS UI module. These
-- aliases preserve the exact local names consumed by the proven runtime paths.
local NATIVE_SETTINGS_ASSET = dd.UILayout.assets.settings
local NATIVE_SETTINGS_CLASS = dd.UILayout.assets.settingsClass
local NATIVE_INPUT_LISTENER_ASSET = dd.UILayout.assets.inputListener
local NATIVE_INPUT_LISTENER_CLASS = dd.UILayout.assets.inputListenerClass
local NATIVE_BPFL_UI_ASSET = dd.UILayout.assets.bpflUi
local NATIVE_BPFL_UI_CDO = dd.UILayout.assets.bpflUiCdo
local NATIVE_SETTING_INFO_PANEL_ASSET = dd.UILayout.assets.settingInfoPanel
local NATIVE_SETTING_INFO_PANEL_CLASS = dd.UILayout.assets.settingInfoPanelClass

local SETTINGS_PROMPT_WIDTH = dd.UILayout.widths.prompt
local SETTINGS_LIST_WIDTH = dd.UILayout.widths.list
local SETTINGS_VALUE_WIDTH = dd.UILayout.widths.value
local SETTINGS_FALLBACK_LIST_WIDTH = dd.UILayout.widths.fallbackList
local SETTINGS_INFO_WIDTH = dd.UILayout.widths.info
local SETTINGS_INFO_TEXT_WIDTH = dd.UILayout.widths.infoText
local SETTINGS_LAYOUT = dd.UILayout.settings

local SCALEBOX_STRETCH_USER_SPECIFIED = dd.UILayout.enums.SCALEBOX_STRETCH_USER_SPECIFIED
local WIDGET_CLIP_INHERIT = dd.UILayout.enums.WIDGET_CLIP_INHERIT
local WIDGET_CLIP_TO_BOUNDS = dd.UILayout.enums.WIDGET_CLIP_TO_BOUNDS
local HALIGN_FILL = dd.UILayout.enums.HALIGN_FILL
local HALIGN_LEFT = dd.UILayout.enums.HALIGN_LEFT
local HALIGN_CENTER = dd.UILayout.enums.HALIGN_CENTER
local HALIGN_RIGHT = dd.UILayout.enums.HALIGN_RIGHT
local VALIGN_TOP = dd.UILayout.enums.VALIGN_TOP
local VALIGN_CENTER = dd.UILayout.enums.VALIGN_CENTER

dd.NativePresentationFactory, dd.native_presentation_factory_error = dd.load_lua_table_module(scripts_dir .. "\\UI\\NativePresentation.lua", "UI.NativePresentation")
if dd.NativePresentationFactory == nil or type(dd.NativePresentationFactory.Bind) ~= "function" then
    error("MortalShell2TTS UI.NativePresentation failed to load: " .. tostring(dd.native_presentation_factory_error or "missing API"))
end
dd.native_presentation, dd.native_presentation_error = dd.NativePresentationFactory.Bind({
    dd = dd, ui = ui, config = config, unwrap = unwrap, valid = valid, object_name = object_name,
    log = log, diag = diag, trim = trim, clamp = clamp, tabs = tabs,
    row_description = row_description, row_control_hint = row_control_hint, current_tab = current_tab, current_rows = current_rows,
    ellipsize_text = ellipsize_text, row_value = row_value, settings_tab_text = settings_tab_text,
    settings_label_text = settings_label_text, settings_values_text = settings_values_text,
    read_modui_host_axis = read_modui_host_axis,
    NATIVE_SETTINGS_ASSET = NATIVE_SETTINGS_ASSET, NATIVE_SETTINGS_CLASS = NATIVE_SETTINGS_CLASS,
    NATIVE_INPUT_LISTENER_ASSET = NATIVE_INPUT_LISTENER_ASSET, NATIVE_INPUT_LISTENER_CLASS = NATIVE_INPUT_LISTENER_CLASS,
    NATIVE_SETTING_INFO_PANEL_ASSET = NATIVE_SETTING_INFO_PANEL_ASSET, NATIVE_SETTING_INFO_PANEL_CLASS = NATIVE_SETTING_INFO_PANEL_CLASS,
    SETTINGS_PROMPT_WIDTH = SETTINGS_PROMPT_WIDTH, SETTINGS_LIST_WIDTH = SETTINGS_LIST_WIDTH,
    SETTINGS_VALUE_WIDTH = SETTINGS_VALUE_WIDTH, SETTINGS_FALLBACK_LIST_WIDTH = SETTINGS_FALLBACK_LIST_WIDTH,
    SETTINGS_INFO_WIDTH = SETTINGS_INFO_WIDTH, SETTINGS_INFO_TEXT_WIDTH = SETTINGS_INFO_TEXT_WIDTH, SETTINGS_LAYOUT = SETTINGS_LAYOUT,
    SCALEBOX_STRETCH_USER_SPECIFIED = SCALEBOX_STRETCH_USER_SPECIFIED, HALIGN_FILL = HALIGN_FILL, HALIGN_LEFT = HALIGN_LEFT, VALIGN_TOP = VALIGN_TOP,
})
if type(dd.native_presentation) ~= "table" then
    error("MortalShell2TTS UI.NativePresentation failed: " .. tostring(dd.native_presentation_error or "missing API"))
end
diag("dependency.nativePresentation", { module = "UI.NativePresentation", ownership = "consumer-local-native-presentation-fallback", status = "ready" })

local function acquire_settings_input(controller, library, widget, handler)
    controller = unwrap(controller)
    diag("modalInput.acquire", { stage = "begin" })
    library = unwrap(library)
    widget = unwrap(widget)
    handler = unwrap(handler)
    if not valid(controller) or not valid(library) or not valid(widget) then
        log("modal input unavailable: controller/library/widget was invalid")
        return false
    end
    if not valid(handler) then
        log("modal input unavailable: BPC_UserInterfaceHandler was invalid")
        return false
    end

    local game_and_ui = library["SetInputMode_GameAndUIEx"]
    if game_and_ui == nil then
        log("modal input unavailable: WidgetBlueprintLibrary.SetInputMode_GameAndUIEx was not exposed")
        return false
    end

    ui.saved_show_cursor = dd.ModUI.Runtime.Observation.ControllerPropertyBool(controller, "bShowMouseCursor")
    ui.saved_click_events = dd.ModUI.Runtime.Observation.ControllerPropertyBool(controller, "bEnableClickEvents")
    ui.saved_hover_events = dd.ModUI.Runtime.Observation.ControllerPropertyBool(controller, "bEnableMouseOverEvents")
    ui.saved_move_probe_ok, ui.saved_move_ignored = dd.ModUI.Runtime.Observation.ControllerIgnoredState(controller, "IsMoveInputIgnored")
    ui.saved_look_probe_ok, ui.saved_look_ignored = dd.ModUI.Runtime.Observation.ControllerIgnoredState(controller, "IsLookInputIgnored")
    ui.restore_input_hint = (ui.saved_show_cursor or ui.saved_click_events or ui.saved_hover_events) and "ui" or "game"
    diag("modalInput.snapshot", {
        cursor = ui.saved_show_cursor,
        click = ui.saved_click_events,
        hover = ui.saved_hover_events,
        moveProbe = ui.saved_move_probe_ok,
        moveIgnored = ui.saved_move_ignored,
        lookProbe = ui.saved_look_probe_ok,
        lookIgnored = ui.saved_look_ignored,
        restoreHint = ui.restore_input_hint,
    })
    ui.move_ignore_bumped = false
    ui.look_ignore_bumped = false
    ui.native_ui_handler = valid(handler) and handler or nil
    ui.native_ui_input_enabled = false

    -- ObjectDump correction (v0.9.17): IMC_Menu_Default is shared game state.
    -- HUD widgets such as WBP_Notify_Large_Item_Default own WBP_InputListener
    -- children but never call EnableUserInterfaceInput/DisableUserInterfaceInput;
    -- they rely on the menu mapping already being present. v0.9.16 incorrectly
    -- added that shared context and then removed it on close, which could strand
    -- the next native popup with no keyboard/controller actions. Do not touch
    -- the mapping context at all. Our temporary listener only binds to whatever
    -- menu InputActions Mortal Shell already exposes.
    local mapping_name = "<unavailable>"
    pcall(function() mapping_name = object_name(unwrap(handler.InputMapping)) end)
    ui.native_ui_input_enabled = false
    log("native UI shared mapping preserved untouched mapping=" .. tostring(mapping_name)
        .. " ownership=game")

    -- Prior v0.8.6/v0.8.7 testing proved PlayerController Enhanced Input does
    -- not reach the menu listener under UIOnly. Use GameAndUI so the already-
    -- active game InputActions can reach our temporary generic listener.
    local ok_mode, mode_error = pcall(game_and_ui, library, controller, widget, 0, false, true)
    if not ok_mode then
        log("modal input unavailable: SetInputMode_GameAndUIEx failed: " .. tostring(mode_error))
        diag("modalInput.acquire", { stage = "SetInputMode_GameAndUIEx", status = "failed", error = mode_error })
        return false
    end
    diag("modalInput.acquire", { stage = "SetInputMode_GameAndUIEx", status = "ok" })

    -- v0.9.42 uses exact, TTS-owned gameplay-effect handles for movement, camera,
    -- abilities, and native game-menu admission. These controller guards remain
    -- conservative extras and cover the small gap before those handles are acquired.
    if ui.saved_move_probe_ok and not ui.saved_move_ignored then
        local ok = pcall(function() controller:SetIgnoreMoveInput(true) end)
        ui.move_ignore_bumped = ok
    end
    if ui.saved_look_probe_ok and not ui.saved_look_ignored then
        local ok = pcall(function() controller:SetIgnoreLookInput(true) end)
        ui.look_ignore_bumped = ok
    end

    -- This menu is now genuinely mouse-operable. Preserve the caller's three
    -- cursor/event flags above, expose the cursor for this modal, then restore the
    -- exact snapshot during teardown. Center a previously-hidden cursor through
    -- Mortal Shell's own helper so the first mouse interaction starts on-screen.
    pcall(function() controller.bShowMouseCursor = true end)
    pcall(function() controller.bEnableClickEvents = true end)
    pcall(function() controller.bEnableMouseOverEvents = true end)
    if not ui.saved_show_cursor then
        pcall(function()
            LoadAsset(NATIVE_BPFL_UI_ASSET)
            local bpfl = unwrap(StaticFindObject(NATIVE_BPFL_UI_CDO))
            if valid(bpfl) and bpfl["ResetMouseToScreenCenter"] ~= nil then
                bpfl:ResetMouseToScreenCenter(true, widget, controller)
            end
        end)
    end

    pcall(function() widget:SetKeyboardFocus() end)
    pcall(function() widget:SetUserFocus(controller) end)
    pcall(function() widget:SetFocus() end)

    ui.controller = controller
    ui.widget_library = library
    ui.modal_input_active = true
    ui.modal_keybind_seen = false
    ui.modal_keybind_confirmed = false
    ui.modal_watch_age_ticks = 0

    log(string.format(
        "modal input acquired mode=GameAndUI(native-bridge) mapping=%s restoreHint=%s savedCursor=%s savedClick=%s savedHover=%s activeCursor=true activeClick=true activeHover=true moveIgnored=%s lookIgnored=%s moveGuard=%s lookGuard=%s",
        "shared-preserved",
        tostring(ui.restore_input_hint),
        tostring(ui.saved_show_cursor),
        tostring(ui.saved_click_events),
        tostring(ui.saved_hover_events),
        tostring(ui.saved_move_ignored),
        tostring(ui.saved_look_ignored),
        tostring(ui.move_ignore_bumped),
        tostring(ui.look_ignore_bumped)
    ))
    diag("modalInput.acquire", {
        stage = "complete",
        status = "ok",
        moveGuard = ui.move_ignore_bumped,
        lookGuard = ui.look_ignore_bumped,
        handler = valid(ui.native_ui_handler) and object_name(ui.native_ui_handler) or "<invalid>",
    })
    return true
end

local function restore_settings_input(reason)
    diag("modalInput.restore", { stage = "begin", reason = reason, active = ui.modal_input_active })
    if not ui.modal_input_active then
        ui.controller = nil
        ui.widget_library = nil
        return
    end

    local controller = unwrap(ui.controller)
    local library = unwrap(ui.widget_library)
    local restore_mode = "none"

    if valid(controller) then
        if ui.move_ignore_bumped then
            pcall(function() controller:SetIgnoreMoveInput(false) end)
        end
        if ui.look_ignore_bumped then
            pcall(function() controller:SetIgnoreLookInput(false) end)
        end

        pcall(function() controller.bShowMouseCursor = ui.saved_show_cursor end)
        pcall(function() controller.bEnableClickEvents = ui.saved_click_events end)
        pcall(function() controller.bEnableMouseOverEvents = ui.saved_hover_events end)

        if valid(library) then
            if ui.restore_input_hint == "ui" and library["SetInputMode_GameAndUIEx"] ~= nil then
                local ok = pcall(function()
                    library:SetInputMode_GameAndUIEx(controller, nil, 0, false, true)
                end)
                if ok then restore_mode = "GameAndUI" end
            end

            if restore_mode == "none" and library["SetInputMode_GameOnly"] ~= nil then
                local ok = pcall(function() library:SetInputMode_GameOnly(controller, true) end)
                if ok then
                    restore_mode = "GameOnly"
                    pcall(function() library:SetFocusToGameViewport() end)
                end
            end
        end
    end

    log("modal input released restore=" .. tostring(restore_mode) .. " reason=" .. tostring(reason or "close"))
    diag("modalInput.restore", {
        stage = "complete",
        restoreMode = restore_mode,
        reason = reason or "close",
    })

    ui.controller = nil
    ui.widget_library = nil
    ui.modal_input_active = false
    ui.modal_keybind_seen = false
    ui.modal_keybind_confirmed = false
    ui.modal_watch_age_ticks = 0
    ui.move_ignore_bumped = false
    ui.look_ignore_bumped = false
end

local function note_modal_keybind(source, action)
    if ui.open and not ui.closing and ui.modal_input_active then
        ui.modal_keybind_seen = true
        if not ui.modal_keybind_confirmed then
            ui.modal_keybind_confirmed = true
            diag("input.activity.first", {
                source = tostring(source or "unknown"),
                action = tostring(action or "unknown"),
            })
        end
    end
end

local function active_ui_session_valid()
    return ui.open
        and not ui.closing
        and (tonumber(ui.active_generation) or 0) > 0
        and (ui.host_visible_shell == true or valid(ui.widget))
end

-- Narration duplicate suppression needs elapsed real time rather than process CPU
-- time. Mortal Shell's own continuous menu input uses KismetSystemLibrary
-- GetRealTimeSeconds for the same pause-safe reason. Resolve it lazily and fail
-- soft to wall-clock seconds if this engine branch exposes the function differently.
function dd.real_time_seconds()
    local library = unwrap(dd.kismet_system_library)
    if not valid(library) then
        local ok_library, candidate = pcall(function()
            return unwrap(StaticFindObject("/Script/Engine.Default__KismetSystemLibrary"))
        end)
        if ok_library and valid(candidate) then
            library = candidate
            dd.kismet_system_library = candidate
        end
    end

    if valid(library) and library["GetRealTimeSeconds"] ~= nil then
        -- While Settings is active, ui.controller is already the validated session
        -- controller. Use it directly so the Pass-133 FindAllOf local-controller resolver
        -- does not become an active-input clock hot path. Narration usually runs with no
        -- Settings controller, so only then resolve a live player/controller as additional
        -- WorldContext candidates rather than falling back to one-second wall-clock time.
        local live_player, live_controller = nil, nil
        if not valid(ui.controller) then
            live_player, live_controller = dd.native_presentation.GetPlayerAndController()
        end
        for _, context in ipairs({ ui.controller, live_controller, live_player, ui.widget }) do
            context = unwrap(context)
            if valid(context) then
                local ok_time, value = pcall(function()
                    return library:GetRealTimeSeconds(context)
                end)
                value = ok_time and tonumber(unwrap(value)) or nil
                if dd.finite_number(value) and value >= 0 then
                    return value, "unreal-real-time"
                end
            end
        end
    end

    return tonumber(os.time()) or 0, "os.time"
end

-- Input timeout/debounce windows are wall-time semantics, not CPU-time semantics.
-- os.clock() measures process CPU time on standard Lua and can therefore stretch a
-- 220 ms recorder grace period or 1.5 s sequence timeout differently across PCs.
-- Prefer Unreal's pause-safe real-time clock whenever it is available; retain the
-- old high-resolution os.clock() only as a fail-soft fallback when native timing
-- cannot be resolved on an unexpected engine branch.
function dd.input_time_seconds()
    if dd.real_time_seconds ~= nil then
        local ok_time, value, source = pcall(dd.real_time_seconds)
        value = ok_time and tonumber(value) or nil
        if value ~= nil and tostring(source) == "unreal-real-time" then
            return value, "unreal-real-time"
        end
    end

    local ok_clock, cpu_time = pcall(function() return os.clock() end)
    cpu_time = ok_clock and tonumber(cpu_time) or nil
    if cpu_time ~= nil then return cpu_time, "os.clock-fallback" end
    return tonumber(os.time()) or 0, "os.time-fallback"
end

local function claim_cross_source_navigation(semantic, source_kind, source)
    local ok_clock, now = pcall(function() return os.clock() end)
    now = ok_clock and tonumber(now) or nil

    local allowed, next_semantic, next_source_kind, next_clock, info = dd.ModUI.Input.Route.ClaimCrossSource(
        ui.input_dedupe_last_semantic,
        ui.input_dedupe_last_source_kind,
        ui.input_dedupe_last_clock,
        semantic,
        source_kind,
        now,
        INPUT_CROSS_SOURCE_DEDUPE_SECONDS
    )

    if allowed == false then
        ui.input_dedupe_count = (tonumber(ui.input_dedupe_count) or 0) + 1
        diag("input.dedupe", {
            status = "suppressed",
            semantic = tostring(semantic or ""),
            sourceKind = tostring(source_kind or ""),
            priorSourceKind = type(info) == "table" and tostring(info.prior_source_kind or "") or "",
            elapsedMs = type(info) == "table" and math.floor(((tonumber(info.elapsed) or 0) * 1000.0) + 0.5) or 0,
            source = source,
            generation = ui.active_generation,
        })
        return false
    end

    -- Invalid semantic/source or unavailable clock intentionally leave the old
    -- state untouched, matching the pre-extraction fail-open behavior.
    ui.input_dedupe_last_semantic = next_semantic
    ui.input_dedupe_last_source_kind = next_source_kind
    ui.input_dedupe_last_clock = next_clock
    return true
end

function dd.activate_fallback_renderer(reason)
    reason = tostring(reason or "rail-health-failure")
    if ui.presentation_mode == "fallback" then
        return true
    end

    local vb_data = unwrap(ui.native_reader_vb_data)
    local vb_ok = valid(vb_data) and dd.native_presentation.SetNativeVisibility(vb_data, 0) or false

    -- Do not destroy child widgets from inside a redraw/input boundary. Collapse
    -- the richer rails and keep their UObject graph parent-owned until normal
    -- close; this is a one-way per-session degradation path.
    local rail_results = {}
    for label, widget in pairs({
        tabs = ui.native_tabs_widget,
        labels = ui.native_labels_widget,
        values = ui.native_values_widget,
    }) do
        if valid(widget) then
            rail_results[label] = dd.native_presentation.SetNativeVisibility(widget, 1)
        else
            rail_results[label] = false
        end
    end

    ui.presentation_mode = "fallback"
    local combined = settings_combined_text()
    local body_ok = dd.native_presentation.SetNativeText(ui.body_widget, combined, "reader.body")

    diag("renderer.degrade", {
        reason = reason,
        mode = ui.presentation_mode,
        vbDataVisible = vb_ok,
        tabsCollapsed = rail_results.tabs,
        labelsCollapsed = rail_results.labels,
        valuesCollapsed = rail_results.values,
        fallbackBodySet = body_ok,
        bodyBytes = #combined,
    })
    log("settings renderer degraded to combined fallback reason=" .. reason
        .. " vbDataVisible=" .. tostring(vb_ok)
        .. " bodySet=" .. tostring(body_ok))

    return vb_ok and body_ok
end

local set_ui_text_body
-- ui.render: every settings redraw (text composition + native presentation publish).
local function set_ui_text()
    local perf = dd.perf
    if perf == nil or not perf.enabled then return set_ui_text_body() end
    local token = perf.Begin()
    local result = set_ui_text_body()
    perf.End("ui.render", token)
    return result
end

set_ui_text_body = function()
    local generation = tonumber(ui.active_generation) or 0
    local host_visible = ui.host_visible_shell == true
    if not ui.open or ui.closing or generation <= 0 or (not host_visible and not valid(ui.widget)) then
        if ui.open and not ui.invalid_session_logged then
            ui.invalid_session_logged = true
            log("settings redraw rejected: active session/shell validity guard failed generation=" .. tostring(generation))
            diag("redraw.guard", {
                status = "rejected",
                generation = generation,
                open = ui.open,
                closing = ui.closing,
                widgetValid = valid(ui.widget),
                hostVisibleShell = host_visible,
            })
        end
        return false
    end

    if host_visible then
        ui.redraw_sequence = (ui.redraw_sequence or 0) + 1
        local redraw_id = ui.redraw_sequence
        local published, detail = dd.publish_modui_host_menu_presentation()
        diag("redraw.end", {
            id = redraw_id,
            status = published and "host-presentation-published" or "host-presentation-failed",
            mode = "host-visible-shell",
            generation = generation,
            presentationSequence = type(_G.MortalShell2TTSRuntime) == "table" and _G.MortalShell2TTSRuntime.modui_host_presentation_sequence or 0,
            detail = detail,
        })
        return published == true
    end

    if ui.presentation_mode == "rails" then
        local rail_health = valid(ui.native_tabs_widget) and valid(ui.native_tabs_text)
            and valid(ui.native_labels_widget) and valid(ui.native_labels_text)
            and valid(ui.native_values_widget) and valid(ui.native_values_text)
        if not rail_health then
            dd.activate_fallback_renderer("pre-redraw-rail-reference-invalid")
        end
    end

    ui.redraw_sequence = (ui.redraw_sequence or 0) + 1
    local redraw_id = ui.redraw_sequence
    local set_calls_before = tonumber(ui.render_set_calls) or 0
    local set_skips_before = tonumber(ui.render_set_skips) or 0
    log("settings redraw begin id=" .. tostring(redraw_id) .. " tab=" .. tostring(current_tab().key) .. " selected=" .. tostring(ui.selected))
    diag("redraw.begin", {
        id = redraw_id,
        tab = current_tab().key,
        selected = ui.selected,
    })

    if not valid(ui.header_widget) then
        ui.header_widget = dd.native_presentation.NativeWidgetField(ui.widget, "Text_PromptName")
    end
    if not valid(ui.body_widget) then
        ui.body_widget = dd.native_presentation.NativeWidgetField(ui.widget, "RTB_ReadText")
    end
    if not valid(ui.page_widget) then
        ui.page_widget = dd.native_presentation.NativeWidgetField(ui.widget, "Text_Page_Status")
    end

    local body_text = settings_plain_text()
    log("settings redraw text built id=" .. tostring(redraw_id) .. " bytes=" .. tostring(#body_text))
    diag("redraw.text", { id = redraw_id, bodyBytes = #body_text })

    local header_text = type(dd.settings_presentation.HeaderText) == "function" and dd.settings_presentation.HeaderText() or "TEXT TO SPEECH SETTINGS"
    local header_ok = dd.native_presentation.SetNativeText(ui.header_widget, header_text, "reader.header")
    log("settings redraw header SetText complete id=" .. tostring(redraw_id) .. " ok=" .. tostring(header_ok))

    local body_ok = dd.native_presentation.SetNativeText(ui.body_widget, body_text, "reader.body")
    log("settings redraw body SetText complete id=" .. tostring(redraw_id) .. " ok=" .. tostring(body_ok))

    local page_text = type(dd.settings_presentation.PageText) == "function" and dd.settings_presentation.PageText()
        or string.format("%02d/%02d", ui.tab, #tabs)
    local page_ok = dd.native_presentation.SetNativeText(ui.page_widget, page_text, "reader.page")
    log("settings redraw page SetText complete id=" .. tostring(redraw_id) .. " ok=" .. tostring(page_ok))

    local values_ok = false
    if ui.presentation_mode == "rails" then
        values_ok = dd.native_presentation.UpdateNativeValuesPanel()
        if valid(ui.native_tabs_widget) or valid(ui.native_labels_widget) or valid(ui.native_values_widget) then
            log("settings redraw passive tab/label/value rails complete id=" .. tostring(redraw_id) .. " ok=" .. tostring(values_ok))
        end
    else
        diag("redraw.rails", { id = redraw_id, status = "skipped-fallback-mode" })
    end

    if ui.presentation_mode == "rails" and not values_ok then
        local fallback_ok = dd.activate_fallback_renderer("runtime-passive-rail-update-failed")
        if fallback_ok then
            body_ok = true
        end
    end

    local details_ok = dd.native_presentation.UpdateNativeDetailsPanel()
    if valid(ui.native_details_widget) then
        log("settings redraw setting info panel complete id=" .. tostring(redraw_id) .. " ok=" .. tostring(details_ok))
    end

    local presentation_ok = false
    if ui.presentation_mode == "rails" then
        presentation_ok = values_ok == true
    else
        presentation_ok = body_ok == true and valid(ui.native_reader_vb_data)
    end

    diag("redraw.end", {
        id = redraw_id,
        status = header_ok and presentation_ok and "presentation-ok" or "presentation-failed",
        mode = ui.presentation_mode,
        header = header_ok,
        body = body_ok,
        page = page_ok,
        passiveRails = values_ok,
        presentation = presentation_ok,
        details = details_ok,
        generation = generation,
        setCalls = (tonumber(ui.render_set_calls) or 0) - set_calls_before,
        setSkips = (tonumber(ui.render_set_skips) or 0) - set_skips_before,
    })

    if header_ok and presentation_ok then
        return true
    end

    if not ui.native_error_logged then
        ui.native_error_logged = true
        log("native settings shell created, but expected text fields were unavailable")
    end
    return false
end

dd.set_ui_text = set_ui_text

-- Non-native Settings actions/navigation are module-owned. The host retains
-- native widget/input/modal/pause mutations and supplies only bounded callbacks.
dd.settings_controller, dd.settings_controller_error = dd.SettingsControllerFactory.New({
    config = config,
    ui = ui,
    engines = engines,
    azure_regions = azure_regions,
    tabs = tabs,
    navigation = dd.ModUI.Settings.Navigation,
    save_config = save_config,
    defaults = function() return dd.ConfigDefaults.New() end,
    log = log,
    diag = diag,
    refresh_voices = refresh_voices,
    voice_index = voice_index,
    active_voice_value = active_voice_value,
    capture_voice_profile = dd.capture_voice_profile,
    apply_voice_profile = dd.apply_voice_profile,
    current_voice_styles = dd.current_voice_styles,
    normalized_voice_style = dd.normalized_voice_style,
    normalize_queue_behavior = dd.normalize_queue_behavior,
    normalize_duplicate_window = dd.normalize_duplicate_window,
    stop_speech = stop_speech,
    reset_duplicates = function() return dd.speech_runtime.ResetDuplicates() end,
    engine_index = function() return dd.engine_runtime.Index() end,
    region_index = function() return dd.engine_runtime.RegionIndex() end,
    refresh_audio_outputs = refresh_audio_outputs,
    audio_output_index = audio_output_index,
    tts_command = tts_command,
    reset_voice_profiles = function() return dd.voice_profile_runtime.Reset() end,
    bind_capture_active = function() return type(dd.bind_capture_active) == "function" and dd.bind_capture_active() or false end,
    active_session_valid = active_ui_session_valid,
    voice_browser_active = dd.voice_browser_active,
    voice_browser_move = function(delta) return dd.voice_browser_controller.Move(delta) end,
    voice_browser_cycle_gender = function(delta) return dd.voice_browser_controller.CycleGender(delta) end,
    voice_browser_activate = function() return dd.voice_browser_controller.Activate() end,
    open_voice_browser = function() return dd.voice_browser_controller.Open() end,
    controller_settings_active = function() return type(dd.controller_settings_active) == "function" and dd.controller_settings_active() or false end,
    controller_settings_move = function(delta) return dd.controller_settings_move(delta) end,
    controller_settings_change = function(delta) return dd.controller_settings_change(delta) end,
    controller_settings_activate = function() return dd.controller_settings_activate() end,
    open_controller_settings = function() return dd.open_controller_settings() end,
    current_rows = current_rows,
    current_tab = current_tab,
    current_voice_pitch_supported = dd.current_voice_pitch_supported,
    sync_open_bind_labels = function() return dd.sync_open_bind_labels() end,
    sync_perf = function(reason)
        if type(dd.sync_perf) == "function" then return dd.sync_perf(reason) end
        return nil
    end,
    clear_keyboard_open_sequence = function()
        if dd.open_bind_sequence_state ~= nil then dd.open_bind_sequence_state.keyboard = nil end
    end,
    republish_modui_host_binding = function(kind, value)
        if type(dd.republish_modui_host_binding) ~= "function" then return nil end
        return dd.republish_modui_host_binding(kind, value)
    end,
    get_player_and_controller = function() return dd.native_presentation.GetPlayerAndController() end,
    refresh_binding_conflicts = function(controller)
        if type(dd.refresh_binding_conflicts) ~= "function" then return nil end
        return dd.refresh_binding_conflicts(controller)
    end,
    clear_pending_speech = function() return dd.speech_queue.Clear() end,
    reader_is_open = function() return dd.reader_runtime.IsOpen() end,
    read_reader = function() return dd.reader_runtime.Read() end,
    queue_speech = function(text, page, reason) return dd.speech_queue.Queue(text, page, reason) end,
    test_voice = function() return dd.speech_runtime.Test() end,
    start_bind_capture = function(kind)
        if type(dd.start_bind_capture) ~= "function" then return nil end
        return dd.start_bind_capture(kind)
    end,
    pause_native_gameplay = function(handler, reason)
        if type(dd.pause_native_gameplay) ~= "function" then return false end
        return dd.pause_native_gameplay(handler, reason)
    end,
    release_native_gameplay_pause = function(reason)
        if type(dd.release_native_gameplay_pause) ~= "function" then return false end
        return dd.release_native_gameplay_pause(reason)
    end,
    unwrap = unwrap,
    valid = valid,
    apply_ui_style = function() return true end,
    redraw = function() return set_ui_text() end,
})
if dd.settings_controller == nil
    or type(dd.settings_controller.Save) ~= "function"
    or type(dd.settings_controller.CycleVoice) ~= "function"
    or type(dd.settings_controller.ChangeSelected) ~= "function"
    or type(dd.settings_controller.ActivateSelected) ~= "function"
    or type(dd.settings_controller.ClearResetConfirmation) ~= "function"
    or type(dd.settings_controller.MoveSelection) ~= "function"
    or type(dd.settings_controller.ChangeTab) ~= "function" then
    error("MortalShell2TTS Settings.Controller failed: " .. tostring(dd.settings_controller_error or "missing API"))
end
diag("dependency.settingsController", { module = "Settings.Controller", ownership = "settings-actions-navigation", status = "ready" })

dd.NativeInputTriggerFunction = "/Game/Sparta/UI/Core/Navigation/WBP_InputListener.WBP_InputListener_C:InputTriggeredCallback"
dd.NativeInputHookFields = {
    registered = "native_input_hooks_registered",
    pre = "native_input_enum_hook_pre",
    post = "native_input_enum_hook_post",
    cycle = "native_input_hook_cycle",
}

dd.NativeUIObserverFactory, dd.native_ui_runtime_factory_error = dd.load_lua_table_module(scripts_dir .. "\\Runtime\\NativeUIObserver.lua", "Runtime.NativeUIObserver")
if dd.NativeUIObserverFactory == nil or type(dd.NativeUIObserverFactory.Bind) ~= "function" then
    error("MortalShell2TTS Runtime.NativeUIObserver failed to load: " .. tostring(dd.native_ui_runtime_factory_error or "missing API"))
end
dd.native_ui_runtime, dd.native_ui_runtime_error = dd.NativeUIObserverFactory.Bind({
    dd = dd, ui = ui, unwrap = unwrap, valid = valid, object_name = object_name, widget_text = widget_text,
    log = log, diag = diag, scripts_dir = scripts_dir,
    NATIVE_BPFL_UI_ASSET = NATIVE_BPFL_UI_ASSET, NATIVE_BPFL_UI_CDO = NATIVE_BPFL_UI_CDO,
    native_widget_field = dd.native_presentation.NativeWidgetField,
    native_menu_query = dd.ModUI.Runtime.Observation.MenuQuery,
})
if type(dd.native_ui_runtime) ~= "table" then
    error("MortalShell2TTS Runtime.NativeUIObserver failed: " .. tostring(dd.native_ui_runtime_error or "missing API"))
end
diag("dependency.nativeUIObserver", { module = "Runtime.NativeUIObserver", ownership = "native-ui-observation+admission", status = "ready" })

local function native_input_value(value)
    value = unwrap(value)
    local number = tonumber(value)
    if number ~= nil then return tostring(number) end
    return tostring(value)
end

local function native_action_route(action_name)
    return dd.ModUI.Input.Route.Action(action_name)
end

local function native_controller_is_gamepad()
    local using_gamepad, status, detail = dd.ModUI.Runtime.Listener.ControllerIsGamepad(ui.controller)
    if status == "method-unavailable" then
        if not ui.native_gamepad_probe_warned then
            ui.native_gamepad_probe_warned = true
            log("native controller routing disabled: IsUsingGamepadForFeedback was not exposed")
        end
        return false
    elseif status == "probe-failed" then
        if not ui.native_gamepad_probe_warned then
            ui.native_gamepad_probe_warned = true
            log("native controller routing disabled: gamepad-state probe failed: " .. tostring(detail))
        end
        return false
    end
    return using_gamepad == true
end


dd.number_array_contains = dd.ModUI.Input.Acceptance.Contains

function dd.listener_native_acceptance(listener, input_number)
    return dd.ModUI.Runtime.Listener.AcceptanceSnapshot(
        listener,
        input_number,
        ui.native_action_name_by_enum,
        ui.native_verified_accepted_inputs
    )
end

local function dispatch_native_controller_route(route, source)
    local generation = tonumber(ui.active_generation) or 0
    local gamepad_mode = native_controller_is_gamepad()
    diag("input.controller.candidate", {
        route = route,
        source = source,
        gamepadMode = gamepad_mode,
        closing = ui.closing,
        generation = generation,
    })
    if not ui.open or ui.closing or generation <= 0 or route == nil or not gamepad_mode then return end
    if dd.bind_capture_active ~= nil and dd.bind_capture_active() then
        -- During recording the polling recorder owns every controller button, including
        -- Circle. Circle cancels only if it is the complete recorded chord; L3+Circle,
        -- R1+Circle, etc. are valid bindings and must not be pre-empted by menu Back.
        diag("input.controller.dispatch", { status = "suppressed-during-bind-capture", route = route, source = source })
        return
    end
    local browser_page_modifier = dd.voice_browser_active ~= nil and dd.voice_browser_active()
        and (route == "up" or route == "down")
        and dd.voice_browser_page_modifier_down(ui.controller)
    local navigation_semantic = browser_page_modifier and (route == "up" and "page-up" or "page-down") or route
    if (route == "up" or route == "down" or route == "left" or route == "right")
        and not claim_cross_source_navigation(navigation_semantic, "controller", source) then
        return
    end
    if browser_page_modifier then
        dd.voice_browser_page(route == "up" and -1 or 1)
        diag("voice.browser", { action = "modifier-page", direction = route, source = tostring(source) })
        return
    elseif dd.voice_browser_active ~= nil and dd.voice_browser_active() and (route == "up" or route == "down") then
        diag("voice.browser.input", { action = "row", direction = route, source = "controller-native", nativeSource = tostring(source) })
    end
    local rt = _G.MortalShell2TTSRuntime
    if rt == nil then
        diag("input.controller.dispatch", { status = "runtime-unavailable", route = route, source = source })
        return
    end

    note_modal_keybind("controller", route)
    log("controller menu action=" .. tostring(route) .. " source=" .. tostring(source))
    diag("input.controller.dispatch", { status = "dispatch", route = route, source = source })
    if route == "left" then
        local map_blocked = select(1, dd.probe_native_menu_blocks(ui.native_ui_handler, "controller-left"))
        if not map_blocked then
            log("WARNING: controller Left arrived while MapMenuQuery block could not be verified")
        end
    end
    if route == "up" and rt.ui_up_game ~= nil then
        rt.ui_up_game()
    elseif route == "down" and rt.ui_down_game ~= nil then
        rt.ui_down_game()
    elseif route == "left" and rt.ui_left_game ~= nil then
        rt.ui_left_game()
    elseif route == "right" and rt.ui_right_game ~= nil then
        rt.ui_right_game()
    elseif route == "previous_tab" and rt.ui_prev_tab_game ~= nil then
        rt.ui_prev_tab_game()
    elseif route == "next_tab" and rt.ui_tab_game ~= nil then
        rt.ui_tab_game()
    elseif route == "confirm" and rt.ui_return_game ~= nil then
        rt.ui_return_game()
    elseif route == "back" and rt.ui_controller_back_game ~= nil then
        rt.ui_controller_back_game()
    elseif route == "back" and rt.ui_close_game ~= nil then
        rt.ui_close_game()
    end
end

-- Mouse pointer coordinate resolution is Mortal Shell/UE4SS-specific host work, but it
-- is a coherent subsystem rather than composition-root policy. Pass 101 moves the
-- guarded BPFL_UI / WidgetLayoutLibrary / PlayerController resolver chain into
-- UI.Pointer while retaining the exact proven resolver order and reference-space math.
dd.PointerRuntimeFactory, dd.pointer_runtime_factory_error = dd.load_lua_table_module(scripts_dir .. "\\UI\\Pointer.lua", "UI.Pointer")
if dd.PointerRuntimeFactory == nil or type(dd.PointerRuntimeFactory.New) ~= "function" then
    error("MortalShell2TTS UI.Pointer failed to load: " .. tostring(dd.pointer_runtime_factory_error or "missing API"))
end

dd.pointer_runtime, dd.pointer_runtime_error = dd.PointerRuntimeFactory.New({
    ui = ui,
    unwrap = unwrap,
    valid = valid,
    load_asset = function(path) return LoadAsset(path) end,
    static_find_object = function(path) return StaticFindObject(path) end,
    native_bpfl_ui_asset = NATIVE_BPFL_UI_ASSET,
    native_bpfl_ui_cdo = NATIVE_BPFL_UI_CDO,
})
if dd.pointer_runtime == nil
    or type(dd.pointer_runtime.Resolve) ~= "function"
    or type(dd.pointer_runtime.FiniteNumber) ~= "function"
    or type(dd.pointer_runtime.DirectStructNumber) ~= "function"
    or type(dd.pointer_runtime.OutputNumber) ~= "function" then
    error("MortalShell2TTS UI.Pointer failed: " .. tostring(dd.pointer_runtime_error or "missing API"))
end
diag("dependency.uiPointer", { module = "UI.Pointer", ownership = "pointer-coordinate-resolution", status = "ready" })

-- Thin compatibility adapters remain because existing details/window/browser code
-- consumes these helpers by name. The algorithms themselves now live in UI.Pointer.
function dd.finite_number(value) return dd.pointer_runtime.FiniteNumber(value) end
function dd.direct_struct_number(value, names) return dd.pointer_runtime.DirectStructNumber(value, names) end
function dd.output_number(holder, names) return dd.pointer_runtime.OutputNumber(holder, names) end
function dd.reference_pointer_from_bpfl() return dd.pointer_runtime.ReferenceFromBPFL() end
function dd.reference_pointer_from_layout() return dd.pointer_runtime.ReferenceFromLayout() end
function dd.reference_pointer_from_controller_out_params() return dd.pointer_runtime.ReferenceFromControllerOutParams() end
function dd.mouse_screen_position() return dd.pointer_runtime.Resolve() end

function dd.select_mouse_row(row, activate, region)
    row = tonumber(row)
    local rows = current_rows()
    if row == nil or row < 1 or row > #rows then return false end

    local was_selected = ui.selected == row
    if not was_selected then dd.clear_reset_confirmation("mouse-selection-changed") end
    ui.selected = row
    ui.selected_by_tab[ui.tab] = row
    ui.mouse_last_region = tostring(region or "row")
    ui.status = was_selected and "Mouse activated the selected setting." or "Setting selected with mouse."

    if activate or was_selected then
        dd.activate_selected()
    else
        set_ui_text()
    end
    return true
end

function dd.handle_mouse_click(source, pointer_override)
    if not active_ui_session_valid() then return false end
    if dd.bind_capture_active ~= nil and dd.bind_capture_active() then
        diag("input.mouse.click", { source = source, region = "suppressed-during-bind-capture", handled = false })
        return false
    end
    ui.mouse_click_count = (tonumber(ui.mouse_click_count) or 0) + 1

    local pointer, pointer_error = nil, nil
    if type(pointer_override) == "table" then
        pointer = pointer_override
    else
        pointer, pointer_error = dd.mouse_screen_position()
    end
    if pointer == nil then
        diag("input.mouse.click", {
            source = source,
            region = "unavailable",
            handled = false,
            error = pointer_error,
        })
        return false
    end

    local x = pointer.reference_x
    local y = pointer.reference_y
    local browser = dd.voice_browser_active ~= nil and dd.voice_browser_active()
    local controller_panel = dd.controller_settings_active ~= nil and dd.controller_settings_active()
    local wide_profile = browser or controller_panel
    -- ModUI 0.70.0: the host resolved the pointer against the strip and rails it drew.
    -- Its tab answer is authoritative for the main profile (the strip is windowed and
    -- measured there; the old three-equal-slots map below is the fallback for a host
    -- that sent nothing). Row hits keep the local path so the proven browser semantics
    -- and the value Previous/Next split stay exactly as they were.
    local host_hit = type(pointer.host_hit) == "table" and pointer.host_hit or nil
    if not wide_profile and host_hit ~= nil and (host_hit.kind == "tab" or host_hit.kind == "tab-scroll") then
        local target = host_hit.kind == "tab" and tonumber(host_hit.index)
            or (ui.tab + (tonumber(host_hit.direction) or 1))
        target = clamp(math.floor(target or ui.tab), 1, #tabs)
        dd.clear_reset_confirmation(target ~= ui.tab and "mouse-tab-changed" or "mouse-tab-clicked")
        ui.selected_by_tab[ui.tab] = ui.selected
        ui.tab = target
        ui.selected = ui.selected_by_tab[target] or 1
        if ui.selected > #current_rows() then ui.selected = 1 end
        ui.mouse_last_region = "tabs"
        ui.status = "Tab selected with mouse."
        set_ui_text()
        diag("input.mouse.click", {
            source = source, pointerSource = pointer.source, region = "tabs", hostHit = host_hit.kind,
            tab = current_tab().key, tabSlot = target, referenceX = x, referenceY = y,
        })
        return true
    end
    if not wide_profile and host_hit ~= nil and (host_hit.kind == "label" or host_hit.kind == "value") then
        -- A row the host resolved: take its row, and for a value its Previous/Next side,
        -- by moving the reference point into the matching local zone. Everything below
        -- then runs the proven branch for that zone.
        local host_layout = type(dd.UILayout) == "table" and type(dd.UILayout.ResolveAdaptive) == "function"
            and dd.UILayout.ResolveAdaptive("main", settings_label_text(), settings_values_text()) or nil
        local hp = host_layout and host_layout.pointer or nil
        if hp ~= nil then
            local row_total = #current_rows()
            local Viewport = type(dd.ModUI) == "table" and type(dd.ModUI.Settings) == "table" and dd.ModUI.Settings.Viewport or nil
            local first = 1
            if type(Viewport) == "table" and type(Viewport.Window) == "function" then first = Viewport.Window(row_total, ui.selected) end
            local visible_row = (tonumber(host_hit.index) or 1) - first + 1
            y = SETTINGS_LAYOUT.MAIN_ROW_HIT_TOP + (visible_row - 0.5) * SETTINGS_LAYOUT.ROW_HIT_STEP
            if host_hit.kind == "value" then
                local prev_right = hp.previousRight or SETTINGS_LAYOUT.MAIN_VALUE_PREVIOUS_RIGHT
                x = (tonumber(host_hit.direction) or 1) < 0 and (prev_right - 1.0) or (prev_right + 1.0)
            else
                x = hp.rowLeft + 1.0
            end
        end
    end
    local adaptive_layout = type(dd.UILayout) == "table" and type(dd.UILayout.ResolveAdaptive) == "function"
        and dd.UILayout.ResolveAdaptive(wide_profile and "browser" or "main", settings_label_text(), settings_values_text()) or nil
    local pointer_layout = adaptive_layout and adaptive_layout.pointer or nil

    -- Pass 42 recalibrates the three main tab hit zones from the user's 1080p
    -- pointer sweep. The previous v0.9.59-era map (625..1030) was substantially
    -- left of the current v0.9.77+ centered tab glyphs: clicks around 780..796 on
    -- visible MOD resolved as SPEECH, while ~900..930 on visible SPEECH resolved
    -- as ENGINE. Keep the proven Y band, but align X to the current presentation.
    if not wide_profile
        and x >= SETTINGS_LAYOUT.TAB_HIT_LEFT and x < SETTINGS_LAYOUT.TAB_HIT_RIGHT
        and y >= SETTINGS_LAYOUT.TAB_HIT_TOP and y < SETTINGS_LAYOUT.TAB_HIT_BOTTOM then
        local tab_width = (SETTINGS_LAYOUT.TAB_HIT_RIGHT - SETTINGS_LAYOUT.TAB_HIT_LEFT) / #tabs
        local target = math.floor((x - SETTINGS_LAYOUT.TAB_HIT_LEFT) / tab_width) + 1
        target = clamp(target, 1, #tabs)
        dd.clear_reset_confirmation(target ~= ui.tab and "mouse-tab-changed" or "mouse-tab-clicked")
        ui.selected_by_tab[ui.tab] = ui.selected
        ui.tab = target
        ui.selected = ui.selected_by_tab[target] or 1
        if ui.selected > #current_rows() then ui.selected = 1 end
        ui.mouse_last_region = "tabs"
        ui.status = "Tab selected with mouse."
        set_ui_text()
        diag("input.mouse.click", {
            source = source,
            pointerSource = pointer.source,
            normalizedX = pointer.normalized_x,
            normalizedY = pointer.normalized_y,
            region = "tabs",
            tab = current_tab().key,
            tabSlot = target,
            screenX = pointer.x,
            screenY = pointer.y,
            referenceX = x,
            referenceY = y,
            viewport = tostring(pointer.width) .. "x" .. tostring(pointer.height),
        })
        return true
    end

    -- Rows share a stable baseline because labels and values are sibling rails.
    -- Pass 43 uses the measured main-rail reference map instead of the old v0.9.52
    -- 615..980 / value-left=760 approximation. The follow-up sweep proved that map
    -- still put the Previous zone far left of the visible `< value >` control.
    local row_top = wide_profile and SETTINGS_LAYOUT.BROWSER_ROW_HIT_TOP or SETTINGS_LAYOUT.MAIN_ROW_HIT_TOP
    local row_step = SETTINGS_LAYOUT.ROW_HIT_STEP
    local row_left = pointer_layout and pointer_layout.rowLeft or (wide_profile and SETTINGS_LAYOUT.BROWSER_ROW_HIT_LEFT or SETTINGS_LAYOUT.MAIN_ROW_HIT_LEFT)
    local row_right = pointer_layout and pointer_layout.rowRight or (wide_profile and SETTINGS_LAYOUT.BROWSER_ROW_HIT_RIGHT or SETTINGS_LAYOUT.MAIN_ROW_HIT_RIGHT)
    local value_left = pointer_layout and pointer_layout.valueLeft or (wide_profile and SETTINGS_LAYOUT.BROWSER_VALUE_HIT_LEFT or SETTINGS_LAYOUT.MAIN_VALUE_HIT_LEFT)
    if x >= row_left and x < row_right and y >= row_top then
        local row = math.floor((y - row_top) / row_step) + 1
        -- The shared shell windows a main-profile tab with more rows than it can show
        -- (ModUI Settings.Viewport). Map the visible row back to the tab row with the
        -- same pure window the host rendered from. Identity for every tab of ten or fewer.
        local row_total = #current_rows()
        local visible_rows = row_total
        local Viewport = not browser and type(dd.ModUI) == "table" and type(dd.ModUI.Settings) == "table"
            and dd.ModUI.Settings.Viewport or nil
        if type(Viewport) == "table" and type(Viewport.Window) == "function" then
            local first, last = Viewport.Window(row_total, ui.selected)
            visible_rows = last - first + 1
            row = first + row - 1
        end
        if row >= 1 and row <= row_total and y < row_top + (visible_rows * row_step) then
            local value_region = x >= value_left
            if not browser then
                value_region = value_region and x < (pointer_layout and pointer_layout.valueRight or SETTINGS_LAYOUT.MAIN_VALUE_HIT_RIGHT)
            end
            local region = value_region and "values" or (ui.presentation_mode == "rails" and "labels" or "fallback-list")

            -- Voice Browser keeps its already-proven select/activate click semantics.
            if browser then
                local activated = value_region or ui.selected == row
                local handled = dd.select_mouse_row(row, value_region, region)
                diag("input.mouse.click", {
                    source = source,
                    pointerSource = pointer.source,
                    normalizedX = pointer.normalized_x,
                    normalizedY = pointer.normalized_y,
                    region = region,
                    row = row,
                    activated = activated,
                    mouseAction = activated and "activate" or "select",
                    screenX = pointer.x,
                    screenY = pointer.y,
                    referenceX = x,
                    referenceY = y,
                    rowHitTop = row_top,
                    rowHitStep = row_step,
                    viewport = tostring(pointer.width) .. "x" .. tostring(pointer.height),
                })
                return handled
            end

            -- Main Settings uses one contiguous adjustable-value boundary.
            -- Pass 45 keeps the standardized Previous/< band measured in Pass 43,
            -- but removes the fixed center/right-arrow dead zone: the exact x where
            -- Previous ends is where Next begins. This remains robust when rendered
            -- value text changes width and moves the visible `>` glyph.
            -- Label clicks only select; action/binding rows remain one-click actions.
            local rows = current_rows()
            local row_data = rows[row]
            if row_data == nil then return false end
            if row ~= ui.selected then dd.clear_reset_confirmation("mouse-selection-changed") end
            ui.selected = row
            ui.selected_by_tab[ui.tab] = row
            ui.mouse_last_region = tostring(region)

            local mouse_action = "select"
            local activated = false
            if value_region then
                local kind = tostring(row_data.kind or "")
                local key = tostring(row_data.key or "")
                local whole_value_action = kind == "action"
                    or key == "menu_keybind"
                    or key == "controller_menu_bind"
                    or key == "azure_key"
                if whole_value_action then
                    mouse_action = "activate"
                    activated = true
                    dd.activate_selected()
                elseif x < (pointer_layout and pointer_layout.previousRight or SETTINGS_LAYOUT.MAIN_VALUE_PREVIOUS_RIGHT) then
                    mouse_action = "previous"
                    activated = true
                    dd.change_selected(-1)
                else
                    mouse_action = "next"
                    activated = true
                    dd.change_selected(1)
                end
            else
                dd.clear_reset_confirmation("mouse-label-clicked")
                ui.status = "Setting selected with mouse."
                set_ui_text()
            end

            diag("input.mouse.click", {
                source = source,
                pointerSource = pointer.source,
                normalizedX = pointer.normalized_x,
                normalizedY = pointer.normalized_y,
                region = region,
                row = row,
                activated = activated,
                mouseAction = mouse_action,
                screenX = pointer.x,
                screenY = pointer.y,
                referenceX = x,
                referenceY = y,
                viewport = tostring(pointer.width) .. "x" .. tostring(pointer.height),
            })
            return true
        end
    end

    -- The information panel is itself an action surface for the selected row.
    -- Keep its hitbox moving with the details rail so pointer geometry remains aligned
    -- with the restored value/details gutter.
    local details_left = pointer_layout and pointer_layout.detailsLeft or (wide_profile and SETTINGS_LAYOUT.BROWSER_DETAILS_HIT_LEFT or SETTINGS_LAYOUT.DETAILS_HIT_LEFT)
    local details_right = pointer_layout and pointer_layout.detailsRight or (wide_profile and SETTINGS_LAYOUT.BROWSER_DETAILS_HIT_RIGHT or SETTINGS_LAYOUT.DETAILS_HIT_RIGHT)
    local details_top = pointer_layout and pointer_layout.detailsTop or (wide_profile and SETTINGS_LAYOUT.BROWSER_DETAILS_HIT_TOP or SETTINGS_LAYOUT.DETAILS_HIT_TOP)
    local details_bottom = pointer_layout and pointer_layout.detailsBottom or (wide_profile and SETTINGS_LAYOUT.BROWSER_DETAILS_HIT_BOTTOM or SETTINGS_LAYOUT.DETAILS_HIT_BOTTOM)
    if x >= details_left and x < details_right and y >= details_top and y < details_bottom then
        ui.mouse_last_region = "details"
        dd.activate_selected()
        diag("input.mouse.click", {
            source = source,
            pointerSource = pointer.source,
            normalizedX = pointer.normalized_x,
            normalizedY = pointer.normalized_y,
            region = "details",
            row = ui.selected,
            activated = true,
            screenX = pointer.x,
            screenY = pointer.y,
            referenceX = x,
            referenceY = y,
            viewport = tostring(pointer.width) .. "x" .. tostring(pointer.height),
        })
        return true
    end

    diag("input.mouse.click", {
        source = source,
        pointerSource = pointer.source,
        normalizedX = pointer.normalized_x,
        normalizedY = pointer.normalized_y,
        region = "outside",
        handled = false,
        screenX = pointer.x,
        screenY = pointer.y,
        referenceX = x,
        referenceY = y,
        viewport = tostring(pointer.width) .. "x" .. tostring(pointer.height),
    })
    return false
end

function dd.dispatch_native_pointer_route(route, source, pointer_override)
    local generation = tonumber(ui.active_generation) or 0
    if not ui.open or ui.closing or generation <= 0 or route == nil then return end
    local rt = _G.MortalShell2TTSRuntime
    note_modal_keybind("mouse", route)
    diag("input.mouse.dispatch", { route = route, source = source })

    if route == "mouse_left" then
        dd.handle_mouse_click(source, pointer_override)
    elseif route == "mouse_right" then
        if rt ~= nil and rt.ui_pointer_back_game ~= nil then
            rt.ui_pointer_back_game()
        elseif rt ~= nil and rt.ui_controller_back_game ~= nil then
            rt.ui_controller_back_game()
        end
    elseif route == "mouse_wheel_up" then
        if dd.voice_browser_active ~= nil and dd.voice_browser_active() then
            local page_modifier = dd.voice_browser_page_modifier_down(ui.controller)
            local semantic = page_modifier and "page-up" or "up"
            if claim_cross_source_navigation(semantic, "mouse-wheel", source) then dd.voice_browser_wheel(-1, source) end
            diag("input.mouse.wheelTarget", { region = "voice-browser", direction = "up", mode = page_modifier and "page" or "row" })
        else
            local over_details, pointer = dd.mouse_pointer_in_details(pointer_override)
            if over_details then
                dd.scroll_details(-1, "mouse-wheel")
                diag("input.mouse.wheelTarget", { region = "details", direction = "up", referenceX = pointer and pointer.reference_x, referenceY = pointer and pointer.reference_y })
            elseif claim_cross_source_navigation("up", "mouse-wheel", source) then
                dd.move_selection(-1)
            end
        end
    elseif route == "mouse_wheel_down" then
        if dd.voice_browser_active ~= nil and dd.voice_browser_active() then
            local page_modifier = dd.voice_browser_page_modifier_down(ui.controller)
            local semantic = page_modifier and "page-down" or "down"
            if claim_cross_source_navigation(semantic, "mouse-wheel", source) then dd.voice_browser_wheel(1, source) end
            diag("input.mouse.wheelTarget", { region = "voice-browser", direction = "down", mode = page_modifier and "page" or "row" })
        else
            local over_details, pointer = dd.mouse_pointer_in_details(pointer_override)
            if over_details then
                dd.scroll_details(1, "mouse-wheel")
                diag("input.mouse.wheelTarget", { region = "details", direction = "down", referenceX = pointer and pointer.reference_x, referenceY = pointer and pointer.reference_y })
            elseif claim_cross_source_navigation("down", "mouse-wheel", source) then
                dd.move_selection(1)
            end
        end
    end
end

-- Pass 183 broad architecture audit: the proven gameplay/modal isolation implementation
-- is now framework-owned by MortalShell2ModUI.Runtime.ModalIsolation. TTS still owns the
-- session timing that acquires/releases it, preserving the runtime-proven transition/close
-- choreography while future settings providers can reuse the exact same policy implementation.
dd.ModalIsolationFactory = dd.ModUI ~= nil and dd.ModUI.Runtime ~= nil and dd.ModUI.Runtime.ModalIsolation or nil
dd.modal_isolation_load_error = dd.ModalIsolationFactory == nil and "MortalShell2ModUI Runtime.ModalIsolation unavailable" or nil
if dd.ModalIsolationFactory == nil or type(dd.ModalIsolationFactory.New) ~= "function" then
    diag("dependency.modalIsolation", { status = "missing-or-invalid", error = dd.modal_isolation_load_error })
    log("MortalShell2ModUI Runtime.ModalIsolation is missing or invalid. Re-extract both release folders.")
    return
end
dd.modal_isolation, dd.modal_isolation_error = dd.ModalIsolationFactory.New({
    ui = ui,
    config = config,
    ModUI = dd.ModUI,
    unwrap = unwrap,
    valid = valid,
    same_object = dd.native_ui_runtime.SameObject,
    struct_field = dd.struct_field,
    log = log,
    diag = diag,
})
if type(dd.modal_isolation) ~= "table"
    or type(dd.modal_isolation.PauseNativeGameplay) ~= "function"
    or type(dd.modal_isolation.ReleaseNativeGameplayPause) ~= "function"
    or type(dd.modal_isolation.ResolvePlayerAbilitySystem) ~= "function"
    or type(dd.modal_isolation.RemoveNativeModalEffect) ~= "function"
    or type(dd.modal_isolation.ProbeNativeMenuBlocks) ~= "function"
    or type(dd.modal_isolation.RetryPendingNativeModalCleanup) ~= "function"
    or type(dd.modal_isolation.ReleaseNativeModalIsolation) ~= "function"
    or type(dd.modal_isolation.AcquireNativeModalIsolation) ~= "function" then
    diag("dependency.modalIsolation", { status = "init-failed", error = dd.modal_isolation_error })
    log("MortalShell2ModUI Runtime.ModalIsolation could not initialize. Re-extract both release folders.")
    return
end
dd.pause_native_gameplay = dd.modal_isolation.PauseNativeGameplay
dd.release_native_gameplay_pause = dd.modal_isolation.ReleaseNativeGameplayPause
dd.resolve_player_ability_system = dd.modal_isolation.ResolvePlayerAbilitySystem
dd.remove_native_modal_effect = dd.modal_isolation.RemoveNativeModalEffect
dd.probe_native_menu_blocks = dd.modal_isolation.ProbeNativeMenuBlocks
dd.retry_pending_native_modal_cleanup = dd.modal_isolation.RetryPendingNativeModalCleanup
dd.release_native_modal_isolation = dd.modal_isolation.ReleaseNativeModalIsolation
dd.acquire_native_modal_isolation = dd.modal_isolation.AcquireNativeModalIsolation
diag("dependency.modalIsolation", { module = "MortalShell2ModUI.Runtime.ModalIsolation", ownership = "shared-policy+consumer-session-lifetime", status = "ready" })

-- Pass 120 corrective: this helper is defined before the later composition-root
-- `local runtime = _G.MortalShell2TTSRuntime` declaration. Referencing `runtime` here
-- therefore resolves as a global in Lua and was nil in Pass 119 target-game runtime.
-- Resolve the process-retained runtime table explicitly so source order cannot silently
-- turn host semantic delegation into a nil-global dispatch failure again.
-- Pass 163: the healthy path is fully host-semantic. Keep the consumer-local pointer/semantic
-- machinery only as an extracted compatibility fallback instead of carrying another ~600 lines
-- inside the composition root. The module installs the historical dd.* surface verbatim.
dd.SemanticFallback, dd.semantic_fallback_load_error = dd.load_lua_table_module(
    scripts_dir .. "\\Input\\SemanticFallback.lua", "Input.SemanticFallback")
if dd.SemanticFallback == nil or type(dd.SemanticFallback.Install) ~= "function" then
    diag("dependency.semanticFallback", { status = "missing-or-invalid", error = dd.semantic_fallback_load_error })
    log("MortalShell2TTS Input.SemanticFallback module is missing or invalid. Re-extract the release ZIP.")
    return
end
dd.semantic_fallback_install_ok = dd.SemanticFallback.Install({
    dd = dd,
    ui = ui,
    unwrap = unwrap,
    valid = valid,
    same_object = dd.native_ui_runtime.SameObject,
    object_address = dd.native_ui_runtime.ObjectAddress,
    native_controller_is_gamepad = native_controller_is_gamepad,
    native_input_value = native_input_value,
    dispatch_native_controller_route = dispatch_native_controller_route,
    runtime_diagnostics = runtime_diagnostics,
    log = log,
    diag = diag,
    RegisterHook = RegisterHook,
    UnregisterHook = UnregisterHook,
})
if dd.semantic_fallback_install_ok ~= true
    or type(dd.host_native_semantics_active) ~= "function"
    or type(dd.dispatch_modui_host_native_input_event) ~= "function"
    or type(dd.ensure_native_input_hook_runtime) ~= "function"
    or type(dd.native_input_bridge_host_options) ~= "function"
    or type(dd.deactivate_native_input_host) ~= "function"
    or type(dd.reset_native_input_bridge_state) ~= "function" then
    diag("dependency.semanticFallback", { status = "init-failed" })
    log("MortalShell2TTS Input.SemanticFallback module could not initialize. Re-extract the release ZIP.")
    return
end
diag("dependency.semanticFallback", { module = "Input.SemanticFallback", ownership = "consumer-local-failsoft-only", status = "ready" })

local function create_native_input_bridge(player, controller, library, handler)
    player = unwrap(player)
    controller = unwrap(controller)
    library = unwrap(library)
    handler = unwrap(handler)

    diag("input.bridge.begin", {
        player = valid(player) and object_name(player) or "<invalid>",
        controller = valid(controller) and object_name(controller) or "<invalid>",
        handler = valid(handler) and object_name(handler) or "<invalid>",
        sharedHost = true,
        sharedConstruction = true,
    })

    if not valid(player) or not valid(controller) or not valid(library) or not valid(handler) then
        log("native input bridge unavailable: player/controller/library/UI handler was invalid")
        diag("input.bridge.end", { status = "invalid-prerequisite", sharedHost = true, sharedConstruction = true })
        return false
    end

    local listener_class = dd.native_presentation.LoadNativeInputListenerClass()
    if not valid(listener_class) then
        log("native input bridge unavailable: WBP_InputListener class could not be loaded")
        diag("input.bridge.end", { status = "listener-class-unavailable", sharedHost = true, sharedConstruction = true })
        return false
    end

    local listener = nil
    local desired_inputs = {}

    local function cleanup_stage(stage, payload)
        if stage == "cleanup-begin" then
            local reason = type(payload) == "table" and payload.reason or "bridge setup failed"
            diag("input.cleanup.begin", {
                reason = reason,
                listener = valid(listener) and object_name(listener) or "<invalid>",
                sharedHost = true,
                sharedConstruction = true,
            })
        elseif stage == "before-disable" then
            if valid(listener) then
                dd.log_listener_input_handles(listener, "failure-before-cleanup")
                dd.log_handler_active_listeners(handler, listener, "failure-before-cleanup")
            end
        elseif stage == "bindings-disabled" then
            payload = type(payload) == "table" and payload or {}
            if not payload.ok then
                log("native input bridge disable warning SetEnabledState="
                    .. tostring(payload.setEnabledStateOk and "ok" or payload.setEnabledStateError)
                    .. " UnbindInputs="
                    .. tostring(payload.unbindInputsOk and "ok" or payload.unbindInputsError))
            end
            diag("input.cleanup.native", {
                SetEnabledState = payload.setEnabledStateOk and "ok" or tostring(payload.setEnabledStateError),
                UnbindInputs = payload.unbindInputsOk and "ok" or tostring(payload.unbindInputsError),
                sharedRuntime = true,
                sharedHost = true,
                sharedConstruction = true,
            })
            if valid(listener) then
                dd.log_listener_input_handles(listener, "failure-after-unbind")
                dd.log_handler_active_listeners(handler, listener, "failure-after-unbind")
            end
        elseif stage == "accepted-restored" then
            local activation = type(ui.native_bridge_activation) == "table" and ui.native_bridge_activation or {}
            local accepted = type(activation.accepted) == "table" and activation.accepted or {}
            dd.InputBridgeDiagnostics.AcceptedRestore(payload, accepted.original or ui.native_original_accepted_inputs, { sharedHost = true })
        elseif stage == "hook-retired" then
            dd.InputBridgeDiagnostics.HookRetire(payload, "bridge failure cleanup")
        elseif stage == "cleanup-remove" then
            payload = type(payload) == "table" and payload or { ok = false, status = "invalid-result" }
            diag("input.cleanup.remove", {
                status = payload.ok and "ok" or "failed",
                error = payload.error or (payload.ok and nil or payload.status),
                sharedRuntime = true,
                sharedHost = true,
                sharedConstruction = true,
            })
        elseif stage == "cleanup-end" then
            dd.reset_native_input_bridge_state()
            diag("input.cleanup.end", { sharedHost = true, sharedConstruction = true })
        end
    end

    local host_options = dd.native_input_bridge_host_options("settings input bridge", function(stage, payload)
        if stage == "created" then
            payload = type(payload) == "table" and payload or {}
            if payload.ok then
                listener = unwrap(payload.listener)
                ui.native_listener = listener
                ui.native_input_bridge = listener
                ui.native_bridge_lease = nil
                ui.native_bridge_activation = nil
                ui.native_last_source = ""
                ui.native_gamepad_probe_warned = false

                diag("input.bridge.created", {
                    listener = object_name(listener),
                    address = dd.native_ui_runtime.ObjectAddress(listener) or "<unknown>",
                    sharedRuntime = true,
                    sharedHost = true,
                    sharedConstruction = true,
                })

                dd.log_listener_input_handles(listener, "after-create")
                dd.log_listener_delegate_bindings(listener, "standalone-after-create")
                local defaults = type(payload.defaults) == "table" and payload.defaults or {}
                diag("input.listener.defaults", {
                    IgnoreBlockAll = defaults.IgnoreBlockAll,
                    bInvalidate = defaults.bInvalidate,
                    bAutoActivate = defaults.bAutoActivate,
                    bEnabled = defaults.bEnabled,
                    sharedRuntime = true,
                    sharedHost = true,
                    sharedConstruction = true,
                })
            end
        elseif stage == "attached" then
            if type(payload) == "table" and payload.ok and valid(listener) then
                dd.log_listener_input_handles(listener, "after-viewport-construct")
                dd.log_listener_delegate_bindings(listener, "standalone-after-viewport-construct")
            end
        elseif stage == "handler" then
            payload = type(payload) == "table" and payload or {}
            local constructed_handler = unwrap(payload.constructedHandler)
            diag("input.listener.handler", {
                stage = "after-construct-before-override",
                value = valid(constructed_handler) and object_name(constructed_handler) or "<nil>",
                authoritative = object_name(handler),
                same = payload.handlerSame == true,
                error = payload.constructedHandlerError,
                sharedRuntime = true,
                sharedHost = true,
                sharedConstruction = true,
            })

            if payload.status == "already-correct" then
                diag("input.listener.handler", {
                    stage = "manual-override",
                    status = "skipped-native-construct-already-correct",
                    sharedRuntime = true,
                    sharedHost = true,
                    sharedConstruction = true,
                })
            elseif payload.ok then
                diag("input.listener.handler", {
                    stage = "manual-override",
                    status = "ok",
                    sharedRuntime = true,
                    sharedHost = true,
                    sharedConstruction = true,
                })
            else
                diag("input.listener.handler", {
                    stage = "manual-override",
                    status = "failed",
                    error = payload.assignmentError or payload.status,
                    sharedRuntime = true,
                    sharedHost = true,
                    sharedConstruction = true,
                })
            end
        elseif stage == "before-routes" then
            dd.log_handler_active_listeners(handler, listener, "before-route-build")
        elseif stage == "routes" then
            desired_inputs = dd.InputBridgeDiagnostics.ApplyRoutes(payload)
        elseif stage == "accepted" then
            dd.InputBridgeDiagnostics.ApplyAccepted(payload, desired_inputs, type(payload) == "table" and payload.ownedByHost == true)
        elseif stage == "before-hook" then
            dd.log_listener_input_handles(listener, "before-hook-register")
        elseif stage == "hook" then
            dd.InputBridgeDiagnostics.HookRegister(payload)
        elseif stage == "before-bindings" then
            dd.log_handler_active_listeners(handler, listener, "before-enable")
            dd.log_listener_input_handles(listener, "before-enable")
        elseif stage == "bindings" then
            dd.InputBridgeDiagnostics.BindingEnable(payload, listener, handler)
        elseif stage == "activated" then
            ui.native_bridge_activation = payload
        end
    end)
    host_options.zOrder = 9999
    host_options.onCleanupStage = cleanup_stage
    ui.native_bridge_external_hook = host_options.hookExternallyHosted == true
    diag("input.hookRestoration", {
        status = ui.native_bridge_external_hook and "process-wide-mirror-restored" or "local-session-hook",
        pass = 152,
        consumerListener = true,
        processWideHook = ui.native_bridge_external_hook,
        localSessionHook = not ui.native_bridge_external_hook,
        nativeSemantics = "controller+mouse+menu-actions",
        toggleControl = "consumer-open-chord-poll",
    })
    diag("input.hookIsolation", {
        status = ui.native_bridge_external_hook and "restoration-process-wide-mirror" or "restoration-local-session-fallback",
        pass = 150,
        consumerListener = true,
        processWideHook = ui.native_bridge_external_hook,
        localSessionHook = not ui.native_bridge_external_hook,
        toggleControl = "consumer-open-chord-poll",
    })

    local open_result = dd.ModUI.Runtime.InputBridge.OpenSession(
        player,
        controller,
        library,
        listener_class,
        handler,
        host_options
    )
    open_result = type(open_result) == "table" and open_result or { ok = false, status = "invalid-result" }
    listener = unwrap(open_result.listener or listener)

    if not open_result.ok then
        local status = tostring(open_result.status or "failed")
        if status == "create-create-unavailable" then
            log("native input bridge unavailable: WidgetBlueprintLibrary.Create was not exposed")
            diag("input.bridge.end", { status = "create-unavailable", sharedRuntime = true, sharedHost = true, sharedConstruction = true })
        elseif status:find("create-", 1, true) == 1 then
            local create_result = type(open_result.create) == "table" and open_result.create or {}
            log("native input bridge unavailable: WBP_InputListener Create failed: " .. tostring(create_result.error or create_result.status or status))
            diag("input.bridge.end", { status = create_result.status or status, error = create_result.error, sharedRuntime = true, sharedHost = true, sharedConstruction = true })
        elseif status:find("attach-", 1, true) == 1 then
            local attach = type(open_result.attach) == "table" and open_result.attach or {}
            local viewport_error = attach.viewportError or attach.error or attach.status or status
            log("native input bridge unavailable: invisible WBP_InputListener AddToViewport failed: " .. tostring(viewport_error))
        elseif status:find("handler-", 1, true) == 1 then
            log("native input bridge unavailable: UserInterfaceComponent assignment failed")
        elseif status == "activation-routes-empty" or status == "activation-routes-unavailable" or status == "activation-listener-invalid" then
            log("native input bridge unavailable: generic listener exposed no routable menu InputActions")
        elseif status:find("activation-accepted-", 1, true) == 1 then
            log("native input bridge unavailable: AcceptedInputs could not be configured exactly")
        elseif status:find("activation-hook-", 1, true) == 1 then
            log("native input bridge unavailable: InputTriggeredCallback hook did not arm")
        elseif status:find("activation-bindings-", 1, true) == 1 then
            log("native input bridge unavailable: enable and direct BindInputs both failed")
        else
            log("native input bridge unavailable: shared construction host failed: " .. status)
        end
        dd.reset_native_input_bridge_state()
        diag("input.bridge.end", { status = status, sharedRuntime = true, sharedHost = true, sharedConstruction = true })
        return false
    end

    ui.native_bridge_activation = open_result.activation
    ui.native_bridge_lease = type(open_result.lease) == "table" and open_result.lease or nil
    ui.native_bridge_session = type(open_result.session) == "table" and open_result.session or nil
    ui.native_listener_enabled = true

    local enabled_state = "<unknown>"
    local ok_state, state = pcall(function() return unwrap(listener:IsEnabled()) end)
    if ok_state then enabled_state = tostring(state) end

    local handle_count = dd.log_listener_input_handles(listener, "after-enable")
    local expected_handle_count = #desired_inputs * 2
    diag("input.handles.expected", {
        desiredInputs = #desired_inputs,
        expectedIfTriggeredAndCompletedPerInput = expected_handle_count,
        actual = handle_count ~= nil and handle_count or "<unknown>",
        exact = handle_count ~= nil and handle_count == expected_handle_count or false,
        sharedHost = true,
        sharedConstruction = true,
    })

    local active_count, contains_listener = dd.log_handler_active_listeners(handler, listener, "after-enable")
    dd.log_listener_delegate_bindings(listener, "standalone-after-enable")

    diag("input.bridge.end", {
        status = "enabled",
        IsEnabled = enabled_state,
        handleCount = handle_count ~= nil and handle_count or "<unknown>",
        ActiveListenersCount = active_count ~= nil and active_count or "<unknown>",
        ActiveListenersContainsTTS = contains_listener,
        sharedHost = true,
        sharedConstruction = true,
        sharedLeaseHookSpec = type(open_result.lease) == "table" and open_result.lease.hookSpecOwned == true,
        sharedLeaseRouter = true,
        sharedInputBridgeSession = type(open_result.session) == "table" and open_result.session.sharedInputBridgeSession == true,
    })

    log("native input bridge enabled object=" .. object_name(listener)
        .. " IsEnabled=" .. tostring(enabled_state)
        .. " handles=" .. tostring(handle_count or "unknown")
        .. " activeListenersContainsTTS=" .. tostring(contains_listener)
        .. " readerListener=disabled mapping=shared-preserved host=shared-construction")
    if ui.native_bridge_external_hook == true and type(dd.write_modui_host_native_input_request) == "function" then
        pcall(dd.write_modui_host_native_input_request, true, listener, ui.active_generation)
    end
    return true
end

-- Pass 169 extracts the complete Settings session/shell lifecycle. The composition root
-- supplies application/runtime dependencies while UI.SettingsSession owns host/fallback open,
-- close quarantine, shell retirement/cache state, and fail-closed session rollback.
dd.SettingsSessionFactory, dd.settings_session_factory_error = dd.load_lua_table_module(scripts_dir .. "\\UI\\SettingsSession.lua", "UI.SettingsSession")
if dd.SettingsSessionFactory == nil or type(dd.SettingsSessionFactory.Install) ~= "function" then
    dd.settings_session_failure = "module-unavailable: " .. tostring(dd.settings_session_factory_error or "missing API")
else
    local session_ok, session_result, session_error = pcall(dd.SettingsSessionFactory.Install, {
        dd = dd,
        ui = ui,
        config = config,
        version = VERSION,
        unwrap = unwrap,
        valid = valid,
        object_name = object_name,
        diag = diag,
        log = log,
        restore_settings_input = restore_settings_input,
        set_ui_text = set_ui_text,
        create_native_input_bridge = create_native_input_bridge,
        current_tab = current_tab,
        save_config = save_config,
        refresh_voices = refresh_voices,
        runtime_diagnostics = runtime_diagnostics,
        acquire_settings_input = acquire_settings_input,
        schedule_close_finalize = function(delay_ms)
            if schedule_close_finalize == nil then return false end
            return schedule_close_finalize(delay_ms)
        end,
        schedule_shell_cache_expiry = function(delay_ms, token)
            if schedule_shell_cache_expiry == nil then return false end
            return schedule_shell_cache_expiry(delay_ms, token)
        end,
        static_find_object = function(path) return StaticFindObject(path) end,
        close_quarantine_ms = type(dd.ModUI) == "table" and type(dd.ModUI.Settings) == "table"
            and type(dd.ModUI.Settings.CloseGuard) == "table"
            and tonumber(dd.ModUI.Settings.CloseGuard.DELAY_MS) or 225,
        shell_reuse_ms = SHELL_REUSE_MS,
        consumer_native_listener_transition_isolation = false,
        widget_blueprint_library_cdo = "/Script/UMG.Default__WidgetBlueprintLibrary",
    })
    if session_ok and type(session_result) == "table" then
        dd.SettingsSession = session_result
        diag("dependency.settingsSession", {
            module = "UI.SettingsSession", ownership = tostring(session_result.ownership), status = "ready",
        })
    else
        dd.settings_session_failure = tostring(session_ok and session_error or session_result)
    end
end
if dd.SettingsSession == nil then
    dd.toggle_settings_ui = function()
        diag("dependency.settingsSession", {
            module = "UI.SettingsSession", failure = tostring(dd.settings_session_failure), status = "unavailable-core-continues",
        })
        return false
    end
    diag("dependency.settingsSession", {
        module = "UI.SettingsSession", failure = tostring(dd.settings_session_failure), status = "unavailable-core-continues",
    })
end


    return {
        ownership = "tts-settings-interaction-runtime",
        NoteModalKeybind = note_modal_keybind,
        ActiveUISessionValid = active_ui_session_valid,
        ClaimCrossSourceNavigation = claim_cross_source_navigation,
        SetUIText = set_ui_text,
        CreateNativeInputBridge = create_native_input_bridge,
        AcquireSettingsInput = acquire_settings_input,
        RestoreSettingsInput = restore_settings_input,
    }
end

return M
