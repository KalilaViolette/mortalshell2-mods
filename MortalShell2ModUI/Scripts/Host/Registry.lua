-- MortalShell2ModUI Host.Registry
-- Bounded deterministic consumer registration over UE4SS primitive shared variables.
-- Consumers claim one of 32 deterministic slots, publish an encoded descriptor, and can
-- later receive a host acknowledgement. Executable callbacks always remain inside the
-- owning Lua state.

local M = {}

function M.Bind(protocol, get_shared, set_shared)
    if type(protocol) ~= "table" then return nil, "Host.Registry requires Host.Protocol" end
    if type(get_shared) ~= "function" then return nil, "Host.Registry requires get_shared" end
    if type(set_shared) ~= "function" then return nil, "Host.Registry requires set_shared" end

    local self = {}

    local function safe_get(key)
        local ok, value = pcall(get_shared, key)
        if not ok then return nil, tostring(value) end
        return value, nil
    end

    local function safe_set(key, value)
        local ok, result = pcall(set_shared, key, value)
        if not ok then return false, tostring(result) end
        return true, result
    end

    local function current_slot_matches(slot, consumer_id, consumer_revision)
        local owner_key, owner_key_err = protocol.SlotKey(slot, "Owner")
        if owner_key == nil then return false, owner_key_err end
        local owner, owner_err = safe_get(owner_key)
        if owner_err ~= nil then return false, owner_err end
        if tostring(owner or "") ~= tostring(consumer_id or "") then return false, "slot owner changed" end
        local revision_key, revision_key_err = protocol.SlotKey(slot, "Revision")
        if revision_key == nil then return false, revision_key_err end
        local current_revision, revision_err = safe_get(revision_key)
        if revision_err ~= nil then return false, revision_err end
        if math.max(0, math.floor(tonumber(current_revision) or 0))
            ~= math.max(0, math.floor(tonumber(consumer_revision) or 0)) then
            return false, "slot revision changed"
        end
        return true
    end

    function self.ReadHostEpoch()
        local value, err = safe_get(protocol.HostKey("Epoch"))
        if err ~= nil then return nil, err end
        local epoch = tostring(value or "")
        if epoch == "" then return nil, "host epoch unavailable" end
        return epoch
    end

    -- Closed settings consumers only need the primitive visibility gate. Keep
    -- the full HostMetadata contract for active/closing ownership arbitration,
    -- but avoid its broad shared-variable snapshot during ordinary gameplay.
    function self.ReadVisibilitySnapshot()
        local native_menu_hook_state = safe_get(protocol.HostKey("NativeMenuHookState"))
        local native_menu_state = safe_get(protocol.HostKey("NativeMenuState"))
        local native_menu_active = safe_get(protocol.HostKey("NativeMenuActive"))
        local native_menu_sequence = safe_get(protocol.HostKey("NativeMenuSequence"))
        local menu_session_state = safe_get(protocol.HostKey("MenuSessionState"))
        local visible_shell_host_state = safe_get(protocol.HostKey("VisibleShellHostState"))
        local visible_shell_host_consumer = safe_get(protocol.HostKey("VisibleShellHostConsumer"))
        local menu_shell_state = safe_get(protocol.HostKey("MenuShellState"))
        return {
            nativeMenuHookState = tostring(native_menu_hook_state or "unavailable"),
            nativeMenuState = tostring(native_menu_state or "unavailable"),
            nativeMenuActive = native_menu_active == true or tostring(native_menu_active or "") == "true",
            nativeMenuSequence = math.max(0, math.floor(tonumber(native_menu_sequence) or 0)),
            menuSessionState = tostring(menu_session_state or "idle"),
            visibleShellHostState = tostring(visible_shell_host_state or "unavailable"),
            visibleShellHostConsumer = tostring(visible_shell_host_consumer or ""),
            menuShellState = tostring(menu_shell_state or "none"),
        }
    end

    function self.HostMetadata()
        local epoch = safe_get(protocol.HostKey("Epoch"))
        local state = safe_get(protocol.HostKey("State"))
        local version = safe_get(protocol.HostKey("Version"))
        local protocol_version = safe_get(protocol.HostKey("ProtocolVersion"))
        local physical_hotkey_state = safe_get(protocol.HostKey("PhysicalHotkeyState"))
        local physical_analog_state = safe_get(protocol.HostKey("PhysicalAnalogState"))
        local physical_controller_capture_state = safe_get(protocol.HostKey("PhysicalControllerCaptureState"))
        local physical_keyboard_capture_state = safe_get(protocol.HostKey("PhysicalKeyboardCaptureState"))
        local physical_keyboard_navigation_state = safe_get(protocol.HostKey("PhysicalKeyboardNavigationState"))
        local physical_native_input_hook_state = safe_get(protocol.HostKey("PhysicalNativeInputHookState"))
        local physical_native_listener_state = safe_get(protocol.HostKey("PhysicalNativeListenerState"))
        local physical_native_listener_address = safe_get(protocol.HostKey("PhysicalNativeListenerAddress"))
        local controller_profile_revision = safe_get(protocol.HostKey("ControllerProfileRevision"))
        local controller_profile_source = safe_get(protocol.HostKey("ControllerProfileSource"))
        local controller_profile_calibrated = safe_get(protocol.HostKey("ControllerProfileCalibrated"))
        local native_menu_hook_state = safe_get(protocol.HostKey("NativeMenuHookState"))
        local native_menu_state = safe_get(protocol.HostKey("NativeMenuState"))
        local native_menu_active = safe_get(protocol.HostKey("NativeMenuActive"))
        local native_menu_sequence = safe_get(protocol.HostKey("NativeMenuSequence"))
        local native_menu_reason = safe_get(protocol.HostKey("NativeMenuReason"))
        local menu_state = safe_get(protocol.HostKey("MenuState"))
        local menu_provider_count = safe_get(protocol.HostKey("MenuProviderCount"))
        local menu_provider_consumer = safe_get(protocol.HostKey("MenuProviderConsumer"))
        local menu_provider_slot = safe_get(protocol.HostKey("MenuProviderSlot"))
        local menu_provider_revision = safe_get(protocol.HostKey("MenuProviderRevision"))
        local menu_provider_display = safe_get(protocol.HostKey("MenuProviderDisplay"))
        local menu_provider_pages = safe_get(protocol.HostKey("MenuProviderPages"))
        local menu_provider_actions = safe_get(protocol.HostKey("MenuProviderActions"))
        local menu_provider_consumers = safe_get(protocol.HostKey("MenuProviderConsumers"))
        local menu_hotkey_owner_consumer = safe_get(protocol.HostKey("MenuHotkeyOwnerConsumer"))
        local menu_hotkey_owner_slot = safe_get(protocol.HostKey("MenuHotkeyOwnerSlot"))
        local menu_hotkey_owner_revision = safe_get(protocol.HostKey("MenuHotkeyOwnerRevision"))
        local menu_active_consumer = safe_get(protocol.HostKey("MenuActiveConsumer"))
        local menu_host_epoch = safe_get(protocol.HostKey("MenuHostEpoch"))
        local visible_shell_host_state = safe_get(protocol.HostKey("VisibleShellHostState"))
        local visible_shell_host_consumer = safe_get(protocol.HostKey("VisibleShellHostConsumer"))
        local visible_shell_host_slot = safe_get(protocol.HostKey("VisibleShellHostSlot"))
        local visible_shell_host_revision = safe_get(protocol.HostKey("VisibleShellHostRevision"))
        local visible_shell_host_generation = safe_get(protocol.HostKey("VisibleShellHostGeneration"))
        local visible_shell_host_sequence = safe_get(protocol.HostKey("VisibleShellHostPresentationSequence"))
        local visible_shell_host_address = safe_get(protocol.HostKey("VisibleShellHostAddress"))
        local visible_shell_host_mode = safe_get(protocol.HostKey("VisibleShellHostMode"))
        local menu_session_state = safe_get(protocol.HostKey("MenuSessionState"))
        local menu_session_consumer = safe_get(protocol.HostKey("MenuSessionConsumer"))
        local menu_session_slot = safe_get(protocol.HostKey("MenuSessionSlot"))
        local menu_session_revision = safe_get(protocol.HostKey("MenuSessionRevision"))
        local menu_session_sequence = safe_get(protocol.HostKey("MenuSessionSequence"))
        local menu_session_generation = safe_get(protocol.HostKey("MenuSessionGeneration"))
        local menu_session_reason = safe_get(protocol.HostKey("MenuSessionReason"))
        local menu_session_host_epoch = safe_get(protocol.HostKey("MenuSessionHostEpoch"))
        local menu_lease_state = safe_get(protocol.HostKey("MenuLeaseState"))
        local menu_lease_consumer = safe_get(protocol.HostKey("MenuLeaseConsumer"))
        local menu_lease_slot = safe_get(protocol.HostKey("MenuLeaseSlot"))
        local menu_lease_revision = safe_get(protocol.HostKey("MenuLeaseRevision"))
        local menu_lease_sequence = safe_get(protocol.HostKey("MenuLeaseSequence"))
        local menu_lease_generation = safe_get(protocol.HostKey("MenuLeaseGeneration"))
        local menu_lease_reason = safe_get(protocol.HostKey("MenuLeaseReason"))
        local menu_lease_host_epoch = safe_get(protocol.HostKey("MenuLeaseHostEpoch"))
        local menu_shell_state = safe_get(protocol.HostKey("MenuShellState"))
        local menu_shell_consumer = safe_get(protocol.HostKey("MenuShellConsumer"))
        local menu_shell_slot = safe_get(protocol.HostKey("MenuShellSlot"))
        local menu_shell_revision = safe_get(protocol.HostKey("MenuShellRevision"))
        local menu_shell_sequence = safe_get(protocol.HostKey("MenuShellSequence"))
        local menu_shell_generation = safe_get(protocol.HostKey("MenuShellGeneration"))
        local menu_shell_address = safe_get(protocol.HostKey("MenuShellAddress"))
        local menu_shell_reused = safe_get(protocol.HostKey("MenuShellReused"))
        local menu_shell_cache_token = safe_get(protocol.HostKey("MenuShellCacheToken"))
        local menu_shell_reason = safe_get(protocol.HostKey("MenuShellReason"))
        local menu_shell_host_epoch = safe_get(protocol.HostKey("MenuShellHostEpoch"))
        return {
            epoch = epoch, state = state, version = version, protocolVersion = protocol_version,
            physicalHotkeyState = physical_hotkey_state,
            physicalAnalogState = physical_analog_state,
            physicalControllerCaptureState = physical_controller_capture_state,
            physicalKeyboardCaptureState = physical_keyboard_capture_state,
            physicalKeyboardNavigationState = physical_keyboard_navigation_state,
            physicalNativeInputHookState = physical_native_input_hook_state,
            physicalNativeListenerState = physical_native_listener_state,
            physicalNativeListenerAddress = tostring(physical_native_listener_address or ""),
            controllerProfileRevision = math.max(0, math.floor(tonumber(controller_profile_revision) or 0)),
            controllerProfileSource = tostring(controller_profile_source or ""),
            controllerProfileCalibrated = controller_profile_calibrated == true or tostring(controller_profile_calibrated or "") == "true",
            nativeMenuHookState = tostring(native_menu_hook_state or "unavailable"),
            nativeMenuState = tostring(native_menu_state or "unavailable"),
            nativeMenuActive = native_menu_active == true or tostring(native_menu_active or "") == "true",
            nativeMenuSequence = math.max(0, math.floor(tonumber(native_menu_sequence) or 0)),
            nativeMenuReason = tostring(native_menu_reason or ""),
            menuState = menu_state,
            menuProviderCount = math.max(0, math.floor(tonumber(menu_provider_count) or 0)),
            menuProviderConsumer = tostring(menu_provider_consumer or ""),
            menuProviderSlot = math.floor(tonumber(menu_provider_slot) or -1),
            menuProviderRevision = math.max(0, math.floor(tonumber(menu_provider_revision) or 0)),
            menuProviderDisplay = tostring(menu_provider_display or ""),
            menuProviderPages = tostring(menu_provider_pages or ""),
            menuProviderActions = tostring(menu_provider_actions or ""),
            menuProviderConsumers = tostring(menu_provider_consumers or ""),
            menuHotkeyOwnerConsumer = tostring(menu_hotkey_owner_consumer or ""),
            menuHotkeyOwnerSlot = math.floor(tonumber(menu_hotkey_owner_slot) or -1),
            menuHotkeyOwnerRevision = math.max(0, math.floor(tonumber(menu_hotkey_owner_revision) or 0)),
            menuActiveConsumer = tostring(menu_active_consumer or ""),
            menuHostEpoch = tostring(menu_host_epoch or ""),
            visibleShellHostState = tostring(visible_shell_host_state or "unavailable"),
            visibleShellHostConsumer = tostring(visible_shell_host_consumer or ""),
            visibleShellHostSlot = math.floor(tonumber(visible_shell_host_slot) or -1),
            visibleShellHostRevision = math.max(0, math.floor(tonumber(visible_shell_host_revision) or 0)),
            visibleShellHostGeneration = math.max(0, math.floor(tonumber(visible_shell_host_generation) or 0)),
            visibleShellHostPresentationSequence = math.max(0, math.floor(tonumber(visible_shell_host_sequence) or 0)),
            visibleShellHostAddress = tostring(visible_shell_host_address or ""),
            visibleShellHostMode = tostring(visible_shell_host_mode or ""),
            menuSessionState = tostring(menu_session_state or "idle"),
            menuSessionConsumer = tostring(menu_session_consumer or ""),
            menuSessionSlot = math.floor(tonumber(menu_session_slot) or -1),
            menuSessionRevision = math.max(0, math.floor(tonumber(menu_session_revision) or 0)),
            menuSessionSequence = math.max(0, math.floor(tonumber(menu_session_sequence) or 0)),
            menuSessionGeneration = math.max(0, math.floor(tonumber(menu_session_generation) or 0)),
            menuSessionReason = tostring(menu_session_reason or ""),
            menuSessionHostEpoch = tostring(menu_session_host_epoch or ""),
            menuLeaseState = tostring(menu_lease_state or "idle"),
            menuLeaseConsumer = tostring(menu_lease_consumer or ""),
            menuLeaseSlot = math.floor(tonumber(menu_lease_slot) or -1),
            menuLeaseRevision = math.max(0, math.floor(tonumber(menu_lease_revision) or 0)),
            menuLeaseSequence = math.max(0, math.floor(tonumber(menu_lease_sequence) or 0)),
            menuLeaseGeneration = math.max(0, math.floor(tonumber(menu_lease_generation) or 0)),
            menuLeaseReason = tostring(menu_lease_reason or ""),
            menuLeaseHostEpoch = tostring(menu_lease_host_epoch or ""),
            menuShellState = tostring(menu_shell_state or "none"),
            menuShellConsumer = tostring(menu_shell_consumer or ""),
            menuShellSlot = math.floor(tonumber(menu_shell_slot) or -1),
            menuShellRevision = math.max(0, math.floor(tonumber(menu_shell_revision) or 0)),
            menuShellSequence = math.max(0, math.floor(tonumber(menu_shell_sequence) or 0)),
            menuShellGeneration = math.max(0, math.floor(tonumber(menu_shell_generation) or 0)),
            menuShellAddress = tostring(menu_shell_address or ""),
            menuShellReused = menu_shell_reused == true or tostring(menu_shell_reused or "") == "true",
            menuShellCacheToken = math.max(0, math.floor(tonumber(menu_shell_cache_token) or 0)),
            menuShellReason = tostring(menu_shell_reason or ""),
            menuShellHostEpoch = tostring(menu_shell_host_epoch or ""),
        }
    end

    function self.ReadControllerProfileRevision()
        local value, err = safe_get(protocol.HostKey("ControllerProfileRevision"))
        if err ~= nil then return nil, err end
        return math.max(0, math.floor(tonumber(value) or 0))
    end

    function self.PublishControllerProfileState(source_consumer, calibrated, reason)
        local current, current_err = self.ReadControllerProfileRevision()
        if current == nil then return nil, current_err end
        local next_revision = current + 1
        local source = tostring(source_consumer or "MortalShell2ModUI")
        local ok, set_err = safe_set(protocol.HostKey("ControllerProfileSource"), source)
        if not ok then return nil, set_err end
        ok, set_err = safe_set(protocol.HostKey("ControllerProfileCalibrated"), calibrated == true)
        if not ok then return nil, set_err end
        ok, set_err = safe_set(protocol.HostKey("ControllerProfileReason"), tostring(reason or "updated"))
        if not ok then return nil, set_err end
        -- Revision is the commit marker and is written last. Consumer Lua states reload the
        -- shared persistent profile only when this primitive revision changes.
        ok, set_err = safe_set(protocol.HostKey("ControllerProfileRevision"), next_revision)
        if not ok then return nil, set_err end
        return { revision = next_revision, source = source, calibrated = calibrated == true }
    end

    function self.PublishMenuState(metadata)
        metadata = metadata or {}
        local fields = {
            MenuState = tostring(metadata.state or "idle"),
            MenuProviderCount = math.max(0, math.floor(tonumber(metadata.providerCount) or 0)),
            MenuProviderConsumer = tostring(metadata.providerConsumer or ""),
            MenuProviderSlot = math.floor(tonumber(metadata.providerSlot) or -1),
            MenuProviderRevision = math.max(0, math.floor(tonumber(metadata.providerRevision) or 0)),
            MenuProviderDisplay = tostring(metadata.providerDisplay or ""),
            MenuProviderPages = tostring(metadata.providerPages or ""),
            MenuProviderActions = tostring(metadata.providerActions or ""),
            MenuProviderConsumers = tostring(metadata.providerConsumers or ""),
            MenuHotkeyOwnerConsumer = tostring(metadata.hotkeyOwnerConsumer or ""),
            MenuHotkeyOwnerSlot = math.floor(tonumber(metadata.hotkeyOwnerSlot) or -1),
            MenuHotkeyOwnerRevision = math.max(0, math.floor(tonumber(metadata.hotkeyOwnerRevision) or 0)),
            MenuActiveConsumer = tostring(metadata.activeConsumer or metadata.providerConsumer or ""),
            MenuHostEpoch = tostring(metadata.hostEpoch or ""),
        }
        for key, value in pairs(fields) do
            local ok, set_err = safe_set(protocol.HostKey(key), value)
            if not ok then return false, tostring(set_err) end
        end
        return true
    end

    function self.ReadMenuState()
        local host = self.HostMetadata()
        return {
            state = host.menuState,
            providerCount = host.menuProviderCount,
            providerConsumer = host.menuProviderConsumer,
            providerSlot = host.menuProviderSlot,
            providerRevision = host.menuProviderRevision,
            providerDisplay = host.menuProviderDisplay,
            providerPages = host.menuProviderPages,
            providerActions = host.menuProviderActions,
            providerConsumers = host.menuProviderConsumers,
            hotkeyOwnerConsumer = host.menuHotkeyOwnerConsumer,
            hotkeyOwnerSlot = host.menuHotkeyOwnerSlot,
            hotkeyOwnerRevision = host.menuHotkeyOwnerRevision,
            activeConsumer = host.menuActiveConsumer,
            hostEpoch = host.menuHostEpoch,
        }
    end


    function self.SetMenuActiveConsumerRequest(consumer_id)
        local id, err = protocol.NormalizeConsumerId(consumer_id)
        if id == nil then return false, err end
        return safe_set(protocol.HostKey("MenuActiveConsumerRequest"), id)
    end

    function self.ClearMenuActiveConsumerRequest()
        return safe_set(protocol.HostKey("MenuActiveConsumerRequest"), "")
    end

    function self.ReadMenuActiveConsumerRequest()
        local value, err = safe_get(protocol.HostKey("MenuActiveConsumerRequest"))
        if err ~= nil then return nil, err end
        local text = tostring(value or "")
        if text == "" then return "", nil end
        return protocol.NormalizeConsumerId(text)
    end

    function self.PublishVisibleShellHostState(metadata)
        metadata = type(metadata) == "table" and metadata or {}
        local fields = {
            VisibleShellHostState = tostring(metadata.state or "ready"),
            VisibleShellHostConsumer = tostring(metadata.consumer or ""),
            VisibleShellHostSlot = math.floor(tonumber(metadata.slot) or -1),
            VisibleShellHostRevision = math.max(0, math.floor(tonumber(metadata.revision) or 0)),
            VisibleShellHostGeneration = math.max(0, math.floor(tonumber(metadata.generation) or 0)),
            VisibleShellHostPresentationSequence = math.max(0, math.floor(tonumber(metadata.sequence) or 0)),
            VisibleShellHostAddress = tostring(metadata.address or ""),
            VisibleShellHostMode = tostring(metadata.mode or ""),
        }
        for key, value in pairs(fields) do
            local ok, set_err = safe_set(protocol.HostKey(key), value)
            if not ok then return false, tostring(set_err) end
        end
        return true
    end

    function self.SetMenuPresentation(slot, consumer_id, consumer_revision, sequence, generation, snapshot)
        local id, id_err = protocol.NormalizeConsumerId(consumer_id)
        if id == nil then return nil, id_err end
        slot = math.floor(tonumber(slot) or -1)
        if slot < 0 or slot >= protocol.SLOT_COUNT then return nil, "presentation slot invalid" end
        consumer_revision = math.max(0, math.floor(tonumber(consumer_revision) or 0))
        local current_ok, current_err = current_slot_matches(slot, id, consumer_revision)
        if not current_ok then return nil, "presentation stale: " .. tostring(current_err) end
        sequence = math.max(1, math.floor(tonumber(sequence) or 0))
        generation = math.max(0, math.floor(tonumber(generation) or 0))
        snapshot = type(snapshot) == "table" and snapshot or {}
        local function text(value, limit)
            local out = tostring(value or "")
            limit = math.max(0, math.floor(tonumber(limit) or 0))
            if #out > limit then out = out:sub(1, limit) end
            return out
        end
        local values = {
            PresentationConsumer = id,
            PresentationRevision = consumer_revision,
            PresentationGeneration = generation,
            PresentationSequence = sequence,
            PresentationProfile = text(snapshot.profile, 32),
            PresentationHeader = text(snapshot.header, 256),
            PresentationPage = text(snapshot.page, 64),
            PresentationTabs = text(snapshot.tabs, 4096),
            -- Primitive structure metadata lets the host build native controls
            -- without allowing a consumer to pass UObject references across the
            -- registry boundary.
            PresentationTabLabels = text(snapshot.tabLabels, 4096),
            PresentationSelectedTab = math.max(1, math.floor(tonumber(snapshot.selectedTab) or 1)),
            PresentationRowKinds = text(snapshot.rowKinds, 4096),
            PresentationRowProgress = text(snapshot.rowProgress, 4096),
            PresentationSelectedRow = math.max(1, math.floor(tonumber(snapshot.selectedRow) or 1)),
            PresentationLabels = text(snapshot.labels, 8192),
            PresentationValues = text(snapshot.values, 8192),
            PresentationBody = text(snapshot.body, 16384),
            PresentationDetailTitle = text(snapshot.detailTitle, 1024),
            PresentationDetails = text(snapshot.details, 16384),
        }
        -- Commit marker is written last so the host never renders a mixed snapshot.
        for field, value in pairs(values) do
            if field ~= "PresentationSequence" then
                local ok, set_err = safe_set(protocol.SlotKey(slot, field), value)
                if not ok then return nil, set_err end
            end
        end
        local ok, set_err = safe_set(protocol.SlotKey(slot, "PresentationSequence"), sequence)
        if not ok then return nil, set_err end
        return { consumer = id, slot = slot, revision = consumer_revision, generation = generation, sequence = sequence }
    end

    function self.ReadConsumerMenuPresentation(slot, consumer_id, expected_revision, expected_generation)
        local id, id_err = protocol.NormalizeConsumerId(consumer_id)
        if id == nil then return nil, id_err end
        slot = math.floor(tonumber(slot) or -1)
        if slot < 0 or slot >= protocol.SLOT_COUNT then return nil, "presentation slot invalid" end
        if expected_revision ~= nil then
            local current_ok, current_err = current_slot_matches(slot, id, expected_revision)
            if not current_ok then return nil, "presentation stale: " .. tostring(current_err) end
        end
        local commit_a, commit_err = safe_get(protocol.SlotKey(slot, "PresentationSequence"))
        if commit_err ~= nil then return nil, commit_err end
        commit_a = math.max(0, math.floor(tonumber(commit_a) or 0))
        if commit_a <= 0 then return nil, "presentation pending" end
        local consumer = tostring((safe_get(protocol.SlotKey(slot, "PresentationConsumer"))) or "")
        local revision = math.max(0, math.floor(tonumber((safe_get(protocol.SlotKey(slot, "PresentationRevision")))) or 0))
        local generation = math.max(0, math.floor(tonumber((safe_get(protocol.SlotKey(slot, "PresentationGeneration")))) or 0))
        if consumer ~= id then return nil, "presentation consumer mismatch" end
        if expected_revision ~= nil and revision ~= math.max(0, math.floor(tonumber(expected_revision) or 0)) then
            return nil, "presentation revision mismatch"
        end
        if expected_generation ~= nil and generation ~= math.max(0, math.floor(tonumber(expected_generation) or 0)) then
            return nil, "presentation generation mismatch"
        end
        local snapshot = {
            consumer = id, slot = slot, revision = revision, generation = generation, sequence = commit_a,
            profile = tostring((safe_get(protocol.SlotKey(slot, "PresentationProfile"))) or "main"),
            header = tostring((safe_get(protocol.SlotKey(slot, "PresentationHeader"))) or ""),
            page = tostring((safe_get(protocol.SlotKey(slot, "PresentationPage"))) or ""),
            tabs = tostring((safe_get(protocol.SlotKey(slot, "PresentationTabs"))) or ""),
            tabLabels = tostring((safe_get(protocol.SlotKey(slot, "PresentationTabLabels"))) or ""),
            selectedTab = math.max(1, math.floor(tonumber(
                (safe_get(protocol.SlotKey(slot, "PresentationSelectedTab")))) or 1)),
            rowKinds = tostring((safe_get(protocol.SlotKey(slot, "PresentationRowKinds"))) or ""),
            rowProgress = tostring((safe_get(protocol.SlotKey(slot, "PresentationRowProgress"))) or ""),
            selectedRow = math.max(1, math.floor(tonumber(
                (safe_get(protocol.SlotKey(slot, "PresentationSelectedRow")))) or 1)),
            labels = tostring((safe_get(protocol.SlotKey(slot, "PresentationLabels"))) or ""),
            values = tostring((safe_get(protocol.SlotKey(slot, "PresentationValues"))) or ""),
            body = tostring((safe_get(protocol.SlotKey(slot, "PresentationBody"))) or ""),
            detailTitle = tostring((safe_get(protocol.SlotKey(slot, "PresentationDetailTitle"))) or ""),
            details = tostring((safe_get(protocol.SlotKey(slot, "PresentationDetails"))) or ""),
        }
        local commit_b = math.max(0, math.floor(tonumber((safe_get(protocol.SlotKey(slot, "PresentationSequence")))) or 0))
        if commit_b ~= commit_a then return nil, "presentation changed during read" end
        return snapshot
    end


    function self.SetMenuAction(slot, consumer_id, consumer_revision, sequence, generation, action, source, payload)
        local id, id_err = protocol.NormalizeConsumerId(consumer_id)
        if id == nil then return nil, id_err end
        slot = math.floor(tonumber(slot) or -1)
        if slot < 0 or slot >= protocol.SLOT_COUNT then return nil, "action slot invalid" end
        consumer_revision = math.max(0, math.floor(tonumber(consumer_revision) or 0))
        local current_ok, current_err = current_slot_matches(slot, id, consumer_revision)
        if not current_ok then return nil, "action stale: " .. tostring(current_err) end
        local encoded, encode_err = protocol.BuildMenuAction(
            id, slot, consumer_revision, sequence, generation, action, source, payload)
        if encoded == nil then return nil, encode_err end
        local ring_size = math.max(4, math.floor(tonumber(protocol.MENU_ACTION_RING_SIZE) or 32))
        local normalized_sequence = math.max(1, math.floor(tonumber(sequence) or 0))
        local ring_index = (normalized_sequence - 1) % ring_size
        local event_key, event_err = protocol.SlotKey(slot, string.format("MenuActionEvent%02d", ring_index))
        if event_key == nil then return nil, event_err end
        local ok, set_err = safe_set(event_key, encoded)
        if not ok then return nil, set_err end
        local head_key, head_err = protocol.SlotKey(slot, "MenuActionHead")
        if head_key == nil then return nil, head_err end
        ok, set_err = safe_set(head_key, normalized_sequence)
        if not ok then return nil, set_err end
        return { consumer = consumer_id, slot = slot, revision = consumer_revision, sequence = normalized_sequence }
    end

    function self.ReadConsumerMenuActionEvents(slot, consumer_id, expected_revision, last_sequence)
        local id, id_err = protocol.NormalizeConsumerId(consumer_id)
        if id == nil then return nil, id_err end
        slot = math.floor(tonumber(slot) or -1)
        if slot < 0 or slot >= protocol.SLOT_COUNT then return nil, "action slot invalid" end
        if expected_revision ~= nil then
            local current_ok, current_err = current_slot_matches(slot, id, expected_revision)
            if not current_ok then return nil, "action stale: " .. tostring(current_err) end
        end
        last_sequence = math.max(0, math.floor(tonumber(last_sequence) or 0))
        local head_key, head_err = protocol.SlotKey(slot, "MenuActionHead")
        if head_key == nil then return nil, head_err end
        local head, read_err = safe_get(head_key)
        if read_err ~= nil then return nil, read_err end
        head = math.max(0, math.floor(tonumber(head) or 0))
        if head <= last_sequence then return {}, head end
        local ring_size = math.max(4, math.floor(tonumber(protocol.MENU_ACTION_RING_SIZE) or 32))
        local first = math.max(last_sequence + 1, head - ring_size + 1)
        local events = {}
        for sequence = first, head do
            local ring_index = (sequence - 1) % ring_size
            local event_key = protocol.SlotKey(slot, string.format("MenuActionEvent%02d", ring_index))
            local encoded = event_key ~= nil and safe_get(event_key) or nil
            if encoded ~= nil then
                local event = protocol.ValidateMenuAction(encoded, id, slot, expected_revision)
                if type(event) == "table" and event.sequence == sequence then events[#events + 1] = event end
            end
        end
        return events, head
    end

    function self.SetMenuSession(slot, consumer_id, consumer_revision, sequence, state, generation, reason)
        local payload, payload_err = protocol.BuildMenuSession(
            consumer_id, slot, consumer_revision, sequence, state, generation, reason)
        if payload == nil then return nil, payload_err end
        local key, key_err = protocol.SlotKey(slot, "MenuSession")
        if key == nil then return nil, key_err end
        local ok, set_err = safe_set(key, payload)
        if not ok then return nil, set_err end

        -- Pass 128 preserves every short-lived opening/ready/closing/closed transition.
        -- Payload is written before the head sequence so the host never observes a head
        -- that points at an incompletely published ring cell. The latest mailbox above is
        -- retained for diagnostics/backward compatibility only.
        local normalized_sequence = math.max(1, math.floor(tonumber(sequence) or 0))
        local ring_size = math.max(4, math.floor(tonumber(protocol.MENU_SESSION_RING_SIZE) or 16))
        local ring_index = (normalized_sequence - 1) % ring_size
        local event_key, event_key_err = protocol.SlotKey(slot, string.format("MenuSessionEvent%02d", ring_index))
        if event_key == nil then return nil, event_key_err end
        ok, set_err = safe_set(event_key, payload)
        if not ok then return nil, set_err end
        local sequence_key, sequence_key_err = protocol.SlotKey(slot, "MenuSessionEventSequence")
        if sequence_key == nil then return nil, sequence_key_err end
        ok, set_err = safe_set(sequence_key, normalized_sequence)
        if not ok then return nil, set_err end
        return protocol.ValidateMenuSession(payload, consumer_id, slot, consumer_revision)
    end

    function self.ReadConsumerMenuSession(slot, consumer_id, consumer_revision)
        local key, key_err = protocol.SlotKey(slot, "MenuSession")
        if key == nil then return nil, key_err end
        local payload, get_err = safe_get(key)
        if get_err ~= nil then return nil, get_err end
        if payload == nil or tostring(payload) == "" then return nil, "menu session unavailable" end
        return protocol.ValidateMenuSession(payload, consumer_id, slot, consumer_revision)
    end

    function self.ReadConsumerMenuSessionEvents(slot, consumer_id, consumer_revision, last_sequence)
        local sequence_key, key_err = protocol.SlotKey(slot, "MenuSessionEventSequence")
        if sequence_key == nil then return nil, key_err end
        local head, head_err = safe_get(sequence_key)
        if head_err ~= nil then return nil, head_err end
        head = math.max(0, math.floor(tonumber(head) or 0))
        local previous = math.max(0, math.floor(tonumber(last_sequence) or 0))
        if head <= previous then return {}, head end

        local ring_size = math.max(4, math.floor(tonumber(protocol.MENU_SESSION_RING_SIZE) or 16))
        local first = math.max(previous + 1, head - ring_size + 1)
        local events = {}
        for expected_sequence = first, head do
            local ring_index = (expected_sequence - 1) % ring_size
            local payload_key, payload_key_err = protocol.SlotKey(
                slot, string.format("MenuSessionEvent%02d", ring_index))
            if payload_key ~= nil then
                local payload, payload_err = safe_get(payload_key)
                if payload_err == nil and payload ~= nil and tostring(payload) ~= "" then
                    local event = protocol.ValidateMenuSession(payload, consumer_id, slot, consumer_revision)
                    if type(event) == "table" and tonumber(event.sequence) == expected_sequence then
                        events[#events + 1] = event
                    end
                end
            end
        end
        return events, head
    end

    function self.PublishMenuSessionState(metadata)
        metadata = metadata or {}
        local fields = {
            MenuSessionState = tostring(metadata.state or "idle"),
            MenuSessionConsumer = tostring(metadata.consumer or ""),
            MenuSessionSlot = math.floor(tonumber(metadata.slot) or -1),
            MenuSessionRevision = math.max(0, math.floor(tonumber(metadata.revision) or 0)),
            MenuSessionSequence = math.max(0, math.floor(tonumber(metadata.sequence) or 0)),
            MenuSessionGeneration = math.max(0, math.floor(tonumber(metadata.generation) or 0)),
            MenuSessionReason = tostring(metadata.reason or ""),
            MenuSessionHostEpoch = tostring(metadata.hostEpoch or ""),
        }
        for key, value in pairs(fields) do
            local ok, set_err = safe_set(protocol.HostKey(key), value)
            if not ok then return false, tostring(set_err) end
        end
        return true
    end

    function self.ReadMenuSessionState()
        local host = self.HostMetadata()
        return {
            state = host.menuSessionState, consumer = host.menuSessionConsumer,
            slot = host.menuSessionSlot, revision = host.menuSessionRevision,
            sequence = host.menuSessionSequence, generation = host.menuSessionGeneration,
            reason = host.menuSessionReason, hostEpoch = host.menuSessionHostEpoch,
        }
    end

    function self.SetMenuLease(slot, consumer_id, consumer_revision, sequence, active, generation, reason)
        local payload, payload_err = protocol.BuildMenuLease(
            consumer_id, slot, consumer_revision, sequence, active, generation, reason)
        if payload == nil then return nil, payload_err end
        local key, key_err = protocol.SlotKey(slot, "MenuLease")
        if key == nil then return nil, key_err end
        local ok, set_err = safe_set(key, payload)
        if not ok then return nil, set_err end
        return protocol.ValidateMenuLease(payload, consumer_id, slot, consumer_revision)
    end

    function self.ReadConsumerMenuLease(slot, consumer_id, consumer_revision)
        local key, key_err = protocol.SlotKey(slot, "MenuLease")
        if key == nil then return nil, key_err end
        local payload, get_err = safe_get(key)
        if get_err ~= nil then return nil, get_err end
        if payload == nil or tostring(payload) == "" then return nil, "menu lease unavailable" end
        return protocol.ValidateMenuLease(payload, consumer_id, slot, consumer_revision)
    end

    function self.PublishMenuLeaseState(metadata)
        metadata = metadata or {}
        local fields = {
            MenuLeaseState = tostring(metadata.state or "idle"),
            MenuLeaseConsumer = tostring(metadata.consumer or ""),
            MenuLeaseSlot = math.floor(tonumber(metadata.slot) or -1),
            MenuLeaseRevision = math.max(0, math.floor(tonumber(metadata.revision) or 0)),
            MenuLeaseSequence = math.max(0, math.floor(tonumber(metadata.sequence) or 0)),
            MenuLeaseGeneration = math.max(0, math.floor(tonumber(metadata.generation) or 0)),
            MenuLeaseReason = tostring(metadata.reason or ""),
            MenuLeaseHostEpoch = tostring(metadata.hostEpoch or ""),
        }
        for key, value in pairs(fields) do
            local ok, set_err = safe_set(protocol.HostKey(key), value)
            if not ok then return false, tostring(set_err) end
        end
        return true
    end

    function self.ReadMenuLeaseState()
        local host = self.HostMetadata()
        return {
            state = host.menuLeaseState, consumer = host.menuLeaseConsumer,
            slot = host.menuLeaseSlot, revision = host.menuLeaseRevision,
            sequence = host.menuLeaseSequence, generation = host.menuLeaseGeneration,
            reason = host.menuLeaseReason, hostEpoch = host.menuLeaseHostEpoch,
        }
    end


    function self.SetMenuShell(slot, consumer_id, consumer_revision, sequence, state, generation,
        shell_address, reused, cache_token, reason)
        local payload, payload_err = protocol.BuildMenuShell(
            consumer_id, slot, consumer_revision, sequence, state, generation,
            shell_address, reused, cache_token, reason)
        if payload == nil then return nil, payload_err end
        local key, key_err = protocol.SlotKey(slot, "MenuShell")
        if key == nil then return nil, key_err end
        local ok, set_err = safe_set(key, payload)
        if not ok then return nil, set_err end
        return protocol.ValidateMenuShell(payload, consumer_id, slot, consumer_revision)
    end

    function self.ReadConsumerMenuShell(slot, consumer_id, consumer_revision)
        local key, key_err = protocol.SlotKey(slot, "MenuShell")
        if key == nil then return nil, key_err end
        local payload, get_err = safe_get(key)
        if get_err ~= nil then return nil, get_err end
        if payload == nil or tostring(payload) == "" then return nil, "menu shell unavailable" end
        return protocol.ValidateMenuShell(payload, consumer_id, slot, consumer_revision)
    end

    function self.PublishMenuShellState(metadata)
        metadata = metadata or {}
        local fields = {
            MenuShellState = tostring(metadata.state or "none"),
            MenuShellConsumer = tostring(metadata.consumer or ""),
            MenuShellSlot = math.floor(tonumber(metadata.slot) or -1),
            MenuShellRevision = math.max(0, math.floor(tonumber(metadata.revision) or 0)),
            MenuShellSequence = math.max(0, math.floor(tonumber(metadata.sequence) or 0)),
            MenuShellGeneration = math.max(0, math.floor(tonumber(metadata.generation) or 0)),
            MenuShellAddress = tostring(metadata.address or ""),
            MenuShellReused = metadata.reused == true,
            MenuShellCacheToken = math.max(0, math.floor(tonumber(metadata.cacheToken) or 0)),
            MenuShellReason = tostring(metadata.reason or ""),
            MenuShellHostEpoch = tostring(metadata.hostEpoch or ""),
        }
        for key, value in pairs(fields) do
            local ok, set_err = safe_set(protocol.HostKey(key), value)
            if not ok then return false, tostring(set_err) end
        end
        return true
    end

    function self.ReadMenuShellState()
        local host = self.HostMetadata()
        return {
            state = host.menuShellState, consumer = host.menuShellConsumer,
            slot = host.menuShellSlot, revision = host.menuShellRevision,
            sequence = host.menuShellSequence, generation = host.menuShellGeneration,
            address = host.menuShellAddress, reused = host.menuShellReused,
            cacheToken = host.menuShellCacheToken, reason = host.menuShellReason,
            hostEpoch = host.menuShellHostEpoch,
        }
    end

    function self.ReadRegistryRevision()
        local value, get_err = safe_get(protocol.HostKey("RegistryRevision"))
        if get_err ~= nil then return nil, get_err end
        return math.max(0, math.floor(tonumber(value) or 0)), nil
    end

    function self.AdvanceRegistryRevision()
        local current, read_err = self.ReadRegistryRevision()
        if current == nil then return nil, read_err end
        local next_revision = current + 1
        local ok, set_err = safe_set(protocol.HostKey("RegistryRevision"), next_revision)
        if not ok then return nil, set_err end
        return next_revision, nil
    end

    function self.ClaimSlot(consumer_id)
        local id, err = protocol.NormalizeConsumerId(consumer_id)
        if id == nil then return nil, err end
        for probe = 0, protocol.SLOT_COUNT - 1 do
            local slot = protocol.SlotIndex(id, probe)
            local owner_key = protocol.SlotKey(slot, "Owner")
            local owner, get_err = safe_get(owner_key)
            if get_err ~= nil then return nil, get_err end
            owner = tostring(owner or "")
            if owner == "" or owner == id then
                local ok, set_err = safe_set(owner_key, id)
                if not ok then return nil, set_err end
                local verify, verify_err = safe_get(owner_key)
                if verify_err ~= nil then return nil, verify_err end
                if tostring(verify or "") == id then
                    return slot, nil, probe
                end
            end
        end
        return nil, "no registry slot available"
    end

    function self.Publish(options)
        options = options or {}
        local descriptor, descriptor_err = protocol.BuildConsumerDescriptor(options)
        if descriptor == nil then return nil, descriptor_err end
        local id = assert(protocol.NormalizeConsumerId(options.consumer_id))
        local slot, claim_err, probe = self.ClaimSlot(id)
        if slot == nil then return nil, claim_err end
        local descriptor_key = protocol.SlotKey(slot, "Descriptor")
        local revision_key = protocol.SlotKey(slot, "Revision")
        local current_revision = tonumber((safe_get(revision_key))) or 0
        local next_revision = math.max(1, math.floor(current_revision + 1))
        local ok, set_err = safe_set(descriptor_key, descriptor)
        if not ok then return nil, set_err end
        ok, set_err = safe_set(revision_key, next_revision)
        if not ok then return nil, set_err end
        local registry_revision, registry_err = self.AdvanceRegistryRevision()
        if registry_revision == nil then return nil, registry_err end
        local host = self.HostMetadata()
        return {
            consumer = id,
            slot = slot,
            probe = probe,
            revision = next_revision,
            registryRevision = registry_revision,
            descriptor = descriptor,
            hostEpoch = host.epoch,
            hostState = host.state,
            hostVersion = host.version,
            hostProtocolVersion = host.protocolVersion,
        }
    end

    function self.RetireConsumer(slot, consumer_id, consumer_revision)
        local id, id_err = protocol.NormalizeConsumerId(consumer_id)
        if id == nil then return nil, id_err end
        slot = math.floor(tonumber(slot) or -1)
        if slot < 0 or slot >= protocol.SLOT_COUNT then return nil, "slot invalid" end
        local current_ok, current_err = current_slot_matches(slot, id, consumer_revision)
        if not current_ok then return nil, "retire stale: " .. tostring(current_err) end

        -- Clear discoverable ownership first. Revision is intentionally retained so the next
        -- claim increments past any stale per-slot mailboxes still carrying the old revision.
        local fields = { "Descriptor", "Ack", "HotkeyState", "NativeInputRequest", "ControllerRequest", "CaptureRequest" }
        for _, field in ipairs(fields) do
            local key = protocol.SlotKey(slot, field)
            local ok, set_err = safe_set(key, "")
            if not ok then return nil, set_err end
        end
        local owner_key = protocol.SlotKey(slot, "Owner")
        local ok, set_err = safe_set(owner_key, "")
        if not ok then return nil, set_err end
        local registry_revision, registry_err = self.AdvanceRegistryRevision()
        if registry_revision == nil then return nil, registry_err end
        return { consumer = id, slot = slot, revision = math.max(0, math.floor(tonumber(consumer_revision) or 0)), registryRevision = registry_revision }
    end

    function self.ReadSlot(slot)
        local owner_key, key_err = protocol.SlotKey(slot, "Owner")
        if owner_key == nil then return nil, key_err end
        local owner, owner_err = safe_get(owner_key)
        if owner_err ~= nil then return nil, owner_err end
        owner = tostring(owner or "")
        if owner == "" then return nil, "empty" end
        local descriptor = safe_get(protocol.SlotKey(slot, "Descriptor"))
        local fields, descriptor_err = protocol.ValidateConsumerDescriptor(descriptor, owner)
        if fields == nil then return nil, descriptor_err end
        local revision = tonumber((safe_get(protocol.SlotKey(slot, "Revision")))) or 0
        return {
            consumer = owner,
            slot = slot,
            revision = math.floor(revision),
            fields = fields,
        }
    end

    function self.Scan()
        local entries = {}
        for slot = 0, protocol.SLOT_COUNT - 1 do
            local entry = self.ReadSlot(slot)
            if type(entry) == "table" then entries[#entries + 1] = entry end
        end
        return entries
    end

    function self.Acknowledge(slot, consumer_id, host_epoch, consumer_revision)
        local payload, payload_err = protocol.BuildAcknowledgement(consumer_id, slot, host_epoch, consumer_revision)
        if payload == nil then return false, payload_err end
        return safe_set(protocol.SlotKey(slot, "Ack"), payload)
    end

    function self.ReadAcknowledgement(slot, consumer_id, expected_revision)
        local payload, get_err = safe_get(protocol.SlotKey(slot, "Ack"))
        if get_err ~= nil then return nil, get_err end
        if payload == nil or tostring(payload) == "" then return nil, "ack pending" end
        return protocol.ValidateAcknowledgement(payload, consumer_id, slot, expected_revision)
    end

    function self.SetHotkeyState(slot, consumer_id, host_epoch, consumer_revision, state)
        local payload, payload_err = protocol.EncodeFields({
            protocol = protocol.VERSION, consumer = consumer_id,
            slot = math.floor(tonumber(slot) or -1),
            revision = math.max(0, math.floor(tonumber(consumer_revision) or 0)),
            hostEpoch = tostring(host_epoch or ""), state = tostring(state or ""),
        })
        if payload == nil then return false, payload_err end
        return safe_set(protocol.SlotKey(slot, "HotkeyState"), payload)
    end

    function self.ReadHotkeyState(slot, consumer_id, expected_revision, expected_host_epoch)
        local payload, get_err = safe_get(protocol.SlotKey(slot, "HotkeyState"))
        if get_err ~= nil then return nil, get_err end
        if payload == nil or tostring(payload) == "" then return nil, "hotkey state pending" end
        local fields, decode_err = protocol.DecodeFields(payload)
        if fields == nil then return nil, decode_err end
        if tonumber(fields.protocol) ~= protocol.VERSION then return nil, "hotkey protocol mismatch" end
        local id = protocol.NormalizeConsumerId(fields.consumer)
        local expected = protocol.NormalizeConsumerId(consumer_id)
        if id == nil or expected == nil or id ~= expected then return nil, "hotkey consumer mismatch" end
        if math.floor(tonumber(fields.slot) or -1) ~= math.floor(tonumber(slot) or -2) then return nil, "hotkey slot mismatch" end
        if math.max(0, math.floor(tonumber(fields.revision) or 0)) ~= math.max(0, math.floor(tonumber(expected_revision) or 0)) then
            return nil, "hotkey revision mismatch"
        end
        if expected_host_epoch ~= nil and tostring(fields.hostEpoch or "") ~= tostring(expected_host_epoch or "") then
            return nil, "hotkey host epoch mismatch"
        end
        return fields
    end

    function self.SetNativeInputRequest(slot, consumer_id, host_epoch, consumer_revision, sequence, active, listener_address, generation)
        local payload, payload_err = protocol.BuildNativeInputRequest(
            consumer_id, slot, host_epoch, consumer_revision, sequence, active, listener_address, generation)
        if payload == nil then return false, payload_err end
        return safe_set(protocol.SlotKey(slot, "NativeInputRequest"), payload)
    end

    function self.ReadNativeInputRequest(slot, consumer_id, expected_revision, expected_host_epoch)
        local payload, get_err = safe_get(protocol.SlotKey(slot, "NativeInputRequest"))
        if get_err ~= nil then return nil, get_err end
        if payload == nil or tostring(payload) == "" then return nil, "native input request pending" end
        return protocol.ValidateNativeInputRequest(payload, consumer_id, slot, expected_revision, expected_host_epoch)
    end

    function self.SetControllerRequest(slot, consumer_id, host_epoch, consumer_revision, sequence, active)
        local payload, payload_err = protocol.BuildControllerRequest(
            consumer_id, slot, host_epoch, consumer_revision, sequence, active)
        if payload == nil then return nil, payload_err end
        return safe_set(protocol.SlotKey(slot, "ControllerRequest"), payload)
    end

    function self.ReadControllerRequest(slot, consumer_id, expected_revision, expected_host_epoch)
        local payload, get_err = safe_get(protocol.SlotKey(slot, "ControllerRequest"))
        if get_err ~= nil then return nil, get_err end
        if payload == nil or tostring(payload) == "" then return nil, "controller request unavailable" end
        return protocol.ValidateControllerRequest(payload, consumer_id, slot, expected_revision, expected_host_epoch)
    end

    function self.SetCaptureRequest(slot, consumer_id, host_epoch, consumer_revision, sequence, kind, active)
        local payload, payload_err = protocol.BuildCaptureRequest(
            consumer_id, slot, host_epoch, consumer_revision, sequence, kind, active)
        if payload == nil then return false, payload_err end
        return safe_set(protocol.SlotKey(slot, "CaptureRequest"), payload)
    end

    function self.ReadCaptureRequest(slot, consumer_id, expected_revision, expected_host_epoch)
        local payload, get_err = safe_get(protocol.SlotKey(slot, "CaptureRequest"))
        if get_err ~= nil then return nil, get_err end
        if payload == nil or tostring(payload) == "" then return nil, "capture request pending" end
        return protocol.ValidateCaptureRequest(payload, consumer_id, slot, expected_revision, expected_host_epoch)
    end

    function self.PublishKeySample(slot, consumer_id, host_epoch, consumer_revision, capture_sequence, key, down, source, press_sequence)
        key = tostring(key or "")
        if key == "" then return nil, "key missing" end
        local safe_key = key:gsub("[^%w_%-]", "_")
        local sequence_key = protocol.SlotKey(slot, "Key_" .. safe_key .. "_Sequence")
        local payload_key = protocol.SlotKey(slot, "Key_" .. safe_key)
        local current = tonumber((safe_get(sequence_key))) or 0
        local sequence = math.max(1, math.floor(current + 1))
        local payload, payload_err = protocol.BuildKeySample(
            consumer_id, slot, host_epoch, consumer_revision, sequence, capture_sequence, key, down, source, press_sequence)
        if payload == nil then return nil, payload_err end
        local ok, set_err = safe_set(payload_key, payload)
        if not ok then return nil, set_err end
        ok, set_err = safe_set(sequence_key, sequence)
        if not ok then return nil, set_err end
        return { sequence = sequence, payload = payload }
    end

    function self.ReadKeySample(slot, consumer_id, expected_revision, expected_host_epoch, expected_capture_sequence, key, last_sequence)
        key = tostring(key or "")
        if key == "" then return nil, "key missing" end
        local safe_key = key:gsub("[^%w_%-]", "_")
        local sequence, sequence_err = safe_get(protocol.SlotKey(slot, "Key_" .. safe_key .. "_Sequence"))
        if sequence_err ~= nil then return nil, sequence_err end
        sequence = math.max(0, math.floor(tonumber(sequence) or 0))
        if sequence <= math.max(0, math.floor(tonumber(last_sequence) or 0)) then return nil, "key pending" end
        local payload, payload_err = safe_get(protocol.SlotKey(slot, "Key_" .. safe_key))
        if payload_err ~= nil then return nil, payload_err end
        local sample, sample_err = protocol.ValidateKeySample(
            payload, consumer_id, slot, expected_revision, expected_host_epoch, expected_capture_sequence, key)
        if sample == nil then return nil, sample_err end
        if tonumber(sample.sequence) ~= sequence then return nil, "key sequence mismatch" end
        return sample
    end

    function self.PublishAxisSample(slot, consumer_id, host_epoch, consumer_revision, axis, value, source, frame)
        axis = tostring(axis or "")
        if axis == "" then return nil, "axis missing" end
        local safe_axis = axis:gsub("[^%w_%-]", "_")
        local sequence_key = protocol.SlotKey(slot, "Axis_" .. safe_axis .. "_Sequence")
        local payload_key = protocol.SlotKey(slot, "Axis_" .. safe_axis)
        local current = tonumber((safe_get(sequence_key))) or 0
        local sequence = math.max(1, math.floor(current + 1))
        local payload, payload_err = protocol.BuildAxisSample(
            consumer_id, slot, host_epoch, consumer_revision, sequence, axis, value, source, frame)
        if payload == nil then return nil, payload_err end
        local ok, set_err = safe_set(payload_key, payload)
        if not ok then return nil, set_err end
        ok, set_err = safe_set(sequence_key, sequence)
        if not ok then return nil, set_err end
        return { sequence = sequence, payload = payload }
    end

    function self.ReadAxisSample(slot, consumer_id, expected_revision, expected_host_epoch, axis, last_sequence)
        axis = tostring(axis or "")
        if axis == "" then return nil, "axis missing" end
        local safe_axis = axis:gsub("[^%w_%-]", "_")
        local sequence, sequence_err = safe_get(protocol.SlotKey(slot, "Axis_" .. safe_axis .. "_Sequence"))
        if sequence_err ~= nil then return nil, sequence_err end
        sequence = math.max(0, math.floor(tonumber(sequence) or 0))
        if sequence <= math.max(0, math.floor(tonumber(last_sequence) or 0)) then return nil, "axis pending" end
        local payload, payload_err = safe_get(protocol.SlotKey(slot, "Axis_" .. safe_axis))
        if payload_err ~= nil then return nil, payload_err end
        local sample, sample_err = protocol.ValidateAxisSample(
            payload, consumer_id, slot, expected_revision, expected_host_epoch, axis)
        if sample == nil then return nil, sample_err end
        if tonumber(sample.sequence) ~= sequence then return nil, "axis sequence mismatch" end
        return sample
    end

    function self.PublishNativeInputEvent(slot, consumer_id, host_epoch, consumer_revision, request_sequence, generation, input_number, source, pointer_snapshot, route)
        local sequence_key = protocol.SlotKey(slot, "NativeInputEventSequence")
        local current = tonumber((safe_get(sequence_key))) or 0
        local sequence = math.max(1, math.floor(current + 1))
        local ring_size = math.max(4, math.floor(tonumber(protocol.NATIVE_INPUT_RING_SIZE) or 32))
        local ring_index = (sequence - 1) % ring_size
        local payload_key = protocol.SlotKey(slot, string.format("NativeInputEvent%02d", ring_index))
        local payload, payload_err = protocol.BuildNativeInputEvent(
            consumer_id, slot, host_epoch, consumer_revision, sequence, request_sequence, generation, input_number, source, pointer_snapshot, route)
        if payload == nil then return nil, payload_err end
        local ok, set_err = safe_set(payload_key, payload)
        if not ok then return nil, set_err end
        ok, set_err = safe_set(sequence_key, sequence)
        if not ok then return nil, set_err end
        return { sequence = sequence, payload = payload, ringIndex = ring_index }
    end

    function self.ReadNativeInputEvents(slot, consumer_id, expected_revision, expected_host_epoch, expected_request_sequence, last_sequence)
        local sequence_key = protocol.SlotKey(slot, "NativeInputEventSequence")
        local current, current_err = safe_get(sequence_key)
        if current_err ~= nil then return nil, current_err end
        current = math.max(0, math.floor(tonumber(current) or 0))
        last_sequence = math.max(0, math.floor(tonumber(last_sequence) or 0))
        if current <= last_sequence then
            return { sequence = current, events = {}, dropped = false }
        end
        local ring_size = math.max(4, math.floor(tonumber(protocol.NATIVE_INPUT_RING_SIZE) or 32))
        local first = last_sequence + 1
        local dropped = false
        if current - first + 1 > ring_size then
            first = current - ring_size + 1
            dropped = true
        end
        local events = {}
        for sequence = first, current do
            local ring_index = (sequence - 1) % ring_size
            local payload, payload_err = safe_get(protocol.SlotKey(slot, string.format("NativeInputEvent%02d", ring_index)))
            if payload_err ~= nil then
                dropped = true
            else
                local event = protocol.ValidateNativeInputEvent(
                    payload, consumer_id, slot, expected_revision, expected_host_epoch, expected_request_sequence)
                if type(event) == "table" and tonumber(event.sequence) == sequence then
                    events[#events + 1] = event
                else
                    dropped = true
                end
            end
        end
        return { sequence = current, events = events, dropped = dropped }
    end

    function self.PublishNavigationEvent(slot, consumer_id, host_epoch, consumer_revision, action, source)
        local sequence_key = protocol.SlotKey(slot, "NavigationEventSequence")
        local current = tonumber((safe_get(sequence_key))) or 0
        local sequence = math.max(1, math.floor(current + 1))
        local ring_size = math.max(4, math.floor(tonumber(protocol.NAVIGATION_RING_SIZE) or 16))
        local ring_index = (sequence - 1) % ring_size
        local payload_key = protocol.SlotKey(slot, string.format("NavigationEvent%02d", ring_index))
        local payload, payload_err = protocol.BuildNavigationEvent(
            consumer_id, slot, host_epoch, consumer_revision, sequence, action, source)
        if payload == nil then return nil, payload_err end
        local ok, set_err = safe_set(payload_key, payload)
        if not ok then return nil, set_err end
        ok, set_err = safe_set(sequence_key, sequence)
        if not ok then return nil, set_err end
        return { sequence = sequence, payload = payload, ringIndex = ring_index }
    end

    function self.ReadNavigationEvents(slot, consumer_id, expected_revision, expected_host_epoch, last_sequence)
        local sequence_key = protocol.SlotKey(slot, "NavigationEventSequence")
        local current, current_err = safe_get(sequence_key)
        if current_err ~= nil then return nil, current_err end
        current = math.max(0, math.floor(tonumber(current) or 0))
        last_sequence = math.max(0, math.floor(tonumber(last_sequence) or 0))
        if current <= last_sequence then
            return { sequence = current, events = {}, dropped = false }
        end
        local ring_size = math.max(4, math.floor(tonumber(protocol.NAVIGATION_RING_SIZE) or 16))
        local first = last_sequence + 1
        local dropped = false
        if current - first + 1 > ring_size then
            first = current - ring_size + 1
            dropped = true
        end
        local events = {}
        for sequence = first, current do
            local ring_index = (sequence - 1) % ring_size
            local payload, payload_err = safe_get(protocol.SlotKey(slot, string.format("NavigationEvent%02d", ring_index)))
            if payload_err ~= nil then
                dropped = true
            else
                local event, event_err = protocol.ValidateNavigationEvent(
                    payload, consumer_id, slot, expected_revision, expected_host_epoch)
                if type(event) == "table" and tonumber(event.sequence) == sequence then
                    events[#events + 1] = event
                else
                    dropped = true
                end
            end
        end
        return { sequence = current, events = events, dropped = dropped }
    end

    function self.PublishEvent(slot, consumer_id, host_epoch, consumer_revision, action, kind)
        local sequence_key = protocol.SlotKey(slot, "EventSequence")
        local payload_key = protocol.SlotKey(slot, "Event")
        local current = tonumber((safe_get(sequence_key))) or 0
        local sequence = math.max(1, math.floor(current + 1))
        local payload, payload_err = protocol.BuildInputEvent(
            consumer_id, slot, host_epoch, consumer_revision, sequence, action, kind)
        if payload == nil then return nil, payload_err end
        local ok, set_err = safe_set(payload_key, payload)
        if not ok then return nil, set_err end
        ok, set_err = safe_set(sequence_key, sequence)
        if not ok then return nil, set_err end
        return { sequence = sequence, payload = payload }
    end

    function self.ReadEvent(slot, consumer_id, expected_revision, expected_host_epoch, last_sequence)
        local sequence, sequence_err = safe_get(protocol.SlotKey(slot, "EventSequence"))
        if sequence_err ~= nil then return nil, sequence_err end
        sequence = math.max(0, math.floor(tonumber(sequence) or 0))
        if sequence <= math.max(0, math.floor(tonumber(last_sequence) or 0)) then return nil, "event pending" end
        local payload, payload_err = safe_get(protocol.SlotKey(slot, "Event"))
        if payload_err ~= nil then return nil, payload_err end
        local event, event_err = protocol.ValidateInputEvent(
            payload, consumer_id, slot, expected_revision, expected_host_epoch)
        if event == nil then return nil, event_err end
        if tonumber(event.sequence) ~= sequence then return nil, "event sequence mismatch" end
        return event
    end

    return self
end

return M
