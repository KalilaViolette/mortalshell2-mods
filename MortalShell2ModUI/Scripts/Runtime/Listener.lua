-- MortalShell2ModUI Runtime.Listener
-- Input-listener/runtime-route helpers.
-- Pass 54 owns bounded listener binding enable/disable transactions on top of
-- Pass-53 AcceptedInputs mutation. Pass 55 moved generic UE4SS hook lifecycle into
-- Runtime.Hook; Pass 56 moved bounded listener-object lifecycle mechanics into
-- Runtime.Bridge; Pass 57 composes route/mutation/binding with Runtime.Hook in
-- Runtime.InputBridge. Consumers still own class discovery, lifecycle timing, callback
-- semantics, dispatch, diagnostics, polling/scheduling, world/shell ownership,
-- pause/effects, and close quarantine.

local Listener = {}

function Listener.Bind(Object, Array, Acceptance, Route)
    if type(Object) ~= "table" then error("Runtime.Listener requires Core.Object", 0) end
    if type(Array) ~= "table" then error("Runtime.Listener requires Core.Array", 0) end
    if type(Acceptance) ~= "table" then error("Runtime.Listener requires Input.Acceptance", 0) end
    if type(Route) ~= "table" or type(Route.Action) ~= "function" then
        error("Runtime.Listener requires Input.Route", 0)
    end

    local Bound = {}

    function Bound.MapFind(map, key)
        map = Object.Unwrap(map)
        if map == nil then return nil end

        local ok_contains, contains = pcall(function() return map:Contains(key) end)
        if ok_contains and Object.Unwrap(contains) ~= true then return nil end

        local ok_find, value = pcall(function() return Object.Unwrap(map:Find(key)) end)
        if ok_find and Object.Valid(value) then return value end
        return nil
    end

    function Bound.BuildRoutes(listener, minimum_input, maximum_input)
        listener = Object.Unwrap(listener)
        if not Object.Valid(listener) then
            return {
                status = "listener-invalid",
                accepted = {},
                routeByEnum = {},
                routeByAction = {},
                actionNameByEnum = {},
                mouseInputReady = false,
                entries = {},
            }
        end

        local ok_map, interface_inputs = pcall(function()
            return Object.Unwrap(listener.InterfaceInputs)
        end)
        if not ok_map or interface_inputs == nil then
            return {
                status = "interface-map-unavailable",
                error = tostring(interface_inputs),
                accepted = {},
                routeByEnum = {},
                routeByAction = {},
                actionNameByEnum = {},
                mouseInputReady = false,
                entries = {},
            }
        end

        local low = math.floor(tonumber(minimum_input) or 0)
        local high = math.floor(tonumber(maximum_input) or 32)
        if high < low then low, high = high, low end

        local accepted = {}
        local seen = {}
        local route_by_enum = {}
        local route_by_action = {}
        local action_name_by_enum = {}
        local mouse_input_ready = false
        local entries = {}

        for input = low, high do
            local action = Bound.MapFind(interface_inputs, input)
            if Object.Valid(action) then
                local name = Object.Name(action)
                local route = Route.Action(name)
                if route ~= nil then
                    route_by_enum[input] = route
                    route_by_action[name] = route
                    action_name_by_enum[input] = name
                    if route:find("mouse_", 1, true) == 1 then
                        mouse_input_ready = true
                    end
                    if not seen[input] then
                        accepted[#accepted + 1] = input
                        seen[input] = true
                    end
                    entries[#entries + 1] = {
                        enum = input,
                        action = name,
                        route = route,
                    }
                end
            end
        end

        table.sort(accepted)
        return {
            status = #accepted > 0 and "ok" or "empty",
            accepted = accepted,
            routeByEnum = route_by_enum,
            routeByAction = route_by_action,
            actionNameByEnum = action_name_by_enum,
            mouseInputReady = mouse_input_ready,
            entries = entries,
        }
    end

    local function read_accepted_inputs(listener)
        local ok_array, accepted_array = pcall(function()
            return Object.Unwrap(listener.AcceptedInputs)
        end)
        if not ok_array then
            return nil, tostring(accepted_array)
        end
        return Array.ByteValues(accepted_array)
    end

    function Bound.ConfigureAcceptedInputs(listener, desired)
        listener = Object.Unwrap(listener)
        if not Object.Valid(listener) or type(desired) ~= "table" or #desired == 0 then
            return {
                ok = false,
                status = "invalid-arguments",
                desiredCount = type(desired) == "table" and #desired or nil,
                changed = false,
                missing = {},
                unexpected = {},
            }
        end

        local original, original_error = read_accepted_inputs(listener)
        local result = {
            ok = false,
            status = "pending",
            desiredCount = #desired,
            desired = desired,
            original = original,
            originalError = original_error,
            changed = false,
            verified = nil,
            verifyError = nil,
            missing = {},
            unexpected = {},
            restore = nil,
        }

        local ok_set, set_error = pcall(function()
            listener.AcceptedInputs = desired
        end)
        if not ok_set then
            result.status = "assignment-failed"
            result.error = tostring(set_error)
            return result
        end

        -- Mutation has happened even if verification fails. Preserve an explicit
        -- ownership bit so the caller can account for the successful mutation and
        -- the shared helper can fail-soft by restoring the original snapshot.
        result.changed = true

        local verified, verify_error = read_accepted_inputs(listener)
        result.verified = verified
        result.verifyError = verify_error
        if verified == nil then
            result.status = "read-failed"
            result.restore = Bound.RestoreAcceptedInputs(listener, original, true)
            return result
        end

        local missing, unexpected = Acceptance.SetDiff(desired, verified)
        result.missing = missing
        result.unexpected = unexpected
        local exact = #desired == #verified and #missing == 0 and #unexpected == 0
        if not exact then
            result.status = "mismatch"
            result.restore = Bound.RestoreAcceptedInputs(listener, original, true)
            return result
        end

        result.ok = true
        result.status = "exact"
        return result
    end

    function Bound.RestoreAcceptedInputs(listener, original, changed)
        listener = Object.Unwrap(listener)
        local result = {
            ok = true,
            status = "not-owned",
            expected = original,
            active = nil,
            missing = {},
            unexpected = {},
        }

        if changed ~= true or not Object.Valid(listener) then
            return result
        end

        if type(original) ~= "table" then
            result.ok = false
            result.status = "original-unknown"
            return result
        end

        local ok_set, set_error = pcall(function()
            listener.AcceptedInputs = original
        end)
        if not ok_set then
            result.ok = false
            result.status = "assignment-failed"
            result.error = tostring(set_error)
            return result
        end

        local restored, read_error = read_accepted_inputs(listener)
        result.active = restored
        result.readError = read_error
        if restored == nil then
            result.ok = false
            result.status = "read-failed"
            return result
        end

        local missing, unexpected = Acceptance.SetDiff(original, restored)
        result.missing = missing
        result.unexpected = unexpected
        local exact = #original == #restored and #missing == 0 and #unexpected == 0
        result.ok = exact
        result.status = exact and "exact" or "mismatch"
        return result
    end


    function Bound.DisableBindings(listener)
        listener = Object.Unwrap(listener)
        local result = {
            ok = true,
            status = "listener-invalid",
            setEnabledStateOk = true,
            setEnabledStateError = nil,
            unbindInputsOk = true,
            unbindInputsError = nil,
        }

        if not Object.Valid(listener) then
            return result
        end

        result.status = "pending"
        if listener["SetEnabledState"] ~= nil then
            local ok_disable, disable_error = pcall(function()
                listener:SetEnabledState(false)
            end)
            result.setEnabledStateOk = ok_disable
            result.setEnabledStateError = ok_disable and nil or tostring(disable_error)
        end

        local ok_unbind, unbind_error = pcall(function()
            if listener["UnbindInputs"] ~= nil then listener:UnbindInputs() end
            listener.bEnabled = false
        end)
        result.unbindInputsOk = ok_unbind
        result.unbindInputsError = ok_unbind and nil or tostring(unbind_error)

        result.ok = result.setEnabledStateOk and result.unbindInputsOk
        result.status = result.ok and "ok" or "partial-failure"
        return result
    end

    function Bound.EnableBindings(listener)
        listener = Object.Unwrap(listener)
        local result = {
            ok = false,
            status = "listener-invalid",
            path = "none",
            initialError = nil,
            scrub = nil,
            bindError = nil,
        }

        if not Object.Valid(listener) then
            return result
        end

        local ok_enable, enable_error = pcall(function()
            listener:SetEnabledState(true)
        end)
        if ok_enable then
            result.ok = true
            result.status = "ok"
            result.path = "SetEnabledState"
            return result
        end

        result.initialError = tostring(enable_error)

        -- Blueprint execution can fail after earlier nodes already ran. Preserve the
        -- proven consumer behavior: scrub any partial listener-owned binding state
        -- before attempting the direct BindInputs compatibility fallback.
        result.scrub = Bound.DisableBindings(listener)

        local ok_bind, bind_error = pcall(function()
            listener.bEnabled = true
            listener:BindInputs()
        end)
        if not ok_bind then
            result.status = "bind-fallback-failed"
            result.path = "BindInputs-fallback"
            result.bindError = tostring(bind_error)
            return result
        end

        result.ok = true
        result.status = "ok"
        result.path = "BindInputs-fallback"
        return result
    end

    function Bound.ControllerIsGamepad(controller)
        controller = Object.Unwrap(controller)
        if not Object.Valid(controller) then
            return false, "controller-invalid"
        end
        if controller["IsUsingGamepadForFeedback"] == nil then
            return false, "method-unavailable"
        end

        local ok, value = pcall(function()
            return Object.Unwrap(controller:IsUsingGamepadForFeedback())
        end)
        if not ok then
            return false, "probe-failed", tostring(value)
        end
        return value == true, "ok"
    end

    function Bound.AcceptanceSnapshot(listener, input_number, action_name_by_enum, fallback_accepted)
        listener = Object.Unwrap(listener)
        input_number = tonumber(input_number)
        local action_map = type(action_name_by_enum) == "table" and action_name_by_enum or {}
        local snapshot = {
            enabled = nil,
            accepted = nil,
            secondaryBlocked = nil,
            tertiaryBlocked = nil,
            action = action_map[input_number or -1] or "<unknown>",
            error = "",
        }

        if not Object.Valid(listener) or input_number == nil then
            snapshot.error = "listener/input invalid"
            return false, snapshot
        end

        local ok_enabled, enabled = pcall(function()
            return Object.Unwrap(listener:IsEnabled())
        end)
        if ok_enabled and (enabled == true or enabled == false) then
            snapshot.enabled = enabled
        elseif not ok_enabled then
            snapshot.error = snapshot.error .. " IsEnabled=" .. tostring(enabled)
        end

        local accepted_values = nil
        local ok_array, accepted_array = pcall(function()
            return Object.Unwrap(listener.AcceptedInputs)
        end)
        if ok_array then
            accepted_values = select(1, Array.ByteValues(accepted_array))
        end
        if accepted_values == nil then
            accepted_values = type(fallback_accepted) == "table" and fallback_accepted or {}
        end
        snapshot.accepted = Acceptance.Contains(accepted_values, input_number)

        local action_name = snapshot.action
        if action_name:find("_Secondary", 1, true) and listener["IsSecondaryNavigationBlocked"] ~= nil then
            local ok, blocked = pcall(function()
                return Object.Unwrap(listener:IsSecondaryNavigationBlocked(input_number))
            end)
            if ok and (blocked == true or blocked == false) then
                snapshot.secondaryBlocked = blocked
            elseif not ok then
                snapshot.error = snapshot.error .. " SecondaryBlocked=" .. tostring(blocked)
            end
        end

        if action_name:find("_Tertiary", 1, true) and listener["IsTertiaryNavigationBlocked"] ~= nil then
            local ok, blocked = pcall(function()
                return Object.Unwrap(listener:IsTertiaryNavigationBlocked(input_number))
            end)
            if ok and (blocked == true or blocked == false) then
                snapshot.tertiaryBlocked = blocked
            elseif not ok then
                snapshot.error = snapshot.error .. " TertiaryBlocked=" .. tostring(blocked)
            end
        end

        local allowed = snapshot.accepted == true
            and snapshot.enabled ~= false
            and snapshot.secondaryBlocked ~= true
            and snapshot.tertiaryBlocked ~= true

        return allowed, snapshot
    end

    return Bound
end

return Listener
