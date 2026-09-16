-- MortalShell2TTS pure per-voice profile serialization helpers.
-- Runtime profile selection/application and diagnostics are owned by Config.VoiceProfileRuntime.

local VoiceProfiles = {}

local function trim_with(Value, value)
    if type(Value) == "table" and type(Value.Trim) == "function" then
        return Value.Trim(value)
    end
    return tostring(value or ""):match("^%s*(.-)%s*$")
end

local function clamp_with(Value, value, minimum, maximum)
    if type(Value) == "table" and type(Value.Clamp) == "function" then
        return Value.Clamp(value, minimum, maximum)
    end
    value = tonumber(value) or minimum
    if value < minimum then return minimum end
    if value > maximum then return maximum end
    return value
end

function VoiceProfiles.Escape(value)
    return (tostring(value or ""):gsub("([^%w%._%-])", function(char)
        return string.format("%%%02X", string.byte(char))
    end))
end

function VoiceProfiles.Unescape(value)
    return (tostring(value or ""):gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16) or 63)
    end))
end

function VoiceProfiles.Key(engine, voice)
    return tostring(engine or "system_speech"):lower() .. "\0" .. tostring(voice or "default"):lower()
end

function VoiceProfiles.Default()
    return { rate = 0, volume = 100, pitch = 0, style = "default" }
end

function VoiceProfiles.Sanitize(profile, Value)
    profile = type(profile) == "table" and profile or {}
    local style = tostring(profile.style or "default"):gsub("[%z\r\n\t]", " ")
    style = trim_with(Value, style)
    if style == "" then style = "default" end
    if #style > 96 then style = style:sub(1, 96) end
    return {
        rate = clamp_with(Value, math.floor((tonumber(profile.rate) or 0) + 0.5), -10, 10),
        volume = clamp_with(Value, math.floor((tonumber(profile.volume) or 100) + 0.5), 0, 100),
        pitch = clamp_with(Value, math.floor((tonumber(profile.pitch) or 0) + 0.5), -6, 6),
        style = style,
    }
end

function VoiceProfiles.Deserialize(serialized, Value)
    local profiles = {}
    serialized = tostring(serialized or "")
    if #serialized > 786432 then serialized = serialized:sub(1, 786432) end
    local accepted = 0
    for record in serialized:gmatch("[^;]+") do
        if accepted >= 1024 then break end
        local engine, voice, rate, volume, pitch, style = record:match("^([^,]*),([^,]*),([^,]*),([^,]*),([^,]*),([^,]*)$")
        if engine ~= nil and voice ~= nil then
            engine = VoiceProfiles.Unescape(engine):lower()
            voice = VoiceProfiles.Unescape(voice)
            style = VoiceProfiles.Unescape(style or "default")
            if (engine == "system_speech" or engine == "azure") and trim_with(Value, voice) ~= "" then
                local parsed = VoiceProfiles.Sanitize({
                    rate = rate,
                    volume = volume,
                    pitch = pitch,
                    style = style,
                }, Value)
                voice = tostring(voice):gsub("[%z\r\n\t]", " ")
                voice = trim_with(Value, voice)
                if #voice > 384 then voice = voice:sub(1, 384) end
                if voice ~= "" then
                    parsed.voice = voice
                    profiles[VoiceProfiles.Key(engine, voice)] = parsed
                    accepted = accepted + 1
                end
            end
        end
    end
    return profiles, accepted
end

function VoiceProfiles.Serialize(profiles, Value)
    local records = {}
    for key, profile in pairs(type(profiles) == "table" and profiles or {}) do
        local engine, voice_lower = tostring(key):match("^(.-)\0(.*)$")
        if engine ~= nil and voice_lower ~= nil then
            local voice = tostring(profile.voice or voice_lower)
            profile = VoiceProfiles.Sanitize(profile, Value)
            records[#records + 1] = table.concat({
                VoiceProfiles.Escape(engine),
                VoiceProfiles.Escape(voice),
                tostring(profile.rate),
                tostring(profile.volume),
                tostring(profile.pitch),
                VoiceProfiles.Escape(profile.style),
            }, ",")
        end
    end
    table.sort(records)
    return table.concat(records, ";")
end

return VoiceProfiles
