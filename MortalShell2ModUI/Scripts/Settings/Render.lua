-- MortalShell2ModUI Settings.Render
-- Pure text rendering for generic settings rows. Consumer callbacks provide the
-- actual labels/values and action semantics; this module never reads consumer state.

local Render = {}

local function resolve(fn, row, index, fallback)
    if type(fn) ~= "function" then return fallback end
    return fn(row, index)
end

function Render.Labels(rows, selected_index, label_fn)
    rows = type(rows) == "table" and rows or {}
    selected_index = math.floor((tonumber(selected_index) or 1) + 0.5)
    local lines = {}
    for index, row in ipairs(rows) do
        local prefix = index == selected_index and "> " or "  "
        local label = resolve(label_fn, row, index, tostring(type(row) == "table" and row.label or ""))
        lines[#lines + 1] = prefix .. label
    end
    return table.concat(lines, "\n")
end

function Render.Values(rows, selected_index, value_fn, action_predicate)
    rows = type(rows) == "table" and rows or {}
    selected_index = math.floor((tonumber(selected_index) or 1) + 0.5)
    local lines = {}
    for index, row in ipairs(rows) do
        local value = resolve(value_fn, row, index, "")
        if index == selected_index then
            local action = false
            if type(action_predicate) == "function" then
                action = action_predicate(row, index) == true
            elseif type(row) == "table" then
                action = row.kind == "action"
            end
            if action then value = "[ " .. value .. " ]" else value = "< " .. value .. " >" end
        end
        lines[#lines + 1] = value
    end
    return table.concat(lines, "\n")
end

-- v0.71.0 section headers. A consumer marks a row "header" in rowKinds and sends its
-- title as the label (no cursor prefix, an empty value); the host draws it as a
-- divider line in capitals, HEADER_LEFT .. TITLE .. HEADER_RIGHT, so a group of rows
-- reads as a group inside one tab. v0.71.1: the em dash (U+2014) she chose -- 0.71.0
-- drew ASCII hyphens until the glyph was seen to render; the UI playground's T08 shot
-- (2026-09-14, bundle 173541) drew "\u{2014} POSITION \u{2014}" in the rails' own style
-- (DT_TextStyle_ReadText, Crimson Italic), long dashes exactly as intended, so the
-- UTF-8 passes through Conv_StringToText and the font has the glyph. Both rails stay
-- line-for-line with the consumer's rows, so pointer hits and the row viewport are
-- untouched; the rail width is measured in bytes, so a header over-estimates the
-- rail by four glyphs at most -- never under.
Render.HEADER_LEFT = "\u{2014} "
Render.HEADER_RIGHT = " \u{2014}"

local function split_lines(text)
    local out = {}
    text = tostring(text or "")
    if text == "" then return out end
    for line in (text .. "\n"):gmatch("(.-)\n") do out[#out + 1] = line end
    return out
end

-- v0.71.3 (user, 2026-09-15, with video): on FIRST open every header drew four em dashes
-- a side, and moving the cursor corrected it to one. Decoration was not idempotent and it
-- is applied more than once.
--
-- ShellService stores the DECORATED snapshot in ui.last_presentation (it has to -- the
-- pointer hit-test resolves against exactly the text that was drawn), and a relayout
-- re-renders that stored snapshot rather than asking the consumer again. A first open
-- runs several measurement passes before the rails settle, so the header went through
-- DecorateHeaders once per pass and grew a dash each time. The first cursor move sends a
-- fresh, undecorated snapshot from the consumer, which is why it fixed itself.
--
-- The fix belongs here rather than at the call site: decorating an already-decorated
-- title must be a no-op, whoever calls it and however often. Leading/trailing dashes only,
-- so a title that legitimately contains one keeps it.
function Render.HeaderLine(title)
    title = tostring(title or ""):gsub("^%s*>?%s*", ""):gsub("%s+$", "")
    while true do
        local stripped = title:gsub("^\u{2014}%s*", ""):gsub("%s*\u{2014}$", "")
        if stripped == title then break end
        title = stripped
    end
    return Render.HEADER_LEFT .. title:upper() .. Render.HEADER_RIGHT
end

-- Returns the labels text with every "header" row rewritten, and how many were.
function Render.DecorateHeaders(labels_text, kinds_text)
    local kinds = split_lines(kinds_text)
    if #kinds == 0 then return labels_text, 0 end
    local labels = split_lines(labels_text)
    local count = 0
    for index, kind in ipairs(kinds) do
        if kind == "header" and labels[index] ~= nil then
            labels[index] = Render.HeaderLine(labels[index])
            count = count + 1
        end
    end
    if count == 0 then return labels_text, 0 end
    return table.concat(labels, "\n"), count
end

function Render.Combined(tab_text, rows, selected_index, label_fn, value_fn)
    rows = type(rows) == "table" and rows or {}
    selected_index = math.floor((tonumber(selected_index) or 1) + 0.5)
    local lines = { tostring(tab_text or ""), "" }
    for index, row in ipairs(rows) do
        local prefix = index == selected_index and "> " or "  "
        local label = resolve(label_fn, row, index, tostring(type(row) == "table" and row.label or ""))
        local value = resolve(value_fn, row, index, "")
        lines[#lines + 1] = string.format("%s%-15s  %s", prefix, label, value)
    end
    return table.concat(lines, "\n")
end

return Render
