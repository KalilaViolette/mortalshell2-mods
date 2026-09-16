-- Shared scheduler/budget boundary for all non-pose POI work.

local Factory = {}

function Factory.New(ctx)
    local state = assert(ctx.State, "Runtime.WorkBudget requires State")
    local lifecycle = assert(ctx.Lifecycle, "Runtime.WorkBudget requires Runtime.Lifecycle")
    local log = assert(ctx.Log, "Runtime.WorkBudget requires Log")
    local runtime = {}

    -- `label` names the perf section (schedule.<label>) the callback is timed under.
    -- Every caller passes one; an unlabelled callback shows up as schedule.unlabelled
    -- in the summary, which is the cue to go and name it.
    function runtime.Schedule(delay_ms, callback, label)
        return lifecycle.Schedule(delay_ms, function()
            -- The native-menu gate is a true UObject quarantine. Defer every
            -- background POI read too; stopping only the visible pose loop left
            -- audits running during the exact transition we were protecting.
            if state.native_menu_gate_available and state.native_menu_active then
                runtime.Schedule(250, callback, label)
                return
            end
            local ok, err = pcall(callback)
            if not ok then
                local text = tostring(err)
                if state.poi == nil or state.poi.last_work_error ~= text then
                    log("POI background work error: " .. text)
                end
                if state.poi ~= nil then state.poi.last_work_error = text end
            elseif state.poi ~= nil then
                state.poi.last_work_error = nil
            end
        end, label)
    end

    function runtime.RunSlice(max_items, max_cpu_ms, step)
        local started = os.clock()
        local processed = 0
        local exhausted = false
        max_items = math.max(1, math.floor(tonumber(max_items) or 1))
        max_cpu_ms = math.max(0.01, tonumber(max_cpu_ms) or 0.20)
        while processed < max_items do
            local had_item = step()
            if not had_item then
                exhausted = true
                break
            end
            processed = processed + 1
            if processed >= 1 and (os.clock() - started) * 1000.0 >= max_cpu_ms then break end
        end
        return processed, (os.clock() - started) * 1000.0, exhausted
    end

    return runtime
end

return Factory
