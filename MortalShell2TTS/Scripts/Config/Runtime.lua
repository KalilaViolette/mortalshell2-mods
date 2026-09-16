-- MortalShell2TTS Config.Runtime
-- Bounded persisted-config lifecycle orchestration extracted from main.lua.
-- Owns recognized-key parsing, fail-soft backup selection, legacy bind migration,
-- deterministic sanitization dispatch, and complete-snapshot save orchestration.
-- Unreal/runtime state, voice-profile ownership, helper commands, and file mechanics
-- remain outside this module and are supplied explicitly as dependencies.

local Runtime = {}

local function require_table(value, name)
    if type(value) ~= "table" then
        error(tostring(name or "dependency") .. " must be a table", 3)
    end
    return value
end

local function call_log(options, message)
    if type(options.log) == "function" then
        options.log(message)
    end
end

function Runtime.Sanitize(config, value_helpers, sanitize)
    config = require_table(config, "config")
    value_helpers = require_table(value_helpers, "value_helpers")
    sanitize = require_table(sanitize, "sanitize")

    local clamp = assert(value_helpers.Clamp, "Value.Clamp is required")
    local sanitize_text = assert(sanitize.Text, "Config.Sanitize.Text is required")
    local sanitize_binding = assert(sanitize.Binding, "Config.Sanitize.Binding is required")
    local sanitize_favorites = assert(sanitize.Favorites, "Config.Sanitize.Favorites is required")
    local normalize_queue = assert(sanitize.QueueBehavior, "Config.Sanitize.QueueBehavior is required")
    local normalize_duplicate = assert(sanitize.DuplicateWindow, "Config.Sanitize.DuplicateWindow is required")

    config.read_delay_ms = clamp(math.floor((tonumber(config.read_delay_ms) or 0) + 0.5), 0, 3000)
    config.panel_opacity = clamp(math.floor((tonumber(config.panel_opacity) or 94) + 0.5), 50, 100)
    config.panel_font_size = clamp(math.floor((tonumber(config.panel_font_size) or 22) + 0.5), 16, 30)
    config.rate = clamp(math.floor((tonumber(config.rate) or 0) + 0.5), -10, 10)
    config.volume = clamp(math.floor((tonumber(config.volume) or 100) + 0.5), 0, 100)
    config.pitch = clamp(math.floor((tonumber(config.pitch) or 0) + 0.5), -6, 6)
    config.voice_style = sanitize_text(config.voice_style, "default", 96)
    config.voice = sanitize_text(config.voice, "default", 384)
    config.azure_voice = sanitize_text(config.azure_voice, "en-US-AvaMultilingualNeural", 384)
    config.audio_output = sanitize_text(config.audio_output, "default", 512)
    config.azure_region = sanitize_text(config.azure_region, "eastus", 64):lower()
    if config.azure_region:match("^[%w%-]+$") == nil then config.azure_region = "eastus" end
    config.favorite_windows_voices = sanitize_favorites(config.favorite_windows_voices)
    config.favorite_azure_voices = sanitize_favorites(config.favorite_azure_voices)
    config.speech_queue_behavior = normalize_queue(config.speech_queue_behavior)
    config.duplicate_suppression_seconds = normalize_duplicate(config.duplicate_suppression_seconds)
    config.pronunciation_corrections = config.pronunciation_corrections ~= false
    config.menu_keybind = sanitize_binding(config.menu_keybind, "seq:LeftControl>T>T>S", false)
    config.controller_menu_bind = sanitize_binding(config.controller_menu_bind, "Gamepad_LeftThumbstick+Gamepad_RightThumbstick", true)
    config.modifier_sides_equivalent = config.modifier_sides_equivalent ~= false
    config.pause_game_while_menu_open = config.pause_game_while_menu_open == true
    config.log_performance = config.log_performance == true
    config.debug_logging = config.debug_logging == true
    return config
end

function Runtime.Load(config, options)
    config = require_table(config, "config")
    options = require_table(options, "options")
    local read_file = assert(options.read_file, "read_file is required")
    local write_file_atomic = assert(options.write_file_atomic, "write_file_atomic is required")
    local snapshot_valid = assert(options.snapshot_valid, "snapshot_valid is required")
    local trim = assert(options.trim, "trim is required")
    local bool_from_string = assert(options.bool_from_string, "bool_from_string is required")
    local clamp = assert(options.clamp, "clamp is required")
    local config_path = assert(options.config_path, "config_path is required")

    local load_source = "defaults"
    local loaded_schema = 1
    local content, content_read_reason = read_file(config_path, 1024 * 1024)
    local current_valid, current_reason = snapshot_valid(content)
    if content_read_reason == "oversized" then current_reason = "oversized" end
    if current_valid then load_source = "current" end
    if not current_valid then
        local backup, backup_read_reason = read_file(config_path .. ".bak", 1024 * 1024)
        local backup_valid, backup_reason = snapshot_valid(backup)
        if backup_read_reason == "oversized" then backup_valid, backup_reason = false, "oversized" end
        if backup_valid then
            content = backup
            load_source = "backup"
            call_log(options, "recovering TTSConfig.ini from last-known-good backup; current=" .. tostring(current_reason))
            write_file_atomic(config_path, backup)
        elseif content ~= nil then
            load_source = "current-failsoft"
            call_log(options, "configured TTSConfig.ini snapshot is " .. tostring(current_reason) .. "; parsing fail-soft defaults/recognized values")
        elseif content_read_reason == "oversized" then
            call_log(options, "configured TTSConfig.ini exceeds the 1 MB safety limit and no valid backup is available; using defaults")
        elseif backup_read_reason == "oversized" then
            call_log(options, "last-known-good TTSConfig.ini.bak exceeds the 1 MB safety limit; using defaults")
        elseif backup ~= nil and not backup_valid then
            call_log(options, "last-known-good TTSConfig.ini.bak rejected reason=" .. tostring(backup_reason))
        end
    end
    if content == nil then return false, "defaults", 1 end

    for raw_line in content:gmatch("[^\r\n]+") do
        local line = trim(raw_line)
        if line ~= "" and line:sub(1, 1) ~= ";" and line:sub(1, 1) ~= "#" and line:sub(1, 1) ~= "[" then
            local key, value = line:match("^([^=]+)=(.*)$")
            if key ~= nil then
                key = trim(key):lower()
                value = trim(value)
                if key == "narration" or key == "narrationenabled" then
                    config.narration = bool_from_string(value, config.narration)
                elseif key == "readdelayms" or key == "delaybeforereadingms" then
                    config.read_delay_ms = clamp(math.floor((tonumber(value) or config.read_delay_ms) + 0.5), 0, 3000)
                elseif key == "announcepagenumber" then
                    config.announce_page_number = bool_from_string(value, config.announce_page_number)
                elseif key == "logperformance" then
                    config.log_performance = bool_from_string(value, config.log_performance)
                elseif key == "debuglogging" or key == "debuglog" then
                    config.debug_logging = bool_from_string(value, config.debug_logging)
                elseif key == "menukeybind" or key == "openkeybind" then
                    config.menu_keybind = value ~= "" and value or "seq:LeftControl>T>T>S"
                elseif key == "controllermenubind" or key == "controlleropenbind" then
                    config.controller_menu_bind = value ~= "" and value or "Gamepad_LeftThumbstick+Gamepad_RightThumbstick"
                elseif key == "matchmodifiersides" or key == "modifieranyside" or key == "unifiedmodifiers" then
                    config.modifier_sides_equivalent = bool_from_string(value, config.modifier_sides_equivalent)
                elseif key == "pausegamewhilemenuopen" or key == "pausegamewithmenu" or key == "pausewithmenu" then
                    config.pause_game_while_menu_open = bool_from_string(value, config.pause_game_while_menu_open)
                elseif key == "panelopacity" then
                    config.panel_opacity = clamp(math.floor((tonumber(value) or config.panel_opacity) + 0.5), 50, 100)
                elseif key == "panelfontsize" then
                    config.panel_font_size = clamp(math.floor((tonumber(value) or config.panel_font_size) + 0.5), 16, 30)
                elseif key == "voice" or key == "voicename" then
                    config.voice = value ~= "" and value or "default"
                elseif key == "azurevoice" then
                    config.azure_voice = value ~= "" and value or config.azure_voice
                elseif key == "rate" then
                    config.rate = clamp(math.floor((tonumber(value) or config.rate) + 0.5), -10, 10)
                elseif key == "volume" then
                    config.volume = clamp(math.floor((tonumber(value) or config.volume) + 0.5), 0, 100)
                elseif key == "pitch" then
                    config.pitch = clamp(math.floor((tonumber(value) or config.pitch) + 0.5), -6, 6)
                elseif key == "voicestyle" then
                    config.voice_style = value ~= "" and value or "default"
                elseif key == "favoritewindowsvoices" then
                    config.favorite_windows_voices = value
                elseif key == "favoriteazurevoices" then
                    config.favorite_azure_voices = value
                elseif key == "speechqueue" or key == "speechqueuebehavior" then
                    config.speech_queue_behavior = options.sanitize.QueueBehavior(value)
                elseif key == "duplicatetextseconds" or key == "duplicatesuppressionseconds" then
                    config.duplicate_suppression_seconds = options.sanitize.DuplicateWindow(value)
                elseif key == "pronunciationcorrections" or key == "pronunciation" then
                    config.pronunciation_corrections = bool_from_string(value, config.pronunciation_corrections)
                elseif key == "voiceprofiles" then
                    config.voice_profiles = value
                elseif key == "configschema" then
                    config.config_schema = math.max(1, math.floor((tonumber(value) or 1) + 0.5))
                elseif key == "engine" then
                    config.engine = value ~= "" and value:lower() or "system_speech"
                elseif key == "audiooutput" then
                    config.audio_output = value ~= "" and value or "default"
                elseif key == "azureregion" then
                    config.azure_region = value ~= "" and value:lower() or "eastus"
                end
            end
        end
    end

    if config.voice:lower() == "auto" then config.voice = "default" end
    if config.engine ~= "system_speech" and config.engine ~= "azure" then
        call_log(options, "unknown configured TTS engine '" .. tostring(config.engine) .. "'; falling back to system_speech")
        config.engine = "system_speech"
    end
    if trim(config.audio_output) == "" then config.audio_output = "default" end

    local legacy_keyboard = {
        ctrl_del = "LeftControl+Delete",
        ctrl_home = "LeftControl+Home",
        ctrl_end = "LeftControl+End",
        ctrl_insert = "LeftControl+Insert",
        ctrl_pageup = "LeftControl+PageUp",
        ctrl_pagedown = "LeftControl+PageDown",
    }
    local keyboard_value = trim(config.menu_keybind)
    config.menu_keybind = legacy_keyboard[keyboard_value:lower()] or keyboard_value
    if config.menu_keybind == "" then config.menu_keybind = "seq:LeftControl>T>T>S" end

    local legacy_controller = {
        l3_r3 = "Gamepad_LeftThumbstick+Gamepad_RightThumbstick",
        l3_dpad_up = "Gamepad_LeftThumbstick+Gamepad_DPad_Up",
        l3_dpad_down = "Gamepad_LeftThumbstick+Gamepad_DPad_Down",
        l3_dpad_left = "Gamepad_LeftThumbstick+Gamepad_DPad_Left",
        l3_dpad_right = "Gamepad_LeftThumbstick+Gamepad_DPad_Right",
        off = "off",
    }
    local controller_value = trim(config.controller_menu_bind)
    config.controller_menu_bind = legacy_controller[controller_value:lower()] or controller_value

    Runtime.Sanitize(config, options.value_helpers, options.sanitize)
    loaded_schema = tonumber(config.config_schema) or 1
    return true, load_source, loaded_schema
end

function Runtime.Save(config, options)
    config = require_table(config, "config")
    options = require_table(options, "options")
    Runtime.Sanitize(config, options.value_helpers, options.sanitize)
    local content = options.codec.Serialize(
        config,
        options.schema,
        options.serialize_voice_profiles(),
        options.sanitize.QueueBehavior(config.speech_queue_behavior),
        options.sanitize.DuplicateWindow(config.duplicate_suppression_seconds)
    )
    return options.write_config_atomic(options.config_path, content)
end

return Runtime
