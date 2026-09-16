-- Owns the MortalShell2ModUI consumer boundary: registration, tabbed settings,
-- shared input/modal isolation, mouse hit testing, and semantic navigation.

local Factory = {}

function Factory.New(ctx)
    local state = assert(ctx.State, "UI.ModUI requires State")
    local Config = assert(ctx.Config, "UI.ModUI requires Config")
    local ConfigRuntime = assert(ctx.ConfigRuntime, "UI.ModUI requires Config.Runtime")
    local Renderer = assert(ctx.Renderer, "UI.ModUI requires Map.NativeWidget")
    local TABS = assert(ctx.SettingsTabs, "UI.ModUI requires tabbed Config.Schema")
    local log = assert(ctx.Log, "UI.ModUI requires Log")
    local Perf = type(ctx.Perf) == "table" and ctx.Perf
        or { Begin = function() return nil end, End = function() end, Count = function() end }
    local debug_log = assert(ctx.DebugLog, "UI.ModUI requires DebugLog")
    local mods_dir = assert(ctx.ModsDir, "UI.ModUI requires ModsDir")
    local mod_name = assert(ctx.ModName, "UI.ModUI requires ModName")
    local version = assert(ctx.Version, "UI.ModUI requires Version")
    local mod_ref = assert(ctx.ModRef, "UI.ModUI requires ModRef")
    local Object = assert(ctx.Object, "UI.ModUI requires Core.Object")

    local runtime = {}
    local publish_settings
    local close_guard
    local finalize_close
    local modal_config = { pause_game_while_menu_open = Config.PauseGameWhileSettingsOpen == true }
    local modal_isolation = nil

    local function capture_module()
        return type(state.modui) == "table" and type(state.modui.Input) == "table"
            and state.modui.Input.Capture or nil
    end

    local function binding_module()
        return type(state.modui) == "table" and type(state.modui.Input) == "table"
            and state.modui.Input.Binding or nil
    end

    local function bind_capture_active()
        return type(state.bind_capture) == "table" and state.bind_capture.active == true
    end

    local function descriptor_overrides(active)
        local pages = {}
        for _, tab in ipairs(TABS) do pages[#pages + 1] = tostring(tab.key or tab.label or "") end
        return {
            hotkey_provider = active == true,
            open_keyboard = tostring(Config.MenuKeybind or "off"),
            open_controller = tostring(Config.ControllerMenuBind or "off"),
            modifier_sides_equivalent = Config.ModifierSidesEquivalent == true,
            pages = table.concat(pages, ","),
        }
    end

    local function load_table_module(path)
        local chunk, load_error = loadfile(path)
        if chunk == nil then return nil, load_error end
        local ok, result = pcall(chunk)
        if not ok or type(result) ~= "table" then return nil, tostring(result) end
        return result
    end

    local function clamp(value, minimum, maximum)
        value = tonumber(value) or minimum
        if value < minimum then return minimum end
        if value > maximum then return maximum end
        return value
    end

    local function struct_field(value, field)
        value = Object.Unwrap(value)
        if value == nil then return nil end
        local ok, result = pcall(function() return Object.Unwrap(value[field]) end)
        return ok and result or nil
    end

    local function diagnostic(event, fields)
        if not Config.DebugLog then return end
        local parts = { tostring(event) }
        if type(fields) == "table" then
            local keys = {}
            for key in pairs(fields) do keys[#keys + 1] = tostring(key) end
            table.sort(keys)
            for _, key in ipairs(keys) do parts[#parts + 1] = key .. "=" .. tostring(fields[key]) end
        end
        debug_log(table.concat(parts, " "))
    end

    -- v0.16.8: a tab may be gated like a row (`hidden = function(Config)`); the CAPTURE
    -- tab sits behind the Advanced settings switch. Everything the shell shows -- the
    -- strip, the page counter, tab switching, mouse hits -- runs over the visible list,
    -- so a hidden tab simply is not there. The bind-time `pages` descriptor still names
    -- every tab: it is informational metadata on the host side, never a layout.
    local function visible_tabs()
        local out = {}
        for _, tab in ipairs(TABS) do
            local hidden = tab.hidden == true
            if type(tab.hidden) == "function" then
                local ok, result = pcall(tab.hidden, Config)
                hidden = ok and result == true
            end
            if not hidden then out[#out + 1] = tab end
        end
        if #out == 0 then out[1] = TABS[1] end
        return out
    end

    local function current_tab()
        local tabs = visible_tabs()
        state.settings_tab = clamp(math.floor(tonumber(state.settings_tab) or 1), 1, #tabs)
        return tabs[state.settings_tab]
    end

    -- Per-tab selection memory is keyed by the tab's key, not its position, so hiding a
    -- tab never hands one tab's remembered row to another.
    local function selection_key()
        return tostring(current_tab().key or state.settings_tab)
    end

    local function current_rows()
        local tab = current_tab()
        if type(tab.settings) ~= "table" then return {} end
        local rows = {}
        for _, setting in ipairs(tab.settings) do
            local hidden = setting.hidden == true
            if type(setting.hidden) == "function" then
                local ok, result = pcall(setting.hidden, Config)
                hidden = ok and result == true
            end
            if not hidden then rows[#rows + 1] = setting end
        end
        return rows
    end

    local function setting_label(setting)
        if type(setting) ~= "table" then return "" end
        if type(setting.label) == "function" then
            local ok, result = pcall(setting.label, Config)
            if ok and result ~= nil then return tostring(result) end
        end
        return tostring(setting.label or setting.key or "")
    end

    -- v0.18.0 section headers (Config/Schema `header(...)`): rows the selection walks
    -- over, never onto. They are still rows -- the host lays them out and numbers
    -- pointer hits by them -- so they stay in current_rows() and are skipped here.
    local function is_header(setting)
        return type(setting) == "table" and setting.kind == "header"
    end

    -- The nearest selectable row at or after `index` in `direction` (1 or -1),
    -- wrapping; `index` itself when there is nothing else to land on.
    local function selectable_from(rows, index, direction)
        local count = #rows
        if count == 0 then return 1 end
        direction = direction < 0 and -1 or 1
        local candidate = clamp(math.floor(index), 1, count)
        for _ = 1, count do
            if not is_header(rows[candidate]) then return candidate end
            candidate = ((candidate - 1 + direction) % count) + 1
        end
        return clamp(math.floor(index), 1, count)
    end

    local function normalize_selection()
        local rows = current_rows()
        local maximum = math.max(1, #rows)
        local selected = tonumber(state.settings_selected_by_tab[selection_key()])
            or tonumber(state.settings_selection) or 1
        selected = clamp(math.floor(selected), 1, maximum)
        selected = selectable_from(rows, selected, 1)
        state.settings_selection = selected
        state.settings_selected_by_tab[selection_key()] = selected
        return selected
    end

    local function selected_setting()
        local setting = current_rows()[normalize_selection()]
        if is_header(setting) then return nil end
        return setting
    end

    -- The key of the row the cursor is on, for modules that preview a look while its
    -- row is selected (Runtime/CombatState.lua). nil when the window is closed.
    function runtime.SelectedSettingKey()
        if not state.settings_open then return nil end
        local view = state.controller_view
        if type(view) == "table" and type(view.Active) == "function" and view.Active() == true then
            return nil
        end
        local setting = selected_setting()
        if type(setting) ~= "table" then return nil end
        if type(setting.resolve_key) == "function" then
            local ok, resolved = pcall(setting.resolve_key, Config)
            if ok and resolved ~= nil then return tostring(resolved) end
        end
        return setting.key ~= nil and tostring(setting.key) or nil
    end

    local function resolve_native_ui_handler(world_context)
        if type(state.modui) ~= "table" or type(state.modui.Runtime) ~= "table"
            or type(state.modui.Runtime.Resolve) ~= "table"
            or type(state.modui.Runtime.Resolve.UIHandlerWithFallback) ~= "function" then
            return nil
        end
        local ok, handler = pcall(state.modui.Runtime.Resolve.UIHandlerWithFallback, world_context, {
            LoadAsset = LoadAsset,
            StaticFindObject = StaticFindObject,
            FindFirstOf = FindFirstOf,
            BPFLAsset = "/Game/Sparta/UI/Core/BPFL_UI",
            BPFLCdo = "/Game/Sparta/UI/Core/BPFL_UI.Default__BPFL_UI_C",
        })
        handler = Object.Unwrap(ok and handler or nil)
        return Object.Valid(handler) and handler or nil
    end

    function runtime.Bind()
        local modui, modui_error = load_table_module(mods_dir .. "\\MortalShell2ModUI\\Scripts\\ModUI.lua")
        if modui == nil then
            log("MortalShell2ModUI unavailable; minimap core remains enabled, shared settings are disabled: " .. tostring(modui_error))
            return false
        end
        state.modui = modui
        -- The ModUI library runs in this Lua state; its consumer-side work (shared-variable
        -- reads) is charged to the minimap's profiler.
        if type(ctx.Perf) == "table" then modui.Perf = ctx.Perf end
        local client_factory, client_error = load_table_module(
            mods_dir .. "\\MortalShell2ModUI\\Scripts\\Host\\ConsumerClient.lua")
        if client_factory == nil or type(client_factory.BindSettingsProvider) ~= "function" then
            log("MortalShell2ModUI consumer API unavailable: " .. tostring(client_error))
            return false
        end
        local ok, client, bind_error = pcall(client_factory.BindSettingsProvider, modui, mod_ref, {
            minimum_api = 2,
            consumer_id = mod_name,
            display_name = "MortalShell2Minimap",
            version = version,
            menu_order = 200,
            hotkey_provider = false,
            open_keyboard = tostring(Config.MenuKeybind or "off"),
            open_controller = tostring(Config.ControllerMenuBind or "off"),
            modifier_sides_equivalent = Config.ModifierSidesEquivalent == true,
            keyboard_navigation = true,
            native_input = true,
            controller_feed = true,
            actions = "open-settings",
            pages = table.concat((function()
                local out = {}
                for _, tab in ipairs(TABS) do out[#out + 1] = tostring(tab.key or tab.label or "") end
                return out
            end)(), ","),
        })
        if not ok or type(client) ~= "table" then
            log("MortalShell2ModUI bind failed: " .. tostring(ok and bind_error or client))
            return false
        end
        local published, publish_error = client.Publish()
        if type(published) ~= "table" then
            log("MortalShell2ModUI registration failed: " .. tostring(publish_error))
            return false
        end
        if type(modui.Runtime) ~= "table" or type(modui.Runtime.ModalIsolation) ~= "table"
            or type(modui.Runtime.ModalIsolation.New) ~= "function" then
            log("MortalShell2ModUI modal isolation API unavailable; settings stay disabled for input safety")
            return false
        end
        local isolation_ok, isolation = pcall(modui.Runtime.ModalIsolation.New, {
            ui = state,
            config = modal_config,
            ModUI = modui,
            unwrap = Object.Unwrap,
            valid = Object.Valid,
            same_object = Object.Same,
            struct_field = struct_field,
            log = log,
            diag = diagnostic,
        })
        if not isolation_ok or type(isolation) ~= "table"
            or type(isolation.AcquireNativeModalIsolation) ~= "function"
            or type(isolation.ReleaseNativeModalIsolation) ~= "function" then
            log("MortalShell2ModUI modal isolation bind failed; settings stay disabled: " .. tostring(isolation))
            return false
        end
        modal_isolation = isolation
        local guard_factory = type(modui.Settings) == "table" and modui.Settings.CloseGuard or nil
        if type(guard_factory) ~= "table" or type(guard_factory.New) ~= "function" then
            log("MortalShell2ModUI close guard API unavailable; settings stay disabled for input safety")
            return false
        end
        close_guard = guard_factory.New({
            schedule = function(delay_ms, callback)
                return type(ctx.Lifecycle) == "table" and ctx.Lifecycle.Schedule(delay_ms, callback, "ui.close-guard") or false
            end,
            current_generation = function() return state.settings_generation end,
            finalize = function(reason, generation) finalize_close(reason, generation) end,
        })
        state.modui_client = client
        state.modui_available = true
        log("MortalShell2ModUI API " .. tostring(modui.API_VERSION or "?")
            .. " registered; Minimap owns independent keyboard/controller settings hotkeys")
        return true
    end

    function runtime.PublishHotkey(active, reason, force)
        if not state.modui_available or type(state.modui_client) ~= "table" then return false end
        active = active == true
        if state.modui_hotkey_enabled == active and force ~= true then return true end
        local ok, registration, publish_error = pcall(
            state.modui_client.Publish, descriptor_overrides(active))
        if ok and type(registration) == "table" then
            state.modui_hotkey_enabled = active
            if state.settings_open then
                local generation = state.settings_generation
                pcall(state.modui_client.Activate)
                pcall(state.modui_client.Lease, true, generation, "binding-revision")
                pcall(state.modui_client.Session, "ready", generation, "binding-revision")
                local native_ok, native_request = pcall(state.modui_client.NativeInput, true, generation)
                if native_ok and type(native_request) == "table" then
                    state.modui_native_request_sequence = math.max(0,
                        math.floor(tonumber(native_request.sequence) or 0))
                    state.modui_native_event_sequence = 0
                    state.modui_native_host_epoch = tostring(native_request.hostEpoch or "")
                end
                pcall(state.modui_client.ControllerInput, true)
                if type(publish_settings) == "function" then publish_settings() end
            end
            debug_log("ModUI hotkey " .. (active and "enabled" or "quarantined") .. " reason=" .. tostring(reason))
            return true
        end
        log("ModUI hotkey update failed reason=" .. tostring(reason) .. " error=" .. tostring(ok and publish_error or registration))
        return false
    end

    -- v0.17.0: a row's value list may be a function of Config (the LOCAL icon and
    -- color rows depend on the selected category and on each other).
    -- v0.18.2 / UIPlayground 0.1.1 (her playground run): a row's own `read` may
    -- legitimately return false (a per-category or per-knob switch that is off), and
    -- the `read(Config) or Config[key]` idiom threw that false away, so an Off value
    -- read as nil, the arrows could not find it in the row's values and a row whose
    -- values list On first (the marquee, the child backdrops, the circle effect)
    -- could never come back on. Only a nil read falls through to the plain key.
    local function read_value(setting)
        if type(setting.read) == "function" then
            local value = setting.read(Config)
            if value ~= nil then return value end
        end
        return Config[setting.key]
    end

    local function setting_values(setting)
        if type(setting) ~= "table" then return nil end
        if type(setting.values) == "function" then
            local ok, values = pcall(setting.values, Config)
            return ok and type(values) == "table" and values or {}
        end
        return setting.values
    end

    local function nearest_value_index(values, current)
        values = type(values) == "table" and values or {}
        if #values == 0 then return 1 end
        local best_index, best_distance = 1, math.huge
        for index, value in ipairs(values) do
            local distance
            if type(value) == "boolean" then
                distance = value == current and 0 or 1
            elseif tostring(value) == tostring(current) then
                distance = 0
            elseif tonumber(value) ~= nil and tonumber(current) ~= nil then
                distance = math.abs((tonumber(value) or 0) - (tonumber(current) or 0))
            else
                distance = 1
            end
            if distance < best_distance then best_index, best_distance = index, distance end
        end
        return best_index
    end

    local function shared_binding_label(value)
        local Binding = binding_module()
        if type(Binding) == "table" and type(Binding.Label) == "function" then
            return Binding.Label(value, "Unbound", Config.ModifierSidesEquivalent == true)
        end
        value = tostring(value or "")
        if value == "" or value:lower() == "off" then return "Unbound" end
        return value
    end

    local function capture_display(capture)
        local Capture, Binding = capture_module(), binding_module()
        if type(Capture) == "table" and type(Capture.InputsLabel) == "function" then
            local tokens = #(capture.press_order or {}) > 0
                and capture.press_order or capture.order
            return Capture.InputsLabel(tokens, Binding,
                Config.ModifierSidesEquivalent == true)
        end
        return table.concat(capture.press_order or capture.order or {}, " + ")
    end

    local function release_capture_request(reason)
        if not bind_capture_active() then return false end
        local capture = state.bind_capture
        if capture.host_requested == true and type(state.modui_client) == "table"
            and type(state.modui_client.BindingCapture) == "function" then
            pcall(state.modui_client.BindingCapture, false, capture.kind)
        end
        capture.host_requested = false
        diagnostic("input.bindCapture", {
            status = "released", kind = capture.kind, reason = tostring(reason or "capture-end"),
        })
        return true
    end

    local function cancel_bind_capture(reason)
        if not bind_capture_active() then return false end
        local kind = tostring(state.bind_capture.kind or "binding")
        release_capture_request(reason or "cancel")
        state.bind_capture = { active = false }
        state.bind_capture_status = "Recording cancelled; previous "
            .. (kind == "keyboard" and "keyboard" or "controller") .. " binding kept."
        if type(publish_settings) == "function" then publish_settings() end
        return true
    end

    local function provider_binding_conflict(kind, serialized)
        if type(state.modui_client) ~= "table"
            or type(state.modui_client.Providers) ~= "function" then return nil end
        local ok, providers = pcall(state.modui_client.Providers)
        if not ok or type(providers) ~= "table" then return nil end
        local field = kind == "keyboard" and "openKeyboard" or "openController"
        for _, provider in ipairs(providers) do
            if tostring(provider.consumer or "") ~= mod_name
                and tostring(provider[field] or "") == tostring(serialized or "") then
                return tostring(provider.display or provider.consumer or "another mod")
            end
        end
        return nil
    end

    local function commit_bind_capture()
        if not bind_capture_active() then return false end
        local Capture = capture_module()
        if type(Capture) ~= "table" or type(Capture.ResolveCommit) ~= "function" then
            return cancel_bind_capture("capture-helper-unavailable")
        end
        local resolved = Capture.ResolveCommit(state.bind_capture)
        if type(resolved) ~= "table" then return false end
        if resolved.cancel == true then return cancel_bind_capture(resolved.cancel_reason) end

        local kind = tostring(resolved.kind or state.bind_capture.kind or "")
        local serialized = tostring(resolved.serialized or "")
        local conflict = provider_binding_conflict(kind, serialized)
        release_capture_request("commit")
        state.bind_capture = { active = false }
        if kind == "keyboard" then
            Config.MenuKeybind = serialized
        else
            Config.ControllerMenuBind = serialized
        end
        ConfigRuntime.Normalize()
        ConfigRuntime.Save()
        runtime.PublishHotkey(state.modui_hotkey_enabled, "recorded-binding", true)
        state.bind_capture_status = (kind == "keyboard" and "Keyboard hotkey set to "
            or "Controller hotkey set to ") .. shared_binding_label(serialized) .. "."
        if conflict ~= nil then
            state.bind_capture_status = state.bind_capture_status
                .. " Warning: this is also used by " .. conflict .. "."
        end
        diagnostic("input.bindCapture", {
            status = "committed", kind = kind, mode = resolved.mode,
            steps = resolved.steps, conflict = conflict or "none",
        })
        if type(publish_settings) == "function" then publish_settings() end
        return true
    end

    local function start_bind_capture(kind)
        if kind ~= "keyboard" and kind ~= "controller" then return false end
        if not state.settings_open or type(state.modui_client) ~= "table"
            or type(state.modui_client.BindingCapture) ~= "function" then
            state.bind_capture_status = "Shared binding recorder is unavailable; previous binding kept."
            if type(publish_settings) == "function" then publish_settings() end
            return false
        end
        local Capture = capture_module()
        if type(Capture) ~= "table" or type(Capture.NewState) ~= "function" then
            state.bind_capture_status = "Shared binding recorder is unavailable; previous binding kept."
            if type(publish_settings) == "function" then publish_settings() end
            return false
        end
        local capture = Capture.NewState(kind, os.clock(), "os.clock")
        if type(capture) ~= "table" then return false end
        if kind == "controller" then
            capture.stick_capture.left = type(Capture.NewStickGate) == "function"
                and Capture.NewStickGate(3) or nil
            capture.stick_capture.right = type(Capture.NewStickGate) == "function"
                and Capture.NewStickGate(3) or nil
            local profile_ok, profile = pcall(state.modui_client.ControllerProfile, true)
            capture.controller_profile = profile_ok and type(profile) == "table" and profile or {}
            capture.trigger_active = {}
        end
        state.bind_capture = capture
        local ok, request = pcall(state.modui_client.BindingCapture, true, kind)
        if not ok or type(request) ~= "table" then
            state.bind_capture = { active = false }
            state.bind_capture_status = "Binding recorder could not start; previous binding kept."
            diagnostic("input.bindCapture", {
                status = "start-failed", kind = kind, error = tostring(request),
            })
            if type(publish_settings) == "function" then publish_settings() end
            return false
        end
        capture.host_requested = true
        state.bind_capture_status = kind == "keyboard"
            and "Release all keyboard keys, then press a chord or repeated-key sequence. Release all keys to save; Escape alone cancels."
            or "Release all controller inputs, then press a chord or repeated-button sequence. Release everything to save; Circle/B alone cancels."
        diagnostic("input.bindCapture", { status = "started", kind = kind })
        if type(publish_settings) == "function" then publish_settings() end
        return true
    end

    local function controller_capture_tokens(capture)
        local Capture = capture_module()
        if type(Capture) ~= "table" or type(Capture.ResolveStickDirection) ~= "function" then
            return {}
        end
        local out = {}
        local profile = type(capture.controller_profile) == "table"
            and capture.controller_profile or {}
        for _, stick in ipairs({ "left", "right" }) do
            local ok, x, y, _, ready = pcall(
                state.modui_client.ControllerStick, stick, { semantic = false })
            if ok and ready == true and tonumber(x) ~= nil and tonumber(y) ~= nil then
                local gate = capture.stick_capture[stick]
                local token = type(gate) == "table" and select(1,
                    Capture.ResolveStickDirection(gate, stick, x, y, {
                        activation = tonumber(profile.stick_activation) or 0.68,
                        release = tonumber(profile.stick_release) or 0.30,
                        neutral = tonumber(profile.stick_neutral) or 0.22,
                        dominance_margin = tonumber(profile.dominance_margin) or 0.12,
                        required_neutral_ticks = tonumber(profile.neutral_ticks) or 3,
                    })) or nil
                if token ~= nil then out[#out + 1] = token end
            end
        end
        for _, entry in ipairs({
            { axis = "Gamepad_LeftTriggerAxis", token = "axis:Gamepad_LeftTriggerAxis:pos" },
            { axis = "Gamepad_RightTriggerAxis", token = "axis:Gamepad_RightTriggerAxis:pos" },
        }) do
            local prior = capture.trigger_active[entry.axis] == true
            local ok, active = pcall(state.modui_client.ControllerTrigger,
                entry.axis, prior, {})
            if ok and active ~= nil then
                capture.trigger_active[entry.axis] = active == true
                if active == true then out[#out + 1] = entry.token end
            end
        end
        return out
    end

    local function scan_capture_inputs(capture)
        local Capture = capture_module()
        local keys = capture.kind == "keyboard"
            and type(Capture) == "table" and Capture.KeyboardKeys
            or type(Capture) == "table" and Capture.ControllerKeys
        local active, host_rising = {}, {}
        for _, key in ipairs(type(keys) == "table" and keys or {}) do
            local ok, down, _, ready, press_delta = pcall(
                state.modui_client.ReadBindingKey, key)
            if ok and ready == true then
                if down == true then active[#active + 1] = key end
                for _ = 1, math.max(0, math.floor(tonumber(press_delta) or 0)) do
                    host_rising[#host_rising + 1] = key
                end
            end
        end
        if capture.kind == "controller" then
            for _, token in ipairs(controller_capture_tokens(capture)) do
                active[#active + 1] = token
            end
        end
        return active, host_rising
    end

    local function update_bind_capture()
        if not bind_capture_active() then return false end
        local capture = state.bind_capture
        local active, host_rising = scan_capture_inputs(capture)
        if capture.phase == "wait_clear" then
            if #active == 0 then
                capture.phase = "waiting"
                capture.previous_active = {}
                capture.starter_suppress_until = os.clock() + 0.22
                state.bind_capture_status = capture.kind == "keyboard"
                    and "Recording keyboard hotkey: press a chord or repeated-key sequence, then release all keys to save. Escape alone cancels."
                    or "Recording controller hotkey: press a chord or repeated-button sequence, then release everything to save. Circle/B alone cancels."
                publish_settings()
            end
            return true
        end

        if tonumber(capture.starter_suppress_until) ~= nil
            and os.clock() < capture.starter_suppress_until
            and #active == 1 and active[1] == capture.starter_token then
            active, host_rising = {}, {}
        end
        local active_set, rising, host_counts = {}, {}, {}
        for _, token in ipairs(active) do active_set[token] = true end
        for _, token in ipairs(host_rising) do
            host_counts[token] = (host_counts[token] or 0) + 1
            rising[#rising + 1] = token
        end
        for _, token in ipairs(active) do
            if host_counts[token] == nil and capture.previous_active[token] ~= true then
                rising[#rising + 1] = token
            end
        end
        if capture.phase == "waiting" then
            if #active == 0 and #host_rising == 0 then
                capture.previous_active = active_set
                return true
            end
            capture.phase = "recording"
        end
        if capture.phase == "recording" then
            for _, token in ipairs(active) do
                if not capture.seen[token] then
                    capture.seen[token] = true
                    capture.order[#capture.order + 1] = token
                end
            end
            for _, token in ipairs(rising) do
                if not capture.seen[token] then
                    capture.seen[token] = true
                    capture.order[#capture.order + 1] = token
                end
                capture.press_order[#capture.press_order + 1] = token
            end
            if #active == 0 then
                capture.previous_active = active_set
                return commit_bind_capture()
            end
            capture.previous_active = active_set
            local display = capture_display(capture)
            if display ~= capture.last_display then
                capture.last_display = display
                state.bind_capture_status = "Recording: " .. display
                    .. ". Release all controls to save; Escape/Circle alone cancels."
                publish_settings()
            end
        else
            capture.previous_active = active_set
        end
        return true
    end

    local function tab_strip()
        local parts = {}
        for index, tab in ipairs(visible_tabs()) do
            local label = tostring(tab.label or tab.key or index)
            parts[#parts + 1] = index == state.settings_tab and ("[ " .. label .. " ]") or label
        end
        return table.concat(parts, "    ")
    end

    local function safe_details(value, columns)
        value = tostring(value or "")
        local details = state.modui and state.modui.Settings and state.modui.Settings.Details or nil
        if type(details) == "table" and type(details.WrapLines) == "function"
            and type(details.Window) == "function" then
            local lines = details.WrapLines(value, tonumber(columns) or 38)
            return select(1, details.Window(lines, 0, 18))
        end
        return value
    end

    -- v0.16.8 (user): "The Controller Settings option in TTS should be built into Mod UI,
    -- and each mod adds that setting to open the Controller Settings window." The INPUT
    -- tab's Controller settings row opens ModUI's shared Controller.Settings view
    -- (deadzones, calibration, live test). The view owns its rows and modes; this file
    -- only routes navigation into it and publishes its presentation instead of the tab's.
    local function controller_view_active()
        return type(state.controller_view) == "table" and type(state.controller_view.Active) == "function"
            and state.controller_view.Active() == true
    end

    local function ensure_controller_view()
        if type(state.controller_view) == "table" then return state.controller_view end
        if type(state.modui_client) ~= "table" or type(state.modui_client.ControllerSettings) ~= "function" then
            return nil, "MortalShell2ModUI 0.70.0 or newer is required for the shared controller screen"
        end
        local ok, view, view_err = pcall(state.modui_client.ControllerSettings, {
            get_selected = function() return state.settings_selection end,
            -- The parent tab's selection never moves while the view is open, so the
            -- view's own row index stays inside the view.
            set_selected = function() end,
            set_status = function(text) state.controller_status = tostring(text or "") end,
            apply_window_profile = function() end, -- the published snapshot carries the profile
            redraw = function() return publish_settings() end,
            diag = function(event, fields) diagnostic(tostring(event), fields) end,
            log = log,
        })
        if not ok or type(view) ~= "table" then
            return nil, tostring(ok and view_err or view)
        end
        state.controller_view = view
        return view
    end

    local function open_controller_view()
        local view, view_err = ensure_controller_view()
        if view == nil then
            state.controller_status = tostring(view_err or "controller screen unavailable")
            log("Controller settings unavailable: " .. tostring(view_err))
            publish_settings()
            return false
        end
        state.controller_status = ""
        state.pending_reset = nil
        local opened = view.Open() == true
        debug_log("Controller settings " .. (opened and "opened" or "open failed"))
        return opened
    end

    local function close_controller_view(reason)
        if not controller_view_active() then return false end
        pcall(state.controller_view.Shutdown, reason)
        state.controller_status = ""
        return true
    end

    local function controller_snapshot()
        local presentation = type(state.modui) == "table" and type(state.modui.Controller) == "table"
            and type(state.modui.Controller.Settings) == "table"
            and state.modui.Controller.Settings.Presentation or nil
        if type(presentation) ~= "function" then return nil end
        local snapshot = presentation(state.controller_view, {
            header = "MINIMAP SETTINGS - CONTROLLER",
            status = state.controller_status,
            wrap = function(text) return safe_details(text, 42) end,
        })
        return type(snapshot) == "table" and snapshot or nil
    end

    local function settings_snapshot()
        local rows = current_rows()
        local selected_index = normalize_selection()
        local labels, values, kinds, progress = {}, {}, {}, {}
        for index, setting in ipairs(rows) do
            if is_header(setting) then
                -- v0.18.0: a plain title, no cursor, no value. The host draws the
                -- divider (ModUI 0.71.0 rowKind "header"); an older host shows the title.
                labels[#labels + 1] = "  " .. setting_label(setting)
                values[#values + 1] = ""
                kinds[#kinds + 1] = "header"
                progress[#progress + 1] = "0"
            else
                labels[#labels + 1] = (index == selected_index and "> " or "  ") .. setting_label(setting)
                local current = read_value(setting)
                local display
                if bind_capture_active() and setting.binding_kind == state.bind_capture.kind then
                    display = "Recording..."
                elseif setting.binding_kind ~= nil then
                    display = shared_binding_label(current)
                else
                    display = setting.format(current, Config)
                end
                if index == selected_index and not bind_capture_active() then display = "< " .. display .. " >" end
                values[#values + 1] = display
                kinds[#kinds + 1] = setting.binding_kind ~= nil and "binding"
                    or setting.kind == "action" and "action"
                    or setting.control == "slider" and "slider" or "choice"
                local row_values = setting_values(setting)
                if type(row_values) == "table" and #row_values > 1 then
                    progress[#progress + 1] = string.format("%.6f",
                        (nearest_value_index(row_values, current) - 1) / (#row_values - 1))
                else
                    progress[#progress + 1] = "0"
                end
            end
        end
        local selected = rows[selected_index]
        local detail = type(selected.detail) == "function" and selected.detail(Config) or selected.detail
        local reset_signature = tostring(state.settings_generation) .. ":tab:" .. tostring(current_tab().key)
        if selected.reset_tab == true and state.pending_reset == reset_signature then
            detail = "Activate Reset this tab again to confirm. Moving away or changing tabs cancels."
        end
        local recording = bind_capture_active()
        local tab_labels = {}
        local tabs = visible_tabs()
        for _, tab in ipairs(tabs) do tab_labels[#tab_labels + 1] = tostring(tab.label or tab.key or "") end
        return {
            profile = "main",
            header = "MINIMAP SETTINGS",
            page = string.format("%02d/%02d", state.settings_tab, #tabs),
            tabs = tab_strip(),
            tabLabels = table.concat(tab_labels, "\n"),
            selectedTab = state.settings_tab,
            selectedRow = selected_index,
            rowKinds = table.concat(kinds, "\n"),
            rowProgress = table.concat(progress, "\n"),
            labels = table.concat(labels, "\n"),
            values = table.concat(values, "\n"),
            body = recording
                and "Release everything to save   Escape / Circle alone cancels"
                or "Up/Down Select   Left/Right Change   A/D or L1/R1 Tabs   Enter/Cross Activate   Back Close",
            detailTitle = setting_label(selected),
            details = safe_details(recording and state.bind_capture_status
                or (selected.binding_kind ~= nil and state.bind_capture_status ~= ""
                    and state.bind_capture_status or detail)),
        }
    end

    publish_settings = function()
        if not state.settings_open or not state.modui_available then return false end
        local token = Perf.Begin()
        local snapshot = controller_view_active() and controller_snapshot() or nil
        if snapshot == nil then snapshot = settings_snapshot() end
        local ok, result, publish_error = pcall(
            state.modui_client.Presentation, snapshot, state.settings_generation)
        Perf.End("ui.publish", token)
        if not ok or type(result) ~= "table" then
            log("ModUI presentation failed: " .. tostring(ok and publish_error or result))
            return false
        end
        return true
    end

    local function release_input_and_modal(reason)
        local generation = state.settings_generation
        close_controller_view(reason or "settings-close")
        if bind_capture_active() then cancel_bind_capture(reason or "settings-close") end
        if state.modui_available and type(state.modui_client) == "table" then
            pcall(state.modui_client.NativeInput, false, generation)
            pcall(state.modui_client.ControllerInput, false)
        end
        if type(modal_isolation) == "table" then
            pcall(modal_isolation.ReleaseNativeModalIsolation, tostring(reason or "settings close"))
        end
        state.modui_native_request_sequence = 0
        state.modui_native_event_sequence = 0
        state.modui_native_host_epoch = ""
        state.modui_ownership_mismatch_steps = 0
        state.active_generation = 0
    end

    finalize_close = function(reason, generation)
        generation = math.max(0, math.floor(tonumber(generation) or state.settings_generation))
        if generation ~= state.settings_generation then return false end
        state.settings_open = false
        state.settings_closing = false
        state.pending_reset = nil
        release_input_and_modal(reason)
        if state.modui_available and type(state.modui_client) == "table" then
            pcall(state.modui_client.Session, "closed", generation, tostring(reason or "close"))
            pcall(state.modui_client.Lease, false, generation, tostring(reason or "close"))
        end
        debug_log("Settings closed reason=" .. tostring(reason) .. " guard=complete")
        return true
    end

    function runtime.CloseSettings(reason, immediate)
        if not state.settings_open and not state.settings_closing and state.native_modal_isolation ~= true
            and state.native_pause_bumped ~= true then return end
        local generation = state.settings_generation
        if state.settings_closing and immediate ~= true then return end
        close_controller_view(reason or "close")
        state.settings_open = false
        state.settings_closing = true
        state.pending_reset = nil
        if state.modui_available and type(state.modui_client) == "table" then
            pcall(state.modui_client.Session, "closing", generation, tostring(reason or "close"))
        end
        if immediate == true or type(close_guard) ~= "table" then
            if type(close_guard) == "table" and type(close_guard.Cancel) == "function" then close_guard.Cancel() end
            return finalize_close(reason, generation)
        end
        local scheduled = close_guard.Request(generation, tostring(reason or "close"))
        if scheduled ~= true then return finalize_close(reason, generation) end
        debug_log("Settings close quarantined reason=" .. tostring(reason) .. " durationMs=225")
    end

    local function open_failed(generation, reason)
        state.settings_open = false
        state.settings_closing = false
        if type(close_guard) == "table" and type(close_guard.Cancel) == "function" then close_guard.Cancel() end
        release_input_and_modal(reason)
        pcall(state.modui_client.Session, "closed", generation, "open-failed")
        pcall(state.modui_client.Lease, false, generation, "open-failed")
        log("Settings open blocked for input safety: " .. tostring(reason))
        return false
    end

    local function open_settings(reason)
        if state.settings_open or state.settings_closing or not state.modui_available or state.world_quarantined
            or (state.native_menu_gate_available and state.native_menu_active) then return false end
        if type(close_guard) == "table" and type(close_guard.Cancel) == "function" then close_guard.Cancel() end
        state.settings_generation = state.settings_generation + 1
        local generation = state.settings_generation
        state.active_generation = generation
        state.settings_open = true
        state.settings_closing = false
        state.pending_reset = nil
        normalize_selection()
        pcall(state.modui_client.Activate)
        pcall(state.modui_client.Lease, true, generation, tostring(reason or "open"))
        publish_settings()
        pcall(state.modui_client.Session, "opening", generation, tostring(reason or "open"))

        local player = Object.Unwrap(state.player)
        local controller = Object.Unwrap(state.controller)
        local handler = resolve_native_ui_handler(player)
        if not Object.Valid(handler) then handler = resolve_native_ui_handler(controller) end
        if not Object.Valid(player) or not Object.Valid(handler) then
            return open_failed(generation, "gameplay player/UI handler unavailable")
        end
        modal_config.pause_game_while_menu_open = Config.PauseGameWhileSettingsOpen == true
        local isolation_ok, isolated = pcall(modal_isolation.AcquireNativeModalIsolation, player, handler)
        if not isolation_ok or isolated ~= true then
            return open_failed(generation, "shared modal isolation unavailable")
        end

        local native_ok, native_request = pcall(state.modui_client.NativeInput, true, generation)
        if not native_ok or type(native_request) ~= "table" then
            return open_failed(generation, "native input listener unavailable")
        end
        state.modui_native_request_sequence = math.max(0, math.floor(tonumber(native_request.sequence) or 0))
        state.modui_native_event_sequence = 0
        state.modui_native_host_epoch = tostring(native_request.hostEpoch or "")
        pcall(state.modui_client.ControllerInput, true)
        pcall(state.modui_client.Session, "ready", generation, tostring(reason or "open"))
        debug_log("Settings opened generation=" .. tostring(generation)
            .. " tab=" .. tostring(current_tab().key)
            .. " modal=" .. tostring(state.native_modal_mode))
        return true
    end

    local function apply_pause_option()
        modal_config.pause_game_while_menu_open = Config.PauseGameWhileSettingsOpen == true
        if not state.settings_open or type(modal_isolation) ~= "table" then return end
        if modal_config.pause_game_while_menu_open then
            pcall(modal_isolation.PauseNativeGameplay, state.native_modal_handler, "user-option")
        else
            pcall(modal_isolation.ReleaseNativeGameplayPause, "user-option")
        end
    end

    -- Normalise, save and push one changed row into the running mod: pause option,
    -- hotkey binding, profiler flags, a rebuild, or a live renderer setting.
    local function apply_setting(setting, reason)
        ConfigRuntime.Normalize()
        ConfigRuntime.Save()
        if setting.apply == "settings-pause" then
            apply_pause_option()
        elseif setting.apply == "hotkey-binding" or setting.binding_kind ~= nil then
            runtime.PublishHotkey(state.modui_hotkey_enabled, "settings-binding", true)
        elseif setting.apply == "perf" then
            if type(ctx.PerfSync) == "function" then ctx.PerfSync("setting") end
        elseif setting.rebuild then
            state.rebuild_requested = true
        else
            Renderer.ApplyLiveSetting(setting)
        end
        publish_settings()
        local saved_value = read_value(setting)
        debug_log("Setting " .. tostring(setting.key) .. "=" .. tostring(saved_value) .. " via=" .. tostring(reason or "change"))
    end

    local function change_setting(direction)
        local setting = selected_setting()
        if type(setting) ~= "table" then return end
        local row_values = setting_values(setting)
        if setting.binding_kind ~= nil or setting.kind == "action" or bind_capture_active()
            or type(row_values) ~= "table" or #row_values == 0 then return end
        direction = direction < 0 and -1 or 1
        local old_value = read_value(setting)
        local index = nearest_value_index(row_values, old_value)
        -- v0.16.8 (user): the arrows cycle -- past the last value comes the first, so
        -- an On/Off row toggles either way and a list never dead-ends.
        index = ((index - 1 + direction) % #row_values) + 1
        local new_value = row_values[index]
        if old_value == new_value then return end
        if type(setting.write) == "function" then setting.write(Config, new_value) else Config[setting.key] = new_value end
        apply_setting(setting, "change")
    end

    -- v0.16.8 (user): holding R or L3 on a row for 5 s (ModUI 0.70.0 publishes
    -- "reset-row") puts that one row back to its default. Action rows have nothing to
    -- reset; binding rows go back to the shipped hotkey; per-category rows resolve to
    -- the category's own key first.
    local function reset_selected_setting(source)
        local setting = selected_setting()
        if type(setting) ~= "table" or bind_capture_active() then return false end
        if setting.kind == "action" or setting.reset_tab == true then return false end
        local key = type(setting.resolve_key) == "function" and setting.resolve_key(Config) or setting.key
        if key == nil or type(ConfigRuntime.ResetKey) ~= "function" then return false end
        local before = read_value(setting)
        ConfigRuntime.ResetKey(key)
        state.pending_reset = nil
        apply_setting(setting, "reset:" .. tostring(source or "hold"))
        local after = read_value(setting)
        debug_log("Reset row key=" .. tostring(key) .. " from=" .. tostring(before) .. " to=" .. tostring(after)
            .. " source=" .. tostring(source or "hold"))
        return true
    end

    local function activate_setting()
        local setting = selected_setting()
        if type(setting) ~= "table" then return end
        if setting.binding_kind ~= nil then
            start_bind_capture(setting.binding_kind)
            return
        end
        if setting.controller_settings == true then
            open_controller_view()
            return
        end
        if setting.reset_tab == true then
            local interaction = type(state.modui.Settings) == "table" and state.modui.Settings.Interaction or nil
            local confirmed = type(interaction) == "table" and type(interaction.ResetConfirmation) == "function"
                and interaction.ResetConfirmation(state, "tab:" .. tostring(current_tab().key), state.settings_generation)
            if not confirmed then publish_settings(); return end
            for _, candidate in ipairs(current_rows()) do
                if candidate.reset_tab ~= true then
                    local key = type(candidate.resolve_key) == "function"
                        and candidate.resolve_key(Config) or candidate.key
                    if key ~= nil then ConfigRuntime.ResetKey(key) end
                end
            end
            ConfigRuntime.Normalize()
            ConfigRuntime.Save()
            apply_pause_option()
            runtime.PublishHotkey(state.modui_hotkey_enabled, "tab-reset", true)
            state.rebuild_requested = true
            state.pending_reset = nil
            publish_settings()
            debug_log("Reset settings tab=" .. tostring(current_tab().key))
            return
        end
        local current = read_value(setting)
        change_setting(type(current) == "boolean" and (current and -1 or 1) or 1)
    end

    local function move_selection(direction)
        local rows = current_rows()
        if #rows == 0 then return end
        local next_index = ((normalize_selection() - 1 + direction) % #rows) + 1
        -- v0.18.0: step over section headers in the direction of travel.
        state.settings_selection = selectable_from(rows, next_index, direction)
        state.pending_reset = nil
        state.settings_selected_by_tab[selection_key()] = state.settings_selection
        publish_settings()
    end

    local function switch_tab(direction, absolute)
        state.settings_selected_by_tab[selection_key()] = normalize_selection()
        state.pending_reset = nil
        local count = #visible_tabs()
        if absolute ~= nil then
            state.settings_tab = clamp(math.floor(tonumber(absolute) or 1), 1, count)
        else
            current_tab() -- clamps state.settings_tab into the visible range first
            state.settings_tab = ((state.settings_tab - 1 + direction) % count) + 1
        end
        state.settings_selection = tonumber(state.settings_selected_by_tab[selection_key()]) or 1
        normalize_selection()
        publish_settings()
    end

    local function process_action(action)
        action = tostring(action or "")
        local interaction = type(state.modui) == "table" and type(state.modui.Settings) == "table"
            and state.modui.Settings.Interaction or nil
        if type(interaction) == "table" and type(interaction.Action) == "function" then
            action = tostring(interaction.Action(action) or action)
        end
        if type(state.modui) == "table" and type(state.modui.Input) == "table"
            and type(state.modui.Input.Route) == "table"
            and type(state.modui.Input.Route.Semantic) == "function" then
            action = tostring(state.modui.Input.Route.Semantic(action) or action)
        end
        if bind_capture_active() then return end
        if action == "toggle-menu" or action == "open-settings" then
            if state.settings_open then runtime.CloseSettings("toggle") else open_settings("hotkey") end
            return
        end
        if not state.settings_open or action == "mouse_left" or action == "mouse_right" then return end
        if controller_view_active() then
            local view = state.controller_view
            if action == "back" or action == "escape" then
                view.Back(action)
            elseif action == "up" then
                view.Move(-1)
            elseif action == "down" then
                view.Move(1)
            elseif action == "left" then
                view.Change(-1)
            elseif action == "right" then
                view.Change(1)
            elseif action == "enter" or action == "confirm" then
                view.Activate()
            end
            return
        end
        if action == "back" or action == "escape" then
            runtime.CloseSettings(action)
        elseif action == "up" then
            move_selection(-1)
        elseif action == "down" then
            move_selection(1)
        elseif action == "left" then
            change_setting(-1)
        elseif action == "right" then
            change_setting(1)
        elseif action == "previous_tab" or action == "page-up" then
            switch_tab(-1)
        elseif action == "next_tab" or action == "page-down" or action == "tab" then
            switch_tab(1)
        elseif action == "enter" or action == "confirm" then
            activate_setting()
        elseif action == "reset-row" then
            reset_selected_setting("hold")
        end
    end

    local function pointer_from_event(event)
        local interaction = type(state.modui) == "table" and type(state.modui.Settings) == "table"
            and state.modui.Settings.Interaction or nil
        if type(interaction) == "table" and type(interaction.Pointer) == "function" then
            return interaction.Pointer(event)
        end
        local x, y = tonumber(event.pointerX), tonumber(event.pointerY)
        local width, height = tonumber(event.viewportWidth), tonumber(event.viewportHeight)
        if x == nil or y == nil or width == nil or height == nil or width <= 0 or height <= 0 then return nil end
        local scale = height / 1080.0
        if scale <= 0 then return nil end
        return {
            x = ((x - width * 0.5) / scale) + 960.0,
            y = y / scale,
        }
    end

    local function handle_mouse_left(pointer, host_hit)
        if bind_capture_active() then return false end
        if type(pointer) ~= "table" or type(state.modui) ~= "table"
            or type(state.modui.Settings) ~= "table"
            or type(state.modui.Settings.Layout) ~= "table" then return false end
        local layout = state.modui.Settings.Layout
        local interaction = state.modui.Settings.Interaction
        local constants = layout.settings
        local x, y = tonumber(pointer.x), tonumber(pointer.y)
        if x == nil or y == nil or type(constants) ~= "table" then return false end

        -- v0.16.8: while the shared controller screen is up, clicks go to its rows.
        if controller_view_active() then
            local view = state.controller_view
            local view_rows = view.Rows() or {}
            local hit = type(host_hit) == "table" and host_hit or nil
            if hit == nil then
                local snapshot = controller_snapshot()
                hit = type(snapshot) == "table" and type(interaction) == "table" and type(interaction.Hit) == "function"
                    and interaction.Hit(layout, "browser", snapshot, { "CONTROLLER" }, 1, #view_rows, x, y) or nil
            end
            if type(hit) ~= "table" or (hit.kind ~= "value" and hit.kind ~= "label") then return false end
            local index = tonumber(hit.index) or 0
            if index < 1 or index > #view_rows then return false end
            if index ~= view.selected then view.Move(index - view.selected) end
            if hit.kind == "value" and tostring(view.Mode()) == "settings" then
                local row = view_rows[index]
                if type(row) == "table" and row.kind == "action" then view.Activate() else view.Change(hit.direction) end
            end
            return true
        end

        local rows = current_rows()
        -- v0.70.0 ModUI: the host resolves the pointer against the layout it drew and
        -- sends the answer with the event; that is authoritative. The local model is the
        -- fallback for a host that did not.
        local hit = type(host_hit) == "table" and host_hit or nil
        if hit == nil then
            local tab_labels = {}
            for _, tab in ipairs(visible_tabs()) do tab_labels[#tab_labels + 1] = tostring(tab.label or tab.key or "") end
            local snapshot = settings_snapshot()
            hit = type(interaction) == "table" and type(interaction.Hit) == "function"
                and interaction.Hit(layout, "main", snapshot, tab_labels,
                    state.settings_tab, #rows, x, y) or nil
        end
        if type(hit) ~= "table" then return false end
        if hit.kind == "tab-scroll" then switch_tab(tonumber(hit.direction) or 1); return true end
        if hit.kind == "tab" then switch_tab(0, hit.index); return true end
        if hit.kind ~= "value" and hit.kind ~= "label" then return false end
        hit.index = tonumber(hit.index) or 0
        if hit.index >= 1 and hit.index <= #rows then
            -- v0.18.0: a click on a section header lands nowhere.
            if is_header(rows[hit.index]) then return true end
            state.settings_selection = hit.index
            state.settings_selected_by_tab[selection_key()] = hit.index
            state.pending_reset = nil
            if hit.kind == "value" then
                local setting = rows[hit.index]
                if type(setting) == "table" and (setting.binding_kind ~= nil or setting.kind == "action") then
                    activate_setting()
                else
                    change_setting(hit.direction)
                end
            else
                publish_settings()
            end
            return true
        end
        return false
    end

    local function process_pointer_event(event)
        if bind_capture_active() then return end
        if type(event) ~= "table" or tonumber(event.generation) ~= tonumber(state.settings_generation) then return end
        local route = tostring(event.route or "")
        if route == "mouse_left" then
            local host_hit = nil
            if type(event.hitKind) == "string" and event.hitKind ~= "" then
                host_hit = { kind = event.hitKind, index = tonumber(event.hitIndex), direction = tonumber(event.hitDirection) }
            end
            handle_mouse_left(pointer_from_event(event), host_hit)
        elseif route == "mouse_right" then
            if controller_view_active() then
                state.controller_view.Back("mouse-right")
            else
                runtime.CloseSettings("mouse-right")
            end
        end
    end

    local function read_pointer_events()
        if not state.settings_open or type(state.modui_client) ~= "table"
            or type(state.modui_client.registry) ~= "table"
            or type(state.modui_client.registry.ReadNativeInputEvents) ~= "function" then return end
        local registration = state.modui_client.Registration()
        if type(registration) ~= "table" or state.modui_native_request_sequence <= 0
            or state.modui_native_host_epoch == "" then return end
        local ok, batch = pcall(state.modui_client.registry.ReadNativeInputEvents,
            registration.slot, registration.consumer, registration.revision,
            state.modui_native_host_epoch, state.modui_native_request_sequence,
            state.modui_native_event_sequence)
        if not ok or type(batch) ~= "table" then return end
        state.modui_native_event_sequence = math.max(state.modui_native_event_sequence,
            math.floor(tonumber(batch.sequence) or 0))
        for _, event in ipairs(type(batch.events) == "table" and batch.events or {}) do
            local route = tostring(event.route or "")
            if route == "mouse_left" or route == "mouse_right" then process_pointer_event(event) end
        end
    end

    function runtime.ReadActions()
        if not state.modui_available or type(state.modui_client) ~= "table" then return end
        local capture_owned_cycle = bind_capture_active()
        local token = Perf.Begin()
        if capture_owned_cycle then update_bind_capture() else read_pointer_events() end
        Perf.End(capture_owned_cycle and "ui.bind-capture" or "ui.pointer", token)
        if controller_view_active() then
            -- Calibration / live test: sample the sticks the host is streaming and redraw.
            token = Perf.Begin()
            pcall(state.controller_view.Poll)
            Perf.End("ui.controller-view", token)
        end
        token = Perf.Begin()
        local perf = type(state.performance) == "table" and state.performance or nil
        if perf ~= nil then perf.modui_action_reads = (tonumber(perf.modui_action_reads) or 0) + 1 end
        local ok, events = pcall(state.modui_client.ReadActions)
        Perf.End("ui.read-actions", token)
        if not ok or type(events) ~= "table" then return end
        if perf ~= nil then
            perf.modui_actions_received = (tonumber(perf.modui_actions_received) or 0) + #events
            if #events == 0 then
                perf.modui_empty_action_reads = (tonumber(perf.modui_empty_action_reads) or 0) + 1
            end
        end
        for _, event in ipairs(events) do
            local action = tostring(type(event) == "table" and event.action or "")
            local duplicate = action ~= "toggle-menu" and action ~= "open-settings"
                and action == state.last_action and (state.step_count - state.last_action_step) <= 1
            if not capture_owned_cycle and not bind_capture_active()
                and not duplicate and action ~= "" then
                state.last_action = action
                state.last_action_step = state.step_count
                token = Perf.Begin()
                process_action(action)
                Perf.End("ui.action", token)
            end
        end
    end

    function runtime.ReadShellState()
        state.modui_shell_active = state.settings_open or state.settings_closing
        if not state.modui_available or type(state.modui_client) ~= "table" then return end
        local perf = type(state.performance) == "table" and state.performance or nil
        if perf ~= nil then perf.modui_shell_reads = (tonumber(perf.modui_shell_reads) or 0) + 1 end
        local full_required = state.settings_open or state.settings_closing
            or type(state.modui_client.ReadVisibilitySnapshot) ~= "function"
        local ok, metadata
        local token = Perf.Begin()
        if full_required then
            if perf ~= nil then
                perf.modui_full_metadata_reads = (tonumber(perf.modui_full_metadata_reads) or 0) + 1
            end
            ok, metadata = pcall(state.modui_client.HostMetadata)
        else
            if perf ~= nil then
                perf.modui_visibility_snapshots = (tonumber(perf.modui_visibility_snapshots) or 0) + 1
            end
            ok, metadata = pcall(state.modui_client.ReadVisibilitySnapshot)
            if not ok or type(metadata) ~= "table" then
                if perf ~= nil then
                    perf.modui_visibility_fallbacks = (tonumber(perf.modui_visibility_fallbacks) or 0) + 1
                    perf.modui_full_metadata_reads = (tonumber(perf.modui_full_metadata_reads) or 0) + 1
                end
                ok, metadata = pcall(state.modui_client.HostMetadata)
            end
        end
        Perf.End(full_required and "ui.read-shell.full" or "ui.read-shell.snapshot", token)
        if not ok or type(metadata) ~= "table" then return end
        local session = tostring(metadata.menuSessionState or "idle")
        local shell = tostring(metadata.visibleShellHostState or metadata.menuShellState or "")
        local native_hook = tostring(metadata.nativeMenuHookState or "unavailable")
        local native_state = tostring(metadata.nativeMenuState or "unavailable")
        state.native_menu_gate_available = native_hook == "ready" or native_hook == "partial"
        state.native_menu_state = native_state
        state.native_menu_sequence = math.max(0, math.floor(tonumber(metadata.nativeMenuSequence) or 0))
        state.native_menu_active = state.native_menu_gate_available and (
            metadata.nativeMenuActive == true or native_state == "active"
                or native_state == "settling" or native_state == "quarantined")
        if state.settings_open then
            local registration = state.modui_client.Registration()
            local own_consumer = tostring(type(registration) == "table" and registration.consumer or mod_name)
            local own_generation = math.max(0, math.floor(tonumber(state.settings_generation) or 0))
            local active_consumer = tostring(metadata.menuActiveConsumer or "")
            local session_consumer = tostring(metadata.menuSessionConsumer or "")
            local lease_consumer = tostring(metadata.menuLeaseConsumer or "")
            local visible_consumer = tostring(metadata.visibleShellHostConsumer or "")
            local foreign = (active_consumer ~= "" and active_consumer ~= own_consumer)
                or (session_consumer ~= "" and session_consumer ~= own_consumer)
                or (lease_consumer ~= "" and lease_consumer ~= own_consumer)
                or (shell == "active" and visible_consumer ~= "" and visible_consumer ~= own_consumer)
            local owned = session_consumer == own_consumer
                and math.max(0, math.floor(tonumber(metadata.menuSessionGeneration) or 0)) == own_generation
                and (session == "opening" or session == "ready" or session == "closing")
                and lease_consumer == own_consumer
                and tostring(metadata.menuLeaseState or "") == "granted"
                and math.max(0, math.floor(tonumber(metadata.menuLeaseGeneration) or 0)) == own_generation
            if owned then
                state.modui_ownership_mismatch_steps = 0
            else
                state.modui_ownership_mismatch_steps =
                    math.max(0, math.floor(tonumber(state.modui_ownership_mismatch_steps) or 0)) + 1
                local limit = foreign and 2 or 12
                if state.modui_ownership_mismatch_steps >= limit then
                    log("Settings host ownership lost; restoring gameplay input and pause state")
                    runtime.CloseSettings("host-ownership-lost")
                    state.modui_shell_active = false
                    return
                end
            end
        else
            state.modui_ownership_mismatch_steps = 0
        end
        state.modui_shell_active = state.settings_open or state.settings_closing
            or session == "opening" or session == "ready" or session == "closing"
            or shell == "active"
    end

    function runtime.EmitSummary(reason)
        local perf = type(state.performance) == "table" and state.performance or {}
        log(string.format(
            "ModUI performance reason=%s actionReads=%d emptyActionReads=%d actions=%d shellReads=%d visibilitySnapshots=%d fullMetadataReads=%d visibilityFallbacks=%d narrowSnapshot=%s emptyActionFastReturn=%s summaryOnly=true",
            tostring(reason or "manual"),
            tonumber(perf.modui_action_reads) or 0,
            tonumber(perf.modui_empty_action_reads) or 0,
            tonumber(perf.modui_actions_received) or 0,
            tonumber(perf.modui_shell_reads) or 0,
            tonumber(perf.modui_visibility_snapshots) or 0,
            tonumber(perf.modui_full_metadata_reads) or 0,
            tonumber(perf.modui_visibility_fallbacks) or 0,
            tostring(type(state.modui_client) == "table"
                and type(state.modui_client.ReadVisibilitySnapshot) == "function"),
            tostring(true)))
    end

    return runtime
end

return Factory
