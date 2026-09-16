-- MortalShell2ModUI public Lua API.
-- API v2 retains the runtime-proven shared input host and Pass-182
-- default shared-controller consumer facade/profile synchronization contract. Pass 183
-- audits the wider one-window/many-mods goal, transfers proven modal-isolation policy into
-- framework ownership, and hardens the public consumer lifecycle without changing live
-- session/transition timing. Independent UE4SS Lua states
-- exchange only bounded primitive descriptors, presentations and actions; executable
-- setting/gameplay semantics remain inside each consumer mod.
-- v0.71.0: section headers. A consumer row whose rowKind is "header" is drawn as a
-- divider line in capitals (-- TITLE --) with no value; the consumer keeps it
-- unselectable. Settings/Render.DecorateHeaders, applied by the host before the
-- labels are measured, clipped, windowed or hit-tested.
-- v0.70.3: the browser profile (shared controller screen, TTS voice browser) sizes its
-- columns from the text and follows with the smoke, like the settings window.
-- v0.70.2: the rails follow the tab that is showing, both ways (user: the space must
-- come back when a narrower tab no longer needs it).
-- v0.70.1: the smoke backdrop follows the prompt width (Layout.BackgroundTransform).
-- v0.70.0: measured rails (label/value columns grow to the text the host actually
-- drew), a windowed left-justified tab strip that never leaves the window ("<"/">"
-- scroll marks), host-resolved pointer hits carried on native input events, the
-- shared Controller.Settings screen any consumer can open from a row, and
-- hold-to-reset: R / L3 held 5 s over a row publishes "reset-row" to the consumer.
-- v0.69.1: the settings tab strip never squeezes a cell below the six-tab width; more
-- tabs grow the strip (Settings/Layout.TabStrip), drawn cells and pointer regions alike.
-- v0.69.0: performance logging (Core/Perf.lua, ModUI.Perf per Lua state, host follows
-- the consumers' Protocol.PERF_KEYS flags) and a ten-row scrolling settings viewport
-- (Settings/Viewport.lua) so a consumer tab may exceed ten rows.
-- v0.68.4: native-menu gate tracks each open game-tab widget, so closing a child
-- menu (level up) no longer releases a still-open parent (beacon menu).
-- v0.68.3: narrow closed-menu visibility snapshot plus empty-action fast return.
-- v0.68.0: host-owned primitive native-menu lifecycle gate for every consumer.
-- v0.67.1: runtime safety corrective; restores the proven native rich-text rails
-- and retires unproven per-control construction/focus calls.
-- v0.67.0: shared native settings controls, common pointer/semantic policy,
-- scoped reset confirmation, and guarded close lifetime.
-- v0.66.0: settings-provider binding-capture facade, retaining the same
-- host-owned on-demand keyboard/controller recorder used by TTS.
-- v0.65.0: independent provider hotkeys, active-session ownership guard,
-- shared semantic dedupe, and content-aware tab pointer geometry.
-- v0.63.0 / Pass 182 hardens the shared-controller contract: raw acquisition is profile-agnostic, consumer facades automatically inherit/reload the shared profile, and a dedicated non-capture controller feed exposes normalized semantic input to every registered mod by default.
-- v0.62.5 / Pass 181 preserves user-preferred controller thresholds separately from safety-constrained effective runtime values, so temporary low activations restore prior Release/Deadzone preferences when headroom returns.

local ModUI = {
    NAME = "MortalShell2ModUI",
    VERSION = "0.71.8",
    API_VERSION = 2,
}

local function script_path()
    local ok, info = pcall(function() return debug.getinfo(1, "S") end)
    if not ok or info == nil then return nil end
    local source = tostring(info.source or "")
    if source:sub(1, 1) == "@" then source = source:sub(2) end
    if source == "" then return nil end
    return source:gsub("/", "\\")
end

local function parent_path(path)
    if path == nil then return nil end
    return path:match("^(.*)\\[^\\]+$")
end

local scripts_dir = parent_path(script_path())

local function load_component(relative_path, label)
    if scripts_dir == nil then error("MortalShell2ModUI cannot resolve its Scripts directory", 0) end
    local path = scripts_dir .. "\\" .. tostring(relative_path or "")
    local chunk, load_err = loadfile(path)
    if chunk == nil then
        error("MortalShell2ModUI unable to load " .. tostring(label or relative_path) .. ": " .. tostring(load_err), 0)
    end
    local ok, result = pcall(chunk)
    if not ok then
        error("MortalShell2ModUI failed to initialize " .. tostring(label or relative_path) .. ": " .. tostring(result), 0)
    end
    if type(result) ~= "table" then
        error("MortalShell2ModUI component " .. tostring(label or relative_path) .. " did not return a table", 0)
    end
    return result
end

local function try_load_component(relative_path, label)
    local ok, result = pcall(load_component, relative_path, label)
    if ok and type(result) == "table" then return result, nil end
    return nil, tostring(result)
end

local HostProtocol = load_component("Host\\Protocol.lua", "Host.Protocol")
local HostRegistry = load_component("Host\\Registry.lua", "Host.Registry")
local HostService = load_component("Host\\Service.lua", "Host.Service")
local HostMenuService = load_component("Host\\MenuService.lua", "Host.MenuService")
local HostInputService = load_component("Host\\InputService.lua", "Host.InputService")
local HostSemanticService = load_component("Host\\SemanticService.lua", "Host.SemanticService")
local HostShellService = load_component("Host\\ShellService.lua", "Host.ShellService")
local HostConsumerClient = load_component("Host\\ConsumerClient.lua", "Host.ConsumerClient")
local HostProviderSelector = load_component("Host\\ProviderSelector.lua", "Host.ProviderSelector")
local HostAudio = load_component("Host\\Audio.lua", "Host.Audio")
local ControllerProfile = load_component("Controller\\Profile.lua", "Controller.Profile")
local ControllerSettings = load_component("Controller\\Settings.lua", "Controller.Settings")
ModUI.Controller = {
    VERSION = 2,
    Profile = ControllerProfile,
    Settings = ControllerSettings,
}
ModUI.Host = {
    Protocol = HostProtocol,
    Registry = HostRegistry,
    Service = HostService,
    MenuService = HostMenuService,
    InputService = HostInputService,
    SemanticService = HostSemanticService,
    ShellService = HostShellService,
    ConsumerClient = HostConsumerClient,
    ProviderSelector = HostProviderSelector,
    -- v0.71.4: the game's own UI click, played through its own broadcaster.
    Audio = HostAudio,
}

ModUI.Text = load_component("Core\\Text.lua", "Core.Text")
-- Performance logging (Core/Perf.lua, byte-identical in all three mods). ModUI.Perf is
-- the profiler of whichever Lua state loaded this library: the standalone host replaces
-- it with its own instance, and a consumer (Minimap, TTS) assigns its own so library
-- code running in the consumer's state (InputHost polls, consumer-client reads) is
-- charged to that consumer's log. Library modules read ModUI.Perf at call time, never
-- cache it. The default is a disabled instance: Begin() returns nil and costs nothing.
ModUI.PerfFactory = load_component("Core\\Perf.lua", "Core.Perf")
ModUI.Perf = ModUI.PerfFactory.New({ mod = "ModUI-library", log = function() end })
ModUI.Value = load_component("Core\\Value.lua", "Core.Value")
ModUI.Object = load_component("Core\\Object.lua", "Core.Object")
local Array = load_component("Core\\Array.lua", "Core.Array")
ModUI.Array = Array.Bind(ModUI.Object)
local Binding = load_component("Input\\Binding.lua", "Input.Binding")
local Conflict = load_component("Input\\Conflict.lua", "Input.Conflict")
local Capture = load_component("Input\\Capture.lua", "Input.Capture")
local Repeat = load_component("Input\\Repeat.lua", "Input.Repeat")
local Route = load_component("Input\\Route.lua", "Input.Route")
local Acceptance = load_component("Input\\Acceptance.lua", "Input.Acceptance")
ModUI.Input = {
    Binding = Binding,
    Conflict = Conflict.Bind(Binding),
    Capture = Capture,
    Repeat = Repeat,
    Route = Route,
    Acceptance = Acceptance,
}
local Admission = load_component("Runtime\\Admission.lua", "Runtime.Admission")
local Observation = load_component("Runtime\\Observation.lua", "Runtime.Observation")
local BoundObservation = Observation.Bind(ModUI.Object, ModUI.Array)
local Resolve = load_component("Runtime\\Resolve.lua", "Runtime.Resolve")
local Listener = load_component("Runtime\\Listener.lua", "Runtime.Listener")
local Hook = load_component("Runtime\\Hook.lua", "Runtime.Hook")
local Bridge = load_component("Runtime\\Bridge.lua", "Runtime.Bridge")
local InputBridge = load_component("Runtime\\InputBridge.lua", "Runtime.InputBridge")
local PhysicalBinding = load_component("Runtime\\PhysicalBinding.lua", "Runtime.PhysicalBinding")
local ControllerAnalog = load_component("Runtime\\ControllerAnalog.lua", "Runtime.ControllerAnalog")
local InputHost, InputHostError = try_load_component("Runtime\\InputHost.lua", "Runtime.InputHost")
local NativeState = load_component("Runtime\\NativeState.lua", "Runtime.NativeState")
local NativeMenuGate = load_component("Runtime\\NativeMenuGate.lua", "Runtime.NativeMenuGate")
local ModalIsolation = load_component("Runtime\\ModalIsolation.lua", "Runtime.ModalIsolation")
local BoundListener = Listener.Bind(ModUI.Object, ModUI.Array, ModUI.Input.Acceptance, ModUI.Input.Route)
local BoundBridge = Bridge.Bind(ModUI.Object, BoundObservation)
ModUI.Runtime = {
    Admission = Admission,
    Observation = BoundObservation,
    Resolve = Resolve.Bind(ModUI.Object),
    Listener = BoundListener,
    Hook = Hook,
    Bridge = BoundBridge,
    InputBridge = InputBridge.Bind(BoundBridge, BoundListener, Hook),
    PhysicalBinding = PhysicalBinding,
    ControllerAnalog = ControllerAnalog,
    InputHost = InputHost,
    InputHostError = InputHostError,
    NativeState = NativeState,
    NativeMenuGate = NativeMenuGate,
    ModalIsolation = ModalIsolation,
}
local SettingsLayout = load_component("Settings\\Layout.lua", "Settings.Layout")
local SettingsNativeControls = load_component("Settings\\NativeControls.lua", "Settings.NativeControls")
local PresentationSafetyFactory = load_component("Settings\\PresentationSafety.lua", "Settings.PresentationSafety")
local PresentationSafety, PresentationSafetyError = PresentationSafetyFactory.Bind(ModUI.Text, SettingsLayout)
if type(PresentationSafety) ~= "table" or type(PresentationSafety.Sanitize) ~= "function" then
    error("MortalShell2ModUI failed to bind Settings.PresentationSafety: " .. tostring(PresentationSafetyError), 0)
end
ModUI.Settings = {
    Model = load_component("Settings\\Model.lua", "Settings.Model"),
    Render = load_component("Settings\\Render.lua", "Settings.Render"),
    Navigation = load_component("Settings\\Navigation.lua", "Settings.Navigation"),
    Details = load_component("Settings\\Details.lua", "Settings.Details"),
    Layout = SettingsLayout,
    PresentationSafety = PresentationSafety,
    NativeControls = SettingsNativeControls,
    CloseGuard = load_component("Settings\\CloseGuard.lua", "Settings.CloseGuard"),
    Interaction = load_component("Settings\\Interaction.lua", "Settings.Interaction"),
    Viewport = load_component("Settings\\Viewport.lua", "Settings.Viewport"),
}
-- Pointer hits must map back through the same window the host renders from.
ModUI.Settings.Interaction.Viewport = ModUI.Settings.Viewport

ModUI.Capabilities = {
    text = true,
    textEllipsizeLines = true,
    value = true,
    object = true,
    array = true,
    inputBinding = true,
    inputConflict = true,
    inputCapture = true,
    inputRepeat = true,
    inputRoute = true,
    inputAcceptance = true,
    runtimeAdmission = true,
    runtimeObservation = true,
    runtimeResolve = true,
    runtimeListener = true,
    runtimeListenerMutation = true,
    runtimeListenerBindings = true,
    runtimeHook = true,
    runtimeBridgeLifecycle = true,
    runtimeInputBridge = true,
    runtimeInputBridgeExternalHook = true,
    runtimeInputBridgeConstruction = true,
    runtimeInputBridgeLease = true,
    runtimeInputBridgeTrampoline = true,
    runtimeInputBridgeHandlerSlot = true,
    runtimeInputBridgeLeaseHookSpec = true,
    runtimeInputBridgeLeaseRouter = true,
    runtimeInputBridgeLeaseTeardownOptions = true,
    runtimeInputBridgeLeaseTeardownActivation = true,
    runtimeInputBridgeTeardownTicket = true,
    runtimeInputBridgeTeardownAuthorization = true,
    runtimeInputBridgeTeardownCompletion = true,
    runtimeInputBridgeTeardownBarrier = true,
    runtimeInputBridgeTeardownTransaction = true,
    runtimeInputBridgeTeardownPlan = true,
    runtimeInputBridgeSession = true,
    runtimePhysicalBinding = type(PhysicalBinding.New) == "function",
    runtimeControllerAnalog = type(ControllerAnalog.New) == "function",
    controllerProfile = type(ControllerProfile.Current) == "function",
    controllerProfilePersistence = type(ControllerProfile.Save) == "function",
    controllerNormalization = type(ControllerProfile.NormalizeStick) == "function" and type(ControllerProfile.NormalizeAxis) == "function" and type(ControllerProfile.NormalizeAxisSemantic) == "function" and type(ControllerProfile.NormalizeStickSemantic) == "function",
    controllerConsumerDefaultSharedProfile = true,
    controllerRadialStickDeadzone = true,
    controllerTriggerHysteresis = type(ControllerProfile.TriggerActive) == "function",
    controllerSettings = type(ControllerSettings.New) == "function",
    controllerCalibration = type(ControllerSettings.New) == "function",
    controllerTest = type(ControllerSettings.New) == "function",
    runtimeInputHost = InputHost ~= nil and type(InputHost.Install) == "function",
    runtimeInputHostConsumerScoped = InputHost ~= nil and type(InputHost.Install) == "function",
    hostProtocol = true,
    hostRegistry = true,
    hostRegistryPrimitiveOnly = true,
    hostService = true,
    hostMenuService = true,
    hostMenuProviderArbitration = true,
    hostSharedMenuControlPlane = true,
    hostMenuSessionObservation = true,
    hostMenuSessionTransitionRing = true,
    hostMenuSessionLease = true,
    hostMenuLeaseArbitration = true,
    hostMenuLeaseAuthority = true,
    hostMenuShellObservation = true,
    hostSharedMenuShellObservation = true,
    hostVisibleShell = true,
    hostVisibleShellSingleOwner = true,
    hostMenuPresentation = true,
    hostMenuPresentationSafety = true,
    hostMenuConsumerArbitration = true,
    hostMenuActiveConsumer = true,
    hostMenuActionRing = true,
    hostSingleMenuHotkeyOwner = true,
    hostConsumerClient = true,
    hostConsumerRoles = type(HostConsumerClient.BindSettingsProvider) == "function"
        and type(HostConsumerClient.BindControllerConsumer) == "function"
        and type(HostConsumerClient.BindServiceConsumer) == "function",
    hostConsumerRetirement = true,
    hostConsumerControllerFeed = true,
    hostConsumerControllerProfileSync = true,
    hostConsumerControllerSemanticDefault = true,
    hostConsumerControllerProfileMutation = true,
    hostConsumerNativeInput = true,
    hostConsumerDirectory = true,
    hostConsumerActivationCycle = true,
    hostProviderSelector = true,
    hostProviderSelectorClosedState = true,
    hostMultiConsumerRegistration = true,
    hostInputService = true,
    hostSessionNativeInputHook = true,
    hostGenericMenuSemanticRing = true,
    hostControllerCache = true,
    hostIdleAnalogOnDemand = true,
    runtimeInputHostIdleMailboxFastPath = true,
    runtimeInputHostTransitionPendingIntent = true,
    hostRegistrationAck = true,
    hostDiscoveryBounded = true,
    hostPhysicalHotkeyInput = true,
    hostHotkeyCaptureIsolation = true,
    hostCapturePressSequence = true,
    hostPhysicalRightStickY = true,
    hostPhysicalControllerAnalog = true,
    hostPhysicalControllerCapture = true,
    hostPhysicalKeyboardCapture = true,
    hostPhysicalKeyboardNavigation = true,
    hostPhysicalNativeInputHook = true,
    hostPhysicalNativeListenerShadow = true,
    hostPhysicalNativeListener = true,
    hostNativePointerSnapshot = true,
    hostSinglePhysicalInput = true,
    runtimeNativeState = true,
    runtimeNativeMenuGate = type(NativeMenuGate.New) == "function",
    hostNativeMenuState = true,
    runtimeModalIsolationPolicy = type(ModalIsolation.New) == "function",
    settingsLayout = true,
    settingsPresentationSafety = true,
    settingsViewport = true,
    perfLogging = true,
    settingsNativeControls = SettingsNativeControls.RUNTIME_ENABLED == true
        and type(SettingsNativeControls.Bind) == "function",
    settingsCloseGuard = true,
    settingsInteraction = true,
    settingsModel = true,
    settingsRender = true,
    settingsNavigation = true,
    settingsDetails = true,
}

function ModUI.HasCapability(name)
    return ModUI.Capabilities[tostring(name or "")] == true
end

function ModUI.SupportsApi(minimum)
    return ModUI.API_VERSION >= math.floor((tonumber(minimum) or 1) + 0.5)
end

return ModUI
