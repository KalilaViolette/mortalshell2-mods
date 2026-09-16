-- Centralizes UE4SS wrapper and reflected read handling. The 30 Hz pose path
-- still uses retained objects; POI reads occur only in budgeted background work.

local Factory = {}

function Factory.New(state)
    local runtime = {}

    function runtime.Unwrap(value)
        if value == nil then return nil end
        if type(state.modui) == "table" and type(state.modui.Object) == "table"
            and type(state.modui.Object.Unwrap) == "function" then
            return state.modui.Object.Unwrap(value)
        end
        local ok, result = pcall(function() return value:get() end)
        return ok and result or value
    end

    function runtime.Valid(value)
        value = runtime.Unwrap(value)
        if value == nil then return false end
        if type(state.modui) == "table" and type(state.modui.Object) == "table"
            and type(state.modui.Object.Valid) == "function" then
            return state.modui.Object.Valid(value)
        end
        local ok, result = pcall(function() return value:IsValid() end)
        return ok and result == true
    end

    function runtime.AsBoolean(value)
        if type(value) == "boolean" then return value end
        local ok, result = pcall(function() return value:get() end)
        if ok and type(result) == "boolean" then return result end
        return nil
    end

    function runtime.Address(value)
        value = runtime.Unwrap(value)
        if not runtime.Valid(value) then return nil end
        local ok, result = pcall(function() return value:GetAddress() end)
        if not ok or result == nil then return nil end
        local number = tonumber(result)
        if number ~= nil then
            local format_ok, formatted = pcall(string.format, "0x%X", number)
            if format_ok then return formatted end
        end
        return tostring(result)
    end

    function runtime.Name(value)
        value = runtime.Unwrap(value)
        if not runtime.Valid(value) then return "<invalid>" end
        local ok, result = pcall(function() return value:GetFullName() end)
        if ok and result ~= nil then return tostring(result) end
        ok, result = pcall(function() return value:GetFName():ToString() end)
        return ok and result ~= nil and tostring(result) or "<unnamed>"
    end

    -- v0.18.11: the object's path as StaticFindObject wants it back. GetFullName prefixes
    -- the type ("BP_Foo_C /Game/..."), so the path is what follows the first space. This
    -- is a STRING: storing it is how a record can be re-acquired later without retaining a
    -- wrapper to an object the game may destroy (invariant 0).
    function runtime.FullPath(value)
        value = runtime.Unwrap(value)
        if not runtime.Valid(value) then return nil end
        local ok, result = pcall(function() return value:GetFullName() end)
        if ok and type(result) == "string" and #result > 0 then
            local path = result:match("^%S+%s+(.+)$") or result
            if #path > 0 and path:find("%.") ~= nil then return path end
        end
        ok, result = pcall(function() return value:GetPathName() end)
        if ok and type(result) == "string" and #result > 0 then return result end
        return nil
    end

    function runtime.ShortName(value)
        value = runtime.Unwrap(value)
        if not runtime.Valid(value) then return nil end
        local ok, result = pcall(function() return value:GetFName():ToString() end)
        return ok and result ~= nil and tostring(result) or nil
    end

    -- Cold objective reconciliation sometimes receives a component whose IconClass
    -- property is absent even though its owning actor class is authoritative. Read
    -- only that already-retained owner's class name; this performs no global scan,
    -- CDO lookup, soft-reference read, or hot-path work.
    function runtime.ClassShortName(value)
        value = runtime.Unwrap(value)
        if not runtime.Valid(value) then return nil end
        local class = nil
        local class_ok = pcall(function() class = runtime.Unwrap(value:GetClass()) end)
        if not class_ok or not runtime.Valid(class) then return nil end
        local ok, result = pcall(function() return class:GetFName():ToString() end)
        return ok and result ~= nil and tostring(result) or nil
    end

    function runtime.Same(left, right)
        local left_address, right_address = runtime.Address(left), runtime.Address(right)
        return left_address ~= nil and right_address ~= nil and left_address == right_address
    end

    function runtime.Property(object, key)
        object = runtime.Unwrap(object)
        if not runtime.Valid(object) then return nil, "object-invalid" end
        local ok, result = pcall(function() return object[key] end)
        if not ok then return nil, tostring(result) end
        return result, nil
    end

    function runtime.Number(object, key)
        local value, err = runtime.Property(object, key)
        if err ~= nil then return nil end
        return tonumber(runtime.Unwrap(value))
    end

    function runtime.Boolean(object, key)
        local value, err = runtime.Property(object, key)
        if err ~= nil then return nil end
        return runtime.AsBoolean(value)
    end

    function runtime.Tag(value)
        if value == nil then return nil end
        local raw = runtime.Unwrap(value)
        local ok, result = pcall(function() return raw.TagName:ToString() end)
        if ok and result ~= nil and tostring(result) ~= "" then return tostring(result) end
        ok, result = pcall(function() return raw:ToString() end)
        if ok and result ~= nil and tostring(result) ~= "" then return tostring(result) end
        return nil
    end

    function runtime.Vector(value)
        value = runtime.Unwrap(value)
        if value == nil then return nil end
        local ok, x, y, z = pcall(function()
            return tonumber(value.X), tonumber(value.Y), tonumber(value.Z)
        end)
        if not ok or x == nil or y == nil then return nil end
        return { x = x, y = y, z = z }
    end

    function runtime.ActorLocation(actor)
        actor = runtime.Unwrap(actor)
        if not runtime.Valid(actor) then return nil end
        local ok, result = pcall(function() return actor:K2_GetActorLocation() end)
        if not ok then ok, result = pcall(function() return actor:GetActorLocation() end) end
        return ok and runtime.Vector(result) or nil
    end

    function runtime.ObjectiveLocation(component)
        component = runtime.Unwrap(component)
        if not runtime.Valid(component) then return nil, "component-invalid", nil end
        local owner = nil
        pcall(function() owner = runtime.Unwrap(component:GetOwner()) end)
        local location = runtime.ActorLocation(owner)
        if location ~= nil then return location, "owner-actor", owner end
        local ok, result = pcall(function() return component:K2_GetComponentLocation() end)
        if not ok then ok, result = pcall(function() return component:GetComponentLocation() end) end
        location = ok and runtime.Vector(result) or nil
        if location ~= nil then return location, "component", owner end
        return nil, runtime.Valid(owner) and "owner-no-location" or "owner-invalid", owner
    end

    function runtime.ArrayCopy(array)
        if array == nil then return nil, "nil" end
        local values, raw_count = {}, 0
        local ok, err = pcall(function()
            array:ForEach(function(_, element)
                raw_count = raw_count + 1
                local value = runtime.Unwrap(element)
                if value ~= nil then values[#values + 1] = value end
            end)
        end)
        if ok then return values, "ForEach", raw_count end
        values, raw_count = {}, 0
        ok, err = pcall(function()
            raw_count = #array
            for index = 1, raw_count do
                local value = runtime.Unwrap(array[index])
                if value ~= nil then values[#values + 1] = value end
            end
        end)
        if ok then return values, "index", raw_count end
        return nil, tostring(err)
    end

    -- Objective discovery must not retain a copied table of UObject wrappers
    -- while a streamed region is changing. These two helpers let the sliced
    -- audit reacquire the live array and consume only the current element.
    function runtime.ArrayCount(array)
        array = runtime.Unwrap(array)
        if array == nil then return nil, "nil" end
        local ok, count = pcall(function() return tonumber(array:GetArrayNum()) end)
        if ok and count ~= nil then return math.max(0, math.floor(count)), "GetArrayNum" end
        ok, count = pcall(function() return #array end)
        if ok and tonumber(count) ~= nil then
            return math.max(0, math.floor(tonumber(count))), "length"
        end
        return nil, tostring(count)
    end

    function runtime.ArrayAt(array, index)
        array = runtime.Unwrap(array)
        index = math.floor(tonumber(index) or 0)
        if array == nil or index < 1 then return nil, "invalid-index" end
        local ok, value = pcall(function() return runtime.Unwrap(array[index]) end)
        if not ok then return nil, tostring(value) end
        return value, value ~= nil and nil or "nil-element"
    end

    function runtime.MapEntries(map_value, fallback_max)
        local entries = {}
        if map_value == nil then return entries, "nil" end
        local ok, err = pcall(function()
            map_value:ForEach(function(key, value)
                entries[#entries + 1] = {
                    key = runtime.Unwrap(key),
                    value = runtime.Unwrap(value),
                }
            end)
        end)
        if ok then return entries, "ForEach" end
        if fallback_max ~= nil then
            local answered = false
            for index = 0, fallback_max - 1 do
                local find_ok, value = pcall(function()
                    return runtime.Unwrap(map_value:Find(index))
                end)
                if find_ok then
                    answered = true
                    if value ~= nil and runtime.Valid(value) then
                        entries[#entries + 1] = { key = index, value = value }
                    end
                end
            end
            if answered then return entries, "Find(index)" end
        end
        return entries, tostring(err)
    end

    function runtime.ObjectiveState(component)
        component = runtime.Unwrap(component)
        local direct = {
            component = runtime.Address(component),
            enabled = runtime.Boolean(component, "Enabled"),
            save_loaded = runtime.Boolean(component, "bSaveLoaded"),
        }
        local runtime_data = nil
        pcall(function() runtime_data = runtime.Unwrap(component.RuntimeData) end)
        direct.runtime = runtime.Address(runtime_data)
        direct.visible = runtime.Boolean(runtime_data, "Visible")
        direct.revealed = runtime.Boolean(runtime_data, "Revealed")
        direct.completed = runtime.Boolean(runtime_data, "Completed")
        direct.show_area = runtime.Boolean(runtime_data, "ShowArea")
        return direct, runtime_data
    end

    return runtime
end

return Factory
