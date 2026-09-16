-- MortalShell2TTS Audio.Runtime
-- Bounded runtime orchestration for the helper-published audio-output catalog.
-- File access, parser/config/UI state and diagnostics are injected by the consumer.
-- Helper process ownership, synthesis, Settings UI and Unreal/input state remain outside.

local Runtime = {}

local CATALOG_BYTES_LIMIT = 2 * 1024 * 1024
local CATALOG_ENTRIES_LIMIT = 1024

local function lower(value)
    return tostring(value or ""):lower()
end

function Runtime.New(options)
    options = type(options) == "table" and options or {}

    local config = assert(options.config, "Audio.Runtime requires config")
    local ui = assert(options.ui, "Audio.Runtime requires ui")
    local read_file = assert(options.read_file, "Audio.Runtime requires read_file")
    local parser = assert(options.parser, "Audio.Runtime requires parser")
    local sanitize_text = assert(options.sanitize_text, "Audio.Runtime requires sanitize_text")
    local outputs_path = assert(options.outputs_path, "Audio.Runtime requires outputs_path")
    local log = type(options.log) == "function" and options.log or function() end

    if type(parser.Parse) ~= "function" then
        return nil, "Audio.Outputs parser API missing"
    end

    local self = {}

    function self.Refresh()
        local content, read_reason = read_file(outputs_path, CATALOG_BYTES_LIMIT)
        if read_reason == "oversized" then
            log("audio-output catalog exceeded 2 MB safety limit; using System Default only")
        end

        local values, parse_info = parser.Parse(content, sanitize_text, CATALOG_ENTRIES_LIMIT)
        if type(parse_info) == "table" and parse_info.truncated == true then
            log("audio-output catalog exceeded 1024-entry safety limit; remaining entries ignored")
        end

        ui.audio_outputs = values
        return values, parse_info
    end

    function self.CurrentLabel()
        self.Refresh()
        local selected = lower(config.audio_output)
        for _, output in ipairs(ui.audio_outputs or {}) do
            if lower(output.value) == selected then return output.label end
        end
        if selected ~= "default" then return "Unavailable / disconnected" end
        return "System Default"
    end

    function self.Index()
        self.Refresh()
        local selected = lower(config.audio_output)
        for index, output in ipairs(ui.audio_outputs or {}) do
            if lower(output.value) == selected then return index end
        end
        return 1
    end

    return self
end

return Runtime
