-- MortalShell2TTS configuration sanitization helpers.
-- Pure TTS/config policy only; no file IO, migration, hooks, helper commands, or runtime ownership.

local Sanitize = {}

local function trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$")
end

function Sanitize.QueueBehavior(value)
    value = trim(value):lower():gsub("[%s%-]+", "_")
    if value == "queue" then return "queue" end
    if value == "ignore" or value == "ignore_while_speaking" then return "ignore" end
    return "interrupt"
end

function Sanitize.DuplicateWindow(value)
    value = math.floor((tonumber(value) or 0) + 0.5)
    local allowed = { 0, 1, 3, 5, 10 }
    local nearest = allowed[1]
    local distance = math.abs(value - nearest)
    for _, candidate in ipairs(allowed) do
        local next_distance = math.abs(value - candidate)
        if next_distance < distance then nearest, distance = candidate, next_distance end
    end
    return nearest
end

function Sanitize.Text(value, fallback, max_length)
    value = tostring(value or ""):gsub("[%z\r\n\t]", " ")
    value = trim(value)
    if value == "" then value = tostring(fallback or "") end
    max_length = tonumber(max_length) or 256
    if #value > max_length then value = value:sub(1, max_length) end
    return value
end

function Sanitize.Binding(value, fallback, allow_off)
    value = trim(value)
    fallback = tostring(fallback or "")
    if allow_off and value:lower() == "off" then return "off" end
    if value == "" or #value > 2048 or value:find("[%z\r\n\t]") ~= nil then return fallback end

    local sequence = value:sub(1, 4):lower() == "seq:"
    local body = sequence and value:sub(5) or value
    local separator = sequence and ">" or "+"
    local tokens = {}
    local pattern = sequence and "[^>]+" or "[^+]+"
    for token in body:gmatch(pattern) do
        token = trim(token)
        local key, direction = token:match("^axis:([%w_]+):([%a]+)$")
        if direction ~= "pos" and direction ~= "neg" then key, direction = nil, nil end
        local ordinary = token:match("^[%w_]+$") ~= nil
        if token == "" or (not ordinary and key == nil) then return fallback end
        tokens[#tokens + 1] = key ~= nil and ("axis:" .. key .. ":" .. direction) or token
        if #tokens > 24 then return fallback end
    end
    if #tokens == 0 then return fallback end
    if sequence and #tokens < 2 then return tokens[1] end
    return (sequence and "seq:" or "") .. table.concat(tokens, separator)
end

function Sanitize.Favorites(value)
    local seen, values = {}, {}
    for token in tostring(value or ""):gmatch("[^|]+") do
        token = Sanitize.Text(token, "", 256)
        if token ~= "" and token ~= "default" and token:find("|", 1, true) == nil then
            local key = token:lower()
            if seen[key] == nil then
                seen[key] = true
                values[#values + 1] = token
                if #values >= 1024 then break end
            end
        end
    end
    table.sort(values, function(a, b) return a:lower() < b:lower() end)
    return table.concat(values, "|")
end

return Sanitize
