-- MortalShell2TTS Speech.Runtime
-- Runtime speech request composition/duplicate policy and IPC dispatch.
-- Delay scheduling remains in Speech.Queue; helper lifecycle, synthesis and Unreal clocks stay injected/consumer-owned.

local Runtime = {}

function Runtime.New(options)
    options = type(options) == "table" and options or {}
    local config = assert(options.config, "Speech.Runtime requires config")
    local duplicate = assert(options.duplicate, "Speech.Runtime requires duplicate policy")
    local command = assert(options.command, "Speech.Runtime requires command")
    local normalize_window = assert(options.normalize_window, "Speech.Runtime requires normalize_window")
    local save_config = assert(options.save_config, "Speech.Runtime requires save_config")
    local real_time_seconds = options.real_time_seconds
    local log = type(options.log) == "function" and options.log or function() end
    local diag = type(options.diag) == "function" and options.diag or function() end

    local recent = {}
    local duplicate_clock_source = nil
    local self = {}

    function self.ResetDuplicates()
        recent = {}
    end

    function self.RequestKey(text, page)
        return duplicate.RequestKey(text, page)
    end

    function self.SpokenText(text, page)
        text = tostring(text or "")
        if config.announce_page_number then
            local current, total = tostring(page or ""):match("^(%d+)%s*/%s*(%d+)$")
            if current ~= nil and total ~= nil then
                text = "Page " .. tostring(tonumber(current) or current) .. " of " .. tostring(tonumber(total) or total) .. ". " .. text
            end
        end
        return text
    end

    function self.SpeakNow(text, page)
        if not config.narration then return end
        text = self.SpokenText(text, page)
        if text == "" then return end
        if command("SPEAK", text) then log("speak page=" .. tostring(page) .. " chars=" .. tostring(#text)) end
    end

    function self.DuplicateSuppressed(text, page)
        local window = normalize_window(config.duplicate_suppression_seconds)
        if window <= 0 then recent = {}; return false end

        local now, clock_source = nil, "os.time"
        if type(real_time_seconds) == "function" then
            local ok, value, source = pcall(real_time_seconds)
            if ok then now, clock_source = tonumber(value), tostring(source or clock_source) end
        end
        if now == nil then now = tonumber(os.time()) or 0 end
        if duplicate_clock_source ~= clock_source then
            duplicate_clock_source = clock_source
            diag("speech.duplicateClock", {source = clock_source})
        end

        local suppressed, next_recent, info = duplicate.Check(recent, text, page, now, window, 64)
        recent = next_recent
        if suppressed then
            diag("speech.duplicate", {
                action = "suppressed", seconds = window, page = tostring(page),
                chars = #tostring(text or ""),
                recentKeys = type(info) == "table" and tonumber(info.recent_keys) or 0,
            })
            return true
        end
        return false
    end

    function self.Stop(reason)
        local sent = command("STOP", "")
        diag("speech.stop", {reason = tostring(reason or "unspecified"), sent = sent == true})
        if sent then log("stop: " .. tostring(reason)) end
        return sent == true
    end

    function self.Test()
        save_config()
        if command("TEST", "Mortal Shell Two text to speech preview. The darkness remembers every name.") then
            log("voice preview requested")
            return true
        end
        return false
    end

    return self
end

return Runtime
