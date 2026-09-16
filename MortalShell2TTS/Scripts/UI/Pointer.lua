local M = {}

function M.New(options)
    options = options or {}
    local ui = options.ui
    local unwrap = options.unwrap
    local valid = options.valid
    local load_asset = options.load_asset
    local static_find_object = options.static_find_object
    local bpfl_asset = options.native_bpfl_ui_asset
    local bpfl_cdo = options.native_bpfl_ui_cdo

    if type(ui) ~= "table" then return nil, "UI.Pointer requires ui" end
    if type(unwrap) ~= "function" then return nil, "UI.Pointer requires unwrap" end
    if type(valid) ~= "function" then return nil, "UI.Pointer requires valid" end
    if type(load_asset) ~= "function" then return nil, "UI.Pointer requires load_asset" end
    if type(static_find_object) ~= "function" then return nil, "UI.Pointer requires static_find_object" end

    local self = {}

    function self.FiniteNumber(value)
        value = tonumber(value)
        return value ~= nil and value == value and value > -1000000000.0 and value < 1000000000.0
    end

    function self.DirectStructNumber(value, names)
        if value == nil then return nil end
        local function probe(candidate)
            if candidate == nil then return nil end
            for _, name in ipairs(names or {}) do
                local raw = nil
                local ok = pcall(function() raw = candidate[name] end)
                if ok then
                    local number = tonumber(unwrap(raw))
                    if self.FiniteNumber(number) then return number end
                end
            end
            return nil
        end
        local number = probe(value)
        if number ~= nil then return number end
        local unwrapped = unwrap(value)
        if unwrapped ~= value then return probe(unwrapped) end
        return nil
    end

    function self.OutputNumber(holder, names)
        if type(holder) ~= "table" then return tonumber(unwrap(holder)) end
        for _, name in ipairs(names or {}) do
            local value = nil
            pcall(function() value = unwrap(holder[name]) end)
            value = tonumber(value)
            if self.FiniteNumber(value) then return value end
        end
        for _, candidate in pairs(holder) do
            local value = tonumber(unwrap(candidate))
            if self.FiniteNumber(value) then return value end
        end
        return nil
    end

    function self.ReferenceFromBPFL()
        pcall(function() load_asset(bpfl_asset) end)
        local ok_cdo, bpfl = pcall(function() return unwrap(static_find_object(bpfl_cdo)) end)
        if not ok_cdo or not valid(bpfl) or bpfl["GetNormalizedMouseLocation"] == nil then
            return nil, "bpfl-normalized-unavailable"
        end
        local contexts = { ui.controller, ui.widget }
        for _, context in ipairs(contexts) do
            context = unwrap(context)
            if valid(context) then
                for _, factor_viewport_scale in ipairs({ true, false }) do
                    local ok, point = pcall(function() return bpfl:GetNormalizedMouseLocation(factor_viewport_scale, false, context) end)
                    if ok and point ~= nil then
                        local nx = self.DirectStructNumber(point, { "X" })
                        local ny = self.DirectStructNumber(point, { "Y" })
                        if self.FiniteNumber(nx) and self.FiniteNumber(ny)
                            and math.abs(nx) <= 2.0 and math.abs(ny) <= 2.0
                            and not (nx == 0.0 and ny == 0.0) then
                            return {
                                reference_x = (nx + 1.0) * 960.0,
                                reference_y = (ny + 1.0) * 540.0,
                                normalized_x = nx,
                                normalized_y = ny,
                                source = factor_viewport_scale and "BPFL_UI-normalized-dpi" or "BPFL_UI-normalized-logical",
                            }, nil
                        end
                    end
                end
            end
        end
        return nil, "bpfl-normalized-empty"
    end

    function self.ReferenceFromLayout()
        local ok_layout, layout = pcall(function() return unwrap(static_find_object("/Script/UMG.Default__WidgetLayoutLibrary")) end)
        if not ok_layout or not valid(layout) then return nil, "layout-library-unavailable" end
        local contexts = { ui.controller, ui.widget }
        for _, context in ipairs(contexts) do
            context = unwrap(context)
            if valid(context) then
                local ok_pointer, point = pcall(function() return layout:GetMousePositionOnViewport(context) end)
                local ok_viewport, viewport = pcall(function() return layout:GetViewportSize(context) end)
                if ok_pointer and point ~= nil and ok_viewport and viewport ~= nil then
                    local x = self.DirectStructNumber(point, { "X" })
                    local y = self.DirectStructNumber(point, { "Y" })
                    local width = self.DirectStructNumber(viewport, { "X", "Width" })
                    local height = self.DirectStructNumber(viewport, { "Y", "Height" })
                    local scale = 1.0
                    pcall(function()
                        local candidate = tonumber(unwrap(layout:GetViewportScale(context)))
                        if self.FiniteNumber(candidate) and candidate > 0.0 then scale = candidate end
                    end)
                    if self.FiniteNumber(x) and self.FiniteNumber(y)
                        and self.FiniteNumber(width) and self.FiniteNumber(height)
                        and width > 0.0 and height > 0.0
                        and not (x == 0.0 and y == 0.0) then
                        local logical_width = width / scale
                        local logical_height = height / scale
                        local reference_scale = logical_height / 1080.0
                        if reference_scale > 0.0 then
                            return {
                                x = x, y = y, width = logical_width, height = logical_height,
                                reference_x = ((x - (logical_width * 0.5)) / reference_scale) + 960.0,
                                reference_y = y / reference_scale,
                                source = "WidgetLayoutLibrary-controller-context",
                            }, nil
                        end
                    end
                end
            end
        end
        return nil, "layout-pointer-empty"
    end

    function self.ReferenceFromControllerOutParams()
        local controller = unwrap(ui.controller)
        if not valid(controller) then return nil, "controller-invalid" end
        local mouse_x_out, mouse_y_out = {}, {}
        local ok_mouse, mouse_result = pcall(function() return unwrap(controller:GetMousePosition(mouse_x_out, mouse_y_out)) end)
        if not ok_mouse then return nil, "GetMousePosition=" .. tostring(mouse_result) end
        local x = self.OutputNumber(mouse_x_out, { "LocationX", "X" })
        local y = self.OutputNumber(mouse_y_out, { "LocationY", "Y" })
        if x == nil or y == nil then return nil, "mouse-out-parameters-empty" end
        if mouse_result == false then return nil, "mouse-position-unavailable" end
        local width_out, height_out = {}, {}
        local ok_viewport, viewport_error = pcall(function() controller:GetViewportSize(width_out, height_out) end)
        if not ok_viewport then return nil, "GetViewportSize=" .. tostring(viewport_error) end
        local width = self.OutputNumber(width_out, { "SizeX", "X", "Width" })
        local height = self.OutputNumber(height_out, { "SizeY", "Y", "Height" })
        if width == nil or height == nil or width <= 0.0 or height <= 0.0 then return nil, "viewport-out-parameters-empty" end
        local reference_scale = height / 1080.0
        return {
            x = x, y = y, width = width, height = height,
            reference_x = ((x - (width * 0.5)) / reference_scale) + 960.0,
            reference_y = y / reference_scale,
            source = "PlayerController-out-params-fallback",
        }, nil
    end

    function self.Resolve()
        local errors = {}
        for _, resolver in ipairs({ self.ReferenceFromBPFL, self.ReferenceFromLayout, self.ReferenceFromControllerOutParams }) do
            local pointer, err = resolver()
            if pointer ~= nil and self.FiniteNumber(pointer.reference_x) and self.FiniteNumber(pointer.reference_y) then return pointer, nil end
            errors[#errors + 1] = tostring(err or "unknown")
        end
        return nil, table.concat(errors, "|")
    end

    return self
end

return M
