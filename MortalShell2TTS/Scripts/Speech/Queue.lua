-- MortalShell2TTS Speech.Queue
-- Pure delayed-narration queue orchestration. The consumer owns clocks, Unreal
-- delayed-action handles, duplicate policy, actual speech dispatch, configuration,
-- helper lifecycle, reader state, UI/input, and diagnostics formatting.

local M = {}

function M.New(options)
    options = type(options) == "table" and options or {}
    local narration_enabled = options.narration_enabled
    local delay_ms = options.delay_ms
    local duplicate_suppressed = options.duplicate_suppressed
    local speak_now = options.speak_now
    local schedule_delay = options.schedule_delay
    local cancel_delay = options.cancel_delay
    local log = options.log or function() end

    if type(narration_enabled) ~= "function" then return nil, "missing-narration-enabled" end
    if type(delay_ms) ~= "function" then return nil, "missing-delay-ms" end
    if type(duplicate_suppressed) ~= "function" then return nil, "missing-duplicate-suppressed" end
    if type(speak_now) ~= "function" then return nil, "missing-speak-now" end
    if type(schedule_delay) ~= "function" then return nil, "missing-schedule-delay" end
    if type(cancel_delay) ~= "function" then return nil, "missing-cancel-delay" end

    local pending = nil
    local runtime = {}

    function runtime.Clear()
        pending = nil
        cancel_delay()
    end

    function runtime.Queue(text, page, reason)
        if not narration_enabled() then return false, "narration-disabled" end
        text = tostring(text or "")
        if text == "" then return false, "empty" end
        if duplicate_suppressed(text, page) then return false, "duplicate" end

        runtime.Clear()
        local delay = tonumber(delay_ms()) or 0
        if delay <= 0 then
            speak_now(text, page)
            return true, "immediate"
        end

        pending = {
            text = text,
            page = page,
            reason = reason or "reader",
        }
        log("speech queued page=" .. tostring(page) .. " delay=" .. tostring(delay) .. "ms")

        if schedule_delay(delay) then return true, "scheduled" end

        -- Fail open if a future runtime cannot schedule the requested delay.
        local current = pending
        pending = nil
        log("speech delay scheduler unavailable; speaking immediately")
        speak_now(current.text, current.page)
        return true, "scheduler-fallback"
    end

    function runtime.Process()
        if pending == nil then return false, "none" end
        if not narration_enabled() then
            runtime.Clear()
            return false, "narration-disabled"
        end

        local current = pending
        pending = nil
        speak_now(current.text, current.page)
        return true, "spoken"
    end

    function runtime.HasPending()
        return pending ~= nil
    end

    function runtime.PendingSnapshot()
        if pending == nil then return nil end
        return {
            text = pending.text,
            page = pending.page,
            reason = pending.reason,
        }
    end

    return runtime, nil
end

return M
