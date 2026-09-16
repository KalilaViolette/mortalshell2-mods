-- Primitive-only objective icon catalog. Exact Texture2D paths are sourced
-- from the current game object dump. Runtime code never inspects IconClass
-- CDOs or soft-reference wrappers; ObjectivePool resolves these known paths
-- once, outside movement, in bounded slices.

local Resolver = {}

local TEXTURE_ROOT = "/Game/Sparta/UI/World/Map/Textures/"

local function texture(name)
    return TEXTURE_ROOT .. name .. "." .. name
end

-- FModel cooked Texture2D dimensions for every exact POI texture in this catalog.
-- The old renderer forced every UImage CanvasSlot to a square, distorting native
-- non-square artwork such as the 32x102 Spire. Keep this primitive metadata beside
-- the exact texture catalog so runtime presentation never needs reflected texture-size reads.
local NATIVE_DIMENSIONS_BY_NAME = {
    T_UI_Icon_Map_Spire = { 32, 102 },
    T_UI_Icon_Map_Gate_Locked = { 175, 209 },
    T_UI_Icon_Map_Gate_Cleansed = { 147, 186 },
    T_UI_Icon_Map_Gate_Open = { 175, 209 },
    T_UI_Icon_Map_Dungeon_Uncompleted = { 512, 512 },
    T_UI_Icon_Map_Dungeon_Completed = { 512, 512 },
    T_UI_Icon_Map_EvilStatue_Discovered = { 512, 512 },
    T_UI_Icon_Map_EvilStatue_Completed = { 512, 512 },
    T_UI_Icon_Map_Beacon_Revitalized = { 189, 158 },
    T_UI_Icon_Map_Beacon_Cleansed = { 104, 156 },
    T_UI_Icon_Map_Beacon_Uncleansed = { 189, 158 },
    T_UI_Icon_Map_MiniBeacon_Uncleansed = { 104, 156 },
    T_UI_Icon_Map_MiniBeacon_Cleansed = { 104, 156 },
    T_UI_Icon_Map_RukStatue = { 246, 177 },
    T_UI_Icon_Map_Shells = { 512, 512 },
    T_UI_Icon_Map_Sidearms = { 512, 512 },
    T_UI_Icon_Map_Traversal_Unlocked = { 512, 512 },
    T_UI_Icon_Map_Traversal_Locked = { 512, 512 },
    T_UI_Icon_Map_Weapons = { 512, 512 },
    T_UI_MapActor_GloomLost = { 80, 130 },
    T_UI_Icon_Map_Tracker_Color = { 512, 512 },
}

local function texture_name(path)
    return tostring(path or ""):match("/([^/]+)%.")
end

function Resolver.NativeDimensions(path)
    local dimensions = NATIVE_DIMENSIONS_BY_NAME[texture_name(path)]
    if type(dimensions) ~= "table" then return nil, nil end
    return tonumber(dimensions[1]), tonumber(dimensions[2])
end

-- Fit native artwork inside a square maximum-extent budget without changing its
-- aspect ratio. The maximum extent remains the existing configured icon size, so
-- range/edge policies retain their conservative accepted footprint.
function Resolver.FitSize(path, maximum_extent)
    maximum_extent = tonumber(maximum_extent)
    if maximum_extent == nil or maximum_extent <= 0 then return nil, nil end
    local width, height = Resolver.NativeDimensions(path)
    if width == nil or height == nil or width <= 0 or height <= 0 then
        return maximum_extent, maximum_extent
    end
    if width >= height then
        return maximum_extent, maximum_extent * (height / width)
    end
    return maximum_extent * (width / height), maximum_extent
end

-- v0.18.3: the POI sizes, edge distances and discovery policy below are the ones
-- the author actually plays on, adopted from her own config so a fresh install
-- opens on the tuned set. `discovery_default` is the shipped value of this
-- family's DiscoveredOnly / DiscoveredHidden row.
Resolver.Categories = {
    {
        key = "Hub", label = "Hub / Spire", icon_class = "WBP_WMI_HUB_C",
        discovery_default = false,
        default_path = texture("T_UI_Icon_Map_Spire"),
        completed_path = texture("T_UI_Icon_Map_Spire"),
        size = 64, edge = true, edge_max_distance = 100, edge_min_scale = 0.25,
    },
    {
        key = "Boss", label = "Boss gates", icon_class = "WBP_WMI_Boss_C",
        discovery_default = false,
        default_path = texture("T_UI_Icon_Map_Gate_Locked"),
        completed_path = texture("T_UI_Icon_Map_Gate_Cleansed"),
        -- WBP_WMI_Boss also selects this state after its narrative gate opens.
        -- It is catalogued for bounded resolution, while the conservative
        -- two-state renderer continues to use only primitive objective state.
        alternate_paths = { texture("T_UI_Icon_Map_Gate_Open") },
        size = 36, edge = true, edge_max_distance = 150, edge_min_scale = 0.30,
    },
    {
        key = "Dungeon", label = "Dungeons", icon_class = "WBP_WMI_Dungeon_C",
        discovery_default = false,
        default_path = texture("T_UI_Icon_Map_Dungeon_Uncompleted"),
        completed_path = texture("T_UI_Icon_Map_Dungeon_Completed"),
        -- BP_STH_Entrance_Dungeon configures this objective as Manual reveal.
        -- A local minimap must still identify a nearby entrance the player can
        -- already see; the projection/range gate keeps unrevealed dungeons from
        -- becoming global discoveries.
        show_when_enabled = true,
        size = 36, edge = true, edge_max_distance = 150, edge_min_scale = 0.30,
    },
    {
        key = "EvilStatue", label = "Evil statues", icon_class = "WBP_WMI_EvilStatue_C",
        discovery_default = false,
        default_path = texture("T_UI_Icon_Map_EvilStatue_Discovered"),
        completed_path = texture("T_UI_Icon_Map_EvilStatue_Completed"),
        size = 36, edge = true, edge_max_distance = 150, edge_min_scale = 0.30,
    },
    {
        key = "LandingArea", label = "Landing areas", icon_class = "WBP_WMI_LandingArea_C",
        discovery_default = false,
        default_path = texture("T_UI_Icon_Map_Beacon_Revitalized"),
        completed_path = texture("T_UI_Icon_Map_Beacon_Cleansed"),
        -- The native widget uses the uncleansed image for a merely discovered
        -- landing area and the revitalized image after its owner is unlocked.
        -- Owner activation is intentionally not polled on the movement path.
        alternate_paths = { texture("T_UI_Icon_Map_Beacon_Uncleansed") },
        size = 40, edge = true, edge_max_distance = 150, edge_min_scale = 0.30,
    },
    {
        key = "SmallBeacon", label = "Small beacons", icon_class = "WBP_WMI_SmallBeacon_C",
        discovery_mode = "none",
        default_path = texture("T_UI_Icon_Map_MiniBeacon_Uncleansed"),
        completed_path = texture("T_UI_Icon_Map_MiniBeacon_Cleansed"),
        size = 36, edge = true, edge_max_distance = 25, edge_min_scale = 0.30,
    },
    {
        key = "MapStation", label = "Map stations", icon_class = "WBP_WMI_MapStation_C",
        discovery_default = false,
        default_path = texture("T_UI_Icon_Map_RukStatue"),
        completed_path = texture("T_UI_Icon_Map_RukStatue"),
        -- The game's world map presents this navigation landmark even while its
        -- objective RuntimeData is not in the ordinary revealed/visible set.
        -- FModel proves the exact objective owner/tag/widget chain, so permit
        -- only this family through the enabled+save-loaded state gate.
        show_when_enabled = true,
        size = 48, edge = true, edge_max_distance = 150, edge_min_scale = 0.30,
    },
    {
        key = "Shell", label = "Shells", icon_class = "WBP_WMI_Shell_C",
        discovery_default = true,
        discovery_mode = "hidden",
        default_path = texture("T_UI_Icon_Map_Shells"),
        completed_path = texture("T_UI_Icon_Map_Shells"),
        size = 36, edge = true, edge_max_distance = 200, edge_min_scale = 0.30,
    },
    {
        key = "Sidearm", label = "Sidearms", icon_class = "WBP_WMI_Sidearm_C",
        discovery_default = true,
        discovery_mode = "hidden",
        default_path = texture("T_UI_Icon_Map_Sidearms"),
        completed_path = texture("T_UI_Icon_Map_Sidearms"),
        size = 36, edge = true, edge_max_distance = 200, edge_min_scale = 0.30,
    },
    {
        key = "Traversal", label = "Traversal points", icon_class = "WBP_WMI_Traversal_C",
        discovery_default = false,
        default_path = texture("T_UI_Icon_Map_Traversal_Unlocked"),
        completed_path = texture("T_UI_Icon_Map_Traversal_Unlocked"),
        -- The native widget has an owner-driven inactive state. Preserve the
        -- accepted default until that primitive can be selected safely, but
        -- keep the exact locked texture in the bounded asset catalog.
        alternate_paths = { texture("T_UI_Icon_Map_Traversal_Locked") },
        size = 36, edge = true, edge_max_distance = 100, edge_min_scale = 0.40,
    },
    {
        key = "Weapon", label = "Weapons", icon_class = "WBP_WMI_Weapon_C",
        discovery_default = true,
        discovery_mode = "hidden",
        default_path = texture("T_UI_Icon_Map_Weapons"),
        completed_path = texture("T_UI_Icon_Map_Weapons"),
        size = 36, edge = true, edge_max_distance = 200, edge_min_scale = 0.30,
    },
    {
        -- Keep this final so adding the remaining family does not change any
        -- existing category index saved by v0.7. The exported game Blueprint
        -- binds WBP_WMI_Spoils directly to T_UI_MapActor_GloomLost.
        key = "Spoils", label = "Death spoils", icon_class = "WBP_WMI_Spoils_C",
        -- v0.16.8 (user): no "Discovered only" row -- your own dropped gloom is never
        -- something you have not discovered.
        discovery_mode = "none",
        default_path = texture("T_UI_MapActor_GloomLost"),
        completed_path = texture("T_UI_MapActor_GloomLost"),
        -- The native objective uses the same texture in both states. Completion
        -- means the lost Gloom was retrieved, so it must leave the minimap.
        hide_when_completed = true,
        size = 36, edge = true, edge_max_distance = 2000, edge_min_scale = 0.20,
    },
}

Resolver.FallbackPath = texture("T_UI_Icon_Map_Tracker_Color")

local BY_CLASS = {}
local BY_KEY = {}
local BY_OWNER_CLASS = {
    -- FModel export: BP_MapObjective_MapStation_C owns the
    -- BPC_WorldMapObjective whose native widget is WBP_WMI_MapStation_C.
    -- Some live instances do not expose that IconClass through reflection, so
    -- the exact owning Blueprint class is a stronger fallback than guessing.
    ["BP_MapObjective_MapStation_C"] = "MapStation",
}
local BY_TAG = {
    ["UI.MapActor.Boss"] = "Boss",
    ["UI.MapActor.Dungeon"] = "Dungeon",
    ["UI.MapActor.EvilStatue"] = "EvilStatue",
    ["UI.MapActor.MapStation"] = "MapStation",
    ["UI.MapActor.Shell"] = "Shell",
    ["UI.MapActor.Sidearm"] = "Sidearm",
    ["UI.MapActor.Traversal"] = "Traversal",
    ["UI.MapActor.Weapon"] = "Weapon",
    ["UI.MapActor.DeathSpoils"] = "Spoils",
    ["UI.MapActor.HUB"] = "Hub",
}
for index, category in ipairs(Resolver.Categories) do
    category.index = index
    category.config_prefix = "POI" .. category.key
    category.discovery_mode = tostring(category.discovery_mode or "only")
    category.config_keys = {
        Visible = category.config_prefix .. "Visible",
        IconSize = category.config_prefix .. "IconSize",
        EdgeIndicators = category.config_prefix .. "EdgeIndicators",
        EdgeMaxDistance = category.config_prefix .. "EdgeMaxDistance",
        EdgeMinScale = category.config_prefix .. "EdgeMinScale",
    }
    if category.discovery_mode == "hidden" then
        category.config_keys.DiscoveredHidden = category.config_prefix .. "DiscoveredHidden"
    elseif category.discovery_mode == "only" then
        category.config_keys.DiscoveredOnly = category.config_prefix .. "DiscoveredOnly"
    end
    BY_CLASS[category.icon_class] = category
    BY_KEY[category.key] = category
end

local function category_from_tag(objective_tag)
    objective_tag = tostring(objective_tag or "")
    local key = BY_TAG[objective_tag]
    if key ~= nil then return BY_KEY[key] end
    if objective_tag:find("UI.MapActor.LandingArea", 1, true) == 1 then
        if objective_tag:find("Small", 1, true) ~= nil
            or objective_tag:find("Mini", 1, true) ~= nil then
            return BY_KEY.SmallBeacon
        end
        return BY_KEY.LandingArea
    end
    return nil
end

function Resolver.Describe(icon_class, objective_tag, owner_class)
    local class_key = tostring(icon_class or "<no-icon-class>")
    local class_category = BY_CLASS[class_key]
    local tag_category = category_from_tag(objective_tag)
    local owner_category = BY_KEY[BY_OWNER_CLASS[tostring(owner_class or "")]]
    local category = class_category or tag_category or owner_category
    return {
        key = class_key,
        category_key = category and category.key or nil,
        category_index = category and category.index or nil,
        default_path = category and category.default_path or nil,
        completed_path = category and category.completed_path or nil,
        policy = category and (class_category ~= nil
            and "object-dump-exact-texture-path"
            or tag_category ~= nil
                and "objective-tag-fallback-exact-texture-path"
                or "objective-owner-class-fallback-exact-texture-path")
            or "unresolved-fail-closed",
    }
end

function Resolver.Category(key)
    return BY_KEY[tostring(key or "")]
end

function Resolver.Paths()
    local seen, paths = {}, {}
    local function add(path)
        if type(path) == "string" and path ~= "" and not seen[path] then
            seen[path] = true
            paths[#paths + 1] = path
        end
    end
    add(Resolver.FallbackPath)
    for _, category in ipairs(Resolver.Categories) do
        add(category.default_path)
        add(category.completed_path)
        for _, path in ipairs(category.alternate_paths or {}) do add(path) end
    end
    return paths
end

function Resolver.Policy()
    return "no-cdo-no-soft-wrapper-bounded-exact-texture-load"
end

return Resolver
