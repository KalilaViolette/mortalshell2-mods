-- MortalShell2ModUI Settings.Viewport
-- Pure row-window policy for the main settings profile. The shell was calibrated for
-- ten rows (MAIN_ROW_HIT_TOP + 10 * ROW_HIT_STEP fits the prompt background); a tab
-- with more rows than that scrolls instead of clipping. The window is a pure function
-- of (row count, selected row), so the host that renders and the consumer that maps
-- pointer hits back to rows agree without sharing state:
--
--   * rows <= ROWS: the window is the whole tab (identity; every existing consumer is
--     unchanged).
--   * rows >  ROWS: the selected row is kept near the middle of the window and the
--     window is clamped to the list, so Up/Down (arrow keys, d-pad, the semantic
--     Up/Down actions -- all the same MoveSelection path) scroll the list one row at
--     a time once the selection reaches the middle. Wrapping from the last row to the
--     first jumps the window back to the top.
--
-- The browser profile has its own paging and is never windowed. No Unreal objects,
-- hooks, timers or consumer state live here.

local M = {}

M.ROWS = 10

local function rounded(value, fallback)
    local number = tonumber(value)
    if number == nil then number = tonumber(fallback) or 1 end
    return math.floor(number + 0.5)
end

local function split_lines(text)
    local lines = {}
    text = tostring(text or "")
    if text == "" then return lines end
    for line in (text .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
    return lines
end

-- First and last row index of the visible window, and whether it is windowed at all.
function M.Window(row_count, selected_index, rows)
    rows = math.max(1, rounded(rows, M.ROWS))
    row_count = math.max(0, rounded(row_count, 0))
    if row_count <= rows then return 1, row_count, false end
    local selected = rounded(selected_index, 1)
    if selected < 1 then selected = 1 end
    if selected > row_count then selected = row_count end
    local first = selected - math.floor((rows - 1) / 2)
    local max_first = row_count - rows + 1
    if first > max_first then first = max_first end
    if first < 1 then first = 1 end
    return first, first + rows - 1, true
end

-- Maps a window-relative row (what the pointer hit) back to the tab's row index.
function M.AbsoluteIndex(row_count, selected_index, visible_index, rows)
    local first = M.Window(row_count, selected_index, rows)
    return first + rounded(visible_index, 1) - 1
end

-- Windowed copy of a consumer presentation snapshot: labels, values, rowKinds and
-- rowProgress are sliced, selectedRow becomes window-relative, and scrollFirst /
-- scrollTotal / scrollRows record what happened for diagnostics. Returns the same
-- table untouched when nothing needs windowing.
function M.Apply(snapshot, rows)
    if type(snapshot) ~= "table" then return snapshot, false end
    if tostring(snapshot.profile or "main") == "browser" then return snapshot, false end
    local labels = split_lines(snapshot.labels)
    local row_count = #labels
    local first, last, windowed = M.Window(row_count, snapshot.selectedRow, rows)
    if not windowed then return snapshot, false end
    local copy = {}
    for key, value in pairs(snapshot) do copy[key] = value end
    local function slice(field)
        local lines = split_lines(snapshot[field])
        if #lines == 0 then return end
        local out = {}
        for index = first, last do out[#out + 1] = lines[index] or "" end
        copy[field] = table.concat(out, "\n")
    end
    slice("labels")
    slice("values")
    slice("rowKinds")
    slice("rowProgress")
    copy.selectedRow = rounded(snapshot.selectedRow, 1) - first + 1
    copy.scrollFirst = first
    copy.scrollTotal = row_count
    copy.scrollRows = last - first + 1
    return copy, true
end

return M
