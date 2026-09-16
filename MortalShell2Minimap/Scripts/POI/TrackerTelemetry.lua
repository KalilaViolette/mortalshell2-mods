-- Manual, primitive-only tracker diagnostics for scale and presentation.
-- This module creates no UObjects, retains no actor references, and does no
-- per-frame work. It runs only when Registry.EmitSummary("ctrl-delete") does.

local Factory = {}

function Factory.New(ctx)
    local state = assert(ctx.State, "POI.TrackerTelemetry requires State")
    local Config = assert(ctx.Config, "POI.TrackerTelemetry requires Config")
    local log = assert(ctx.Log, "POI.TrackerTelemetry requires Log")
    local MapScale = assert(ctx.MapScale, "POI.TrackerTelemetry requires Map.Scale")
    local TrackerProjection = assert(ctx.TrackerProjection,
        "POI.TrackerTelemetry requires Overlay.TrackerProjection")
    local TrackerPool = assert(ctx.TrackerPool,
        "POI.TrackerTelemetry requires Overlay.TrackerPool")

    local WORLD_ORIGIN_X = 38050.053612
    local WORLD_ORIGIN_Y = -134391.872342
    local WORLD_SPAN_UNITS = MapScale.WORLD_SPAN_UNITS

    local runtime = {}

    local function normalized(world_x, world_y)
        return 0.5 - (world_x - WORLD_ORIGIN_X) / WORLD_SPAN_UNITS,
            0.5 - (world_y - WORLD_ORIGIN_Y) / WORLD_SPAN_UNITS
    end

    function runtime.Emit(trackers, tracker_count)
        local player_x = tonumber(state.player_world_x)
        local player_y = tonumber(state.player_world_y)
        local size = tonumber(Config.Size)
        local range_meters = tonumber(Config.ZoomMeters)
        tracker_count = math.max(0, math.floor(tonumber(tracker_count) or 0))

        if player_x == nil or player_y == nil or size == nil or range_meters == nil
            or size <= MapScale.MAP_INSET_PIXELS or range_meters <= 0 then
            log(string.format(
                "Tracker telemetry unavailable playerX=%s playerY=%s size=%s range=%s trackers=%d widgets=0",
                tostring(player_x), tostring(player_y), tostring(size),
                tostring(range_meters), tracker_count))
            return false
        end

        local native_zoom = MapScale.NativeZoom(range_meters)
        local native_scale = MapScale.NativePixelsPerWorldUnit(range_meters)
        local legacy_scale = MapScale.LegacyPixelsPerWorldUnit(size, range_meters)
        local correction = MapScale.CorrectionFactor(size, range_meters)
        local effective_span = MapScale.EffectiveVisibleMeters(size, range_meters)
        local marker_size = math.max(16,
            math.floor(tonumber(Config.TrackerIconSize) or 28))
        local player_u, player_v = normalized(player_x, player_y)
        log(string.format(
            "Tracker telemetry begin player=(%.3f,%.3f) playerMap=(%.6f,%.6f) size=%.1f range=%.1fm nativeZoom=%.6f logicalMapPixels=%.0f tileSurfacePixels=%.0f nativeScale=%.9f legacyScale=%.9f correction=%.6f effectiveSpan=%.3fm trackers=%d baseSize=%d persistentEdges=%s edgeRange=%.0fm edgeMinScale=%.2f edgeVisibility=%d%% widgets=0",
            player_x, player_y, player_u, player_v, size, range_meters,
            native_zoom, MapScale.MAP_LOGICAL_PIXELS,
            MapScale.NATIVE_TILE_SURFACE_PIXELS, native_scale, legacy_scale,
            correction, effective_span, tracker_count, marker_size,
            tostring(Config.ShowTrackerEdgeIndicators),
            Config.TrackerEdgeMaxDistance, Config.TrackerEdgeMinScale,
            math.floor(tonumber(Config.EdgeVisibility) or 50)))

        local indices = {}
        for index in pairs(type(trackers) == "table" and trackers or {}) do
            indices[#indices + 1] = index
        end
        table.sort(indices, function(a, b) return tonumber(a) < tonumber(b) end)

        local emitted = 0
        for _, index in ipairs(indices) do
            local record = trackers[index]
            local tracker_x = type(record) == "table" and tonumber(record.x) or nil
            local tracker_y = type(record) == "table" and tonumber(record.y) or nil
            if tracker_x ~= nil and tracker_y ~= nil then
                local delta_x = tracker_x - player_x
                local delta_y = tracker_y - player_y
                local distance_meters = math.sqrt(delta_x * delta_x + delta_y * delta_y) / 100.0
                local native_x = -delta_x * native_scale
                local native_y = -delta_y * native_scale
                local legacy_x = -delta_x * legacy_scale
                local legacy_y = -delta_y * legacy_scale
                local _, _, _, _, standard_inside, display_visible, _,
                    frame_limit, mode, rendered_size, boundary_distance,
                    display_x, display_y, inset_limit, size_scale,
                    size_progress = TrackerProjection.Position(
                        player_x, player_y, tracker_x, tracker_y, size,
                        range_meters, marker_size,
                        Config.ShowTrackerEdgeIndicators,
                        Config.TrackerEdgeMaxDistance,
                        Config.TrackerEdgeMinScale, 0.0,
                        state.map_rotation_angle, Config.MapShape,
                        marker_size, marker_size, Config.EdgeVisibility)
                local tracker_u, tracker_v = normalized(tracker_x, tracker_y)
                log(string.format(
                    "Tracker telemetry index=%s actor=%s tracker=(%.3f,%.3f) trackerMap=(%.6f,%.6f) worldDelta=(%.3f,%.3f) distance=%.3fm nativeOffset=(%.3f,%.3f) legacyOffset=(%.3f,%.3f) displayOffset=(%.3f,%.3f) frameLimit=%.3f edgeAnchorLimit=%.3f boundaryDistance=%.3fm mode=%s standardInside=%s displayVisible=%s renderedSize=%.0f sizeScale=%.3f sizeProgress=%.3f widgets=0",
                    tostring(index), tostring(record.actor_id), tracker_x, tracker_y,
                    tracker_u, tracker_v, delta_x, delta_y, distance_meters,
                    native_x, native_y, legacy_x, legacy_y,
                    display_x or 0.0, display_y or 0.0, frame_limit,
                    inset_limit, boundary_distance or 0.0,
                    TrackerProjection.ModeName(mode),
                    tostring(standard_inside), tostring(display_visible),
                    rendered_size, size_scale, size_progress))
                emitted = emitted + 1
            else
                log(string.format(
                    "Tracker telemetry index=%s actor=%s location=unavailable widgets=0",
                    tostring(index), tostring(type(record) == "table" and record.actor_id or nil)))
            end
        end

        log(string.format(
            "Tracker telemetry end emitted=%d registryCount=%d widgets=0",
            emitted, tracker_count))
        return true
    end

    return runtime
end

return Factory
