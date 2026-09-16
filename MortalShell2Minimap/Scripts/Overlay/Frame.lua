-- v0.17.0 map frame (user request 2026-09-14: "frames for our square map and circle
-- map ... something sharp, that feels natural, and would be toggleable on/off").
--
-- A frame is a handful of UImages on the renderer's OUTER canvas (the same root the
-- labels use: it clips nothing and sits outside the circle mask and the opacity
-- retainer), placed around the map box at (OffsetX, OffsetY, Size). They are built
-- once per widget build and again when the two GENERAL rows change; nothing here
-- runs per tick. Style keys are shape-neutral so one row serves both shapes:
--
--   line    circle: T_UI_Rune_Circle (512, thin double ring) at 1.185x the map
--           square: eight T_UI_White bars, 1.5 units on the edge + 0.5 units 5 out
--   vector  a Slate RoundedBox brush with an outline and no texture: crisp at any
--           size. UNPROVEN through UE4SS until she sees it -- the brush is written as
--           one whole FSlateBrush table (a struct read returns a copy, Labels v0.11.x),
--           first through SetBrush, then as a property. If neither write takes the
--           style falls back to "line" and the summary says so.
--   ornate  circle: T_UI_Icon_Map_Crosshair (the world map's cursor ring with its
--           four cardinal points) at 1.47x; square: four T_UI_DetailsDivider_Golden
--   off     nothing built
--
-- Color presets multiply the (white / parchment) artwork, as the icon tints do, so
-- the same five names read the same on every style. Opacity follows the map's.
-- Sizes below are design units; Slate scales them by the DPI curve (x2 at 4K).

local Factory = {}

local STYLES = { "off", "line", "vector", "ornate" }
local COLORS = {
    bronze = { R = 0.72, G = 0.60, B = 0.40, A = 1.0 },
    white  = { R = 0.92, G = 0.90, B = 0.85, A = 1.0 },
    red    = { R = 0.85, G = 0.20, B = 0.15, A = 1.0 },
    blue   = { R = 0.35, G = 0.60, B = 0.95, A = 1.0 },
    green  = { R = 0.40, G = 0.80, B = 0.45, A = 1.0 },
}
local COLOR_ORDER = { "bronze", "white", "red", "blue", "green" }

Factory.Styles = STYLES
Factory.Colors = COLOR_ORDER

-- Shape-aware row text for the GENERAL "Map frame" row.
function Factory.StyleLabel(style, shape)
    style = tostring(style or "line"):lower()
    local circle = tostring(shape or "square"):lower() == "circle"
    if style == "off" then return "Off" end
    if style == "vector" then return circle and "Vector ring" or "Vector outline" end
    if style == "ornate" then return circle and "Compass" or "Gold dividers" end
    return circle and "Ring" or "Bars"
end

function Factory.ColorLabel(color)
    color = tostring(color or "bronze"):lower()
    return (color:sub(1, 1):upper() .. color:sub(2))
end

function Factory.New(ctx)
    local state = assert(ctx.State, "Overlay.Frame requires State")
    local Config = assert(ctx.Config, "Overlay.Frame requires Config")
    local Object = assert(ctx.Object, "Overlay.Frame requires Core.Object")
    local log = assert(ctx.Log, "Overlay.Frame requires Log")
    local Perf = type(ctx.Perf) == "table" and ctx.Perf
        or { Begin = function() return nil end, End = function() end }
    local unwrap, valid = Object.Unwrap, Object.Valid

    local IMAGE_CLASS_PATH = "/Script/UMG.Image"
    local UI_ROOT = "/Game/Sparta/UI/"
    local function texture_path(relative)
        local name = string.match(relative, "([^/]+)$")
        return UI_ROOT .. relative .. "." .. name
    end
    local TEX = {
        ring = texture_path("Common/Textures/T_UI_Rune_Circle"),
        compass = texture_path("World/Map/Textures/T_UI_Icon_Map_Crosshair"),
        white = texture_path("Common/Textures/T_UI_White"),
        divider = texture_path("Common/Textures/T_UI_DetailsDivider_Golden"),
    }
    -- Geometry, in design units and multiples of the map size. The ring textures
    -- carry their ring inset from the texture edge, so the box is scaled to put the
    -- inner edge of the drawn ring on the map edge (measured from the FModel export:
    -- Rune_Circle inner radius 0.844 of the half-width, Crosshair 0.68).
    local RING_SCALE = 1.185
    local COMPASS_SCALE = 1.47
    local BAR_THICK = 1.5
    local BAR_THIN = 0.5
    local BAR_THIN_INSET = 5
    local DIVIDER_THICK = 3
    local VECTOR_WIDTH = 1.5
    local VECTOR_THIN = 0.75
    local VECTOR_THIN_GAP = 4.5
    local VECTOR_CORNER = 14
    local Z_ORDER = 50
    local VIS_COLLAPSED = 1
    local VIS_HIT_TEST_INVISIBLE = 3
    local DRAW_AS_ROUNDED_BOX = 4      -- ESlateBrushDrawType::RoundedBox
    local ROUNDING_FIXED = 0           -- ESlateBrushRoundingType::FixedRadius
    local ROUNDING_HALF_HEIGHT = 1     -- ESlateBrushRoundingType::HalfHeightRadius
    local COLOR_USE_SPECIFIED = 0      -- ESlateColorStylingMode::UseColor_Specified

    state.map_frame = state.map_frame or {
        entries = {}, image_class = nil, built_style = "none", built_shape = "none",
        built_color = "none", vector_status = "untried", fallback_reason = nil,
        metrics = { builds = 0, build_failures = 0, images = 0, texture_loads = 0,
            texture_failures = 0, vector_attempts = 0, vector_property_writes = 0,
            vector_setbrush_writes = 0, vector_failures = 0, teardowns = 0,
            opacity_writes = 0 },
    }
    local frame = state.map_frame
    local metrics = frame.metrics

    local function style()
        local value = tostring(Config.MapFrame or "line"):lower()
        for _, key in ipairs(STYLES) do if key == value then return value end end
        return "line"
    end

    local function color()
        local value = tostring(Config.MapFrameColor or "bronze"):lower()
        return COLORS[value] ~= nil and value or "bronze"
    end

    local function shape()
        return tostring(Config.MapShape or "square"):lower() == "circle" and "circle" or "square"
    end

    local function map_box()
        local size = tonumber(Config.Size) or 260
        return tonumber(Config.OffsetX) or 0, tonumber(Config.OffsetY) or 0, size
    end

    local function opacity()
        return math.max(0.0, math.min(1.0, tonumber(Config.Opacity) or 1.0))
    end

    local function find_object(path)
        local token = Perf.Begin()
        local ok, value = pcall(StaticFindObject, path)
        Perf.End("native.find", token)
        value = unwrap(ok and value or nil)
        return valid(value) and value or nil
    end

    local function load_texture(path)
        local object = find_object(path)
        if object ~= nil then return object end
        if type(LoadAsset) == "function" then
            metrics.texture_loads = metrics.texture_loads + 1
            local token = Perf.Begin()
            pcall(LoadAsset, path)
            Perf.End("native.load", token)
            object = find_object(path)
        end
        if object == nil then metrics.texture_failures = metrics.texture_failures + 1 end
        return object
    end

    local function root_canvas()
        local retained = state.retained
        if type(retained) ~= "table" then return nil end
        return valid(retained.root) and retained.root or nil
    end

    local function make_name(base)
        state.widget_counter = (state.widget_counter or 0) + 1
        return FName("MS2Minimap_Frame_" .. tostring(base) .. "_" .. tostring(state.widget_counter))
    end

    -- One image on the outer canvas: centred box (cx, cy) of w x h units.
    local function add_image(parent, base, cx, cy, w, h)
        if not valid(frame.image_class) then return nil, "image-class-unavailable" end
        local entry = { image = nil, slot = nil }
        local ok, err = pcall(function()
            local image = unwrap(StaticConstructObject(frame.image_class, parent, make_name(base)))
            assert(valid(image), "frame image construction failed")
            entry.image = image
            local slot = unwrap(parent:AddChildToCanvas(image))
            assert(valid(slot), "frame image slot failed")
            entry.slot = slot
            slot:SetPosition({ X = cx - w / 2.0, Y = cy - h / 2.0 })
            slot:SetSize({ X = w, Y = h })
            pcall(slot.SetZOrder, slot, Z_ORDER)
            pcall(image.SetRenderOpacity, image, opacity())
            image:SetVisibility(VIS_HIT_TEST_INVISIBLE)
        end)
        if not ok then
            if valid(entry.image) then pcall(entry.image.RemoveFromParent, entry.image) end
            return nil, tostring(err)
        end
        frame.entries[#frame.entries + 1] = entry
        metrics.images = metrics.images + 1
        return entry
    end

    local function add_textured(parent, base, path, tint, cx, cy, w, h)
        local texture = load_texture(path)
        if texture == nil then return nil, "texture-unavailable:" .. tostring(path) end
        local entry, err = add_image(parent, base, cx, cy, w, h)
        if entry == nil then return nil, err end
        local ok = pcall(entry.image.SetBrushFromTexture, entry.image, texture, false)
        if not ok then return nil, "brush-write-failed" end
        pcall(entry.image.SetColorAndOpacity, entry.image, tint)
        return entry
    end

    -- The whole-brush table for a hollow rounded box with an outline. Every field a
    -- default FSlateBrush would carry is named, so a zero-filled struct still draws
    -- what we mean (a struct assignment from a table may not keep unnamed fields).
    local function rounded_brush(w, h, width, tint, rounding, corner)
        return {
            ImageSize = { X = w, Y = h },
            Margin = { Left = 0.0, Top = 0.0, Right = 0.0, Bottom = 0.0 },
            TintColor = { SpecifiedColor = { R = 0.0, G = 0.0, B = 0.0, A = 0.0 },
                ColorUseRule = COLOR_USE_SPECIFIED },
            OutlineSettings = {
                CornerRadii = { X = corner, Y = corner, Z = corner, W = corner },
                Color = { SpecifiedColor = tint, ColorUseRule = COLOR_USE_SPECIFIED },
                Width = width, RoundingType = rounding, bUseBrushTransparency = false,
            },
            DrawAs = DRAW_AS_ROUNDED_BOX, Tiling = 0, Mirroring = 0, ImageType = 0,
        }
    end

    -- Returns entry, how. "setbrush" or "property" on success; nil, reason otherwise.
    local function add_vector(parent, base, cx, cy, w, h, width, tint, rounding, corner)
        local entry, err = add_image(parent, base, cx, cy, w, h)
        if entry == nil then return nil, err end
        metrics.vector_attempts = metrics.vector_attempts + 1
        local brush = rounded_brush(w, h, width, tint, rounding, corner)
        local how = nil
        if pcall(entry.image.SetBrush, entry.image, brush) then
            how = "setbrush"
            metrics.vector_setbrush_writes = metrics.vector_setbrush_writes + 1
        elseif pcall(function() entry.image.Brush = brush end) then
            how = "property"
            metrics.vector_property_writes = metrics.vector_property_writes + 1
        end
        if how == nil then
            metrics.vector_failures = metrics.vector_failures + 1
            return nil, "brush-write-failed"
        end
        -- Read the enum back: a write that raised nothing but changed nothing is the
        -- silent failure the font code met. It must read back as RoundedBox, because
        -- an Image-type brush with no texture paints a solid white square over the
        -- map, which is worse than no frame.
        local draw_as = nil
        pcall(function() draw_as = tonumber(entry.image.Brush.DrawAs) end)
        if draw_as ~= DRAW_AS_ROUNDED_BOX then
            metrics.vector_failures = metrics.vector_failures + 1
            return nil, "brush-readback:" .. tostring(draw_as)
        end
        pcall(entry.image.SetColorAndOpacity, entry.image, { R = 1.0, G = 1.0, B = 1.0, A = 1.0 })
        return entry, how .. "+readback"
    end

    local function teardown()
        for _, entry in ipairs(frame.entries) do
            if valid(entry.image) then pcall(entry.image.RemoveFromParent, entry.image) end
        end
        if #frame.entries > 0 then metrics.teardowns = metrics.teardowns + 1 end
        frame.entries = {}
        frame.built_style, frame.built_shape, frame.built_color = "none", "none", "none"
    end

    local function build_line(parent, current_shape, tint, cx, cy, size)
        if current_shape == "circle" then
            local box = size * RING_SCALE
            return add_textured(parent, "Ring", TEX.ring, tint, cx, cy, box, box)
        end
        local half = size / 2.0
        local edge = half + BAR_THICK / 2.0
        local long = size + BAR_THICK * 2.0
        local thin_edge = half + BAR_THIN_INSET
        local thin_long = size + BAR_THIN_INSET * 2.0 + BAR_THIN
        local bars = {
            { "Top", cx, cy - edge, long, BAR_THICK },
            { "Bottom", cx, cy + edge, long, BAR_THICK },
            { "Left", cx - edge, cy, BAR_THICK, long },
            { "Right", cx + edge, cy, BAR_THICK, long },
            { "TopThin", cx, cy - thin_edge, thin_long, BAR_THIN },
            { "BottomThin", cx, cy + thin_edge, thin_long, BAR_THIN },
            { "LeftThin", cx - thin_edge, cy, BAR_THIN, thin_long },
            { "RightThin", cx + thin_edge, cy, BAR_THIN, thin_long },
        }
        for _, bar in ipairs(bars) do
            local entry, err = add_textured(parent, bar[1], TEX.white, tint, bar[2], bar[3], bar[4], bar[5])
            if entry == nil then return nil, err end
        end
        return true
    end

    -- The ornate textures are already colored (parchment, gold), so the preset is
    -- lifted halfway to white before it multiplies them: Bronze keeps the game's own
    -- color, the others tint it, and nothing turns to mud.
    local function lifted(tint)
        return { R = tint.R + (1.0 - tint.R) * 0.5, G = tint.G + (1.0 - tint.G) * 0.5,
            B = tint.B + (1.0 - tint.B) * 0.5, A = 1.0 }
    end

    local function build_ornate(parent, current_shape, tint, cx, cy, size)
        tint = lifted(tint)
        if current_shape == "circle" then
            local box = size * COMPASS_SCALE
            return add_textured(parent, "Compass", TEX.compass, tint, cx, cy, box, box)
        end
        local half = size / 2.0
        local edge = half + DIVIDER_THICK / 2.0
        local long = size + DIVIDER_THICK * 2.0
        local bars = {
            { "Top", cx, cy - edge, long, DIVIDER_THICK },
            { "Bottom", cx, cy + edge, long, DIVIDER_THICK },
        }
        for _, bar in ipairs(bars) do
            local entry, err = add_textured(parent, bar[1], TEX.divider, tint, bar[2], bar[3], bar[4], bar[5])
            if entry == nil then return nil, err end
        end
        -- The divider is a horizontal strip; the sides are the same strip turned.
        for _, side in ipairs({ { "Left", cx - edge }, { "Right", cx + edge } }) do
            local entry, err = add_textured(parent, side[1], TEX.divider, tint, side[2], cy, long, DIVIDER_THICK)
            if entry == nil then return nil, err end
            pcall(entry.image.SetRenderTransformAngle, entry.image, 90.0)
        end
        return true
    end

    local function build_vector(parent, current_shape, tint, cx, cy, size)
        local rounding = current_shape == "circle" and ROUNDING_HALF_HEIGHT or ROUNDING_FIXED
        local corner = current_shape == "circle" and 0 or VECTOR_CORNER
        local outer = size + 2.0 + VECTOR_WIDTH * 2.0
        local entry, how = add_vector(parent, "Vector", cx, cy, outer, outer, VECTOR_WIDTH, tint, rounding, corner)
        if entry == nil then return nil, how end
        if current_shape == "circle" then
            local second = outer + VECTOR_THIN_GAP * 2.0 + VECTOR_THIN * 2.0
            local dim = { R = tint.R * 0.7, G = tint.G * 0.7, B = tint.B * 0.7, A = 1.0 }
            local thin, thin_how = add_vector(parent, "VectorThin", cx, cy, second, second, VECTOR_THIN, dim, rounding, corner)
            if thin == nil then return nil, thin_how end
        end
        return true, how
    end

    local function build()
        teardown()
        local wanted = style()
        local current_shape = shape()
        local current_color = color()
        if wanted == "off" then
            frame.built_style, frame.built_shape, frame.built_color = "off", current_shape, current_color
            return true
        end
        local parent = root_canvas()
        if parent == nil then return false, "root-unavailable" end
        if not valid(frame.image_class) then frame.image_class = find_object(IMAGE_CLASS_PATH) end
        if not valid(frame.image_class) then return false, "image-class-unavailable" end
        local x, y, size = map_box()
        local cx, cy = x + size / 2.0, y + size / 2.0
        local tint = COLORS[current_color]
        metrics.builds = metrics.builds + 1
        local ok, err
        if wanted == "vector" then
            ok, err = build_vector(parent, current_shape, tint, cx, cy, size)
            if ok then
                frame.vector_status = tostring(err)
            else
                frame.vector_status = "failed:" .. tostring(err)
                frame.fallback_reason = tostring(err)
                log("Map frame vector style unavailable (" .. tostring(err) .. "); drawing the line style instead")
                teardown()
                wanted = "line"
                ok, err = build_line(parent, current_shape, tint, cx, cy, size)
            end
        elseif wanted == "ornate" then
            ok, err = build_ornate(parent, current_shape, tint, cx, cy, size)
        else
            ok, err = build_line(parent, current_shape, tint, cx, cy, size)
        end
        if not ok then
            metrics.build_failures = metrics.build_failures + 1
            log("Map frame build failed style=" .. tostring(wanted) .. " shape=" .. current_shape
                .. " reason=" .. tostring(err))
            teardown()
            return false, err
        end
        frame.built_style, frame.built_shape, frame.built_color = wanted, current_shape, current_color
        return true
    end

    local runtime = {}

    function runtime.OnRendererReady()
        if not state.built then return false end
        local ok = build()
        return ok == true
    end

    function runtime.ApplyLiveSetting(setting)
        if type(setting) ~= "table" then return end
        if setting.apply == "map-frame" then
            if state.built then build() end
        elseif setting.apply == "opacity" then
            local value = opacity()
            for _, entry in ipairs(frame.entries) do
                if valid(entry.image) and pcall(entry.image.SetRenderOpacity, entry.image, value) then
                    metrics.opacity_writes = metrics.opacity_writes + 1
                end
            end
        end
    end

    -- The widget tree the images live in is torn down with the renderer; drop our
    -- handles without touching them.
    function runtime.DropWorldReferencesUnread()
        frame.entries = {}
        frame.image_class = nil
        frame.built_style, frame.built_shape, frame.built_color = "none", "none", "none"
    end

    function runtime.Summary()
        return string.format(
            "style=%s shape=%s color=%s images=%d vector=%s builds=%d buildFailures=%d textureLoads=%d textureFailures=%d vectorAttempts=%d vectorWrites=%d/%d vectorFailures=%d teardowns=%d opacityWrites=%d",
            tostring(frame.built_style), tostring(frame.built_shape), tostring(frame.built_color),
            #frame.entries, tostring(frame.vector_status), metrics.builds, metrics.build_failures,
            metrics.texture_loads, metrics.texture_failures, metrics.vector_attempts,
            metrics.vector_setbrush_writes, metrics.vector_property_writes, metrics.vector_failures,
            metrics.teardowns, metrics.opacity_writes)
    end

    function runtime.EmitSummary(reason)
        log("Map frame summary reason=" .. tostring(reason) .. " " .. runtime.Summary())
    end

    -- How far (design units) the drawn frame reaches past the map edge, so the labels
    -- can sit below it. Uses what is actually built (a vector fallback is "line").
    local COMPASS_REACH = 0.941   -- the cardinal points' tip, as a fraction of the half-width
    function runtime.OuterExtent()
        local built = frame.built_style
        local current = (built ~= "none" and built ~= nil) and built or style()
        if current == "off" then return 0.0 end
        local _, _, size = map_box()
        local circle = shape() == "circle"
        if current == "line" then
            return circle and size * (RING_SCALE - 1.0) / 2.0 or (BAR_THIN_INSET + BAR_THIN / 2.0)
        elseif current == "vector" then
            return circle and (1.0 + VECTOR_WIDTH + VECTOR_THIN_GAP + VECTOR_THIN) or (1.0 + VECTOR_WIDTH)
        elseif current == "ornate" then
            return circle and size * (COMPASS_SCALE * COMPASS_REACH - 1.0) / 2.0 or DIVIDER_THICK
        end
        return 0.0
    end

    function runtime.State() return frame end

    return runtime
end

return Factory
