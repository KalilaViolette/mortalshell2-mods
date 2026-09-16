-- v0.68 adds a host-owned primitive native-menu lifecycle gate so every
-- consumer can suspend UObject work across game-menu transitions.
-- v0.67 adds shared native text controls, target-derived pointer routing,
-- semantic alias dedupe, per-tab reset interaction, and a guarded close lifetime.
-- v0.65 keeps the proven shell/modal implementation while isolating every
-- provider hotkey and preventing active-session ownership theft.
-- Pass 182 hardens the shared controller contract: consumer mods receive the current shared Controller.Profile automatically through a dedicated non-capture controller feed, while raw physical acquisition remains profile-agnostic.
-- Pass 178 preserves the 100 Hz Controller Test/Calibration lane and corrects raw analog source arbitration so finite near-center analog values cannot become synthetic digital +/-1.
-- Pass 162 adds a host-owned closed-state provider selector and a real independent second-consumer
-- integration probe. The canonical menu hotkey remains single-owner; the selector changes only the
-- active provider while the shared menu is closed, then the same hotkey targets that provider.
-- Pass 161 moves the bounded shared-menu native semantic callback into the standalone ModUI
-- host while keeping the rejected process-lifetime callback mirror hard-isolated. The one visible
-- shell survives same-consumer/same-generation descriptor revisions without recreation.
-- Pass 155 gives active binding capture exclusive physical-key authority, carries monotonic
-- per-key pressSequence edges through the hosted capture mailbox, and uses a capture-only 20 ms
-- cadence so repeated presses cannot be flattened by the normal 50 ms state-sample path. Open-bind
-- neutral rearm waits until capture ends; checkpoint-4 quarantine and rejected mirror are unchanged.
-- Pass 152 keeps the Pass-151 process-wide InputTriggeredCallback mirror hard-isolated while
-- allowing MortalShell2TTS to restore host-owned physical WBP_InputListener construction. Callback
-- semantics remain one TTS-local per-session hook, admitted by the host-published primitive listener
-- address. OPEN-HOTKEY ownership remains consumer-side, so rejected checkpoint 2 is not revived.
-- Pass 151 rolled the unsafe process-wide callback mirror back after Pass 150 reproduced CBADB8CF.
local ok, ModUI = pcall(require, "ModUI")
if not ok or type(ModUI) ~= "table" then
    print("[MortalShell2ModUI] startup failed: " .. tostring(ModUI) .. "\n")
    return
end

-- Pass 137 keeps the standalone host-native-listener capability available but does not
-- change its implementation; MortalShell2TTS intentionally selects the numeric-address
-- consumer-listener path as a transition-crash ownership A/B. Pass 136 gameplay-only
-- front-end admission remains active before consumer open-hotkey evaluation.
-- Pass 135 retains Pass 134 open-hotkey isolation and adds consumer-side transition-settle admission.
-- Pass 134 isolated standalone physical OPEN-HOTKEY polling after two transition-heavy
-- collectors crashed in the same UE4SS native call-stack family at the next menu-chord boundary.
-- Consumers may opt out of host hotkey ownership while retaining the host provider/session/
-- native-listener/control-plane architecture. Pass 133 still hardens the world-transition boundary:
-- shared PlayerController resolution now prefers the valid local PlayerController/Pawn pair
-- instead of trusting FindFirstOf(BP_PlayerCharacter_C) when stale loaded characters may coexist.
-- Pass 132 shell observation remains observation-only; visible shell ownership stays with TTS.
-- Pass 130 promotes the Pass-129-proven canonical shared-menu lease from observation into a
-- guarded native-listener authorization boundary. The standalone primary WBP_InputListener is
-- created/retained and allowed to publish host-owned native events only while the exact current
-- provider/revision/generation lease is granted. Visible shell construction/rendering/open-close is promoted to the standalone host when the provider advertises presentation support; consumer-local shell remains fail-soft fallback, and the existing mutually-exclusive 750 ms consumer-listener fallback
-- remains available if host lease/listener authority fails to become active.
-- Pass 125 promotes the Pass-124-proven generic native-listener construction/
-- lifetime boundary. While a consumer native-input request is active, ModUI creates one
-- additional WBP_InputListener shadow, configures/binds it, observes its callbacks, and
-- retires it when requests reach zero. Consumer listener semantics remain authoritative
-- in this proof pass, so hostSinglePhysicalInput is still false.
-- Pass 123 moved pointer semantics onto the proven host snapshot with a bootstrap/local
-- fallback gate; Pass 122 corrected callback-time pointer acquisition through BPFL_UI,
-- WidgetLayoutLibrary, then PlayerController out-parameters.
-- Pass 119 consumes the now-proven exact-listener native event ring for consumer-provided
-- non-pointer menu semantics. Mouse/pointer actions remain on the immediate local callback
-- pending cursor-at-event ownership, and the local controller route remains fail-soft fallback
-- when the host request is unavailable.
-- Pass 118 corrects the Pass-117 observation-hook startup race by deferring/retrying
-- hook arming after UE4SS game-thread initialization. Pass 117 adds one process-wide
-- standalone WBP_InputListener InputTriggeredCallback observation hook. Only events from
-- the exact consumer-published active listener address
-- are mirrored through a revision/epoch/request-bound primitive ring; TTS's existing local
-- listener hook remains authoritative for semantics in this staged proof pass.
-- Pass 116 moves the fixed keyboard navigation RegisterKeyBind owner into standalone
-- MortalShell2ModUI. Primitive navigation events cross the Lua-state boundary; consumer
-- Settings/Voice Browser semantics and the native WBP_InputListener remain unchanged.
-- Pass 115 extends the proven on-demand capture mailbox to keyboard recording. The broad
-- keyboard catalog is scanned/published only while a revision/epoch/capture-sequence-bound
-- keyboard recording request is active; native menu navigation and mouse capture remain consumer-scoped.
-- Pass 114 moved controller DIGITAL binding-capture button reads behind the same on-demand
-- Host.InputService request; idle polling scans neither capture catalog.
-- Pass 113 expands the now-runtime-proven shared RightY mailbox to the complete controller
-- analog set used by capture/browser consumers: both stick axes plus both trigger axes.
-- The SAME standalone 50 ms physical poll publishes change/heartbeat-throttled samples.
-- Pass 112 corrected the Pass-111 readiness publication gap: Host.InputService was
-- publishing RightY samples, but PhysicalAnalogState remained "starting", so consumers
-- correctly stayed on their local fail-soft reader and never trusted the shared mailbox.
-- Pass 111 extends the already-running standalone physical poll with a revision-bound
-- RightY axis mailbox. Details scrolling, Voice Browser paging, right-stick capture and
-- RightY hotkey evaluation can consume the same host-owned sample without another physical read.
-- Pass 109 corrects the Pass-108 public API composition regression: ModUI.lua now
-- explicitly loads/exposes Host.InputService and Runtime.PhysicalBinding before capability
-- construction. Pass 108's physical ownership scope itself is otherwise unchanged.
-- Pass 108 starts the physical ownership migration after Pass-107 runtime proof: the
-- standalone ModUI state now owns OPEN-HOTKEY key/axis polling through Host.InputService.
-- Native menu input, binding capture, browser/details analog, and consumer action semantics
-- remain consumer-scoped, so one complete physical/menu host is still NOT claimed yet.
-- Pass 106 established Host.Protocol/Host.Registry v1 over primitive-only UE4SS shared
-- variables so separate Lua states can exchange declarative metadata without callbacks.
-- Pass 105 moved the reusable consumer-scoped keyboard/controller/mouse/hotkey runtime
-- into ModUI Runtime.InputHost.
-- Pass 90 preserves explicit false in native-state tri-state observations; Pass 89 added a pure read-only native-state transition tracker for bounded
-- consumer diagnostics. It performs no Unreal access or mutation.
-- Pass 75 keeps the target-game-proven teardown plan intact and retains the
-- successful Open listener/lease/activation plus its later teardown plan in one shared
-- session. MortalShell2TTS still chooses the listener class and decides exactly when
-- open, quarantine, deactivation, and retirement may occur.
-- v0.71.2: the startup line is version and API only. The full capability string --
-- every subsystem and its ownership, 2,600 characters of it -- is a developer
-- diagnostic, and it was the first thing a user saw on opening UE4SS.log to report a
-- bug. It still goes out, but only when ModUI logging is on.
local capabilities_logged = false
local CAPABILITIES = "runtimeOwnership=input-bridge-session-host coreValue=shared runtimeObject=shared runtimeArray=shared runtimeObservation=shared runtimeResolve=shared runtimeListener=shared-bindings runtimeHook=shared-lifecycle runtimeBridge=shared-lifecycle runtimeInputBridge=shared-session-host runtimeInputBridgeConstruction=shared runtimeInputBridgeLease=shared runtimeInputBridgeTrampoline=shared runtimeInputBridgeHandlerSlot=shared runtimeInputBridgeLeaseHookSpec=shared runtimeInputBridgeLeaseRouter=shared runtimeInputBridgeLeaseTeardownOptions=shared runtimeInputBridgeLeaseTeardownActivation=shared runtimeInputBridgeTeardownTicket=shared runtimeInputBridgeTeardownAuthorization=shared runtimeInputBridgeTeardownCompletion=shared runtimeInputBridgeTeardownBarrier=shared runtimeInputBridgeTeardownTransaction=shared runtimeInputBridgeTeardownPlan=shared runtimeInputBridgeSession=shared runtimePhysicalBinding=shared runtimeControllerAnalog=shared controllerProfile=shared-persistent controllerSettings=shared-calibration-test runtimeInputHost=shared-consumer-settings hostProtocol=primitive-v1 hostRegistry=deterministic-slots hostService=revision-aware hostMenuService=provider+session-transition-ring+lease-arbitration+native-listener-authority hostNativeMenuState=primitive-hook-gate hostVisibleShell=single-owner+revision-continuity+primitive-presentation hostSemanticService=session-bounded-exact-listener hostMenuSessionObservation=true hostMenuSessionTransitionRing=true hostMenuSessionLease=true hostMenuLeaseArbitration=true hostMenuLeaseAuthority=true hostInputService=standalone-open-hotkeys+controller-analog+on-demand-controller+keyboard-capture+fixed-keyboard-navigation+generic-native-event-ring+pointer-semantics+native-listener-primary hostRegistrationAck=true hostPhysicalHotkeyInput=true hostPhysicalRightStickY=true hostPhysicalControllerAnalog=true hostPhysicalControllerCapture=true hostPhysicalKeyboardCapture=true hostPhysicalKeyboardNavigation=true hostPhysicalNativeInputHook=true hostPhysicalNativeListenerShadow=true hostPhysicalNativeListener=true hostSinglePhysicalInput=true runtimeNativeState=shared-observation-tracker runtimeAdmission=shared-policy inputBinding=shared inputConflict=shared inputCapture=shared+stickGate inputRepeat=shared inputRoute=shared inputAcceptance=shared settingsModel=shared settingsRender=shared settingsNavigation=shared settingsDetails=shared runtimeModalIsolation=shared-policy consumerRoles=explicit consumerRetirement=shared"
print(string.format("[MortalShell2ModUI] loaded version=%s api=%s\n", tostring(ModUI.VERSION), tostring(ModUI.API_VERSION)))

-- Primitive-only cross-mod metadata is safe with UE4SS ModRef shared variables. Pass 130 makes the proven canonical lease authoritative for host-owned native-listener activation/event publication while retaining bounded consumer fallback; Pass 129 established observational lease arbitration and Pass 125
-- promotes the Pass-124-proven WBP_InputListener to the healthy-path primary physical native
-- listener when a consumer explicitly publishes the host-listener token. Numeric exact-address
-- requests remain mutually-exclusive fallback compatibility; the game-owned menu mapping remains
-- untouched. Pass 117 supplied the one process-wide observation hook and Pass 108 the
-- permanent physical OPEN-HOTKEY poll in this standalone state.
pcall(function()
    if ModRef == nil or ModRef.SetSharedVariable == nil or ModRef.GetSharedVariable == nil then
        return
    end
    if ModUI.Host == nil
        or ModUI.Host.Protocol == nil
        or ModUI.Host.Registry == nil
        or ModUI.Host.Service == nil
        or ModUI.Host.MenuService == nil
        or ModUI.Host.InputService == nil
        or ModUI.Host.ShellService == nil then
        return
    end

    local Protocol = ModUI.Host.Protocol
    local epoch = string.format("%s:%s", tostring(os.time()), tostring({}):gsub("table: ", ""))
    -- Performance logging for the standalone host (Core/Perf.lua; PERFORMANCE_LOGGING.md).
    -- The host has no settings of its own, so it follows the consumers: once a second the
    -- poll reads each consumer's Protocol.PERF_KEYS flag and logs while any of them is 1.
    -- Emits ride on the permanent input poll (InputService.Poll -> perf.Tick()).
    local host_perf = ModUI.PerfFactory.New({
        mod = "ModUI",
        log = function(line) print("[MortalShell2ModUI] " .. tostring(line) .. "\n") end,
        clock = os.clock,
    })
    ModUI.Perf = host_perf
    local perf_sync_clock = nil
    local perf_sync_sources = ""
    local function sync_perf_from_consumers()
        local now = os.clock()
        if perf_sync_clock ~= nil and now - perf_sync_clock < 1.0 then return end
        perf_sync_clock = now
        local wanted, names = false, {}
        for name, key in pairs(Protocol.PERF_KEYS) do
            local ok, value = pcall(ModRef.GetSharedVariable, ModRef, key)
            if ok and (value == 1 or value == true or value == "1" or value == "true") then
                wanted = true
                names[#names + 1] = name
            end
        end
        table.sort(names)
        local sources = table.concat(names, "+")
        if host_perf.SetEnabled(wanted, wanted and ("consumer:" .. sources) or "consumers-off") then
            perf_sync_sources = sources
            -- The capability string moved off the startup line in v0.71.2; it goes out
            -- here instead, once, the first time a consumer turns logging on.
            if wanted and not capabilities_logged then
                capabilities_logged = true
                print("[MortalShell2ModUI] capabilities " .. CAPABILITIES .. "\n")
            end
        elseif wanted and sources ~= perf_sync_sources then
            perf_sync_sources = sources
            print("[MortalShell2ModUI] [PERF] ModUI logging sources=" .. sources .. "\n")
        end
    end

    -- Every shared-variable read/write is a cross-Lua-state call into UE4SS; counted
    -- as shared.get / shared.set. Exact counts, no timing.
    local function shared_get(name)
        if host_perf.enabled then host_perf.Count("shared.get") end
        return ModRef:GetSharedVariable(name)
    end
    local function shared_set(name, value)
        if host_perf.enabled then host_perf.Count("shared.set") end
        return ModRef:SetSharedVariable(name, value)
    end

    ModRef:SetSharedVariable("MortalShell2ModUI.Version", tostring(ModUI.VERSION))
    ModRef:SetSharedVariable("MortalShell2ModUI.ApiVersion", tonumber(ModUI.API_VERSION) or 0)
    ModRef:SetSharedVariable(Protocol.HostKey("Version"), tostring(ModUI.VERSION))
    ModRef:SetSharedVariable(Protocol.HostKey("ProtocolVersion"), tonumber(Protocol.VERSION) or 0)
    ModRef:SetSharedVariable(Protocol.HostKey("SlotCount"), tonumber(Protocol.SLOT_COUNT) or 0)
    ModRef:SetSharedVariable(Protocol.HostKey("Epoch"), epoch)
    ModRef:SetSharedVariable(Protocol.HostKey("State"), "registry-discovery")
    if ModRef:GetSharedVariable(Protocol.HostKey("RegistryRevision")) == nil then
        ModRef:SetSharedVariable(Protocol.HostKey("RegistryRevision"), 0)
    end
    ModRef:SetSharedVariable(Protocol.HostKey("AcknowledgedConsumers"), 0)
    ModRef:SetSharedVariable(Protocol.HostKey("MenuState"), "starting")
    ModRef:SetSharedVariable(Protocol.HostKey("MenuProviderCount"), 0)
    ModRef:SetSharedVariable(Protocol.HostKey("MenuProviderConsumer"), "")
    ModRef:SetSharedVariable(Protocol.HostKey("MenuProviderSlot"), -1)
    ModRef:SetSharedVariable(Protocol.HostKey("MenuProviderRevision"), 0)
    ModRef:SetSharedVariable(Protocol.HostKey("MenuProviderDisplay"), "")
    ModRef:SetSharedVariable(Protocol.HostKey("MenuProviderPages"), "")
    ModRef:SetSharedVariable(Protocol.HostKey("MenuProviderActions"), "")
    ModRef:SetSharedVariable(Protocol.HostKey("MenuHostEpoch"), epoch)
    ModRef:SetSharedVariable(Protocol.HostKey("MenuSessionState"), "idle")
    ModRef:SetSharedVariable(Protocol.HostKey("MenuSessionConsumer"), "")
    ModRef:SetSharedVariable(Protocol.HostKey("MenuSessionSlot"), -1)
    ModRef:SetSharedVariable(Protocol.HostKey("MenuSessionRevision"), 0)
    ModRef:SetSharedVariable(Protocol.HostKey("MenuSessionSequence"), 0)
    ModRef:SetSharedVariable(Protocol.HostKey("MenuSessionGeneration"), 0)
    ModRef:SetSharedVariable(Protocol.HostKey("MenuSessionReason"), "")
    ModRef:SetSharedVariable(Protocol.HostKey("MenuSessionHostEpoch"), epoch)
    ModRef:SetSharedVariable(Protocol.HostKey("MenuLeaseState"), "idle")
    ModRef:SetSharedVariable(Protocol.HostKey("MenuLeaseConsumer"), "")
    ModRef:SetSharedVariable(Protocol.HostKey("MenuLeaseSlot"), -1)
    ModRef:SetSharedVariable(Protocol.HostKey("MenuLeaseRevision"), 0)
    ModRef:SetSharedVariable(Protocol.HostKey("MenuLeaseSequence"), 0)
    ModRef:SetSharedVariable(Protocol.HostKey("MenuLeaseGeneration"), 0)
    ModRef:SetSharedVariable(Protocol.HostKey("MenuLeaseReason"), "")
    ModRef:SetSharedVariable(Protocol.HostKey("MenuLeaseHostEpoch"), epoch)
    ModRef:SetSharedVariable(Protocol.HostKey("MenuShellState"), "none")
    ModRef:SetSharedVariable(Protocol.HostKey("MenuShellConsumer"), "")
    ModRef:SetSharedVariable(Protocol.HostKey("MenuShellSlot"), -1)
    ModRef:SetSharedVariable(Protocol.HostKey("MenuShellRevision"), 0)
    ModRef:SetSharedVariable(Protocol.HostKey("MenuShellSequence"), 0)
    ModRef:SetSharedVariable(Protocol.HostKey("MenuShellGeneration"), 0)
    ModRef:SetSharedVariable(Protocol.HostKey("MenuShellAddress"), "")
    ModRef:SetSharedVariable(Protocol.HostKey("MenuShellReused"), false)
    ModRef:SetSharedVariable(Protocol.HostKey("MenuShellCacheToken"), 0)
    ModRef:SetSharedVariable(Protocol.HostKey("MenuShellReason"), "")
    ModRef:SetSharedVariable(Protocol.HostKey("MenuShellHostEpoch"), epoch)
    ModRef:SetSharedVariable(Protocol.HostKey("PhysicalHotkeyState"), "starting")
    ModRef:SetSharedVariable(Protocol.HostKey("PhysicalAnalogState"), "starting")
    ModRef:SetSharedVariable(Protocol.HostKey("PhysicalControllerCaptureState"), "starting")
    ModRef:SetSharedVariable(Protocol.HostKey("PhysicalKeyboardCaptureState"), "starting")
    ModRef:SetSharedVariable(Protocol.HostKey("PhysicalKeyboardNavigationState"), "starting")
    ModRef:SetSharedVariable(Protocol.HostKey("PhysicalNativeInputHookState"), "starting")
    ModRef:SetSharedVariable(Protocol.HostKey("PhysicalNativeListenerState"), "starting")
    ModRef:SetSharedVariable(Protocol.HostKey("PhysicalNativeListenerActive"), false)
    ModRef:SetSharedVariable(Protocol.HostKey("PhysicalNativeListenerAddress"), "")
    ModRef:SetSharedVariable(Protocol.HostKey("PhysicalNativeListenerEventCount"), 0)
    ModRef:SetSharedVariable(Protocol.HostKey("PhysicalNativeListenerSessionCount"), 0)
    ModRef:SetSharedVariable(Protocol.HostKey("NativeMenuHookState"), "starting")
    ModRef:SetSharedVariable(Protocol.HostKey("NativeMenuState"), "starting")
    ModRef:SetSharedVariable(Protocol.HostKey("NativeMenuActive"), false)
    ModRef:SetSharedVariable(Protocol.HostKey("NativeMenuSequence"), 0)
    ModRef:SetSharedVariable(Protocol.HostKey("NativeMenuReason"), "startup")
    if ModRef:GetSharedVariable(Protocol.HostKey("ControllerProfileRevision")) == nil then
        ModRef:SetSharedVariable(Protocol.HostKey("ControllerProfileRevision"), 0)
    end
    ModRef:SetSharedVariable(Protocol.HostKey("ControllerProfileSource"), "")
    ModRef:SetSharedVariable(Protocol.HostKey("ControllerProfileCalibrated"), false)
    ModRef:SetSharedVariable(Protocol.HostKey("ControllerProfileReason"), "startup")
    ModRef:SetSharedVariable(Protocol.HostKey("MenuActiveConsumer"), "")
    ModRef:SetSharedVariable(Protocol.HostKey("MenuProviderConsumers"), "")
    ModRef:SetSharedVariable(Protocol.HostKey("MenuHotkeyOwnerConsumer"), "")
    ModRef:SetSharedVariable(Protocol.HostKey("MenuHotkeyOwnerSlot"), -1)
    ModRef:SetSharedVariable(Protocol.HostKey("MenuHotkeyOwnerRevision"), 0)
    if ModRef:GetSharedVariable(Protocol.HostKey("MenuActiveConsumerRequest")) == nil then
        ModRef:SetSharedVariable(Protocol.HostKey("MenuActiveConsumerRequest"), "")
    end
    ModRef:SetSharedVariable(Protocol.HostKey("VisibleShellHostState"), "starting")
    ModRef:SetSharedVariable(Protocol.HostKey("VisibleShellHostConsumer"), "")
    ModRef:SetSharedVariable(Protocol.HostKey("VisibleShellHostSlot"), -1)
    ModRef:SetSharedVariable(Protocol.HostKey("VisibleShellHostRevision"), 0)
    ModRef:SetSharedVariable(Protocol.HostKey("VisibleShellHostGeneration"), 0)
    ModRef:SetSharedVariable(Protocol.HostKey("VisibleShellHostPresentationSequence"), 0)
    ModRef:SetSharedVariable(Protocol.HostKey("VisibleShellHostAddress"), "")
    ModRef:SetSharedVariable(Protocol.HostKey("VisibleShellHostMode"), "single-owner")

    local registry, registry_err = ModUI.Host.Registry.Bind(Protocol, shared_get, shared_set)
    if registry == nil then
        ModRef:SetSharedVariable(Protocol.HostKey("State"), "registry-error")
        print("[MortalShell2ModUI] Host.Registry bind failed: " .. tostring(registry_err) .. "\n")
        return
    end
    if type(registry.PublishControllerProfileState) == "function" then
        local profile = nil
        if type(ModUI.Controller.Profile.Reload) == "function" then
            profile = select(1, ModUI.Controller.Profile.Reload())
        end
        if type(profile) ~= "table" then profile = ModUI.Controller.Profile.Current() end
        local profile_state, profile_err = registry.PublishControllerProfileState(
            "MortalShell2ModUI", type(profile) == "table" and profile.calibrated == true, "host-startup")
        if type(profile_state) ~= "table" then
            print("[MortalShell2ModUI] controller profile sync startup failed: " .. tostring(profile_err) .. "\n")
        end
    end

    local service, service_err = ModUI.Host.Service.Bind(registry, Protocol)
    if service == nil then
        ModRef:SetSharedVariable(Protocol.HostKey("State"), "registry-error")
        print("[MortalShell2ModUI] Host.Service bind failed: " .. tostring(service_err) .. "\n")
        return
    end
    local menu_service, menu_service_err = ModUI.Host.MenuService.Bind(registry, Protocol)
    if menu_service == nil then
        ModRef:SetSharedVariable(Protocol.HostKey("MenuState"), "degraded")
        print("[MortalShell2ModUI] Host.MenuService bind failed: " .. tostring(menu_service_err) .. "\n")
        return
    end

    local provider_selector = nil
    local provider_selector_err = "Host.ProviderSelector unavailable"
    if type(ModUI.Host.ProviderSelector) == "table" and type(ModUI.Host.ProviderSelector.Bind) == "function" then
        provider_selector, provider_selector_err = ModUI.Host.ProviderSelector.Bind(registry, menu_service, {
            host_epoch = function() return epoch end,
            log = function(message) print("[MortalShell2ModUI] " .. tostring(message or "") .. "\n") end,
        })
    end
    -- v0.65 removes the legacy F8 provider selector. Each provider exposes and
    -- owns its own keyboard/controller binding, so opening a settings page no
    -- longer depends on hidden active-provider state.

    local shell_service, shell_service_err = ModUI.Host.ShellService.Bind(ModUI, registry, Protocol, {
        log = function(message)
            print("[MortalShell2ModUI] " .. tostring(message or "") .. "\n")
        end,
        diag = function(kind, fields)
            fields = type(fields) == "table" and fields or {}
            local parts = {}
            for key, value in pairs(fields) do parts[#parts + 1] = tostring(key) .. "=" .. tostring(value) end
            table.sort(parts)
            print("[MortalShell2ModUI] shell." .. tostring(kind or "diag") .. " " .. table.concat(parts, " ") .. "\n")
        end,
    })
    if shell_service == nil then
        ModRef:SetSharedVariable(Protocol.HostKey("VisibleShellHostState"), "degraded")
        print("[MortalShell2ModUI] Host.ShellService bind failed: " .. tostring(shell_service_err) .. "\n")
    else
        registry.PublishVisibleShellHostState({ state = "ready", mode = "single-owner" })
    end

    local last_visible_shell_signature = ""
    local function publish_visible_shell_report(report)
        report = type(report) == "table" and report or { state = "degraded", active = false }
        local payload = {
            state = tostring(report.state or (report.active and "active" or "ready")),
            consumer = tostring(report.consumer or ""),
            slot = math.floor(tonumber(report.slot) or -1),
            revision = math.max(0, math.floor(tonumber(report.revision) or 0)),
            generation = math.max(0, math.floor(tonumber(report.generation) or 0)),
            sequence = math.max(0, math.floor(tonumber(report.sequence) or 0)),
            address = tostring(report.address or ""),
            mode = tostring(report.mode or "single-owner"),
        }
        local ok_publish, publish_err = registry.PublishVisibleShellHostState(payload)
        if not ok_publish then
            ModRef:SetSharedVariable(Protocol.HostKey("VisibleShellHostState"), "degraded")
            return false, publish_err
        end
        local signature = table.concat({ payload.state, payload.consumer, tostring(payload.slot),
            tostring(payload.revision), tostring(payload.generation), tostring(payload.sequence),
            payload.address, payload.mode, tostring(report.error or "") }, "|")
        if signature ~= last_visible_shell_signature then
            last_visible_shell_signature = signature
            print(string.format(
                "[MortalShell2ModUI] visible shell host state=%s consumer=%s slot=%s revision=%s generation=%s presentation=%s address=%s mode=%s error=%s\n",
                payload.state, payload.consumer, tostring(payload.slot), tostring(payload.revision),
                tostring(payload.generation), tostring(payload.sequence), payload.address, payload.mode,
                tostring(report.error or "")))
        end
        return true
    end

    local function reconcile_menu_provider(registrations, label)
        local menu_report, menu_err = menu_service.Reconcile(registrations or {}, epoch)
        if menu_report == nil then
            ModRef:SetSharedVariable(Protocol.HostKey("MenuState"), "degraded")
            print("[MortalShell2ModUI] Host.MenuService reconcile failed label=" .. tostring(label)
                .. " error=" .. tostring(menu_err) .. "\n")
            return false, menu_err
        end
        if menu_report.changed == true then
            print(string.format(
                "[MortalShell2ModUI] host menu provider state=%s providers=%d consumer=%s slot=%s revision=%s pages=%s\n",
                tostring(menu_report.state),
                tonumber(menu_report.providerCount) or 0,
                tostring(menu_report.providerConsumer or ""),
                tostring(menu_report.providerSlot or ""),
                tostring(menu_report.providerRevision or ""),
                tostring(menu_report.providerPages or "")))
        end
        return true, menu_report
    end

    local acknowledged_consumers = {}
    local function run_discovery(label, force)
        local report, scan_err = service.ScanAndAcknowledge(epoch, force)
        if report == nil then
            ModRef:SetSharedVariable(Protocol.HostKey("State"), "registry-error")
            print("[MortalShell2ModUI] Host.Service scan failed label=" .. tostring(label) .. " error=" .. tostring(scan_err) .. "\n")
            return
        end
        for _, consumer in ipairs(report.consumers or {}) do
            acknowledged_consumers[tostring(consumer)] = true
        end
        local count = 0
        for _ in pairs(acknowledged_consumers) do count = count + 1 end
        ModRef:SetSharedVariable(Protocol.HostKey("ObservedRegistryRevision"), tonumber(report.registryRevision) or 0)
        ModRef:SetSharedVariable(Protocol.HostKey("AcknowledgedConsumers"), count)
        ModRef:SetSharedVariable(Protocol.HostKey("State"), count > 0 and "registry-ready" or "registry-discovery")
        reconcile_menu_provider(report.registrations or {}, label)

        if (tonumber(report.acknowledged) or 0) > 0 then
            print(string.format("[MortalShell2ModUI] host registry acknowledged label=%s consumers=%d revision=%s\n",
                tostring(label), count, tostring(report.registryRevision)))
        end
    end

    local function tick_menu_session()
        local report, tick_err = menu_service.Tick(epoch)
        if report == nil then return false, tick_err end
        local events = type(report.events) == "table" and report.events or {}
        for _, event in ipairs(events) do
            print(string.format(
                "[MortalShell2ModUI] host menu session state=%s consumer=%s slot=%s revision=%s generation=%s sequence=%s reason=%s\n",
                tostring(event.state or ""), tostring(event.consumer or ""), tostring(event.slot or ""),
                tostring(event.revision or ""), tostring(event.generation or ""),
                tostring(event.sequence or ""), tostring(event.reason or "")))
        end
        local lease = type(report.lease) == "table" and report.lease or nil
        if lease ~= nil and lease.changed == true then
            print(string.format(
                "[MortalShell2ModUI] host menu lease state=%s consumer=%s slot=%s revision=%s generation=%s sequence=%s reason=%s observational=true\n",
                tostring(lease.state or ""), tostring(lease.consumer or ""), tostring(lease.slot or ""),
                tostring(lease.revision or ""), tostring(lease.generation or ""),
                tostring(lease.sequence or ""), tostring(lease.reason or "")))
        end
        local shell = type(report.shell) == "table" and report.shell or nil
        if shell ~= nil and shell.changed == true then
            print(string.format(
                "[MortalShell2ModUI] host menu shell state=%s consumer=%s slot=%s revision=%s generation=%s sequence=%s address=%s reused=%s cacheToken=%s reason=%s observational=true\n",
                tostring(shell.state or ""), tostring(shell.consumer or ""), tostring(shell.slot or ""),
                tostring(shell.revision or ""), tostring(shell.generation or ""), tostring(shell.sequence or ""),
                tostring(shell.address or ""), tostring(shell.reused == true), tostring(shell.cacheToken or 0),
                tostring(shell.reason or "")))
        end
        if type(shell_service) == "table" and type(shell_service.Tick) == "function" then
            local selected = type(menu_service.Selected) == "function" and menu_service.Selected() or nil
            local providers = type(menu_service.Providers) == "function" and menu_service.Providers() or {}
            report.providerCount = type(providers) == "table" and #providers or 0
            report.providerIndex = 0
            report.providerDisplay = type(selected) == "table" and tostring(type(selected.fields) == "table" and selected.fields.display or selected.consumer or "") or ""
            for index, provider in ipairs(providers or {}) do
                if type(selected) == "table" and tostring(provider.consumer or "") == tostring(selected.consumer or "") then
                    report.providerIndex = index
                    break
                end
            end
            local shell_report = shell_service.Tick(report, selected)
            publish_visible_shell_report(shell_report)
        else
            publish_visible_shell_report({ state = "degraded", active = false, error = shell_service_err })
        end
        return report
    end

    local input_service = nil
    local semantic_service = nil
    local semantic_state_signature = ""
    -- `label`, when given, times the callback as schedule.<label>. The permanent input
    -- poll passes none: it is already the `poll` section.
    local function schedule_host_poll(delay_ms, callback, label)
        if ExecuteInGameThreadWithDelay == nil then return false end
        local scheduled = false
        local timed = callback
        if label ~= nil then
            local section = "schedule." .. tostring(label)
            timed = function()
                local token = host_perf.Begin()
                callback()
                host_perf.End(section, token)
            end
        end
        local ok = pcall(function()
            ExecuteInGameThreadWithDelay(delay_ms, timed)
            scheduled = true
        end)
        return ok and scheduled
    end

    -- The game owns the BPC_UserInterfaceHandler and its menus. This observer
    -- deliberately ignores every hook Context/parameter and publishes only a
    -- primitive transition latch. Consumers therefore do not need to poll or
    -- retain native UI objects while a menu is opening, active, or closing.
    local native_menu_gate = nil
    local native_menu_hook_ids = {}
    local native_menu_hook_status = "starting"
    local native_menu_publish_signature = ""
    local function publish_native_menu_snapshot(snapshot)
        snapshot = type(snapshot) == "table" and snapshot or {}
        ModRef:SetSharedVariable(Protocol.HostKey("NativeMenuState"), tostring(snapshot.state or "unavailable"))
        ModRef:SetSharedVariable(Protocol.HostKey("NativeMenuActive"), snapshot.active == true)
        ModRef:SetSharedVariable(Protocol.HostKey("NativeMenuSequence"), math.max(0, math.floor(tonumber(snapshot.sequence) or 0)))
        ModRef:SetSharedVariable(Protocol.HostKey("NativeMenuReason"), tostring(snapshot.reason or ""))
        local signature = table.concat({
            tostring(snapshot.state or ""), tostring(snapshot.active == true),
            tostring(snapshot.sequence or 0), tostring(snapshot.reason or ""),
            tostring(snapshot.openMenus or 0),
        }, "|")
        if signature ~= native_menu_publish_signature then
            native_menu_publish_signature = signature
            print(string.format(
                "[MortalShell2ModUI] native menu state=%s active=%s sequence=%s reason=%s openMenus=%s evictedMenus=%s primitiveOnly=true\n",
                tostring(snapshot.state or ""), tostring(snapshot.active == true),
                tostring(snapshot.sequence or 0), tostring(snapshot.reason or ""),
                tostring(snapshot.openMenus or 0), tostring(snapshot.evictedMenus or 0)))
        end
    end

    local gate_factory = ModUI.Runtime ~= nil and ModUI.Runtime.NativeMenuGate or nil
    if type(gate_factory) == "table" and type(gate_factory.New) == "function" then
        local ok_gate, gate_or_error = pcall(gate_factory.New, {
            publish = publish_native_menu_snapshot,
            schedule = schedule_host_poll,
            settle_ms = 1000,
        })
        if ok_gate and type(gate_or_error) == "table" then
            native_menu_gate = gate_or_error
        else
            native_menu_hook_status = "degraded"
            ModRef:SetSharedVariable(Protocol.HostKey("NativeMenuHookState"), "degraded")
            print("[MortalShell2ModUI] native menu gate initialization failed: "
                .. tostring(gate_or_error) .. "\n")
        end
    else
        native_menu_hook_status = "degraded"
        ModRef:SetSharedVariable(Protocol.HostKey("NativeMenuHookState"), "degraded")
    end

    -- WBP_Menu_Game_Tab owns the game's real bOpen state and exposes a balanced
    -- primitive UpdateOpenState(bool) boundary for every native game-tab menu.
    -- Use that lifecycle rather than handler-wide refresh events. The exact
    -- LandingArea open hook remains an early transition guard; the balanced base
    -- state hook authoritatively releases it when the widget closes.
    local NATIVE_MENU_HOOK_SPECS = {
        { asset = "/Game/Sparta/UI/Menu/WBP_Menu_Game_Tab", function_name = "UpdateOpenState", mode = "state", source = "game-tab-state", authoritative = true },
        { asset = "/Game/Sparta/UI/Menu/LandingArea/WBP_MGT_LandingArea", function_name = "OnMenuOpen", mode = "open", source = "landing-area", lease_ms = 15000 },
        { asset = "/Game/Sparta/UI/Menu/LandingArea/WBP_MGT_LandingArea", function_name = "OnMenuClose", mode = "close", source = "landing-area" },
        { asset = "/Game/Sparta/UI/Menu/LandingArea/WBP_MGT_LandingArea", function_name = "OnRemove", mode = "close", source = "landing-area" },
    }

    local function primitive_hook_bool(value)
        if type(value) == "boolean" then return value end
        local ok, unwrapped = pcall(function() return value:get() end)
        if ok and type(unwrapped) == "boolean" then return unwrapped end
        return nil
    end

    -- v0.68.4: primitive identity of the widget whose UpdateOpenState fired.
    -- Read inside the live callback only (address, no property access) and
    -- never retained; it keys nested game-tab menus (beacon -> level up).
    local function native_menu_instance_key(context)
        local ok, address = pcall(function() return context:get():GetAddress() end)
        if ok and type(address) == "number" and address ~= 0 then
            return string.format("%X", address)
        end
        return nil
    end

    local function native_menu_hook_path(spec)
        local class_name = tostring(spec.asset or ""):match("([^/]+)$")
        if class_name == nil then return nil end
        return tostring(spec.asset) .. "." .. class_name .. "_C:" .. tostring(spec.function_name)
    end

    local function arm_native_menu_hooks()
        if type(native_menu_gate) ~= "table" then return false, "gate-unavailable" end
        if RegisterHook == nil or LoadAsset == nil then return false, "hook-api-unavailable" end
        local loaded_assets = {}
        local armed = 0
        for _, spec in ipairs(NATIVE_MENU_HOOK_SPECS) do
            local hook_path = native_menu_hook_path(spec)
            if hook_path ~= nil and native_menu_hook_ids[hook_path] == nil then
                local asset_ready = loaded_assets[spec.asset]
                if asset_ready == nil then
                    local ok_load, loaded = pcall(function() return LoadAsset(spec.asset) end)
                    asset_ready = ok_load and loaded ~= nil
                    loaded_assets[spec.asset] = asset_ready
                end
                if asset_ready then
                    local hook_mode = tostring(spec.mode or "")
                    local hook_source = tostring(spec.source or "native-ui")
                    local hook_authoritative = spec.authoritative == true
                    local hook_lease_ms = math.max(0, math.floor(tonumber(spec.lease_ms) or 0))
                    local hook_section = "hook.native-menu." .. tostring(spec.function_name or hook_mode)
                    local hook_body
                    local callback = function(context, state_value)
                        local token = host_perf.Begin()
                        hook_body(context, state_value)
                        host_perf.End(hook_section, token)
                    end
                    hook_body = function(context, state_value)
                        if hook_mode == "state" then
                            local open_state = primitive_hook_bool(state_value)
                            local instance = native_menu_instance_key(context)
                            if open_state == true then
                                if instance ~= nil then
                                    pcall(native_menu_gate.OpenInstance, hook_source, instance)
                                else
                                    pcall(native_menu_gate.Open, hook_source, 0)
                                end
                            elseif open_state == false then
                                if instance ~= nil then
                                    pcall(native_menu_gate.CloseInstance, hook_source, instance)
                                else
                                    pcall(native_menu_gate.Close, hook_source, hook_authoritative)
                                end
                            end
                        elseif hook_mode == "open" then
                            pcall(native_menu_gate.Open, hook_source, hook_lease_ms)
                        else
                            pcall(native_menu_gate.Close, hook_source, hook_authoritative)
                        end
                    end
                    local ok_register, pre_id, post_id
                    if hook_mode == "close" then
                        ok_register, pre_id, post_id = pcall(RegisterHook,
                            hook_path, function() end, callback)
                    else
                        ok_register, pre_id, post_id = pcall(RegisterHook, hook_path, callback)
                    end
                    if ok_register and (pre_id ~= nil or post_id ~= nil) then
                        native_menu_hook_ids[hook_path] = {
                            pre = pre_id, post = post_id, callback = callback,
                        }
                    end
                end
            end
            if hook_path ~= nil and native_menu_hook_ids[hook_path] ~= nil then armed = armed + 1 end
        end

        local landing_asset = "/Game/Sparta/UI/Menu/LandingArea/WBP_MGT_LandingArea"
        local landing_class = ".WBP_MGT_LandingArea_C:"
        local game_tab_asset = "/Game/Sparta/UI/Menu/WBP_Menu_Game_Tab"
        local state_ready = native_menu_hook_ids[
            game_tab_asset .. ".WBP_Menu_Game_Tab_C:UpdateOpenState"] ~= nil
        local open_ready = native_menu_hook_ids[landing_asset .. landing_class .. "OnMenuOpen"] ~= nil
        local close_ready = native_menu_hook_ids[landing_asset .. landing_class .. "OnMenuClose"] ~= nil
            or native_menu_hook_ids[landing_asset .. landing_class .. "OnRemove"] ~= nil
        local lifecycle_ready = state_ready and open_ready
        local status = lifecycle_ready and (armed == #NATIVE_MENU_HOOK_SPECS and "ready" or "partial") or "starting"
        if status ~= native_menu_hook_status then
            native_menu_hook_status = status
            ModRef:SetSharedVariable(Protocol.HostKey("NativeMenuHookState"), status)
            print(string.format(
                "[MortalShell2ModUI] native menu hooks state=%s armed=%d total=%d baseOpenState=%s landingOpen=%s landingCloseFallback=%s boundedFallbackLeaseMs=15000\n",
                status, armed, #NATIVE_MENU_HOOK_SPECS, tostring(state_ready),
                tostring(open_ready), tostring(close_ready)))
        end
        if lifecycle_ready then pcall(native_menu_gate.Ready, "hooks-" .. status) end
        return lifecycle_ready, status
    end

    local function schedule_native_menu_hook_arm()
        if type(native_menu_gate) ~= "table" then return false end
        local retry_delays = { 100, 300, 750, 1500, 3000, 5000 }
        local scheduled_any = false
        for index, delay_ms in ipairs(retry_delays) do
            local scheduled = schedule_host_poll(delay_ms, function()
                local ready, status = arm_native_menu_hooks()
                if ready and status == "ready" then return end
                if index == #retry_delays and not ready then
                    native_menu_hook_status = "degraded"
                    ModRef:SetSharedVariable(Protocol.HostKey("NativeMenuHookState"), "degraded")
                    pcall(native_menu_gate.Degraded, "landing-area-hook-lifecycle-unavailable")
                    print("[MortalShell2ModUI] native menu hooks degraded after bounded retries\n")
                end
            end, "native-menu-hook-arm")
            scheduled_any = scheduled_any or scheduled
        end
        return scheduled_any
    end

    schedule_native_menu_hook_arm()
    -- Pass 131 performance corrective: the standalone host used to resolve
    -- BP_PlayerCharacter_C through FindFirstOf on every nominal 50 ms input poll.
    -- Retain only the PlayerController wrapper, validate it before use, and perform
    -- authoritative local-PlayerController resolution only on cache miss/world transition.
    -- This mirrors the already-proven consumer-side controller cache and removes
    -- a game-thread world search from the permanent idle hotkey cadence.
    local host_controller_cache = nil
    local host_controller_cache_hits = 0
    local host_controller_cache_misses = 0
    local function host_controller()
        local cached = ModUI.Object.Unwrap(host_controller_cache)
        if ModUI.Object.Valid(cached) then
            host_controller_cache_hits = host_controller_cache_hits + 1
            return cached
        end

        host_controller_cache = nil
        host_controller_cache_misses = host_controller_cache_misses + 1
        local token = host_perf.Begin()
        local _, controller, _, resolver = ModUI.Runtime.Resolve.PlayerController(FindFirstOf, FindAllOf)
        host_perf.End("native.resolve-controller", token)
        controller = ModUI.Object.Unwrap(controller)
        if ModUI.Object.Valid(controller) then
            host_controller_cache = controller
            if host_controller_cache_misses <= 5 then
                print("[MortalShell2ModUI] host controller cache acquired"
                    .. " resolver=" .. tostring(resolver or "unknown")
                    .. " misses=" .. tostring(host_controller_cache_misses)
                    .. " hits=" .. tostring(host_controller_cache_hits) .. "\n")
            end
            return controller
        end
        return nil
    end

    -- Pass 125 promotes the Pass-124-proven standalone listener to the primary physical
    -- WBP_InputListener for consumers that explicitly request host ownership. The same
    -- object lifecycle remains host-owned; only host-token requests create/retain it.
    -- Numeric consumer-listener requests are still supported by Host.InputService as a
    -- guarded fallback and do not create a duplicate host listener.
    local host_native_listener_shadow = {
        listener = nil,
        address = nil,
        accepted_original = nil,
        accepted_changed = false,
        event_count = 0,
        session_count = 0,
        active_requests = 0,
        last_failure = "",
        route_by_enum = {},
    }

    local HOST_NATIVE_LISTENER_ASSET = "/Game/Sparta/UI/Core/Navigation/WBP_InputListener"
    local HOST_NATIVE_LISTENER_CLASS = "/Game/Sparta/UI/Core/Navigation/WBP_InputListener.WBP_InputListener_C"
    local HOST_WIDGET_LIBRARY_CDO = "/Script/UMG.Default__WidgetBlueprintLibrary"
    local HOST_BPFL_UI_ASSET = "/Game/Sparta/UI/Core/BPFL_UI"
    local HOST_BPFL_UI_CDO = "/Game/Sparta/UI/Core/BPFL_UI.Default__BPFL_UI_C"

    local function publish_host_native_listener_state(state, active, address)
        ModRef:SetSharedVariable(Protocol.HostKey("PhysicalNativeListenerState"), tostring(state or "ready"))
        ModRef:SetSharedVariable(Protocol.HostKey("PhysicalNativeListenerActive"), active == true)
        ModRef:SetSharedVariable(Protocol.HostKey("PhysicalNativeListenerAddress"), tostring(address or ""))
        ModRef:SetSharedVariable(Protocol.HostKey("PhysicalNativeListenerEventCount"),
            tonumber(host_native_listener_shadow.event_count) or 0)
        ModRef:SetSharedVariable(Protocol.HostKey("PhysicalNativeListenerSessionCount"),
            tonumber(host_native_listener_shadow.session_count) or 0)
    end

    local function host_native_listener_cleanup(reason)
        local listener = ModUI.Object.Unwrap(host_native_listener_shadow.listener)
        if ModUI.Object.Valid(listener) then
            local disabled = ModUI.Runtime.Listener.DisableBindings(listener)
            local restored = ModUI.Runtime.Listener.RestoreAcceptedInputs(
                listener,
                host_native_listener_shadow.accepted_original,
                host_native_listener_shadow.accepted_changed == true)
            local removed = ModUI.Runtime.Bridge.RemoveListener(listener)
            print(string.format(
                "[MortalShell2ModUI] host native listener primary retired reason=%s address=%s events=%d disable=%s restore=%s remove=%s\n",
                tostring(reason or "inactive"),
                tostring(host_native_listener_shadow.address or ""),
                tonumber(host_native_listener_shadow.event_count) or 0,
                tostring(type(disabled) == "table" and disabled.status or "invalid"),
                tostring(type(restored) == "table" and restored.status or "invalid"),
                tostring(type(removed) == "table" and removed.status or "invalid")))
        end
        host_native_listener_shadow.listener = nil
        host_native_listener_shadow.address = nil
        host_native_listener_shadow.accepted_original = nil
        host_native_listener_shadow.accepted_changed = false
        host_native_listener_shadow.event_count = 0
        host_native_listener_shadow.route_by_enum = {}
        publish_host_native_listener_state("ready", false, "")
    end

    local function host_native_listener_open()
        if ModUI.Object.Valid(ModUI.Object.Unwrap(host_native_listener_shadow.listener)) then
            return true, "already-active"
        end
        local player, controller = ModUI.Runtime.Resolve.PlayerController(FindFirstOf, FindAllOf)
        player = ModUI.Object.Unwrap(player)
        controller = ModUI.Object.Unwrap(controller)
        if not ModUI.Object.Valid(player) or not ModUI.Object.Valid(controller) then
            return false, "player/controller-invalid"
        end

        local handler, handler_meta = ModUI.Runtime.Resolve.UIHandlerWithFallback(player, {
            LoadAsset = LoadAsset,
            StaticFindObject = StaticFindObject,
            FindFirstOf = FindFirstOf,
            BPFLAsset = HOST_BPFL_UI_ASSET,
            BPFLCdo = HOST_BPFL_UI_CDO,
        })
        handler = ModUI.Object.Unwrap(handler)
        if not ModUI.Object.Valid(handler) then
            return false, "ui-handler-invalid:" .. tostring(type(handler_meta) == "table" and handler_meta.status or "unknown")
        end

        local library, listener_class = nil, nil
        local load_ok = pcall(function()
            if LoadAsset ~= nil then LoadAsset(HOST_NATIVE_LISTENER_ASSET) end
            if StaticFindObject ~= nil then
                library = ModUI.Object.Unwrap(StaticFindObject(HOST_WIDGET_LIBRARY_CDO))
                listener_class = ModUI.Object.Unwrap(StaticFindObject(HOST_NATIVE_LISTENER_CLASS))
            end
        end)
        if not load_ok or not ModUI.Object.Valid(library) or not ModUI.Object.Valid(listener_class) then
            return false, "listener-class/library-unavailable"
        end

        local created = ModUI.Runtime.Bridge.CreateListener(player, controller, library, listener_class)
        created = type(created) == "table" and created or { ok = false, status = "invalid-create-result" }
        local listener = ModUI.Object.Unwrap(created.listener)
        if not created.ok or not ModUI.Object.Valid(listener) then
            return false, "create-" .. tostring(created.status or "failed")
        end
        host_native_listener_shadow.listener = listener

        local function fail(stage)
            host_native_listener_cleanup("open-failed-" .. tostring(stage))
            return false, tostring(stage)
        end

        local attached = ModUI.Runtime.Bridge.AttachViewport(listener, 9998)
        if type(attached) ~= "table" or attached.ok ~= true then
            return fail("attach-" .. tostring(type(attached) == "table" and attached.status or "invalid"))
        end

        local handler_result = ModUI.Runtime.Bridge.EnsureHandler(listener, handler)
        if type(handler_result) ~= "table" or handler_result.ok ~= true then
            return fail("handler-" .. tostring(type(handler_result) == "table" and handler_result.status or "invalid"))
        end

        local routes = ModUI.Runtime.Listener.BuildRoutes(listener, 0, 32)
        local desired = type(routes) == "table" and routes.accepted or nil
        if type(desired) ~= "table" or #desired == 0 then
            return fail("routes-empty")
        end

        local accepted = ModUI.Runtime.Listener.ConfigureAcceptedInputs(listener, desired)
        if type(accepted) ~= "table" or accepted.ok ~= true then
            return fail("accepted-" .. tostring(type(accepted) == "table" and accepted.status or "invalid"))
        end
        host_native_listener_shadow.accepted_original = accepted.original
        host_native_listener_shadow.accepted_changed = accepted.changed == true
        host_native_listener_shadow.route_by_enum = type(routes.routeByEnum) == "table" and routes.routeByEnum or {}

        local enabled = ModUI.Runtime.Listener.EnableBindings(listener)
        if type(enabled) ~= "table" or enabled.ok ~= true then
            return fail("bindings-" .. tostring(type(enabled) == "table" and enabled.status or "invalid"))
        end

        local address = ModUI.Object.Address(listener)
        if tonumber(address) == nil then return fail("address-unavailable") end
        host_native_listener_shadow.address = string.format("%.0f", tonumber(address))
        host_native_listener_shadow.event_count = 0
        host_native_listener_shadow.session_count = (tonumber(host_native_listener_shadow.session_count) or 0) + 1

        local handles = nil
        pcall(function()
            handles = select(1, ModUI.Runtime.Observation.ListenerInputHandleCount(listener))
        end)
        publish_host_native_listener_state("active", true, host_native_listener_shadow.address)
        print(string.format(
            "[MortalShell2ModUI] host native listener primary armed session=%d address=%s accepted=%d handles=%s handler=%s\n",
            host_native_listener_shadow.session_count,
            tostring(host_native_listener_shadow.address),
            #desired,
            tostring(handles or "unknown"),
            tostring(ModUI.Object.Name(handler))))
        return true, "active"
    end

    local function host_native_listener_shadow_tick(active_requests)
        active_requests = math.max(0, math.floor(tonumber(active_requests) or 0))
        host_native_listener_shadow.active_requests = active_requests
        local listener = ModUI.Object.Unwrap(host_native_listener_shadow.listener)
        if active_requests > 0 then
            if not ModUI.Object.Valid(listener) then
                local ok_open, status = host_native_listener_open()
                if not ok_open and tostring(status) ~= tostring(host_native_listener_shadow.last_failure) then
                    host_native_listener_shadow.last_failure = tostring(status)
                    print("[MortalShell2ModUI] host native listener shadow pending status=" .. tostring(status) .. "\n")
                end
            end
        elseif ModUI.Object.Valid(listener) then
            host_native_listener_cleanup("no-active-native-requests")
        end
    end

    local function observe_host_native_listener_shadow(address, input_number)
        if tostring(address or "") ~= tostring(host_native_listener_shadow.address or "") then return false end
        host_native_listener_shadow.event_count = (tonumber(host_native_listener_shadow.event_count) or 0) + 1
        ModRef:SetSharedVariable(Protocol.HostKey("PhysicalNativeListenerEventCount"),
            host_native_listener_shadow.event_count)
        print(string.format(
            "[MortalShell2ModUI] host native listener primary event sequence=%d input=%d address=%s\n",
            host_native_listener_shadow.event_count,
            math.floor(tonumber(input_number) or -1),
            tostring(host_native_listener_shadow.address or "")))
        return true
    end
    local function host_native_listener_address()
        return host_native_listener_shadow.address
    end
    local function host_native_listener_route(input_number, address)
        if tostring(address or "") ~= tostring(host_native_listener_shadow.address or "") then return nil end
        return type(host_native_listener_shadow.route_by_enum) == "table"
            and host_native_listener_shadow.route_by_enum[math.floor(tonumber(input_number) or -1)] or nil
    end
    local function register_host_keyboard_navigation(dispatch)
        if RegisterKeyBind == nil or Key == nil or type(dispatch) ~= "function" then return false end
        local bindings = {
            { key = Key.UP_ARROW, action = "up", source = "UpArrow" },
            { key = Key.DOWN_ARROW, action = "down", source = "DownArrow" },
            { key = Key.LEFT_ARROW, action = "left", source = "LeftArrow" },
            { key = Key.RIGHT_ARROW, action = "right", source = "RightArrow" },
            { key = Key.RETURN, action = "enter", source = "Return" },
            { key = Key.TAB, action = "tab", source = "Tab" },
            { key = Key.A, action = "a", source = "A" },
            { key = Key.D, action = "d", source = "D" },
            { key = Key.PAGE_UP, action = "page-up", source = "PageUp" },
            { key = Key.PAGE_DOWN, action = "page-down", source = "PageDown" },
            { key = Key.ESCAPE, action = "escape", source = "Escape" },
        }
        for _, binding_spec in ipairs(bindings) do
            if binding_spec.key == nil then return false end
            local ok = pcall(function()
                RegisterKeyBind(binding_spec.key, function()
                    local token = host_perf.Begin()
                    dispatch(binding_spec.action, binding_spec.source)
                    host_perf.End("keybind.navigation", token)
                end)
            end)
            if not ok then return false end
        end
        return true
    end

    -- Pass 122 corrective: Pass 121 proved that direct PlayerController out-parameter
    -- mouse/viewport reads can be empty from the standalone ModUI Lua state even while
    -- TTS's consumer-local BPFL_UI/layout pointer resolver is healthy. Prefer the same
    -- game-native BPFL_UI normalized location and WidgetLayoutLibrary paths here, keeping
    -- PlayerController out-parameters only as the final fallback. This remains observation
    -- only: pointer semantics are still consumer-local.
    local pointer_snapshot_failure_logged = false
    local function host_pointer_snapshot()
        local controller = ModUI.Object.Unwrap(host_controller())
        if not ModUI.Object.Valid(controller) then
            if not pointer_snapshot_failure_logged then
                pointer_snapshot_failure_logged = true
                print("[MortalShell2ModUI] host pointer snapshot unavailable reason=controller-invalid\n")
            end
            return nil
        end

        local function finite(value)
            value = tonumber(ModUI.Object.Unwrap(value))
            return value ~= nil and value == value
                and value > -1000000000.0 and value < 1000000000.0 and value or nil
        end
        local function direct_struct_number(value, names)
            if value == nil then return nil end
            local function probe(candidate)
                if candidate == nil then return nil end
                for _, name in ipairs(names or {}) do
                    local raw = nil
                    pcall(function() raw = candidate[name] end)
                    local number = finite(raw)
                    if number ~= nil then return number end
                end
                return nil
            end
            local number = probe(value)
            if number ~= nil then return number end
            local unwrapped = ModUI.Object.Unwrap(value)
            if unwrapped ~= value then return probe(unwrapped) end
            return nil
        end
        local function output_number(holder, names)
            if type(holder) ~= "table" then return finite(holder) end
            for _, name in ipairs(names or {}) do
                local candidate = nil
                pcall(function() candidate = holder[name] end)
                candidate = finite(candidate)
                if candidate ~= nil then return candidate end
            end
            for _, candidate in pairs(holder) do
                candidate = finite(candidate)
                if candidate ~= nil then return candidate end
            end
            return nil
        end

        local errors = {}

        -- Preferred route: the same cooked BPFL_UI normalized pointer API already proven
        -- by MortalShell2TTS's local pointer resolver. Publish reference-space coordinates
        -- as a 1920x1080 logical snapshot so the primitive protocol stays unchanged.
        local bpfl_asset = "/Game/Sparta/UI/Core/BPFL_UI"
        local bpfl_cdo = "/Game/Sparta/UI/Core/BPFL_UI.Default__BPFL_UI_C"
        local bpfl = nil
        pcall(function()
            if LoadAsset ~= nil then LoadAsset(bpfl_asset) end
            if StaticFindObject ~= nil then bpfl = ModUI.Object.Unwrap(StaticFindObject(bpfl_cdo)) end
        end)
        if ModUI.Object.Valid(bpfl) and bpfl["GetNormalizedMouseLocation"] ~= nil then
            for _, factor_viewport_scale in ipairs({ true, false }) do
                local ok_point, point = pcall(function()
                    return bpfl:GetNormalizedMouseLocation(factor_viewport_scale, false, controller)
                end)
                if ok_point and point ~= nil then
                    local nx = direct_struct_number(point, { "X" })
                    local ny = direct_struct_number(point, { "Y" })
                    if nx ~= nil and ny ~= nil
                        and math.abs(nx) <= 2.0 and math.abs(ny) <= 2.0
                        and not (nx == 0.0 and ny == 0.0) then
                        return {
                            x = (nx + 1.0) * 960.0,
                            y = (ny + 1.0) * 540.0,
                            width = 1920.0,
                            height = 1080.0,
                            source = factor_viewport_scale
                                and "BPFL_UI-normalized-dpi-reference"
                                or "BPFL_UI-normalized-logical-reference",
                        }
                    end
                end
            end
            errors[#errors + 1] = "bpfl-normalized-empty"
        else
            errors[#errors + 1] = "bpfl-unavailable"
        end

        -- Secondary route: WidgetLayoutLibrary supplies logical viewport pointer/size
        -- without relying on UE4SS output-parameter table mutation.
        local layout = nil
        pcall(function()
            if StaticFindObject ~= nil then
                layout = ModUI.Object.Unwrap(StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary"))
            end
        end)
        if ModUI.Object.Valid(layout) then
            local ok_pointer, point = pcall(function() return layout:GetMousePositionOnViewport(controller) end)
            local ok_viewport, viewport = pcall(function() return layout:GetViewportSize(controller) end)
            if ok_pointer and point ~= nil and ok_viewport and viewport ~= nil then
                local x = direct_struct_number(point, { "X" })
                local y = direct_struct_number(point, { "Y" })
                local width = direct_struct_number(viewport, { "X", "Width" })
                local height = direct_struct_number(viewport, { "Y", "Height" })
                local scale = 1.0
                pcall(function()
                    local candidate = finite(layout:GetViewportScale(controller))
                    if candidate ~= nil and candidate > 0.0 then scale = candidate end
                end)
                if x ~= nil and y ~= nil and width ~= nil and height ~= nil
                    and width > 0.0 and height > 0.0
                    and not (x == 0.0 and y == 0.0) then
                    local logical_width = width / scale
                    local logical_height = height / scale
                    if logical_width > 0.0 and logical_height > 0.0 then
                        return {
                            x = x, y = y,
                            width = logical_width, height = logical_height,
                            source = "WidgetLayoutLibrary-controller-context",
                        }
                    end
                end
            end
            errors[#errors + 1] = "layout-pointer-empty"
        else
            errors[#errors + 1] = "layout-unavailable"
        end

        -- Final fallback: retain Pass 121's direct PlayerController out-parameter path.
        local mouse_x_out, mouse_y_out = {}, {}
        local mouse_ok, mouse_available = pcall(function()
            return ModUI.Object.Unwrap(controller:GetMousePosition(mouse_x_out, mouse_y_out))
        end)
        if mouse_ok and mouse_available ~= false then
            local x = output_number(mouse_x_out, { "LocationX", "X" })
            local y = output_number(mouse_y_out, { "LocationY", "Y" })
            if x ~= nil and y ~= nil then
                local width_out, height_out = {}, {}
                local viewport_ok = pcall(function() controller:GetViewportSize(width_out, height_out) end)
                if viewport_ok then
                    local width = output_number(width_out, { "SizeX", "X", "Width" })
                    local height = output_number(height_out, { "SizeY", "Y", "Height" })
                    if width ~= nil and height ~= nil and width > 0.0 and height > 0.0 then
                        return {
                            x = x, y = y, width = width, height = height,
                            source = "PlayerController-out-params-fallback",
                        }
                    end
                end
            end
        end
        errors[#errors + 1] = "controller-out-params-empty"

        if not pointer_snapshot_failure_logged then
            pointer_snapshot_failure_logged = true
            print("[MortalShell2ModUI] host pointer snapshot unavailable reasons="
                .. table.concat(errors, "|") .. "\n")
        end
        return nil
    end

    -- v0.70.0: the visible shell resolves the pointer against the layout it drew, so a
    -- click lands on the tab or row the host rendered, not on a consumer-side model of
    -- it. The consumer receives hitKind / hitIndex / hitDirection on the input event.
    do
        local host_pointer_snapshot_raw = host_pointer_snapshot
        host_pointer_snapshot = function()
            local snapshot = host_pointer_snapshot_raw()
            if type(snapshot) == "table" and type(shell_service) == "table"
                and type(shell_service.ResolvePointer) == "function" then
                local ok, hit = pcall(shell_service.ResolvePointer, snapshot)
                if ok and type(hit) == "table" then
                    snapshot.hitKind = tostring(hit.kind or "")
                    snapshot.hitIndex = tonumber(hit.index)
                    snapshot.hitDirection = tonumber(hit.direction)
                end
            end
            return snapshot
        end
    end

    local native_input_hook_ids = nil
    local native_input_hook_terminal = false
    local PROCESS_WIDE_NATIVE_INPUT_HOOK_ISOLATION = true -- Pass 151 rollback after Pass-150 CBADB8CF recurrence
    local function arm_native_input_observer()
        if native_input_hook_ids ~= nil then
            return true, "already-armed"
        end
        if type(input_service) ~= "table" or type(input_service.PublishNativeInput) ~= "function" then
            return false, "input-service-unavailable"
        end
        if RegisterHook == nil or LoadAsset == nil then
            return false, "hook-api-unavailable"
        end
        local listener_asset = "/Game/Sparta/UI/Core/Navigation/WBP_InputListener"
        local hook_path = "/Game/Sparta/UI/Core/Navigation/WBP_InputListener.WBP_InputListener_C:InputTriggeredCallback"
        local load_ok, loaded = pcall(function() return LoadAsset(listener_asset) end)
        if not load_ok or loaded == nil then
            return false, "listener-asset-load-failed:" .. tostring(loaded)
        end
        local callback = function(Context, Input)
            local token = host_perf.Begin()
            local context = ModUI.Object.Unwrap(Context)
            local address = ModUI.Object.Address(context)
            local input_number = tonumber(ModUI.Object.Unwrap(Input))
            if tonumber(address) ~= nil and input_number ~= nil then
                pcall(observe_host_native_listener_shadow, string.format("%.0f", tonumber(address)), input_number)
                local ok_publish, publish_err = pcall(input_service.PublishNativeInput, address, input_number)
                if not ok_publish then
                    print("[MortalShell2ModUI] native input mirror publish exception: " .. tostring(publish_err) .. "\\n")
                end
            end
            host_perf.End("hook.native-input", token)
        end
        local register_ok, pre_id, post_id = pcall(RegisterHook, hook_path, callback)
        if not register_ok or (pre_id == nil and post_id == nil) then
            return false, "register-hook-failed:" .. tostring(pre_id)
        end
        native_input_hook_ids = { pre = pre_id, post = post_id, callback = callback }
        native_input_hook_terminal = true
        _G.MortalShell2ModUIRuntime = _G.MortalShell2ModUIRuntime or {}
        _G.MortalShell2ModUIRuntime.nativeInputMirrorHook = native_input_hook_ids
        return true, "armed"
    end

    -- LoadAsset/RegisterHook may run before UGameEngine::Tick has initialized UE4SS's
    -- game-thread identity when a standalone mod is loaded very early. Pass 117 treated
    -- that transient startup state as terminal degradation. Keep the capability in
    -- "starting" and retry only from delayed game-thread callbacks; once armed, force a
    -- fresh registry acknowledgement so consumers can observe physicalNativeInputHookHost=true.
    local function schedule_native_input_observer_arm()
        if PROCESS_WIDE_NATIVE_INPUT_HOOK_ISOLATION then
            print("[MortalShell2ModUI] process-wide native input mirror intentionally isolated by runtime flag\n")
            return false
        end
        local retry_delays = { 100, 300, 750, 1500, 3000, 5000 }
        local scheduled_any = false
        for index, delay_ms in ipairs(retry_delays) do
            local callback = function()
                if native_input_hook_ids ~= nil or native_input_hook_terminal then return end
                local armed, status = arm_native_input_observer()
                if armed then
                    ModRef:SetSharedVariable(Protocol.HostKey("PhysicalNativeInputHookState"), "ready")
                    print("[MortalShell2ModUI] native input mirror hook armed retry=" .. tostring(index) .. " delayMs=" .. tostring(delay_ms) .. " status=" .. tostring(status) .. "\\n")
                    run_discovery("native-hook-ready", true)
                    return
                end

                local terminal = index == #retry_delays
                if terminal then
                    native_input_hook_terminal = true
                    ModRef:SetSharedVariable(Protocol.HostKey("PhysicalNativeInputHookState"), "degraded")
                    print("[MortalShell2ModUI] native input mirror hook degraded after retries status=" .. tostring(status) .. "\\n")
                    run_discovery("native-hook-degraded", true)
                else
                    ModRef:SetSharedVariable(Protocol.HostKey("PhysicalNativeInputHookState"), "starting")
                    print("[MortalShell2ModUI] native input mirror hook retry pending retry=" .. tostring(index) .. " delayMs=" .. tostring(delay_ms) .. " status=" .. tostring(status) .. "\\n")
                end
            end
            if schedule_host_poll(delay_ms, callback, "native-input-observer-arm") then
                scheduled_any = true
            elseif index == #retry_delays and native_input_hook_ids == nil then
                native_input_hook_terminal = true
                ModRef:SetSharedVariable(Protocol.HostKey("PhysicalNativeInputHookState"), "degraded")
                print("[MortalShell2ModUI] native input mirror hook retry scheduling failed delayMs=" .. tostring(delay_ms) .. "\\n")
            end
        end
        return scheduled_any
    end

    local input_factory = ModUI.Host.InputService
    local physical_binding = ModUI.Runtime ~= nil and ModUI.Runtime.PhysicalBinding or nil
    if type(input_factory) == "table" and type(input_factory.Bind) == "function" and type(physical_binding) == "table" then
        local fname_adapter = function(value) return FName(value) end
        local service_instance, input_err = input_factory.Bind(
            registry, service, Protocol, physical_binding, ModUI.Input.Binding, {
                host_epoch = epoch,
                get_controller = host_controller,
                invalidate_controller_cache = function(reason)
                    local had_cache = host_controller_cache ~= nil
                    host_controller_cache = nil
                    if had_cache then
                        print("[MortalShell2ModUI] host controller cache cleared reason="
                            .. tostring(reason or "unspecified") .. "\n")
                    end
                    return true
                end,
                schedule = schedule_host_poll,
                unwrap = ModUI.Object.Unwrap,
                valid = ModUI.Object.Valid,
                fname = fname_adapter,
                controller_analog = ModUI.Runtime.ControllerAnalog,
                controller_profile = ModUI.Controller.Profile, -- policy only; raw acquisition stays profile-agnostic
                register_navigation_bindings = register_host_keyboard_navigation,
                capture_pointer_snapshot = host_pointer_snapshot,
                native_listener_shadow_tick = host_native_listener_shadow_tick,
                menu_registry_reconcile = function(registrations)
                    return reconcile_menu_provider(registrations, "input-registry-refresh")
                end,
                menu_session_tick = tick_menu_session,
                perf = host_perf,
                perf_sync = sync_perf_from_consumers,
                menu_active_consumer = function()
                    return type(menu_service.Selected) == "function" and menu_service.Selected() or nil
                end,
                menu_hotkey_owner = function()
                    return type(menu_service.HotkeyOwner) == "function" and menu_service.HotkeyOwner() or nil
                end,
                native_semantic_tick = function(menu_report)
                    if type(semantic_service) == "table" and type(semantic_service.Tick) == "function" then
                        return semantic_service.Tick(menu_report)
                    end
                    return nil
                end,
                native_listener_address = host_native_listener_address,
                native_listener_route = host_native_listener_route,
                input_time_seconds = function()
                    local ok_clock, value = pcall(function() return os.clock() end)
                    if ok_clock and tonumber(value) ~= nil then return tonumber(value), "os.clock" end
                    return tonumber(os.time()) or 0, "os.time"
                end,
                log = function(message) print("[MortalShell2ModUI] " .. tostring(message) .. "\\n") end,
            })
        if type(service_instance) == "table" then
            input_service = service_instance
            local semantic_factory = ModUI.Host ~= nil and ModUI.Host.SemanticService or nil
            if type(semantic_factory) == "table" and type(semantic_factory.Bind) == "function" then
                local semantic_instance, semantic_err = semantic_factory.Bind(registry, Protocol, ModUI.Object, {
                    register_hook = RegisterHook, unregister_hook = UnregisterHook, load_asset = LoadAsset,
                    input_service = input_service, menu_service = menu_service,
                    listener_address = host_native_listener_address,
                    observe_event = observe_host_native_listener_shadow,
                    publish_state = function(status, report)
                        ModRef:SetSharedVariable(Protocol.HostKey("PhysicalNativeInputHookState"), tostring(status or "session-idle"))
                        report = type(report) == "table" and report or {}
                        local signature = table.concat({ tostring(status or ""), tostring(report.consumer or ""),
                            tostring(report.revision or 0), tostring(report.generation or 0),
                            tostring(report.address or ""), tostring(report.cycle or 0), tostring(report.reason or "") }, "|")
                        if signature ~= semantic_state_signature then
                            semantic_state_signature = signature
                            print(string.format("[MortalShell2ModUI] shared-menu semantic state=%s consumer=%s revision=%s generation=%s address=%s cycle=%s reason=%s\n",
                                tostring(status or ""), tostring(report.consumer or ""), tostring(report.revision or 0),
                                tostring(report.generation or 0), tostring(report.address or ""),
                                tostring(report.cycle or 0), tostring(report.reason or "")))
                        end
                    end,
                    log = function(message) print("[MortalShell2ModUI] " .. tostring(message) .. "\n") end,
                })
                if type(semantic_instance) == "table" then
                    semantic_service = semantic_instance
                    ModRef:SetSharedVariable(Protocol.HostKey("PhysicalNativeInputHookState"), "session-idle")
                else
                    ModRef:SetSharedVariable(Protocol.HostKey("PhysicalNativeInputHookState"), "degraded")
                    print("[MortalShell2ModUI] Host.SemanticService bind failed: " .. tostring(semantic_err) .. "\n")
                end
            else
                ModRef:SetSharedVariable(Protocol.HostKey("PhysicalNativeInputHookState"), "degraded")
                print("[MortalShell2ModUI] Host.SemanticService unavailable\n")
            end

            local armed, arm_err = input_service.Arm()
            if armed then
                ModRef:SetSharedVariable(Protocol.HostKey("PhysicalHotkeyState"), "ready")
                ModRef:SetSharedVariable(Protocol.HostKey("PhysicalAnalogState"), "ready")
                ModRef:SetSharedVariable(Protocol.HostKey("PhysicalControllerCaptureState"), "ready")
                ModRef:SetSharedVariable(Protocol.HostKey("PhysicalKeyboardCaptureState"), "ready")
                local nav_ready = type(input_service.NavigationReady) == "function" and input_service.NavigationReady() == true
                ModRef:SetSharedVariable(Protocol.HostKey("PhysicalKeyboardNavigationState"), nav_ready and "ready" or "degraded")
                publish_host_native_listener_state("ready", false, "")
                -- Pass 161 permanently leaves the rejected process-wide callback mirror isolated.
                -- Host.SemanticService owns a bounded callback only for the active shared-menu session.
                native_input_hook_terminal = true
                if semantic_service == nil then
                    ModRef:SetSharedVariable(Protocol.HostKey("PhysicalNativeInputHookState"), "degraded")
                end
                print("[MortalShell2ModUI] standalone shared-menu host armed cadence=50ms backoff=250ms navigation="
                    .. tostring(nav_ready) .. " nativeSemantic=" .. tostring(semantic_service ~= nil and "session-bounded" or "degraded")
                    .. " processWideMirror=isolated\n")
            else
                ModRef:SetSharedVariable(Protocol.HostKey("PhysicalHotkeyState"), "degraded")
                ModRef:SetSharedVariable(Protocol.HostKey("PhysicalAnalogState"), "degraded")
                ModRef:SetSharedVariable(Protocol.HostKey("PhysicalControllerCaptureState"), "degraded")
                ModRef:SetSharedVariable(Protocol.HostKey("PhysicalKeyboardCaptureState"), "degraded")
                ModRef:SetSharedVariable(Protocol.HostKey("PhysicalKeyboardNavigationState"), "degraded")
                ModRef:SetSharedVariable(Protocol.HostKey("PhysicalNativeInputHookState"), "degraded")
                publish_host_native_listener_state("degraded", false, "")
                print("[MortalShell2ModUI] standalone input host arm failed: " .. tostring(arm_err) .. "\n")
            end
        else
            ModRef:SetSharedVariable(Protocol.HostKey("PhysicalHotkeyState"), "degraded")
            ModRef:SetSharedVariable(Protocol.HostKey("PhysicalAnalogState"), "degraded")
            ModRef:SetSharedVariable(Protocol.HostKey("PhysicalControllerCaptureState"), "degraded")
            ModRef:SetSharedVariable(Protocol.HostKey("PhysicalKeyboardCaptureState"), "degraded")
            ModRef:SetSharedVariable(Protocol.HostKey("PhysicalKeyboardNavigationState"), "degraded")
            ModRef:SetSharedVariable(Protocol.HostKey("PhysicalNativeInputHookState"), "degraded")
            publish_host_native_listener_state("degraded", false, "")
            print("[MortalShell2ModUI] Host.InputService bind failed: " .. tostring(input_err) .. "\n")
        end
    else
        ModRef:SetSharedVariable(Protocol.HostKey("PhysicalHotkeyState"), "degraded")
        ModRef:SetSharedVariable(Protocol.HostKey("PhysicalAnalogState"), "degraded")
        ModRef:SetSharedVariable(Protocol.HostKey("PhysicalControllerCaptureState"), "degraded")
        ModRef:SetSharedVariable(Protocol.HostKey("PhysicalKeyboardCaptureState"), "degraded")
        ModRef:SetSharedVariable(Protocol.HostKey("PhysicalKeyboardNavigationState"), "degraded")
        ModRef:SetSharedVariable(Protocol.HostKey("PhysicalNativeInputHookState"), "degraded")
        publish_host_native_listener_state("degraded", false, "")
    end

    if type(RegisterLoadMapPreHook) == "function" then
        local ok_pre, pre_err = pcall(RegisterLoadMapPreHook, function()
            local token = host_perf.Begin()
            -- LoadMap-pre is a no-UObject boundary. Never validate/dereference old-world shell/controller wrappers here.
            host_controller_cache = nil
            if type(native_menu_gate) == "table" then
                pcall(native_menu_gate.Quarantine, "LoadMap-pre")
            end
            if type(semantic_service) == "table" and type(semantic_service.WorldPreload) == "function" then
                pcall(semantic_service.WorldPreload, "LoadMap-pre")
            end
            if type(shell_service) == "table" and type(shell_service.WorldPreload) == "function" then
                pcall(shell_service.WorldPreload, "LoadMap-pre")
            end
            publish_visible_shell_report({ state = "quarantined", active = false, mode = "single-owner" })
            print("[MortalShell2ModUI] visible shell world quarantine entered reason=LoadMap-pre\n")
            host_perf.End("lifecycle.load-map-pre", token)
        end)
        if not ok_pre then print("[MortalShell2ModUI] visible shell LoadMap-pre hook failed: " .. tostring(pre_err) .. "\n") end
    end
    if type(RegisterLoadMapPostHook) == "function" then
        local ok_post, post_err = pcall(RegisterLoadMapPostHook, function()
            local token = host_perf.Begin()
            if type(native_menu_gate) == "table" then
                pcall(native_menu_gate.Release, "LoadMap-post")
            end
            if type(semantic_service) == "table" and type(semantic_service.WorldPostload) == "function" then
                pcall(semantic_service.WorldPostload, "LoadMap-post")
            end
            if type(shell_service) == "table" and type(shell_service.WorldPostload) == "function" then
                pcall(shell_service.WorldPostload, "LoadMap-post")
            end
            publish_visible_shell_report({ state = "ready", active = false, mode = "single-owner" })
            print("[MortalShell2ModUI] visible shell world quarantine released reason=LoadMap-post\n")
            host_perf.End("lifecycle.load-map-post", token)
        end)
        if not ok_post then print("[MortalShell2ModUI] visible shell LoadMap-post hook failed: " .. tostring(post_err) .. "\n") end
    end

    run_discovery("startup", true)
    local initial_menu_ok, initial_menu_err = tick_menu_session()
    if not initial_menu_ok then
        print("[MortalShell2ModUI] initial host menu session tick failed: " .. tostring(initial_menu_err) .. "\n")
    end

    -- Cover either sibling-mod load order without creating a permanent host watcher.
    -- These six one-shot callbacks retire naturally after the bounded discovery window.
    local discovery_delays = { 100, 300, 750, 1500, 3000, 5000 }
    for index, delay_ms in ipairs(discovery_delays) do
        local callback = function()
            run_discovery("retry-" .. tostring(index), false)
        end
        local scheduled = false
        local ok = pcall(function()
            ExecuteInGameThreadWithDelay(delay_ms, callback)
            scheduled = true
        end)
        if not ok or not scheduled then
            pcall(function() ExecuteWithDelay(delay_ms, callback) end)
        end
    end
end)
