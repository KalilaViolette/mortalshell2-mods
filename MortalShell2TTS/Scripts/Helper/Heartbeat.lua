-- MortalShell2TTS Helper.Heartbeat
-- Pure parser/validator for the helper's atomic heartbeat snapshot. File IO, clocks,
-- restart policy, diagnostics and helper process ownership are owned by Helper.Runtime.

local Heartbeat = {}

local function field(content, name)
    return content:match("^" .. name .. "=([^;]+)") or content:match(";" .. name .. "=([^;]+)")
end

function Heartbeat.Evaluate(content, expected_version, now_epoch, max_age_seconds)
    if content == nil then return false, "missing", nil end
    content = tostring(content)

    local helper_version = field(content, "version")
    local helper_pid = tonumber(field(content, "pid"))
    local helper_start = tonumber(field(content, "startFileTimeUtc"))
    local game_pid = tonumber(field(content, "gamePid")) or 0
    local binding_mode = field(content, "bindingMode") or "unknown"
    local epoch = tonumber(field(content, "epoch"))

    if helper_version == nil or helper_pid == nil or helper_pid <= 0 or helper_start == nil or helper_start <= 0 or epoch == nil then
        return false, "invalid", nil
    end
    if binding_mode ~= "exact-pid" and binding_mode ~= "fallback-name" then
        return false, "invalid-binding", nil
    end
    if binding_mode == "exact-pid" and game_pid <= 0 then
        return false, "invalid-owner", nil
    end
    if tostring(helper_version) ~= tostring(expected_version or "") then
        return false, "version-mismatch:" .. tostring(helper_version), {
            version = tostring(helper_version), pid = helper_pid, start = helper_start,
            gamePid = game_pid, bindingMode = tostring(binding_mode), epoch = epoch,
            identity = tostring(helper_version) .. ":" .. tostring(helper_pid) .. ":" .. tostring(helper_start),
        }
    end

    now_epoch = tonumber(now_epoch) or 0
    max_age_seconds = tonumber(max_age_seconds) or 0
    local age = now_epoch - epoch
    local info = {
        version = tostring(helper_version), pid = helper_pid, start = helper_start,
        gamePid = game_pid, bindingMode = tostring(binding_mode), epoch = epoch,
        identity = tostring(helper_version) .. ":" .. tostring(helper_pid) .. ":" .. tostring(helper_start),
    }
    if age < -300 then return false, "future", info end
    if age <= max_age_seconds then return true, tostring(age), info end
    return false, tostring(age), info
end

return Heartbeat
