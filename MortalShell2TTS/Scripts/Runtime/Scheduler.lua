local M = {}

function M.New(options)
    options = options or {}
    local runtime = options.runtime
    local diag = options.diag
    local log = options.log
    local execute_in_game_thread = options.execute_in_game_thread
    local execute_in_game_thread_with_delay = options.execute_in_game_thread_with_delay
    local execute_with_delay = options.execute_with_delay
    local process_event_method = options.process_event_method
    local process_event_available = options.process_event_available
    if type(runtime) ~= "table" then return nil, "Runtime.Scheduler requires runtime" end
    if type(diag) ~= "function" then return nil, "Runtime.Scheduler requires diag" end
    if type(log) ~= "function" then return nil, "Runtime.Scheduler requires log" end
    if type(execute_in_game_thread) ~= "function" then return nil, "Runtime.Scheduler requires execute_in_game_thread" end
    if process_event_available == false then process_event_method = nil end
    -- Optional profiler (Core/Perf.lua). Every game-thread dispatch and one-shot delay in
    -- the mod passes through here, so this is where they are timed: dispatch.<label> and
    -- oneshot.<label> (the async fallback as oneshot.<label>.async). Labels carry
    -- per-instance suffixes such as "-g12" / "-3"; those are stripped so a section stays
    -- one section. Timing wraps only when the profiler is on at scheduling time.
    local perf = type(options.perf) == "table" and options.perf or nil
    local function section_label(label)
        return (tostring(label or "work"):gsub("%-%a?%d+$", ""))
    end
    local function timed(section, callback)
        if perf == nil or not perf.enabled or type(callback) ~= "function" then return callback end
        return function(...)
            local token = perf.Begin()
            callback(...)
            perf.End(section, token)
        end
    end
    runtime.dispatch_error_logged = runtime.dispatch_error_logged or {}
    runtime.delayed_action_error_logged = runtime.delayed_action_error_logged or {}
    local self = {}

    function self.Dispatch(callback, label)
        label = tostring(label or "work")
        callback = timed("dispatch." .. section_label(label), callback)
        if process_event_method ~= nil then
            local ok, err = pcall(function() execute_in_game_thread(callback, process_event_method) end)
            if ok then return true end
            local key = "process-event:" .. label
            if not runtime.dispatch_error_logged[key] then
                runtime.dispatch_error_logged[key] = true
                log("ProcessEvent game-thread dispatch failed for " .. label .. ": " .. tostring(err) .. "; trying legacy/default dispatch")
            end
        end
        local ok, err = pcall(function() execute_in_game_thread(callback, nil) end)
        if not ok then
            local key = "default:" .. label
            if not runtime.dispatch_error_logged[key] then
                runtime.dispatch_error_logged[key] = true
                log("default game-thread dispatch failed for " .. label .. ": " .. tostring(err))
            end
        end
        return ok
    end

    function self.ScheduleOneShot(delay_ms, game_callback, async_fallback, label)
        delay_ms = math.max(0, math.floor((tonumber(delay_ms) or 0) + 0.5))
        label = tostring(label or "delayed-work")
        local section = "oneshot." .. section_label(label)
        game_callback = timed(section, game_callback)
        async_fallback = timed(section .. ".async", async_fallback)
        diag("delay.schedule", { stage = "begin", label = label, delayMs = delay_ms })
        if type(execute_in_game_thread_with_delay) == "function" then
            local ok, handle, marker = pcall(function()
                local value, status = execute_in_game_thread_with_delay(delay_ms, game_callback)
                return value, status
            end)
            if ok and marker ~= "unavailable" then
                diag("delay.schedule", { stage = "scheduled", label = label, delayMs = delay_ms, backend = "ExecuteInGameThreadWithDelay", executionMethod = "UE4SS-default", handle = handle ~= nil and tostring(handle) or "<nil>" })
                return true, handle
            end
            local failure = ok and marker or handle
            diag("delay.schedule", { stage = "modern-failed", label = label, delayMs = delay_ms, error = failure })
            if not runtime.delayed_action_error_logged[label] then
                runtime.delayed_action_error_logged[label] = true
                log("game-thread delayed action failed for " .. label .. ": " .. tostring(failure) .. "; trying legacy short-delay fallback")
            end
        else
            diag("delay.schedule", { stage = "modern-unavailable", label = label, delayMs = delay_ms })
        end
        if type(execute_with_delay) == "function" and async_fallback ~= nil then
            local ok, result, marker = pcall(function()
                local value, status = execute_with_delay(delay_ms, async_fallback)
                return value, status
            end)
            if ok and marker ~= "unavailable" then
                diag("delay.schedule", { stage = "scheduled", label = label, delayMs = delay_ms, backend = "ExecuteWithDelay+dispatch_game_thread", executionMethod = "async-fallback", handle = "<none>" })
                return true, nil
            end
            local failure = ok and marker or result
            diag("delay.schedule", { stage = "legacy-failed", label = label, delayMs = delay_ms, error = failure })
            if not runtime.delayed_action_error_logged["legacy:" .. label] then
                runtime.delayed_action_error_logged["legacy:" .. label] = true
                log("legacy short-delay fallback failed for " .. label .. ": " .. tostring(failure))
            end
        end
        diag("delay.schedule", { stage = "failed", label = label, delayMs = delay_ms })
        return false, nil
    end

    log("game-thread dispatch preference=" .. (process_event_method ~= nil and "ProcessEvent" or "legacy/default") .. " ProcessEventAvailable=" .. tostring(process_event_available))
    return self
end

return M
