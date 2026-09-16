-- MortalShell2TTS Settings.Controller
-- Owns non-native Settings value/action orchestration, reset confirmation,
-- selection/tab movement, and row activation/change policy. Native widget/input/
-- modal/pause lifetimes remain in UI.SettingsRuntime and are accessed only through
-- bounded callbacks.

local M = {}

local QUEUE_BEHAVIORS = { "interrupt", "queue", "ignore" }
local DUPLICATE_WINDOWS = { 0, 1, 3, 5, 10 }

local function wrap_index(index, count)
    if count <= 0 then return 0 end
    if index < 1 then return count end
    if index > count then return 1 end
    return index
end

function M.New(options)
    options = options or {}
    local config = assert(options.config, "Settings.Controller requires config")
    local ui = assert(options.ui, "Settings.Controller requires ui")
    local engines = assert(options.engines, "Settings.Controller requires engines")
    local azure_regions = assert(options.azure_regions, "Settings.Controller requires azure_regions")
    local navigation = assert(options.navigation, "Settings.Controller requires navigation")
    local tabs = assert(options.tabs, "Settings.Controller requires tabs")

    local self = {}

    local function call(name, ...)
        local fn = options[name]
        if type(fn) ~= "function" then return nil end
        return fn(...)
    end

    function self.Save(reason)
        local ok = call("save_config")
        if ok then
            call("log", "settings applied: " .. tostring(reason))
            return true
        end
        return false
    end

    function self.CycleVoice(delta)
        call("refresh_voices")
        if #ui.voices == 0 then return end
        local index = wrap_index((tonumber(call("voice_index")) or 1) + delta, #ui.voices)
        local previous_voice = call("active_voice_value")
        call("capture_voice_profile", config.engine, previous_voice)
        local reason
        if config.engine == "azure" then
            config.azure_voice = ui.voices[index].value
            reason = "azure_voice=" .. tostring(config.azure_voice)
        else
            config.voice = ui.voices[index].value
            reason = "voice=" .. tostring(config.voice)
        end
        call("apply_voice_profile", config.engine, call("active_voice_value"))
        call("capture_voice_profile", config.engine, call("active_voice_value"))
        if not self.Save(reason) then
            ui.status = "Unable to save voice setting."
            return
        end
        call("log", "voice setting saved; helper sync deferred until next SPEAK/TEST: " .. tostring(call("active_voice_value")))
        ui.status = "Voice changed to " .. tostring(ui.voices[index].label) .. ". Applies on next speech/test."
    end

    function self.CycleVoiceStyle(delta)
        local styles = call("current_voice_styles") or {}
        if #styles == 0 then
            ui.status = "Voice Style is N/A for this voice. Saved preference retained."
            call("redraw")
            return
        end
        local values = { "default" }
        for _, style in ipairs(styles) do values[#values + 1] = style end
        local current = tostring(call("normalized_voice_style") or "default")
        local index = 1
        for i, value in ipairs(values) do if value:lower() == current:lower() then index = i break end end
        index = wrap_index(index + (delta < 0 and -1 or 1), #values)
        config.voice_style = values[index]
        call("capture_voice_profile", config.engine, call("active_voice_value"))
        call("save_config")
        ui.status = "Voice Style set to " .. (config.voice_style == "default" and "Default" or config.voice_style) .. "."
        call("log", "voice style saved: " .. tostring(config.voice_style))
        call("redraw")
    end

    function self.CycleQueueBehavior(delta)
        local current = tostring(call("normalize_queue_behavior", config.speech_queue_behavior) or "interrupt")
        local index = 1
        for i, value in ipairs(QUEUE_BEHAVIORS) do if value == current then index = i break end end
        index = wrap_index(index + (delta < 0 and -1 or 1), #QUEUE_BEHAVIORS)
        config.speech_queue_behavior = QUEUE_BEHAVIORS[index]
        call("stop_speech", "speech queue behavior changed")
        self.Save("speech_queue=" .. tostring(config.speech_queue_behavior))
        call("diag", "speech.queueMode", { mode = config.speech_queue_behavior })
        if config.speech_queue_behavior == "queue" then
            ui.status = "Speech Queue: queued narration waits in order."
        elseif config.speech_queue_behavior == "ignore" then
            ui.status = "Speech Queue: new narration is ignored while speech is active."
        else
            ui.status = "Speech Queue: new narration interrupts current speech."
        end
    end

    function self.CycleDuplicateWindow(delta)
        local current = tonumber(call("normalize_duplicate_window", config.duplicate_suppression_seconds)) or 0
        local index = 1
        for i, value in ipairs(DUPLICATE_WINDOWS) do if value == current then index = i break end end
        index = wrap_index(index + (delta < 0 and -1 or 1), #DUPLICATE_WINDOWS)
        config.duplicate_suppression_seconds = DUPLICATE_WINDOWS[index]
        call("reset_duplicates")
        self.Save("duplicate_text_seconds=" .. tostring(config.duplicate_suppression_seconds))
        call("diag", "speech.duplicateSetting", { seconds = config.duplicate_suppression_seconds })
        if config.duplicate_suppression_seconds <= 0 then
            ui.status = "Duplicate Text suppression disabled."
        else
            ui.status = "Duplicate Text suppression set to " .. tostring(config.duplicate_suppression_seconds) .. " second(s)."
        end
    end

    function self.CycleEngine(delta)
        local index = wrap_index((tonumber(call("engine_index")) or 1) + delta, #engines)
        call("capture_voice_profile", config.engine, call("active_voice_value"))
        call("stop_speech", "engine changed")
        config.engine = engines[index].value
        ui.voice_catalog_engine = ""
        call("refresh_voices")
        call("apply_voice_profile", config.engine, call("active_voice_value"))
        call("capture_voice_profile", config.engine, call("active_voice_value"))
        if not self.Save("engine=" .. tostring(config.engine)) then
            ui.status = "Unable to save TTS engine setting."
            return
        end
        local helper_synced = call("tts_command", "CONFIG", "") == true
        call("log", "engine setting saved; helper queue cleared; config sync requested=" .. tostring(helper_synced) .. ": " .. tostring(config.engine))
        if config.engine == "azure" then
            ui.status = helper_synced and "Azure streaming selected and synchronized." or "Azure streaming selected. Helper will synchronize on next speech/test."
        else
            ui.status = helper_synced and "Windows Speech selected and synchronized." or "Windows Speech selected. Helper will synchronize on next speech/test."
        end
    end

    function self.CycleAzureRegion(delta)
        local index = wrap_index((tonumber(call("region_index")) or 1) + delta, #azure_regions)
        config.azure_region = azure_regions[index]
        if not self.Save("azure_region=" .. tostring(config.azure_region)) then
            ui.status = "Unable to save Azure region."
            return
        end
        ui.status = "Azure region set to " .. tostring(config.azure_region) .. ". Applies on next speech/test; use Refresh Azure Voices to refresh the catalog now."
    end

    function self.CycleAudioOutput(delta)
        call("refresh_audio_outputs")
        if #ui.audio_outputs == 0 then return end
        local index = wrap_index((tonumber(call("audio_output_index")) or 1) + delta, #ui.audio_outputs)
        config.audio_output = ui.audio_outputs[index].value
        if not self.Save("audio_output=" .. tostring(config.audio_output)) then
            ui.status = "Unable to save audio output setting."
            return
        end
        local helper_synced = call("tts_command", "CONFIG", "") == true
        call("log", "audio output setting saved; config sync requested=" .. tostring(helper_synced) .. ": " .. tostring(config.audio_output))
        ui.status = "Audio output changed to " .. tostring(ui.audio_outputs[index].label)
            .. (helper_synced and " and synchronized." or ". Helper will synchronize on next speech/test.")
    end

    function self.ResetSpeech()
        call("stop_speech", "speech settings reset")
        config.voice = "default"
        config.azure_voice = "en-US-AvaMultilingualNeural"
        config.rate = 0
        config.volume = 100
        config.pitch = 0
        config.voice_style = "default"
        config.favorite_windows_voices = ""
        config.favorite_azure_voices = ""
        config.speech_queue_behavior = "interrupt"
        config.duplicate_suppression_seconds = 0
        config.pronunciation_corrections = true
        call("reset_duplicates")
        call("reset_voice_profiles")
        call("capture_voice_profile", "system_speech", config.voice)
        call("capture_voice_profile", "azure", config.azure_voice)
        call("apply_voice_profile", config.engine, call("active_voice_value"))
        self.Save("reset speech settings")
    end

    function self.ResetEngine()
        call("capture_voice_profile", config.engine, call("active_voice_value"))
        call("stop_speech", "engine settings reset")
        config.engine = "system_speech"
        config.audio_output = "default"
        config.azure_region = "eastus"
        ui.voice_catalog_engine = ""
        call("refresh_voices")
        call("apply_voice_profile", config.engine, call("active_voice_value"))
        call("capture_voice_profile", config.engine, call("active_voice_value"))
        self.Save("reset engine settings")
    end


    function self.ClearResetConfirmation(reason)
        local pending_key = tostring(ui.pending_reset_key or "")
        if pending_key == "" then return false end
        ui.pending_reset_key = ""
        ui.pending_reset_generation = 0
        call("diag", "settings.resetConfirmation", {
            status = "cleared",
            key = pending_key,
            reason = tostring(reason or "cancelled"),
        })
        return true
    end

    function self.ResetMod()
        local was_narration = config.narration
        local was_user_pause = config.pause_game_while_menu_open == true and ui.native_pause_reason == "user-option"
        config.narration = true
        config.read_delay_ms = 0
        config.announce_page_number = false
        config.menu_keybind = "seq:LeftControl>T>T>S"
        config.controller_menu_bind = "Gamepad_LeftThumbstick+Gamepad_RightThumbstick"
        config.modifier_sides_equivalent = true
        config.pause_game_while_menu_open = false
        config.log_performance = false
        config.debug_logging = false
        call("sync_perf", "reset-mod")
        if was_user_pause then
            call("release_native_gameplay_pause", "user-option")
            ui.native_modal_mode = "exact-gameplay-effects-unpaused"
        end
        call("sync_open_bind_labels")
        call("clear_keyboard_open_sequence")
        local _, controller = call("get_player_and_controller")
        call("refresh_binding_conflicts", controller)
        config.panel_opacity = 94
        config.panel_font_size = 22
        call("clear_pending_speech")
        self.Save("reset mod settings")
        local republish_ok = call("republish_modui_host_binding", "reset", "defaults")
        if republish_ok ~= nil and republish_ok ~= true then
            call("diag", "input.hostRegistration", { status = "reset-republish-fallback", reason = tostring(republish_ok) })
        end
        call("apply_ui_style")
        if not was_narration and call("reader_is_open") == true then
            local state = call("read_reader")
            if state ~= nil then call("queue_speech", state.text, state.page, "narration re-enabled") end
        end
    end

    function self.ConfirmReset(reset_key)
        reset_key = tostring(reset_key or "")
        local generation = tonumber(ui.active_generation) or 0
        local label = reset_key == "reset_mod" and "Mod settings"
            or (reset_key == "reset_speech" and "Speech settings"
            or (reset_key == "reset_engine" and "Engine settings" or "Settings"))
        if ui.pending_reset_key == reset_key
            and tonumber(ui.pending_reset_generation) == generation and generation > 0 then
            ui.pending_reset_key = ""
            ui.pending_reset_generation = 0
            call("diag", "settings.resetConfirmation", {
                status = "confirmed",
                key = reset_key,
                generation = generation,
            })
            return true
        end
        self.ClearResetConfirmation("replaced")
        ui.pending_reset_key = reset_key
        ui.pending_reset_generation = generation
        ui.status = label .. " reset armed. Press Confirm again to restore defaults; move away or Back to cancel."
        call("diag", "settings.resetConfirmation", {
            status = "armed",
            key = reset_key,
            generation = generation,
        })
        return false
    end

    function self.ChangeSelected(delta)
        if call("bind_capture_active") == true then return end
        if call("active_session_valid") ~= true then return end
        if call("controller_settings_active") == true then
            call("controller_settings_change", delta)
            return
        end
        if self.ClearResetConfirmation("setting-adjusted") then
            ui.status = "Reset cancelled."
            call("redraw")
            return
        end
        if call("voice_browser_active") == true then
            call("voice_browser_cycle_gender", delta)
            return
        end
        local rows = call("current_rows") or {}
        local row = rows[ui.selected]
        if row == nil then return end

        if row.key == "narration" then
            config.narration = not config.narration
            call("clear_pending_speech")
            self.Save("narration=" .. tostring(config.narration))
            if config.narration then
                if call("reader_is_open") == true then
                    local state = call("read_reader")
                    if state ~= nil then call("queue_speech", state.text, state.page, "narration enabled") end
                end
                ui.status = "Narration enabled."
            else
                call("stop_speech", "narration disabled")
                ui.status = "Narration disabled."
            end
        elseif row.key == "announce_page_number" then
            config.announce_page_number = not config.announce_page_number
            self.Save("announce_page_number=" .. tostring(config.announce_page_number))
            ui.status = "Page-number announcement " .. (config.announce_page_number and "enabled." or "disabled.")
        elseif row.key == "log_performance" then
            config.log_performance = not config.log_performance
            self.Save("log_performance=" .. tostring(config.log_performance))
            call("sync_perf", "setting")
            ui.status = "Performance logging " .. (config.log_performance and "enabled: [PERF] summaries every 10 s." or "disabled.")
        elseif row.key == "debug_logging" then
            config.debug_logging = config.debug_logging ~= true
            self.Save("debug_logging=" .. tostring(config.debug_logging))
            call("diag", "config.runtime", { status = "debug-logging", enabled = config.debug_logging == true })
            ui.status = "Debug logging " .. (config.debug_logging and "enabled: routine DIAG lines go to UE4SS.log." or "disabled: only startup, session and failure events are logged.")
        elseif row.key == "menu_keybind" then
            ui.status = "Press Enter / Cross to record a new keyboard binding."
        elseif row.key == "modifier_sides_equivalent" then
            config.modifier_sides_equivalent = not config.modifier_sides_equivalent
            self.Save("modifier_sides_equivalent=" .. tostring(config.modifier_sides_equivalent))
            call("sync_open_bind_labels")
            call("clear_keyboard_open_sequence")
            local republish_ok = call("republish_modui_host_binding", "modifier-sides", tostring(config.modifier_sides_equivalent))
            if republish_ok ~= nil and republish_ok ~= true then
                call("diag", "input.hostRegistration", { status = "modifier-sides-republish-fallback", reason = tostring(republish_ok) })
            end
            ui.status = config.modifier_sides_equivalent
                and "Modifier matching uses either left or right Ctrl / Shift / Alt."
                or "Modifier matching keeps left and right Ctrl / Shift / Alt separate."
        elseif row.key == "pause_game_while_menu_open" then
            config.pause_game_while_menu_open = not config.pause_game_while_menu_open
            self.Save("pause_game_while_menu_open=" .. tostring(config.pause_game_while_menu_open))
            if config.pause_game_while_menu_open then
                if ui.native_pause_bumped and (tonumber(ui.native_pause_bumps) or 0) > 0 then
                    ui.status = ui.native_pause_reason == "compatibility-fallback"
                        and "Pause enabled. Compatibility pause was already required and remains active with native blockers."
                        or "Pause enabled. Native blockers and game pause are active together."
                else
                    local handler = call("unwrap", ui.native_modal_handler)
                    if call("valid", handler) == true and call("pause_native_gameplay", handler, "user-option") == true then
                        ui.native_modal_mode = "exact-gameplay-effects+user-pause"
                        ui.status = "Pause enabled. Native blockers and game pause are active together."
                    else
                        ui.native_modal_mode = "exact-gameplay-effects-unpaused-pause-request-failed"
                        ui.status = "Pause enabled, but the game pause could not be acquired. Native blockers remain active."
                    end
                end
            else
                if ui.native_pause_reason == "user-option" then
                    call("release_native_gameplay_pause", "user-option")
                    ui.native_modal_mode = "exact-gameplay-effects-unpaused"
                    ui.status = "Pause disabled. Native blockers remain active and the background is live."
                elseif ui.native_pause_reason == "compatibility-fallback" then
                    ui.status = "Pause preference disabled, but compatibility pause remains required for this session."
                else
                    ui.status = "Pause disabled. Native blockers remain active and the background is live."
                end
            end
            call("diag", "modalIsolation.pausePreference", {
                enabled = config.pause_game_while_menu_open == true,
                mode = ui.native_modal_mode,
                pauseReason = ui.native_pause_reason,
                pauseBumps = ui.native_pause_bumps,
            })
        elseif row.key == "controller_menu_bind" then
            ui.status = "Press Enter / Cross to record a new controller binding."
        elseif row.key == "voice" then
            self.CycleVoice(delta < 0 and -1 or 1)
        elseif row.key == "voice_style" then
            self.CycleVoiceStyle(delta)
            return
        elseif row.key == "pitch" then
            if call("current_voice_pitch_supported") ~= true then
                ui.status = "Pitch is not available for this voice."
            else
                local old_value = config.pitch
                config.pitch = navigation.StepValue(old_value, delta, row.step, row.min, row.max)
                if config.pitch ~= old_value then
                    call("capture_voice_profile", config.engine, call("active_voice_value"))
                    call("save_config")
                    ui.status = "Pitch set to " .. (config.pitch > 0 and "+" or "") .. tostring(config.pitch) .. "."
                    call("log", "pitch setting saved; helper sync deferred until next SPEAK/TEST: " .. tostring(config.pitch))
                end
            end
        elseif row.key == "speech_queue_behavior" then
            self.CycleQueueBehavior(delta)
        elseif row.key == "duplicate_suppression_seconds" then
            self.CycleDuplicateWindow(delta)
        elseif row.key == "pronunciation_corrections" then
            config.pronunciation_corrections = not (config.pronunciation_corrections ~= false)
            self.Save("pronunciation_corrections=" .. tostring(config.pronunciation_corrections))
            call("diag", "speech.pronunciationSetting", { enabled = config.pronunciation_corrections == true })
            ui.status = config.pronunciation_corrections
                and "Pronunciation corrections enabled. Applies on next speech/test."
                or "Pronunciation corrections disabled. Original text will be synthesized unchanged."
        elseif row.key == "engine" then
            self.CycleEngine(delta < 0 and -1 or 1)
        elseif row.key == "audio_output" then
            self.CycleAudioOutput(delta < 0 and -1 or 1)
        elseif row.key == "engine_mode" then
            if config.engine == "azure" then
                ui.status = "Azure uses cloud REST synthesis and streams raw PCM directly to the selected Windows playback device."
            else
                ui.status = "Windows Speech is fully local and requires no internet connection."
            end
        elseif row.key == "azure_region" then
            self.CycleAzureRegion(delta < 0 and -1 or 1)
        elseif row.kind == "int" then
            local old_value = config[row.key]
            local new_value = navigation.StepValue(old_value, delta, row.step, row.min, row.max)
            config[row.key] = new_value
            if new_value ~= old_value then
                if row.key == "rate" or row.key == "volume" then call("capture_voice_profile", config.engine, call("active_voice_value")) end
                self.Save(row.key .. "=" .. tostring(new_value))
                if row.key == "panel_opacity" or row.key == "panel_font_size" then
                    call("apply_ui_style")
                elseif row.key == "rate" or row.key == "volume" then
                    call("log", row.key .. " setting saved; helper sync deferred until next SPEAK/TEST: " .. tostring(new_value))
                end
                ui.status = row.label .. " set to " .. tostring(new_value) .. tostring(row.suffix or "")
            end
        end
        call("redraw")
    end

    function self.ActivateSelected()
        if call("bind_capture_active") == true then return end
        if call("active_session_valid") ~= true then return end
        if call("controller_settings_active") == true then
            call("controller_settings_activate")
            return
        end
        if call("voice_browser_active") == true then
            call("voice_browser_activate")
            return
        end
        local rows = call("current_rows") or {}
        local row = rows[ui.selected]
        if row == nil then return end
        if tostring(ui.pending_reset_key or "") ~= "" and ui.pending_reset_key ~= row.key then
            self.ClearResetConfirmation("different-action")
        end

        if row.key == "menu_keybind" then
            call("start_bind_capture", "keyboard")
        elseif row.key == "controller_menu_bind" then
            call("start_bind_capture", "controller")
        elseif row.key == "controller_settings" then
            call("open_controller_settings")
            return
        elseif row.key == "voice" then
            call("open_voice_browser")
            return
        elseif row.key == "test" then
            call("test_voice")
            ui.status = "Playing voice preview..."
        elseif row.key == "reset_mod" then
            if self.ConfirmReset(row.key) then
                self.ResetMod()
                ui.status = "Mod settings restored."
            end
        elseif row.key == "reset_speech" then
            if self.ConfirmReset(row.key) then
                self.ResetSpeech()
                ui.status = "Speech settings restored."
            end
        elseif row.key == "reset_engine" then
            if self.ConfirmReset(row.key) then
                self.ResetEngine()
                ui.status = "Engine settings restored."
            end
        elseif row.key == "azure_key" then
            if call("tts_command", "AZURE_KEY_CLIPBOARD", "") == true then
                ui.status = "Importing Azure key from clipboard. The key never passes through Lua or TTSConfig.ini."
            end
        elseif row.key == "azure_key_clear" then
            if call("tts_command", "AZURE_KEY_CLEAR", "") == true then ui.status = "Clearing stored Azure key..." end
        elseif row.key == "azure_refresh" then
            if call("tts_command", "AZURE_REFRESH", "") == true then ui.status = "Refreshing Azure voice list..." end
        elseif row.key == "engine_help" then
            if config.engine == "azure" then
                ui.status = "Azure: REST streaming starts playback as audio arrives. Key storage uses Windows DPAPI CurrentUser outside the mod folder."
            else
                ui.status = "Windows Speech: System Default uses System.Speech; a specific device uses Windows SAPI audio routing. Fully local/offline."
            end
        elseif row.kind == "engine_info" then
            self.ChangeSelected(1)
            return
        else
            self.ChangeSelected(1)
            return
        end
        call("redraw")
    end

    -- v0.9.262 (user): holding R or L3 on a row for 5 s (ModUI 0.70.0 "reset-row")
    -- restores that one row's default. Each row goes through the same path a manual
    -- change would take, so side effects (helper sync, voice profiles, hotkey
    -- republish, perf/diag switches) stay identical. Action and info rows do nothing.
    function self.ResetSelected(source)
        if call("bind_capture_active") == true then return false end
        if call("active_session_valid") ~= true then return false end
        if call("controller_settings_active") == true or call("voice_browser_active") == true then return false end
        local rows = call("current_rows") or {}
        local row = rows[ui.selected]
        if row == nil then return false end
        local key = tostring(row.key or "")
        local kind = tostring(row.kind or "")
        if kind == "action" or kind == "engine_info" or kind == "azure_key" then return false end
        local defaults = call("defaults")
        if type(defaults) ~= "table" or defaults[key] == nil then return false end
        self.ClearResetConfirmation("row-reset")
        local default_value = defaults[key]
        local current = config[key]
        local label = tostring(row.label or key)
        if key == "voice" then
            default_value = config.engine == "azure" and defaults.azure_voice or defaults.voice
            current = call("active_voice_value")
        end
        if current == default_value then
            ui.status = label .. " is already at its default."
            call("redraw")
            return false
        end

        if kind == "toggle" then
            -- The toggle branch of ChangeSelected flips the value and runs its side effects.
            self.ChangeSelected(1)
        elseif key == "voice" then
            call("capture_voice_profile", config.engine, current)
            if config.engine == "azure" then config.azure_voice = default_value else config.voice = default_value end
            call("apply_voice_profile", config.engine, call("active_voice_value"))
            call("capture_voice_profile", config.engine, call("active_voice_value"))
            self.Save("voice reset")
            ui.status = "Voice reset to the engine default. Applies on next speech/test."
        elseif key == "voice_style" then
            config.voice_style = default_value
            call("capture_voice_profile", config.engine, call("active_voice_value"))
            self.Save("voice_style reset")
            ui.status = "Voice Style reset to Default."
        elseif key == "speech_queue_behavior" then
            config.speech_queue_behavior = default_value
            call("stop_speech", "speech queue behavior reset")
            self.Save("speech_queue reset")
            call("diag", "speech.queueMode", { mode = config.speech_queue_behavior })
            ui.status = "Speech Queue reset: new narration interrupts current speech."
        elseif key == "duplicate_suppression_seconds" then
            config.duplicate_suppression_seconds = default_value
            call("reset_duplicates")
            self.Save("duplicate_text_seconds reset")
            call("diag", "speech.duplicateSetting", { seconds = config.duplicate_suppression_seconds })
            ui.status = "Duplicate Text suppression reset (off)."
        elseif key == "engine" then
            local target = 1
            for index, entry in ipairs(engines) do if entry.value == default_value then target = index end end
            self.CycleEngine(target - (tonumber(call("engine_index")) or 1))
        elseif key == "audio_output" then
            call("refresh_audio_outputs")
            local target = 1
            for index, entry in ipairs(ui.audio_outputs or {}) do if entry.value == default_value then target = index end end
            if #(ui.audio_outputs or {}) == 0 then
                config.audio_output = default_value
                self.Save("audio_output reset")
                ui.status = "Audio output reset to the system default."
            else
                self.CycleAudioOutput(target - (tonumber(call("audio_output_index")) or 1))
            end
        elseif key == "azure_region" then
            local target = 1
            for index, entry in ipairs(azure_regions) do if entry == default_value then target = index end end
            self.CycleAzureRegion(target - (tonumber(call("region_index")) or 1))
        elseif key == "menu_keybind" or key == "controller_menu_bind" then
            config[key] = default_value
            call("sync_open_bind_labels")
            call("clear_keyboard_open_sequence")
            local _, controller = call("get_player_and_controller")
            call("refresh_binding_conflicts", controller)
            self.Save(key .. " reset")
            local republish_ok = call("republish_modui_host_binding", "reset-row", default_value)
            if republish_ok ~= nil and republish_ok ~= true then
                call("diag", "input.hostRegistration", { status = "reset-row-republish-fallback", reason = tostring(republish_ok) })
            end
            ui.status = label .. " reset to the default binding."
        elseif kind == "int" or kind == "pitch" then
            config[key] = default_value
            if key == "rate" or key == "volume" or key == "pitch" then
                call("capture_voice_profile", config.engine, call("active_voice_value"))
            end
            self.Save(key .. " reset")
            if key == "panel_opacity" or key == "panel_font_size" then call("apply_ui_style") end
            ui.status = label .. " reset to " .. tostring(default_value) .. tostring(row.suffix or "") .. "."
        else
            return false
        end
        call("diag", "settings.rowReset", { key = key, source = tostring(source or "hold"), value = tostring(config[key]) })
        call("redraw")
        return true
    end

    function self.MoveSelection(delta)
        self.ClearResetConfirmation("selection-moved")
        if call("bind_capture_active") == true then return end
        if call("active_session_valid") ~= true then return end
        if call("controller_settings_active") == true then
            call("controller_settings_move", delta)
            return
        end
        if call("voice_browser_active") == true then
            call("voice_browser_move", delta)
            return
        end
        local rows = call("current_rows") or {}
        ui.selected = navigation.MoveSelection(ui.selected, delta, #rows)
        ui.selected_by_tab[ui.tab] = ui.selected
        ui.status = ""
        call("redraw")
    end

    function self.ChangeTab(delta)
        self.ClearResetConfirmation("tab-changed")
        if call("bind_capture_active") == true then return end
        if call("active_session_valid") ~= true then return end
        if call("controller_settings_active") == true then return end
        if call("voice_browser_active") == true then return end
        ui.selected_by_tab[ui.tab] = ui.selected
        ui.tab = navigation.MoveTab(ui.tab, delta, #tabs)
        local rows = call("current_rows") or {}
        ui.selected = navigation.NormalizeSelection(ui.selected_by_tab[ui.tab] or 1, #rows)
        ui.status = ""
        call("redraw")
        local tab = call("current_tab")
        call("log", "settings tab=" .. tostring(type(tab) == "table" and tab.key or "<unknown>"))
    end

    return self
end

return M
