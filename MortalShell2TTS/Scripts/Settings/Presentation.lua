-- MortalShell2TTS Settings.Presentation
-- Owns TTS-specific row/value text and passive Settings/Voice Browser presentation.
-- Native widget creation, mutation, layout tuning and input remain host-owned.

local M = {}

function M.New(options)
    options = options or {}
    local config = assert(options.config, "Settings.Presentation requires config")
    local ui = assert(options.ui, "Settings.Presentation requires ui")
    local tabs = assert(options.tabs, "Settings.Presentation requires tabs")
    local descriptions = assert(options.descriptions, "Settings.Presentation requires descriptions")
    local model = assert(options.model, "Settings.Presentation requires model")
    local render = assert(options.render, "Settings.Presentation requires render")
    local text = assert(options.text, "Settings.Presentation requires text")
    local trim = assert(options.trim, "Settings.Presentation requires trim")
    local valid = assert(options.valid, "Settings.Presentation requires valid")
    local bar = assert(text.ProgressBar, "Settings.Presentation requires ProgressBar")
    local ellipsize = assert(text.Ellipsize, "Settings.Presentation requires Ellipsize")

    local self = {}
    local function call(name, ...)
        local fn = options[name]
        if type(fn) ~= "function" then return nil end
        return fn(...)
    end

    function self.Ellipsize(value, limit)
        return ellipsize(tostring(value or ""), limit)
    end

    function self.VoiceBrowserActive()
        local state = options.voice_browser
        return type(state) == "table" and state.active == true
    end

    function self.ControllerSettingsActive()
        return call("controller_settings_active") == true
    end

    function self.CurrentTab()
        return model.CurrentTab(tabs, ui.tab)
    end

    function self.CurrentRows()
        if self.ControllerSettingsActive() then return call("controller_settings_rows") or {} end
        if self.VoiceBrowserActive() then return call("voice_browser_rows") or {} end
        return model.RowsForTab(tabs, ui.tab)
    end

    function self.RowDescription(row)
        if self.ControllerSettingsActive() then return tostring(call("controller_settings_description", row) or "") end
        return model.RowDescription(tabs, ui.tab, row, descriptions)
    end

    function self.RowControlHint(row)
        if row == nil then return "" end
        if self.ControllerSettingsActive() then return tostring(call("controller_settings_control_hint", row) or "") end
        if (row.key == "reset_mod" or row.key == "reset_speech" or row.key == "reset_engine")
            and tostring(ui.pending_reset_key or "") == tostring(row.key or "") then
            return "Confirm / Enter / Cross / click value again: restore defaults; move away / Back: cancel"
        end
        if row.key == "menu_keybind" or row.key == "controller_menu_bind" then
            local kind = row.key == "menu_keybind" and "keyboard" or "controller"
            if call("bind_capture_active", kind) == true then
                return "Press combination, then release all controls to save. Esc / Circle alone: cancel"
            end
            -- v0.9.263 (user, pre-release): the "Hold R / L3 5 s: default binding" half of
            -- this hint is gone. She tested the hold in TTS and in the minimap and it reset
            -- nothing in either. The ResetSelected path below is still wired and still
            -- correct; what is unproven is whether ModUI's hold detector ever publishes
            -- "reset-row" (R reaches the minimap as menu-back, and the L3 FKey name has
            -- never been verified). A hint is a promise, so it waits for the fix.
            return "Confirm / Enter / Cross / click value: record a new binding"
        end
        if row.key == "voice" then return "Left/Right or mouse <: previous; value/right: next; Enter/Cross: open voice browser" end
        if row.key == "voice_style" then return "Left/Right or mouse <: previous; value/right: next style" end
        if row.key == "pitch" then return "Left/Right or mouse <: decrease; value/right: increase pitch" end
        if row.key == "speech_queue_behavior" or row.key == "duplicate_suppression_seconds" then return "Left/Right or mouse <: previous; value/right: next" end
        if row.kind == "action" or row.key == "azure_key" then return "Confirm / Enter / click value: activate" end
        if row.kind == "engine_info" then return "Confirm / Enter / click value: details" end
        -- v0.9.262: one hint for every adjustable row.
        -- v0.9.263 (user, pre-release): the hold half is cut here too, same reason as above.
        return "Left/Right or mouse <: previous; value/right: next"
    end

    function self.RowValue(row)
        if self.ControllerSettingsActive() then return tostring(call("controller_settings_value", row) or "") end
        if row.key == "narration" then
            return config.narration and "On" or "Off"
        elseif row.key == "read_delay_ms" then
            return tostring(config.read_delay_ms) .. " ms"
        elseif row.key == "announce_page_number" then
            return config.announce_page_number and "On" or "Off"
        elseif row.key == "log_performance" then
            return config.log_performance and "On" or "Off"
        elseif row.key == "debug_logging" then
            return config.debug_logging and "On" or "Off"
        elseif row.key == "menu_keybind" then
            if call("bind_capture_active", "keyboard") == true then return "Recording..." end
            return tostring(call("keyboard_open_label") or "")
        elseif row.key == "modifier_sides_equivalent" then
            return config.modifier_sides_equivalent and "Any Side" or "Separate"
        elseif row.key == "pause_game_while_menu_open" then
            return config.pause_game_while_menu_open and "On" or "Off"
        elseif row.key == "controller_menu_bind" then
            if call("bind_capture_active", "controller") == true then return "Recording..." end
            return tostring(call("controller_open_label") or "")
        elseif row.key == "controller_settings" then
            return "Open"
        elseif row.key == "panel_opacity" then
            return string.format("%d%%  %s", config.panel_opacity, bar(config.panel_opacity, 50, 100, 12))
        elseif row.key == "panel_font_size" then
            return tostring(config.panel_font_size) .. " px"
        elseif row.key == "voice" then
            return tostring(call("current_voice_label") or "")
        elseif row.key == "voice_style" then
            return tostring(call("voice_style_label") or "")
        elseif row.key == "rate" then
            return string.format("%d  %s", config.rate, bar(config.rate, -10, 10, 16))
        elseif row.key == "pitch" then
            if call("current_voice_pitch_supported") ~= true then return "N/A" end
            return (config.pitch > 0 and "+" or "") .. tostring(config.pitch)
        elseif row.key == "volume" then
            return string.format("%d%%  %s", config.volume, bar(config.volume, 0, 100, 16))
        elseif row.key == "speech_queue_behavior" then
            local mode = tostring(call("normalize_queue_behavior", config.speech_queue_behavior) or "interrupt")
            if mode == "queue" then return "Queue" end
            if mode == "ignore" then return "Ignore While Speaking" end
            return "Interrupt"
        elseif row.key == "duplicate_suppression_seconds" then
            local seconds = tonumber(call("normalize_duplicate_window", config.duplicate_suppression_seconds)) or 0
            return seconds <= 0 and "Off" or (tostring(seconds) .. (seconds == 1 and " sec" or " secs"))
        elseif row.key == "pronunciation_corrections" then
            return config.pronunciation_corrections ~= false and "On" or "Off"
        elseif row.key == "engine" then
            return tostring(call("engine_current_label") or "")
        elseif row.key == "audio_output" then
            return tostring(call("current_audio_output_label") or "")
        elseif row.key == "engine_mode" then
            local engine = call("engine_current")
            if config.engine == "azure" then
                call("refresh_engine_status")
                if ui.azure_key_status == "missing" then return "Cloud / Streaming - Azure key required" end
                if ui.azure_ready then
                    local count = tonumber(ui.azure_voice_count) or 0
                    if count > 0 then return string.format("Cloud / Streaming - Ready (%d voices)", count) end
                    return "Cloud / Streaming - Ready"
                end
                return "Cloud / Streaming - Azure key stored"
            end
            return type(engine) == "table" and engine.mode or "Unknown"
        elseif row.key == "azure_region" then
            return tostring(config.azure_region)
        elseif row.key == "azure_key" then
            call("refresh_engine_status")
            if ui.azure_key_status == "dpapi" then return "Stored (Windows DPAPI) - Enter to replace" end
            if ui.azure_key_status == "environment" then return "Environment variable" end
            return "Not configured - Enter to import clipboard"
        elseif (row.key == "reset_mod" or row.key == "reset_speech" or row.key == "reset_engine")
            and tostring(ui.pending_reset_key or "") == tostring(row.key or "") then
            return "Confirm again"
        elseif row.kind == "action" then
            return "Press Enter"
        end
        return ""
    end

    function self.RowDisplayLabel(row)
        if self.ControllerSettingsActive() then return tostring(call("controller_settings_label", row) or row.label or "") end
        if row.kind == "voice_browser" and row.voice ~= nil then
            local marker = call("is_voice_favorite", row.voice.value) == true and "* " or "  "
            return marker .. ellipsize(tostring(row.voice.label or row.voice.value), 23)
        elseif row.kind == "voice_browser_empty" then
            return "No voices match"
        end
        if row.key == "reset_mod" then return "Reset Mod" end
        if row.key == "reset_speech" then return "Reset Speech" end
        if row.key == "reset_engine" then return "Reset Engine" end
        if row.key == "azure_refresh" then return "Refresh Voices" end
        return tostring(row.label or "")
    end

    function self.RowDisplayValue(row)
        if self.ControllerSettingsActive() then return tostring(call("controller_settings_value", row) or "") end
        if row.kind == "voice_browser" and row.voice ~= nil then
            local state = options.voice_browser or {}
            local selected = tostring(state.chosen or ""):lower() == tostring(row.voice.value or ""):lower()
            local meta = trim(tostring(row.voice.gender or ""))
            if trim(tostring(row.voice.locale or "")) ~= "" then meta = (meta ~= "" and (meta .. " ") or "") .. tostring(row.voice.locale) end
            if selected then meta = "Selected" .. (meta ~= "" and (" | " .. meta) or "") end
            return ellipsize(meta ~= "" and meta or "Voice", 24)
        elseif row.kind == "voice_browser_empty" then
            return "Adjust search/filter"
        end
        if row.key == "menu_keybind" then
            if call("bind_capture_active", "keyboard") == true then return "Recording..." end
            local label = tostring(call("keyboard_open_label") or "")
            local badge = tostring(call("binding_conflict_badge", "keyboard") or "")
            if badge ~= "" then return ellipsize(label, 18) .. badge end
            return label
        elseif row.key == "controller_menu_bind" then
            if call("bind_capture_active", "controller") == true then return "Recording..." end
            local label = tostring(call("controller_open_label") or "")
            local badge = tostring(call("binding_conflict_badge", "controller") or "")
            if badge ~= "" then return ellipsize(label, 18) .. badge end
            return label
        elseif row.key == "panel_opacity" then
            return string.format("%d%%", config.panel_opacity)
        elseif row.key == "voice_style" then
            return ellipsize(tostring(call("voice_style_label") or ""), 18)
        elseif row.key == "rate" then
            return tostring(config.rate)
        elseif row.key == "pitch" then
            if call("current_voice_pitch_supported") ~= true then return "N/A" end
            return (config.pitch > 0 and "+" or "") .. tostring(config.pitch)
        elseif row.key == "volume" then
            return string.format("%d%%", config.volume)
        elseif row.key == "speech_queue_behavior" then
            local mode = tostring(call("normalize_queue_behavior", config.speech_queue_behavior) or "interrupt")
            if mode == "queue" then return "Queue" end
            if mode == "ignore" then return "Ignore" end
            return "Interrupt"
        elseif row.key == "duplicate_suppression_seconds" then
            local seconds = tonumber(call("normalize_duplicate_window", config.duplicate_suppression_seconds)) or 0
            return seconds <= 0 and "Off" or (tostring(seconds) .. "s")
        elseif row.key == "pronunciation_corrections" then
            return config.pronunciation_corrections ~= false and "On" or "Off"
        elseif row.key == "voice" then
            return ellipsize(tostring(call("current_voice_label") or ""), 20)
        elseif row.key == "engine" then
            return config.engine == "azure" and "Azure" or "Windows"
        elseif row.key == "audio_output" then
            local label = tostring(call("current_audio_output_label") or "")
            local short = label:match("^(.-)%s*%b()$")
            if short ~= nil and trim(short) ~= "" then label = trim(short) end
            label = label:gsub("%s+[Ii]nput$", "")
            return ellipsize(label, 16)
        elseif row.key == "engine_mode" then
            return config.engine == "azure" and "Cloud" or "Local"
        elseif row.key == "azure_key" then
            call("refresh_engine_status")
            if ui.azure_key_status == "dpapi" then return "Stored" end
            if ui.azure_key_status == "environment" then return "Environment" end
            return "Not configured"
        elseif (row.key == "reset_mod" or row.key == "reset_speech" or row.key == "reset_engine")
            and tostring(ui.pending_reset_key or "") == tostring(row.key or "") then
            return "Confirm again"
        elseif row.kind == "action" then
            return "Enter"
        end
        return ellipsize(self.RowValue(row), 24)
    end

    function self.TabText()
        if self.ControllerSettingsActive() then return tostring(call("controller_settings_tab") or "[ CONTROLLER SETTINGS ]") end
        if self.VoiceBrowserActive() then
            local state = options.voice_browser
            local query = trim(state.query)
            if query == "" then query = "<type to search>" end
            local total = #state.filtered
            local page_size = math.max(1, tonumber(state.page_size) or 10)
            local page_count = total > 0 and math.ceil(total / page_size) or 0
            local page_number = total > 0 and (math.floor((math.max(1, tonumber(state.offset) or 1) - 1) / page_size) + 1) or 0
            local range_first = total > 0 and math.max(1, tonumber(state.offset) or 1) or 0
            local range_last = total > 0 and math.min(total, range_first + page_size - 1) or 0
            return "[ VOICE BROWSER ]    Search: " .. ellipsize(query, 16)
                .. "    Gender: " .. tostring(state.gender)
                .. "    Page " .. tostring(page_number) .. "/" .. tostring(page_count)
                .. " (" .. tostring(range_first) .. "-" .. tostring(range_last) .. "/" .. tostring(total) .. ")"
        end
        return text.TabStrip(tabs, ui.tab)
    end

    function self.HeaderText()
        if self.ControllerSettingsActive() then return tostring(call("controller_settings_header") or "MORTAL SHELL 2 MOD UI - CONTROLLER") end
        return "TEXT TO SPEECH SETTINGS"
    end

    function self.PageText()
        if self.ControllerSettingsActive() then return tostring(call("controller_settings_page") or "") end
        if self.VoiceBrowserActive() then
            local state = options.voice_browser or {}
            local total = #(state.filtered or {})
            local page_size = math.max(1, tonumber(state.page_size) or 10)
            local page_count = total > 0 and math.ceil(total / page_size) or 0
            local page_number = total > 0 and (math.floor((math.max(1, tonumber(state.offset) or 1) - 1) / page_size) + 1) or 0
            return tostring(page_number) .. "/" .. tostring(page_count)
        end
        return string.format("%02d/%02d", tonumber(ui.tab) or 1, #tabs)
    end

    function self.LabelsText()
        return render.Labels(self.CurrentRows(), ui.selected, function(row) return self.RowDisplayLabel(row) end)
    end

    function self.ValuesText()
        return render.Values(self.CurrentRows(), ui.selected, function(row) return self.RowDisplayValue(row) end, function(row)
            return row ~= nil and (row.kind == "action" or row.key == "azure_key")
        end)
    end

    function self.CombinedText()
        return render.Combined(self.TabText(), self.CurrentRows(), ui.selected, function(row) return self.RowDisplayLabel(row) end, function(row) return self.RowDisplayValue(row) end)
    end

    function self.PlainText()
        if ui.presentation_mode == "rails"
            and valid(ui.native_tabs_widget) and valid(ui.native_tabs_text)
            and valid(ui.native_labels_widget) and valid(ui.native_labels_text)
            and valid(ui.native_values_widget) and valid(ui.native_values_text) then
            return ""
        end
        return self.CombinedText()
    end

    return self
end

return M
