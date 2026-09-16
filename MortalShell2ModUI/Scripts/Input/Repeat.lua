-- MortalShell2ModUI Input.Repeat
-- Pure deterministic hold/repeat timing helpers only. Consumers own physical input
-- polling, action dispatch, diagnostics, and any Unreal/controller state.

local Repeat = {}

local function positive_integer(value, fallback)
    value = math.floor(tonumber(value) or tonumber(fallback) or 1)
    if value < 1 then value = 1 end
    return value
end

function Repeat.AdvanceHeld(ticks, held, initial_ticks, repeat_every)
    if held ~= true then return 0, false end

    ticks = (tonumber(ticks) or 0) + 1
    initial_ticks = positive_integer(initial_ticks, 8)
    repeat_every = positive_integer(repeat_every, 2)

    local fire = ticks >= initial_ticks and ((ticks - initial_ticks) % repeat_every) == 0
    return ticks, fire
end

function Repeat.AdvanceDirectional(direction, ticks, next_direction, active, initial_ticks, repeat_every)
    if active ~= true or tonumber(next_direction) == nil or tonumber(next_direction) == 0 then
        return 0, 0, false, false
    end

    next_direction = tonumber(next_direction) > 0 and 1 or -1
    direction = tonumber(direction) or 0
    initial_ticks = positive_integer(initial_ticks, 8)
    repeat_every = positive_integer(repeat_every, 3)

    if direction ~= next_direction then
        return next_direction, 1, true, false
    end

    ticks = (tonumber(ticks) or 0) + 1
    local repeat_fire = ticks >= initial_ticks and ((ticks - initial_ticks) % repeat_every) == 0
    return direction, ticks, false, repeat_fire
end

return Repeat
