-- MortalShell2ModUI Settings.Navigation
-- Pure navigation/value-step helpers. No consumer state, hooks, timers, Unreal
-- objects, or game-specific behavior are owned here.

local Navigation = {}

local function rounded_int(value, fallback)
    local number = tonumber(value)
    if number == nil then number = tonumber(fallback) or 1 end
    return math.floor(number + 0.5)
end

function Navigation.WrapIndex(index, count)
    count = math.max(0, rounded_int(count, 0))
    if count <= 0 then return 1 end
    index = rounded_int(index, 1)
    while index < 1 do index = index + count end
    while index > count do index = index - count end
    return index
end

function Navigation.MoveSelection(selected_index, delta, row_count)
    return Navigation.WrapIndex(
        rounded_int(selected_index, 1) + rounded_int(delta, 0),
        row_count
    )
end

function Navigation.MoveTab(tab_index, delta, tab_count)
    return Navigation.WrapIndex(
        rounded_int(tab_index, 1) + rounded_int(delta, 0),
        tab_count
    )
end

function Navigation.NormalizeSelection(selected_index, row_count)
    row_count = math.max(0, rounded_int(row_count, 0))
    if row_count <= 0 then return 1 end
    selected_index = rounded_int(selected_index, 1)
    if selected_index < 1 or selected_index > row_count then return 1 end
    return selected_index
end

function Navigation.StepValue(value, delta, step, minimum, maximum)
    minimum = tonumber(minimum) or 0
    maximum = tonumber(maximum) or minimum
    if maximum < minimum then minimum, maximum = maximum, minimum end
    value = tonumber(value) or minimum
    delta = tonumber(delta) or 0
    step = tonumber(step) or 1
    local next_value = value + (delta * step)
    if next_value < minimum then return minimum end
    if next_value > maximum then return maximum end
    return next_value
end

return Navigation
