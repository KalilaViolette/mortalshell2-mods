-- MortalShell2ModUI Core.Value
-- Pure setting/value helpers only. This module owns no Unreal objects, hooks,
-- timers, input routes, settings state, or game-specific behavior.

local Value = {}

function Value.Trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$")
end

function Value.Clamp(value, low, high)
    value = tonumber(value) or low
    if value < low then return low end
    if value > high then return high end
    return value
end

function Value.BoolFromString(value, fallback)
    local normalized = Value.Trim(value):lower()
    if normalized == "true" or normalized == "1" or normalized == "yes" or normalized == "on" then return true end
    if normalized == "false" or normalized == "0" or normalized == "no" or normalized == "off" then return false end
    return fallback
end

return Value
