-- MortalShell2TTS Config.VoiceProfileRuntime
-- Runtime ownership for schema-versioned per-voice tuning profiles (profile-state).
-- Serialization primitives remain in Config.VoiceProfiles; config persistence and UI remain consumer-owned.

local Runtime = {}

function Runtime.New(options)
    options = type(options) == "table" and options or {}
    local config = assert(options.config, "VoiceProfileRuntime requires config")
    local Profiles = assert(options.profiles, "VoiceProfileRuntime requires profiles")
    local Value = assert(options.value_helpers, "VoiceProfileRuntime requires value_helpers")
    local diag = type(options.diag) == "function" and options.diag or function() end
    local log = type(options.log) == "function" and options.log or function() end
    local schema = tonumber(options.schema) or 3

    for _, name in ipairs({"Escape", "Key", "Default", "Sanitize", "Deserialize", "Serialize"}) do
        if type(Profiles[name]) ~= "function" then return nil, "Config.VoiceProfiles API missing " .. name end
    end

    local profiles = {}
    local self = {}

    local function selected_voice(engine, voice)
        engine = tostring(engine or config.engine):lower()
        return engine, tostring(voice or (engine == "azure" and config.azure_voice or config.voice))
    end

    function self.Reset()
        profiles = {}
    end

    function self.Serialize()
        return Profiles.Serialize(profiles, Value)
    end

    function self.Deserialize(serialized)
        profiles = Profiles.Deserialize(serialized, Value)
        return profiles
    end

    function self.Profile(engine, voice, create)
        engine, voice = selected_voice(engine, voice)
        local key = Profiles.Key(engine, voice)
        local profile = profiles[key]
        if profile == nil and create then
            profile = Profiles.Default()
            profile.voice = voice
            profiles[key] = profile
        elseif profile ~= nil and profile.voice == nil then
            profile.voice = voice
        end
        return profile
    end

    function self.Capture(engine, voice)
        engine, voice = selected_voice(engine, voice)
        local profile = Profiles.Sanitize({
            rate = config.rate,
            volume = config.volume,
            pitch = config.pitch,
            style = config.voice_style,
        }, Value)
        profile.voice = voice
        profiles[Profiles.Key(engine, voice)] = profile
        config.voice_profiles = self.Serialize()
        diag("speech.voiceProfile", {
            action = "capture", engine = engine,
            profileId = Profiles.Escape(engine .. ":" .. voice), profileSource = "stored",
            voice = voice, rate = profile.rate, volume = profile.volume,
            pitch = profile.pitch, style = profile.style,
        })
        return profile
    end

    function self.Apply(engine, voice)
        engine, voice = selected_voice(engine, voice)
        local profile = self.Profile(engine, voice, false)
        local source = profile ~= nil and "stored" or "default"
        if profile == nil then profile = Profiles.Default() end
        profile = Profiles.Sanitize(profile, Value)
        config.rate, config.volume, config.pitch, config.voice_style = profile.rate, profile.volume, profile.pitch, profile.style
        diag("speech.voiceProfile", {
            action = "apply", engine = engine,
            profileId = Profiles.Escape(engine .. ":" .. voice), profileSource = source,
            voice = voice, rate = profile.rate, volume = profile.volume,
            pitch = profile.pitch, style = profile.style,
        })
        return profile
    end

    function self.Initialize(previous_schema)
        self.Deserialize(config.voice_profiles)
        previous_schema = tonumber(previous_schema) or tonumber(config.config_schema) or 1
        if previous_schema < 2 or next(profiles) == nil then
            local legacy = Profiles.Sanitize({
                rate = config.rate, volume = config.volume,
                pitch = config.pitch, style = config.voice_style,
            }, Value)
            for _, pair in ipairs({{"system_speech", config.voice}, {"azure", config.azure_voice}}) do
                local voice = tostring(pair[2] or "")
                if voice ~= "" then
                    profiles[Profiles.Key(pair[1], voice)] = {
                        rate = legacy.rate, volume = legacy.volume, pitch = legacy.pitch,
                        style = legacy.style, voice = voice,
                    }
                end
            end
            log(previous_schema < 2
                and "config migration seeded per-voice tuning for selected Windows/Azure voices"
                or "voice-profile data was missing/invalid; rebuilt selected voice profiles from active tuning")
        end
        config.config_schema = schema
        config.voice_profiles = self.Serialize()
        self.Apply(config.engine, config.engine == "azure" and config.azure_voice or config.voice)
    end

    return self
end

return Runtime
