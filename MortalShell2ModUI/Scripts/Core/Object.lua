-- Shared UE4SS-safe object helpers.
-- This is the first runtime-aware MortalShell2ModUI utility layer, but it owns no
-- hooks, polling, world lifecycle, widget construction, or input mutation.

local Object = {}

function Object.Unwrap(value)
    if value == nil then return nil end
    local ok, result = pcall(function() return value:get() end)
    if ok then return result end
    return value
end

function Object.Valid(value)
    value = Object.Unwrap(value)
    if value == nil then return false end
    local ok, result = pcall(function() return value:IsValid() end)
    return ok and result == true
end

function Object.Name(object)
    object = Object.Unwrap(object)
    if not Object.Valid(object) then return "<invalid>" end
    local ok, result = pcall(function() return object:GetFullName() end)
    if ok then return tostring(result) end
    return tostring(object)
end

function Object.TextString(value)
    value = Object.Unwrap(value)
    if value == nil then return nil end
    local ok, result = pcall(function() return value:ToString() end)
    if ok then return tostring(result) end
    return nil
end

function Object.WidgetText(widget)
    widget = Object.Unwrap(widget)
    if not Object.Valid(widget) then return nil end
    local ok, value = pcall(function() return Object.Unwrap(widget:GetText()) end)
    if ok and value ~= nil then return Object.TextString(value) end
    return nil
end

function Object.Address(object)
    object = Object.Unwrap(object)
    if not Object.Valid(object) then return nil end
    local ok, value = pcall(function() return object:GetAddress() end)
    if ok then return tonumber(value) end
    return nil
end

function Object.Same(left, right)
    left = Object.Unwrap(left)
    right = Object.Unwrap(right)
    if not Object.Valid(left) or not Object.Valid(right) then return false end
    if left == right then return true end

    local left_address = Object.Address(left)
    local right_address = Object.Address(right)
    return left_address ~= nil and right_address ~= nil and left_address == right_address
end

return Object
