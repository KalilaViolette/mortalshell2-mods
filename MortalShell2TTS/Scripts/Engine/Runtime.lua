-- MortalShell2TTS Engine.Runtime
-- Bounded runtime orchestration for the helper-published engine-status snapshot.
-- File access, parser/config/UI state and diagnostics are injected by the consumer.
-- Helper lifecycle, Azure voice catalog parsing/synthesis, Settings UI and Unreal/input state remain outside.

local Runtime = {}

local STATUS_BYTES_LIMIT = 128 * 1024

function Runtime.New(options)
    options = type(options) == "table" and options or {}

    local config = assert(options.config, "Engine.Runtime requires config")
    local ui = assert(options.ui, "Engine.Runtime requires ui")
    local read_file = assert(options.read_file, "Engine.Runtime requires read_file")
    local parser = assert(options.parser, "Engine.Runtime requires parser")
    local bool_from_string = options.bool_from_string
    local engine_status_path = assert(options.engine_status_path, "Engine.Runtime requires engine_status_path")
    local engines = assert(options.engines, "Engine.Runtime requires engines")
    local azure_regions = assert(options.azure_regions, "Engine.Runtime requires azure_regions")
    local log = type(options.log) == "function" and options.log or function() end

    if type(parser.Parse) ~= "function" then
        return nil, "Engine.Status parser API missing"
    end

    local self = {}

    function self.Index()
        for index, engine in ipairs(engines) do
            if engine.value == config.engine then return index end
        end
        return 1
    end

    function self.RegionIndex()
        local selected = tostring(config.azure_region or ""):lower()
        for index, region in ipairs(azure_regions) do
            if tostring(region or ""):lower() == selected then return index end
        end
        return 1
    end

    function self.Current()
        for _, engine in ipairs(engines) do
            if engine.value == config.engine then return engine end
        end
        return engines[1]
    end

    function self.CurrentLabel()
        local engine = self.Current()
        return engine and engine.label or tostring(config.engine)
    end

    function self.Refresh()
        local content, read_reason = read_file(engine_status_path, STATUS_BYTES_LIMIT)
        if read_reason == "oversized" then
            log("engine status snapshot exceeded 128 KB safety limit; ignoring")
        end
        content = content or ""
        if content == ui.engine_status_raw then return false end
        ui.engine_status_raw = content

        local parsed = parser.Parse(content, bool_from_string)
        ui.azure_key_status = parsed.azure_key_status
        ui.azure_ready = parsed.azure_ready
        ui.azure_voice_count = parsed.azure_voice_count
        ui.azure_message = parsed.azure_message

        -- A helper status change is the synchronization point for a refreshed
        -- Azure catalog. Invalidate once here; do not reread/reparse hundreds of
        -- voices on every native UI paint or Left/Right input event.
        if config.engine == "azure" then ui.voice_catalog_engine = "" end
        return true
    end

    return self
end

return Runtime
