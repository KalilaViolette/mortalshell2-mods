-- MortalShell2ModUI Runtime.Bridge
-- Bounded WBP_InputListener object lifecycle transactions.
-- Consumers retain class discovery, listener lifetime policy/timing, diagnostics,
-- route/dispatch semantics, hooks, modal isolation, world/shell ownership, and
-- close quarantine. This module owns only generic create/attach/handler/remove mechanics.

local Bridge = {}

function Bridge.Bind(Object, Observation)
    if type(Object) ~= "table" then error("Runtime.Bridge requires Core.Object", 0) end
    if type(Observation) ~= "table" or type(Observation.SafeProperty) ~= "function" then
        error("Runtime.Bridge requires Runtime.Observation", 0)
    end

    local Bound = {}

    local function valid(value)
        return Object.Valid(Object.Unwrap(value))
    end

    function Bound.CreateListener(player, controller, library, listener_class)
        player = Object.Unwrap(player)
        controller = Object.Unwrap(controller)
        library = Object.Unwrap(library)
        listener_class = Object.Unwrap(listener_class)

        local result = {
            ok = false,
            status = "invalid-prerequisite",
            listener = nil,
            error = nil,
            defaults = nil,
            defaultWrites = {},
        }

        if not valid(player) or not valid(controller) or not valid(library) or not valid(listener_class) then
            return result
        end

        local create = library["Create"]
        if create == nil then
            result.status = "create-unavailable"
            return result
        end

        local ok_create, listener = pcall(create, library, player, listener_class, controller)
        listener = Object.Unwrap(listener)
        result.listener = listener
        if not ok_create or not valid(listener) then
            result.status = "create-failed"
            result.error = tostring(listener)
            return result
        end

        result.defaults = {
            IgnoreBlockAll = select(1, Observation.SafeProperty(listener, "IgnoreBlockAll")),
            bInvalidate = select(1, Observation.SafeProperty(listener, "bInvalidate")),
            bAutoActivate = select(1, Observation.SafeProperty(listener, "bAutoActivate")),
            bEnabled = select(1, Observation.SafeProperty(listener, "bEnabled")),
        }

        local writes = {
            { field = "bAutoActivate", value = false },
            { field = "bEnabled", value = false },
            { field = "Silent", value = true },
        }
        for _, write in ipairs(writes) do
            local ok_write, write_error = pcall(function()
                listener[write.field] = write.value
            end)
            result.defaultWrites[write.field] = {
                ok = ok_write,
                error = ok_write and nil or tostring(write_error),
            }
        end

        result.ok = true
        result.status = "created"
        return result
    end

    function Bound.AttachViewport(listener, z_order)
        listener = Object.Unwrap(listener)
        local result = {
            ok = false,
            status = "listener-invalid",
            viewportError = nil,
            opacity = nil,
            visibility = nil,
        }
        if not valid(listener) then return result end

        local ok_viewport, viewport_error = pcall(function()
            listener:AddToViewport(math.floor(tonumber(z_order) or 9999))
        end)
        result.viewportError = ok_viewport and nil or tostring(viewport_error)
        if not ok_viewport then
            result.status = "viewport-failed"
            return result
        end

        local ok_opacity, opacity_error = pcall(function() listener:SetRenderOpacity(0.0) end)
        result.opacity = {
            ok = ok_opacity,
            error = ok_opacity and nil or tostring(opacity_error),
        }

        local ok_visibility, visibility_error = pcall(function() listener:SetVisibility(3) end)
        result.visibility = {
            ok = ok_visibility,
            error = ok_visibility and nil or tostring(visibility_error),
        }

        result.ok = true
        result.status = "attached"
        return result
    end

    function Bound.EnsureHandler(listener, handler)
        listener = Object.Unwrap(listener)
        handler = Object.Unwrap(handler)
        local result = {
            ok = false,
            status = "invalid-prerequisite",
            constructedHandler = nil,
            constructedHandlerError = nil,
            handlerSame = false,
            assignment = "not-attempted",
            assignmentError = nil,
        }
        if not valid(listener) or not valid(handler) then return result end

        local constructed_handler, constructed_error = Observation.SafeProperty(listener, "UserInterfaceComponent")
        constructed_handler = Object.Unwrap(constructed_handler)
        result.constructedHandler = constructed_handler
        result.constructedHandlerError = constructed_error
        result.handlerSame = valid(constructed_handler) and Object.Same(constructed_handler, handler)

        if result.handlerSame then
            result.assignment = "already-correct"
            result.ok = true
            result.status = "already-correct"
            return result
        end

        local ok_assign, assign_error = pcall(function()
            listener.UserInterfaceComponent = handler
        end)
        if not ok_assign then
            result.status = "assignment-failed"
            result.assignment = "failed"
            result.assignmentError = tostring(assign_error)
            return result
        end

        result.assignment = "assigned"
        result.ok = true
        result.status = "assigned"
        return result
    end

    function Bound.RemoveListener(listener)
        listener = Object.Unwrap(listener)
        local result = {
            ok = false,
            status = "listener-invalid",
            error = nil,
        }
        if not valid(listener) then return result end

        local ok_remove, remove_error = pcall(function()
            listener:RemoveFromParent()
        end)
        if not ok_remove then
            result.status = "remove-failed"
            result.error = tostring(remove_error)
            return result
        end

        result.ok = true
        result.status = "removed"
        return result
    end

    return Bound
end

return Bridge
