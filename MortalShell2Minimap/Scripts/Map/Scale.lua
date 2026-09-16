-- Shared, primitive-only calibration for the native tiled world map.
-- MapSize=4096 is the logical Blueprint projection atlas. The Slate renderer
-- displays a five-level, 1024px tile pyramid whose finest surface is 16384px.
-- Native SetZoom is applied to that full tile surface, so direct-slot markers
-- must use the same surface span rather than the logical projection atlas.

local Scale = {}

Scale.MAP_LOGICAL_PIXELS = 4096.0
Scale.MAP_INSET_PIXELS = 4.0
Scale.TILE_SIZE_PIXELS = 1024.0
Scale.TILE_LEVEL_COUNT = 5
Scale.TILE_FINEST_GRID = 2 ^ (Scale.TILE_LEVEL_COUNT - 1)
Scale.NATIVE_TILE_SURFACE_PIXELS = Scale.TILE_SIZE_PIXELS * Scale.TILE_FINEST_GRID
Scale.WORLD_SPAN_UNITS = 315552.0
-- Runtime/FModel-proven BP_WorldMapSettings_2D origin used by both the retained
-- native renderer and the v0.9.3 closed-map area-availability fallback. Keeping
-- this in one primitive-only module prevents classifier/projection drift.
Scale.WORLD_ORIGIN_X = 38050.053612
Scale.WORLD_ORIGIN_Y = -134391.872342
Scale.WORLD_SPAN_METERS = Scale.WORLD_SPAN_UNITS / 100.0
Scale.BASE_NATIVE_ZOOM = 0.25

function Scale.WorldPanNormalized(world_x, world_y)
    world_x, world_y = tonumber(world_x), tonumber(world_y)
    if world_x == nil or world_y == nil then return nil, nil end
    return 0.5 - (world_x - Scale.WORLD_ORIGIN_X) / Scale.WORLD_SPAN_UNITS,
        0.5 - (world_y - Scale.WORLD_ORIGIN_Y) / Scale.WORLD_SPAN_UNITS
end

function Scale.WorldInsideNativeBounds(world_x, world_y)
    local pan_x, pan_y = Scale.WorldPanNormalized(world_x, world_y)
    if pan_x == nil or pan_y == nil then return nil, pan_x, pan_y end
    local epsilon = 0.000001
    return pan_x >= -epsilon and pan_x <= 1.0 + epsilon
        and pan_y >= -epsilon and pan_y <= 1.0 + epsilon, pan_x, pan_y
end


function Scale.NormalizeDegrees(value)
    value = tonumber(value)
    if value == nil then return nil end
    return ((value + 180.0) % 360.0) - 180.0
end

-- The retained native map's north-up projection places world +Y at screen up.
-- UMG render-transform angles are clockwise-positive in screen coordinates, so
-- rotating the surface by 90-cameraYaw keeps the final gameplay camera heading
-- at screen up. The same angle is reused by POI/pin projection.
function Scale.CameraHeadingMapAngle(camera_yaw)
    camera_yaw = tonumber(camera_yaw)
    if camera_yaw == nil then return nil end
    return Scale.NormalizeDegrees(90.0 - camera_yaw)
end

function Scale.PlayerHeadingMapAngle(player_yaw)
    player_yaw = tonumber(player_yaw)
    if player_yaw == nil then return nil end
    return Scale.NormalizeDegrees(90.0 - player_yaw)
end

function Scale.RotationBasis(angle_degrees)
    angle_degrees = tonumber(angle_degrees) or 0.0
    if math.abs(angle_degrees) < 0.000001 then return 1.0, 0.0, true end
    local radians = math.rad(angle_degrees)
    return math.cos(radians), math.sin(radians), false
end

function Scale.RotateScreenOffsetBasis(offset_x, offset_y, cosine, sine, identity)
    offset_x, offset_y = tonumber(offset_x), tonumber(offset_y)
    if offset_x == nil or offset_y == nil then return nil, nil end
    if identity == true then return offset_x, offset_y end
    cosine, sine = tonumber(cosine), tonumber(sine)
    if cosine == nil or sine == nil then return nil, nil end
    return offset_x * cosine - offset_y * sine,
        offset_x * sine + offset_y * cosine
end

function Scale.RotateScreenOffset(offset_x, offset_y, angle_degrees)
    offset_x, offset_y = tonumber(offset_x), tonumber(offset_y)
    angle_degrees = tonumber(angle_degrees) or 0.0
    if offset_x == nil or offset_y == nil then return nil, nil end
    local cosine, sine, identity = Scale.RotationBasis(angle_degrees)
    return Scale.RotateScreenOffsetBasis(
        offset_x, offset_y, cosine, sine, identity)
end

function Scale.NativeZoom(zoom_meters)
    zoom_meters = tonumber(zoom_meters)
    if zoom_meters == nil or zoom_meters <= 0 then return nil end
    return Scale.BASE_NATIVE_ZOOM * Scale.WORLD_SPAN_METERS / zoom_meters
end

function Scale.NativePixelsPerWorldUnit(zoom_meters)
    local native_zoom = Scale.NativeZoom(zoom_meters)
    if native_zoom == nil then return nil end
    return Scale.NATIVE_TILE_SURFACE_PIXELS / Scale.WORLD_SPAN_UNITS * native_zoom
end

-- Retained only for manual diagnostics and migration analysis. v0.3.2 and
-- earlier projected trackers with this configured-range formula.
function Scale.LegacyPixelsPerWorldUnit(size, zoom_meters)
    size, zoom_meters = tonumber(size), tonumber(zoom_meters)
    if size == nil or zoom_meters == nil or size <= Scale.MAP_INSET_PIXELS
        or zoom_meters <= 0 then return nil end
    return (size - Scale.MAP_INSET_PIXELS) / (zoom_meters * 100.0)
end

function Scale.CorrectionFactor(size, zoom_meters)
    local native_scale = Scale.NativePixelsPerWorldUnit(zoom_meters)
    local legacy_scale = Scale.LegacyPixelsPerWorldUnit(size, zoom_meters)
    if native_scale == nil or legacy_scale == nil or legacy_scale == 0 then return nil end
    return native_scale / legacy_scale
end

function Scale.EffectiveVisibleMeters(size, zoom_meters)
    size = tonumber(size)
    local native_scale = Scale.NativePixelsPerWorldUnit(zoom_meters)
    if size == nil or size <= Scale.MAP_INSET_PIXELS
        or native_scale == nil or native_scale <= 0 then return nil end
    return (size - Scale.MAP_INSET_PIXELS) / native_scale / 100.0
end

return Scale
