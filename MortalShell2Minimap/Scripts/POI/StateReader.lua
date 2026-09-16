-- Direct objective/save-state reader used only by budgeted reconciliation work.

local Factory = {}

function Factory.New(ctx)
    local Object = assert(ctx.Object, "POI.StateReader requires Core.Object")
    local Projection = assert(ctx.Projection, "POI.StateReader requires POI.Projection")
    local IconResolver = assert(ctx.IconResolver, "POI.StateReader requires POI.IconResolver")
    local runtime = {}

    local function weak_refs(component, owner, runtime_data)
        return setmetatable({
            component = component,
            owner = owner,
            runtime_data = runtime_data,
        }, { __mode = "v" })
    end

    local function tag_property(component, key)
        local value = nil
        pcall(function() value = component[key] end)
        return Object.Tag(value)
    end

    function runtime.ReadFull(component, generation)
        component = Object.Unwrap(component)
        if not Object.Valid(component) then return nil, "component-invalid" end
        local id = Object.Address(component)
        if id == nil then return nil, "component-address-unavailable" end

        local direct, runtime_data = Object.ObjectiveState(component)
        local location, route, owner = Object.ObjectiveLocation(component)
        local icon_class = nil
        pcall(function() icon_class = Object.Unwrap(component.IconClass) end)
        local objective_tag = tag_property(component, "ObjectiveTag")
        local owner_class = type(Object.ClassShortName) == "function"
            and Object.ClassShortName(owner) or nil
        local icon = IconResolver.Describe(
            Object.ShortName(icon_class), objective_tag, owner_class)
        local projected = location and Projection.WorldToMap(location.x, location.y) or nil
        local record = {
            id = id,
            generation = generation,
            refs = weak_refs(component, owner, runtime_data),
            owner_id = Object.Address(owner),
            owner_class = owner_class,
            runtime_id = direct.runtime,
            world_x = location and location.x or nil,
            world_y = location and location.y or nil,
            world_z = location and location.z or nil,
            location_route = route,
            map_x = projected and projected.x or nil,
            map_y = projected and projected.y or nil,
            normalized_x = projected and projected.normalized_x or nil,
            normalized_y = projected and projected.normalized_y or nil,
            icon_key = icon.key,
            icon_category = icon.category_key,
            icon_category_index = icon.category_index,
            icon_default_path = icon.default_path,
            icon_completed_path = icon.completed_path,
            icon_policy = icon.policy,
            objective_tag = objective_tag,
            biome_tag = tag_property(component, "BiomeTag"),
            equipment_tag = tag_property(component, "EquipmentTag"),
            custom_tag = tag_property(component, "OptionalCustomTag"),
            enabled = direct.enabled,
            save_loaded = direct.save_loaded,
            visible = direct.visible,
            revealed = direct.revealed,
            completed = direct.completed,
            show_area = direct.show_area,
            future_pool_slot = nil,
        }
        return record, nil
    end

    function runtime.RefreshState(record, current_component)
        if type(record) ~= "table" or type(record.refs) ~= "table" then
            return false, "record-invalid"
        end
        -- Prefer the strong wrapper supplied by the current audit/event. The
        -- record intentionally stores only a weak wrapper, which may be
        -- collected even while the native objective remains authoritative.
        local component = Object.Unwrap(current_component)
        if not Object.Valid(component) then component = Object.Unwrap(record.refs.component) end
        if not Object.Valid(component) then return false, "component-stale" end
        local direct, runtime_data = Object.ObjectiveState(component)
        record.refs.component = component
        record.refs.runtime_data = runtime_data
        record.runtime_id = direct.runtime
        record.enabled = direct.enabled
        record.save_loaded = direct.save_loaded
        record.visible = direct.visible
        record.revealed = direct.revealed
        record.completed = direct.completed
        record.show_area = direct.show_area
        return true, nil
    end

    return runtime
end

return Factory
