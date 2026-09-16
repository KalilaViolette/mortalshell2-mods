-- Declarative, tabbed ModUI settings schema. Each tab deliberately stays below
-- the shared shell's visible-row budget, while the selected POI category keeps
-- twelve independent policies editable without a sixty-row page.

local Factory = {}

local function percent(value)
    return tostring(math.floor((tonumber(value) or 0) * 100 + 0.5)) .. "%"
end

local function on_off(value) return value and "ON" or "OFF" end
local function map_orientation(value)
    value = tostring(value or "north")
    if value == "camera" then return "Camera heading up" end
    if value == "player" then return "Player heading up" end
    return "North up"
end
local function map_shape(value) return tostring(value or "square") == "circle" and "Circle" or "Square" end
-- v0.17.0 map frame rows; the style names follow the shape.
local function map_frame(value, Config)
    local style = tostring(value or "line"):lower()
    local circle = type(Config) == "table" and tostring(Config.MapShape or "square"):lower() == "circle"
    if style == "off" then return "Off" end
    if style == "vector" then return circle and "Vector ring" or "Vector outline" end
    if style == "ornate" then return circle and "Compass" or "Gold dividers" end
    return circle and "Ring" or "Bars"
end
local function map_frame_color(value)
    value = tostring(value or "bronze"):lower()
    return value:sub(1, 1):upper() .. value:sub(2)
end
-- v0.15.0 CAPTURE tab labels. The numbers are the engine's own enums
-- (ESceneCaptureSource, ETextureRenderTargetFormat) so the log and the row agree.
local CAPTURE_SOURCE_LABELS = {
    [0] = "Scene color HDR", [1] = "Scene color, no alpha", [2] = "Final color LDR",
    [3] = "Scene color + depth", [4] = "Scene depth", [5] = "Device depth",
    [6] = "Normals", [7] = "Base color (draws nothing)", [8] = "Final color HDR",
    [9] = "Final tone curve HDR",
}
local function capture_source(value)
    local number = math.floor(tonumber(value) or 3)
    return CAPTURE_SOURCE_LABELS[number] or tostring(value)
end
local CAPTURE_FORMAT_LABELS = {
    [2] = "RGBA8 linear", [3] = "RGBA8 sRGB", [6] = "RGBA16 float",
    [9] = "RGBA32 float", [10] = "RGB10A2",
}
local function capture_format(value)
    local number = math.floor(tonumber(value) or 3)
    return CAPTURE_FORMAT_LABELS[number] or tostring(value)
end
local function exposure_method(value)
    local number = math.floor(tonumber(value) or 0)
    return ({ [0] = "Histogram", [1] = "Basic", [2] = "Manual" })[number] or tostring(value)
end
local function stops(value)
    local number = tonumber(value) or 0
    if number == 0 then return "0" end
    return string.format("%+.1f", number)
end
local function ev(value) return tostring(tonumber(value) or 0) .. " EV" end
local CAPTURE_BIAS_VALUES = {}
for index = 0, 40 do CAPTURE_BIAS_VALUES[#CAPTURE_BIAS_VALUES + 1] = -10.0 + index * 0.5 end
local CAPTURE_EV_VALUES = { -10, -8, -6, -4, -2, -1, 0, 1, 2, 3, 4, 6, 8, 10, 12, 14, 16, 18, 20 }
local function no_map_background(value)
    value = tostring(value or "dungeon"):lower()
    if value == "transparent" then return "Transparent" end
    if value == "cloud" then return "Cloud" end
    return "Dungeon map"
end
local function pixels(value) return tostring(value) .. " px" end
local function meters(value) return tostring(value) .. " m" end
local function whole_percent(value) return tostring(math.floor((tonumber(value) or 0) + 0.5)) .. "%" end
local function whole_percent_of(value)
    return tostring(math.floor((tonumber(value) or 0) * 100 + 0.5)) .. "%"
end

local BINDING_LABELS = {
    LeftControl = "Ctrl", RightControl = "Right Ctrl", LeftShift = "Shift",
    RightShift = "Right Shift", LeftAlt = "Alt", RightAlt = "Right Alt",
    Gamepad_LeftThumbstick = "L3", Gamepad_RightThumbstick = "R3",
    Gamepad_DPad_Up = "D-Pad Up", Gamepad_DPad_Down = "D-Pad Down",
    Gamepad_DPad_Left = "D-Pad Left", Gamepad_DPad_Right = "D-Pad Right",
}

local function binding_label(value)
    value = tostring(value or "off")
    if value:lower() == "off" then return "Unbound" end
    local raw = value:sub(1, 4):lower() == "seq:" and value:sub(5) or value
    local out = {}
    for token in raw:gmatch("[^+>]+") do
        local clean = token:match("^%s*(.-)%s*$")
        out[#out + 1] = BINDING_LABELS[clean] or clean
    end
    return table.concat(out, " + ")
end

local function selected_category(categories, Config)
    local index = math.max(1, math.min(#categories,
        math.floor(tonumber(Config.POISettingsCategory) or 1)))
    return categories[index]
end

local function dynamic_setting(categories, suffix, definition)
    definition.read = function(Config)
        local category = selected_category(categories, Config)
        return category and Config[category.config_prefix .. suffix] or nil
    end
    definition.write = function(Config, value)
        local category = selected_category(categories, Config)
        if category ~= nil then Config[category.config_prefix .. suffix] = value end
    end
    definition.resolve_key = function(Config)
        local category = selected_category(categories, Config)
        return category and (category.config_prefix .. suffix) or nil
    end
    definition.dynamic_suffix = suffix
    return definition
end

local function discovery_setting(categories)
    local function mode(Config)
        local category = selected_category(categories, Config)
        return category and tostring(category.discovery_mode or "only") or "none"
    end
    local function key(Config)
        local category = selected_category(categories, Config)
        if category == nil then return nil end
        local current_mode = tostring(category.discovery_mode or "only")
        if current_mode == "hidden" then return category.config_prefix .. "DiscoveredHidden" end
        if current_mode == "only" then return category.config_prefix .. "DiscoveredOnly" end
        return nil
    end
    return {
        key = "SelectedPOIDiscovery",
        label = function(Config)
            return mode(Config) == "hidden" and "Discovered hidden" or "Discovered only"
        end,
        detail = function(Config)
            return mode(Config) == "hidden"
                and "Hide locations in this equipment family after they have been discovered."
                or "Only show locations you've discovered."
        end,
        values = { false, true }, format = on_off, apply = "poi-presentation",
        hidden = function(Config) return mode(Config) == "none" end,
        read = function(Config)
            local resolved = key(Config)
            return resolved ~= nil and Config[resolved] or false
        end,
        write = function(Config, value)
            local resolved = key(Config)
            if resolved ~= nil then Config[resolved] = value == true end
        end,
        resolve_key = key,
        dynamic_suffix = "DiscoveryPolicy",
    }
end

local SIZE_VALUES = { 160, 180, 200, 220, 240, 260, 280, 300, 320, 360, 400, 450, 500 }
local MAP_RANGE_VALUES = { 25, 50, 75, 100, 140, 180, 250, 350, 500, 750, 1000, 1500, 2000, 3000, 5000, 8000, 10000, 15000, 25000, 50000 }
local ICON_SIZE_VALUES = { 12, 14, 16, 18, 20, 22, 24, 26, 28, 30, 32, 36, 40, 48, 56, 64, 80, 96, 112, 128 }
local EDGE_RANGE_VALUES = { 10, 15, 25, 35, 50, 75, 100, 150, 200, 250, 350, 500, 750, 1000, 1500, 2000, 3000, 5000 }
local SCALE_VALUES = { 0.20, 0.25, 0.30, 0.35, 0.40, 0.50, 0.60, 0.70, 0.80, 0.90, 1.00 }
-- Per-category local icon scale. Reaches above 1.00 because the shared base size is
-- tuned for interactables and a boss marker legitimately wants to be bigger than one.
local LOCAL_SCALE_VALUES = {
    0.25, 0.30, 0.35, 0.40, 0.45, 0.50, 0.60, 0.70, 0.80, 0.90,
    1.00, 1.10, 1.25, 1.50, 1.75, 2.00,
}
local EDGE_VISIBILITY_VALUES = { 0, 5, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55, 60, 65, 70, 75, 80, 85, 90, 95, 100 }

function Factory.New(categories, local_categories, local_art, label_art)
    categories = type(categories) == "table" and categories or {}
    -- v0.17.1: the Labels module names the fonts and colors its rows cycle through.
    local label_fonts = type(label_art) == "table" and type(label_art.FontChoices) == "table"
        and label_art.FontChoices or { { key = "trajan", label = "Trajan" } }
    local label_colors = type(label_art) == "table" and type(label_art.ColorChoices) == "table"
        and label_art.ColorChoices or { "white" }
    local label_font_keys, label_font_labels = {}, {}
    for i, choice in ipairs(label_fonts) do
        label_font_keys[i] = choice.key
        label_font_labels[choice.key] = choice.label
    end
    -- v0.17.0: the Classifier (or anything with IconOptions / ColorOptions / TintLabel)
    -- names the icons and colors the LOCAL rows cycle through. Without it the two
    -- rows still exist and cycle whatever keys the category list carries.
    local art = type(local_art) == "table" and local_art or {}
    local function icon_option_keys(category)
        local out = {}
        if category == nil then return out end
        if type(art.IconOptions) == "function" then
            for i, option in ipairs(art.IconOptions(category.key)) do out[i] = option.key end
        elseif type(category.icons) == "table" then
            for i, key in ipairs(category.icons) do out[i] = key end
        end
        return out
    end
    local function icon_option_label(category, value)
        if category ~= nil and type(art.IconOptions) == "function" then
            for _, option in ipairs(art.IconOptions(category.key)) do
                if option.key == tostring(value) then return option.label end
            end
        end
        return tostring(value or "default")
    end
    local function color_option_keys(category, icon)
        local out = {}
        if category == nil then return out end
        if type(art.ColorOptions) == "function" then
            for i, option in ipairs(art.ColorOptions(category.key, icon)) do out[i] = option.key end
        elseif type(category.colors) == "table" then
            for i, key in ipairs(category.colors) do out[i] = key end
        end
        return out
    end
    local function color_label(value)
        if type(art.TintLabel) == "function" then return art.TintLabel(value) end
        return tostring(value or "white")
    end
    local category_values = {}
    for index = 1, #categories do category_values[index] = index end
    -- v0.10.11 local-interactable categories (Local.Classifier.CategoryList()).
    local_categories = type(local_categories) == "table" and #local_categories > 0 and local_categories or {
        { key = "Lore", label = "Lore / notes" }, { key = "Chest", label = "Chests" },
        { key = "ShellGhost", label = "Shell ghosts" }, { key = "Pickup", label = "Pickups" },
        { key = "Other", label = "Other interactables" }, { key = "NPC", label = "NPCs / merchants" },
        { key = "Movement", label = "Movement spots" },
    }
    local local_category_values = {}
    for index = 1, #local_categories do local_category_values[index] = index end
    local function selected_local(Config)
        local index = math.max(1, math.min(#local_categories,
            math.floor(tonumber(Config.LocalSettingsCategory) or 1)))
        return local_categories[index]
    end
    local function selected_local_key(Config)
        local category = selected_local(Config)
        return category and ("LocalShow" .. tostring(category.key)) or nil
    end
    -- v0.11.7: the LOCAL tab gets the same per-category shape the ICONS tab has had
    -- since v0.10.x -- one selector row, and every row under it addressing only the
    -- selected category's own key. Before this, "Local icon size" was a single number
    -- for the whole pool, so shrinking bear traps shrank enemies and chests with them.
    local function local_dynamic_setting(prefix, definition)
        definition.read = function(Config)
            local category = selected_local(Config)
            return category and Config[prefix .. tostring(category.key)] or nil
        end
        definition.write = function(Config, value)
            local category = selected_local(Config)
            if category ~= nil then Config[prefix .. tostring(category.key)] = value end
        end
        definition.resolve_key = function(Config)
            local category = selected_local(Config)
            return category and (prefix .. tostring(category.key)) or nil
        end
        definition.dynamic_suffix = prefix
        return definition
    end

    -- v0.16.8 (user decision 2026-09-14): a fresh install shows the rows a player
    -- actually wants; the CAPTURE tab and the budget / rate / LOD rows sit behind one
    -- "Advanced settings" switch on the MOD tab. Hidden rows keep their values.
    local function advanced_hidden(Config)
        return Config.AdvancedSettings ~= true
    end
    -- v0.18.0 (user decision 2026-09-14): section headers inside a tab. A header is a
    -- row with no key and no value; the UI never selects it, the ModUI host draws it as
    -- a divider (-- TITLE --), and it is the spacing between one group and the next.
    local function header(label)
        return { kind = "header", label = label }
    end
    local tabs = {
        {
            key = "GENERAL", label = "GENERAL",
            settings = {
                header("Minimap"),
                {
                    key = "Enabled", label = "Minimap", detail = "Show or hide the minimap during normal gameplay.",
                    values = { false, true }, format = on_off,
                },
                {
                    key = "Size", label = "Size", detail = "Square minimap size in screen pixels. Applied live.",
                    -- v0.18.43: was rebuild = true. Every size-dependent line in the
                    -- renderer's build is a slot property write on a widget this mod owns,
                    -- so the size is applied in place; see Map/NativeWidget.ApplySizeLayout.
                    values = SIZE_VALUES, format = pixels, apply = "size",
                },
                {
                    key = "ZoomMeters", label = "Map range", detail = "Controls how much of the world is visible. This expanded scale reaches far beyond the earlier 750 maximum.",
                    values = MAP_RANGE_VALUES, format = meters, apply = "zoom",
                },
                {
                    key = "Opacity", label = "Opacity", detail = "Opacity of the complete minimap.",
                    values = { 0.20, 0.30, 0.40, 0.50, 0.60, 0.70, 0.75, 0.80, 0.85, 0.90, 0.92, 0.95, 1.00 },
                    format = percent, apply = "opacity",
                },
                {
                    key = "ShowArrow", label = "Player arrow", detail = "Show the native player-facing icon at the center. Camera heading up shows player facing relative to the camera; Player heading up keeps the arrow straight up.",
                    values = { false, true }, format = on_off, apply = "arrow",
                },
                header("Position"),
                {
                    key = "OffsetX", label = "Position X", detail = "Horizontal distance from the left edge of the screen.",
                    values = { 0, 8, 16, 28, 40, 60, 80, 100, 140, 180, 240, 320, 480, 720, 1000, 1500, 2000 },
                    format = pixels, rebuild = true,
                },
                {
                    key = "OffsetY", label = "Position Y", detail = "Vertical distance from the top edge of the screen.",
                    values = { 0, 8, 16, 28, 40, 52, 64, 80, 100, 140, 180, 240, 320, 480, 720, 1000, 1500, 2000 },
                    format = pixels, rebuild = true,
                },
                header("Shape & frame"),
                {
                    key = "MapShape", label = "Map shape",
                    detail = "Use the current square minimap, or clip the complete minimap subtree to a circle with radial edge clamping.",
                    values = { "square", "circle" }, format = map_shape, rebuild = true,
                },
                {
                    key = "MapOrientation", label = "Map orientation",
                    detail = "Keep north at the top, keep the final gameplay camera heading at the top, or keep the player's facing direction at the top.",
                    values = { "north", "camera", "player" }, format = map_orientation, apply = "orientation",
                },
                -- v0.17.0 map frame (user decision 2026-09-14): one row cycling every
                -- style for the current shape, a color row under it, on by default.
                {
                    key = "MapFrame", label = "Map frame",
                    detail = "A frame drawn around the map edge. Circle: Ring is the game's thin double ring, Vector ring is drawn by the engine at any size, Compass is the world map's cursor ring with its four points. Square: Bars are crisp lines at any size, Vector outline is engine-drawn with rounded corners, Gold dividers are the game's gold rule. Vector needs the engine to accept the brush; if it does not, Ring or Bars is drawn instead and the Ctrl+Delete summary says so.",
                    values = { "off", "line", "vector", "ornate" }, format = map_frame, apply = "map-frame",
                },
                {
                    key = "MapFrameColor", label = "Frame color",
                    detail = "Color of the frame. Bronze is the game's own gold-grey UI line.",
                    values = { "bronze", "white", "red", "blue", "green" }, format = map_frame_color, apply = "map-frame",
                    hidden = function(Config) return tostring(Config.MapFrame or "line"):lower() == "off" end,
                },
            },
        },
        {
            -- v0.16.8 (user decision 2026-09-14): what is drawn ON the map -- the dungeon
            -- view, labels, the trail and the marker decorations -- in one place, so LOCAL
            -- is only the local-marker categories and GENERAL is only the frame.
            key = "MAP", label = "MAP",
            settings = {
                header("Dungeon map"),
                {
                    key = "NoMapBackground", label = "No-map background",
                    detail = "What fills the minimap where the game has no map at all, which in practice means inside dungeons. Dungeon map draws a live top-down view of the rooms around you; Transparent shows only your markers; Cloud keeps the game's own fog plate. If the live view cannot start for any reason it falls back to Transparent on its own.",
                    values = { "dungeon", "transparent", "cloud" },
                    format = no_map_background, apply = "area-presentation",
                },
                {
                    key = "DungeonViewBrightness", label = "Dungeon map brightness",
                    detail = "How bright the live top-down view is drawn inside dungeons, where the game has no map. The capture is unlit, so how well lit a dungeon is does not change the picture at all -- only what its walls and floors are made of does. The default suits stone; raise it for a pale dungeon that reads washed out, lower it for one that reads muddy.",
                    values = { 0.40, 0.50, 0.60, 0.70, 0.80, 0.90, 1.00, 1.10, 1.25, 1.50 },
                    format = whole_percent_of, apply = "dungeon-brightness",
                },
                {
                    key = "DungeonViewOpenWorldBrightness", label = "Open world brightness",
                    detail = "The same thing for the open world, used only when Dungeon map everywhere is on. It is a separate number because sunlit ground is far higher albedo than dungeon stone and glares at the brightness that suits a dungeon; the two rows do not affect each other.",
                    values = { 0.20, 0.30, 0.40, 0.50, 0.55, 0.60, 0.70, 0.80, 0.90, 1.00 },
                    format = whole_percent_of, apply = "dungeon-brightness",
                },
                {
                    key = "DungeonViewEverywhere", label = "Dungeon map everywhere",
                    detail = "Also use the live top-down view out in the open world, in place of the game's drawn map. It costs a little frame time whenever it is drawing, which is why it is off by default and limited to dungeons otherwise.",
                    values = { false, true }, format = on_off, apply = "dungeon",
                },
                {
                    key = "DungeonViewRate", label = "Dungeon map rate",
                    hidden = advanced_hidden,
                    detail = "How often the live top-down view re-renders while you are moving. It costs render time rather than game-thread time, so it shows up as frame rate and not as stutter. Standing still costs nothing until a slow idle refresh. 30 Hz is the default, and 5 Hz was the benchmarked minimum-cost setting. It only runs inside dungeons unless you turn Dungeon map everywhere on.",
                    values = { 2, 5, 10, 15, 20, 30, 45, 60 },
                    format = function(value) return tostring(value) .. " Hz" end,
                    apply = "dungeon",
                },
                {
                    -- v0.16.11 (user: "for when I'm in tight spaces the camera comes in
                    -- closer, but when I'm in wide open ones it lifts up revealing more of
                    -- the terrain so it doesn't get cut off").
                    key = "DungeonViewCeilingAuto", label = "Ceiling cut",
                    hidden = advanced_hidden,
                    detail = "Auto measures the headroom above you a few times a second and cuts the dungeon map just under the ceiling: low in a corridor, high in a hall, so upper floors and rising ground stop being sliced away. Fixed always cuts at the CAPTURE tab's \"Ceiling cut\" height, which is also Auto's lowest setting.",
                    values = { true, false },
                    format = function(value) return value ~= false and "Auto" or "Fixed" end,
                    apply = "dungeon-ceiling",
                },
                header("Labels"),
                {
                    key = "MapLabels", label = "Map labels",
                    detail = "Text on the minimap, drawn in the game's own font: the region name under the map, cardinal letters on the edge, or both.",
                    values = { 0, 1, 2, 3 },
                    format = function(value)
                        value = math.floor(tonumber(value) or 0)
                        if value == 1 then return "Area name" end
                        if value == 2 then return "Cardinals" end
                        if value == 3 then return "Both" end
                        return "Off"
                    end,
                    apply = "labels",
                },
                -- v0.17.1 (user: "adjust the label size / text style / color ... and maybe
                -- some fonts"): the label rows. Every one re-dresses the live text.
                {
                    key = "MapLabelSize", label = "Label size",
                    detail = "Point size of the label text. Auto scales it from the map size; a number sets it outright. The cardinal letters use this size, the region name two points more, the second line the same as the letters.",
                    values = { 0, 6, 7, 8, 9, 10, 11, 12, 13, 14, 16, 18, 20, 22, 24, 28 },
                    format = function(value)
                        value = math.floor(tonumber(value) or 0)
                        if value <= 0 then return "Auto" end
                        return tostring(value) .. " pt"
                    end,
                    apply = "labels",
                },
                {
                    key = "MapLabelFont", label = "Label font",
                    detail = "Which of the game's own fonts the labels use. Trajan is the face of the game's headings; Crimson Text is its body text. Game announcement adopts whatever face the last area announcement used. A font that cannot be loaded falls back to Trajan.",
                    values = label_font_keys,
                    format = function(value) return label_font_labels[tostring(value)] or tostring(value) end,
                    apply = "labels",
                },
                {
                    key = "MapLabelColor", label = "Label color",
                    detail = "Color of the label text.",
                    values = label_colors,
                    format = function(value)
                        value = tostring(value or "white")
                        return value:sub(1, 1):upper() .. value:sub(2)
                    end,
                    apply = "labels",
                },
                {
                    key = "MapLabelOutline", label = "Label outline",
                    hidden = advanced_hidden,
                    detail = "A dark outline around each letter, for reading over a pale map without the fog plate.",
                    values = { 0, 1, 2, 3 },
                    format = function(value)
                        value = math.floor(tonumber(value) or 0)
                        return ({ [0] = "Off", [1] = "Thin", [2] = "Medium", [3] = "Thick" })[value] or "Off"
                    end,
                    apply = "labels",
                },
                {
                    key = "MapLabelShadow", label = "Label shadow",
                    hidden = advanced_hidden,
                    detail = "A one-pixel drop shadow under the letters.",
                    values = { false, true }, format = on_off, apply = "labels",
                },
                {
                    key = "MapLabelCardinals", label = "Cardinal letters",
                    detail = "North only, or all four letters on the map edge.",
                    values = { 1, 4 },
                    format = function(value)
                        return math.floor(tonumber(value) or 1) >= 4 and "N E S W" or "North only"
                    end,
                    apply = "labels",
                },
                header("Markers"),
                {
                    key = "FootstepTrail", label = "Footstep trail",
                    detail = "Leaves fading breadcrumbs along the path you walked. Longer trails keep more marks alive.",
                    values = { 0, 8, 16, 24, 32, 48 },
                    format = function(value)
                        value = math.floor(tonumber(value) or 0)
                        if value <= 0 then return "Off" end
                        return tostring(value) .. " marks"
                    end,
                    apply = "trail",
                },
                {
                    key = "FootstepTrailSize", label = "Footstep trail size",
                    detail = "Size of each footstep mark, as a percentage of the base local icon size.",
                    values = { 25, 35, 50, 65, 80, 100, 125, 150, 175, 200 },
                    format = whole_percent, apply = "trail",
                },
                {
                    key = "LocalIconPlates", label = "Icon backing plates",
                    detail = "Draws the game's soft black disc behind the local markers (chests, enemies, and the rest) so pale art stays readable over pale map tiles.",
                    values = { false, true }, format = on_off, apply = "local-presentation",
                },
                header("Height markers"),
                {
                    key = "LocalHeightMarkers", label = "Height markers",
                    detail = "Marks local icons that are well above or below you with an arrow: pointing up for above, down for below.",
                    values = { false, true }, format = on_off, apply = "local-presentation",
                },
                {
                    key = "LocalHeightThresholdMeters", label = "Height threshold",
                    detail = "How far above or below you a marker has to be before it counts as on another level and gets the arrow.",
                    values = { 1, 2, 3, 4, 5, 6, 8, 10, 15, 20 },
                    format = function(value) return string.format("%g", tonumber(value) or 3) .. " m" end,
                    apply = "local-presentation",
                    hidden = function(Config) return Config.LocalHeightMarkers == false end,
                },
                {
                    key = "LocalHeightMarkerSize", label = "Arrow size",
                    detail = "Size of the arrow as a percentage of the icon it sits beside.",
                    values = { 40, 50, 60, 75, 90, 100, 125, 150 },
                    format = whole_percent, apply = "local-presentation",
                    hidden = function(Config) return Config.LocalHeightMarkers == false end,
                },
                {
                    key = "LocalHeightFade", label = "Height fade",
                    detail = "Fades an icon that is on another level -- arrow, icon and plate together -- so it is told apart from the ones on your level at a glance. It gets fainter the further away it is and never goes below the minimum.",
                    values = { false, true }, format = on_off, apply = "local-presentation",
                    hidden = function(Config) return Config.LocalHeightMarkers == false end,
                },
                {
                    key = "LocalHeightFadeStart", label = "Fade at threshold",
                    detail = "How visible an icon is the moment it crosses the height threshold. 100% starts the fade from fully visible.",
                    values = { 40, 50, 60, 70, 75, 80, 90, 100 },
                    format = whole_percent, apply = "local-presentation",
                    hidden = function(Config)
                        return advanced_hidden(Config) or Config.LocalHeightMarkers == false
                            or Config.LocalHeightFade == false
                    end,
                },
                {
                    key = "LocalHeightFadeMin", label = "Fade minimum",
                    detail = "The faintest an icon on another level ever gets, however far above or below you it is.",
                    values = { 10, 20, 25, 30, 35, 40, 50, 60, 75 },
                    format = whole_percent, apply = "local-presentation",
                    hidden = function(Config)
                        return advanced_hidden(Config) or Config.LocalHeightMarkers == false
                            or Config.LocalHeightFade == false
                    end,
                },
                {
                    key = "LocalHeightFadeRange", label = "Fade range",
                    detail = "How many metres past the threshold the fade takes to reach its minimum.",
                    values = { 5, 10, 15, 20, 30, 50 },
                    format = meters, apply = "local-presentation",
                    hidden = function(Config)
                        return advanced_hidden(Config) or Config.LocalHeightMarkers == false
                            or Config.LocalHeightFade == false
                    end,
                },
            },
        },
        {
            key = "ICONS", label = "ICONS",
            settings = {
                header("Map icons"),
                {
                    key = "ShowPOIs", label = "Map icons", detail = "Show revealed objectives using their exact game icon families and completion states.",
                    values = { false, true }, format = on_off, apply = "poi-presentation",
                },
                {
                    key = "EdgeVisibility", label = "Edge visibility", hidden = advanced_hidden,
                    detail = "How much of persistent off-map POI and user-pin artwork remains visible at the Square or Circle boundary. 50% is the accepted midpoint-on-edge behavior; 100% keeps the complete icon visible.",
                    values = EDGE_VISIBILITY_VALUES, format = whole_percent, apply = "edge-presentation",
                },
                header("Selected category"),
                {
                    key = "POISettingsCategory", label = "Icon category", detail = "Choose which icon family the controls below edit.",
                    values = category_values,
                    format = function(value)
                        local category = categories[math.floor(tonumber(value) or 1)]
                        return category and category.label or "Unknown"
                    end,
                },
                dynamic_setting(categories, "Visible", {
                    key = "SelectedPOIVisible", label = "Selected icons", detail = "Show or hide icons in the selected category.",
                    values = { false, true }, format = on_off, apply = "poi-presentation",
                }),
                discovery_setting(categories),
                dynamic_setting(categories, "IconSize", {
                    key = "SelectedPOIIconSize", label = "Selected icon size", detail = "Base pixel size for the selected category.",
                    values = ICON_SIZE_VALUES, format = pixels, apply = "poi-presentation",
                }),
                dynamic_setting(categories, "EdgeIndicators", {
                    key = "SelectedPOIEdgeIndicators", label = "Selected off-map icons", detail = "Keep this category on the minimap boundary while it is off-map and within range.",
                    values = { false, true }, format = on_off, apply = "poi-presentation",
                }),
                dynamic_setting(categories, "EdgeMaxDistance", {
                    hidden = advanced_hidden, key = "SelectedPOIEdgeMaxDistance", label = "Selected off-map range", detail = "Maximum persistent-edge distance for the selected category.",
                    values = EDGE_RANGE_VALUES, format = meters, apply = "poi-presentation",
                }),
                dynamic_setting(categories, "EdgeMinScale", {
                    hidden = advanced_hidden, key = "SelectedPOIEdgeMinScale", label = "Selected far size", detail = "Smallest size for this category at its maximum off-map distance.",
                    values = SCALE_VALUES, format = percent, apply = "poi-presentation",
                }),
                -- v0.18.0 (user decision 2026-09-14): the four user-pin rows were a tab of
                -- their own (PINS); they are icons on the map, so they live here now.
                header("User pins"),
                {
                    key = "TrackerIconSize", label = "User pin size", detail = "Base size of each user-created map pin on the minimap.",
                    values = ICON_SIZE_VALUES, format = pixels, apply = "tracker-presentation",
                },
                {
                    key = "ShowTrackerEdgeIndicators", label = "Off-map user pins", detail = "Keep distant user pins on the minimap boundary so their direction remains visible.",
                    values = { false, true }, format = on_off, apply = "tracker-presentation",
                },
                {
                    hidden = advanced_hidden, key = "TrackerEdgeMaxDistance", label = "Off-map pin range", detail = "Maximum distance for persistent user-pin edge indicators. Pins farther away are hidden.",
                    values = EDGE_RANGE_VALUES, format = meters, apply = "tracker-presentation",
                },
                {
                    hidden = advanced_hidden, key = "TrackerEdgeMinScale", label = "Far pin size", detail = "Smallest user-pin size at maximum distance. Pins grow to full size as they enter the visible map.",
                    values = SCALE_VALUES, format = percent, apply = "tracker-presentation",
                },
            },
        },
        {
            key = "LOCAL", label = "LOCAL",
            settings = {
                header("Local markers"),
                {
                    key = "ShowLocalInteractables", label = "Local interactables",
                    detail = "Show useful loaded-world interactables discovered from Mortal Shell II's own registration lifecycle. This does not use a recurring world scan.",
                    values = { false, true }, format = on_off, apply = "local-presentation",
                },
                {
                    key = "LocalInteractableIconSize", label = "Base icon size",
                    detail = "Size every local marker is measured from. Each category below multiplies this number by its own percentage, so this row moves the whole set together and the per-category rows move one kind at a time.",
                    values = ICON_SIZE_VALUES, format = pixels, apply = "local-presentation",
                },
                {
                    key = "LocalInteractableBudget", label = "Local icon budget", hidden = advanced_hidden,
                    detail = "Hard cap for reusable local-interactable marker images. Useful proven families are prioritized before overflow is dropped.",
                    values = { 8, 12, 16, 24, 32, 40, 48, 56, 64 },
                    format = function(value) return tostring(value) .. " icons" end,
                    apply = "local-presentation",
                },
                -- Everything from here down is scoped to the selected category. Keeping
                -- the selector as the last shared row is what makes that readable: a row
                -- above it is "all local icons", a row below it is "this kind only".
                header("Selected category"),
                {
                    key = "LocalSettingsCategory", label = "Local category",
                    detail = "Choose which kind of local marker the rows below this one edit. Every row underneath belongs to the category shown here and changes back when you change this row.",
                    values = local_category_values,
                    format = function(value)
                        local category = local_categories[math.floor(tonumber(value) or 1)]
                        return category and category.label or "Unknown"
                    end,
                },
                {
                    key = "SelectedLocalVisible",
                    label = function(Config)
                        local category = selected_local(Config)
                        return (category and tostring(category.label) or "Selected") .. ": show"
                    end,
                    detail = "Show or hide markers for the selected local category. Interactables also need the game to be letting you interact with them; hostiles do not.",
                    values = { false, true }, format = on_off, apply = "local-presentation",
                    read = function(Config)
                        local key = selected_local_key(Config)
                        return key ~= nil and Config[key] ~= false or false
                    end,
                    write = function(Config, value)
                        local key = selected_local_key(Config)
                        if key ~= nil then Config[key] = value == true end
                    end,
                    resolve_key = selected_local_key,
                    dynamic_suffix = "LocalShow",
                },
                local_dynamic_setting("LocalIconScale", {
                    key = "SelectedLocalIconScale",
                    label = function(Config)
                        local category = selected_local(Config)
                        return (category and tostring(category.label) or "Selected") .. ": size"
                    end,
                    detail = "Size of this category's markers as a percentage of the base icon size above. Traps start at 60%, enemies at 50% and bosses at 85%; everything else starts at 100%.",
                    values = LOCAL_SCALE_VALUES, format = percent, apply = "local-presentation",
                }),
                -- v0.17.0 (icon audit, user decision 2026-09-14): every category cycles
                -- through its own shortlist of icons, and an icon that takes a color gets
                -- a color row under it. Existing categories start on the icon they had.
                local_dynamic_setting("LocalIcon", {
                    key = "SelectedLocalIcon",
                    label = function(Config)
                        local category = selected_local(Config)
                        return (category and tostring(category.label) or "Selected") .. ": icon"
                    end,
                    detail = "Which of this category's icons to draw. The first entry is what the category has always worn; the others are the alternatives from the icon audit. White icons take the color chosen on the row below; bronze and painted ones keep their own color.",
                    values = function(Config) return icon_option_keys(selected_local(Config)) end,
                    format = function(value, Config) return icon_option_label(selected_local(Config), value) end,
                    apply = "local-presentation",
                    hidden = function(Config) return #icon_option_keys(selected_local(Config)) < 2 end,
                }),
                local_dynamic_setting("LocalIconColor", {
                    key = "SelectedLocalIconColor",
                    label = function(Config)
                        local category = selected_local(Config)
                        return (category and tostring(category.label) or "Selected") .. ": icon color"
                    end,
                    detail = "Color for this category's icon, from the shortlist that suits it. Only offered when the chosen icon is white artwork that a color can be laid over.",
                    values = function(Config)
                        local category = selected_local(Config)
                        return color_option_keys(category, category and Config["LocalIcon" .. tostring(category.key)] or nil)
                    end,
                    format = function(value) return color_label(value) end,
                    apply = "local-presentation",
                    hidden = function(Config)
                        local category = selected_local(Config)
                        return #color_option_keys(category, category and Config["LocalIcon" .. tostring(category.key)] or nil) == 0
                    end,
                }),
            },
        },
        -- v0.18.0 COMBAT (user decision 2026-09-14): what the minimap does while the
        -- game's own music state says you are fighting (Runtime/CombatState.lua). The
        -- three look rows preview live while they are selected.
        {
            key = "COMBAT", label = "COMBAT",
            settings = {
                {
                    key = "CombatHide", label = "Hide in combat",
                    detail = "Fade the minimap out completely while you are fighting and bring it back afterwards. Combat is what the game itself calls combat: the moment its music switches to the fight, including bosses. Enemies that have merely noticed you do not count.",
                    values = { false, true }, format = on_off, apply = "combat",
                },
                {
                    key = "CombatOpacity", label = "Combat opacity",
                    detail = "How visible the minimap is during a fight, as a fraction of its normal opacity. 100% leaves it alone. Selecting this row previews it.",
                    values = { 0.10, 0.20, 0.30, 0.40, 0.50, 0.60, 0.70, 0.80, 0.90, 1.00 },
                    format = percent, apply = "combat",
                    hidden = function(Config) return Config.CombatHide == true end,
                },
                {
                    key = "CombatSize", label = "Combat size",
                    detail = "How big the minimap is during a fight, as a fraction of its normal size. It shrinks in place, about its own centre, labels and frame with it. 100% leaves it alone. Selecting this row previews it.",
                    values = { 0.50, 0.60, 0.70, 0.75, 0.80, 0.90, 1.00 },
                    format = percent, apply = "combat",
                    hidden = function(Config) return Config.CombatHide == true end,
                },
                {
                    key = "CombatTransition", label = "Transition",
                    hidden = advanced_hidden,
                    detail = "How long the change between the normal look and the combat look takes, each way.",
                    values = { 0.0, 0.25, 0.5, 1.0 },
                    format = function(value)
                        value = tonumber(value) or 0
                        if value <= 0 then return "Instant" end
                        return (string.format("%.2f", value):gsub("%.?0+$", "")) .. " s"
                    end,
                    apply = "combat",
                },
                {
                    key = "CombatRestoreDelay", label = "Restore delay",
                    detail = "How long after the fight music ends the minimap keeps its combat look before returning to normal, so a lull in a fight does not flicker it.",
                    values = { 0, 1, 2, 3, 5, 8 },
                    format = function(value)
                        value = tonumber(value) or 0
                        if value <= 0 then return "None" end
                        return tostring(math.floor(value + 0.5)) .. " s"
                    end,
                    apply = "combat",
                },
            },
        },
        {
            key = "INPUT", label = "INPUT",
            settings = {
                header("Hotkeys"),
                {
                    key = "MenuKeybind", label = "Keyboard hotkey",
                    kind = "open_keybind", binding_kind = "keyboard",
                    detail = "Press Enter or click the value, release existing keys, then press the keyboard chord or repeated-key sequence you want. Release everything to save; Escape alone cancels.",
                    format = binding_label, apply = "hotkey-binding",
                },
                {
                    key = "ControllerMenuBind", label = "Controller hotkey",
                    kind = "controller_open_bind", binding_kind = "controller",
                    detail = "Press Enter, Cross/A, or click the value, release existing inputs, then press the controller chord or repeated-button sequence you want. Release everything to save; Circle/B alone cancels.",
                    format = binding_label, apply = "hotkey-binding",
                },
                {
                    key = "ModifierSidesEquivalent", label = "Modifier sides",
                    hidden = advanced_hidden,
                    detail = "When enabled, left and right Ctrl, Shift, and Alt are treated as equivalent while matching the keyboard hotkey.",
                    values = { false, true }, format = function(value)
                        return value and "Any side" or "Separate"
                    end, apply = "hotkey-binding",
                },
                header("Controller"),
                {
                    key = "ControllerSettings", label = "Controller settings",
                    kind = "action", controller_settings = true,
                    detail = "Opens the shared MortalShell2ModUI controller screen: stick deadzone, activation and release thresholds, a guided calibration and a live controller test. The profile it saves is shared by every mod on the framework.",
                    format = function() return "Open" end,
                },
            },
        },
        {
            key = "MOD", label = "MOD",
            settings = {
                header("Window"),
                {
                    key = "PauseGameWhileSettingsOpen", label = "Pause in settings", detail = "Pause the game while this settings window is open. Input remains blocked even when this is off.",
                    values = { false, true }, format = on_off, apply = "settings-pause",
                },
                header("Diagnostics"),
                {
                    hidden = advanced_hidden, key = "DebugLog", label = "Debug logging", detail = "Write additional minimap diagnostics to the UE4SS log.",
                    values = { false, true }, format = on_off,
                },
                {
                    key = "LogPerformance", label = "Log performance",
                    hidden = advanced_hidden,
                    detail = "Every 10 s, write [PERF] lines with CPU time and call counts for each minimap system to the UE4SS log. Also turns on the shared UI host's logging. Ctrl+Delete writes one immediately.",
                    values = { false, true }, format = on_off, apply = "perf",
                },
                header("Advanced"),
                {
                    key = "AdvancedSettings", label = "Advanced settings",
                    detail = "Show the CAPTURE tab, the budget, rate and LOD rows under this one, Edge visibility on ICONS and Local icon budget on LOCAL. Off hides them; their values stay as they are.",
                    values = { false, true }, format = on_off,
                },
                {
                    key = "POIMaxIcons", label = "Map-icon budget", hidden = advanced_hidden, detail = "Hard cap for reusable objective icons. Construction remains sliced to avoid hitches.",
                    values = { 16, 24, 32, 48, 64, 96, 128, 160, 192 },
                    format = function(value) return tostring(value) .. " icons" end, rebuild = true,
                },
                {
                    key = "MaxResidentTiles", label = "Tile budget", hidden = advanced_hidden, detail = "Maximum native map tiles retained by the minimap. Eight is the tested default.",
                    values = { 2, 3, 4, 6, 8, 10, 12, 16, 20, 24, 32 },
                    format = function(value) return tostring(value) .. " tiles" end, rebuild = true,
                },
                {
                    key = "LODBias", label = "LOD bias", hidden = advanced_hidden, detail = "Higher values prefer coarser map tiles. Zero is the tested sharp default.",
                    values = { 0, 1, 2, 3, 4, 5 }, format = function(value) return "+" .. tostring(value) end,
                    rebuild = true,
                },
                {
                    key = "PanUpdatesPerSecond", label = "Map update rate", hidden = advanced_hidden, detail = "How often native map tiles and pooled icons follow the player.",
                    values = { 5, 10, 12, 15, 20, 24, 30, 45, 60 }, format = function(value) return tostring(value) .. " Hz" end,
                },
                {
                    key = "ArrowUpdatesPerSecond", label = "Arrow update rate", hidden = advanced_hidden, detail = "How often the player-direction arrow updates.",
                    values = { 5, 10, 12, 15, 20, 24, 30, 45, 60 }, format = function(value) return tostring(value) .. " Hz" end,
                },
            },
        },
        -- v0.15.0: every parameter of the live dungeon capture, as rows, so the exposure
        -- question can be worked by turning knobs and watching the map. The defaults are
        -- the shipped capture. Each change rebuilds the capture (or just re-tints it) and
        -- writes a `capture=` description into the log, so a screenshot ties to a setting.
        {
            key = "CAPTURE", label = "CAPTURE", hidden = advanced_hidden,
            settings = {
                -- v0.15.1: map lighting first, because it is the fix. The rest is tuning.
                header("Lighting"),
                {
                    key = "DungeonCaptureRig", label = "Map lighting",
                    detail = "The answer to the white-out. Each zone rewrites the level's one lighting rig (sun, sky light, sky brightness, fog); up-facing ground under a bright profile is more than any capture can hold, so with this on the rig is set to the four values below for the instant the map is captured and restored before your own view draws. Measured: same zone, game lighting pure white in every pixel; map lighting readable, nothing clipped, no flicker on screen. Those are the LEVEL's components rather than the mod's, so the borrowed rig is dropped on any teardown and after 20 seconds and found again, which keeps a streamed-out zone from being written to.",
                    values = { false, true }, format = on_off, apply = "dungeon-capture",
                },
                {
                    key = "DungeonCaptureRigSun", label = "Map sun",
                    detail = "Directional light intensity (lux) while the map is captured. 0 means no sun in the map, which is how the readable zone had it; the game's bright profile uses 200.",
                    values = { 0, 1, 2, 5, 10, 20, 50, 100, 200 },
                    format = function(value) return tostring(value) .. " lux" end, apply = "dungeon-capture",
                },
                {
                    key = "DungeonCaptureRigSky", label = "Map sky light",
                    detail = "Sky light intensity while the map is captured. The readable zone had 1; the bright profile doubles it to 2.",
                    values = { 0, 0.25, 0.5, 0.75, 1, 1.5, 2, 3, 4 },
                    format = function(value) return tostring(value) end, apply = "dungeon-capture",
                },
                {
                    key = "DungeonCaptureRigSkyFactor", label = "Map sky brightness",
                    detail = "Sky atmosphere luminance factor while the map is captured. 1 is the readable zone; the bright profile sets 10.",
                    values = { 0.1, 0.25, 0.5, 1, 2, 3, 5, 10 },
                    format = function(value) return "x" .. tostring(value) end, apply = "dungeon-capture",
                },
                {
                    key = "DungeonCaptureRigFog", label = "Map fog",
                    detail = "Fog inscatter brightness while the map is captured, neutral grey. 0.4 is the readable zone; the bright profile is about 4 and blue. 0 removes the haze from the map entirely.",
                    values = { 0, 0.1, 0.2, 0.4, 0.7, 1, 2, 4 },
                    format = function(value) return tostring(value) end, apply = "dungeon-capture",
                },
                header("Capture"),
                {
                    key = "DungeonCaptureSource", label = "Source",
                    detail = "What the capture reads out of the renderer. Scene color + depth is the shipped one: lit HDR color with an opaque alpha. Final color HDR / LDR / tone curve run the post-process chain, which is the only place the exposure rows below take effect. Base color is immune to light but writes no alpha, so it draws nothing. Depth and normals are not pictures.",
                    values = { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 }, format = capture_source, apply = "dungeon-capture",
                },
                {
                    key = "DungeonCaptureFormat", label = "Target format",
                    detail = "The texture the capture renders into. RGBA8 sRGB is shipped and clips at white. RGBA16 float keeps the full range, so the tint below becomes a real exposure instead of a dimmer; it is what made the sunlit gate readable.",
                    values = { 2, 3, 6, 9, 10 }, format = capture_format, apply = "dungeon-capture",
                },
                {
                    key = "DungeonCaptureTint", label = "Exposure tint",
                    detail = "Multiplies the two brightness rows on the LOCAL tab. On a float target this is exposure: 15% brought a courtyard that was pure white into range. On an 8-bit target it only dims what already clipped.",
                    values = { 0.02, 0.03, 0.05, 0.07, 0.10, 0.15, 0.20, 0.30, 0.40, 0.50, 0.70, 1.00, 1.50, 2.00 },
                    format = whole_percent_of, apply = "dungeon-brightness",
                },
                {
                    key = "DungeonCaptureUnlit", label = "Unlit flag",
                    detail = "The engine's unlit view-mode flag on the capture. Measured to make no difference on the shipped source; kept here because it is a knob and the other sources are untested with it.",
                    values = { false, true }, format = on_off, apply = "dungeon-capture",
                },
                {
                    key = "DungeonViewPixels", label = "Resolution",
                    detail = "The capture's texture size. The probe measured 256 at 40 m; a wider map range spreads the same pixels over more ground, so raise this if the plan reads mushy. Cost rises with the square of this.",
                    values = { 64, 128, 192, 256, 384, 512, 768, 1024 }, format = pixels, apply = "dungeon-capture",
                },
                {
                    key = "DungeonCaptureLOD", label = "Detail distance",
                    detail = "Level-of-detail distance factor for the capture. Higher keeps finer meshes at range; 4 is shipped.",
                    values = { 0.5, 1, 2, 4, 8, 16 },
                    format = function(value) return "x" .. tostring(value) end, apply = "dungeon-capture",
                },
                header("Exposure"),
                {
                    key = "DungeonCapturePostProcess", label = "Own post process",
                    detail = "Let the capture run its own exposure, bloom and vignette settings (the rows below) instead of inheriting the game's. Measured to do nothing on the scene-color sources and to apply on the final-color ones.",
                    values = { false, true }, format = on_off, apply = "dungeon-capture",
                },
                {
                    key = "DungeonCaptureExposureMethod", label = "Exposure",
                    detail = "Histogram and Basic meter the capture and adapt, like a camera. Manual is a fixed setting from the bias below. Only with Own post process on, and only on a final-color source.",
                    values = { 0, 1, 2 }, format = exposure_method, apply = "dungeon-capture",
                },
                {
                    key = "DungeonCaptureExposureBias", label = "Exposure bias",
                    detail = "In stops. Each +1 doubles the brightness, each -1 halves it. With Manual this is the whole exposure; with Histogram or Basic it shifts the metered result.",
                    values = CAPTURE_BIAS_VALUES, format = stops, apply = "dungeon-capture",
                },
                {
                    key = "DungeonCaptureExposureMin", label = "Min brightness",
                    detail = "Lowest exposure the meter may adapt to, in EV100. The game's own range is -10 to 20. Raising this stops a dark crypt from being brightened past this point.",
                    values = CAPTURE_EV_VALUES, format = ev, apply = "dungeon-capture",
                },
                {
                    key = "DungeonCaptureExposureMax", label = "Max brightness",
                    detail = "Highest exposure the meter may adapt to, in EV100. Lowering this stops a sunlit courtyard from being dimmed past this point.",
                    values = CAPTURE_EV_VALUES, format = ev, apply = "dungeon-capture",
                },
                {
                    key = "DungeonCaptureExposureSpeed", label = "Adaptation speed",
                    detail = "Stops per second the meter may move. A one-shot capture only advances by one frame's worth per capture, so at 10 Hz the engine's usual 20 is about 2 real stops per second; 100 settles in about a second.",
                    values = { 0.5, 1, 2, 3, 5, 10, 20, 40, 100, 200, 500, 1000 },
                    format = function(value) return tostring(value) end, apply = "dungeon-capture",
                },
                {
                    key = "DungeonCapturePhysicalCamera", label = "Physical camera",
                    detail = "Apply the engine's physical-camera exposure (ISO, aperture, shutter) on top. Off is the sane default for a map.",
                    values = { false, true }, format = on_off, apply = "dungeon-capture",
                },
                {
                    key = "DungeonCaptureBloom", label = "Bloom",
                    detail = "Off overrides bloom to zero in the capture. On leaves the game's own bloom settings alone.",
                    values = { false, true }, format = on_off, apply = "dungeon-capture",
                },
                {
                    key = "DungeonCaptureVignette", label = "Vignette",
                    detail = "Off overrides the vignette to zero in the capture. On leaves the game's own setting alone.",
                    values = { false, true }, format = on_off, apply = "dungeon-capture",
                },
                {
                    key = "DungeonCapturePersist", label = "Keep adaptation history",
                    detail = "Keep the capture's rendering state between captures so a metered exposure remembers where it was. Needed for Histogram and Basic to settle; harmless otherwise.",
                    values = { false, true }, format = on_off, apply = "dungeon-capture",
                },
                header("Camera"),
                {
                    key = "DungeonViewHeightMeters", label = "Camera height",
                    detail = "How far above you the camera sits. Orthographic, so this changes neither the footprint nor the ceiling cut, only how much air it looks through -- measured to make no visible difference from 3 m to 60 m.",
                    values = { 3, 4, 6, 8, 10, 15, 20, 30, 45, 60, 90 }, format = meters, apply = "dungeon-capture",
                },
                {
                    key = "DungeonViewSliceMeters", label = "Ceiling cut",
                    detail = "Everything above you by more than this is cut away so the ceiling does not hide the floor. With the MAP tab's Ceiling cut on Auto this is the lowest the cut goes; on Fixed it is the cut.",
                    values = { 0.5, 1, 1.5, 2, 2.5, 3, 4, 5, 7, 10 }, format = meters, apply = "dungeon-capture",
                },
                {
                    key = "DungeonViewCeilingMaxMeters", label = "Auto cut ceiling",
                    detail = "The highest the automatic ceiling cut will go, in a hall with nothing above you. It can never exceed the camera height less half a metre.",
                    values = { 5, 8, 10, 15, 20, 25, 30, 40, 60 }, format = meters, apply = "dungeon-ceiling",
                },
            },
        },
    }

    local flat = {}
    for tab_index, tab in ipairs(tabs) do
        tab.settings[#tab.settings + 1] = {
            key = "ResetTab_" .. tostring(tab.key),
            label = "Reset this tab",
            kind = "action",
            reset_tab = true,
            detail = "Restore only this tab's settings to their defaults. Activate twice to confirm.",
            format = function() return "Reset" end,
        }
        for row_index, setting in ipairs(tab.settings) do
            if setting.kind == nil and setting.binding_kind == nil
                and type(setting.values) == "table" and #setting.values >= 4
                and tonumber(setting.values[1]) ~= nil then
                setting.control = "slider"
            end
            setting.tab_index = tab_index
            setting.row_index = row_index
            flat[#flat + 1] = setting
        end
    end
    return { Tabs = tabs, Settings = flat }
end

return Factory
