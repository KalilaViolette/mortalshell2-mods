-- MortalShell2ModUI Core.Array
-- Read-only UE4SS/TArray helpers. This layer may inspect native arrays and names,
-- but it owns no mutation, hooks, polling, world/controller lifetime or widgets.

local Array = {}

function Array.Bind(Object)
    local Bound = {}

    function Bound.Count(array_value)
        array_value = Object.Unwrap(array_value)
        if array_value == nil then return nil, "array=nil" end
        local ok, count = pcall(function() return tonumber(array_value:GetArrayNum()) end)
        if not ok then return nil, tostring(count) end
        return tonumber(count), nil
    end

    function Bound.ByteValues(array_value)
        array_value = Object.Unwrap(array_value)
        if array_value == nil then return nil, "array=nil" end
        local count, count_error = Bound.Count(array_value)
        if count == nil then return nil, count_error end

        -- UE4SS Lua TArray wrappers are one-based even though Unreal TArray is
        -- zero-based. Preserve the proven 1..count indexing contract exactly.
        local result = {}
        for index = 1, count do
            local ok_value, value = pcall(function() return Object.Unwrap(array_value[index]) end)
            if not ok_value then
                return nil, "index=" .. tostring(index) .. " error=" .. tostring(value)
            end
            value = tonumber(value)
            if value == nil then
                return nil, "index=" .. tostring(index) .. " non-numeric=" .. tostring(value)
            end
            result[#result + 1] = value
        end
        return result, nil
    end

    function Bound.ObjectEntries(array_value)
        array_value = Object.Unwrap(array_value)
        if array_value == nil then return nil, "array=nil" end
        local count, count_error = Bound.Count(array_value)
        if count == nil then return nil, count_error end

        local result = {}
        for index = 1, count do
            local ok, value = pcall(function() return Object.Unwrap(array_value[index]) end)
            if ok then
                result[#result + 1] = {
                    index = index,
                    object = value,
                    name = Object.Valid(value) and Object.Name(value) or "<invalid>",
                }
            else
                result[#result + 1] = {
                    index = index,
                    object = nil,
                    name = "<read-error:" .. tostring(value) .. ">",
                }
            end
        end
        return result, nil
    end

    function Bound.NameString(value)
        value = Object.Unwrap(value)
        if value == nil then return "<nil>" end
        if type(value) == "string" then return value end

        local ok_to_string, text = pcall(function() return value:ToString() end)
        if ok_to_string and text ~= nil then return tostring(text) end

        local ok_name, name = pcall(function() return value:GetName() end)
        if ok_name and name ~= nil then return tostring(name) end

        return tostring(value)
    end

    return Bound
end

return Array
