-- "Is the ground under her already revealed?", answered in arithmetic.
--
-- WHY THIS IS NOT A RENDER TARGET READBACK
--
-- The obvious implementation is to read a pixel back off the fog mask. It is wrong
-- twice over. It costs an engine round trip on the game thread for a question the tick
-- wants every frame, and -- the part that actually kills it -- THE ANSWER IS ALWAYS
-- YES. The peek circle and the trail are stamped into that same mask, so a read at the
-- player's own position finds the hole we drew there a moment ago. A probe that reports
-- "revealed" wherever the player stands cannot drive a rule about where the player is
-- standing.
--
-- Her proposal instead, 2026-09-17: bake the fragment shapes into coordinates offline
-- and make the test point-in-set. The grids are discovery shapes ONLY, so they cannot
-- be contaminated by anything the mod itself draws, and the lookup is two multiplies
-- and a short scan.
--
-- THE MAPPING, and why a bake is possible at all: every fragment is drawn over the
-- whole mask at UV (0,0)-(1,1) (FogLayer's rd-tiles loop). No placement, no rotation,
-- no per-fragment offset. So a fragment texel IS a cell of the normalised map space
-- Map/Scale.lua calls WorldPanNormalized, and world -> texel is a scale and a floor.
--
-- FAILS CLOSED, AND SAYS SO. With no data file, a data file of the wrong version, or a
-- grid that fails its structure check, every query returns nil rather than false. nil
-- means "no opinion" and the caller keeps whatever behaviour it had; false would mean
-- "fogged", which would switch the peek ON everywhere and look like a feature breaking.
-- The distinction is the whole safety story of this module, so callers must test for
-- `== true` rather than truthiness.

local RevealedGround = {}

-- The tutorial run up to the hub. Not an item, no entry under /Game/Sparta/Items/Map/,
-- visible on a new save from the first frame. Unioned whatever she is carrying, exactly
-- as FogLayer unions its texture.
local DEFAULT_FRAGMENT = "Default"

local DATA_VERSION = 1

-- Eight points on the ring plus the centre. Her rule 1 is about standing in a revealed
-- AREA, not on a revealed point: one texel is 12.3 m at 256, so a point test alone would
-- call the last texel before a fog edge "clear" and drop the peek while half the circle
-- is still in the dark.
local DEFAULT_RING_SAMPLES = 8
local TAU = math.pi * 2.0

local floor = math.floor
local cos, sin = math.cos, math.sin

function RevealedGround.New(ctx)
    ctx = type(ctx) == "table" and ctx or {}
    local MapScale = ctx.MapScale
    local debug_log = ctx.DebugLog or function() end

    local runtime = {}
    local state = {
        data = nil,
        fragments = nil,
        rejected = nil,
        units_per_meter = 100.0,
        span_meters = 3155.52,
        queries = 0,
    }

    if type(MapScale) == "table" then
        local span_units = tonumber(MapScale.WORLD_SPAN_UNITS)
        local span_meters = tonumber(MapScale.WORLD_SPAN_METERS)
        if span_units ~= nil and span_meters ~= nil and span_meters > 0.0 then
            state.units_per_meter = span_units / span_meters
            state.span_meters = span_meters
        end
    end

    ------------------------------------------------------------------
    -- Loading, and the structure check the lookup depends on
    ------------------------------------------------------------------

    -- The scan in `hit` stops at the first span that starts past the query column, which
    -- is only correct while the spans on a row ascend and never touch. A generated file
    -- always satisfies that; a hand-edited one need not, and the failure would be a
    -- silent wrong answer rather than an error. So it is checked once, here, and a grid
    -- that fails takes the whole table down with it.
    local function check_rows(name, grid)
        local width = tonumber(grid.w)
        local height = tonumber(grid.h)
        if width == nil or height == nil or width < 1 or height < 1 then
            return name .. " has no usable size"
        end
        if type(grid.rows) ~= "table" then return name .. " has no rows table" end
        for row, spans in pairs(grid.rows) do
            local index = tonumber(row)
            if index == nil or index < 1 or index > height or index ~= floor(index) then
                return name .. " row " .. tostring(row) .. " is outside 1.." .. tostring(height)
            end
            if type(spans) ~= "table" or #spans == 0 or #spans % 2 ~= 0 then
                return name .. " row " .. tostring(row) .. " is not a list of span pairs"
            end
            local previous_end = 0
            for i = 1, #spans, 2 do
                local from, to = tonumber(spans[i]), tonumber(spans[i + 1])
                if from == nil or to == nil or from > to or from < 1 or to > width then
                    return name .. " row " .. tostring(row) .. " span " .. tostring(i)
                        .. " is not inside 1.." .. tostring(width)
                end
                if from <= previous_end then
                    return name .. " row " .. tostring(row)
                        .. " spans are not ascending and separated, which the lookup's"
                        .. " early exit depends on"
                end
                previous_end = to
            end
        end
        return nil
    end

    -- `data` is the table Scripts/Data/MapReveal.lua returns, or nil when it was never
    -- baked. Returns true only when the table is present, current and whole.
    function runtime.Load(data)
        state.data, state.fragments, state.rejected = nil, nil, nil
        if data == nil then
            state.rejected = "no baked grids are installed"
            return false
        end
        if type(data) ~= "table" or tonumber(data.version) ~= DATA_VERSION
            or type(data.fragments) ~= "table" then
            state.rejected = "the baked grids are not a version " .. DATA_VERSION .. " table"
            debug_log("RevealedGround rejected the baked grids: " .. tostring(state.rejected))
            return false
        end
        if type(data.fragments[DEFAULT_FRAGMENT]) ~= "table" then
            state.rejected = "the baked grids have no " .. DEFAULT_FRAGMENT .. " grid"
            debug_log("RevealedGround rejected the baked grids: " .. tostring(state.rejected))
            return false
        end
        local count = 0
        for name, grid in pairs(data.fragments) do
            if type(grid) ~= "table" then
                state.rejected = tostring(name) .. " is not a grid"
                debug_log("RevealedGround rejected the baked grids: " .. tostring(state.rejected))
                return false
            end
            local fault = check_rows(tostring(name), grid)
            if fault ~= nil then
                state.rejected = fault
                debug_log("RevealedGround rejected the baked grids: " .. fault)
                return false
            end
            count = count + 1
        end
        state.data = data
        state.fragments = data.fragments
        debug_log("RevealedGround loaded " .. count .. " baked grids threshold="
            .. tostring(data.threshold) .. " generated=" .. tostring(data.generated))
        return true
    end

    function runtime.Available()
        return state.fragments ~= nil
    end

    ------------------------------------------------------------------
    -- The lookup
    ------------------------------------------------------------------

    local function hit(grid, u, v)
        if grid == nil then return false end
        local row = floor(v * grid.h) + 1
        if row < 1 then row = 1 elseif row > grid.h then row = grid.h end
        local spans = grid.rows[row]
        if spans == nil then return false end
        local column = floor(u * grid.w) + 1
        if column < 1 then column = 1 elseif column > grid.w then column = grid.w end
        for i = 1, #spans, 2 do
            local from = spans[i]
            -- Ascending and separated (checked at load), so the first span that starts
            -- past the column ends the scan rather than continuing it.
            if column < from then return false end
            if column <= spans[i + 1] then return true end
        end
        return false
    end

    -- The core, in the normalised map space the fog layer already works in. FogLayer
    -- calls THIS rather than RevealedAt: it holds map coordinates, and projecting them
    -- back out to world units only to project them straight back in would be two
    -- multiplies and a subtraction per query for no answer that differs.
    --
    -- nil when there are no grids to answer from. `held` is the short-name list
    -- FogLayer's held_regions() returns; Default is unioned whether or not it is in it.
    function runtime.RevealedAtNormalized(u, v, held)
        local fragments = state.fragments
        if fragments == nil then return nil end
        if u == nil or v == nil then return nil end
        -- NaN compares false against everything, so it would slide past the bounds
        -- check below, index the rows table with NaN, read nil and come back as
        -- "fogged". A position we cannot place is no opinion, not an answer.
        if u ~= u or v ~= v then return nil end
        state.queries = state.queries + 1
        -- Outside the world's own square nothing was ever painted, so it is fogged
        -- rather than unknown. Clamping instead would smear the border row and column
        -- outwards for as far as the player can walk.
        if u < 0.0 or u > 1.0 or v < 0.0 or v > 1.0 then return false end
        if hit(fragments[DEFAULT_FRAGMENT], u, v) then return true end
        if type(held) == "table" then
            for i = 1, #held do
                if hit(fragments[held[i]], u, v) then return true end
            end
        end
        return false
    end

    -- The same question in world units, for callers that hold a world position.
    function runtime.RevealedAt(world_x, world_y, held)
        if state.fragments == nil then return nil end
        if type(MapScale) ~= "table" or type(MapScale.WorldPanNormalized) ~= "function" then
            return nil
        end
        local u, v = MapScale.WorldPanNormalized(world_x, world_y)
        return runtime.RevealedAtNormalized(u, v, held)
    end

    -- True only when the centre AND every ring sample are revealed. Fails on the first
    -- miss, so the common case in open fog costs one lookup rather than nine.
    function runtime.RevealedAroundNormalized(u, v, radius_meters, held, samples)
        if state.fragments == nil then return nil end
        local centre = runtime.RevealedAtNormalized(u, v, held)
        if centre ~= true then return centre end
        local radius = tonumber(radius_meters)
        if radius == nil or radius <= 0.0 then return true end
        local count = tonumber(samples) or DEFAULT_RING_SAMPLES
        if count < 1 then return true end
        count = floor(count)
        -- The normalised span is 1.0 across WORLD_SPAN_METERS, so a radius in metres is
        -- that fraction of it. Derived from Map/Scale.lua rather than assumed.
        local step = radius / state.span_meters
        for i = 0, count - 1 do
            local angle = (i / count) * TAU
            if runtime.RevealedAtNormalized(u + step * cos(angle),
                                            v + step * sin(angle), held) ~= true then
                return false
            end
        end
        return true
    end

    function runtime.RevealedAround(world_x, world_y, radius_meters, held, samples)
        if state.fragments == nil then return nil end
        if type(MapScale) ~= "table" or type(MapScale.WorldPanNormalized) ~= "function" then
            return nil
        end
        local u, v = MapScale.WorldPanNormalized(world_x, world_y)
        return runtime.RevealedAroundNormalized(u, v, radius_meters, held, samples)
    end

    function runtime.Summary()
        if state.fragments == nil then
            return "revealed-ground unavailable (" .. tostring(state.rejected or "not loaded") .. ")"
        end
        local count = 0
        for _ in pairs(state.fragments) do count = count + 1 end
        return string.format("revealed-ground grids=%d threshold=%s generated=%s queries=%d",
            count, tostring(state.data.threshold), tostring(state.data.generated), state.queries)
    end

    return runtime
end

return RevealedGround
