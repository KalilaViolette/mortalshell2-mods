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

    -- THE BUDGET IS A PREDICTION, NOT A RECEIPT. v0.23.57.
    --
    -- The loop used to check the clock AFTER each item, so a slice always ran to
    -- `max_cpu_ms` and then paid for one more item on top. With cheap items that is
    -- invisible. With expensive ones it is the whole cost: her 2026-09-17 session measured
    -- schedule.discovery.arm-continue at avg 18.25 ms against a 10 ms budget, max 47 --
    -- and at 77 fps a frame is 13 ms, so every one of those slices dropped a frame. Her
    -- words: "its like i feel a hitch every 2-3 seconds."
    --
    -- So the slice now stops BEFORE an item it does not expect to fit, using what the last
    -- items actually cost. The estimate decays, so a one-off expensive item cannot shut
    -- the slice down forever, and it is per call site because a registry step and an asset
    -- load have nothing to say about each other.
    --
    -- ALWAYS AT LEAST ONE ITEM. The prediction is only consulted from the second item
    -- onward, so a slice whose first item exceeds the whole budget still makes progress
    -- and the work still terminates. That is the v0.18.14 lesson: a termination PROOF,
    -- not a hope.
    local slice_costs = {}
    local SLICE_COST_DECAY = 0.90

    function runtime.RunSlice(max_items, max_cpu_ms, step, key)
        local started = os.clock()
        local processed = 0
        local exhausted = false
        max_items = math.max(1, math.floor(tonumber(max_items) or 1))
        max_cpu_ms = math.max(0.01, tonumber(max_cpu_ms) or 0.20)
        key = tostring(key or "unkeyed")
        local expected = slice_costs[key] or 0.0
        while processed < max_items do
            if processed >= 1
                and ((os.clock() - started) * 1000.0 + expected) >= max_cpu_ms then
                break
            end
            local item_started = os.clock()
            local had_item = step()
            if not had_item then
                exhausted = true
                break
            end
            processed = processed + 1
            local cost = (os.clock() - item_started) * 1000.0
            -- Decay towards the recent cost rather than remembering the worst forever.
            expected = cost > expected and cost or (expected * SLICE_COST_DECAY)
        end
        slice_costs[key] = expected
        return processed, (os.clock() - started) * 1000.0, exhausted
    end

    return runtime
end

return Factory
