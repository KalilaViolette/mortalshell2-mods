-- MortalShell2TTS Engine.Status
-- Pure helper engine-status snapshot parsing only. File I/O, UI invalidation,
-- diagnostics, config, helper lifecycle, and Azure catalog refresh remain consumer-owned.

local Status = {}

local function trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$")
end

function Status.Parse(content, bool_from_string)
    content = tostring(content or "")
    if type(bool_from_string) ~= "function" then
        bool_from_string = function(value, fallback)
            local lower = trim(value):lower()
            if lower == "true" or lower == "1" or lower == "yes" or lower == "on" then return true end
            if lower == "false" or lower == "0" or lower == "no" or lower == "off" then return false end
            return fallback == true
        end
    end

    local result = {
        azure_key_status = "missing",
        azure_ready = false,
        azure_voice_count = 0,
        azure_message = "",
    }

    for raw_line in content:gmatch("[^\r\n]+") do
        local key, value = raw_line:match("^([^=]+)=(.*)$")
        if key ~= nil then
            key = trim(key):lower()
            value = trim(value)
            if key == "azurekey" then
                result.azure_key_status = value ~= "" and value:lower() or "missing"
            elseif key == "azureready" then
                result.azure_ready = bool_from_string(value, false)
            elseif key == "azurevoicecount" then
                result.azure_voice_count = tonumber(value) or 0
            elseif key == "azuremessage" then
                result.azure_message = value
            end
        end
    end

    -- Preserve the legacy Windows PowerShell snapshot compatibility path where
    -- an array could have been published as one space-joined line.
    if content:find("AzureKey=", 1, true) ~= nil then
        local key_status = content:match("AzureKey=([^%s]+)")
        local ready = content:match("AzureReady=([^%s]+)")
        local count = content:match("AzureVoiceCount=([^%s]+)")
        local message = content:match("AzureMessage=(.*)$")
        if key_status ~= nil then result.azure_key_status = trim(key_status):lower() end
        if ready ~= nil then result.azure_ready = bool_from_string(trim(ready), false) end
        if count ~= nil then result.azure_voice_count = tonumber(trim(count)) or 0 end
        if message ~= nil then result.azure_message = trim(message) end
    end

    return result
end

return Status
