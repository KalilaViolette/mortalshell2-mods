-- MortalShell2ModUI Settings.Details
-- Pure wrapping/window helpers for contextual settings text. This module owns no
-- consumer state, Unreal objects, hooks, timers, input routes, or game behavior.

local Details = {}

function Details.WrapLines(value, width)
    width = math.max(12, math.floor(tonumber(width) or 38))
    local out = {}
    local source = tostring(value or "") .. "\n"
    for raw in source:gmatch("(.-)\n") do
        if raw == "" then
            out[#out + 1] = ""
        else
            local prefix = raw:match("^(%s*%-+%s+)") or ""
            local body = prefix ~= "" and raw:sub(#prefix + 1) or raw
            local continuation = prefix ~= "" and string.rep(" ", #prefix) or ""
            local line = prefix
            local has_word = false
            for word in body:gmatch("%S+") do
                local candidate = line
                if candidate ~= "" and candidate:sub(-1) ~= " " then candidate = candidate .. " " end
                candidate = candidate .. word
                if has_word and #candidate > width then
                    out[#out + 1] = line
                    line = continuation .. word
                else
                    line = candidate
                end
                has_word = true
            end
            if line ~= "" then out[#out + 1] = line end
        end
    end
    if #out == 0 then out[1] = "" end
    return out
end

function Details.Window(lines, offset, visible_total, footer_fn)
    lines = type(lines) == "table" and lines or { "" }
    if #lines == 0 then lines = { "" } end
    visible_total = math.max(4, math.floor(tonumber(visible_total) or 18))
    local content_capacity = #lines > visible_total and (visible_total - 1) or visible_total
    local max_offset = math.max(0, #lines - content_capacity)
    offset = math.floor((tonumber(offset) or 0) + 0.5)
    if offset < 0 then offset = 0 end
    if offset > max_offset then offset = max_offset end

    local first = offset + 1
    local last = math.min(#lines, first + content_capacity - 1)
    local shown = {}
    for index = first, last do shown[#shown + 1] = lines[index] end

    if max_offset > 0 and type(footer_fn) == "function" then
        local footer = footer_fn(offset, max_offset, #lines, content_capacity)
        if footer ~= nil and tostring(footer) ~= "" then shown[#shown + 1] = tostring(footer) end
    end

    return table.concat(shown, "\n"), offset, max_offset, #lines
end

return Details
