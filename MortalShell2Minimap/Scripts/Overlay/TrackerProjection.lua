-- Pure tracker projection and presentation policy. North-up remains the zero-angle baseline;
-- Camera-heading mode supplies the same UMG map-surface angle used by the renderer. Returns primitives
-- only; no UObject access, table allocation, mutation, or logging.

local Factory = {}

function Factory.New(ctx)
    local MapScale = assert(ctx.MapScale, "Overlay.TrackerProjection requires Map.Scale")
    local EdgePolicy = assert(ctx.EdgePolicy,
        "Overlay.TrackerProjection requires Overlay.EdgePolicy")
    local IconScale = assert(ctx.IconScale,
        "Overlay.TrackerProjection requires Overlay.IconScale")
    local state = ctx.State
    local Projection = {}
    local prepared = { revision = 0 }

    Projection.MODE_MAP = 0
    Projection.MODE_EDGE = 1
    Projection.MODE_HIDDEN = 2

    function Projection.Scale(size, zoom_meters)
        size = tonumber(size)
        if size == nil or size <= MapScale.MAP_INSET_PIXELS then return nil end
        return MapScale.NativePixelsPerWorldUnit(zoom_meters)
    end

    function Projection.ModeName(mode)
        if mode == Projection.MODE_MAP then return "map" end
        if mode == Projection.MODE_EDGE then return "persistent-edge" end
        return "hidden"
    end

    function Projection.Prepare(size, zoom_meters, map_rotation_angle,
        map_shape, edge_visibility)
        size = tonumber(size)
        local scale = Projection.Scale(size, zoom_meters)
        if size == nil or scale == nil then return nil end
        local angle = tonumber(map_rotation_angle) or 0.0
        local shape = tostring(map_shape or "square"):lower() == "circle"
        local visible_fraction = EdgePolicy.VisibilityFraction(edge_visibility)
        local range_changed = prepared.size ~= size or prepared.scale ~= scale
            or prepared.circle ~= shape
        if prepared.size ~= size or prepared.scale ~= scale
            or prepared.angle ~= angle or prepared.circle ~= shape
            or prepared.visible_fraction ~= visible_fraction then
            prepared.size = size
            prepared.half_size = size / 2.0
            prepared.scale = scale
            prepared.angle = angle
            prepared.circle = shape
            prepared.visible_fraction = visible_fraction
            prepared.rotation_cos, prepared.rotation_sin,
                prepared.rotation_identity = MapScale.RotationBasis(angle)
            prepared.map_circumscribed_pixels = shape
                and prepared.half_size or prepared.half_size * math.sqrt(2.0)
            if range_changed then
                prepared.range_revision = (tonumber(prepared.range_revision) or 0) + 1
            end
            prepared.revision = prepared.revision + 1
            if type(state) == "table" and type(state.performance) == "table" then
                state.performance.projection_context_updates =
                    (tonumber(state.performance.projection_context_updates) or 0) + 1
            end
        end
        return prepared
    end

    function Projection.RelevantRadiusSquared(context, marker_radius_pixels,
        edge_enabled, edge_max_distance)
        if type(context) ~= "table" or tonumber(context.scale) == nil
            or context.scale <= 0 then return nil end
        marker_radius_pixels = math.max(0.0, tonumber(marker_radius_pixels) or 0.0)
        local map_radius = (context.map_circumscribed_pixels + marker_radius_pixels)
            / context.scale
        local edge_radius = edge_enabled == true
            and math.max(0.0, tonumber(edge_max_distance) or 0.0) * 100.0 or 0.0
        local radius = math.max(map_radius, edge_radius)
        return radius * radius
    end

    function Projection.PositionPrepared(context, player_x, player_y,
        tracker_x, tracker_y, marker_size, edge_enabled, edge_max_distance,
        edge_min_scale, marker_width, marker_height)
        if type(context) ~= "table" then return nil end
        player_x, player_y = tonumber(player_x), tonumber(player_y)
        tracker_x, tracker_y = tonumber(tracker_x), tonumber(tracker_y)
        marker_size = tonumber(marker_size)
        edge_max_distance = tonumber(edge_max_distance)
        edge_min_scale = tonumber(edge_min_scale)
        marker_width = tonumber(marker_width) or marker_size
        marker_height = tonumber(marker_height) or marker_size
        if player_x == nil or player_y == nil or tracker_x == nil or tracker_y == nil
            or marker_size == nil or marker_size <= 0
            or marker_width == nil or marker_width <= 0
            or marker_height == nil or marker_height <= 0 then return nil end

        local delta_x = tracker_x - player_x
        local delta_y = tracker_y - player_y
        local offset_x, offset_y = MapScale.RotateScreenOffsetBasis(
            -delta_x * context.scale, -delta_y * context.scale,
            context.rotation_cos, context.rotation_sin, context.rotation_identity)
        local distance_meters = math.sqrt(delta_x * delta_x + delta_y * delta_y) / 100.0
        local standard_inside, frame_limit = EdgePolicy.Standard(
            context.size, offset_x, offset_y, context.circle)
        if standard_inside == nil then return nil end

        local display_x, display_y = offset_x, offset_y
        local display_anchor_limit = frame_limit
        local rendered_size = marker_size
        local display_visible = standard_inside
        local mode = standard_inside and Projection.MODE_MAP or Projection.MODE_HIDDEN
        local boundary_distance = nil
        local size_scale, size_progress = 1.0, 0.0

        -- At or below 50%, every standard-inside center is already valid. Only
        -- compute exact edge geometry here when the user requests a deeper inset.
        if standard_inside then
            if edge_enabled == true and context.visible_fraction > 0.50 then
                local anchor_inside, anchor_limit, anchor_factor = EdgePolicy.Anchor(
                    context.size, offset_x, offset_y, marker_width, marker_height,
                    context.visible_fraction, context.circle)
                if anchor_inside == nil then return nil end
                display_anchor_limit = anchor_limit
                boundary_distance = EdgePolicy.DistanceAtLimit(
                    distance_meters, offset_x, offset_y, anchor_limit,
                    context.circle, anchor_factor)
                if not anchor_inside then
                    display_x, display_y = offset_x * anchor_factor, offset_y * anchor_factor
                    mode = Projection.MODE_EDGE
                end
            end
        else
            -- Far/disabled markers stop here before exact Square/Circle anchor
            -- work. ObjectivePool's broader squared-distance gate normally
            -- rejects these even earlier, before rotation and square root.
            local edge_range_ok = edge_enabled == true
                and edge_max_distance ~= nil and edge_max_distance > 0.0
                and distance_meters <= edge_max_distance
            if edge_range_ok then
                local _, anchor_limit, anchor_factor = EdgePolicy.Anchor(
                    context.size, offset_x, offset_y, marker_width, marker_height,
                    context.visible_fraction, context.circle)
                if anchor_limit == nil or anchor_factor == nil then return nil end
                boundary_distance = EdgePolicy.DistanceAtLimit(
                    distance_meters, offset_x, offset_y, anchor_limit,
                    context.circle, anchor_factor)
                rendered_size, size_scale, size_progress = IconScale.Quantized(
                    marker_size, edge_min_scale or 1.0, distance_meters,
                    boundary_distance, edge_max_distance)
                if rendered_size ~= nil then
                    local marker_scale = rendered_size / marker_size
                    local rendered_width = marker_width * marker_scale
                    local rendered_height = marker_height * marker_scale
                    local scaled_inside, scaled_limit, scaled_factor = EdgePolicy.Anchor(
                        context.size, offset_x, offset_y, rendered_width, rendered_height,
                        context.visible_fraction, context.circle)
                    if scaled_inside == nil then return nil end
                    display_anchor_limit = scaled_limit
                    if not scaled_inside then
                        display_x, display_y = offset_x * scaled_factor, offset_y * scaled_factor
                    end
                    display_visible = true
                    mode = Projection.MODE_EDGE
                end
            end
        end

        local position_x = display_x ~= nil
            and context.size / 2.0 + display_x - rendered_size / 2.0 or nil
        local position_y = display_y ~= nil
            and context.size / 2.0 + display_y - rendered_size / 2.0 or nil
        return position_x, position_y, offset_x, offset_y, standard_inside,
            display_visible, distance_meters, frame_limit, mode, rendered_size,
            boundary_distance, display_x, display_y, display_anchor_limit,
            size_scale, size_progress
    end

    function Projection.Position(player_x, player_y, tracker_x, tracker_y,
        size, zoom_meters, marker_size, edge_enabled, edge_max_distance,
        edge_min_scale, edge_inset_scale, map_rotation_angle, map_shape,
        marker_width, marker_height, edge_visibility)
        local context = Projection.Prepare(size, zoom_meters,
            map_rotation_angle, map_shape, edge_visibility)
        return Projection.PositionPrepared(context, player_x, player_y,
            tracker_x, tracker_y, marker_size, edge_enabled, edge_max_distance,
            edge_min_scale, marker_width, marker_height)
    end

    return Projection
end

return Factory
