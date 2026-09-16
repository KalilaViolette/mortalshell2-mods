-- MortalShell2ModUI Core.Text
-- Pure presentation helpers only. This module owns no Unreal objects, hooks,
-- timers, input routes, settings state, or game-specific behavior.

local Text = {}

function Text.ProgressBar(value, min_value, max_value, width)
    width = math.max(1, math.floor((tonumber(width) or 16) + 0.5))
    value = tonumber(value) or 0
    min_value = tonumber(min_value) or 0
    max_value = tonumber(max_value) or min_value

    local ratio = 0
    if max_value > min_value then ratio = (value - min_value) / (max_value - min_value) end
    ratio = math.max(0, math.min(1, ratio))
    local filled = math.floor(ratio * width + 0.5)
    return "[" .. string.rep("#", filled) .. string.rep("-", width - filled) .. "]"
end

function Text.Ellipsize(value, max_chars)
    value = tostring(value or "")
    max_chars = math.max(0, math.floor((tonumber(max_chars) or 34) + 0.5))

    -- Never split a valid UTF-8 code point. Fall back to byte truncation only
    -- when the host lacks utf8 helpers or the source string is invalid UTF-8.
    if utf8 ~= nil and type(utf8.len) == "function" and type(utf8.offset) == "function" then
        local ok_len, char_count = pcall(utf8.len, value)
        if ok_len and char_count ~= nil then
            if char_count <= max_chars then return value end
            local keep = max_chars <= 3 and max_chars or (max_chars - 3)
            if keep <= 0 then return max_chars > 0 and string.rep(".", max_chars) or "" end
            local ok_offset, next_byte = pcall(utf8.offset, value, keep + 1)
            local prefix = value
            if ok_offset and next_byte ~= nil then prefix = value:sub(1, next_byte - 1) end
            if max_chars <= 3 then return prefix end
            return prefix .. "..."
        end
    end

    if #value <= max_chars then return value end
    if max_chars <= 3 then return value:sub(1, max_chars) end
    return value:sub(1, max_chars - 3) .. "..."
end

function Text.EllipsizeLines(value, max_chars, max_lines)
    value = tostring(value or "")
    max_chars = math.max(0, math.floor((tonumber(max_chars) or 80) + 0.5))
    max_lines = math.max(0, math.floor((tonumber(max_lines) or 0) + 0.5))

    local lines = {}
    local changed = false
    local count = 0
    -- Preserve empty lines, including a trailing empty line, while bounding every
    -- consumer-provided line independently so one provider cannot invade adjacent rails.
    for line in (value .. "\n"):gmatch("(.-)\n") do
        count = count + 1
        if max_lines > 0 and count > max_lines then
            changed = true
            break
        end
        local clipped = Text.Ellipsize(line, max_chars)
        if clipped ~= line then changed = true end
        lines[#lines + 1] = clipped
    end
    if max_lines > 0 and count > max_lines and #lines > 0 then
        local marker = Text.Ellipsize("...", max_chars)
        lines[#lines] = marker
    end
    return table.concat(lines, "\n"), changed
end

function Text.TabStrip(tabs, selected_index)
    local parts = {}
    tabs = type(tabs) == "table" and tabs or {}
    selected_index = math.floor((tonumber(selected_index) or 1) + 0.5)
    for index, tab in ipairs(tabs) do
        local label = tostring(type(tab) == "table" and tab.label or tab or "")
        if index == selected_index then
            parts[#parts + 1] = "[ " .. label .. " ]"
        else
            parts[#parts + 1] = label
        end
    end
    return table.concat(parts, "    ")
end

return Text
