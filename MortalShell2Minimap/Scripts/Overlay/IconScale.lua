-- Pure distance-to-size policy for persistent edge indicators. Output is
-- quantized to whole pixels so layout size changes are naturally bounded.

local Scale = {}

function Scale.Quantized(normal_size, minimum_scale, distance_meters,
    boundary_distance_meters, maximum_distance_meters)
    normal_size = tonumber(normal_size)
    minimum_scale = tonumber(minimum_scale)
    distance_meters = tonumber(distance_meters)
    boundary_distance_meters = tonumber(boundary_distance_meters)
    maximum_distance_meters = tonumber(maximum_distance_meters)
    if normal_size == nil or normal_size <= 0 or minimum_scale == nil
        or distance_meters == nil or boundary_distance_meters == nil
        or maximum_distance_meters == nil then return nil, nil, nil end

    minimum_scale = math.max(0.0, math.min(1.0, minimum_scale))
    local span = maximum_distance_meters - boundary_distance_meters
    local progress = span > 0.0 and math.max(0.0, math.min(1.0,
        (distance_meters - boundary_distance_meters) / span)) or 1.0
    local continuous_scale = 1.0 - (1.0 - minimum_scale) * progress
    local rendered_size = math.max(1,
        math.floor(normal_size * continuous_scale + 0.5))
    return rendered_size, rendered_size / normal_size, progress
end

return Scale
