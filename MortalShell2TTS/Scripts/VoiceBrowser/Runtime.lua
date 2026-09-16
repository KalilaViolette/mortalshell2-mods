-- MortalShell2TTS VoiceBrowser.Runtime
-- Runtime voice-catalog loading and active-voice capability/label helpers.
-- File access, config/UI state, diagnostics, sanitization, browser interaction,
-- favorites persistence, synthesis and Unreal ownership are injected/consumer-owned.

local Runtime = {}

local function lower(value)
    return tostring(value or ""):lower()
end

function Runtime.New(options)
    options = type(options) == "table" and options or {}
    local config = options.config
    local ui = options.ui
    local read_file = options.read_file
    local sanitize_text = options.sanitize_text
    local log = options.log
    local diag = options.diag

    if type(config) ~= "table" then return nil, "config missing" end
    if type(ui) ~= "table" then return nil, "ui missing" end
    if type(read_file) ~= "function" then return nil, "read_file missing" end
    if type(sanitize_text) ~= "function" then return nil, "sanitize_text missing" end
    if type(log) ~= "function" then log = function() end end
    if type(diag) ~= "function" then diag = function() end end

    local voices_path = tostring(options.voices_path or "")
    local azure_voices_path = tostring(options.azure_voices_path or "")
    local self = {}

    function self.ActiveValue()
        if config.engine == "azure" then return config.azure_voice end
        return config.voice
    end

    function self.Refresh(force)
        if not force and ui.voice_catalog_engine == config.engine and type(ui.voices) == "table" and #ui.voices > 0 then
            return false
        end

        local values = {}
        local seen = {}

        if config.engine ~= "azure" then
            values[1] = { value = "default", label = "System Default", gender = "", locale = "", styles = {}, pitch_supported = true }
            seen["default"] = true
        end

        local catalog_path = config.engine == "azure" and azure_voices_path or voices_path
        local content, catalog_read_reason = read_file(catalog_path, 8 * 1024 * 1024)
        if catalog_read_reason == "oversized" then
            log("voice catalog exceeded 8 MB safety limit; ignoring malformed catalog")
        end
        if content ~= nil then
            local accepted = 0
            for raw_line in content:gmatch("[^\r\n]+") do
                if accepted >= 4096 then
                    log("voice catalog exceeded 4096-entry safety limit; remaining entries ignored")
                    break
                end
                local fields = {}
                for field in (raw_line .. "\t"):gmatch("(.-)\t") do fields[#fields + 1] = tostring(field or ""):match("^%s*(.-)%s*$") end
                local voice_id = sanitize_text(fields[1] or "", "", 384)
                local label = sanitize_text(fields[2] or voice_id, voice_id, 512)
                if #fields <= 1 then label = voice_id end
                local gender = sanitize_text(fields[3] or "", "", 32)
                local locale = sanitize_text(fields[4] or "", "", 64)
                local styles = {}
                for style in tostring(fields[5] or ""):gmatch("[^,]+") do
                    style = sanitize_text(style, "", 96)
                    if style ~= "" then
                        styles[#styles + 1] = style
                        if #styles >= 64 then break end
                    end
                end
                local pitch_supported = tostring(fields[6] or "1") ~= "0"
                local voice_lower = lower(voice_id)
                local malformed_azure_id = config.engine == "azure" and voice_id:find("%s") ~= nil
                if malformed_azure_id then
                    if accepted == 0 then
                        log("Azure voice catalog rejected malformed aggregate record; refresh the catalog with the current helper")
                        diag("voice.catalog.invalid", { engine = "azure", reason = "whitespace-in-shortname", fields = #fields })
                    end
                elseif voice_id ~= "" and not seen[voice_lower] then
                    seen[voice_lower] = true
                    values[#values + 1] = {
                        value = voice_id,
                        label = label ~= "" and label or voice_id,
                        gender = gender,
                        locale = locale,
                        styles = styles,
                        pitch_supported = pitch_supported,
                    }
                    accepted = accepted + 1
                end
            end
        end

        if config.engine == "azure" and #values == 0 then
            values[1] = {
                value = config.azure_voice,
                label = config.azure_voice .. " (Azure list unavailable)",
                gender = "",
                locale = "",
                styles = {},
                pitch_supported = not lower(config.azure_voice):find("dragonhd", 1, true),
            }
        end

        ui.voices = values
        ui.voice_catalog_engine = config.engine
        return true
    end

    function self.CurrentRecord(value)
        self.Refresh(false)
        local wanted = lower(value or self.ActiveValue())
        for _, voice in ipairs(ui.voices or {}) do
            if lower(voice.value) == wanted then return voice end
        end
        return nil
    end

    function self.CurrentStyles(value)
        local voice = self.CurrentRecord(value)
        return voice ~= nil and type(voice.styles) == "table" and voice.styles or {}
    end

    function self.CurrentPitchSupported(value)
        local voice = self.CurrentRecord(value)
        if voice == nil then
            return config.engine ~= "azure" or not lower(value or self.ActiveValue()):find("dragonhd", 1, true)
        end
        return voice.pitch_supported ~= false
    end

    function self.NormalizedStyle(value)
        local styles = self.CurrentStyles(value)
        if #styles == 0 then return "default" end
        local wanted = tostring(config.voice_style or "default")
        if wanted == "" or lower(wanted) == "default" then return "default" end
        for _, style in ipairs(styles) do
            if lower(style) == lower(wanted) then return style end
        end
        return "default"
    end

    function self.StyleLabel()
        local styles = self.CurrentStyles()
        if #styles == 0 then return "N/A" end
        local style = self.NormalizedStyle()
        return style == "default" and "Default" or style
    end

    function self.CurrentLabel()
        self.Refresh(false)
        local active = tostring(self.ActiveValue() or "")
        for _, voice in ipairs(ui.voices or {}) do
            if lower(voice.value) == lower(active) then return voice.label end
        end
        if config.engine == "azure" then
            return active .. " (not in Azure list)"
        end
        if active ~= "" and lower(active) ~= "default" then
            return active .. " (not installed)"
        end
        return "System Default"
    end

    function self.Index()
        self.Refresh(false)
        local active = lower(self.ActiveValue())
        for index, voice in ipairs(ui.voices or {}) do
            if lower(voice.value) == active then return index end
        end
        return 1
    end

    return self
end

return Runtime
