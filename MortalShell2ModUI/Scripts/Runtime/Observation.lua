-- MortalShell2ModUI Runtime.Observation
-- Read-only UE4SS runtime observation helpers. Consumers still own object discovery,
-- diagnostics, mutation, hooks, world lifetime, shell creation and modal behavior.

local Observation = {}

function Observation.Bind(Object, Array)
    if type(Object) ~= "table" then error("Runtime.Observation requires Core.Object", 0) end
    if type(Array) ~= "table" then error("Runtime.Observation requires Core.Array", 0) end

    local Bound = {}

    function Bound.SafeProperty(object, field)
        object = Object.Unwrap(object)
        if object == nil then return nil, "object=nil" end
        local ok, value = pcall(function() return Object.Unwrap(object[field]) end)
        if not ok then return nil, tostring(value) end
        return value, nil
    end

    function Bound.SafeBoolMethod(object, method_name, ...)
        object = Object.Unwrap(object)
        if not Object.Valid(object) then return nil, "object invalid" end
        local method = object[method_name]
        if method == nil then return nil, "method unavailable" end

        local args = { ... }
        local ok, value = pcall(function()
            return Object.Unwrap(method(object, table.unpack(args)))
        end)
        if not ok then return nil, tostring(value) end
        if value == true or value == false then return value, nil end
        return nil, "non-bool result=" .. tostring(value)
    end

    function Bound.ObjectFieldName(object, field)
        local value, err = Bound.SafeProperty(object, field)
        if value == nil then return "<nil>", false, err end
        if Object.Valid(value) then return Object.Name(value), true, nil end
        return "<invalid>", false, nil
    end

    function Bound.ControllerPropertyBool(controller, field)
        controller = Object.Unwrap(controller)
        if not Object.Valid(controller) then return false end
        local ok, value = pcall(function() return controller[field] end)
        return ok and Object.Unwrap(value) == true
    end

    function Bound.ControllerIgnoredState(controller, method_name)
        controller = Object.Unwrap(controller)
        if not Object.Valid(controller) then return false, false end
        local method = controller[method_name]
        if method == nil then return false, false end
        local ok, value = pcall(method, controller)
        if not ok then return false, false end
        return true, Object.Unwrap(value) == true
    end

    function Bound.MenuQuery(handler, field)
        handler = Object.Unwrap(handler)
        if not Object.Valid(handler) or handler["CanOpenGameMenu"] == nil then
            return false, nil, "handler-or-method-unavailable"
        end

        local ok_query, query = pcall(function() return Object.Unwrap(handler[field]) end)
        if not ok_query or query == nil then return false, nil, tostring(query) end
        local ok_allowed, allowed = pcall(function()
            return Object.Unwrap(handler:CanOpenGameMenu(query))
        end)
        if not ok_allowed then return false, nil, tostring(allowed) end
        return true, allowed == true, nil
    end

    function Bound.ListenerInputHandleCount(listener)
        listener = Object.Unwrap(listener)
        if not Object.Valid(listener) then return nil, "listener invalid" end
        local handles, field_error = Bound.SafeProperty(listener, "InputEventsHandle")
        if handles == nil then return nil, field_error or "InputEventsHandle unavailable" end
        return Array.Count(handles)
    end

    function Bound.HandlerActiveListenerSnapshot(handler, listener)
        handler = Object.Unwrap(handler)
        listener = Object.Unwrap(listener)
        if not Object.Valid(handler) then
            return nil, false, {}, "handler invalid"
        end

        local array_value, field_error = Bound.SafeProperty(handler, "ActiveListeners")
        if array_value == nil then
            return nil, false, {}, field_error or "ActiveListeners unavailable"
        end

        local entries, read_error = Array.ObjectEntries(array_value)
        if entries == nil then
            return nil, false, {}, read_error
        end

        local names = {}
        local contains = false
        for _, entry in ipairs(entries) do
            names[#names + 1] = tostring(entry.index) .. ":" .. entry.name
            if Object.Valid(listener) and Object.Valid(entry.object) and Object.Same(entry.object, listener) then
                contains = true
            end
        end
        return #entries, contains, names, nil
    end

    function Bound.AdmissionSnapshot(handler, controller)
        handler = Object.Unwrap(handler)
        controller = Object.Unwrap(controller)

        if not Object.Valid(handler) then
            return {
                handlerValid = false,
            }, {
                ActiveMenu = "<nil>",
                ActiveSubMenu = "<nil>",
                ActiveReadText = "<nil>",
                CurrentTransitionWidget = "<nil>",
                ActiveConfirmations = nil,
                NoActiveMenu = nil,
                NoActiveMenuError = "handler invalid",
                ControllerIsInGameMenu = nil,
                ControllerIsInGameMenuError = "handler invalid",
                HandlerIsInGameMenu = nil,
                CanOpenOptions = nil,
                CanOpenOptionsError = "handler invalid",
            }
        end

        local active_menu_name, active_menu_valid = Bound.ObjectFieldName(handler, "ActiveMenu")
        local active_submenu_name, active_submenu_valid = Bound.ObjectFieldName(handler, "ActiveSubMenu")
        local active_read_name, active_read_valid = Bound.ObjectFieldName(handler, "ActiveReadText")
        local transition_name, transition_valid = Bound.ObjectFieldName(handler, "CurrentTransitionWidget")

        local confirmations_count = nil
        do
            local confirmations = Bound.SafeProperty(handler, "ActiveConfirmations")
            if confirmations ~= nil then
                confirmations_count = select(1, Array.Count(confirmations))
            end
        end

        local no_active_menu, no_active_menu_error = Bound.SafeBoolMethod(handler, "NoActiveMenu")
        local controller_in_menu, controller_in_menu_error = Bound.SafeBoolMethod(controller, "IsInGameMenu")

        local handler_in_menu = nil
        do
            local value = Bound.SafeProperty(handler, "bIsInGameMenu")
            if value == true or value == false then handler_in_menu = value end
        end

        local can_open_options, can_open_error = nil, nil
        do
            local query, query_error = Bound.SafeProperty(handler, "OptionsMenuQuery")
            if query ~= nil and handler["CanOpenGameMenu"] ~= nil then
                local ok, value = pcall(function()
                    return Object.Unwrap(handler:CanOpenGameMenu(query))
                end)
                if ok and (value == true or value == false) then
                    can_open_options = value
                elseif not ok then
                    can_open_error = tostring(value)
                else
                    can_open_error = query_error or ("non-bool result=" .. tostring(value))
                end
            else
                can_open_error = query_error or "query/method unavailable"
            end
        end

        return {
            handlerValid = true,
            activeMenuValid = active_menu_valid,
            activeSubMenuValid = active_submenu_valid,
            activeReadTextValid = active_read_valid,
            transitionValid = transition_valid,
            confirmationsCount = confirmations_count,
            noActiveMenu = no_active_menu,
            controllerInMenu = controller_in_menu,
            handlerInMenu = handler_in_menu,
            canOpenOptions = can_open_options,
        }, {
            ActiveMenu = active_menu_name,
            ActiveSubMenu = active_submenu_name,
            ActiveReadText = active_read_name,
            CurrentTransitionWidget = transition_name,
            ActiveConfirmations = confirmations_count,
            NoActiveMenu = no_active_menu,
            NoActiveMenuError = no_active_menu_error,
            ControllerIsInGameMenu = controller_in_menu,
            ControllerIsInGameMenuError = controller_in_menu_error,
            HandlerIsInGameMenu = handler_in_menu,
            CanOpenOptions = can_open_options,
            CanOpenOptionsError = can_open_error,
        }
    end

    return Bound
end

return Observation
