-- MortalShell2ModUI Controller.Profile
-- Shared persistent controller interpretation profile. The profile lives with ModUI,
-- not any consumer mod, so TTS, Minimap and future settings providers use the same
-- calibrated capture thresholds and stick normalization. No Unreal objects or polling live here.

local Profile = {}

local DEFAULTS = {
    stick_activation = 0.120,
    stick_release = 0.080,
    stick_neutral = 0.050,
    -- Preferred values are user/calibration intent. Effective stick_* values below may be
    -- temporarily safety-constrained without destroying these preferences.
    preferred_stick_activation = 0.120,
    preferred_stick_release = 0.080,
    preferred_stick_neutral = 0.050,
    dominance_margin = 0.050,
    neutral_ticks = 3,
    trigger_activation = 0.600,
    trigger_release = 0.250,
    preferred_trigger_activation = 0.600,
    preferred_trigger_release = 0.250,
    calibrated = false,
    neutral_noise = 0.000,
    weakest_onset = 0.000,
    center_lx = 0.000, center_ly = 0.000,
    center_rx = 0.000, center_ry = 0.000,
    min_lx = -1.000, max_lx = 1.000,
    min_ly = -1.000, max_ly = 1.000,
    min_rx = -1.000, max_rx = 1.000,
    min_ry = -1.000, max_ry = 1.000,
}

local cache = nil
local loaded = false
local path_override = nil

local function clamp(value, low, high)
    value = tonumber(value) or low
    if value < low then return low end
    if value > high then return high end
    return value
end

local function rounded(value)
    value = tonumber(value) or 0
    if value >= 0 then return math.floor(value * 1000 + 0.5) / 1000 end
    return math.ceil(value * 1000 - 0.5) / 1000
end

local function copy_table(source)
    local out = {}
    for key, value in pairs(source or {}) do out[key] = value end
    return out
end

local function script_path()
    local ok, info = pcall(function() return debug.getinfo(1, "S") end)
    if not ok or info == nil then return nil end
    local source = tostring(info.source or "")
    if source:sub(1, 1) == "@" then source = source:sub(2) end
    if source == "" then return nil end
    return source:gsub("/", "\\")
end

local function parent_path(path)
    if path == nil then return nil end
    return path:match("^(.*)\\[^\\]+$")
end

local function config_path()
    if path_override ~= nil then return path_override end
    local local_app_data = type(os.getenv) == "function" and os.getenv("LOCALAPPDATA") or nil
    if type(local_app_data) == "string" and local_app_data ~= "" then
        -- Keep the file directly under LOCALAPPDATA so persistence does not depend on creating
        -- a directory from Lua. It therefore survives consumer/mod-folder replacement.
        return local_app_data:gsub("/", "\\") .. "\\MortalShell2ModUI_ControllerCalibration.ini"
    end
    local controller_dir = parent_path(script_path())
    local scripts_dir = parent_path(controller_dir)
    local mod_dir = parent_path(scripts_dir)
    return mod_dir ~= nil and (mod_dir .. "\\ControllerCalibration.ini") or "ControllerCalibration.ini"
end

local function sanitize_range(value, center, fallback, positive)
    center = clamp(center, -0.500, 0.500)
    value = clamp(value or fallback, -1.000, 1.000)
    if positive then return rounded(math.max(center + 0.100, value)) end
    return rounded(math.min(center - 0.100, value))
end

function Profile.Defaults()
    return copy_table(DEFAULTS)
end

function Profile.Sanitize(value)
    value = type(value) == "table" and value or {}
    local out = copy_table(DEFAULTS)

    -- Keep user/calibration preferences separate from the effective runtime thresholds.
    -- Activation is the upper anchor; Release and Deadzone are temporarily constrained
    -- below it with a 0.001 gap. Raising Activation later automatically restores the
    -- remembered preferences instead of leaving them permanently crushed. Old v2 profiles
    -- have no preferred_* keys, so their existing effective values seed the preferences.
    out.preferred_stick_activation = rounded(clamp(
        value.preferred_stick_activation or value.stick_activation or out.preferred_stick_activation,
        0.003, 0.900))
    out.preferred_stick_release = rounded(clamp(
        value.preferred_stick_release or value.stick_release or out.preferred_stick_release,
        0.002, 0.500))
    out.preferred_stick_neutral = rounded(clamp(
        value.preferred_stick_neutral or value.stick_neutral or out.preferred_stick_neutral,
        0.001, 0.250))

    out.stick_activation = out.preferred_stick_activation
    out.stick_release = rounded(clamp(out.preferred_stick_release, 0.002,
        math.max(0.002, out.stick_activation - 0.001)))
    out.stick_neutral = rounded(clamp(out.preferred_stick_neutral, 0.001,
        math.max(0.001, out.stick_release - 0.001)))
    out.dominance_margin = rounded(clamp(value.dominance_margin or out.dominance_margin, 0.001, 0.300))
    out.neutral_ticks = math.max(1, math.min(8, math.floor((tonumber(value.neutral_ticks) or out.neutral_ticks) + 0.5)))

    -- Trigger hysteresis uses the same preference/effective split. The historical 0.050
    -- minimum gap is preserved while preventing a temporary low activation value from
    -- permanently overwriting the user's preferred trigger release threshold.
    out.preferred_trigger_activation = rounded(clamp(
        value.preferred_trigger_activation or value.trigger_activation or out.preferred_trigger_activation,
        0.100, 0.950))
    out.preferred_trigger_release = rounded(clamp(
        value.preferred_trigger_release or value.trigger_release or out.preferred_trigger_release,
        0.050, 0.900))
    out.trigger_activation = out.preferred_trigger_activation
    out.trigger_release = rounded(clamp(out.preferred_trigger_release, 0.050,
        math.max(0.050, out.trigger_activation - 0.050)))

    out.calibrated = value.calibrated == true or tostring(value.calibrated or ""):lower() == "true"
    out.neutral_noise = rounded(clamp(value.neutral_noise or 0.0, 0.0, 1.0))
    out.weakest_onset = rounded(clamp(value.weakest_onset or 0.0, 0.0, 1.0))

    out.center_lx = rounded(clamp(value.center_lx or 0.0, -0.500, 0.500))
    out.center_ly = rounded(clamp(value.center_ly or 0.0, -0.500, 0.500))
    out.center_rx = rounded(clamp(value.center_rx or 0.0, -0.500, 0.500))
    out.center_ry = rounded(clamp(value.center_ry or 0.0, -0.500, 0.500))
    out.min_lx = sanitize_range(value.min_lx, out.center_lx, -1.0, false)
    out.max_lx = sanitize_range(value.max_lx, out.center_lx, 1.0, true)
    out.min_ly = sanitize_range(value.min_ly, out.center_ly, -1.0, false)
    out.max_ly = sanitize_range(value.max_ly, out.center_ly, 1.0, true)
    out.min_rx = sanitize_range(value.min_rx, out.center_rx, -1.0, false)
    out.max_rx = sanitize_range(value.max_rx, out.center_rx, 1.0, true)
    out.min_ry = sanitize_range(value.min_ry, out.center_ry, -1.0, false)
    out.max_ry = sanitize_range(value.max_ry, out.center_ry, 1.0, true)
    return out
end

function Profile.DirectActivity(value)
    value = Profile.Sanitize(value)
    return rounded(clamp(math.min(0.100, value.stick_activation * 0.75), 0.001, 0.200))
end

function Profile.Recommend(metrics, base)
    metrics = type(metrics) == "table" and metrics or {}
    base = Profile.Sanitize(base)
    local neutral_noise = clamp(metrics.neutral_noise or 0.0, 0.0, 0.50)
    local weakest_onset = clamp(metrics.weakest_onset or base.stick_activation, 0.001, 1.0)

    local center_lx = clamp(metrics.center_lx or base.center_lx, -0.500, 0.500)
    local center_ly = clamp(metrics.center_ly or base.center_ly, -0.500, 0.500)
    local center_rx = clamp(metrics.center_rx or base.center_rx, -0.500, 0.500)
    local center_ry = clamp(metrics.center_ry or base.center_ry, -0.500, 0.500)
    local min_lx = sanitize_range(metrics.min_lx, center_lx, base.min_lx, false)
    local max_lx = sanitize_range(metrics.max_lx, center_lx, base.max_lx, true)
    local min_ly = sanitize_range(metrics.min_ly, center_ly, base.min_ly, false)
    local max_ly = sanitize_range(metrics.max_ly, center_ly, base.max_ly, true)
    local min_rx = sanitize_range(metrics.min_rx, center_rx, base.min_rx, false)
    local max_rx = sanitize_range(metrics.max_rx, center_rx, base.max_rx, true)
    local min_ry = sanitize_range(metrics.min_ry, center_ry, base.min_ry, false)
    local max_ry = sanitize_range(metrics.max_ry, center_ry, base.max_ry, true)

    -- Shipped defaults stay conservative and controller-agnostic. A completed calibration,
    -- however, should follow the controller actually observed instead of clamping every device
    -- back to the defaults. Normalize measured center noise and first sustained movement onset
    -- against the shortest usable cardinal span, then retain small but explicit hysteresis gaps.
    local shortest_span = math.min(
        math.max(0.100, center_lx - min_lx), math.max(0.100, max_lx - center_lx),
        math.max(0.100, center_ly - min_ly), math.max(0.100, max_ly - center_ly),
        math.max(0.100, center_rx - min_rx), math.max(0.100, max_rx - center_rx),
        math.max(0.100, center_ry - min_ry), math.max(0.100, max_ry - center_ry)
    )
    local normalized_noise = clamp(neutral_noise / shortest_span, 0.0, 0.50)
    local normalized_onset = clamp(weakest_onset / shortest_span, 0.001, 1.0)
    local neutral = clamp(math.max(0.005, normalized_noise * 3.0 + 0.001), 0.001, 0.200)
    local release = clamp(math.max(neutral + 0.003, normalized_noise * 4.0 + 0.002), neutral, 0.300)
    local activation = clamp(math.max(release + 0.005, normalized_onset + 0.003, normalized_noise * 6.0 + 0.005),
        release + 0.001, 0.350)
    local margin = clamp(math.max(0.010, normalized_noise * 2.0), 0.001, 0.150)

    return Profile.Sanitize({
        stick_activation = activation,
        stick_release = release,
        stick_neutral = neutral,
        dominance_margin = margin,
        neutral_ticks = DEFAULTS.neutral_ticks,
        trigger_activation = base.trigger_activation,
        trigger_release = base.trigger_release,
        calibrated = true,
        neutral_noise = neutral_noise,
        weakest_onset = weakest_onset,
        center_lx = center_lx, center_ly = center_ly,
        center_rx = center_rx, center_ry = center_ry,
        min_lx = min_lx, max_lx = max_lx,
        min_ly = min_ly, max_ly = max_ly,
        min_rx = min_rx, max_rx = max_rx,
        min_ry = min_ry, max_ry = max_ry,
    })
end

local function normalized_axis(value, center, negative, positive)
    value = tonumber(value) or 0.0
    center = tonumber(center) or 0.0
    negative = tonumber(negative) or -1.0
    positive = tonumber(positive) or 1.0
    local delta = value - center
    if delta >= 0 then
        local span = math.max(0.100, positive - center)
        return clamp(delta / span, -1.0, 1.0)
    end
    local span = math.max(0.100, center - negative)
    return clamp(delta / span, -1.0, 1.0)
end

function Profile.NormalizeStick(stick, x, y, value)
    value = Profile.Sanitize(value or Profile.Current())
    stick = tostring(stick or "left"):lower()
    if stick == "right" then
        return normalized_axis(x, value.center_rx, value.min_rx, value.max_rx),
            normalized_axis(y, value.center_ry, value.min_ry, value.max_ry)
    end
    return normalized_axis(x, value.center_lx, value.min_lx, value.max_lx),
        normalized_axis(y, value.center_ly, value.min_ly, value.max_ly)
end

-- Pass 176: Stick Neutral is now the shared stick deadzone consumers expect it to be.
-- Keep NormalizeStick() unfiltered for Pass-174 recorder continuity; navigation/future mods
-- opt into the filtered API below. Axis signs remain raw UE signs here. In Mortal Shell's
-- RightY path, physical Up is the negative raw direction, so semantic UI code may invert Y.
local function apply_deadzone(value, deadzone)
    value = clamp(tonumber(value) or 0.0, -1.0, 1.0)
    deadzone = clamp(tonumber(deadzone) or DEFAULTS.stick_neutral, 0.0, 0.95)
    local magnitude = math.abs(value)
    if magnitude <= deadzone then return 0.0 end
    local scaled = clamp((magnitude - deadzone) / math.max(0.001, 1.0 - deadzone), 0.0, 1.0)
    return value < 0 and -scaled or scaled
end

function Profile.ScaleAxis(axis_key, raw, value)
    value = Profile.Sanitize(value or Profile.Current())
    axis_key = tostring(axis_key or "")
    local normalized = tonumber(raw) or 0.0
    if axis_key == "Gamepad_LeftX" then
        return normalized_axis(raw, value.center_lx, value.min_lx, value.max_lx)
    elseif axis_key == "Gamepad_LeftY" then
        return normalized_axis(raw, value.center_ly, value.min_ly, value.max_ly)
    elseif axis_key == "Gamepad_RightX" then
        return normalized_axis(raw, value.center_rx, value.min_rx, value.max_rx)
    elseif axis_key == "Gamepad_RightY" then
        return normalized_axis(raw, value.center_ry, value.min_ry, value.max_ry)
    elseif axis_key == "Gamepad_LeftTriggerAxis" or axis_key == "Gamepad_RightTriggerAxis" then
        return clamp(normalized, 0.0, 1.0)
    end
    return clamp(normalized, -1.0, 1.0)
end

function Profile.NormalizeAxis(axis_key, raw, value)
    value = Profile.Sanitize(value or Profile.Current())
    axis_key = tostring(axis_key or "")
    local normalized = Profile.ScaleAxis(axis_key, raw, value)
    if axis_key == "Gamepad_LeftTriggerAxis" or axis_key == "Gamepad_RightTriggerAxis" then
        return normalized
    end
    return apply_deadzone(normalized, value.stick_neutral)
end

function Profile.NormalizeAxisSemantic(axis_key, raw, value)
    axis_key = tostring(axis_key or "")
    local normalized = Profile.NormalizeAxis(axis_key, raw, value)
    -- Match the human/menu convention already used by NormalizeStickSemantic():
    -- Mortal Shell reports physical Right Stick Up as negative raw RightY.
    if axis_key == "Gamepad_RightY" then normalized = -(tonumber(normalized) or 0.0) end
    return normalized
end

function Profile.TriggerActive(raw, was_active, value)
    value = Profile.Sanitize(value or Profile.Current())
    raw = clamp(tonumber(raw) or 0.0, 0.0, 1.0)
    local threshold = was_active == true and value.trigger_release or value.trigger_activation
    return raw >= threshold, raw, threshold
end

function Profile.AxisActive(axis_key, direction, raw, was_active, value)
    value = Profile.Sanitize(value or Profile.Current())
    axis_key = tostring(axis_key or "")
    direction = tostring(direction or "pos")
    if axis_key == "Gamepad_LeftTriggerAxis" or axis_key == "Gamepad_RightTriggerAxis" then
        local active, scalar, threshold = Profile.TriggerActive(raw, was_active == true, value)
        if direction == "neg" then return false, scalar, threshold end
        return active, scalar, threshold
    end
    local scalar = Profile.ScaleAxis(axis_key, raw, value)
    local threshold = was_active == true and value.stick_release or value.stick_activation
    local active = direction == "neg" and scalar <= -threshold or scalar >= threshold
    return active, scalar, threshold
end

function Profile.NormalizeStickFiltered(stick, x, y, value)
    value = Profile.Sanitize(value or Profile.Current())
    stick = tostring(stick or "left"):lower()
    local nx, ny = Profile.NormalizeStick(stick, x, y, value)
    local magnitude = math.sqrt(nx * nx + ny * ny)
    local deadzone = clamp(tonumber(value.stick_neutral) or DEFAULTS.stick_neutral, 0.0, 0.95)
    if magnitude <= deadzone or magnitude <= 0.000001 then return 0.0, 0.0 end
    local scaled = clamp((magnitude - deadzone) / math.max(0.001, 1.0 - deadzone), 0.0, 1.0)
    local factor = scaled / magnitude
    return clamp(nx * factor, -1.0, 1.0), clamp(ny * factor, -1.0, 1.0)
end

function Profile.NormalizeStickSemantic(stick, x, y, value)
    stick = tostring(stick or "left"):lower()
    local nx, ny = Profile.NormalizeStickFiltered(stick, x, y, value)
    -- Mortal Shell/UE reports RightY with the opposite human vertical sense used by
    -- menu navigation: physical Right Stick Up is raw negative, Down is raw positive.
    if stick == "right" then ny = -ny end
    return nx, ny
end

function Profile.CenteredStick(stick, x, y, value)
    value = Profile.Sanitize(value or Profile.Current())
    stick = tostring(stick or "left"):lower()
    if stick == "right" then
        return (tonumber(x) or 0.0) - value.center_rx, (tonumber(y) or 0.0) - value.center_ry
    end
    return (tonumber(x) or 0.0) - value.center_lx, (tonumber(y) or 0.0) - value.center_ly
end

function Profile.Encode(value)
    value = Profile.Sanitize(value)
    return table.concat({
        "; MortalShell2ModUI Controller Calibration",
        "; Shared by every ModUI consumer. Generated/updated by the in-game Controller Settings screen; persistent outside consumer mod folders.",
        "Version=3",
        string.format("StickActivation=%.3f", value.stick_activation),
        string.format("StickRelease=%.3f", value.stick_release),
        string.format("StickNeutral=%.3f", value.stick_neutral),
        string.format("PreferredStickActivation=%.3f", value.preferred_stick_activation),
        string.format("PreferredStickRelease=%.3f", value.preferred_stick_release),
        string.format("PreferredStickNeutral=%.3f", value.preferred_stick_neutral),
        string.format("DominanceMargin=%.3f", value.dominance_margin),
        "NeutralTicks=" .. tostring(value.neutral_ticks),
        string.format("TriggerActivation=%.3f", value.trigger_activation),
        string.format("TriggerRelease=%.3f", value.trigger_release),
        string.format("PreferredTriggerActivation=%.3f", value.preferred_trigger_activation),
        string.format("PreferredTriggerRelease=%.3f", value.preferred_trigger_release),
        "Calibrated=" .. (value.calibrated and "true" or "false"),
        string.format("NeutralNoise=%.3f", value.neutral_noise),
        string.format("WeakestOnset=%.3f", value.weakest_onset),
        string.format("CenterLX=%.3f", value.center_lx), string.format("CenterLY=%.3f", value.center_ly),
        string.format("CenterRX=%.3f", value.center_rx), string.format("CenterRY=%.3f", value.center_ry),
        string.format("MinLX=%.3f", value.min_lx), string.format("MaxLX=%.3f", value.max_lx),
        string.format("MinLY=%.3f", value.min_ly), string.format("MaxLY=%.3f", value.max_ly),
        string.format("MinRX=%.3f", value.min_rx), string.format("MaxRX=%.3f", value.max_rx),
        string.format("MinRY=%.3f", value.min_ry), string.format("MaxRY=%.3f", value.max_ry),
        "; MortalShell2ModUIControllerProfileEnd=1",
        "",
    }, "\r\n")
end

function Profile.Decode(content)
    if type(content) ~= "string" or #content > 16384 then return nil, "invalid-or-oversized" end
    if not content:find("MortalShell2ModUIControllerProfileEnd=1", 1, true) then return nil, "missing-end-marker" end
    local values = {}
    for line in content:gmatch("[^\r\n]+") do
        local key, raw = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
        if key ~= nil then
            if key == "StickActivation" then values.stick_activation = tonumber(raw)
            elseif key == "StickRelease" then values.stick_release = tonumber(raw)
            elseif key == "StickNeutral" then values.stick_neutral = tonumber(raw)
            elseif key == "PreferredStickActivation" then values.preferred_stick_activation = tonumber(raw)
            elseif key == "PreferredStickRelease" then values.preferred_stick_release = tonumber(raw)
            elseif key == "PreferredStickNeutral" then values.preferred_stick_neutral = tonumber(raw)
            elseif key == "DominanceMargin" then values.dominance_margin = tonumber(raw)
            elseif key == "NeutralTicks" then values.neutral_ticks = tonumber(raw)
            elseif key == "TriggerActivation" then values.trigger_activation = tonumber(raw)
            elseif key == "TriggerRelease" then values.trigger_release = tonumber(raw)
            elseif key == "PreferredTriggerActivation" then values.preferred_trigger_activation = tonumber(raw)
            elseif key == "PreferredTriggerRelease" then values.preferred_trigger_release = tonumber(raw)
            elseif key == "Calibrated" then values.calibrated = tostring(raw):lower() == "true"
            elseif key == "NeutralNoise" then values.neutral_noise = tonumber(raw)
            elseif key == "WeakestOnset" then values.weakest_onset = tonumber(raw)
            elseif key == "CenterLX" then values.center_lx = tonumber(raw)
            elseif key == "CenterLY" then values.center_ly = tonumber(raw)
            elseif key == "CenterRX" then values.center_rx = tonumber(raw)
            elseif key == "CenterRY" then values.center_ry = tonumber(raw)
            elseif key == "MinLX" then values.min_lx = tonumber(raw)
            elseif key == "MaxLX" then values.max_lx = tonumber(raw)
            elseif key == "MinLY" then values.min_ly = tonumber(raw)
            elseif key == "MaxLY" then values.max_ly = tonumber(raw)
            elseif key == "MinRX" then values.min_rx = tonumber(raw)
            elseif key == "MaxRX" then values.max_rx = tonumber(raw)
            elseif key == "MinRY" then values.min_ry = tonumber(raw)
            elseif key == "MaxRY" then values.max_ry = tonumber(raw) end
        end
    end
    return Profile.Sanitize(values)
end

function Profile.Reload()
    local path = config_path()
    local file = io.open(path, "rb")
    if file == nil then
        cache = Profile.Defaults()
        loaded = true
        return copy_table(cache), "default-missing"
    end
    local content = file:read(16385)
    file:close()
    local decoded, err = Profile.Decode(content)
    if decoded == nil then
        cache = Profile.Defaults()
        loaded = true
        return copy_table(cache), tostring(err or "decode-failed")
    end
    cache = decoded
    loaded = true
    return copy_table(cache), "loaded"
end

function Profile.Current()
    if not loaded or type(cache) ~= "table" then Profile.Reload() end
    return copy_table(cache)
end

function Profile.Save(value)
    local sanitized = Profile.Sanitize(value)
    local path = config_path()
    local temp = path .. ".tmp"
    local file, err = io.open(temp, "wb")
    if file == nil then return false, tostring(err or "stage-open-failed") end
    local payload = Profile.Encode(sanitized)
    local ok, write_err = pcall(function() file:write(payload); file:flush() end)
    file:close()
    if not ok then os.remove(temp); return false, tostring(write_err or "stage-write-failed") end
    local backup = path .. ".bak"
    os.remove(backup)
    local probe = io.open(path, "rb")
    local had_existing = probe ~= nil
    if probe ~= nil then probe:close() end
    if had_existing then
        local moved_old, move_old_err = os.rename(path, backup)
        if not moved_old then os.remove(temp); return false, tostring(move_old_err or "backup-failed") end
    end
    local renamed, rename_err = os.rename(temp, path)
    if not renamed then
        os.remove(temp)
        if had_existing then os.rename(backup, path) end
        return false, tostring(rename_err or "publish-failed")
    end
    if had_existing then os.remove(backup) end
    cache = sanitized
    loaded = true
    return true, copy_table(cache)
end

function Profile.Reset()
    return Profile.Save(Profile.Defaults())
end

function Profile.Path()
    return config_path()
end

function Profile.SetPathForTest(path)
    path_override = path ~= nil and tostring(path) or nil
    loaded = false
    cache = nil
end

return Profile
