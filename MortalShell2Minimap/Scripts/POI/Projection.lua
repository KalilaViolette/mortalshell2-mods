-- Runtime-proven zero-rotation BP_WorldMapSettings_2D projection constants.

local Projection = {}

local WORLD_ORIGIN_X = 38050.053612
local WORLD_ORIGIN_Y = -134391.872342
local WORLD_SPAN_UNITS = 315552.0
local MAP_SIZE = 4096.0

function Projection.WorldToMap(world_x, world_y)
    world_x, world_y = tonumber(world_x), tonumber(world_y)
    if world_x == nil or world_y == nil then return nil end
    local map_x = -(world_x - WORLD_ORIGIN_X) * MAP_SIZE / WORLD_SPAN_UNITS
    local map_y = -(world_y - WORLD_ORIGIN_Y) * MAP_SIZE / WORLD_SPAN_UNITS
    return {
        x = map_x,
        y = map_y,
        normalized_x = 0.5 + map_x / MAP_SIZE,
        normalized_y = 0.5 + map_y / MAP_SIZE,
    }
end

return Projection
