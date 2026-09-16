-- Primitive-only minimap boundary math. Square mode preserves the accepted
-- axis-aligned behavior at 50% visibility. Circle mode uses a true radial
-- boundary. v0.9.9 generalizes the old fixed midpoint rule into a 0..100%
-- visible-depth policy using each marker's actual rendered width/height.

local Policy = {}

local EPSILON = 0.0000001

local function numbers(size, offset_x, offset_y)
    size = tonumber(size)
    offset_x, offset_y = tonumber(offset_x), tonumber(offset_y)
    if size == nil or size <= 0 or offset_x == nil or offset_y == nil then
        return nil
    end
    return size, offset_x, offset_y
end

local function circle(shape)
    if type(shape) == "boolean" then return shape end
    return tostring(shape or "square"):lower() == "circle"
end

local function marker_dimensions(width, height)
    width = tonumber(width)
    height = tonumber(height)
    if width == nil or width <= 0 then return nil end
    if height == nil or height <= 0 then height = width end
    return width, height
end

local function visibility_fraction(value)
    value = tonumber(value)
    if value == nil or value ~= value then value = 0.50 end
    if value > 1.0 then value = value / 100.0 end
    return math.max(0.0, math.min(1.0, value))
end

local function euclidean(x, y)
    return math.sqrt(x * x + y * y)
end

local function circle_corner_root(ux, uy, cx, cy, half)
    local dot = ux * cx + uy * cy
    local discriminant = dot * dot + half * half - (cx * cx + cy * cy)
    if discriminant < 0.0 then return 0.0 end
    return -dot + math.sqrt(discriminant)
end

-- Distance from center to the ordinary marker-center boundary along the
-- supplied bearing. This is the exact center-on-boundary point that v0.9.8
-- used for 50% visibility.
local function midpoint_distance(size, ux, uy, shape)
    local half = size / 2.0
    if circle(shape) then return half end
    local tx = math.abs(ux) > EPSILON and half / math.abs(ux) or math.huge
    local ty = math.abs(uy) > EPSILON and half / math.abs(uy) or math.huge
    local result = math.min(tx, ty)
    return result == math.huge and 0.0 or result
end

-- Exact maximum center distance that keeps the whole upright marker inside
-- the current shape along this bearing. For Circle this checks all four
-- rectangle corners against the circle rather than approximating the marker
-- as the old square maximum extent.
local function full_fit_distance(size, ux, uy, width, height, shape)
    local half = size / 2.0
    local hx, hy = width / 2.0, height / 2.0
    if not circle(shape) then
        local limit_x = math.max(0.0, half - hx)
        local limit_y = math.max(0.0, half - hy)
        local tx = math.abs(ux) > EPSILON and limit_x / math.abs(ux) or math.huge
        local ty = math.abs(uy) > EPSILON and limit_y / math.abs(uy) or math.huge
        local result = math.min(tx, ty)
        return result == math.huge and 0.0 or math.max(0.0, result)
    end

    -- This is a hot path in Circle mode. Solve the four upright corners
    -- explicitly so no temporary sign tables/iterators reach the Lua GC.
    local result = circle_corner_root(ux, uy, -hx, -hy, half)
    result = math.min(result, circle_corner_root(ux, uy, -hx, hy, half))
    result = math.min(result, circle_corner_root(ux, uy, hx, -hy, half))
    result = math.min(result, circle_corner_root(ux, uy, hx, hy, half))
    return result == math.huge and 0.0 or math.max(0.0, result)
end

-- Desired center distance for the user's visible-depth percentage. 50% is
-- exactly the old center-on-boundary position. 100% is the exact full-fit
-- position. Values below 50% mirror that inset outward, allowing the user to
-- intentionally clip more than half of an off-map icon.
local function anchor_distance(size, offset_x, offset_y, width, height, visible, shape)
    local radius = euclidean(offset_x, offset_y)
    if radius <= EPSILON then return 0.0, 1.0 end
    local ux, uy = offset_x / radius, offset_y / radius
    local midpoint = midpoint_distance(size, ux, uy, shape)
    local full_fit = full_fit_distance(size, ux, uy, width, height, shape)
    local inset = math.max(0.0, midpoint - full_fit)
    local fraction = visibility_fraction(visible)
    local desired = midpoint - (2.0 * fraction - 1.0) * inset
    desired = math.max(0.0, desired)
    return desired, desired / radius
end

function Policy.Standard(size, offset_x, offset_y, shape)
    size, offset_x, offset_y = numbers(size, offset_x, offset_y)
    if size == nil then return nil, nil end
    local frame_limit = size / 2.0
    local inside
    if circle(shape) then
        inside = euclidean(offset_x, offset_y) <= frame_limit
    else
        inside = math.max(math.abs(offset_x), math.abs(offset_y)) <= frame_limit
    end
    return inside, frame_limit
end

function Policy.Anchor(size, offset_x, offset_y, rendered_width, rendered_height,
    visible_fraction_value, shape)
    size, offset_x, offset_y = numbers(size, offset_x, offset_y)
    rendered_width, rendered_height = marker_dimensions(rendered_width, rendered_height)
    if size == nil or rendered_width == nil then return nil, nil, nil end
    local limit, factor = anchor_distance(size, offset_x, offset_y,
        rendered_width, rendered_height, visible_fraction_value, shape)
    local distance = euclidean(offset_x, offset_y)
    return distance <= limit + EPSILON, limit, factor
end

function Policy.DistanceAtLimit(distance_meters, offset_x, offset_y, limit, shape, factor)
    distance_meters = tonumber(distance_meters)
    factor = tonumber(factor)
    if distance_meters == nil then return nil end
    if factor ~= nil and factor == factor then
        return distance_meters * math.max(0.0, factor)
    end

    -- Compatibility fallback for older callers/tests that provide only a
    -- scalar limit. New runtime paths pass the exact ray factor above.
    offset_x, offset_y, limit = tonumber(offset_x), tonumber(offset_y), tonumber(limit)
    if offset_x == nil or offset_y == nil or limit == nil then return nil end
    local extent = circle(shape) and euclidean(offset_x, offset_y)
        or math.max(math.abs(offset_x), math.abs(offset_y))
    if extent <= 0.0 then return distance_meters end
    return distance_meters * math.max(0.0, limit) / extent
end

function Policy.ClampToAnchor(size, offset_x, offset_y, rendered_width, rendered_height,
    visible_fraction_value, shape)
    local _, limit, factor = Policy.Anchor(size, offset_x, offset_y,
        rendered_width, rendered_height, visible_fraction_value, shape)
    if limit == nil or factor == nil then return nil, nil, nil end
    local distance = euclidean(offset_x, offset_y)
    if distance <= EPSILON then return offset_x, offset_y, limit end
    return offset_x * factor, offset_y * factor, limit
end

Policy.VisibilityFraction = visibility_fraction

return Policy
