-- Shared adapter for Mortal Shell II's native Settings controls.
-- Consumers publish primitive presentation data; only the ModUI host creates UMG widgets.
local M = {
    -- Runtime-disabled after the v0.67.0 target test. Constructing a WBP_Text
    -- instance for every tab/label/value produced invisible controls, 1,683
    -- package-load warnings across 24 menu sessions, and left UE4SS at the top
    -- of the subsequent access-violation stack. Keep the adapter and audited
    -- asset catalog available for future work, but require an explicit proven
    -- widget lifecycle before ShellService may bind it again.
    RUNTIME_ENABLED = false,
    assets = {
        text = "/Game/Sparta/UI/Common/WBP_Text",
        textClass = "/Game/Sparta/UI/Common/WBP_Text.WBP_Text_C",
        choice = "/Game/Sparta/UI/Menu/WBP_NB_Option",
        choiceClass = "/Game/Sparta/UI/Menu/WBP_NB_Option.WBP_NB_Option_C",
        slider = "/Game/Sparta/UI/Menu/WBP_NB_Option_Slider",
        sliderClass = "/Game/Sparta/UI/Menu/WBP_NB_Option_Slider.WBP_NB_Option_Slider_C",
        tab = "/Game/Sparta/UI/Settings/W_SpartaTabButton",
        tabClass = "/Game/Sparta/UI/Settings/W_SpartaTabButton.W_SpartaTabButton_C",
        font = "/Game/Sparta/UI/Fonts/CrimsonText-Regular_Font",
        fontObject = "/Game/Sparta/UI/Fonts/CrimsonText-Regular_Font.0",
    },
}

local function lines(value)
    local out = {}
    for line in (tostring(value or "") .. "\n"):gmatch("(.-)\n") do out[#out + 1] = line end
    if #out == 1 and out[1] == "" then return {} end
    return out
end

local function clean_label(value)
    return (tostring(value or ""):gsub("^%s*>%s*", ""):gsub("^%s+", ""))
end

local function clean_value(value)
    value = tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local inner = value:match("^<%s*(.-)%s*>$") or value:match("^%[%s*(.-)%s*%]$")
    return inner or value
end

function M.Bind(options)
    options = options or {}
    local unwrap, valid = options.unwrap, options.valid
    local field, create = options.field, options.create
    if type(unwrap) ~= "function" or type(valid) ~= "function"
        or type(field) ~= "function" or type(create) ~= "function" then
        return nil, "native control adapters incomplete"
    end
    local FText = options.ftext
    local font = unwrap(options.font)
    local log = options.log or function() end
    -- Settings/Layout.TabStrip; the fallback reproduces the pre-v0.69.1 even split so a
    -- caller that does not pass it draws exactly what it always did.
    local tab_strip = type(options.tab_strip) == "function" and options.tab_strip
        or function(width, count)
            local cell = (tonumber(width) or 920) / math.max(1, count)
            return { cell = cell, width = cell * count }
        end
    local state = { parent = nil, tabs = {}, rows = {}, rowKinds = {}, active = false }
    local self = {}

    local function set_text(widget, value)
        widget = unwrap(widget)
        if not valid(widget) or widget["SetText"] == nil then return false end
        return pcall(widget["SetText"], widget, FText(tostring(value or "")))
    end

    local function text_block(widget)
        widget = unwrap(widget)
        if not valid(widget) then return nil end
        local block = field(widget, "TextBlock")
        if valid(block) then return block end
        return widget
    end

    local function style_text(widget, color, width, justification)
        widget = unwrap(widget)
        if not valid(widget) then return end
        -- WBP_Text exposes SetColor/SetText and a dependency-free TextBlock root.
        -- Its authored default is intentionally sparse, so copy the exact option
        -- typography proven by the exported WBP_NB_Option data without executing
        -- that option widget's Settings-dependent Construct graph.
        if widget["SetColor"] ~= nil then pcall(widget["SetColor"], widget, color) end
        local block = text_block(widget)
        if not valid(block) then return end
        if valid(font) then
            pcall(function()
                block.Font = {
                    FontObject = font,
                    TypefaceFontName = FName("Default"),
                    Size = 35.0,
                    LetterSpacing = -20,
                }
            end)
        end
        if width ~= nil and block["SetMinDesiredWidth"] ~= nil then
            pcall(block["SetMinDesiredWidth"], block, tonumber(width) or 0)
        end
        if justification ~= nil and block["SetJustification"] ~= nil then
            pcall(block["SetJustification"], block, justification)
        end
        if block["SetColorAndOpacity"] ~= nil then
            pcall(block["SetColorAndOpacity"], block, color)
        end
    end

    local function visible(widget, show)
        widget = unwrap(widget)
        if valid(widget) and widget["SetVisibility"] ~= nil then
            pcall(widget["SetVisibility"], widget, show and 0 or 1)
        end
    end

    local function remove(widget)
        widget = unwrap(widget)
        if valid(widget) and widget["RemoveFromParent"] ~= nil then pcall(widget["RemoveFromParent"], widget) end
    end

    local function clear(collection)
        for _, item in ipairs(collection) do
            remove(item.widget); remove(item.label); remove(item.value)
        end
        for key in pairs(collection) do collection[key] = nil end
    end

    local function attach(parent, widget, left, top, right)
        local ok, slot = pcall(function() return unwrap(parent:AddChildToOverlay(widget)) end)
        if not ok or not valid(slot) then return nil end
        if slot["SetHorizontalAlignment"] ~= nil then pcall(slot["SetHorizontalAlignment"], slot, 1) end
        if slot["SetVerticalAlignment"] ~= nil then pcall(slot["SetVerticalAlignment"], slot, 1) end
        if slot["SetPadding"] ~= nil then
            pcall(slot["SetPadding"], slot, { Left = left, Top = top, Right = right or 0, Bottom = 0 })
        end
        return slot
    end

    local function rebuild_tabs(parent, count)
        clear(state.tabs)
        for index = 1, count do
            -- WBP_NB_Option was previously proven unsafe when constructed under
            -- the borrowed lore prompt (its Construct graph expects Settings
            -- logic objects). WBP_Text is a dependency-free TextBlock root and
            -- is the safe native typography primitive for this host.
            local widget = create(M.assets.text, M.assets.textClass)
            if not valid(widget) then clear(state.tabs); return false end
            state.tabs[index] = { widget = widget }
        end
        state.parent = parent
        return true
    end

    local function rebuild_rows(parent, kinds)
        clear(state.rows)
        state.rowKinds = {}
        for index, kind in ipairs(kinds) do
            local label = create(M.assets.text, M.assets.textClass)
            local value = create(M.assets.text, M.assets.textClass)
            if not valid(label) or not valid(value) then
                remove(label); remove(value); clear(state.rows); return false
            end
            state.rows[index] = { label = label, value = value }
            state.rowKinds[index] = kind
        end
        state.parent = parent
        return true
    end

    function self.Clear()
        clear(state.tabs); clear(state.rows)
        state.rowKinds, state.parent, state.active = {}, nil, false
    end

    function self.Show(show)
        for _, item in ipairs(state.tabs) do visible(item.widget, show) end
        for _, item in ipairs(state.rows) do
            visible(item.widget, show); visible(item.label, show); visible(item.value, show)
        end
        state.active = show == true
    end

    function self.Render(parent, snapshot, resolved)
        parent = unwrap(parent)
        if not valid(parent) or type(snapshot) ~= "table" or type(resolved) ~= "table"
            or tostring(snapshot.profile or "main") == "browser" then
            self.Show(false); return false, "profile-or-parent"
        end
        local tab_labels = lines(snapshot.tabLabels)
        local labels, values = lines(snapshot.labels), lines(snapshot.values)
        local kinds, progress = lines(snapshot.rowKinds), lines(snapshot.rowProgress)
        if #tab_labels == 0 or #labels == 0 or #labels ~= #values then
            self.Show(false); return false, "metadata-missing"
        end
        while #kinds < #labels do kinds[#kinds + 1] = "choice" end
        -- Every row is the same label+value pair of text widgets, so only the row count
        -- decides a rebuild. v0.69.0: a windowed tab shifts its kinds by one row on every
        -- scroll step; comparing kinds here used to rebuild twenty widgets per keypress.
        local row_shape_changed = #state.rows ~= #labels
        state.rowKinds = kinds
        if state.parent ~= parent or #state.tabs ~= #tab_labels then
            if not rebuild_tabs(parent, #tab_labels) then self.Show(false); return false, "tab-create-failed" end
            row_shape_changed = true
        end
        if row_shape_changed and not rebuild_rows(parent, kinds) then
            self.Show(false); return false, "row-create-failed"
        end

        -- v0.69.1: cells never narrower than the six-tab cell (Settings/Layout.TabStrip),
        -- so a seventh tab grows the strip rather than crowding the labels.
        local tab_cell = tab_strip(resolved.tabWidth, #tab_labels).cell
        for index, item in ipairs(state.tabs) do
            if not valid(item.slot) then
                item.slot = attach(parent, item.widget,
                    (tonumber(resolved.safeLeft) or 460) + (index - 1) * tab_cell,
                    tonumber(resolved.tabTop) or -40, 0)
            end
            local selected = tonumber(snapshot.selectedTab) == index
            set_text(item.widget, selected and ("[ " .. tab_labels[index] .. " ]") or tab_labels[index])
            style_text(item.widget, selected
                and { R = 1, G = 1, B = 1, A = 1 }
                or { R = 0.491021, G = 0.423268, B = 0.296138, A = 1 }, tab_cell, 1)
            visible(item.widget, true)
        end

        local row_step = 81.0 -- authored design units; outer shell is 0.50 scale
        for index, item in ipairs(state.rows) do
            if not valid(item.labelSlot) then
                item.labelSlot = attach(parent, item.label, tonumber(resolved.safeLeft) or 460,
                    (tonumber(resolved.rowsTop) or 82) + (index - 1) * row_step, 0)
            end
            if not valid(item.valueSlot) then
                item.valueSlot = attach(parent, item.value, tonumber(resolved.valueLeft) or 830,
                    (tonumber(resolved.rowsTop) or 82) + (index - 1) * row_step, 0)
            end
            local label_widget, value_widget = item.label, item.value
            set_text(label_widget, clean_label(labels[index]))
            set_text(value_widget, values[index])
            local selected = tonumber(snapshot.selectedRow) == index
            local highlight = selected and { R = 1, G = 1, B = 1, A = 1 }
                or { R = 0.491021, G = 0.423268, B = 0.296138, A = 1 }
            style_text(label_widget, highlight, tonumber(resolved.labelWidth) or 330, 0)
            style_text(value_widget, highlight, tonumber(resolved.valueWidth) or 260, 0)
            visible(item.label, true); visible(item.value, true)
        end
        state.active = true
        return true, "native-controls"
    end

    function self.Active() return state.active end
    return self
end

return M
