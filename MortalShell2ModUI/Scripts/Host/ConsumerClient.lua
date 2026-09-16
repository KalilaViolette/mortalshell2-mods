-- MortalShell2ModUI Host.ConsumerClient
-- Consumer-side facade for one-window/many-mods registration. The facade transports only
-- primitive metadata/snapshots/events through ModRef shared variables; executable callbacks,
-- setting semantics, gameplay ownership and mod-specific state stay in the consumer Lua state.

local M = {}

local ROLE_DEFAULTS = {
    ["settings-provider"] = { settings_provider = true, visible_shell = true, presentation_provider = true, keyboard_navigation = true, native_input = true, controller_feed = true, hotkey_provider = false },
    ["controller-consumer"] = { settings_provider = false, visible_shell = false, presentation_provider = false, keyboard_navigation = false, native_input = false, controller_feed = true, hotkey_provider = false },
    ["service-consumer"] = { settings_provider = false, visible_shell = false, presentation_provider = false, keyboard_navigation = false, native_input = false, controller_feed = false, hotkey_provider = false },
}

local function normalize_options(options)
    local input = type(options) == "table" and options or {}
    local out = {}
    for key, value in pairs(input) do out[key] = value end
    local role = tostring(out.role or "")
    local defaults = ROLE_DEFAULTS[role]
    if type(defaults) == "table" then
        for key, value in pairs(defaults) do
            if out[key] == nil then out[key] = value end
        end
    end
    return out
end

function M.Bind(ModUI, ModRef, options)
    options = normalize_options(options)
    local minimum_api = math.max(0, math.floor(tonumber(options.minimum_api) or 0))
    local current_api = math.max(0, math.floor(tonumber(type(ModUI) == "table" and ModUI.API_VERSION or 0) or 0))
    if minimum_api > 0 and current_api < minimum_api then
        return nil, "MortalShell2ModUI API " .. tostring(minimum_api) .. "+ required; current=" .. tostring(current_api)
    end
    if type(ModUI) ~= "table" or type(ModUI.Host) ~= "table" then
        return nil, "Host.ConsumerClient requires ModUI.Host"
    end
    local Protocol = ModUI.Host.Protocol
    local Registry = ModUI.Host.Registry
    if type(Protocol) ~= "table" or type(Registry) ~= "table" or type(Registry.Bind) ~= "function" then
        return nil, "Host.ConsumerClient requires Host.Protocol/Registry"
    end
    if ModRef == nil or type(ModRef.GetSharedVariable) ~= "function" or type(ModRef.SetSharedVariable) ~= "function" then
        return nil, "Host.ConsumerClient requires UE4SS ModRef shared variables"
    end
    local consumer_id, id_err = Protocol.NormalizeConsumerId(options.consumer_id)
    if consumer_id == nil then return nil, id_err end

    -- Every shared-variable read/write is a cross-Lua-state call into UE4SS; counted
    -- as shared.get / shared.set on the consumer's profiler (ModUI.Perf).
    local registry, registry_err = Registry.Bind(
        Protocol,
        function(name)
            local perf = ModUI.Perf
            if perf ~= nil and perf.enabled then perf.Count("shared.get") end
            return ModRef:GetSharedVariable(name)
        end,
        function(name, value)
            local perf = ModUI.Perf
            if perf ~= nil and perf.enabled then perf.Count("shared.set") end
            return ModRef:SetSharedVariable(name, value)
        end)
    if registry == nil then return nil, registry_err end

    local self = {
        consumer_id = consumer_id,
        display_name = tostring(options.display_name or consumer_id),
        version = tostring(options.version or ""),
        descriptor_options = options,
        registry = registry,
        registration = nil,
        session_sequence = 0,
        lease_sequence = 0,
        presentation_sequence = 0,
        action_sequence = 0,
        action_dedupe = {},
        native_request_sequence = 0,
        controller_request_sequence = 0,
        controller_request_active = false,
        controller_request_host_epoch = "",
        controller_axis_sequences = {},
        controller_axis_cache = {},
        controller_profile_revision = -1,
        controller_profile = nil,
        capture_request_sequence = 0,
        capture_request_active = false,
        capture_request_kind = "",
        capture_request_host_epoch = "",
        capture_key_sequences = {},
        capture_key_press_sequences = {},
        capture_key_cache = {},
    }

    local ControllerProfile = type(ModUI.Controller) == "table" and ModUI.Controller.Profile or nil

    local function refresh_controller_profile(force)
        if type(ControllerProfile) ~= "table" or type(ControllerProfile.Current) ~= "function" then
            return nil, "shared controller profile unavailable"
        end
        local revision = nil
        if type(registry.ReadControllerProfileRevision) == "function" then
            revision = select(1, registry.ReadControllerProfileRevision())
        end
        revision = math.max(0, math.floor(tonumber(revision) or 0))
        if force == true or self.controller_profile == nil or revision ~= self.controller_profile_revision then
            local profile = nil
            if type(ControllerProfile.Reload) == "function" then
                profile = select(1, ControllerProfile.Reload())
            end
            if type(profile) ~= "table" then profile = ControllerProfile.Current() end
            self.controller_profile = type(profile) == "table" and profile or nil
            self.controller_profile_revision = revision
        end
        if type(self.controller_profile) ~= "table" then return nil, "shared controller profile unavailable" end
        local copy = {}
        for key, value in pairs(self.controller_profile) do copy[key] = value end
        return copy, self.controller_profile_revision
    end

    local function host_epoch()
        if type(registry.ReadHostEpoch) == "function" then return registry.ReadHostEpoch() end
        local host = registry.HostMetadata()
        local epoch = tostring(type(host) == "table" and host.epoch or "")
        if epoch == "" then return nil, "host epoch unavailable" end
        return epoch
    end

    local function ensure_controller_request()
        if self.controller_request_active ~= true then return true end
        local reg = self.registration
        if type(reg) ~= "table" then return false, "consumer not published" end
        local epoch, epoch_err = host_epoch()
        if epoch == nil then return false, epoch_err end
        if tostring(self.controller_request_host_epoch or "") == epoch then return true end
        if type(registry.SetControllerRequest) ~= "function" then return false, "shared controller feed unavailable" end
        self.controller_request_sequence = self.controller_request_sequence + 1
        local ok, request_err = registry.SetControllerRequest(
            reg.slot, reg.consumer, epoch, reg.revision, self.controller_request_sequence, true)
        if ok ~= true then return false, request_err end
        self.controller_request_host_epoch = epoch
        self.controller_axis_sequences = {}
        self.controller_axis_cache = {}
        refresh_controller_profile(true)
        return true
    end

    local function read_axis_raw(axis)
        local reg = self.registration
        if type(reg) ~= "table" then return nil, "consumer not published" end
        if self.controller_request_active ~= true then return nil, "controller input inactive" end
        local ensured, ensure_err = ensure_controller_request()
        if not ensured then return nil, ensure_err end
        axis = tostring(axis or "")
        if axis == "" then return nil, "axis missing" end
        local epoch, epoch_err = host_epoch()
        if epoch == nil then return nil, epoch_err end
        local last_sequence = math.max(0, math.floor(tonumber(self.controller_axis_sequences[axis]) or 0))
        local sample, sample_err = registry.ReadAxisSample(
            reg.slot, reg.consumer, reg.revision, epoch, axis, last_sequence)
        if type(sample) == "table" then
            self.controller_axis_sequences[axis] = math.max(last_sequence, math.floor(tonumber(sample.sequence) or 0))
            self.controller_axis_cache[axis] = sample
        elseif sample_err ~= "axis pending" and sample_err ~= nil then
            return nil, sample_err
        end
        local cached = self.controller_axis_cache[axis]
        if type(cached) ~= "table" then return nil, tostring(sample_err or "axis pending") end
        return tonumber(cached.value) or 0.0, tostring(cached.source or ""), true, tonumber(cached.frame) or 0, cached
    end

    local function descriptor()
        local d = self.descriptor_options
        return {
            consumer_id = self.consumer_id,
            display_name = self.display_name,
            version = self.version,
            settings_provider = d.settings_provider ~= false,
            hotkey_provider = d.hotkey_provider == true,
            visible_shell = d.visible_shell ~= false,
            presentation_provider = d.presentation_provider ~= false,
            menu_order = tonumber(d.menu_order) or 100,
            open_keyboard = tostring(d.open_keyboard or ""),
            open_controller = tostring(d.open_controller or ""),
            modifier_sides_equivalent = d.modifier_sides_equivalent == true,
            keyboard_navigation = d.keyboard_navigation ~= false,
            native_input = d.native_input ~= false,
            controller_feed = d.controller_feed ~= false,
            actions = tostring(d.actions or "open-settings"),
            pages = tostring(d.pages or ""),
        }
    end

    function self.Publish(overrides)
        if type(overrides) == "table" then
            for key, value in pairs(overrides) do self.descriptor_options[key] = value end
            if overrides.display_name ~= nil then self.display_name = tostring(overrides.display_name) end
            if overrides.version ~= nil then self.version = tostring(overrides.version) end
        end
        local registration, publish_err = registry.Publish(descriptor())
        if type(registration) ~= "table" then return nil, publish_err end
        self.registration = registration
        self.action_sequence = 0
        self.controller_axis_sequences = {}
        self.controller_axis_cache = {}
        self.controller_request_host_epoch = ""
        self.capture_request_active = false
        self.capture_request_kind = ""
        self.capture_request_host_epoch = ""
        self.capture_key_sequences = {}
        self.capture_key_press_sequences = {}
        self.capture_key_cache = {}
        self.action_dedupe = {}
        refresh_controller_profile(true)
        if self.controller_request_active == true and type(self.ControllerInput) == "function" then
            self.ControllerInput(true)
        end
        return registration
    end

    function self.Registration()
        return self.registration
    end

    function self.Acknowledgement()
        local reg = self.registration
        if type(reg) ~= "table" then return nil, "consumer not published" end
        return registry.ReadAcknowledgement(reg.slot, reg.consumer, reg.revision)
    end

    function self.Activate()
        return registry.SetMenuActiveConsumerRequest(self.consumer_id)
    end

    function self.ClearActivation()
        if type(registry.ClearMenuActiveConsumerRequest) == "function" then
            return registry.ClearMenuActiveConsumerRequest()
        end
        return false, "clear activation unavailable"
    end

    function self.Session(state, generation, reason)
        local reg = self.registration
        if type(reg) ~= "table" then return nil, "consumer not published" end
        self.session_sequence = self.session_sequence + 1
        return registry.SetMenuSession(reg.slot, reg.consumer, reg.revision,
            self.session_sequence, state, generation, reason)
    end

    function self.Lease(active, generation, reason)
        local reg = self.registration
        if type(reg) ~= "table" then return nil, "consumer not published" end
        self.lease_sequence = self.lease_sequence + 1
        return registry.SetMenuLease(reg.slot, reg.consumer, reg.revision,
            self.lease_sequence, active == true, generation, reason)
    end

    function self.Presentation(snapshot, generation)
        local reg = self.registration
        if type(reg) ~= "table" then return nil, "consumer not published" end
        self.presentation_sequence = self.presentation_sequence + 1
        return registry.SetMenuPresentation(reg.slot, reg.consumer, reg.revision,
            self.presentation_sequence, generation, snapshot)
    end

    function self.ReadActions()
        local reg = self.registration
        if type(reg) ~= "table" then return nil, "consumer not published" end
        local events, head = registry.ReadConsumerMenuActionEvents(
            reg.slot, reg.consumer, reg.revision, self.action_sequence)
        if type(events) ~= "table" then return nil, head end
        self.action_sequence = math.max(self.action_sequence, math.floor(tonumber(head) or 0))
        if #events == 0 then return events, self.action_sequence end

        -- Normalize duplicate semantic events at the shared facade so every new
        -- settings provider inherits the same single-step behavior as TTS. The
        -- native listener and fixed navigation owner can report the same physical
        -- press through two routes; exact duplicates in one drain are always one
        -- action, same-source callbacks inside 35 ms are one edge, and cross-source
        -- mirrors inside 120 ms are one edge. Normal held-repeat cadence remains.
        local filtered, batch_seen = {}, {}
        local now = type(os) == "table" and type(os.clock) == "function" and os.clock() or nil
        local function source_kind(source)
            source = tostring(source or ""):lower()
            if source:find("keyboard", 1, true) or source:find("keybind", 1, true) then return "keyboard" end
            if source:find("controller", 1, true) or source:find("gamepad", 1, true) then return "controller" end
            if source:find("native", 1, true) then return "native" end
            return source ~= "" and source or "unknown"
        end
        for _, event in ipairs(events) do
            local action = tostring(type(event) == "table" and event.action or "")
            local semantic = action
            if type(ModUI) == "table" and type(ModUI.Input) == "table"
                and type(ModUI.Input.Route) == "table"
                and type(ModUI.Input.Route.Semantic) == "function" then
                semantic = tostring(ModUI.Input.Route.Semantic(action) or action)
            end
            local generation = math.max(0, math.floor(tonumber(type(event) == "table" and event.generation) or 0))
            local batch_key = semantic .. "|" .. tostring(generation)
            local prior = self.action_dedupe[semantic]
            local kind = source_kind(type(event) == "table" and event.source or "")
            local duplicate = semantic == "" or batch_seen[batch_key] == true
            if not duplicate and type(prior) == "table" and now ~= nil and tonumber(prior.clock) ~= nil then
                local elapsed = now - tonumber(prior.clock)
                local window = tostring(prior.kind or "") == kind and 0.035 or 0.120
                duplicate = elapsed >= 0.0 and elapsed <= window
            end
            if not duplicate then
                batch_seen[batch_key] = true
                self.action_dedupe[semantic] = { kind = kind, clock = now }
                filtered[#filtered + 1] = event
            end
        end
        return filtered, self.action_sequence
    end

    function self.NativeInput(active, generation)
        local reg = self.registration
        if type(reg) ~= "table" then return nil, "consumer not published" end
        if type(registry.SetNativeInputRequest) ~= "function" then return nil, "native input request unavailable" end
        local host = registry.HostMetadata()
        local host_epoch = tostring(type(host) == "table" and host.epoch or "")
        if host_epoch == "" then return nil, "host epoch unavailable" end
        self.native_request_sequence = self.native_request_sequence + 1
        local token = tostring(type(Protocol) == "table" and Protocol.HOST_NATIVE_LISTENER_TOKEN or "host")
        local ok, request_err = registry.SetNativeInputRequest(
            reg.slot, reg.consumer, host_epoch, reg.revision, self.native_request_sequence,
            active == true, active == true and token or "", math.max(0, math.floor(tonumber(generation) or 0)))
        if ok ~= true then return nil, request_err end
        return { sequence = self.native_request_sequence, active = active == true, hostEpoch = host_epoch, token = token }
    end

    function self.ControllerInput(active)
        local reg = self.registration
        if type(reg) ~= "table" then return nil, "consumer not published" end
        if self.descriptor_options.controller_feed == false then return nil, "controller feed disabled by consumer descriptor" end
        if type(registry.SetControllerRequest) ~= "function" then return nil, "shared controller feed unavailable" end
        active = active == true
        -- Local intent is authoritative across host reloads. In particular, a failed OFF request
        -- must not be reasserted later merely because the old host epoch disappeared first.
        self.controller_request_active = active
        if not active then
            self.controller_request_host_epoch = ""
            self.controller_axis_sequences = {}
            self.controller_axis_cache = {}
        end
        local epoch, epoch_err = host_epoch()
        if epoch == nil then return nil, epoch_err end
        self.controller_request_sequence = self.controller_request_sequence + 1
        local ok, request_err = registry.SetControllerRequest(
            reg.slot, reg.consumer, epoch, reg.revision, self.controller_request_sequence, active)
        if ok ~= true then return nil, request_err end
        self.controller_request_host_epoch = active and epoch or ""
        if active then refresh_controller_profile(true) end
        return { sequence = self.controller_request_sequence, active = active, hostEpoch = epoch }
    end

    -- Shared TTS-style binding recorder transport. The provider owns only its
    -- pure capture state/UI; MortalShell2ModUI's standalone host owns every
    -- physical key query and publishes revision-bound primitive samples here.
    function self.BindingCapture(active, kind)
        local reg = self.registration
        if type(reg) ~= "table" then return nil, "consumer not published" end
        if type(registry.SetCaptureRequest) ~= "function" then
            return nil, "shared binding capture unavailable"
        end
        active = active == true
        kind = active and tostring(kind or "") or "off"
        -- v0.70.0: "controller-sampling" is the 100 Hz feed the shared controller
        -- calibration / test screens run on (Host.InputService already serves it).
        if active and kind ~= "keyboard" and kind ~= "controller" and kind ~= "controller-sampling" then
            return nil, "binding capture kind invalid"
        end

        -- Local intent is cleared even if the old host epoch has disappeared;
        -- an old-epoch request cannot be accepted by a replacement host.
        self.capture_request_active = active
        self.capture_request_kind = active and kind or ""
        self.capture_key_sequences = {}
        self.capture_key_press_sequences = {}
        self.capture_key_cache = {}

        local epoch, epoch_err = host_epoch()
        if epoch == nil then
            self.capture_request_host_epoch = ""
            return nil, epoch_err
        end
        self.capture_request_sequence = self.capture_request_sequence + 1
        local ok, request_err = registry.SetCaptureRequest(
            reg.slot, reg.consumer, epoch, reg.revision,
            self.capture_request_sequence, kind, active)
        if ok ~= true then
            self.capture_request_host_epoch = ""
            return nil, request_err
        end
        self.capture_request_host_epoch = active and epoch or ""
        return {
            sequence = self.capture_request_sequence,
            active = active,
            kind = kind,
            hostEpoch = epoch,
        }
    end

    local function ensure_capture_request()
        if self.capture_request_active ~= true then return false, "binding capture inactive" end
        local reg = self.registration
        if type(reg) ~= "table" then return false, "consumer not published" end
        local epoch, epoch_err = host_epoch()
        if epoch == nil then return false, epoch_err end
        if tostring(self.capture_request_host_epoch or "") == epoch then return true end
        self.capture_request_sequence = self.capture_request_sequence + 1
        local ok, request_err = registry.SetCaptureRequest(
            reg.slot, reg.consumer, epoch, reg.revision,
            self.capture_request_sequence, self.capture_request_kind, true)
        if ok ~= true then return false, request_err end
        self.capture_request_host_epoch = epoch
        self.capture_key_sequences = {}
        self.capture_key_press_sequences = {}
        self.capture_key_cache = {}
        return true
    end

    function self.ReadBindingKey(key)
        if type(registry.ReadKeySample) ~= "function" then
            return nil, "shared binding samples unavailable", false, 0
        end
        local ensured, ensure_err = ensure_capture_request()
        if not ensured then return nil, ensure_err, false, 0 end
        local reg = self.registration
        key = tostring(key or "")
        if key == "" then return nil, "binding key missing", false, 0 end
        local last_sequence = math.max(0,
            math.floor(tonumber(self.capture_key_sequences[key]) or 0))
        local last_press = math.max(0,
            math.floor(tonumber(self.capture_key_press_sequences[key]) or 0))
        local sample, sample_err = registry.ReadKeySample(
            reg.slot, reg.consumer, reg.revision,
            self.capture_request_host_epoch, self.capture_request_sequence,
            key, last_sequence)
        if type(sample) == "table" then
            local sequence = math.max(last_sequence,
                math.floor(tonumber(sample.sequence) or 0))
            local press_sequence = math.max(last_press,
                math.floor(tonumber(sample.pressSequence) or 0))
            self.capture_key_sequences[key] = sequence
            self.capture_key_press_sequences[key] = press_sequence
            self.capture_key_cache[key] = {
                down = sample.down == true,
                source = tostring(sample.source or key),
            }
            return sample.down == true, tostring(sample.source or key), true,
                math.max(0, press_sequence - last_press)
        end
        local cached = self.capture_key_cache[key]
        if type(cached) == "table" then
            return cached.down == true, tostring(cached.source or key), true, 0
        end
        return nil, tostring(sample_err or "binding sample pending"), true, 0
    end

    function self.ControllerProfile(force_reload)
        return refresh_controller_profile(force_reload == true)
    end

    function self.ControllerAxis(axis, options)
        options = type(options) == "table" and options or {}
        local raw, source, ready, frame, sample = read_axis_raw(axis)
        if raw == nil then return nil, source, false, frame end
        if options.raw == true then return raw, source, ready, frame, raw, sample end
        local profile, profile_revision = refresh_controller_profile(false)
        if type(profile) ~= "table" then return nil, profile_revision, false, frame end
        local value = raw
        if options.filtered == false and type(ControllerProfile.ScaleAxis) == "function" then
            value = ControllerProfile.ScaleAxis(axis, raw, profile)
            if options.semantic ~= false and tostring(axis) == "Gamepad_RightY" then value = -(tonumber(value) or 0.0) end
        elseif options.filtered ~= false then
            local normalize = options.semantic == false and ControllerProfile.NormalizeAxis or ControllerProfile.NormalizeAxisSemantic
            if type(normalize) == "function" then value = normalize(axis, raw, profile) end
        end
        return tonumber(value) or 0.0, source, ready, frame, raw, profile_revision
    end

    function self.ControllerTrigger(axis, was_active, options)
        options = type(options) == "table" and options or {}
        axis = tostring(axis or "")
        if axis ~= "Gamepad_LeftTriggerAxis" and axis ~= "Gamepad_RightTriggerAxis" then
            return nil, "trigger axis invalid", false
        end
        local value, source, ready, frame, raw, profile_revision = self.ControllerAxis(axis, { filtered = false, semantic = false })
        if value == nil then return nil, source, false, frame end
        local profile = select(1, refresh_controller_profile(false))
        if type(profile) ~= "table" or type(ControllerProfile.TriggerActive) ~= "function" then
            return nil, "shared trigger profile unavailable", false, frame
        end
        local active, scalar, threshold = ControllerProfile.TriggerActive(raw, was_active == true, profile)
        return active, scalar, true, frame, { source = source, threshold = threshold, profileRevision = profile_revision }
    end

    function self.ControllerStick(stick, options)
        options = type(options) == "table" and options or {}
        stick = tostring(stick or "left"):lower() == "right" and "right" or "left"
        local x_axis = stick == "right" and "Gamepad_RightX" or "Gamepad_LeftX"
        local y_axis = stick == "right" and "Gamepad_RightY" or "Gamepad_LeftY"
        local raw_x, x_source, x_ready, x_frame = read_axis_raw(x_axis)
        local raw_y, y_source, y_ready, y_frame = read_axis_raw(y_axis)
        if raw_x == nil or raw_y == nil then return nil, nil, tostring(x_source or y_source or "axis pending"), false end
        if tonumber(x_frame) ~= tonumber(y_frame) then return nil, nil, "frame mismatch", false end
        if options.raw == true then
            return raw_x, raw_y, { xSource = x_source, ySource = y_source, frame = x_frame, rawX = raw_x, rawY = raw_y }, true
        end
        local profile, profile_revision = refresh_controller_profile(false)
        if type(profile) ~= "table" then return nil, nil, tostring(profile_revision), false end
        local nx, ny
        if options.filtered == false then
            nx, ny = ControllerProfile.NormalizeStick(stick, raw_x, raw_y, profile)
            if options.semantic ~= false and stick == "right" then ny = -(tonumber(ny) or 0.0) end
        elseif options.semantic == false and type(ControllerProfile.NormalizeStickFiltered) == "function" then
            nx, ny = ControllerProfile.NormalizeStickFiltered(stick, raw_x, raw_y, profile)
        elseif type(ControllerProfile.NormalizeStickSemantic) == "function" then
            nx, ny = ControllerProfile.NormalizeStickSemantic(stick, raw_x, raw_y, profile)
        else
            nx, ny = ControllerProfile.NormalizeStick(stick, raw_x, raw_y, profile)
            if stick == "right" then ny = -(tonumber(ny) or 0.0) end
        end
        return nx, ny, { xSource = x_source, ySource = y_source, frame = x_frame, rawX = raw_x, rawY = raw_y, profileRevision = profile_revision }, true
    end

    function self.SaveControllerProfile(value, reason)
        if type(ControllerProfile) ~= "table" or type(ControllerProfile.Save) ~= "function" then
            return false, "shared controller profile unavailable"
        end
        local ok, profile_or_err = ControllerProfile.Save(value)
        if ok ~= true or type(profile_or_err) ~= "table" then return false, profile_or_err end
        local state, state_err = self.PublishControllerProfile(profile_or_err, reason or "consumer-save")
        if type(state) ~= "table" then return false, state_err end
        return true, profile_or_err, state
    end

    function self.ResetControllerProfile(reason)
        if type(ControllerProfile) ~= "table" or type(ControllerProfile.Defaults) ~= "function" then
            return false, "shared controller profile unavailable"
        end
        return self.SaveControllerProfile(ControllerProfile.Defaults(), reason or "consumer-reset")
    end

    function self.PublishControllerProfile(profile, reason)
        if type(registry.PublishControllerProfileState) ~= "function" then return nil, "controller profile sync unavailable" end
        profile = type(profile) == "table" and profile or select(1, refresh_controller_profile(true))
        local calibrated = type(profile) == "table" and profile.calibrated == true
        local state, state_err = registry.PublishControllerProfileState(self.consumer_id, calibrated, reason)
        if type(state) == "table" then
            self.controller_profile_revision = math.max(0, math.floor(tonumber(state.revision) or 0))
            self.controller_profile = type(profile) == "table" and profile or self.controller_profile
        end
        return state, state_err
    end

    -- v0.70.0: the shared controller settings / calibration / test screen, bound to
    -- this consumer's host feeds, so any mod adds one "Controller settings" row and
    -- gets the whole screen: `local view = client.ControllerSettings(hooks)`; then
    -- view.Open(), forward Move / Change / Activate / Back while view.Active(), call
    -- view.Poll() each tick, and publish Controller.Settings.Presentation(view).
    -- `hooks` are the consumer's UI callbacks (set_status, redraw, get/set_selected,
    -- apply_window_profile, diag, log); everything that touches the host is bound here.
    function self.ControllerSettings(hooks)
        hooks = type(hooks) == "table" and hooks or {}
        local factory = type(ModUI.Controller) == "table" and ModUI.Controller.Settings or nil
        if type(factory) ~= "table" or type(factory.New) ~= "function" then
            return nil, "Controller.Settings unavailable"
        end
        if type(ControllerProfile) ~= "table" then return nil, "Controller.Profile unavailable" end
        return factory.New({
            profile = ControllerProfile,
            read_axis = function(key)
                local raw, source, ready, frame = self.ControllerAxis(tostring(key or ""), { raw = true })
                if raw == nil then return nil, tostring(source or "axis-unavailable"), false, 0 end
                return raw, tostring(source or key), ready ~= false, tonumber(frame) or 0
            end,
            read_key = function(key)
                local down, source, ready, presses = self.ReadBindingKey(tostring(key or ""))
                if down == nil then return nil, tostring(source or "key-unavailable"), false, 0 end
                return down == true, tostring(source or key), ready ~= false, tonumber(presses) or 0
            end,
            set_capture_request = function(kind, active)
                local result, err = self.BindingCapture(active == true, kind)
                if result == nil then return false, tostring(err or "capture-unavailable") end
                return true, tostring(kind)
            end,
            profile_changed = function(profile, reason)
                local state, err = self.PublishControllerProfile(profile, reason)
                if state == nil then return false, tostring(err or "controller-profile-sync-unavailable") end
                return true, state
            end,
            get_selected = hooks.get_selected, set_selected = hooks.set_selected,
            set_status = hooks.set_status, apply_window_profile = hooks.apply_window_profile,
            redraw = hooks.redraw, diag = hooks.diag, log = hooks.log,
        })
    end

    function self.Providers()
        local entries = registry.Scan()
        local providers = {}
        for _, entry in ipairs(entries or {}) do
            if type(entry) == "table" and type(entry.fields) == "table"
                and tostring(entry.fields.settings or "0") == "1" then
                providers[#providers + 1] = {
                    consumer = tostring(entry.consumer or ""),
                    slot = math.floor(tonumber(entry.slot) or -1),
                    revision = math.max(0, math.floor(tonumber(entry.revision) or 0)),
                    display = tostring(entry.fields.display or entry.consumer or ""),
                    pages = tostring(entry.fields.pages or ""),
                    actions = tostring(entry.fields.actions or ""),
                    visibleShell = tostring(entry.fields.visibleShell or "0") == "1",
                    presentation = tostring(entry.fields.presentation or "0") == "1",
                    hotkeys = tostring(entry.fields.hotkeys or "0") == "1",
                    openKeyboard = tostring(entry.fields.openKeyboard or ""),
                    openController = tostring(entry.fields.openController or ""),
                    menuOrder = math.floor(tonumber(entry.fields.menuOrder) or 100),
                }
            end
        end
        table.sort(providers, function(a, b)
            if a.menuOrder ~= b.menuOrder then return a.menuOrder < b.menuOrder end
            if a.slot ~= b.slot then return a.slot < b.slot end
            return a.consumer < b.consumer
        end)
        return providers
    end


    function self.ActiveProvider()
        local providers = self.Providers()
        local host = registry.HostMetadata()
        local active = tostring(type(host) == "table" and host.menuActiveConsumer or "")
        for index, provider in ipairs(providers) do
            if provider.consumer == active then
                return provider, index, #providers
            end
        end
        return nil, 0, #providers
    end

    function self.ActivateByIndex(index)
        local providers = self.Providers()
        if #providers == 0 then return false, "no settings providers" end
        index = math.floor(tonumber(index) or 1)
        if index < 1 then index = 1 end
        if index > #providers then index = #providers end
        local provider = providers[index]
        return registry.SetMenuActiveConsumerRequest(provider.consumer), provider
    end

    function self.ProviderPosition()
        local provider, index, count = self.ActiveProvider()
        return index, count, provider
    end

    function self.ActivateNext(direction)
        local providers = self.Providers()
        if #providers == 0 then return false, "no settings providers" end
        direction = tonumber(direction) or 1
        direction = direction < 0 and -1 or 1
        local host = registry.HostMetadata()
        local active = tostring(type(host) == "table" and host.menuActiveConsumer or "")
        local index = 1
        for i, provider in ipairs(providers) do
            if provider.consumer == active then index = i; break end
        end
        index = ((index - 1 + direction) % #providers) + 1
        return registry.SetMenuActiveConsumerRequest(providers[index].consumer), providers[index]
    end

    function self.Shutdown(reason)
        local reg = self.registration
        if type(reg) ~= "table" then return true, "already-retired" end
        reason = tostring(reason or "consumer-shutdown")

        -- Best-effort release of active primitive requests/session state before removing the
        -- descriptor from host discovery. Failures here must not strand the discoverable slot.
        if self.controller_request_active == true then pcall(self.ControllerInput, false) end
        if self.capture_request_active == true then pcall(self.BindingCapture, false) end
        pcall(self.NativeInput, false, 0)
        pcall(self.Lease, false, 0, reason)
        pcall(self.Session, "closed", 0, reason)
        local host = registry.HostMetadata()
        if type(host) == "table" and tostring(host.menuActiveConsumer or "") == tostring(reg.consumer or "") then
            pcall(self.ClearActivation)
        end

        local retired, retire_err = nil, "consumer retirement unavailable"
        if type(registry.RetireConsumer) == "function" then
            retired, retire_err = registry.RetireConsumer(reg.slot, reg.consumer, reg.revision)
        end
        self.registration = nil
        self.controller_request_active = false
        self.controller_request_host_epoch = ""
        self.controller_axis_sequences = {}
        self.controller_axis_cache = {}
        self.capture_request_active = false
        self.capture_request_kind = ""
        self.capture_request_host_epoch = ""
        self.capture_key_sequences = {}
        self.capture_key_press_sequences = {}
        self.capture_key_cache = {}
        if retired == nil then return nil, retire_err end
        return retired
    end

    function self.HostMetadata()
        return registry.HostMetadata()
    end

    function self.ReadVisibilitySnapshot()
        if type(registry.ReadVisibilitySnapshot) == "function" then
            return registry.ReadVisibilitySnapshot()
        end
        return registry.HostMetadata()
    end

    refresh_controller_profile(true)
    return self
end

function M.BindSettingsProvider(ModUI, ModRef, options)
    options = normalize_options(options)
    options.role = "settings-provider"
    options = normalize_options(options)
    return M.Bind(ModUI, ModRef, options)
end

function M.BindControllerConsumer(ModUI, ModRef, options)
    options = normalize_options(options)
    options.role = "controller-consumer"
    options = normalize_options(options)
    return M.Bind(ModUI, ModRef, options)
end

function M.BindServiceConsumer(ModUI, ModRef, options)
    options = normalize_options(options)
    options.role = "service-consumer"
    options = normalize_options(options)
    return M.Bind(ModUI, ModRef, options)
end

return M
