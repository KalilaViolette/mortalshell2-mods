-- MortalShell2TTS read-only native-widget diagnostics
-- Pass 85 / v0.9.162 extracts the existing donor/widget inspection helpers from main.lua.
-- This module is diagnostics-only: it does not create, mutate, attach, remove, or own widgets.

local M = {}

function M.New(deps)
    if type(deps) ~= "table" then return nil, "deps-required" end
    local unwrap = deps.unwrap
    local valid = deps.valid
    local object_name = deps.object_name
    local object_address = deps.object_address
    local widget_text = deps.widget_text
    local native_widget_field = deps.native_widget_field
    local safe_property = deps.safe_property
    local diag = deps.diag
    if type(unwrap) ~= "function" or type(valid) ~= "function"
        or type(object_name) ~= "function" or type(object_address) ~= "function"
        or type(widget_text) ~= "function" or type(native_widget_field) ~= "function"
        or type(safe_property) ~= "function" or type(diag) ~= "function" then
        return nil, "invalid-dependencies"
    end

    local api = {}

function api.struct_field(value, field)
    value = unwrap(value)
    if value == nil then return nil end
    local ok, result = pcall(function() return unwrap(value[field]) end)
    if ok then return result end
    return nil
end

function api.vector2_string(value)
    value = unwrap(value)
    if value == nil then return "<nil>" end
    local x = tonumber(api.struct_field(value, "X"))
    local y = tonumber(api.struct_field(value, "Y"))
    if x == nil and y == nil then return tostring(value) end
    return string.format("%.3f,%.3f", x or 0.0, y or 0.0)
end

function api.margin_string(value)
    value = unwrap(value)
    if value == nil then return "<nil>" end
    local left = tonumber(api.struct_field(value, "Left"))
    local top = tonumber(api.struct_field(value, "Top"))
    local right = tonumber(api.struct_field(value, "Right"))
    local bottom = tonumber(api.struct_field(value, "Bottom"))
    if left == nil and top == nil and right == nil and bottom == nil then return tostring(value) end
    return string.format("%.3f,%.3f,%.3f,%.3f", left or 0.0, top or 0.0, right or 0.0, bottom or 0.0)
end

function api.widget_desired_size(widget)
    widget = unwrap(widget)
    if not valid(widget) or widget["GetDesiredSize"] == nil then return "<unavailable>" end
    local ok, value = pcall(function() return unwrap(widget:GetDesiredSize()) end)
    if not ok then return "<error:" .. tostring(value) .. ">" end
    return api.vector2_string(value)
end

function api.widget_visibility_value(widget)
    widget = unwrap(widget)
    if not valid(widget) or widget["GetVisibility"] == nil then return "<unavailable>" end
    local ok, value = pcall(function() return unwrap(widget:GetVisibility()) end)
    if not ok then return "<error:" .. tostring(value) .. ">" end
    return tostring(value)
end

function api.widget_text_value(widget)
    widget = unwrap(widget)
    if not valid(widget) then return "<invalid>" end
    local value = widget_text(widget)
    if value == nil then return "<unavailable>" end
    return value
end

function api.slot_diagnostic(child)
    child = unwrap(child)
    if not valid(child) then return {
        slot = "<invalid-child>",
        sizeRule = "<unknown>",
        sizeValue = "<unknown>",
        padding = "<unknown>",
        hAlign = "<unknown>",
        vAlign = "<unknown>",
    } end

    local slot = select(1, safe_property(child, "Slot"))
    if not valid(slot) then return {
        slot = "<none>",
        sizeRule = "<unknown>",
        sizeValue = "<unknown>",
        padding = "<unknown>",
        hAlign = "<unknown>",
        vAlign = "<unknown>",
    } end

    local size_rule, size_value = "<n/a>", "<n/a>"
    if slot["GetSize"] ~= nil then
        local ok, size = pcall(function() return unwrap(slot:GetSize()) end)
        if ok and size ~= nil then
            size_rule = tostring(api.struct_field(size, "SizeRule") or "<nil>")
            size_value = tostring(api.struct_field(size, "Value") or "<nil>")
        else
            size_rule = "<error>"
            size_value = tostring(size)
        end
    end

    local padding = "<n/a>"
    if slot["GetPadding"] ~= nil then
        local ok, value = pcall(function() return unwrap(slot:GetPadding()) end)
        padding = ok and api.margin_string(value) or ("<error:" .. tostring(value) .. ">")
    else
        local direct = select(1, safe_property(slot, "Padding"))
        if direct ~= nil then padding = api.margin_string(direct) end
    end

    local h_align, v_align = "<n/a>", "<n/a>"
    if slot["GetHorizontalAlignment"] ~= nil then
        local ok, value = pcall(function() return unwrap(slot:GetHorizontalAlignment()) end)
        h_align = ok and tostring(value) or ("<error:" .. tostring(value) .. ">")
    else
        local direct = select(1, safe_property(slot, "HorizontalAlignment"))
        if direct ~= nil then h_align = tostring(direct) end
    end
    if slot["GetVerticalAlignment"] ~= nil then
        local ok, value = pcall(function() return unwrap(slot:GetVerticalAlignment()) end)
        v_align = ok and tostring(value) or ("<error:" .. tostring(value) .. ">")
    else
        local direct = select(1, safe_property(slot, "VerticalAlignment"))
        if direct ~= nil then v_align = tostring(direct) end
    end

    return {
        slot = object_name(slot),
        sizeRule = size_rule,
        sizeValue = size_value,
        padding = padding,
        hAlign = h_align,
        vAlign = v_align,
    }
end

function api.dump_widget_tree_readonly(root, label)
    root = unwrap(root)
    label = tostring(label or "widget")
    if not valid(root) then
        diag("donor.tree", { label = label, status = "root-invalid" })
        return
    end

    local visited = {}
    local function recurse(node, depth, child_index)
        node = unwrap(node)
        if not valid(node) then
            diag("donor.tree", {
                label = label,
                depth = depth,
                childIndex = child_index,
                status = "invalid-node",
            })
            return
        end

        local address = object_address(node)
        local key = address and tostring(address) or object_name(node)
        if visited[key] then
            diag("donor.tree", {
                label = label,
                depth = depth,
                childIndex = child_index,
                node = object_name(node),
                status = "cycle-or-duplicate",
            })
            return
        end
        visited[key] = true

        local parent = nil
        local parent_name = "<none>"
        if node["GetParent"] ~= nil then
            local ok, value = pcall(function() return unwrap(node:GetParent()) end)
            if ok and valid(value) then
                parent = value
                parent_name = object_name(value)
            end
        end

        local slot = api.slot_diagnostic(node)
        diag("donor.tree", {
            label = label,
            depth = depth,
            childIndex = child_index ~= nil and child_index or "<root>",
            node = object_name(node),
            parent = parent_name,
            desired = api.widget_desired_size(node),
            visibility = api.widget_visibility_value(node),
            slot = slot.slot,
            sizeRule = slot.sizeRule,
            sizeValue = slot.sizeValue,
            padding = slot.padding,
            hAlign = slot.hAlign,
            vAlign = slot.vAlign,
        })

        if node["GetChildrenCount"] == nil or node["GetChildAt"] == nil then return end
        local ok_count, count = pcall(function() return tonumber(node:GetChildrenCount()) end)
        if not ok_count or count == nil then
            diag("donor.tree.children", {
                label = label,
                node = object_name(node),
                status = "count-failed",
                error = tostring(count),
            })
            return
        end

        diag("donor.tree.children", {
            label = label,
            node = object_name(node),
            count = count,
        })

        for index = 0, count - 1 do
            local ok_child, child = pcall(function() return unwrap(node:GetChildAt(index)) end)
            if ok_child and valid(child) then
                recurse(child, depth + 1, index)
            else
                diag("donor.tree.child", {
                    label = label,
                    node = object_name(node),
                    index = index,
                    status = "read-failed",
                    error = tostring(child),
                })
            end
        end
    end

    recurse(root, 0, nil)
end

function api.dump_size_box_readonly(box, label)
    box = unwrap(box)
    label = tostring(label or "SizeBox")
    if not valid(box) then
        diag("donor.sizebox", { label = label, status = "invalid" })
        return
    end

    local fields = {
        "bOverride_WidthOverride", "WidthOverride",
        "bOverride_HeightOverride", "HeightOverride",
        "bOverride_MinDesiredWidth", "MinDesiredWidth",
        "bOverride_MinDesiredHeight", "MinDesiredHeight",
        "bOverride_MaxDesiredWidth", "MaxDesiredWidth",
        "bOverride_MaxDesiredHeight", "MaxDesiredHeight",
        "bOverride_MinAspectRatio", "MinAspectRatio",
        "bOverride_MaxAspectRatio", "MaxAspectRatio",
    }
    local values = {
        label = label,
        object = object_name(box),
        desired = api.widget_desired_size(box),
    }
    for _, field in ipairs(fields) do
        local value, err = safe_property(box, field)
        values[field] = value ~= nil and tostring(value) or ("<unavailable:" .. tostring(err) .. ">")
    end
    diag("donor.sizebox", values)
end

function api.dump_scale_box_readonly(box, label)
    box = unwrap(box)
    label = tostring(label or "ScaleBox")
    if not valid(box) then
        diag("donor.scalebox", { label = label, status = "invalid" })
        return
    end

    local values = {
        label = label,
        object = object_name(box),
        desired = api.widget_desired_size(box),
    }
    for _, field in ipairs({ "Stretch", "StretchDirection", "UserSpecifiedScale", "IgnoreInheritedScale" }) do
        local value, err = safe_property(box, field)
        values[field] = value ~= nil and tostring(value) or ("<unavailable:" .. tostring(err) .. ">")
    end
    diag("donor.scalebox", values)
end

function api.dump_rich_text_readonly(text_widget, label)
    text_widget = unwrap(text_widget)
    label = tostring(label or "RichText")
    if not valid(text_widget) then
        diag("donor.text", { label = label, status = "invalid" })
        return
    end

    local style_set_name = "<unavailable>"
    if text_widget["GetTextStyleSet"] ~= nil then
        local ok, style = pcall(function() return unwrap(text_widget:GetTextStyleSet()) end)
        if ok and valid(style) then style_set_name = object_name(style) end
    end

    local style_class_name = "<nil>"
    do
        local style_class = select(1, safe_property(text_widget, "DefaultTextStyleOverrideClass"))
        if valid(style_class) then style_class_name = object_name(style_class) end
    end

    local values = {
        label = label,
        object = object_name(text_widget),
        desired = api.widget_desired_size(text_widget),
        visibility = api.widget_visibility_value(text_widget),
        text = api.widget_text_value(text_widget),
        TextStyleSet = style_set_name,
        DefaultTextStyleOverrideClass = style_class_name,
    }
    for _, field in ipairs({
        "Justification",
        "AutoWrapText",
        "WrapTextAt",
        "TextOverflowPolicy",
        "Clipping",
        "MinDesiredWidth",
        "MobileTextBlockScale",
        "bAutoCollapseWithEmptyText",
    }) do
        local value, err = safe_property(text_widget, field)
        values[field] = value ~= nil and tostring(value) or ("<unavailable:" .. tostring(err) .. ">")
    end
    diag("donor.text", values)
end

function api.dump_progression_attribute_readonly(widget, label)
    widget = unwrap(widget)
    label = tostring(label or "progression-row")
    if not valid(widget) then
        diag("donor.begin", { label = label, status = "invalid" })
        return
    end

    local header_max, header_max_error = safe_property(widget, "HeaderMaxWidth")
    diag("donor.begin", {
        label = label,
        object = object_name(widget),
        address = object_address(widget) or "<unknown>",
        desired = api.widget_desired_size(widget),
        HeaderMaxWidth = header_max ~= nil and tostring(header_max) or ("<unavailable:" .. tostring(header_max_error) .. ">"),
    })

    -- 1/8 Desired size (before prepass).
    diag("donor.desired", {
        label = label,
        phase = "before-prepass",
        desired = api.widget_desired_size(widget),
    })

    -- 2/8 Parent/child topology and 3/8 HorizontalBox slot rules +
    -- 4/8 padding/alignment are emitted by the recursive panel dumper.
    local widget_tree = select(1, safe_property(widget, "WidgetTree"))
    local root = nil
    if valid(widget_tree) then root = select(1, safe_property(widget_tree, "RootWidget")) end
    if valid(root) then
        api.dump_widget_tree_readonly(root, label)
    else
        diag("donor.tree", {
            label = label,
            status = "root-unavailable",
            widgetTree = valid(widget_tree) and object_name(widget_tree) or "<invalid>",
        })
    end

    -- 5/8 SizeBox flags/values.
    api.dump_size_box_readonly(native_widget_field(widget, "SizeBox_Stats"), label .. ".SizeBox_Stats")
    api.dump_size_box_readonly(native_widget_field(widget, "SizeBox_Header"), label .. ".SizeBox_Header")
    api.dump_size_box_readonly(native_widget_field(widget, "SizeBox_Value"), label .. ".SizeBox_Value")

    -- 6/8 ScaleBox_Header tuple.
    api.dump_scale_box_readonly(native_widget_field(widget, "ScaleBox_Header"), label .. ".ScaleBox_Header")

    -- 7/8 Header/value style/layout state.
    api.dump_rich_text_readonly(native_widget_field(widget, "RTB_Ability_Stat_Header"), label .. ".Header")
    api.dump_rich_text_readonly(native_widget_field(widget, "RTB_Ability_Stat_Value"), label .. ".Value")

    -- 8/8 Dot/Image visibility + debug overlay state.
    for _, field in ipairs({ "Dot", "Image_74", "Debug" }) do
        local child = native_widget_field(widget, field)
        diag("donor.decoration", {
            label = label,
            field = field,
            object = valid(child) and object_name(child) or "<invalid>",
            visibility = api.widget_visibility_value(child),
            desired = api.widget_desired_size(child),
            text = field == "Debug" and api.widget_text_value(child) or "<n/a>",
        })
    end

    -- Read-only ForceLayoutPrepass. This may still leave DesiredSize at zero for
    -- an entirely offscreen widget, but the before/after pair tells us exactly
    -- what this cooked widget does without live attachment.
    local prepass_status = "unavailable"
    if widget["ForceLayoutPrepass"] ~= nil then
        local ok, err = pcall(function() widget:ForceLayoutPrepass() end)
        prepass_status = ok and "ok" or ("failed:" .. tostring(err))
    end
    diag("donor.desired", {
        label = label,
        phase = "after-prepass",
        prepass = prepass_status,
        desired = api.widget_desired_size(widget),
    })
    diag("donor.end", { label = label, status = "complete" })
end


    return api
end

return M
