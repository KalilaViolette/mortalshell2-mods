-- MortalShell2ModUI Host.InputService
-- Standalone physical OPEN-HOTKEY + controller-analog host. It consumes declarative
-- keyboard/controller bindings from Host.Registry, performs physical key/axis polling once
-- in the ModUI Lua state, and publishes primitive action events/axis samples back to each
-- consumer slot.
--
-- It intentionally does NOT own the game's native menu mapping or consumer Settings/
-- Voice Browser action semantics. Pass 130 makes the Pass-129-proven canonical menu lease
-- authoritative for the healthy host-owned native-listener path. A HOST_NATIVE_LISTENER_TOKEN
-- request may create/retain the standalone WBP_InputListener and publish its events only while
-- the canonical lease is granted to the exact consumer/slot/revision/generation. Legacy numeric
-- listener-address requests remain mutually-exclusive fail-soft fallback compatibility.
-- Pass 140 gates the process-wide native callback mirror by exact primitive request/address BEFORE any pointer/controller snapshot work, so unrelated game-owned WBP_InputListener callbacks during travel remain inert.
-- Pass 123 moved pointer semantics onto the proven callback-time host snapshot; Pass 122
-- corrected standalone pointer acquisition through BPFL_UI normalized input,
-- WidgetLayoutLibrary, then PlayerController out-parameters.
-- Pass 121 extended the proven standalone WBP_InputListener callback event with optional
-- primitive pointer snapshot fields captured at callback time.
-- Pass 117 added the standalone WBP_InputListener InputTriggeredCallback mirror. The hook
-- publishes revision/epoch/request-bound native input enums for the exact active consumer
-- listener address.
-- Pass 116 moves the fixed UE4SS keyboard navigation RegisterKeyBind owner into the
-- standalone ModUI state. Host callbacks publish primitive sequence-numbered navigation
-- events; consumer states retain all Settings/Voice Browser action semantics.
-- Pass 115 extends the proven on-demand DIGITAL binding-capture mailbox to keyboard recording.
-- The broad keyboard catalog and fourteen controller buttons are queried/published only while a
-- revision/epoch/capture-sequence-bound recording request of that exact kind is active; idle polling
-- does not scan either capture catalog.
-- Pass 114 added on-demand controller DIGITAL binding-capture sampling to that same poll.
-- Pass 113 expands the proven RightY mailbox to all controller axes needed by capture/browser
-- consumers while retaining the same single 50 ms live-controller poll.
-- Pass 182 adds a non-capture shared controller-feed request for gameplay consumers. The
-- physical host remains profile-agnostic and publishes coherent raw axes; consumer facades
-- apply the current shared Controller.Profile automatically unless a mod explicitly overrides it.

local M = {}

local ANALOG_AXES = {
    "Gamepad_LeftX",
    "Gamepad_LeftY",
    "Gamepad_RightX",
    "Gamepad_RightY",
    "Gamepad_LeftTriggerAxis",
    "Gamepad_RightTriggerAxis",
}

local CONTROLLER_CAPTURE_KEYS = {
    "Gamepad_LeftThumbstick", "Gamepad_RightThumbstick",
    "Gamepad_FaceButton_Bottom", "Gamepad_FaceButton_Right", "Gamepad_FaceButton_Left", "Gamepad_FaceButton_Top",
    "Gamepad_LeftShoulder", "Gamepad_RightShoulder",
    "Gamepad_DPad_Up", "Gamepad_DPad_Down", "Gamepad_DPad_Left", "Gamepad_DPad_Right",
    "Gamepad_Special_Left", "Gamepad_Special_Right",
}

local KEYBOARD_CAPTURE_KEYS = {
    "LeftControl", "RightControl", "LeftShift", "RightShift", "LeftAlt", "RightAlt",
    "A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M",
    "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z",
    "Zero", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine",
    "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12",
    "SpaceBar", "Tab", "Enter", "Escape", "BackSpace", "Insert", "Delete", "Home", "End", "PageUp", "PageDown",
    "Up", "Down", "Left", "Right", "CapsLock", "NumLock", "ScrollLock",
    "Semicolon", "Equals", "Comma", "Hyphen", "Period", "Slash", "Tilde",
    "LeftBracket", "Backslash", "RightBracket", "Apostrophe",
    "NumPadZero", "NumPadOne", "NumPadTwo", "NumPadThree", "NumPadFour",
    "NumPadFive", "NumPadSix", "NumPadSeven", "NumPadEight", "NumPadNine",
    "Decimal", "Divide", "Multiply", "Subtract", "Add",
}

function M.Bind(registry, service, protocol, physical_binding, binding, options)
    options = type(options) == "table" and options or {}
    if type(registry) ~= "table" or type(registry.ReadRegistryRevision) ~= "function"
        or type(registry.Scan) ~= "function" or type(registry.PublishEvent) ~= "function"
        or type(registry.PublishAxisSample) ~= "function"
        or type(registry.ReadCaptureRequest) ~= "function" or type(registry.ReadControllerRequest) ~= "function"
        or type(registry.PublishKeySample) ~= "function"
        or type(registry.PublishNavigationEvent) ~= "function"
        or type(registry.ReadNativeInputRequest) ~= "function" or type(registry.PublishNativeInputEvent) ~= "function"
        or type(registry.SetHotkeyState) ~= "function" then
        return nil, "Host.InputService registry API incomplete"
    end
    if type(service) ~= "table" or type(service.ScanAndAcknowledge) ~= "function" then
        return nil, "Host.InputService requires Host.Service"
    end
    if type(protocol) ~= "table" then return nil, "Host.InputService requires Host.Protocol" end
    if type(physical_binding) ~= "table" or type(physical_binding.New) ~= "function" then
        return nil, "Host.InputService requires Runtime.PhysicalBinding"
    end
    if type(binding) ~= "table" then return nil, "Host.InputService requires Input.Binding" end

    local host_epoch = tostring(options.host_epoch or "")
    local get_controller = options.get_controller
    local schedule = options.schedule
    local unwrap = options.unwrap
    local valid = options.valid
    local FName = options.fname
    local log = options.log or function() end
    local register_navigation_bindings = options.register_navigation_bindings
    local capture_pointer_snapshot = options.capture_pointer_snapshot
    local native_listener_shadow_tick = options.native_listener_shadow_tick
    local menu_registry_reconcile = options.menu_registry_reconcile
    local menu_session_tick = options.menu_session_tick
    local native_semantic_tick = options.native_semantic_tick
    local menu_active_consumer = options.menu_active_consumer
    local menu_hotkey_owner = options.menu_hotkey_owner
    local native_listener_address = options.native_listener_address
    local native_listener_route = options.native_listener_route
    local invalidate_controller_cache = options.invalidate_controller_cache
    local controller_profile = options.controller_profile
    -- Profiler (Core/Perf.lua instance of the standalone host) and the once-a-second
    -- consumer-flag check that turns it on. Both optional; nil-safe.
    local perf = type(options.perf) == "table" and options.perf or nil
    local perf_sync = type(options.perf_sync) == "function" and options.perf_sync or nil
    if type(get_controller) ~= "function" then return nil, "get_controller missing" end
    if type(schedule) ~= "function" then return nil, "schedule missing" end
    if type(unwrap) ~= "function" or type(valid) ~= "function" or type(FName) ~= "function" then
        return nil, "physical adapters missing"
    end

    local controller_analog = options.controller_analog
    if type(controller_analog) ~= "table" or type(controller_analog.New) ~= "function" then
        return nil, "Runtime.ControllerAnalog missing"
    end

    local raw_evaluator, raw_err = physical_binding.New(binding, {
        unwrap = unwrap,
        valid = valid,
        fname = FName,
        input_time_seconds = options.input_time_seconds,
        binding_label = function(value) return binding.Label(value, value, false) end,
    })
    if raw_evaluator == nil then return nil, raw_err end

    local analog_reader, analog_err = controller_analog.New({
        unwrap = unwrap,
        valid = valid,
        analog_value = raw_evaluator.AnalogValue,
        key_down = raw_evaluator.KeyDown,
    })
    if analog_reader == nil then return nil, analog_err end

    local hosted_axis = {}
    for _, axis in ipairs(ANALOG_AXES) do hosted_axis[axis] = true end

    local controller_profile_revision = -1
    local controller_profile_cache = nil
    local function current_controller_profile(force)
        if type(controller_profile) ~= "table" or type(controller_profile.Current) ~= "function" then return nil end
        local revision = controller_profile_revision
        if type(registry.ReadControllerProfileRevision) == "function" then
            local value = select(1, registry.ReadControllerProfileRevision())
            if tonumber(value) ~= nil then revision = math.max(0, math.floor(tonumber(value) or 0)) end
        end
        if force == true or controller_profile_cache == nil or revision ~= controller_profile_revision then
            if type(controller_profile.Reload) == "function" then pcall(controller_profile.Reload) end
            controller_profile_cache = controller_profile.Current()
            controller_profile_revision = revision
        end
        return controller_profile_cache
    end

    local evaluator, evaluator_err = physical_binding.New(binding, {
        unwrap = unwrap,
        valid = valid,
        fname = FName,
        input_time_seconds = options.input_time_seconds,
        binding_label = function(value) return binding.Label(value, value, false) end,
        analog_override = function(controller, axis_key)
            axis_key = tostring(axis_key or "")
            if hosted_axis[axis_key] then
                local value, source = analog_reader.Axis(controller, axis_key)
                return true, value, source
            end
            return false
        end,
        analog_policy = function(axis_key, direction, value, was_active)
            local profile = current_controller_profile(false)
            if type(profile) == "table" and type(controller_profile.AxisActive) == "function" then
                return controller_profile.AxisActive(axis_key, direction, value, was_active, profile)
            end
            return nil
        end,
    })
    if evaluator == nil then return nil, evaluator_err end

    local self = {
        armed = false,
        last_registry_revision = -1,
        consumers = {},
        controller = nil,
        controller_available = false,
        poll_count = 0,
        event_count = 0,
        axis_sample_count = 0,
        axis_cache = {},
        key_sample_count = 0,
        key_cache = {},
        capture_request_sequences = {},
        menu_action_sequence = 0,
        navigation_registered = false,
        navigation_event_count = 0,
        native_input_event_count = 0,
        native_listener_authority_signature = "",
        -- v0.70.0 hold-to-reset: per physical key { since = seconds, fired = bool }.
        hold_state = {},
        hold_reset_count = 0,
    }

    -- v0.70.0: holding R (keyboard) or L3 (controller) for HOLD_RESET_SECONDS while a
    -- hosted settings window is open publishes one "reset-row" navigation action, which
    -- the consumer applies to its selected row only. Tracked from the same 50 ms poll as
    -- the hosted hotkeys: no extra timers, no key binds, nothing while no menu is open.
    local HOLD_RESET_SECONDS = tonumber(options.hold_reset_seconds) or 5.0
    local HOLD_RESET_KEYS = {
        { key = "R", source = "hold:R" },
        { key = "Gamepad_LeftThumbstick", source = "hold:L3" },
    }
    local hold_clock = type(options.input_time_seconds) == "function" and options.input_time_seconds
        or function() return os.clock() end

    local hold_was_active = false
    local function tick_hold_reset(controller, capture_active_any)
        local active = self.controller_available and not capture_active_any
            and type(menu_active_consumer) == "function" and menu_active_consumer() ~= nil
        if not active then
            if next(self.hold_state) ~= nil then self.hold_state = {} end
            hold_was_active = false
            return false
        end
        local now = tonumber((hold_clock())) or 0 -- first return only; the source label is second
        local fresh = not hold_was_active
        hold_was_active = true
        local fired_any = false
        for _, spec in ipairs(HOLD_RESET_KEYS) do
            local down = raw_evaluator.KeyDown(controller, spec.key)
            local state = self.hold_state[spec.key]
            if down == true then
                if state == nil then
                    -- A key already down when the menu became active (TTS opens on L3+R3)
                    -- must be released before it can start a hold.
                    state = { since = now, fired = fresh }
                    self.hold_state[spec.key] = state
                end
                if not state.fired and now - state.since >= HOLD_RESET_SECONDS then
                    state.fired = true
                    self.hold_reset_count = self.hold_reset_count + 1
                    self.PublishNavigation("reset-row", spec.source)
                    fired_any = true
                end
            elseif state ~= nil then
                self.hold_state[spec.key] = nil
            end
        end
        return fired_any
    end
    self.TickHoldReset = tick_hold_reset

    local function host_native_request_authorized(consumer, request)
        if type(request) ~= "table" or request.active ~= true then
            return false, nil, "request-inactive"
        end
        if tostring(request.listenerAddress or "") ~= tostring(protocol.HOST_NATIVE_LISTENER_TOKEN or "host") then
            return false, nil, "consumer-fallback-request"
        end
        if type(registry.ReadMenuLeaseState) ~= "function" then
            return false, nil, "menu-lease-state-unavailable"
        end
        local lease = registry.ReadMenuLeaseState()
        if type(lease) ~= "table" then return false, lease, "menu-lease-unavailable" end
        local expected_slot = math.floor(tonumber(consumer.slot) or -1)
        local expected_revision = math.max(0, math.floor(tonumber(consumer.revision) or 0))
        local expected_generation = math.max(0, math.floor(tonumber(request.generation) or 0))
        local authorized = tostring(lease.state or "") == "granted"
            and tostring(lease.consumer or "") == tostring(consumer.consumer or "")
            and math.floor(tonumber(lease.slot) or -1) == expected_slot
            and math.max(0, math.floor(tonumber(lease.revision) or 0)) == expected_revision
            and math.max(0, math.floor(tonumber(lease.generation) or 0)) == expected_generation
            and tostring(lease.hostEpoch or "") == tostring(host_epoch or "")
        return authorized, lease, authorized and "granted" or "lease-mismatch"
    end

    local function note_host_native_lease_authority(consumer, request, authorized, lease, reason)
        local signature = table.concat({
            authorized and "authorized" or "blocked",
            tostring(consumer and consumer.consumer or ""),
            tostring(consumer and consumer.slot or -1),
            tostring(consumer and consumer.revision or 0),
            tostring(request and request.generation or 0),
            tostring(lease and lease.state or "unavailable"),
            tostring(lease and lease.revision or 0),
            tostring(lease and lease.generation or 0),
            tostring(reason or ""),
        }, "|")
        if signature == self.native_listener_authority_signature then return end
        self.native_listener_authority_signature = signature
        log("host native listener lease authority state=" .. (authorized and "authorized" or "blocked")
            .. " consumer=" .. tostring(consumer and consumer.consumer or "")
            .. " slot=" .. tostring(consumer and consumer.slot or -1)
            .. " revision=" .. tostring(consumer and consumer.revision or 0)
            .. " generation=" .. tostring(request and request.generation or 0)
            .. " leaseState=" .. tostring(lease and lease.state or "unavailable")
            .. " leaseRevision=" .. tostring(lease and lease.revision or 0)
            .. " leaseGeneration=" .. tostring(lease and lease.generation or 0)
            .. " reason=" .. tostring(reason or ""))
    end

    local function supports_binding(value)
        value = tostring(value or "")
        if value == "" or value:lower() == "off" then return true end
        return true
    end

    local function refresh_consumers(force)
        local registry_revision, revision_err = registry.ReadRegistryRevision()
        if registry_revision == nil then return false, revision_err end
        if not force and registry_revision == self.last_registry_revision then return true end

        local report, scan_err = service.ScanAndAcknowledge(host_epoch, force == true)
        if report == nil then return false, scan_err end
        if type(menu_registry_reconcile) == "function" then
            local menu_ok, menu_result, menu_err = pcall(menu_registry_reconcile, report.registrations or {})
            if not menu_ok then
                log("host menu provider refresh failed: " .. tostring(menu_result))
            elseif menu_result == false then
                log("host menu provider refresh unavailable: " .. tostring(menu_err))
            end
        end
        local entries = registry.Scan() or {}
        local next_consumers = {}
        for _, entry in ipairs(entries) do
            local fields = type(entry) == "table" and entry.fields or nil
            if type(fields) == "table" then
                local wants_hotkeys = tostring(fields.hotkeys or "0") == "1"
                local wants_native_input = tostring(fields.nativeInput or "0") == "1"
                local supports_controller_feed = tostring(fields.controllerFeed or "0") == "1"
                if wants_hotkeys or wants_native_input or supports_controller_feed then
                    local keyboard = tostring(fields.openKeyboard or "")
                    local controller = tostring(fields.openController or "")
                    local compatible = supports_binding(keyboard) and supports_binding(controller)
                    if wants_hotkeys then
                        registry.SetHotkeyState(entry.slot, entry.consumer, host_epoch, entry.revision, compatible and "ready" or "consumer-fallback")
                    end
                    next_consumers[tostring(entry.consumer)] = {
                        consumer = tostring(entry.consumer),
                        slot = tonumber(entry.slot),
                        revision = tonumber(entry.revision) or 0,
                        keyboard = keyboard,
                        controller = controller,
                        modifier_sides_equivalent = tostring(fields.modifierSides or "0") == "1",
                        keyboard_navigation = tostring(fields.keyboardNavigation or "0") == "1",
                        native_input = wants_native_input,
                        controller_feed = supports_controller_feed,
                        hotkeys = wants_hotkeys,
                        compatible = compatible,
                        keyboard_latched = false,
                        controller_latched = false,
                    }
                end
            end
        end
        self.consumers = next_consumers
        self.last_registry_revision = registry_revision
        self.axis_cache = {}
        self.key_cache = {}
        self.capture_request_sequences = {}
        evaluator.Reset()
        return true
    end

    local function evaluate(consumer, controller, value, kind)
        if binding.IsSequence(value) then
            return evaluator.SequenceTriggered(
                controller, value, consumer.consumer .. ":" .. kind, consumer.modifier_sides_equivalent)
        end
        return evaluator.IsDown(controller, value, consumer.modifier_sides_equivalent)
    end

    local function publish(consumer, kind, target)
        target = type(target) == "table" and target or consumer
        local event, event_err = registry.PublishEvent(
            target.slot, target.consumer, host_epoch, target.revision, "open-settings", kind)
        if event == nil then
            log("host input event publish failed consumer=" .. tostring(target.consumer) .. " kind=" .. tostring(kind) .. " error=" .. tostring(event_err))
            return false
        end
        self.event_count = self.event_count + 1
        if type(registry.SetMenuAction) == "function" then
            self.menu_action_sequence = math.max(0, math.floor(tonumber(self.menu_action_sequence) or 0)) + 1
            local action_result, action_err = registry.SetMenuAction(
                target.slot, target.consumer, target.revision, self.menu_action_sequence, 0,
                "toggle-menu", kind, "hotkeyOwner=" .. tostring(consumer.consumer or ""))
            if action_result == nil then
                log("host menu action publish failed consumer=" .. tostring(target.consumer)
                    .. " kind=" .. tostring(kind) .. " error=" .. tostring(action_err))
            end
        end
        return true
    end

    local function publish_axis(consumer, axis, value, source, force, frame)
        value = tonumber(value) or 0.0
        source = tostring(source or "unavailable")
        local cache_key = tostring(consumer.consumer) .. "|" .. tostring(consumer.revision) .. "|" .. tostring(axis)
        local prior = self.axis_cache[cache_key]
        local heartbeat = prior == nil or (self.poll_count - (tonumber(prior.poll) or 0)) >= 10
        local changed = prior == nil
            or math.abs(value - (tonumber(prior.value) or 0.0)) >= 0.01
            or tostring(prior.source or "") ~= source
        if not force and not heartbeat and not changed then return true end

        local sample, sample_err = registry.PublishAxisSample(
            consumer.slot, consumer.consumer, host_epoch, consumer.revision,
            axis, value, source, frame)
        if sample == nil then
            log("host analog sample publish failed consumer=" .. tostring(consumer.consumer)
                .. " axis=" .. tostring(axis) .. " error=" .. tostring(sample_err))
            return false
        end
        self.axis_cache[cache_key] = { value = value, source = source, poll = self.poll_count }
        self.axis_sample_count = self.axis_sample_count + 1
        return true
    end

    local function publish_analog_axes(consumer, controller)
        local capture_request = registry.ReadCaptureRequest(
            consumer.slot, consumer.consumer, consumer.revision, host_epoch)
        local controller_request = registry.ReadControllerRequest(
            consumer.slot, consumer.consumer, consumer.revision, host_epoch)
        local coherent_capture = type(capture_request) == "table"
            and capture_request.active == true
            and (tostring(capture_request.kind or "") == "controller"
                or tostring(capture_request.kind or "") == "controller-sampling")
        local shared_feed = type(controller_request) == "table" and controller_request.active == true
        local coherent_analog = (coherent_capture or shared_feed) and type(analog_reader.Stick) == "function"
        local frame = math.max(0, math.floor(tonumber(self.poll_count) or 0))

        if controller ~= nil and coherent_analog then
            -- Raw acquisition is intentionally profile-agnostic. The host publishes each stick
            -- as one coherent X/Y pair; Controller.Profile is applied in the consumer facade.
            -- This means every consumer can inherit updated calibration without altering the
            -- physical-source arbitration or the proven hotkey path.
            local lx, ly, lxs, lys = analog_reader.Stick(controller, "left")
            local rx, ry, rxs, rys = analog_reader.Stick(controller, "right")
            publish_axis(consumer, "Gamepad_LeftX", tonumber(lx) or 0.0, tostring(lxs or "unavailable"), true, frame)
            publish_axis(consumer, "Gamepad_LeftY", tonumber(ly) or 0.0, tostring(lys or "unavailable"), true, frame)
            publish_axis(consumer, "Gamepad_RightX", tonumber(rx) or 0.0, tostring(rxs or "unavailable"), true, frame)
            publish_axis(consumer, "Gamepad_RightY", tonumber(ry) or 0.0, tostring(rys or "unavailable"), true, frame)
            for _, axis in ipairs({ "Gamepad_LeftTriggerAxis", "Gamepad_RightTriggerAxis" }) do
                local value, source = analog_reader.Axis(controller, axis)
                if value == nil then value, source = 0.0, tostring(source or "unavailable") end
                publish_axis(consumer, axis, value, source, false, frame)
            end
        elseif controller ~= nil then
            for _, axis in ipairs(ANALOG_AXES) do
                local value, source = analog_reader.Axis(controller, axis)
                if value == nil then value, source = 0.0, tostring(source or "unavailable") end
                publish_axis(consumer, axis, value, source, false, frame)
            end
        else
            for _, axis in ipairs(ANALOG_AXES) do
                publish_axis(consumer, axis, 0.0, "controller-unavailable", coherent_analog, frame)
            end
        end
    end

    local function publish_key(consumer, capture_sequence, key, down, source, force)
        down = down == true
        source = tostring(source or key or "unavailable")
        local cache_key = tostring(consumer.consumer) .. "|" .. tostring(consumer.revision) .. "|" .. tostring(key)
        local prior = self.key_cache[cache_key]
        local same_capture = type(prior) == "table"
            and tonumber(prior.capture_sequence) == tonumber(capture_sequence)
        local press_sequence = same_capture and math.max(0, math.floor(tonumber(prior.press_sequence) or 0)) or 0
        if down and (not same_capture or prior.down ~= true) then
            press_sequence = press_sequence + 1
        end
        local heartbeat = prior == nil or not same_capture
            or (self.poll_count - (tonumber(prior.poll) or 0)) >= 10
        local changed = prior == nil or not same_capture or prior.down ~= down
            or tostring(prior.source or "") ~= source
        if not force and not heartbeat and not changed then return true end
        local sample, sample_err = registry.PublishKeySample(
            consumer.slot, consumer.consumer, host_epoch, consumer.revision, capture_sequence, key, down, source, press_sequence)
        if sample == nil then
            log("host capture sample publish failed consumer=" .. tostring(consumer.consumer)
                .. " key=" .. tostring(key) .. " error=" .. tostring(sample_err))
            return false
        end
        self.key_cache[cache_key] = {
            down = down, source = source, poll = self.poll_count,
            capture_sequence = capture_sequence, press_sequence = press_sequence,
        }
        self.key_sample_count = self.key_sample_count + 1
        return true
    end

    -- Pass 131: shared analog samples are consumer-facing Settings/capture data,
    -- not a requirement for the standalone OPEN-HOTKEY evaluator itself. Avoid six
    -- controller-axis reads per consumer on every permanent idle host tick. Axis-based
    -- open bindings still read the requested axis directly through evaluator.IsDown().
    local function consumer_needs_analog_samples(consumer)
        local native_request = registry.ReadNativeInputRequest(
            consumer.slot, consumer.consumer, consumer.revision, host_epoch)
        if type(native_request) == "table" and native_request.active == true then return true end
        local controller_request = registry.ReadControllerRequest(
            consumer.slot, consumer.consumer, consumer.revision, host_epoch)
        if type(controller_request) == "table" and controller_request.active == true then return true end
        local capture_request = registry.ReadCaptureRequest(
            consumer.slot, consumer.consumer, consumer.revision, host_epoch)
        return type(capture_request) == "table"
            and capture_request.active == true
            and (tostring(capture_request.kind or "") == "controller"
                or tostring(capture_request.kind or "") == "controller-sampling")
    end

    local function publish_capture_keys(consumer, controller)
        local request = registry.ReadCaptureRequest(
            consumer.slot, consumer.consumer, consumer.revision, host_epoch)
        if type(request) ~= "table" then return false end
        local request_key = tostring(consumer.consumer) .. "|" .. tostring(consumer.revision)
        local request_sequence = math.max(0, math.floor(tonumber(request.sequence) or 0))
        local new_request = self.capture_request_sequences[request_key] ~= request_sequence
        self.capture_request_sequences[request_key] = request_sequence
        if request.active ~= true then return false end
        local capture_keys = request.kind == "keyboard" and KEYBOARD_CAPTURE_KEYS
            or (request.kind == "controller" or request.kind == "controller-sampling") and CONTROLLER_CAPTURE_KEYS or nil
        if capture_keys == nil then return false end
        for _, key in ipairs(capture_keys) do
            local down, key_err, source = false, nil, tostring(request.kind) .. "-unavailable"
            if controller ~= nil then
                down, key_err = raw_evaluator.KeyDown(controller, key)
                source = key_err == nil and key or ("fallback:" .. tostring(key_err))
            end
            if down == nil then down = false end
            publish_key(consumer, request_sequence, key, down == true, source, new_request)
        end
        return true
    end

    local function publish_generic_menu_action(consumer, generation, action, source, payload)
        if type(registry.SetMenuAction) ~= "function" or type(consumer) ~= "table" then return false end
        self.menu_action_sequence = math.max(0, math.floor(tonumber(self.menu_action_sequence) or 0)) + 1
        local result, action_err = registry.SetMenuAction(
            consumer.slot, consumer.consumer, consumer.revision, self.menu_action_sequence,
            math.max(0, math.floor(tonumber(generation) or 0)), tostring(action or ""),
            tostring(source or "host"), tostring(payload or ""))
        if result == nil then
            log("host generic menu action publish failed consumer=" .. tostring(consumer.consumer)
                .. " action=" .. tostring(action) .. " error=" .. tostring(action_err))
            return false
        end
        return true
    end

    local function is_active_menu_consumer(consumer)
        if type(consumer) ~= "table" then return false end
        if type(menu_active_consumer) ~= "function" then return true end
        local active = menu_active_consumer()
        return type(active) == "table"
            and tostring(active.consumer or "") == tostring(consumer.consumer or "")
            and math.floor(tonumber(active.slot) or -1) == math.floor(tonumber(consumer.slot) or -1)
            and math.max(0, math.floor(tonumber(active.revision) or 0)) == math.max(0, math.floor(tonumber(consumer.revision) or 0))
    end

    function self.PublishNavigation(action, source)
        action = tostring(action or "")
        if action == "" then return false, "navigation action missing" end
        local published = 0
        for _, consumer in pairs(self.consumers) do
            if consumer.compatible and consumer.keyboard_navigation then
                local event, event_err = registry.PublishNavigationEvent(
                    consumer.slot, consumer.consumer, host_epoch, consumer.revision, action, source)
                if event == nil then
                    log("host navigation event publish failed consumer=" .. tostring(consumer.consumer)
                        .. " action=" .. tostring(action) .. " error=" .. tostring(event_err))
                else
                    published = published + 1
                    self.navigation_event_count = self.navigation_event_count + 1
                    if is_active_menu_consumer(consumer) then
                        publish_generic_menu_action(consumer, 0, action, source, "navigation")
                    end
                end
            end
        end
        return published > 0, published
    end

    function self.NavigationReady()
        return self.navigation_registered == true
    end

    -- Pass 140 corrective: the process-wide InputTriggeredCallback hook also sees game-owned
    -- WBP_InputListener instances during Main Menu/loading/world travel. Pass 139 captured an
    -- unrelated native listener callback while TTS had no active Settings request, yet this
    -- function resolved/captured live PlayerController/pointer state BEFORE checking whether
    -- any consumer actually requested that listener address. During travel that supposedly
    -- passive mirror therefore touched unstable world/UI UObjects and reproduced the recurring
    -- CBADB8CF... UE4SS AV even with zero TTS Settings sessions.
    --
    -- Build a primitive request/address match set first. Until at least one exact active request
    -- matches the callback Context, do not resolve a controller, capture pointer state, inspect a
    -- route, or touch any listener/world UObject beyond the callback's already-supplied address.
    local function matching_native_input_targets(address_text)
        local targets = {}
        for _, consumer in pairs(self.consumers) do
            if consumer.compatible and consumer.native_input then
                local request = registry.ReadNativeInputRequest(
                    consumer.slot, consumer.consumer, consumer.revision, host_epoch)
                if type(request) == "table" and request.active == true then
                    local requested_address = tostring(request.listenerAddress or "")
                    local host_owned = requested_address == tostring(protocol.HOST_NATIVE_LISTENER_TOKEN or "host")
                    local address_matches = requested_address == address_text
                    if host_owned and not address_matches and type(native_listener_address) == "function" then
                        -- Host-owned listener address is already retained as primitive host state.
                        -- Only consult it for an explicitly active HOST_NATIVE_LISTENER request.
                        local host_address = tostring(native_listener_address() or "")
                        address_matches = host_address ~= "" and host_address == address_text
                    end
                    if address_matches then
                        local authorized = true
                        if host_owned then
                            local lease_ok, lease, lease_reason = host_native_request_authorized(consumer, request)
                            authorized = lease_ok == true
                            note_host_native_lease_authority(consumer, request, authorized, lease, lease_reason)
                        end
                        if authorized then
                            targets[#targets + 1] = {
                                consumer = consumer,
                                request = request,
                                host_owned = host_owned,
                            }
                        end
                    end
                end
            end
        end
        return targets
    end

    function self.PublishNativeInput(context_address, input_number)
        context_address = tonumber(context_address)
        input_number = tonumber(input_number)
        if context_address == nil or input_number == nil then return false, 0 end
        local address_text = string.format("%.0f", context_address)

        -- Critical Pass-140 ordering invariant: reject unrelated native callbacks using only
        -- primitive registry/address state before any callback-time pointer/controller work.
        local targets = matching_native_input_targets(address_text)
        if #targets == 0 then return false, 0 end

        local pointer_snapshot = nil
        if type(capture_pointer_snapshot) == "function" then
            local pointer_ok, candidate = pcall(capture_pointer_snapshot)
            if pointer_ok and type(candidate) == "table" then pointer_snapshot = candidate end
        end

        local published = 0
        for _, target in ipairs(targets) do
            local consumer = target.consumer
            local request = target.request
            local route = nil
            if target.host_owned and type(native_listener_route) == "function" then
                local route_ok, route_value = pcall(native_listener_route, math.floor(input_number), address_text)
                if route_ok then route = route_value end
            end
            local event, event_err = registry.PublishNativeInputEvent(
                consumer.slot, consumer.consumer, host_epoch, consumer.revision,
                request.sequence, request.generation, math.floor(input_number), "WBP_InputListener", pointer_snapshot, route)
            if event == nil then
                log("host native input event publish failed consumer=" .. tostring(consumer.consumer)
                    .. " input=" .. tostring(input_number) .. " error=" .. tostring(event_err))
            else
                published = published + 1
                self.native_input_event_count = self.native_input_event_count + 1
                if type(route) == "string" and route ~= "" then
                    publish_generic_menu_action(consumer, request.generation, route, "native",
                        "input=" .. tostring(math.floor(input_number)) .. ";address=" .. address_text)
                end
            end
        end
        return published > 0, published
    end

    local function consumer_is_hotkey_owner(consumer)
        -- v0.65: every opted-in provider owns its own physical binding. The former
        -- single "active provider" owner made one mod's binding open whichever page
        -- happened to be selected (for example, TTS's binding opened Minimap).
        -- Binding conflicts remain deterministic because each event is delivered only
        -- to the descriptor whose binding actually matched.
        return type(consumer) == "table"
            and consumer.compatible == true
            and consumer.hotkeys == true
    end

    local function consumer_needs_controller_poll(consumer)
        if type(consumer) ~= "table" or consumer.compatible ~= true then return false end
        if consumer_is_hotkey_owner(consumer) then return true end
        local native_request = registry.ReadNativeInputRequest(
            consumer.slot, consumer.consumer, consumer.revision, host_epoch)
        if type(native_request) == "table" and native_request.active == true then return true end
        local controller_request = registry.ReadControllerRequest(
            consumer.slot, consumer.consumer, consumer.revision, host_epoch)
        if type(controller_request) == "table" and controller_request.active == true then return true end
        local capture_request = registry.ReadCaptureRequest(
            consumer.slot, consumer.consumer, consumer.revision, host_epoch)
        return type(capture_request) == "table" and capture_request.active == true
    end

    local poll_body
    -- The standalone host's only permanent loop: 250 ms idle, 50 ms while a hosted
    -- hotkey needs the controller, 20 ms during binding capture, 10 ms for calibration.
    -- `poll` is the whole step, `poll.interval` its spacing, and the stages below each
    -- carry their own section. This is also where the host's profiler is synced to the
    -- consumers' flags and where its summary timer is ticked.
    function self.Poll()
        if perf_sync ~= nil then perf_sync() end
        if perf == nil or not perf.enabled then return poll_body() end
        perf.Mark("poll.interval")
        local token = perf.Begin()
        local result = poll_body()
        perf.End("poll", token)
        perf.Tick()
        return result
    end

    local function stage_begin()
        if perf == nil or not perf.enabled then return nil end
        return perf.Begin()
    end
    local function stage_end(name, token)
        if token ~= nil then perf.End(name, token) end
    end

    poll_body = function()
        self.poll_count = self.poll_count + 1
        local stage = stage_begin()
        local refresh_ok, refresh_err = refresh_consumers(false)
        stage_end("poll.refresh-consumers", stage)
        if not refresh_ok then log("host input registry refresh failed: " .. tostring(refresh_err)) end

        -- Pass 134: an opted-out/idle consumer should not make the standalone state retain,
        -- validate, or query a PlayerController merely because Host.InputService exists.
        -- Resolve a controller only while a hosted hotkey, native-input/analog session, or
        -- binding capture actually needs one. This both sharpens the crash A/B and preserves
        -- the Pass-131 idle-performance win.
        local needs_controller = false
        for _, consumer in pairs(self.consumers) do
            if consumer_needs_controller_poll(consumer) then
                needs_controller = true
                break
            end
        end
        local controller = nil
        if needs_controller then
            stage = stage_begin()
            controller = unwrap(get_controller())
            stage_end("poll.controller", stage)
        elseif type(invalidate_controller_cache) == "function" then
            -- Pass 154: when every consumer has relinquished hotkey/native/capture demand
            -- (notably the synchronous LoadMap quarantine), discard the standalone cached
            -- PlayerController by assignment only. Never discover world teardown by validating
            -- an old wrapper after LoadMap has started.
            pcall(invalidate_controller_cache, "no-controller-demand")
        end
        self.controller_available = needs_controller and valid(controller)
        self.controller = self.controller_available and controller or nil
        local capture_active_any = false
        local controller_sampling_active_any = false
        local controller_feed_active_any = false
        stage = stage_begin()
        for _, consumer in pairs(self.consumers) do
            if consumer.compatible then
                local controller_request = registry.ReadControllerRequest(
                    consumer.slot, consumer.consumer, consumer.revision, host_epoch)
                if type(controller_request) == "table" and controller_request.active == true then
                    controller_feed_active_any = true
                end
                if consumer_needs_analog_samples(consumer) then
                    publish_analog_axes(consumer, self.controller_available and controller or nil)
                end
                local capture_active = publish_capture_keys(consumer, self.controller_available and controller or nil) == true
                if capture_active then
                    capture_active_any = true
                    local capture_request = registry.ReadCaptureRequest(
                        consumer.slot, consumer.consumer, consumer.revision, host_epoch)
                    if type(capture_request) == "table" and capture_request.active == true
                        and tostring(capture_request.kind or "") == "controller-sampling" then
                        controller_sampling_active_any = true
                    end
                end
                -- Pass 155: binding capture has exclusive physical-key authority for this consumer.
                -- Never evaluate the currently saved OPEN-HOTKEY while those same controls are being
                -- recorded. This prevents an old binding from competing with the capture mailbox;
                -- post-capture neutral-edge rearm still prevents the new binding from toggling immediately.
                if self.controller_available and consumer_is_hotkey_owner(consumer) and not capture_active then
                    local kd, ke = evaluate(consumer, controller, consumer.keyboard, "keyboard")
                    local cd, ce = evaluate(consumer, controller, consumer.controller, "controller")
                    if kd ~= nil then
                        if kd and not consumer.keyboard_latched then
                            consumer.keyboard_latched = true
                            publish(consumer, "keyboard", consumer)
                        elseif not kd then
                            consumer.keyboard_latched = false
                        end
                    elseif ke ~= nil then
                        log("host keyboard query failed consumer=" .. consumer.consumer .. " error=" .. tostring(ke))
                    end
                    if cd ~= nil then
                        if cd and not consumer.controller_latched then
                            consumer.controller_latched = true
                            publish(consumer, "controller", consumer)
                        elseif not cd then
                            consumer.controller_latched = false
                        end
                    elseif ce ~= nil then
                        log("host controller query failed consumer=" .. consumer.consumer .. " error=" .. tostring(ce))
                    end
                end
            end
        end
        stage_end("poll.consumers", stage)

        -- v0.70.0 hold-to-reset (R / L3 held 5 s over a row while a hosted menu is open).
        tick_hold_reset(self.controller_available and controller or nil, capture_active_any)

        local current_menu_report = nil
        if type(menu_session_tick) == "function" then
            stage = stage_begin()
            local menu_ok, menu_result, menu_err = pcall(menu_session_tick)
            stage_end("poll.menu-session", stage)
            if not menu_ok then
                log("host menu session tick failed: " .. tostring(menu_result))
            elseif menu_result == false then
                log("host menu session tick unavailable: " .. tostring(menu_err))
            elseif type(menu_result) == "table" then
                current_menu_report = menu_result
            end
        end

        if type(native_listener_shadow_tick) == "function" then
            stage = stage_begin()
            local active_native_requests = 0
            for _, consumer in pairs(self.consumers) do
                if consumer.compatible and consumer.native_input then
                    local request = registry.ReadNativeInputRequest(
                        consumer.slot, consumer.consumer, consumer.revision, host_epoch)
                    if type(request) == "table" and request.active == true
                        and tostring(request.listenerAddress or "") == tostring(protocol.HOST_NATIVE_LISTENER_TOKEN or "host") then
                        local authorized, lease, lease_reason = host_native_request_authorized(consumer, request)
                        note_host_native_lease_authority(consumer, request, authorized == true, lease, lease_reason)
                        if authorized == true then active_native_requests = active_native_requests + 1 end
                    end
                end
            end
            local shadow_ok, shadow_err = pcall(native_listener_shadow_tick, active_native_requests)
            if not shadow_ok then
                log("host native listener shadow tick failed: " .. tostring(shadow_err))
            end
            stage_end("poll.native-listener", stage)
        end

        -- Pass 161: the shared-menu semantic callback is one bounded session hook, never a
        -- process-lifetime mirror. Tick only after the host listener has reconciled so the
        -- exact primitive listener address exists before any hook is armed.
        if type(native_semantic_tick) == "function" then
            stage = stage_begin()
            local semantic_ok, semantic_result = pcall(native_semantic_tick, current_menu_report)
            stage_end("poll.semantic", stage)
            if not semantic_ok then
                log("host native semantic session tick failed: " .. tostring(semantic_result))
            end
        end

        -- Pass 177: ordinary hosted input remains 50 ms and binding capture remains 20 ms.
        -- Controller Calibration/Test uses its own on-demand sampling request at 10 ms / 100 Hz
        -- so springback, center crossings and short analog peaks are observed more faithfully
        -- without changing the permanent idle/hotkey cadence.
        local delay_ms = controller_sampling_active_any and self.controller_available and 10
            or ((capture_active_any or controller_feed_active_any) and self.controller_available and 20
            or (self.controller_available and 50 or 250))
        if not schedule(delay_ms, self.Poll) then
            self.armed = false
            return false
        end
        return true
    end

    function self.Arm()
        if self.armed then return true end
        local ok, err = refresh_consumers(true)
        if not ok then return false, err end
        if type(register_navigation_bindings) == "function" then
            local nav_ok, nav_result = pcall(register_navigation_bindings, function(action, source)
                self.PublishNavigation(action, source)
            end)
            self.navigation_registered = nav_ok and nav_result ~= false
            if not self.navigation_registered then
                log("host fixed keyboard navigation registration unavailable: " .. tostring(nav_result))
            end
        end
        self.armed = true
        if not schedule(250, self.Poll) then
            self.armed = false
            return false, "schedule failed"
        end
        return true
    end

    function self.ConsumerCount()
        local count = 0
        for _ in pairs(self.consumers) do count = count + 1 end
        return count
    end

    function self.HostedAxes()
        local copy = {}
        for index, axis in ipairs(ANALOG_AXES) do copy[index] = axis end
        return copy
    end

    function self.HostedControllerCaptureKeys()
        local copy = {}
        for index, key in ipairs(CONTROLLER_CAPTURE_KEYS) do copy[index] = key end
        return copy
    end

    function self.HostedKeyboardCaptureKeys()
        local copy = {}
        for index, key in ipairs(KEYBOARD_CAPTURE_KEYS) do copy[index] = key end
        return copy
    end

    return self
end

return M
