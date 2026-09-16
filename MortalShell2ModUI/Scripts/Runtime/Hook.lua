-- MortalShell2ModUI Runtime.Hook
-- Bounded UE4SS hook registration/retirement transactions.
-- Consumers retain callback semantics, runtime-state ownership, diagnostics, and
-- lifecycle timing; this module owns only the generic RegisterHook/UnregisterHook
-- state transition and hook-ID bookkeeping.

local Hook = {}

local function field_name(fields, key, fallback)
    if type(fields) == "table" and type(fields[key]) == "string" and fields[key] ~= "" then
        return fields[key]
    end
    return fallback
end

function Hook.Register(runtime, path, callback, register_hook, fields)
    local result = {
        ok = false,
        status = "invalid-arguments",
        alreadyRegistered = false,
        pre = nil,
        post = nil,
        cycle = 0,
        error = nil,
    }

    if type(runtime) ~= "table" or type(path) ~= "string" or path == ""
        or type(callback) ~= "function" or type(register_hook) ~= "function" then
        return result
    end

    local registered_field = field_name(fields, "registered", "registered")
    local pre_field = field_name(fields, "pre", "pre")
    local post_field = field_name(fields, "post", "post")
    local cycle_field = field_name(fields, "cycle", "cycle")

    if runtime[registered_field] then
        result.ok = true
        result.status = "already-registered"
        result.alreadyRegistered = true
        result.pre = runtime[pre_field]
        result.post = runtime[post_field]
        result.cycle = tonumber(runtime[cycle_field]) or 0
        return result
    end

    local ok_register, pre, post = pcall(register_hook, path, callback)
    if not ok_register then
        result.status = "register-failed"
        result.error = tostring(pre)
        return result
    end

    runtime[pre_field] = pre
    runtime[post_field] = post
    runtime[registered_field] = true
    runtime[cycle_field] = (tonumber(runtime[cycle_field]) or 0) + 1

    result.ok = true
    result.status = "registered"
    result.pre = pre
    result.post = post
    result.cycle = runtime[cycle_field]
    return result
end

function Hook.Unregister(runtime, path, unregister_hook, fields)
    local result = {
        ok = false,
        status = "invalid-arguments",
        wasRegistered = false,
        pre = nil,
        post = nil,
        cycle = 0,
        error = nil,
    }

    if type(runtime) ~= "table" or type(path) ~= "string" or path == ""
        or type(unregister_hook) ~= "function" then
        return result
    end

    local registered_field = field_name(fields, "registered", "registered")
    local pre_field = field_name(fields, "pre", "pre")
    local post_field = field_name(fields, "post", "post")
    local cycle_field = field_name(fields, "cycle", "cycle")

    result.cycle = tonumber(runtime[cycle_field]) or 0
    if not runtime[registered_field] then
        result.ok = true
        result.status = "not-registered"
        return result
    end

    result.wasRegistered = true
    result.pre = runtime[pre_field]
    result.post = runtime[post_field]

    -- Match the proven consumer behavior: if both hook IDs are unavailable,
    -- keep the registration marker intact so a future caller cannot accidentally
    -- create a duplicate registration whose prior hook cannot be retired.
    if result.pre == nil and result.post == nil then
        result.status = "hook-ids-unavailable"
        return result
    end

    local ok_unregister, unregister_error = pcall(
        unregister_hook,
        path,
        result.pre,
        result.post
    )
    if not ok_unregister then
        result.status = "unregister-failed"
        result.error = tostring(unregister_error)
        return result
    end

    runtime[pre_field] = nil
    runtime[post_field] = nil
    runtime[registered_field] = false

    result.ok = true
    result.status = "unregistered"
    return result
end

return Hook
