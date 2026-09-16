-- MortalShell2ModUI Settings.Model
-- Pure settings-model helpers. This module owns no Unreal objects, hooks,
-- timers, input routes, consumer state, or game-specific behavior.

local Model = {}

local function normalized_index(value, fallback)
    local number = tonumber(value)
    if number == nil then number = tonumber(fallback) or 1 end
    return math.floor(number + 0.5)
end

function Model.CurrentTab(tabs, tab_index)
    tabs = type(tabs) == "table" and tabs or {}
    return tabs[normalized_index(tab_index, 1)]
end

function Model.RowsForTab(tabs, tab_index)
    local tab = Model.CurrentTab(tabs, tab_index)
    if type(tab) ~= "table" or type(tab.rows) ~= "table" then return {} end
    return tab.rows
end

function Model.SelectedRow(rows, selected_index)
    rows = type(rows) == "table" and rows or {}
    return rows[normalized_index(selected_index, 1)]
end

function Model.RowDescription(tabs, tab_index, row, descriptions)
    if type(row) ~= "table" then return "" end
    descriptions = type(descriptions) == "table" and descriptions or {}
    local tab = Model.CurrentTab(tabs, tab_index)
    local direct = descriptions[row.key]
    if direct ~= nil then return tostring(direct) end
    if type(tab) == "table" and tab.description ~= nil then return tostring(tab.description) end
    return ""
end

function Model.ValidateSchema(tabs)
    if type(tabs) ~= "table" or #tabs < 1 then return false, "tabs-empty" end
    local tab_keys = {}
    for tab_index, tab in ipairs(tabs) do
        if type(tab) ~= "table" then return false, "tab-not-table:" .. tostring(tab_index) end
        local key = tostring(tab.key or "")
        local label = tostring(tab.label or "")
        if key == "" then return false, "tab-key-empty:" .. tostring(tab_index) end
        if label == "" then return false, "tab-label-empty:" .. tostring(tab_index) end
        if tab_keys[key] then return false, "duplicate-tab-key:" .. key end
        tab_keys[key] = true
        if type(tab.rows) ~= "table" or #tab.rows < 1 then return false, "rows-empty:" .. key end
        local row_keys = {}
        for row_index, row in ipairs(tab.rows) do
            if type(row) ~= "table" then return false, "row-not-table:" .. key .. ":" .. tostring(row_index) end
            local row_key = tostring(row.key or "")
            local row_label = tostring(row.label or "")
            local row_kind = tostring(row.kind or "")
            if row_key == "" then return false, "row-key-empty:" .. key .. ":" .. tostring(row_index) end
            if row_label == "" then return false, "row-label-empty:" .. key .. ":" .. row_key end
            if row_kind == "" then return false, "row-kind-empty:" .. key .. ":" .. row_key end
            if row_keys[row_key] then return false, "duplicate-row-key:" .. key .. ":" .. row_key end
            row_keys[row_key] = true
        end
    end
    return true, "ok"
end

return Model
