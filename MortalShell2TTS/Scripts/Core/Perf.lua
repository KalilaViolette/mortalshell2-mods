-- Core.Perf -- performance sampling for the Mortal Shell II mods.
--
-- CANONICAL COPY. This file is byte-identical in
--     MortalShell2ModUI/Scripts/Core/Perf.lua      (this one is the original)
--     MortalShell2Minimap/Scripts/Core/Perf.lua
--     MortalShell2TTS/Scripts/Core/Perf.lua
-- Each UE4SS mod is its own Lua state and cannot share a table with another, so the
-- three mods each load their own copy. Validation/PerfRegression.lua fails if the
-- copies differ. Edit this one, copy it to the other two, run the suite.
--
-- WHAT IT IS FOR
--
-- "Tell me while we are developing if something is hurting performance unexpectedly"
-- (user, 2026-09-13). Every recurring or native-touching code path in the mods opens a
-- section; while logging is on, each section accumulates count, total, max and spike
-- figures in plain Lua tables and a summary goes to the log every ten seconds. The
-- output accompanies external frame-time benchmarks: the benchmark says the frame got
-- slower, this says which of our sections did it.
--
-- WHAT IT COSTS
--
-- Off: Begin() is one field read and returns nil; End() with a nil token returns at
-- once. No allocation, no string, no clock. On: one os.clock() per Begin and per End,
-- and a handful of table writes. Nothing is ever logged per event -- v0.11.6 wrote two
-- lines per callback and produced a 16 MB log with no summary in it, and a profiler
-- that floods the log destroys the evidence it exists to collect.
--
-- WHAT THE NUMBERS MEAN
--
-- os.clock() on her Windows build ticks in whole milliseconds (every timed value in
-- every log so far is an integer: seedCpuMs=29.000). A single call shorter than a
-- millisecond reads as 0 or 1, so:
--   * `ms` (total), `avg`, `rate` (calls/s) and `n` are reliable -- quantisation is
--     unbiased over many calls, and counts are exact.
--   * `max` and `spikes` (calls that read 2 ms or more) are reliable as HITCH
--     detectors: a 2 means the call genuinely spanned at least one full tick.
--   * a `max` of 1 on a section means nothing -- it is the tick boundary, not a cost.
-- Counts are the best early warning. PostSpawnMovement's 690 calls a second would have
-- been unmissable in the rate column long before anything was measured in milliseconds.
--
-- NAMING
--
-- Section names are `area.thing`, lower case, stable across versions:
--   tick.pose   hook.ai.ReceiveBeginPlay   schedule.local-sync   io.config.save
-- Hook sections are `hook.<label>` using the mod's existing hook labels; scheduled work
-- is `schedule.<label>`; anything that calls into the engine is a `native.*` counter as
-- well as whatever timed section encloses it. See PERFORMANCE_LOGGING.md.

local Factory = {}

local SPIKE_MS = 2.0
local DEFAULT_INTERVAL_S = 10.0
local MAX_SECTIONS = 512

-- Seconds -> milliseconds, rounded to the microsecond so float dust cannot turn an
-- exact 2 ms into 1.999 and miss the spike threshold. Never negative.
local function to_ms(seconds)
    local ms = math.floor(seconds * 1000000.0 + 0.5) / 1000.0
    if ms < 0 then ms = 0 end
    return ms
end

function Factory.New(options)
    options = type(options) == "table" and options or {}
    local mod = tostring(options.mod or "Mod")
    local log = type(options.log) == "function" and options.log or function() end
    local clock = type(options.clock) == "function" and options.clock or os.clock
    local schedule = type(options.schedule) == "function" and options.schedule or nil
    local interval_s = tonumber(options.interval_s) or DEFAULT_INTERVAL_S
    if interval_s < 1.0 then interval_s = 1.0 end

    local perf = {
        enabled = false,
        mod = mod,
        interval_s = interval_s,
        sections = {},      -- name -> stats
        order = {},         -- names in first-seen order
        section_count = 0,
        emits = 0,
        started_at = nil,   -- clock() when enabled
        last_emit_at = nil,
        timer_token = 0,    -- invalidates a pending self-scheduled emit
        dropped_sections = 0,
    }

    local function section(name)
        local s = perf.sections[name]
        if s ~= nil then return s end
        if perf.section_count >= MAX_SECTIONS then
            perf.dropped_sections = perf.dropped_sections + 1
            return nil
        end
        s = {
            -- lifetime (since enabled)
            n = 0, ms = 0.0, max = 0.0, spikes = 0,
            -- current interval
            in_n = 0, in_ms = 0.0, in_max = 0.0, in_spikes = 0,
            -- Mark(): spacing between consecutive marks
            mark_last = nil, gap_n = 0, gap_ms = 0.0, gap_max = 0.0,
            in_gap_n = 0, in_gap_ms = 0.0, in_gap_max = 0.0,
        }
        perf.sections[name] = s
        perf.section_count = perf.section_count + 1
        perf.order[perf.section_count] = name
        return s
    end

    -- Timing --------------------------------------------------------------

    -- Returns a token when enabled, nil otherwise. The nil is the whole off-cost.
    function perf.Begin()
        if not perf.enabled then return nil end
        return clock()
    end

    -- Closes a timed section. A nil token (profiler off at Begin) is a no-op, which
    -- makes every call site safe to leave in place permanently.
    function perf.End(name, token)
        if token == nil or not perf.enabled then return end
        local elapsed = to_ms(clock() - token)
        local s = section(name)
        if s == nil then return end
        s.n = s.n + 1
        s.ms = s.ms + elapsed
        if elapsed > s.max then s.max = elapsed end
        s.in_n = s.in_n + 1
        s.in_ms = s.in_ms + elapsed
        if elapsed > s.in_max then s.in_max = elapsed end
        if elapsed >= SPIKE_MS then
            s.spikes = s.spikes + 1
            s.in_spikes = s.in_spikes + 1
        end
    end

    -- A counter with no timing: native calls, widget writes, hook events that are
    -- measured by their enclosing section. Exact, and cheap enough for hot paths.
    function perf.Count(name, amount)
        if not perf.enabled then return end
        local s = section(name)
        if s == nil then return end
        amount = tonumber(amount) or 1
        s.n = s.n + amount
        s.in_n = s.in_n + amount
    end

    -- Records the gap since the previous Mark of the same name. Used for the spacing
    -- of a loop's ticks: a max gap far above the expected cadence is a hitch, whether
    -- ours or the game's.
    function perf.Mark(name)
        if not perf.enabled then return end
        local now = clock()
        local s = section(name)
        if s == nil then return end
        if s.mark_last ~= nil then
            local gap = to_ms(now - s.mark_last)
            s.gap_n = s.gap_n + 1
            s.gap_ms = s.gap_ms + gap
            if gap > s.gap_max then s.gap_max = gap end
            s.in_gap_n = s.in_gap_n + 1
            s.in_gap_ms = s.in_gap_ms + gap
            if gap > s.in_gap_max then s.in_gap_max = gap end
        end
        s.mark_last = now
    end

    -- Convenience for a whole function body. Allocates a closure only when called, so
    -- keep it off the hot paths; those use Begin/End directly.
    function perf.Wrap(name, fn, ...)
        local token = perf.Begin()
        local results = table.pack(pcall(fn, ...))
        perf.End(name, token)
        if not results[1] then error(results[2], 0) end
        return table.unpack(results, 2, results.n)
    end

    -- Output --------------------------------------------------------------

    local function fmt_ms(value) return string.format("%.1f", value) end

    -- One header line, then one line per section active in the interval, heaviest
    -- first. Lifetime figures ride along so a single capture is enough to read.
    function perf.Emit(reason)
        if not perf.enabled then return 0 end
        local now = clock()
        local since = perf.last_emit_at ~= nil and (now - perf.last_emit_at) or
            (perf.started_at ~= nil and (now - perf.started_at) or perf.interval_s)
        if since <= 0 then since = perf.interval_s end
        local lifetime = perf.started_at ~= nil and (now - perf.started_at) or since
        perf.emits = perf.emits + 1

        local active = {}
        local total_in_ms, total_in_n, quiet = 0.0, 0, 0
        for _, name in ipairs(perf.order) do
            local s = perf.sections[name]
            if s.in_n > 0 or s.in_gap_n > 0 then
                active[#active + 1] = name
                total_in_ms = total_in_ms + s.in_ms
                total_in_n = total_in_n + s.in_n
            else
                quiet = quiet + 1
            end
        end
        table.sort(active, function(a, b)
            local sa, sb = perf.sections[a], perf.sections[b]
            if sa.in_ms ~= sb.in_ms then return sa.in_ms > sb.in_ms end
            if sa.in_n ~= sb.in_n then return sa.in_n > sb.in_n end
            return a < b
        end)

        log(string.format(
            "[PERF] %s summary reason=%s emit=%d intervalS=%.1f lifetimeS=%.1f sections=%d active=%d quiet=%d totalMs=%s busyPct=%.2f events=%d clockResolutionMs=1 spikeMs=%.0f dropped=%d",
            mod, tostring(reason or "interval"), perf.emits, since, lifetime,
            perf.section_count, #active, quiet, fmt_ms(total_in_ms),
            (total_in_ms / (since * 1000.0)) * 100.0, total_in_n, SPIKE_MS,
            perf.dropped_sections))
        for _, name in ipairs(active) do
            local s = perf.sections[name]
            local line = string.format(
                "[PERF] %s section=%s n=%d ms=%s avg=%.2f max=%s spikes=%d rate=%.1f lifeN=%d lifeMs=%s lifeMax=%s lifeSpikes=%d",
                mod, name, s.in_n, fmt_ms(s.in_ms),
                s.in_n > 0 and (s.in_ms / s.in_n) or 0.0, fmt_ms(s.in_max), s.in_spikes,
                s.in_n / since, s.n, fmt_ms(s.ms), fmt_ms(s.max), s.spikes)
            if s.in_gap_n > 0 then
                line = line .. string.format(" gapN=%d gapAvg=%.1f gapMax=%s lifeGapMax=%s",
                    s.in_gap_n, s.in_gap_ms / s.in_gap_n, fmt_ms(s.in_gap_max), fmt_ms(s.gap_max))
            end
            log(line)
            s.in_n, s.in_ms, s.in_max, s.in_spikes = 0, 0.0, 0.0, 0
            s.in_gap_n, s.in_gap_ms, s.in_gap_max = 0, 0.0, 0.0
        end
        perf.last_emit_at = now
        return #active
    end

    -- Called from any low-frequency place (a mod's own tick). Emits when the
    -- interval has elapsed. Harmless to call often: one comparison when nothing is due.
    function perf.Tick()
        if not perf.enabled then return false end
        local now = clock()
        local last = perf.last_emit_at or perf.started_at or now
        if now - last < perf.interval_s then return false end
        perf.Emit("interval")
        return true
    end

    -- Self-scheduled emits for a mod with no permanent loop of its own (TTS, ModUI).
    local function arm_timer()
        if schedule == nil or not perf.enabled then return end
        perf.timer_token = perf.timer_token + 1
        local token = perf.timer_token
        schedule(math.floor(perf.interval_s * 1000.0 + 0.5), function()
            if token ~= perf.timer_token or not perf.enabled then return end
            perf.Emit("interval")
            arm_timer()
        end)
    end

    function perf.Reset()
        perf.sections, perf.order, perf.section_count = {}, {}, 0
        perf.dropped_sections = 0
        perf.emits = 0
        perf.started_at = perf.enabled and clock() or nil
        perf.last_emit_at = nil
    end

    -- Enable/disable. Turning it on resets the accumulators so the first summary
    -- describes the current session, not whatever ran before the toggle.
    function perf.SetEnabled(on, reason)
        on = on == true
        if on == perf.enabled then return false end
        perf.enabled = on
        perf.timer_token = perf.timer_token + 1
        if on then
            perf.Reset()
            log(string.format("[PERF] %s logging=on reason=%s intervalS=%.1f clockResolutionMs=1 spikeMs=%.0f",
                mod, tostring(reason or "setting"), perf.interval_s, SPIKE_MS))
            arm_timer()
        else
            log(string.format("[PERF] %s logging=off reason=%s emits=%d", mod,
                tostring(reason or "setting"), perf.emits))
        end
        return true
    end

    function perf.Sections()
        return perf.sections, perf.order
    end

    return perf
end

return Factory
