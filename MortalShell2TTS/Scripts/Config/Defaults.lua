-- MortalShell2TTS configuration defaults factory.
-- TTS-specific persisted defaults only; no file IO, migration, hooks, or runtime ownership.

local Defaults = {}

function Defaults.New()
    return {
        narration = true,
        read_delay_ms = 0,
        announce_page_number = false,
        menu_keybind = "seq:LeftControl>T>T>S",
        controller_menu_bind = "Gamepad_LeftThumbstick+Gamepad_RightThumbstick",
        modifier_sides_equivalent = true,
        pause_game_while_menu_open = false,
        -- [PERF] summaries every 10 s (Core/Perf.lua). Off is free. Also switches the
        -- shared ModUI host's logging on. PERFORMANCE_LOGGING.md.
        log_performance = false,
        -- v0.9.262 (user): DIAG lines for routine events (menu input, redraws, helper
        -- chatter) only while this is on. Release-evidence and abnormal events always
        -- log, so a support bundle still has the startup/session/failure record.
        debug_logging = false,
        panel_opacity = 94,
        panel_font_size = 22,
        voice = "default",
        azure_voice = "en-US-AvaMultilingualNeural",
        rate = 0,
        volume = 100,
        pitch = 0,
        voice_style = "default",
        favorite_windows_voices = "",
        favorite_azure_voices = "",
        speech_queue_behavior = "interrupt",
        duplicate_suppression_seconds = 0,
        pronunciation_corrections = true,
        voice_profiles = "",
        config_schema = 1,
        engine = "system_speech",
        audio_output = "default",
        azure_region = "eastus",
    }
end

return Defaults
