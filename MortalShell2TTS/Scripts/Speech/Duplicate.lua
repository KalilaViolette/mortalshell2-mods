-- MortalShell2TTS Speech.Duplicate
-- Pure narration fingerprint/recent-cache transforms only. The consumer owns clock
-- acquisition, configuration, diagnostics, scheduling, and actual speech dispatch.

local Duplicate = {}

local function trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$")
end

function Duplicate.RequestKey(text, page)
    text = trim(tostring(text or ""):gsub("%s+", " ")):lower()
    local h1, h2 = 5381, 52711
    for index = 1, #text do
        local byte = text:byte(index) or 0
        h1 = (h1 * 33 + byte) % 2147483647
        h2 = (h2 * 131 + byte) % 2147483629
    end
    return tostring(page or "") .. "|" .. tostring(#text) .. "|" .. tostring(h1) .. "|" .. tostring(h2)
end

function Duplicate.Check(recent, text, page, now, window, max_entries)
    window = tonumber(window) or 0
    max_entries = math.max(1, math.floor(tonumber(max_entries) or 64))
    if window <= 0 then
        return false, {}, { key = Duplicate.RequestKey(text, page), recent_keys = 0 }
    end

    now = tonumber(now) or 0
    if type(recent) ~= "table" then recent = {} end
    local key = Duplicate.RequestKey(text, page)

    local count, oldest_key, oldest_time = 0, nil, nil
    for existing_key, timestamp in pairs(recent) do
        timestamp = tonumber(timestamp)
        local age = timestamp ~= nil and (now - timestamp) or (window + 1)
        if timestamp == nil or age < 0 or age > window then
            recent[existing_key] = nil
        else
            count = count + 1
            if oldest_time == nil or timestamp < oldest_time then
                oldest_key, oldest_time = existing_key, timestamp
            end
        end
    end

    local previous = tonumber(recent[key])
    if previous ~= nil and (now - previous) >= 0 and (now - previous) <= window then
        recent[key] = now
        return true, recent, { key = key, recent_keys = count }
    end

    if count >= max_entries and oldest_key ~= nil then recent[oldest_key] = nil end
    recent[key] = now
    return false, recent, { key = key, recent_keys = count }
end

return Duplicate
