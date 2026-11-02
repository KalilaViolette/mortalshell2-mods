-- LOAD TIMELINE. v0.23.3.
--
-- Her report, 2026-09-17: "Especially loading in, it's a bit rough, if we could smooth
-- that out and hyper focus on smooth loading in, optimize poi icons loading faster as
-- they are quite delayed loading in".
--
-- Two complaints that pull in opposite directions -- a rough load wants LESS work per
-- frame, icons appearing sooner wants MORE -- and reconciling them by reading the code is
-- how a week gets spent on a wrong theory. So this measures instead. One line per load,
-- naming every stage between the map loading and an icon being on screen, with the real
-- elapsed milliseconds from her machine.
--
-- WHAT IT IS NOT: a profiler. Core/Perf.lua already answers "what costs milliseconds per
-- tick". This answers the different question "where did the seconds between the loading
-- screen and a usable minimap actually go", which no per-tick section total can show,
-- because most of that time is nothing running at all -- it is scheduled delays waiting.
--
-- COST (invariant 0l: a diagnostic is held to the same performance rules as the thing it
-- diagnoses). Stamp() on a milestone already recorded is one table index and a return.
-- After the line is reported the whole thing is inert behind a single boolean. Nothing
-- here allocates per tick and nothing here reads a game object.

local Factory = {}

-- The stages, in the order they happen, with the label each one prints under. A stage
-- that never fires simply does not appear in the line, which is itself the finding: a
-- missing `built` means the renderer never built, and no amount of tuning downstream of
-- it matters.
local STAGES = {
    { key = "load_pre",        label = "loadPre" },
    { key = "load_post",       label = "loadPost" },
    { key = "world_released",  label = "worldReleased" },
    { key = "build_first_try", label = "firstBuildTry" },
    { key = "built",           label = "built" },
    { key = "renderer_ready",  label = "rendererReady" },
    { key = "poi_assets",      label = "poiAssets" },
    { key = "poi_first_icon",  label = "poiFirstIcon" },
    { key = "local_assets",    label = "localAssets" },
    { key = "local_first_icon", label = "localFirstIcon" },
}

-- The last stage of a normal load. Once it lands there is nothing further to wait for and
-- the line is written immediately, while the numbers are still about this load.
local FINAL_STAGE = "local_first_icon"

-- ... unless something never arrives. A load that stalls is the MOST interesting one to
-- see, so the line is written anyway after this long and says which stages are missing.
local DEADLINE_S = 45.0

function Factory.New(ctx)
    local log = assert(ctx.Log, "Core.Timeline requires Log")
    local timeline = {}
    local marks, t0, pending, last_line = {}, nil, false, nil

    local function clock() return os.clock() end

    -- A new load. Everything before it belonged to the previous world and saying so is
    -- more useful than mixing two loads into one line.
    function timeline.Reset(reason)
        marks = {}
        t0 = clock()
        pending = true
        marks.reason = tostring(reason or "load")
    end

    function timeline.Stamp(key)
        if not pending then return end
        if t0 == nil then t0 = clock() end
        if marks[key] ~= nil then return end
        marks[key] = (clock() - t0) * 1000.0
        if key == FINAL_STAGE then timeline.Report("complete") end
    end

    -- Called from the pose tick. One subtraction and a compare when a load is in flight,
    -- one boolean read when it is not.
    function timeline.Poll()
        if not pending or t0 == nil then return end
        if clock() - t0 >= DEADLINE_S then timeline.Report("deadline") end
    end

    -- The line. Built once, kept, and handed to whoever asks afterwards (the Ctrl+Delete
    -- summary, the test runner's results file) rather than recomputed.
    local function compose(reason)
        local parts = { string.format("reason=%s trigger=%s",
            tostring(marks.reason or "load"), tostring(reason or "complete")) }
        local missing, previous = {}, 0.0
        for _, stage in ipairs(STAGES) do
            local at = marks[stage.key]
            if at == nil then
                missing[#missing + 1] = stage.label
            else
                -- Absolute since the load started AND the gap since the stage before it.
                -- The gap is the actionable number: a 5000 ms step between two stages is
                -- a scheduled delay, not work, and those are the ones worth arguing with.
                parts[#parts + 1] = string.format("%s=%.0f(+%.0f)", stage.label, at, at - previous)
                previous = at
            end
        end
        if #missing > 0 then
            parts[#parts + 1] = "missing=" .. table.concat(missing, ",")
        end
        return table.concat(parts, " ")
    end

    function timeline.Report(reason)
        if not pending then return last_line end
        pending = false
        last_line = compose(reason)
        log("[LOAD] timeline " .. last_line)
        return last_line
    end

    -- For the test runner's results file and the summary hotkey: whatever the last load
    -- measured, without re-reporting it.
    function timeline.Line()
        if pending then return compose("in-flight") end
        return last_line
    end

    return timeline
end

return Factory
