-- Pure class-name policy for event-driven local interactables. No UObject access.
-- v0.10.11: default-admit (anything the game lets you interact with), minus
-- world-map POI duplicates. Whether a record is shown right now is decided by
-- Local/Discovery.lua state (hidden / interactions disabled) and per-category
-- settings, not here.
-- v0.10.13: per-category artwork (user approved the shortlist 2026-09-11) and
-- two new categories, Merchant and Service. Every icon carries its native pixel
-- size so the pool can keep the icon's shape (aspect-fit, as ObjectivePool v0.9.7).

local Classifier = {}

local UI_ROOT = "/Game/Sparta/UI/"
-- Object path "<package>.<asset>" from a path relative to /Game/Sparta/UI/.
local function texture(relative)
    local name = string.match(relative, "([^/]+)$")
    return UI_ROOT .. relative .. "." .. name
end

-- Native texture sizes (FModel exports, 2026-09-11). Width, height in pixels.
local ICONS = {
    Tracker    = { path = texture("World/Map/Textures/T_UI_Icon_Map_Tracker_Color"), w = 512, h = 512 },
    Merchant   = { path = texture("World/Map/Textures/T_UI_MapIcon_Merchant"),      w = 128, h = 128 },
    NPC        = { path = texture("World/Map/Textures/T_UI_MapIcon_ShellRevive"),   w = 128, h = 128 },
    Service    = { path = texture("Common/Textures/T_UI_Icon_MeleeSkill"),          w = 512, h = 512 },
    ShellGhost = { path = texture("Icons/Items/Glimpses/T_UI_MethersBreath"),       w = 512, h = 512 },
    Chest      = { path = texture("Common/Textures/T_UI_Upgrade_Level_Fill"),       w = 32,  h = 32 },
    Pickup     = { path = texture("Common/Textures/T_UI_LockOnDot"),                w = 68,  h = 68 },
    Lore       = { path = texture("Common/Textures/T_UI_Shape_Diamond_Glow"),       w = 256, h = 256 },
    Movement   = { path = texture("Common/Textures/T_UI_icon_traversal_Arrow"),     w = 24,  h = 60 },
    Other      = { path = texture("Common/Textures/T_UI_ExclamationMark_Occult"),   w = 256, h = 256 },
    -- Per-type specials inside a category.
    GloomSiphon = { path = texture("Icons/Items/T_Gloom_Temp"),                     w = 512, h = 512 },
    Thestus     = { path = texture("Common/Textures/T_UI_NightMode_Activated"),     w = 88,  h = 88 },
    Shootable   = { path = texture("Common/Textures/T_UI_EnvShooting_Icon"),        w = 256, h = 256 },
    -- v0.11.0 (user picks, 2026-09-12)
    Trap        = { path = texture("Common/Textures/T_UI_StatusEffect_Cursed"),      w = 45,  h = 47 },
    Enemy       = { path = texture("Common/Textures/T_UI_Dot"),                      w = 128, h = 128 },
    Boss        = { path = texture("World/Map/Textures/T_UI_MapIcon_Skull"),         w = 256, h = 256 },
    -- v0.16.1 hidden walls (BP_HiddenWall_C and the Chaos rubble walls): the white
    -- cross, user pick 2026-09-13 (white "will go well with the black fog behind it";
    -- T_UI_Warning_ExclamationMark, 50x48, was the runner-up). v0.16.0 borrowed the
    -- world map's locked-traversal gate and she found it strange for a wall. Size from
    -- her paste of the texture (512x512). An opened wall has no icon at all.
    Secret      = { path = texture("Common/Textures/T_UI_Cross_Simple"),               w = 512, h = 512 },
    -- v0.16.12 explosive barrels: the burn status-effect flame, her pick 2026-09-14
    -- (same bronze family as the trap's Cursed). T_UI_StatusEffect_Havoc, the spiked
    -- burst, is the runner-up if a flame reads as "fire" rather than "will explode".
    Barrel      = { path = texture("Common/Textures/T_UI_StatusEffect_Burn"),           w = 47,  h = 48 },
    -- Decoration, not category art: the height chevron and the icon backing plate.
    Chevron     = { path = texture("Common/Textures/T_UI_InteractIndicator"),        w = 32,  h = 32 },
    Plate       = { path = texture("Common/Textures/T_UI_Icon_Shell_BG_Black"),      w = 492, h = 444 },
    Footstep    = { path = texture("Common/Textures/T_UI_LevelUp_Notify_BG"),        w = 1024, h = 1024 },
    -- v0.17.0 (icon audit, 2026-09-14): the alternatives every category can cycle
    -- through on the LOCAL tab. Sizes from the FModel export. "Flat" art is white and
    -- takes a color; the bronze status glyphs and the painted item icons do not.
    Warning     = { path = texture("Common/Textures/T_UI_Warning_ExclamationMark"),    w = 512, h = 512 },
    Perforation = { path = texture("Common/Textures/T_UI_StatusEffect_Perforation"),   w = 50,  h = 49 },
    Havoc       = { path = texture("Common/Textures/T_UI_StatusEffect_Havoc"),         w = 51,  h = 49 },
    Page        = { path = texture("Icons/Items/T_UI_Icon_VratkoSketch_02"),           w = 512, h = 512 },
    RukMap      = { path = texture("Icons/Items/T_UI_Icon_RukMap"),                    w = 230, h = 230 },
    Scroll      = { path = texture("Icons/Items/T_UI_Icon_MapPiece"),                  w = 512, h = 512 },
    Diamond     = { path = texture("Common/Textures/T_UI_Shape_Diamond_Fill"),         w = 256, h = 256 },
    Crate       = { path = texture("Common/Textures/T_UI_Smelt_TarforgeUnlock_FoundryStone"), w = 1024, h = 1024 },
    Helmet      = { path = texture("World/Map/Textures/T_UI_Icon_Map_Shells"),         w = 512, h = 512 },
    DarkForm    = { path = texture("Icons/DarkForms/T_UI_Icon_DarkForm_Default"),      w = 512, h = 512 },
    Reverie     = { path = texture("Icons/Items/T_UI_Glimpse_Reverie"),                w = 512, h = 512 },
    Disc        = { path = texture("Common/Textures/T_UI_Circle_01"),                  w = 512, h = 512 },
    Ring        = { path = texture("Common/Textures/T_UI_Circle_Border"),              w = 128, h = 128 },
    Padlock     = { path = texture("Menu/Progression/Textures/T_UI_Skill_Lock"),       w = 86,  h = 86 },
    Gate        = { path = texture("World/Map/Textures/T_UI_Icon_Map_Gate_Locked"),    w = 175, h = 209 },
    Arch        = { path = texture("World/Map/Textures/T_UI_Icon_Map_Dungeon_Uncompleted"), w = 512, h = 512 },
    GloomFlat   = { path = texture("World/Map/Textures/T_UI_MapActor_GloomLost"),      w = 80,  h = 130 },
    Face        = { path = texture("Common/Textures/T_UI_Icon_ShellSkill"),            w = 512, h = 512 },
    Candle      = { path = texture("Icons/Items/T_UI_ThestusFlame"),                   w = 512, h = 512 },
    Cog         = { path = texture("Common/Textures/T_UI_Icon_Cog"),                   w = 230, h = 230 },
    ChevronArrow = { path = texture("Common/Textures/T_UI_ArrowSimple_2"),             w = 128, h = 128 },
    SqueezeArrow = { path = texture("Common/Textures/T_UI_SqueezeArrow"),              w = 34,  h = 53 },
    HoldChevron = { path = texture("Common/Textures/T_UI_Hold_Indicator"),             w = 38,  h = 18 },
    Crosshair   = { path = texture("World/Map/Textures/T_UI_Icon_Map_Crosshair"),      w = 512, h = 512 },
}
local ICON_ORDER = { "Tracker", "Merchant", "NPC", "Service", "ShellGhost", "Chest", "Pickup",
    "Lore", "Movement", "Other", "GloomSiphon", "Thestus", "Shootable",
    "Trap", "Enemy", "Boss", "Secret", "Barrel", "Chevron", "Plate", "Footstep",
    "Warning", "Perforation", "Havoc", "Page", "RukMap", "Scroll", "Diamond", "Crate",
    "Helmet", "DarkForm", "Reverie", "Disc", "Ring", "Padlock", "Gate", "Arch", "GloomFlat",
    "Face", "Candle", "Cog", "ChevronArrow", "SqueezeArrow", "HoldChevron", "Crosshair" }

-- The pin marker. Local categories no longer use it; it is the last-resort
-- fallback when a category texture cannot be found or loaded.
Classifier.GenericIconPath = ICONS.Tracker.path
Classifier.MerchantIconPath = ICONS.Merchant.path
Classifier.NPCIconPath = ICONS.NPC.path
-- Decoration paths, resolved by the pool alongside the category art.
Classifier.ChevronIconPath = ICONS.Chevron.path
Classifier.PlateIconPath = ICONS.Plate.path
Classifier.FootstepIconPath = ICONS.Footstep.path
Classifier.SecretIconPath = ICONS.Secret.path

local SIZE_BY_PATH = {}
for _, icon in pairs(ICONS) do SIZE_BY_PATH[icon.path] = { icon.w, icon.h } end

local function contains(value, needle)
    return string.find(tostring(value or ""), needle, 1, true) ~= nil
end

-- Shops. BP_ShopHandler_* are shop counters (the Tavern one owns a
-- "Shop Interaction Handler"); Discovery also passes a "merchant" hint when the
-- captured handler component's name contains "Shop" (BP_Merchant_C's is
-- BPC_Interaction_Shop), which catches shop NPCs with generic class names.
local function merchant_like(class_name)
    return contains(class_name, "BP_Merchant")
        or contains(class_name, "NightMerchant")
        or contains(class_name, "Shopkeeper")
        or contains(class_name, "ShopHandler")
        or contains(class_name, "Barkeep")
end

-- Upgrade stations.
local function service_like(class_name)
    return contains(class_name, "BP_Blacksmith")
        or contains(class_name, "BP_Tarforge")
end

-- Case-insensitive, because the game is not consistent: the hub cultists ship as both
-- BP_Cultist_HUB_PillowCultist_C and BP_Cultist_Hub_Pillowcultist_Minion_C, and the
-- exact-match version of this test let the second one through as an enemy (v0.12.0 run,
-- red dots behind the hub NPC icons).
local function icontains(value, needle)
    return string.find(string.lower(tostring(value or "")),
        string.lower(tostring(needle)), 1, true) ~= nil
end

local function npc_like(class_name)
    return contains(class_name, "BP_NPC_")
        or icontains(class_name, "BP_Cultist_HUB")
        or icontains(class_name, "ShellKeeper")
        or contains(class_name, "BP_NPC_Vlas")
end

-- v0.12.1. BP_AICharacter_C is the base class of the friendly cast as well as the
-- hostile one: her 2026-09-12 hub capture admitted BP_NPC_FrogChild_C,
-- BP_NPC_Vlas_Hub_C, BP_NPC_Shopkeeper_Dog_C and both hub pillow cultists as enemies,
-- which is the red dots she saw sitting behind the NPC icons. The enemy layer asks this
-- before admitting anything, so one list decides friend or foe for every layer.
function Classifier.IsFriendly(class_name)
    class_name = tostring(class_name or "")
    if class_name == "" then return false end
    return npc_like(class_name) or merchant_like(class_name) or service_like(class_name)
        or icontains(class_name, "Thestus")
end

-- v0.10.11 policy (user decision 2026-09-11): "if I can interact with it, show it
-- unless I say otherwise." Every interaction owner is admitted. The only exclusions
-- are families the world-map POI layer already draws, so they would stack a second
-- icon on the same spot.
local function map_duplicate(class_name)
    return contains(class_name, "LandingArea")      -- Landing Area POI
        or contains(class_name, "BP_STH_")           -- dungeon entrances (Dungeon POI)
        or contains(class_name, "TarRootGate")       -- gate POI
        or contains(class_name, "DeathSpoils")       -- Spoils POI
        or contains(class_name, "EvilStatue")        -- Evil Statue POI
        or contains(class_name, "ShatteredBeacon")   -- owns BPC_WorldMapObjective (beacon POI)
        or contains(class_name, "BP_Ruk_C")          -- Ruk at map stations (MapStation POI); judgment call
        -- v0.16.6: BP_BagTeleport_C was parked here "until seen". Seen (her 19:36
        -- snapshot, 1.2 m, "E: TOUCH", no world-map POI of its own): the sack on the
        -- ledge that teleports you to the prison. An ordinary interaction owner now,
        -- admitted as Other -- the occult "!" fits a thing you touch without knowing.
end

local function movement_like(class_name)
    return contains(class_name, "Interaction_Traversal")
        or contains(class_name, "TraversalDestination")
        or contains(class_name, "HubLift")
        or contains(class_name, "LiftCall")
        or contains(class_name, "Interactable_Ability_Sit")
end

-- v0.16.0. The two wall families from the 2026-09-12 object dump: BP_HiddenWall_C
-- (illusory wall: static-mesh pieces, a WallCollision mesh, a ProximityTrigger, a
-- saved bool, a fade timeline; SpartaApplyHit -> ShouldReveal -> FadeMaterialOpacity +
-- DisableCollision) with its Natural_Rock / CannonBall / Spikes variants, and the
-- Chaos rubble BP_DestructiblePlaceholderWall_C (a geometry collection with
-- SpartaApplyHit and Manual/PercentageSpawnItem). BP_InteractionOpenHiddenWall_C is
-- deliberately NOT a wall: it is the pressure-plate interaction that opens one, an
-- ordinary BP_Interaction the handler path already admits.
function Classifier.IsHiddenWall(class_name)
    class_name = tostring(class_name or "")
    if contains(class_name, "InteractionOpenHiddenWall") then return false end
    return contains(class_name, "BP_HiddenWall")
        or contains(class_name, "DestructiblePlaceholderWall")
end

local CATEGORIES = {
    { key = "Lore", label = "Lore / notes", priority = 10 },
    { key = "Chest", label = "Chests", priority = 20 },
    { key = "ShellGhost", label = "Shell ghosts", priority = 25 },
    { key = "Pickup", label = "Pickups", priority = 30 },
    { key = "Other", label = "Other interactables", priority = 35 },
    { key = "NPC", label = "NPCs", priority = 40 },
    { key = "Merchant", label = "Merchants / shops", priority = 36 },
    { key = "Service", label = "Blacksmith / Tarforge", priority = 37 },
    { key = "Movement", label = "Movement spots", priority = 45 },
    -- v0.11.0: bear traps get their own toggle because they are a hazard, not a
    -- convenience. Enemies and bosses come from Local/Discovery's enemy hooks and
    -- outrank everything else: a marker you need right now beats a chest.
    { key = "Trap", label = "Traps", priority = 15 },
    { key = "Boss", label = "Bosses", priority = 4 },
    { key = "Enemy", label = "Enemies", priority = 5 },
    -- v0.16.0 (user decision 2026-09-13: "show unopened walls in range"). Hidden and
    -- breakable walls are not interactables -- no handler, no lock-on component, no
    -- BP_Interaction actor -- so they come from their own seed and hooks in
    -- Local/Discovery, always with the "secret" hint. Between traps and chests: a
    -- passage you did not know about is worth more than loot you can see.
    { key = "Secret", label = "Hidden walls", priority = 18 },
    -- v0.16.9 (user: "an option to hide just the explosive barrels from the minimap,
    -- they can be overwhelming with how many there are sometimes"). Barrels were
    -- Pickups wearing the shootable icon, so the only way to lose them was to lose
    -- every pickup. Their own category: own toggle, own size, same icon; below the
    -- pickups they used to share a switch with.
    { key = "Barrel", label = "Explosive barrels", priority = 33 },
    -- v0.17.0 (icon audit, user decision 2026-09-14): the things that shared a switch
    -- with something unlike them get their own. Loot plants and caged heads out of
    -- Pickups (39 sightings under the pickup toggle); sit spots out of Movement (28,
    -- the most-seen movement item, and flavour rather than traversal); map fragments
    -- and locked doors out of Other; the gloom siphon and Thestus stop being icon
    -- overrides inside Other / NPCs so each can be shown, sized and drawn on its own.
    { key = "Loot", label = "Hit-for-loot plants / cages", priority = 31 },
    { key = "Rest", label = "Rest / sit spots", priority = 46 },
    { key = "MapFragment", label = "Map fragments", priority = 12 },
    { key = "LockedDoor", label = "Locked doors", priority = 34 },
    { key = "GloomSiphon", label = "Gloom siphons", priority = 32 },
    { key = "Thestus", label = "Thestus (day / night)", priority = 38 },
}
local CATEGORY_BY_KEY = {}
for _, c in ipairs(CATEGORIES) do CATEGORY_BY_KEY[c.key] = c end

-- Named colors, multiplied over the texture by the pool (multiply only darkens, so
-- a color needs white art under it). The enemy and boss reds are the v0.11.0 values.
local TINT = {
    white   = { R = 1.00, G = 1.00, B = 1.00, A = 1.0 },
    red     = { R = 0.85, G = 0.18, B = 0.14, A = 1.0 },
    enemyred = { R = 0.78, G = 0.10, B = 0.08, A = 1.0 },
    bossred = { R = 0.92, G = 0.26, B = 0.20, A = 1.0 },
    orange  = { R = 1.00, G = 0.55, B = 0.15, A = 1.0 },
    yellow  = { R = 0.95, G = 0.85, B = 0.30, A = 1.0 },
    green   = { R = 0.40, G = 0.80, B = 0.45, A = 1.0 },
    blue    = { R = 0.35, G = 0.60, B = 0.95, A = 1.0 },
    ghost   = { R = 0.70, G = 0.85, B = 1.00, A = 1.0 },
    purple  = { R = 0.75, G = 0.45, B = 0.95, A = 1.0 },
    teal    = { R = 0.35, G = 0.85, B = 0.80, A = 1.0 },
    gold    = { R = 0.85, G = 0.72, B = 0.40, A = 1.0 },
}
local TINT_LABEL = {
    white = "White", red = "Red", enemyred = "Red", bossred = "Red", orange = "Orange",
    yellow = "Yellow", green = "Green", blue = "Blue", ghost = "Ghost blue",
    purple = "Purple", teal = "Teal", gold = "Gold",
}

-- v0.17.0 (icon audit, user decisions 2026-09-14). Per category, the icons the LOCAL
-- tab's "Icon" row cycles through, first entry the default. "keep it on their current
-- if available, that way I can still understand what I'm looking at" -- so every
-- category that existed keeps the icon it had as the default, and only the new
-- categories start on the audit's pick. `tints` lists the colors the "Icon color"
-- row offers for that icon (first is the default); an icon without `tints` is bronze
-- or painted art that a multiply cannot color, and the color row hides for it.
local ICON_OPTIONS = {
    Boss = {
        { key = "skull", label = "Skull", icon = "Boss", tints = { "bossred", "orange", "purple", "white" } },
    },
    Enemy = {
        { key = "dot", label = "Dot", icon = "Enemy", tints = { "enemyred", "orange", "yellow", "white" } },
    },
    Trap = {
        { key = "cursed", label = "Cursed star", icon = "Trap" },
        { key = "warning", label = "Warning mark", icon = "Warning", tints = { "red", "orange", "yellow", "white" } },
        { key = "teeth", label = "Jagged teeth", icon = "Perforation" },
        { key = "spikes", label = "Spiked burst", icon = "Havoc" },
    },
    Secret = {
        { key = "cross", label = "Cross", icon = "Secret", tints = { "white", "gold", "blue", "green" } },
        { key = "gate", label = "Gate", icon = "Gate" },
        { key = "arch", label = "Archway", icon = "Arch" },
        { key = "padlock", label = "Padlock", icon = "Padlock" },
    },
    Lore = {
        { key = "scroll", label = "Scroll", icon = "Scroll" },
        { key = "diamond", label = "Glowing diamond", icon = "Lore" },
        { key = "page", label = "Parchment page", icon = "Page" },
        { key = "rukmap", label = "Folded map", icon = "RukMap" },
    },
    MapFragment = {
        { key = "rukmap", label = "Folded map", icon = "RukMap" },
        { key = "scroll", label = "Scroll", icon = "Scroll" },
        { key = "occult", label = "Occult mark", icon = "Other", tints = { "white", "gold", "blue" } },
    },
    Chest = {
        { key = "gem", label = "Gem", icon = "Chest" },
        { key = "diamond", label = "White diamond", icon = "Diamond", tints = { "white", "gold", "blue", "green" } },
        { key = "crate", label = "Crate", icon = "Crate" },
    },
    ShellGhost = {
        { key = "wisp", label = "Methers' Breath", icon = "ShellGhost" },
        { key = "helmet", label = "Shell helmet", icon = "Helmet", tints = { "ghost", "white", "purple", "green" } },
        { key = "head", label = "Dark form", icon = "DarkForm" },
        { key = "reverie", label = "Reverie wisp", icon = "Reverie" },
    },
    Pickup = {
        { key = "dot", label = "Soft dot", icon = "Pickup", tints = { "white", "yellow", "green", "blue" } },
        { key = "disc", label = "Hard disc", icon = "Disc", tints = { "white", "yellow", "green", "blue" } },
        { key = "ring", label = "Ring", icon = "Ring", tints = { "white", "yellow", "green", "blue" } },
        { key = "diamond", label = "White diamond", icon = "Diamond", tints = { "white", "yellow", "green", "blue" } },
    },
    Loot = {
        { key = "target", label = "Shooting target", icon = "Shootable", tints = { "green", "white", "yellow", "blue" } },
        { key = "dot", label = "Soft dot", icon = "Pickup", tints = { "white", "green", "yellow", "blue" } },
    },
    Barrel = {
        { key = "burn", label = "Burn flame", icon = "Barrel" },
        { key = "target", label = "Shooting target", icon = "Shootable", tints = { "orange", "red", "yellow", "white" } },
        { key = "warning", label = "Warning mark", icon = "Warning", tints = { "orange", "red", "yellow", "white" } },
        { key = "spikes", label = "Spiked burst", icon = "Havoc" },
    },
    Other = {
        { key = "occult", label = "Occult mark", icon = "Other", tints = { "white", "gold", "blue", "green" } },
        { key = "warning", label = "Warning mark", icon = "Warning", tints = { "white", "gold", "blue", "green" } },
    },
    GloomSiphon = {
        { key = "wisp", label = "Gloom wisp", icon = "GloomSiphon" },
        { key = "flat", label = "Flat wisp", icon = "GloomFlat", tints = { "teal", "white", "purple", "green" } },
    },
    LockedDoor = {
        { key = "padlock", label = "Padlock", icon = "Padlock" },
        { key = "gate", label = "Gate", icon = "Gate" },
        { key = "occult", label = "Occult mark", icon = "Other", tints = { "white", "gold", "blue" } },
    },
    Merchant = {
        { key = "bag", label = "Merchant bag", icon = "Merchant", tints = { "white", "gold", "green" } },
    },
    Service = {
        { key = "sword", label = "Sword", icon = "Service", tints = { "white", "gold", "blue" } },
        { key = "cog", label = "Cog", icon = "Cog" },
    },
    NPC = {
        { key = "figure", label = "Figure", icon = "NPC", tints = { "white", "gold", "green", "blue" } },
        { key = "face", label = "Face glyph", icon = "Face", tints = { "white", "gold", "green", "blue" } },
    },
    Thestus = {
        { key = "candle", label = "Candle", icon = "Candle" },
        { key = "crescent", label = "Crescent", icon = "Thestus" },
    },
    Movement = {
        { key = "arrow", label = "Traversal arrow", icon = "Movement", tints = { "white", "gold", "green", "blue" } },
        { key = "chevron", label = "Chevron arrow", icon = "ChevronArrow", tints = { "white", "gold", "green", "blue" } },
        { key = "squeeze", label = "Squeeze arrow", icon = "SqueezeArrow", tints = { "white", "gold", "green", "blue" } },
    },
    Rest = {
        { key = "chevron", label = "Down chevron", icon = "HoldChevron", tints = { "blue", "white", "gold", "green" } },
        { key = "ring", label = "Ring", icon = "Ring", tints = { "white", "gold", "green", "blue" } },
        { key = "crosshair", label = "Crosshair ring", icon = "Crosshair" },
    },
}

local function options_for(key)
    return ICON_OPTIONS[tostring(key or "")] or {}
end

local function option_for(key, choice)
    local list = options_for(key)
    choice = tostring(choice or ""):lower()
    for _, option in ipairs(list) do
        if option.key == choice then return option end
    end
    return list[1]
end

-- "white" is no tint at all (nil), so a record stays primitives-only and the pool
-- writes its plain white; every other name is a color table.
local function tint_for(option, color)
    if option == nil or type(option.tints) ~= "table" then return nil end
    color = tostring(color or ""):lower()
    local chosen = option.tints[1]
    for _, key in ipairs(option.tints) do
        if key == color then chosen = key end
    end
    if chosen == "white" then return nil end
    return TINT[chosen]
end

-- The art a category draws with, given the user's two LOCAL-tab choices. Unknown
-- choices resolve to the category's default, so a stale ini never blanks a marker.
-- Returns texture_path, tint (nil = white), option key, color key.
function Classifier.ResolveArt(key, icon_choice, color_choice)
    local option = option_for(key, icon_choice)
    if option == nil then return nil end
    local icon = ICONS[option.icon] or ICONS.Tracker
    local tint = tint_for(option, color_choice)
    local color = nil
    if type(option.tints) == "table" then
        color = tostring(color_choice or ""):lower()
        local known = false
        for _, k in ipairs(option.tints) do if k == color then known = true end end
        if not known then color = option.tints[1] end
    end
    return icon.path, tint, option.key, color
end

-- Ordered { key, label } icon choices for the LOCAL "Icon" row.
function Classifier.IconOptions(key)
    local out = {}
    for i, option in ipairs(options_for(key)) do out[i] = { key = option.key, label = option.label } end
    return out
end

-- Ordered { key, label } color choices for the LOCAL "Icon color" row, empty when
-- the chosen icon takes no color.
function Classifier.ColorOptions(key, icon_choice)
    local option = option_for(key, icon_choice)
    local out = {}
    if option == nil or type(option.tints) ~= "table" then return out end
    for i, tint_key in ipairs(option.tints) do
        out[i] = { key = tint_key, label = TINT_LABEL[tint_key] or tint_key }
    end
    return out
end

function Classifier.TintLabel(color)
    return TINT_LABEL[tostring(color or ""):lower()] or tostring(color or "")
end

-- Category policy for a record: label, priority, and the category's DEFAULT art (what
-- the pool draws until the LOCAL tab says otherwise; the pool resolves the live
-- choice itself through ResolveArt). icon_key is no longer used by any rule -- the
-- former per-type overrides are categories now -- but stays accepted.
local function policy(key, icon_key)
    local c = CATEGORY_BY_KEY[key]
    local path, tint = Classifier.ResolveArt(key)
    if icon_key ~= nil and ICONS[icon_key] ~= nil then path = ICONS[icon_key].path end
    return { key = key, label = c.label, priority = c.priority, dynamic = false,
        texture_path = path or ICONS.Tracker.path, tint = tint }
end

-- source_hint:
--   "npc"      the record came from BP_NPC_C:ReceiveBeginPlay, so the owner is an
--              NPC regardless of its class name (e.g. BP_Depraved_Friendly_C).
--   "merchant" the captured interaction handler is a shop handler (its name
--              contains "Shop"). Outranks "npc".
function Classifier.Classify(class_name, source_hint)
    class_name = tostring(class_name or "")
    if class_name == "" then return nil, "class-unavailable" end

    -- Actor-based lore/read-text interactions.
    if contains(class_name, "InteractionReadText") then return policy("Lore") end
    -- Zhirelle's "Locate Shell" ghosts (v0.10.9, user decision).
    if contains(class_name, "Interactable_Shell_Locked") then return policy("ShellGhost") end
    if map_duplicate(class_name) then return nil, "map-duplicate" end
    -- v0.11.0: enemies arrive from the AI hooks with an explicit hint, never by name.
    if source_hint == "boss" then return policy("Boss") end
    if source_hint == "enemy" then return policy("Enemy") end
    -- v0.11.2: bear traps and the rest of the shootable environment props arrive from
    -- their own hooks, with a hint, because they are not interaction owners at all --
    -- BP_BearTrap_C carries a lock-on/env-shooting component and a sphere trigger and
    -- never touches BPC_InteractionHandler, which is why v0.11.0 and v0.11.1 saw none
    -- of them. Name matching stays as a second line for anything else trap-shaped.
    if source_hint == "trap" then return policy("Trap") end
    if contains(class_name, "BearTrap") or contains(class_name, "Bear_Trap") then
        return policy("Trap")
    end
    -- v0.16.0: hidden walls arrive from the wall seed and the wall hooks with their
    -- own hint; the name match is the second line, as for traps. An opened wall is
    -- retired by Discovery, so there is no second icon to choose here.
    if source_hint == "secret" or Classifier.IsHiddenWall(class_name) then
        return policy("Secret")
    end
    -- v0.16.9: an explosive barrel is its own category whatever hint it arrived with
    -- (the env-shooting hook says "barrel"; a re-seed may still say "shootable").
    if source_hint == "barrel" or contains(class_name, "ExplosiveBarrel") then
        return policy("Barrel")
    end
    -- v0.17.0: the rest of the env-shooting family -- attack flowers, flower chests,
    -- caged heads: things you hit for a crafting item -- is "Loot", with its own switch.
    if source_hint == "shootable" then return policy("Loot") end
    -- v0.16.4: the flower chest is a plant you hit for a crafting item, not a chest;
    -- named here so the "Chest" rule below can never claim it.
    if contains(class_name, "FlowerChest") then return policy("Loot") end
    -- v0.17.0: map fragments (BP_InteractionMapFragment: TakeMap, CacheMapItem) and
    -- locked doors (BP_Interactable_Lock_Door) out of Other, and the Gragu claim-shell
    -- interaction in with the shell ghosts, where a shell you can take belongs.
    if contains(class_name, "InteractionMapFragment") then return policy("MapFragment") end
    if contains(class_name, "Interactable_Lock_Door") then return policy("LockedDoor") end
    if contains(class_name, "ClaimShell") then return policy("ShellGhost") end
    if source_hint == "merchant" or merchant_like(class_name) then return policy("Merchant") end
    if service_like(class_name) then return policy("Service") end
    -- v0.10.10: Thestus (the day/night lantern keeper at rest sites) is an
    -- interaction actor, not an AI character; user reported him missing. v0.17.0: his
    -- own category, so his icon and switch are his own.
    if contains(class_name, "BP_DayNight_Interaction_Thestus") then return policy("Thestus") end
    if source_hint == "npc" then return policy("NPC") end
    if contains(class_name, "Chest") then return policy("Chest") end
    if contains(class_name, "Shootable") then return policy("Loot") end
    if contains(class_name, "Pickup") or contains(class_name, "PickUp")
        or contains(class_name, "Artifact") or contains(class_name, "Currency") then
        return policy("Pickup")
    end
    if npc_like(class_name) then return policy("NPC") end
    -- v0.17.0: sit spots (BP_Interactable_Ability_Sit: a motion-warp onto a bench)
    -- are flavour, not a way through; own category, own switch, before the traversal
    -- rule that used to take them.
    if contains(class_name, "Interactable_Ability_Sit") then return policy("Rest") end
    if movement_like(class_name) then return policy("Movement") end
    if contains(class_name, "GloomSiphon") then return policy("GloomSiphon") end
    return policy("Other")
end

-- Hint precedence for re-classifying an existing record (Discovery.upsert).
function Classifier.HintRank(source_hint)
    -- Enemy hints are their own family: an AI-sourced record must never be
    -- re-labelled by a later interaction-handler capture, or vice versa.
    if source_hint == "boss" then return 4 end
    if source_hint == "enemy" then return 3 end
    if source_hint == "trap" then return 3 end
    if source_hint == "secret" then return 3 end
    if source_hint == "merchant" then return 2 end
    if source_hint == "npc" then return 1 end
    if source_hint == "shootable" then return 1 end
    if source_hint == "barrel" then return 1 end
    return 0
end

-- Per-category size multiplier, applied by the pool on top of the shared icon size.
-- The user asked for smaller bear traps (2026-09-12) and found that the icon-size
-- setting is global, which it is: it is one number for the whole local pool. This is
-- the per-icon dimension that was missing. `LocalIconScale<Category>` in the ini
-- overrides any of these without a rebuild.
-- v0.18.3: the sizes actually played on, adopted from the author's own config so a
-- fresh install opens on the tuned set rather than a flat 1.0.
local CATEGORY_SCALE = {
    Trap = 0.60,
    Enemy = 0.50,
    Boss = 0.85,
    Rest = 0.90,
    Secret = 1.10,
    Thestus = 1.50,
    -- The map fragment is small, rare and easy to miss, so it draws large.
    MapFragment = 2.00,
}

function Classifier.CategoryScale(key)
    return CATEGORY_SCALE[tostring(key or "")] or 1.0
end

-- Decoration sizes for the pool (chevron, plate, footstep).
function Classifier.Decoration(key)
    local icon = ICONS[key]
    if icon == nil then return nil end
    return icon.path, icon.w, icon.h
end

-- Native width, height of a texture path (1, 1 when unknown: square).
function Classifier.IconSize(path)
    local size = SIZE_BY_PATH[path]
    if size == nil then return 1, 1 end
    return size[1], size[2]
end

-- Every texture the pool must resolve; the generic fallback first.
function Classifier.Paths()
    local out = {}
    for i, key in ipairs(ICON_ORDER) do out[i] = ICONS[key].path end
    return out
end

function Classifier.Categories()
    local keys = {}
    for i, c in ipairs(CATEGORIES) do keys[i] = c.key end
    return keys
end

-- Ordered { key, label, scale } list for settings (LOCAL -> Local category). `scale`
-- is the category's own default size multiplier and is what Config uses as the default
-- for `LocalIconScale<Key>`, so a new category gets a settings row and a sane starting
-- size from this one table rather than from three places that can disagree.
-- v0.17.0 adds `icon` (default choice key), `icons` (every choice key, in row order),
-- `color` (the default icon's default color, or "white") and `colors` (every color
-- key any of the category's icons offers), which Config uses for `LocalIcon<Key>` and
-- `LocalIconColor<Key>`.
function Classifier.CategoryList()
    local out = {}
    for i, c in ipairs(CATEGORIES) do
        local icons, colors, seen = {}, {}, {}
        for _, option in ipairs(options_for(c.key)) do
            icons[#icons + 1] = option.key
            for _, tint_key in ipairs(option.tints or {}) do
                if not seen[tint_key] then
                    seen[tint_key] = true
                    colors[#colors + 1] = tint_key
                end
            end
        end
        local _, _, default_icon, default_color = Classifier.ResolveArt(c.key)
        out[i] = { key = c.key, label = c.label, scale = Classifier.CategoryScale(c.key),
            icon = default_icon or "default", icons = icons,
            color = default_color or "white", colors = colors }
    end
    return out
end

return Classifier
