-- MortalShell2TTS settings schema.
-- Pure TTS-specific data only: no Unreal objects, hooks, helper IPC, or rendering.

local Schema = {}

Schema.tabs = {
    {
        key = "mod",
        label = "MOD",
        description = "Lore-reader behavior and settings-panel preferences.",
        rows = {
            { key = "narration", label = "Narration", kind = "toggle" },
            { key = "read_delay_ms", label = "Read Delay", kind = "int", min = 0, max = 3000, step = 150, suffix = " ms" },
            { key = "announce_page_number", label = "Announce Page", kind = "toggle" },
            { key = "menu_keybind", label = "Open Keybind", kind = "open_keybind" },
            { key = "modifier_sides_equivalent", label = "Modifier Sides", kind = "toggle" },
            { key = "pause_game_while_menu_open", label = "Pause Game", kind = "toggle" },
            { key = "controller_menu_bind", label = "Controller Bind", kind = "controller_open_bind" },
            { key = "controller_settings", label = "Controller Settings", kind = "action" },
            { key = "log_performance", label = "Log Performance", kind = "toggle" },
            { key = "debug_logging", label = "Debug Logging", kind = "toggle" },
            { key = "reset_mod", label = "Reset Mod Settings", kind = "action" },
        },
    },
    {
        key = "speech",
        label = "SPEECH",
        description = "Engine-agnostic voice presentation settings.",
        rows = {
            { key = "voice", label = "Voice", kind = "voice" },
            { key = "voice_style", label = "Voice Style", kind = "voice_style" },
            { key = "rate", label = "Speech Rate", kind = "int", min = -10, max = 10, step = 1 },
            { key = "pitch", label = "Pitch", kind = "pitch", min = -6, max = 6, step = 1 },
            { key = "volume", label = "Volume", kind = "int", min = 0, max = 100, step = 5, suffix = "%" },
            { key = "speech_queue_behavior", label = "Speech Queue", kind = "speech_queue" },
            { key = "duplicate_suppression_seconds", label = "Duplicate Text", kind = "duplicate_window" },
            { key = "pronunciation_corrections", label = "Pronunciation", kind = "toggle" },
            { key = "test", label = "Test Voice", kind = "action" },
            { key = "reset_speech", label = "Reset Speech Settings", kind = "action" },
        },
    },
    {
        key = "engine",
        label = "ENGINE",
        description = "TTS backend selection and engine-specific capabilities.",
        rows = {
            { key = "engine", label = "TTS Engine", kind = "engine" },
            { key = "audio_output", label = "Audio Output", kind = "audio_output" },
            { key = "engine_mode", label = "Connection", kind = "engine_info" },
            { key = "azure_region", label = "Azure Region", kind = "azure_region" },
            { key = "azure_key", label = "Azure Key", kind = "azure_key" },
            { key = "azure_refresh", label = "Refresh Azure Voices", kind = "action" },
            { key = "azure_key_clear", label = "Clear Azure Key", kind = "action" },
            { key = "engine_help", label = "Engine Details", kind = "action" },
            { key = "reset_engine", label = "Reset Engine Settings", kind = "action" },
        },
    },
}

Schema.descriptions = {
    narration = "Reads lore and documents aloud as pages open.",
    log_performance = "Every 10 s, writes [PERF] lines with CPU time and call counts for each TTS system to the UE4SS log. Also turns on the shared UI host's logging.",
    debug_logging = "Writes the mod's routine DIAG lines (menu input, redraws, helper traffic) to UE4SS.log. Off is quiet; startup, session and failure events are always logged. Turn it on before reproducing a bug you want to report.",
    read_delay_ms = "Delays narration until the reader animation settles.",
    announce_page_number = "Speaks page numbers in multi-page documents.",
    menu_keybind = "Records a keyboard chord or repeated-key sequence used to open this window. The clean-install default is Ctrl, T, T, S. Release everything to save it; known Mortal Shell and UE4SS conflicts are checked automatically.",
    modifier_sides_equivalent = "When Any Side is enabled, Left/Right Ctrl, Shift, and Alt are interchangeable when matching saved bindings. Separate preserves exact left/right modifier matching.",
    pause_game_while_menu_open = "When On, keeps all five native gameplay/input blockers active and also pauses the game while TTS Settings is open. Off keeps the same blockers but leaves the background simulation live. The balanced pause path remains an automatic safety fallback if native player isolation is incomplete.",
    controller_menu_bind = "Records a controller chord or repeated-button sequence used to open this window. Release everything to save it; known Mortal Shell and menu conflicts are checked automatically.",
    controller_settings = "Opens MortalShell2ModUI shared Controller Settings, guided calibration, and live controller test. The saved profile is shared by TTS, Minimap, and future ModUI consumers.",
    reset_mod = "Restores Mod defaults only.",

    voice = "Opens the searchable voice browser for the active engine. Select a voice, press Confirm again to preview it, then Back to apply it.",
    voice_style = "Chooses an Azure speaking style when the current voice exposes styles. Shows N/A when the voice has no style options.",
    rate = "Adjusts local and Azure speech speed.",
    pitch = "Raises or lowers the speaking pitch. Azure Dragon HD voices report N/A because they do not expose prosody pitch.",
    volume = "Adjusts narration without changing game audio.",
    speech_queue_behavior = "Controls new narration while speech is active: Interrupt replaces it, Queue waits in order, Ignore drops the new request.",
    duplicate_suppression_seconds = "Suppresses the same normalized page/text request for a short window. Off by default; previews are never suppressed.",
    pronunciation_corrections = "Turns pronunciation corrections On or Off. Off bypasses both shipped and user rules without disabling narration; your dictionary and voice-specific IPA/fallback data remain saved for when this is turned back On.",
    test = "Previews the current voice and output settings.",
    reset_speech = "Restores voices, per-voice tuning, favorites, queue behavior, and duplicate suppression defaults.",

    engine = "Chooses local Windows Speech or Azure streaming.",
    audio_output = "Chooses the Windows narration device.",
    engine_mode = "Shows the active engine mode and readiness.",
    azure_region = "Matches your Azure Speech resource region.",
    azure_key = "Imports from the clipboard and encrypts with Windows DPAPI.",
    azure_refresh = "Refreshes the cached Azure voice list.",
    azure_key_clear = "Deletes this user's encrypted Azure key.",
    engine_help = "Shows engine and playback details.",
    reset_engine = "Restores engine, output, and region defaults.",
}

return Schema
