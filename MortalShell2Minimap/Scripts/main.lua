-- MortalShell2Minimap v0.18.0 COMBAT tab (hide / opacity / size / transition / restore delay, driven by the game's own music state: Combat and BossCombat), section headers inside every tab (ModUI 0.71.0 draws them as dividers), PINS folded into ICONS as "User pins".
-- v0.17.2 The two Cormorant label fonts are gone (a bare UFontFace draws nothing); only a UFont is ever handed to a label, anything else falls back to Trajan with a named reason.
-- v0.17.1 Map labels: size, font (nine of the game's faces + the announcement's), color, outline, shadow and cardinal rows on MAP; the font now reaches Slate (SetFont), the second line drops when it repeats the first, labels clear the frame and the compass letter.
-- v0.17.0 Map frame (GENERAL: Off / Ring-Bars / Vector / Compass-Dividers, color row, on by default) and the icon audit: every LOCAL category cycles its own icon shortlist with a color row for white art; six new categories (loot plants, rest spots, map fragments, locked doors, gloom siphons, Thestus).
-- v0.16.12 Explosive barrels wear the burn flame (T_UI_StatusEffect_Burn, her pick) at three-quarter size.
-- v0.16.11 Auto ceiling cut: the dungeon map is cut just under the measured headroom (five upward traces per capture), low in corridors, high in halls; MAP row Auto/Fixed, CAPTURE row for the maximum.
-- v0.16.10 Explosive barrels are their own LOCAL category (own on/off and size).
-- v0.16.9 Enemy dots for classes without footsteps (bats, tarred vestiges): eight movement-derived refresh probes on the AI character, player never a dot.
-- v0.16.8 Settings reorganised (GENERAL/MAP/ICONS/LOCAL/PINS/INPUT/MOD/CAPTURE), Advanced settings switch, arrows wrap, hold R/L3 resets a row, shared Controller settings row, footstep trail size, dungeon rate to 60 Hz.
-- v0.13.0 Performance logging: [PERF] sections over every recurring and native-touching path, "Log performance" on the MOD tab, shared flag for the ModUI host
-- Composition root for the modular, performance-first native tile minimap and
-- capped plain-image user-pin/objective pools, lifecycle rehydration, and telemetry.

local MOD_NAME = "MortalShell2Minimap"
local VERSION = "0.18.46"
local MOD_PREFIX = "[MortalShell2Minimap]"

local function log(message)
    print(string.format("%s %s\n", MOD_PREFIX, tostring(message)))
end

local function script_path()
    local ok, info = pcall(function() return debug.getinfo(1, "S") end)
    if not ok or type(info) ~= "table" then return nil end
    local source = tostring(info.source or "")
    if source:sub(1, 1) == "@" then source = source:sub(2) end
    if source == "" then return nil end
    return source:gsub("/", "\\")
end

local function parent_path(path)
    if type(path) ~= "string" then return nil end
    return path:match("^(.*)\\[^\\]+$")
end

local scripts_dir = parent_path(script_path())
local mod_dir = parent_path(scripts_dir) or "Mods\\MortalShell2Minimap"
local mods_dir = parent_path(mod_dir) or "Mods"

local function load_module(relative_path)
    local full_path = scripts_dir .. "\\" .. relative_path
    local chunk, load_error = loadfile(full_path)
    if chunk == nil then
        log("Module load failed path=" .. tostring(relative_path) .. " error=" .. tostring(load_error))
        return nil
    end
    local ok, result = pcall(chunk)
    if not ok or type(result) ~= "table" then
        log("Module invalid path=" .. tostring(relative_path) .. " error=" .. tostring(result))
        return nil
    end
    return result
end

local StateModule = load_module("Runtime\\State.lua")
local ConfigFactory = load_module("Config\\Runtime.lua")
local SchemaModule = load_module("Config\\Schema.lua")
local ObjectFactory = load_module("Core\\Object.lua")
local PerfFactory = load_module("Core\\Perf.lua")
local MapScaleModule = load_module("Map\\Scale.lua")
local RendererFactory = load_module("Map\\NativeWidget.lua")
local UIFactory = load_module("UI\\ModUI.lua")
local LifecycleFactory = load_module("Runtime\\Lifecycle.lua")
local WorkBudgetFactory = load_module("Runtime\\WorkBudget.lua")
local AreaMapStateFactory = load_module("Map\\AreaMapState.lua")
local ProjectionModule = load_module("POI\\Projection.lua")
local IconResolverModule = load_module("POI\\IconResolver.lua")
local EdgePolicyModule = load_module("Overlay\\EdgePolicy.lua")
local IconScaleModule = load_module("Overlay\\IconScale.lua")
local TrackerProjectionFactory = load_module("Overlay\\TrackerProjection.lua")
local TrackerPoolFactory = load_module("Overlay\\TrackerPool.lua")
local ObjectivePoolFactory = load_module("Overlay\\ObjectivePool.lua")
local LocalClassifierModule = load_module("Local\\Classifier.lua")
local LocalPoolFactory = load_module("Overlay\\LocalPool.lua")
local TrailPoolFactory = load_module("Overlay\\TrailPool.lua")
local LabelsFactory = load_module("Overlay\\Labels.lua")
local FrameFactory = load_module("Overlay\\Frame.lua")
local CombatStateFactory = load_module("Runtime\\CombatState.lua")
local DungeonViewFactory = load_module("Map\\DungeonView.lua")
local LocalDiscoveryFactory = load_module("Local\\Discovery.lua")
local AreaNameFactory = load_module("Local\\AreaName.lua")
local InteractionProbeFactory = load_module("Diagnostics\\InteractionProbe.lua")
local StateReaderFactory = load_module("POI\\StateReader.lua")
local TrackerTelemetryFactory = load_module("POI\\TrackerTelemetry.lua")
local RegistryFactory = load_module("POI\\Registry.lua")
local TrackerPersistenceFactory = load_module("POI\\TrackerPersistence.lua")
local TrackerLifecycleFactory = load_module("POI\\TrackerLifecycle.lua")
local AuditFactory = load_module("POI\\Audit.lua")
local HooksFactory = load_module("POI\\Hooks.lua")
if StateModule == nil or ConfigFactory == nil or SchemaModule == nil or ObjectFactory == nil
    or PerfFactory == nil or MapScaleModule == nil
    or RendererFactory == nil or UIFactory == nil or LifecycleFactory == nil
    or WorkBudgetFactory == nil or AreaMapStateFactory == nil
    or ProjectionModule == nil or IconResolverModule == nil
    or EdgePolicyModule == nil or IconScaleModule == nil
    or TrackerProjectionFactory == nil
    or TrackerPoolFactory == nil
    or ObjectivePoolFactory == nil
    or LocalClassifierModule == nil or LocalPoolFactory == nil or LocalDiscoveryFactory == nil
    or InteractionProbeFactory == nil
    or StateReaderFactory == nil or TrackerTelemetryFactory == nil
    or RegistryFactory == nil or TrackerPersistenceFactory == nil
    or TrackerLifecycleFactory == nil
    or AuditFactory == nil
    or HooksFactory == nil then
    log("Startup stopped because one or more required modules could not be loaded; re-extract the release ZIP")
    return
end

local config_runtime = ConfigFactory.New({
    config_path = mod_dir .. "\\MinimapConfig.ini",
    log = log,
    categories = IconResolverModule.Categories,
    local_categories = type(LocalClassifierModule.CategoryList) == "function"
        and LocalClassifierModule.CategoryList() or nil,
})
if type(config_runtime) ~= "table" or type(config_runtime.Values) ~= "table"
    or type(config_runtime.Normalize) ~= "function" or type(config_runtime.Save) ~= "function" then
    log("Startup stopped because Config.Runtime API is incomplete; re-extract the release ZIP")
    return
end

local Config = config_runtime.Values
local schema_runtime = type(SchemaModule.New) == "function"
    and SchemaModule.New(IconResolverModule.Categories,
        type(LocalClassifierModule.CategoryList) == "function" and LocalClassifierModule.CategoryList() or nil,
        LocalClassifierModule, LabelsFactory) or nil
if type(schema_runtime) ~= "table" or type(schema_runtime.Settings) ~= "table"
    or type(schema_runtime.Tabs) ~= "table" then
    log("Startup stopped because Config.Schema API is incomplete; re-extract the release ZIP")
    return
end
local function debug_log(message)
    if Config.DebugLog then log(message) end
end

local state = StateModule.New()
if type(state) ~= "table" then
    log("Startup stopped because Runtime.State API is incomplete; re-extract the release ZIP")
    return
end

_G.MortalShell2MinimapRuntime = _G.MortalShell2MinimapRuntime or {}
local global_runtime = _G.MortalShell2MinimapRuntime
global_runtime.generation = math.max(0, math.floor(tonumber(global_runtime.generation) or 0)) + 1
local instance_generation = global_runtime.generation
state.scheduler_generation = instance_generation
global_runtime.state = state

local ctx = {
    ModName = MOD_NAME,
    Version = VERSION,
    ModRef = ModRef,
    ScriptsDir = scripts_dir,
    ModDir = mod_dir,
    ModsDir = mods_dir,
    ConfigRuntime = config_runtime,
    Config = Config,
    Settings = schema_runtime.Settings,
    SettingsTabs = schema_runtime.Tabs,
    State = state,
    GlobalRuntime = global_runtime,
    InstanceGeneration = instance_generation,
    Log = log,
    DebugLog = debug_log,
}

ctx.Object = ObjectFactory.New(state)
-- Performance logging (Core/Perf.lua; see PERFORMANCE_LOGGING.md). Off by default and
-- free when off; the "Log performance" row on the MOD tab turns it on. Every
-- recurring or native-touching path in this mod opens a section on it.
ctx.Perf = PerfFactory.New({ mod = "Minimap", log = log, clock = os.clock })
config_runtime.SetPerf(ctx.Perf)
local PERF_SHARED_KEY = "MortalShell2Perf.Minimap"
-- Mirrors Config.LogPerformance into the profiler and tells the shared ModUI host
-- (which has no settings of its own) to log too. Called from the pose tick, so a
-- settings change, a tab reset, or an ini edit takes effect within one tick.
ctx.PerfSync = function(reason)
    local wanted = Config.LogPerformance == true
    if ctx.Perf.SetEnabled(wanted, reason or "setting") then
        if ModRef ~= nil and type(ModRef.SetSharedVariable) == "function" then
            pcall(ModRef.SetSharedVariable, ModRef, PERF_SHARED_KEY, wanted and 1 or 0)
        end
    end
end
ctx.MapScale = MapScaleModule
ctx.Renderer = RendererFactory.New(ctx)
ctx.UI = UIFactory.New(ctx)
ctx.Lifecycle = LifecycleFactory.New(ctx)
ctx.WorkBudget = WorkBudgetFactory.New(ctx)
ctx.Projection = ProjectionModule
ctx.IconResolver = IconResolverModule
ctx.EdgePolicy = EdgePolicyModule
ctx.IconScale = IconScaleModule
ctx.TrackerProjection = TrackerProjectionFactory.New(ctx)
ctx.TrackerPool = TrackerPoolFactory.New(ctx)
ctx.ObjectivePool = ObjectivePoolFactory.New(ctx)
ctx.LocalClassifier = LocalClassifierModule
ctx.LocalPool = LocalPoolFactory.New(ctx)
ctx.LocalDiscovery = LocalDiscoveryFactory.New(ctx)
ctx.AreaName = AreaNameFactory ~= nil and AreaNameFactory.New(ctx) or nil
ctx.TrailPool = TrailPoolFactory ~= nil and TrailPoolFactory.New(ctx) or nil
ctx.Labels = LabelsFactory ~= nil and LabelsFactory.New(ctx) or nil
-- v0.17.0 map frame: optional by construction like the labels; nothing else depends on it.
ctx.Frame = FrameFactory ~= nil and FrameFactory.New(ctx) or nil
-- v0.18.0 combat look (COMBAT tab): optional by construction; without it the map
-- simply never reacts to a fight.
ctx.Clock = os.clock
ctx.Combat = CombatStateFactory ~= nil and CombatStateFactory.New(ctx) or nil
-- v0.14.0 dungeon view. Optional by construction: if the module or any engine call it
-- needs is missing, Active() stays false and unmapped areas keep the old presentation.
ctx.DungeonView = DungeonViewFactory ~= nil and DungeonViewFactory.New(ctx) or nil
ctx.InteractionProbe = InteractionProbeFactory.New(ctx)
ctx.AreaMapState = AreaMapStateFactory.New(ctx)
ctx.StateReader = StateReaderFactory.New(ctx)
ctx.TrackerTelemetry = TrackerTelemetryFactory.New(ctx)
ctx.Registry = RegistryFactory.New(ctx)
ctx.TrackerPersistence = TrackerPersistenceFactory.New(ctx)
ctx.TrackerLifecycle = TrackerLifecycleFactory.New(ctx)
ctx.Audit = AuditFactory.New(ctx)
ctx.POIHooks = HooksFactory.New(ctx)
if type(ctx.Object) ~= "table" or type(ctx.MapScale) ~= "table"
    or type(ctx.Renderer) ~= "table"
    or type(ctx.UI) ~= "table" or type(ctx.Lifecycle) ~= "table"
    or type(ctx.WorkBudget) ~= "table" or type(ctx.AreaMapState) ~= "table"
    or type(ctx.StateReader) ~= "table"
    or type(ctx.EdgePolicy) ~= "table" or type(ctx.IconScale) ~= "table"
    or type(ctx.TrackerProjection) ~= "table"
    or type(ctx.TrackerPool) ~= "table"
    or type(ctx.ObjectivePool) ~= "table"
    or type(ctx.LocalClassifier) ~= "table"
    or type(ctx.LocalPool) ~= "table" or type(ctx.LocalPool.SyncRecords) ~= "function"
    or type(ctx.LocalDiscovery) ~= "table" or type(ctx.LocalDiscovery.Arm) ~= "function"
    or type(ctx.LocalDiscovery.OnLoadMapPre) ~= "function"
    or type(ctx.LocalDiscovery.OnWorldReleased) ~= "function"
    or type(ctx.InteractionProbe) ~= "table" or type(ctx.InteractionProbe.EmitSnapshot) ~= "function"
    or type(ctx.InteractionProbe.OnLoadMapPre) ~= "function"
    or type(ctx.InteractionProbe.OnWorldReleased) ~= "function"
    or type(ctx.TrackerTelemetry) ~= "table"
    or type(ctx.Registry) ~= "table" or type(ctx.TrackerPersistence) ~= "table"
    or type(ctx.TrackerLifecycle) ~= "table"
    or type(ctx.Audit) ~= "table"
    or type(ctx.POIHooks) ~= "table" then
    log("Startup stopped because a runtime module API is incomplete; re-extract the release ZIP")
    return
end

local function arm_poi_hooks()
    local armed, total = ctx.POIHooks.Arm()
    return armed >= total
end

local function retry_poi_hooks()
    if arm_poi_hooks() then return end
    local generation = ctx.Registry.State.generation
    for _, delay_ms in ipairs({ 500, 1500, 3000 }) do
        ctx.WorkBudget.Schedule(delay_ms, function()
            if not ctx.Registry.State.quarantined
                and ctx.Registry.State.generation == generation then arm_poi_hooks() end
        end, "poi.arm-retry")
    end
end

ctx.POI = {
    OnLoadMapPre = function()
        if ctx.Registry.State.ready or ctx.Registry.State.record_count > 0 then
            ctx.Registry.EmitSummary("world-close")
        end
        ctx.Audit.OnLoadMapPre()
        ctx.InteractionProbe.OnLoadMapPre()
        ctx.LocalDiscovery.OnLoadMapPre()
        if type(ctx.AreaName) == "table" then ctx.AreaName.OnWorldPre() end
        ctx.AreaMapState.OnLoadMapPre()
        ctx.TrackerLifecycle.OnLoadMapPre()
        ctx.Registry.OnLoadMapPre()
        ctx.ObjectivePool.DropWorldReferencesUnread()
        ctx.TrackerPool.DropWorldReferencesUnread()
        ctx.LocalPool.DropWorldReferencesUnread()
        if type(ctx.TrailPool) == "table" then ctx.TrailPool.DropWorldReferencesUnread() end
        if type(ctx.Labels) == "table" then ctx.Labels.DropWorldReferencesUnread() end
        if type(ctx.Frame) == "table" then ctx.Frame.DropWorldReferencesUnread() end
        if type(ctx.Combat) == "table" then ctx.Combat.DropWorldReferencesUnread() end
        if type(ctx.AreaName) == "table" then ctx.AreaName.DropWorldReferencesUnread() end
        if type(ctx.DungeonView) == "table" then ctx.DungeonView.DropWorldReferencesUnread() end
    end,
    OnWorldReleased = function(reason)
        ctx.Registry.OnWorldReleased()
        ctx.TrackerLifecycle.OnWorldReleased()
        ctx.AreaMapState.OnWorldReleased(reason)
        ctx.LocalDiscovery.OnWorldReleased(reason)
        if type(ctx.AreaName) == "table" then
            ctx.AreaName.Arm()
            -- The one global enumeration in this mod: volumes and beacons that spawned
            -- before we armed are invisible to a spawn-sourced layer, so seed once per
            -- world, off the pose loop, and never again.
            ctx.WorkBudget.Schedule(2500, function()
                if global_runtime.generation == instance_generation then
                    ctx.AreaName.Seed(reason)
                end
            end, "areaname.seed")
        end
        ctx.InteractionProbe.OnWorldReleased(reason)
        retry_poi_hooks()
        ctx.Audit.OnWorldReleased(reason)
    end,
    OnRendererReady = function()
        retry_poi_hooks()
        ctx.TrackerPool.OnRendererReady()
        ctx.ObjectivePool.OnRendererReady()
        ctx.LocalPool.OnRendererReady()
        if type(ctx.TrailPool) == "table" then ctx.TrailPool.OnRendererReady() end
        if type(ctx.Labels) == "table" then
            ctx.Labels.OnRendererReady()
            ctx.Labels.Arm()
        end
        if type(ctx.Frame) == "table" then ctx.Frame.OnRendererReady() end
        if type(ctx.Combat) == "table" then
            ctx.Combat.OnRendererReady()
            ctx.Combat.Arm()
        end
        if type(ctx.DungeonView) == "table" then ctx.DungeonView.OnRendererReady() end
        ctx.Audit.Begin("renderer-ready")
    end,
}

global_runtime.modules = {
    Config = config_runtime,
    Perf = ctx.Perf,
    Object = ctx.Object,
    MapScale = ctx.MapScale,
    Renderer = ctx.Renderer,
    UI = ctx.UI,
    Lifecycle = ctx.Lifecycle,
    WorkBudget = ctx.WorkBudget,
    AreaMapState = ctx.AreaMapState,
    Projection = ctx.Projection,
    IconResolver = ctx.IconResolver,
    EdgePolicy = ctx.EdgePolicy,
    IconScale = ctx.IconScale,
    TrackerProjection = ctx.TrackerProjection,
    TrackerPool = ctx.TrackerPool,
    ObjectivePool = ctx.ObjectivePool,
    LocalClassifier = ctx.LocalClassifier,
    LocalPool = ctx.LocalPool,
    LocalDiscovery = ctx.LocalDiscovery,
    InteractionProbe = ctx.InteractionProbe,
    StateReader = ctx.StateReader,
    TrackerTelemetry = ctx.TrackerTelemetry,
    Registry = ctx.Registry,
    TrackerPersistence = ctx.TrackerPersistence,
    TrackerLifecycle = ctx.TrackerLifecycle,
    Audit = ctx.Audit,
    POIHooks = ctx.POIHooks,
}

ctx.UI.Bind()
arm_poi_hooks()
local local_armed, local_total = ctx.LocalDiscovery.Arm()
if local_armed < local_total then
    for _, delay_ms in ipairs({ 500, 1500, 3000 }) do
        ctx.WorkBudget.Schedule(delay_ms, function()
            if global_runtime.generation == instance_generation then ctx.LocalDiscovery.Arm() end
        end, "discovery.arm-retry")
    end
end
-- The location-volume class is not loaded at boot: in the AreaProbe run it came up on
-- the fifteenth attempt, eighty seconds in. Retry for long enough to catch that.
if type(ctx.AreaName) == "table" then
    ctx.AreaName.Arm()
    for _, delay_ms in ipairs({ 1000, 3000, 6000, 12000, 20000, 35000, 60000, 90000 }) do
        ctx.WorkBudget.Schedule(delay_ms, function()
            if global_runtime.generation ~= instance_generation then return end
            local armed, total = ctx.AreaName.Arm()
            if armed >= total then ctx.AreaName.Seed("armed") end
        end, "areaname.arm-retry")
    end
end
-- v0.18.0: the Combat music state's class is loaded with the game (its CDO is in the
-- object dump), so this usually arms first try; the ladder covers a slow first load.
if type(ctx.Combat) == "table" then
    local armed, total = ctx.Combat.Arm()
    if armed < total then
        for _, delay_ms in ipairs({ 1000, 5000, 15000, 45000 }) do
            ctx.WorkBudget.Schedule(delay_ms, function()
                if global_runtime.generation == instance_generation then ctx.Combat.Arm() end
            end, "combat.arm-retry")
        end
    end
end

local summary_hotkey = "unavailable"
local interaction_hotkey = "unavailable"
if type(RegisterKeyBind) == "function" and type(Key) == "table" and Key.DEL ~= nil
    and type(ModifierKey) == "table" and ModifierKey.CONTROL ~= nil then
    local hotkey_ok = pcall(RegisterKeyBind, Key.DEL, { ModifierKey.CONTROL }, function()
        if global_runtime.generation == instance_generation then
            ctx.AreaMapState.EmitSummary("ctrl-delete")
            ctx.Renderer.EmitSummary("ctrl-delete")
            ctx.Registry.EmitSummary("ctrl-delete")
            ctx.UI.EmitSummary("ctrl-delete")
            ctx.LocalDiscovery.EmitSummary("ctrl-delete")
            if type(ctx.AreaName) == "table" then ctx.AreaName.EmitSummary("ctrl-delete") end
            ctx.LocalPool.EmitSummary("ctrl-delete")
            if type(ctx.TrailPool) == "table" then ctx.TrailPool.EmitSummary("ctrl-delete") end
            if type(ctx.Labels) == "table" then ctx.Labels.EmitSummary("ctrl-delete") end
            if type(ctx.Frame) == "table" then ctx.Frame.EmitSummary("ctrl-delete") end
            if type(ctx.Combat) == "table" then ctx.Combat.EmitSummary("ctrl-delete") end
            if type(ctx.DungeonView) == "table"
                and type(ctx.DungeonView.Summary) == "function" then
                log("Dungeon view " .. ctx.DungeonView.Summary())
            end
            ctx.Perf.Emit("ctrl-delete")
        end
    end)
    if hotkey_ok then summary_hotkey = "Ctrl+Delete" end
end

if type(RegisterKeyBind) == "function" and type(Key) == "table" and Key.DEL ~= nil
    and type(ModifierKey) == "table" and ModifierKey.CONTROL ~= nil
    and ModifierKey.SHIFT ~= nil then
    local hotkey_ok = pcall(RegisterKeyBind, Key.DEL,
        { ModifierKey.CONTROL, ModifierKey.SHIFT }, function()
        if global_runtime.generation == instance_generation then
            ctx.LocalDiscovery.EmitSummary("ctrl-shift-delete")
            if type(ctx.AreaName) == "table" then ctx.AreaName.EmitSummary("ctrl-shift-delete") end
            ctx.LocalPool.EmitSummary("ctrl-shift-delete")
            ctx.InteractionProbe.EmitSnapshot("ctrl-shift-delete")
        end
    end)
    if hotkey_ok then interaction_hotkey = "Ctrl+Shift+Delete" end
end

ctx.PerfSync("startup")
ctx.Lifecycle.Start()

log(string.format(
    "v%s loaded architecture=modular enabled=%s size=%d range=%.0fm tileBudget=%d lodBias=%.1f panHz=%d summaryHotkey=%s interactionHotkey=%s perfLogging=%s; native tiles plus five preallocated user pins and capped sliced objective images, trackerPool=5 trackerSize=%d persistentEdges=%s edgeRange=%.0fm edgeMinScale=%.2f edgeVisibility=%d%% edgePolicy=user-visible-depth+native-aspect trackerLifecycle=post-hook-plus-one-shot-save-outparam objectiveMarkers=bootstrap+event-driven+category-discovery-policy+spoils-retire areaMap=exact-HasAreaMap+native-bounds-fallback+pose-boundary-crossing noMapBackground=%s+nativeFog circleOpacity=outer-retainer+curve-compensated orientation=%s mapShape=%s objectivePoolCap=%d categories=%d settingsTabs=%d settingsInput=shared-native-controls+semantic-dedupe+pointer-targets+close-guard nativeMenuVisibility=balanced-game-tab-state+exact-landing-open settingsPreview=live pauseWhileOpen=%s projection=geometry-cadence+broad-phase+cached-basis moduiPolling=narrow-visibility-snapshot+empty-action-fast-return localLayers=enemies(spawn-sourced+governed-refresh)+traps(env-shooting-component;state-read+spent-hooks+name-supersede)+walls(hidden+rubble;seed+beginplay+notify-reseed;open-retire)+plants(flower-chest+attack-flower;seed+beginplay;state-read+hit-read+regrow)+height-chevrons(sized+fade)+icon-plates+footstep-trail+labels(two-line-area+sub,cardinals;volume-sourced-names+verified-text-ctor+own-trajan-asset+outer-canvas-ring+probed-ink-shape) areaName=location-volumes(outer-text,sub-id)+beacon-proximity+one-shot-world-seed localDiscovery=hot-hook-governor+budgeted-breadcrumb+default-admit-minus-map-duplicates+npc-by-beginplay-source+merchant-by-shop-handler+ranked-hints+gate(hidden,interactions-disabled;enemies-exempt;invalidate-evidence-only)+per-category-toggles+npc-beginplay+handler-lifecycle+primitive-only-no-retained-actor-refs+retire(endplay,unregister,chest-opened,pickup-collected,invalidate-for-pickups)+quarantine-safe-removal localPool=32-default+per-category-art+per-category-scale(settings-backed)+aspect-fit+keeper-pinned-textures+range-prefilter+10m-primitive-reselect+no-edge+no-global-scan interactionDiagnostics=explicit-heavy-only",
    VERSION, tostring(Config.Enabled), Config.Size, Config.ZoomMeters,
    Config.MaxResidentTiles, Config.LODBias, Config.PanUpdatesPerSecond,
    summary_hotkey, interaction_hotkey, tostring(Config.LogPerformance == true), Config.TrackerIconSize,
    tostring(Config.ShowTrackerEdgeIndicators), Config.TrackerEdgeMaxDistance,
    Config.TrackerEdgeMinScale, math.floor(tonumber(Config.EdgeVisibility) or 50),
    tostring(Config.TransparentNoMapBackground),
    tostring(Config.MapOrientation), tostring(Config.MapShape), Config.POIMaxIcons,
    #IconResolverModule.Categories, #schema_runtime.Tabs,
    tostring(Config.PauseGameWhileSettingsOpen)))
