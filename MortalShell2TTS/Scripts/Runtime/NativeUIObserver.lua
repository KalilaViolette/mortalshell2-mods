-- MortalShell2TTS Runtime.NativeUIObserver
-- Pass 164 extraction: native UI observation, diagnostics, transition admission and handler resolution.

local M = {}

function M.Bind(deps)
    deps = type(deps) == "table" and deps or {}
    local dd = assert(deps.dd, "Runtime.NativeUIObserver requires dd")
    local ui = assert(deps.ui, "Runtime.NativeUIObserver requires ui")
    local unwrap = assert(deps.unwrap, "Runtime.NativeUIObserver requires unwrap")
    local valid = assert(deps.valid, "Runtime.NativeUIObserver requires valid")
    local object_name = assert(deps.object_name, "Runtime.NativeUIObserver requires object_name")
    local widget_text = assert(deps.widget_text, "Runtime.NativeUIObserver requires widget_text")
    local log = assert(deps.log, "Runtime.NativeUIObserver requires log")
    local diag = assert(deps.diag, "Runtime.NativeUIObserver requires diag")
    local scripts_dir = assert(deps.scripts_dir, "Runtime.NativeUIObserver requires scripts_dir")
    local NATIVE_BPFL_UI_ASSET = deps.NATIVE_BPFL_UI_ASSET
    local NATIVE_BPFL_UI_CDO = deps.NATIVE_BPFL_UI_CDO
    local native_widget_field = assert(deps.native_widget_field, "Runtime.NativeUIObserver requires native_widget_field")
    local native_menu_query = assert(deps.native_menu_query, "Runtime.NativeUIObserver requires native_menu_query")

local function object_address(object)
    return dd.ModUI.Object.Address(object)
end

local function same_object(left, right)
    return dd.ModUI.Object.Same(left, right)
end

dd.safe_property = dd.ModUI.Runtime.Observation.SafeProperty

dd.UIDiagnostics, dd.ui_diagnostics_error = dd.load_lua_table_module(scripts_dir .. "\\UI\\Diagnostics.lua", "UI.Diagnostics")
if dd.UIDiagnostics == nil or type(dd.UIDiagnostics.New) ~= "function" then
    diag("dependency.uiDiagnostics", { status = "missing-or-invalid", error = dd.ui_diagnostics_error })
    log("MortalShell2TTS UI diagnostics module is missing or invalid. Re-extract the release ZIP.")
    return
end
dd.ui_diagnostics, dd.ui_diagnostics_error = dd.UIDiagnostics.New({
    unwrap = unwrap,
    valid = valid,
    object_name = object_name,
    object_address = object_address,
    widget_text = widget_text,
    native_widget_field = native_widget_field,
    safe_property = dd.safe_property,
    diag = diag,
})
if type(dd.ui_diagnostics) ~= "table" then
    diag("dependency.uiDiagnostics", { status = "init-failed", error = dd.ui_diagnostics_error })
    log("MortalShell2TTS UI diagnostics module could not initialize. Re-extract the release ZIP.")
    return
end
for _, name in ipairs({
    "struct_field", "vector2_string", "margin_string", "widget_desired_size", "widget_visibility_value",
    "widget_text_value", "slot_diagnostic", "dump_widget_tree_readonly", "dump_size_box_readonly",
    "dump_scale_box_readonly", "dump_rich_text_readonly", "dump_progression_attribute_readonly",
}) do
    if type(dd.ui_diagnostics[name]) ~= "function" then
        diag("dependency.uiDiagnostics", { status = "missing-function", field = name })
        log("MortalShell2TTS UI diagnostics module is incomplete. Re-extract the release ZIP.")
        return
    end
    dd[name] = dd.ui_diagnostics[name]
end
diag("dependency.uiDiagnostics", { status = "ready", module = "UI.Diagnostics", readOnly = true })
dd.safe_bool_method = dd.ModUI.Runtime.Observation.SafeBoolMethod
dd.native_tarray_count = dd.ModUI.Array.Count
dd.number_list_csv = dd.ModUI.Input.Acceptance.ListCsv
dd.number_set_diff = dd.ModUI.Input.Acceptance.SetDiff
dd.read_native_object_array = dd.ModUI.Array.ObjectEntries
dd.native_name_string = dd.ModUI.Array.NameString

function dd.read_delegate_bindings(delegate_value)
    delegate_value = unwrap(delegate_value)
    if delegate_value == nil then return nil, "delegate=nil" end
    local get_bindings = delegate_value["GetBindings"]
    if get_bindings == nil then return nil, "GetBindings unavailable" end

    local ok, bindings = pcall(get_bindings, delegate_value)
    if not ok then return nil, tostring(bindings) end
    if bindings == nil then return {}, nil end
    if type(bindings) ~= "table" then
        return nil, "unexpected type=" .. tostring(type(bindings))
    end

    local result = {}
    for index = 1, #bindings do
        local entry = bindings[index]
        local target, function_name = nil, nil
        if type(entry) == "table" then
            target = entry.Object
            function_name = entry.FunctionName
        end
        result[#result + 1] = {
            index = index,
            target = target,
            target_name = valid(target) and object_name(target) or "<invalid>",
            function_name = dd.native_name_string(function_name),
        }
    end
    return result, nil
end

function dd.log_listener_delegate_bindings(listener, stage)
    listener = unwrap(listener)
    stage = tostring(stage or "listener")
    if not valid(listener) then
        diag("input.delegate", { stage = stage, status = "listener-invalid" })
        return
    end

    for _, field in ipairs({ "OnInputTriggered", "OnBackInputTriggered" }) do
        local delegate_value, field_error = dd.safe_property(listener, field)
        if delegate_value == nil then
            diag("input.delegate", {
                stage = stage,
                delegate = field,
                status = "field-unavailable",
                error = field_error,
            })
        else
            local bindings, binding_error = dd.read_delegate_bindings(delegate_value)
            if bindings == nil then
                diag("input.delegate", {
                    stage = stage,
                    delegate = field,
                    status = "read-failed",
                    error = binding_error,
                })
            else
                diag("input.delegate", {
                    stage = stage,
                    delegate = field,
                    status = "ok",
                    count = #bindings,
                })
                for _, binding in ipairs(bindings) do
                    diag("input.delegate.binding", {
                        stage = stage,
                        delegate = field,
                        index = binding.index,
                        target = binding.target_name,
                        functionName = binding.function_name,
                    })
                end
            end
        end
    end
end

dd.listener_input_handle_count = dd.ModUI.Runtime.Observation.ListenerInputHandleCount

function dd.log_listener_input_handles(listener, stage)
    local count, err = dd.listener_input_handle_count(listener)
    diag("input.handles", {
        stage = tostring(stage or "listener"),
        count = count ~= nil and count or "<unknown>",
        error = err,
    })
    return count
end

dd.handler_active_listener_snapshot = dd.ModUI.Runtime.Observation.HandlerActiveListenerSnapshot

function dd.log_handler_active_listeners(handler, listener, stage)
    local count, contains, names, err = dd.handler_active_listener_snapshot(handler, listener)
    diag("handler.activeListeners", {
        stage = tostring(stage or "state"),
        count = count ~= nil and count or "<unknown>",
        containsTTS = contains,
        entries = table.concat(names or {}, "|"),
        error = err,
    })
    return count, contains
end

dd.InputBridgeDiagnostics = dd.InputBridgeDiagnosticsFactory.Bind({
    ui = ui,
    log = log,
    diag = diag,
    listCsv = dd.number_list_csv,
    logHandles = dd.log_listener_input_handles,
    logActive = dd.log_handler_active_listeners,
})

function dd.resolve_native_ui_handler(world_context)
    local handler, meta = dd.ModUI.Runtime.Resolve.UIHandlerWithFallback(world_context, {
        LoadAsset = LoadAsset,
        StaticFindObject = StaticFindObject,
        FindFirstOf = FindFirstOf,
        BPFLAsset = NATIVE_BPFL_UI_ASSET,
        BPFLCdo = NATIVE_BPFL_UI_CDO,
    })
    meta = type(meta) == "table" and meta or { status = "failed" }

    if meta.status == "bpfl" and valid(handler) then
        diag("handler.resolve", {
            status = "bpfl",
            handler = object_name(handler),
        })
        return handler
    end

    if meta.status == "FindFirstOf-fallback" and valid(handler) then
        local primary = type(meta.primary) == "table" and meta.primary or {}
        if primary.status == "bpfl-no-object-return" then
            diag("handler.resolve", {
                status = "bpfl-no-object-return",
                first = tostring(primary.first),
                second = tostring(primary.second),
                third = tostring(primary.third),
            })
        elseif primary.status == "bpfl-call-failed" then
            diag("handler.resolve", {
                status = "bpfl-call-failed",
                error = tostring(primary.error),
            })
        elseif primary.status == "bpfl-cdo-unavailable" then
            diag("handler.resolve", {
                status = "bpfl-cdo-unavailable",
                cdo = tostring(primary.cdo),
            })
        end
        diag("handler.resolve", {
            status = "FindFirstOf-fallback",
            handler = object_name(handler),
        })
        return handler
    end

    if meta.status == "world-context-invalid" then
        diag("handler.resolve", { status = "world-context-invalid" })
        return nil
    end

    local primary = type(meta.primary) == "table" and meta.primary or {}
    if primary.status == "bpfl-no-object-return" then
        diag("handler.resolve", {
            status = "bpfl-no-object-return",
            first = tostring(primary.first),
            second = tostring(primary.second),
            third = tostring(primary.third),
        })
    elseif primary.status == "bpfl-call-failed" then
        diag("handler.resolve", {
            status = "bpfl-call-failed",
            error = tostring(primary.error),
        })
    elseif primary.status == "bpfl-cdo-unavailable" then
        diag("handler.resolve", {
            status = "bpfl-cdo-unavailable",
            cdo = tostring(primary.cdo),
        })
    end

    diag("handler.resolve", {
        status = "failed",
        fallback = tostring(meta.fallback),
    })
    return nil
end

dd.object_field_name = dd.ModUI.Runtime.Observation.ObjectFieldName

dd.native_ui_observer = dd.native_ui_observer or {
    polls = 0,
    -- Pass 146 intentionally does NOT retain a BPC_UserInterfaceHandler UObject here.
    -- Runtime observation only runs while Settings is active, so the already-owned
    -- ui.native_ui_handler is the authoritative session-scoped handler. Retaining a second
    -- wrapper across LoadMap allowed the old-world handler to survive in Lua and later be
    -- validated from an EngineTick-delayed poll after Unreal had destroyed its world.
    handler = nil,
    tracker = dd.ModUI.Runtime.NativeState.NewTracker(),
    errorLogged = false,
}

function dd.reset_native_ui_observer_world_scope(reason)
    local state = dd.native_ui_observer
    if type(state) ~= "table" then return false end
    -- Primitive/Lua-table reset only. Never validate or otherwise dereference the old handler.
    state.handler = nil
    state.polls = 0
    state.errorLogged = false
    state.tracker = dd.ModUI.Runtime.NativeState.NewTracker()
    diag("nativeUI.observer", {
        status = "world-scope-reset",
        reason = tostring(reason or "world-scope-break"),
        generation = tonumber(ui.active_generation) or 0,
    })
    return true
end

function dd.observe_native_ui_state(controller)
    local state = dd.native_ui_observer
    state.polls = (tonumber(state.polls) or 0) + 1
    -- The existing open-binding poll runs at 50 ms with a live controller. Sampling
    -- every fourth pass keeps this read-only observer bounded near 5 Hz without
    -- adding another timer, loop, or hook.
    if state.polls % 4 ~= 0 then return true end
    local perf = dd.perf
    local token = perf ~= nil and perf.Begin() or nil
    local result = dd.observe_native_ui_state_body(controller)
    if token ~= nil then perf.End("poll.native-ui-observer", token) end
    return result
end

-- Body of the 5 Hz read-only observer, timed as poll.native-ui-observer.
function dd.observe_native_ui_state_body(controller)
    local state = dd.native_ui_observer

    diag("input.nativeObserverPhase", {
        stage = "enter",
        generation = tonumber(ui.active_generation) or 0,
        poll = tonumber(state.polls) or 0,
        handlerSource = "ui.native_ui_handler",
    })

    controller = unwrap(controller)
    if not valid(controller) then return false end

    -- Pass 146: never validate a separately retained observer handler. The Settings session
    -- already owns the current-world handler and clears it on close/LoadMap retirement.
    local handler = unwrap(ui.native_ui_handler)
    if not valid(handler) then
        diag("input.nativeObserverPhase", {
            stage = "session-handler-unavailable",
            generation = tonumber(ui.active_generation) or 0,
            poll = tonumber(state.polls) or 0,
        })
        return false
    end

    local snapshot, observed = dd.ModUI.Runtime.Observation.AdmissionSnapshot(handler, controller)
    local map_ok, map_allowed = native_menu_query(handler, "MapMenuQuery")
    local options_ok, options_allowed = native_menu_query(handler, "OptionsMenuQuery")

    local confirmations_count = observed.ActiveConfirmations
    local confirmation_names = {}
    local confirmations = dd.ModUI.Runtime.Observation.SafeProperty(handler, "ActiveConfirmations")
    if confirmations ~= nil then
        local entries = dd.ModUI.Array.ObjectEntries(confirmations)
        if type(entries) == "table" then
            confirmations_count = #entries
            for _, entry in ipairs(entries) do
                confirmation_names[#confirmation_names + 1] = tostring(entry.index) .. ":" .. tostring(entry.name)
            end
        end
    end

    local observation = {
        handlerValid = snapshot.handlerValid == true,
        activeMenu = observed.ActiveMenu,
        activeSubMenu = observed.ActiveSubMenu,
        activeReadText = observed.ActiveReadText,
        transitionWidget = observed.CurrentTransitionWidget,
        confirmationsCount = confirmations_count,
        confirmations = table.concat(confirmation_names, ","),
        noActiveMenu = observed.NoActiveMenu,
        controllerInMenu = observed.ControllerIsInGameMenu,
        handlerInMenu = observed.HandlerIsInGameMenu,
        -- Preserve the full true / false / unknown tri-state. Lua's common
        -- `ok and value or nil` idiom collapses a legitimate false to nil, which
        -- defeated Pass 89's idle-block classifier exactly when a native query
        -- was denied. Runtime.NativeState owns the generic tri-state helper.
        canOpenOptions = dd.ModUI.Runtime.NativeState.KnownBoolean(options_ok, options_allowed),
        canOpenMap = dd.ModUI.Runtime.NativeState.KnownBoolean(map_ok, map_allowed),
        ownedModalActive = ui.open == true or ui.closing == true or ui.native_modal_isolation == true,
        pendingOwnedCleanup = type(ui.native_modal_pending_cleanup) == "table",
    }

    local result = dd.ModUI.Runtime.NativeState.Observe(state.tracker, observation)
    state.tracker = result.tracker
    if result.changed or result.idleBlockedMilestone ~= nil then
        diag("nativeUI.observer", {
            transition = result.transition,
            samples = result.samples,
            changed = result.changed,
            idleBlockedCandidate = result.idleBlockedCandidate,
            idleBlockedSamples = result.idleBlockedSamples,
            idleBlockedMilestone = result.idleBlockedMilestone,
            ActiveMenu = observation.activeMenu,
            ActiveSubMenu = observation.activeSubMenu,
            ActiveReadText = observation.activeReadText,
            CurrentTransitionWidget = observation.transitionWidget,
            ActiveConfirmations = observation.confirmationsCount,
            ConfirmationEntries = observation.confirmations,
            NoActiveMenu = observation.noActiveMenu,
            ControllerIsInGameMenu = observation.controllerInMenu,
            HandlerIsInGameMenu = observation.handlerInMenu,
            OptionsAllowed = observation.canOpenOptions,
            MapAllowed = observation.canOpenMap,
            TTSModalActive = observation.ownedModalActive,
            pendingOwnedCleanup = observation.pendingOwnedCleanup,
        })

        if result.idleBlockedMilestone ~= nil then
            log("native UI idle-block candidate"
                .. " samples=" .. tostring(result.idleBlockedSamples)
                .. " OptionsAllowed=" .. tostring(observation.canOpenOptions)
                .. " MapAllowed=" .. tostring(observation.canOpenMap)
                .. " ActiveMenu=" .. tostring(observation.activeMenu)
                .. " Confirmations=" .. tostring(observation.confirmationsCount)
                .. " TTSModalActive=" .. tostring(observation.ownedModalActive)
                .. " pendingOwnedCleanup=" .. tostring(observation.pendingOwnedCleanup))
        end
    end
    state.errorLogged = false
    diag("input.nativeObserverPhase", {
        stage = "exit",
        generation = tonumber(ui.active_generation) or 0,
        poll = tonumber(state.polls) or 0,
        handlerSource = "ui.native_ui_handler",
    })
    return true
end

-- Pass 135: native menu admission is necessary but not sufficient during streaming/map travel.
-- The Pass-134 crash proved OptionsMenuQuery can flip false -> true roughly one second before
-- a newly reacquired local PlayerController/world is safe for constructing the borrowed Settings
-- UMG graph. Retain a conservative recent-denial cooldown and combine it with Runtime.InputHost's
-- primitive controller-reacquisition settle gate. No old-world UObject is stored by this guard.
dd.native_transition_guard_until = tonumber(dd.native_transition_guard_until) or 0
dd.native_transition_guard_seconds = 3

function dd.note_native_transition_denial(reason)
    reason = tostring(reason or "")
    if not reason:find("OptionsMenuQuery=false", 1, true)
        and not reason:find("CurrentTransitionWidget", 1, true)
        and not reason:find("handler-unavailable", 1, true) then
        return false
    end
    local now = tonumber(os.time()) or 0
    local until_time = now + (tonumber(dd.native_transition_guard_seconds) or 3)
    if until_time > (tonumber(dd.native_transition_guard_until) or 0) then
        dd.native_transition_guard_until = until_time
    end
    diag("admission.transitionGuard", {
        status = "armed", reason = reason, untilEpoch = dd.native_transition_guard_until,
        cooldownSeconds = tonumber(dd.native_transition_guard_seconds) or 3,
    })
    return true
end

function dd.evaluate_transition_settle_admission(controller)
    controller = unwrap(controller)
    if not valid(controller) then return false, "transition-settle:controller-unavailable" end

    if type(dd.open_bind_transition_settled) == "function" then
        local ok_probe, settled, settle_reason = pcall(dd.open_bind_transition_settled, controller)
        if not ok_probe then
            return false, "transition-settle:controller-probe-error"
        end
        if settled ~= true then
            return false, "transition-settle:" .. tostring(settle_reason or "controller-reacquired-settling")
        end
    end

    local now = tonumber(os.time()) or 0
    local until_time = tonumber(dd.native_transition_guard_until) or 0
    if now < until_time then
        return false, "transition-settle:recent-native-loading-denial"
    end
    return true, nil
end

function dd.evaluate_native_menu_admission(handler, controller, stage)
    handler = unwrap(handler)
    controller = unwrap(controller)
    stage = tostring(stage or "pre-open")

    local snapshot, observed = dd.ModUI.Runtime.Observation.AdmissionSnapshot(handler, controller)
    if snapshot.handlerValid == false then
        local allowed, _, reason = dd.ModUI.Runtime.Admission.Evaluate(snapshot)
        diag("admission.state", {
            stage = stage,
            status = "handler-invalid",
            allowed = allowed,
            policy = "diagnostic-fail-open",
        })
        return allowed, reason
    end

    local allowed, blockers, admission_reason = dd.ModUI.Runtime.Admission.Evaluate(snapshot)
    diag("admission.state", {
        stage = stage,
        allowed = allowed,
        blockers = table.concat(blockers, ","),
        ActiveMenu = observed.ActiveMenu,
        ActiveSubMenu = observed.ActiveSubMenu,
        ActiveReadText = observed.ActiveReadText,
        CurrentTransitionWidget = observed.CurrentTransitionWidget,
        ActiveConfirmations = observed.ActiveConfirmations ~= nil and observed.ActiveConfirmations or "<unknown>",
        NoActiveMenu = observed.NoActiveMenu,
        NoActiveMenuError = observed.NoActiveMenuError,
        ControllerIsInGameMenu = observed.ControllerIsInGameMenu,
        ControllerIsInGameMenuError = observed.ControllerIsInGameMenuError,
        HandlerIsInGameMenu = observed.HandlerIsInGameMenu,
        CanOpenOptions = observed.CanOpenOptions,
        CanOpenOptionsError = observed.CanOpenOptionsError,
    })

    if not allowed then
        return false, admission_reason or table.concat(blockers, ",")
    end
    return true, nil
end

function dd.log_blocked_native_admission(handler, controller, reason)
    handler = unwrap(handler)
    controller = unwrap(controller)

    local snapshot, observed = dd.ModUI.Runtime.Observation.AdmissionSnapshot(handler, controller)
    local map_ok, map_allowed, map_error = native_menu_query(handler, "MapMenuQuery")
    local options_ok, options_allowed, options_error = native_menu_query(handler, "OptionsMenuQuery")
    local move_probe, move_ignored = dd.ModUI.Runtime.Observation.ControllerIgnoredState(controller, "IsMoveInputIgnored")
    local look_probe, look_ignored = dd.ModUI.Runtime.Observation.ControllerIgnoredState(controller, "IsLookInputIgnored")

    local signature = table.concat({
        tostring(reason or ""),
        tostring(observed.ActiveMenu),
        tostring(observed.ActiveSubMenu),
        tostring(observed.ActiveReadText),
        tostring(observed.CurrentTransitionWidget),
        tostring(observed.ActiveConfirmations),
        tostring(observed.NoActiveMenu),
        tostring(observed.ControllerIsInGameMenu),
        tostring(observed.HandlerIsInGameMenu),
        (options_ok and tostring(options_allowed) or "<unknown>"),
        (map_ok and tostring(map_allowed) or "<unknown>"),
        (move_probe and tostring(move_ignored) or "<unknown>"),
        (look_probe and tostring(look_ignored) or "<unknown>"),
    }, "|")

    if signature == ui.admission_block_signature then
        ui.admission_block_repeat_count = (tonumber(ui.admission_block_repeat_count) or 0) + 1
    else
        ui.admission_block_signature = signature
        ui.admission_block_repeat_count = 1
    end

    local repeat_count = tonumber(ui.admission_block_repeat_count) or 1
    if repeat_count == 1 or repeat_count % 5 == 0 then
        log("native admission blocked snapshot"
            .. " reason=" .. tostring(reason)
            .. " repeat=" .. tostring(repeat_count)
            .. " ActiveMenu=" .. tostring(observed.ActiveMenu)
            .. " ActiveSubMenu=" .. tostring(observed.ActiveSubMenu)
            .. " ActiveReadText=" .. tostring(observed.ActiveReadText)
            .. " Transition=" .. tostring(observed.CurrentTransitionWidget)
            .. " Confirmations=" .. tostring(observed.ActiveConfirmations)
            .. " NoActiveMenu=" .. tostring(observed.NoActiveMenu)
            .. " ControllerInMenu=" .. tostring(observed.ControllerIsInGameMenu)
            .. " HandlerInMenu=" .. tostring(observed.HandlerIsInGameMenu)
            .. " OptionsAllowed=" .. (options_ok and tostring(options_allowed) or "<unknown>")
            .. " MapAllowed=" .. (map_ok and tostring(map_allowed) or "<unknown>")
            .. " MoveIgnored=" .. (move_probe and tostring(move_ignored) or "<unknown>")
            .. " LookIgnored=" .. (look_probe and tostring(look_ignored) or "<unknown>"))

        diag("admission.blocked", {
            reason = tostring(reason or "blocked"),
            repeatCount = repeat_count,
            ActiveMenu = observed.ActiveMenu,
            ActiveSubMenu = observed.ActiveSubMenu,
            ActiveReadText = observed.ActiveReadText,
            CurrentTransitionWidget = observed.CurrentTransitionWidget,
            ActiveConfirmations = observed.ActiveConfirmations ~= nil and observed.ActiveConfirmations or "<unknown>",
            NoActiveMenu = observed.NoActiveMenu,
            ControllerIsInGameMenu = observed.ControllerIsInGameMenu,
            HandlerIsInGameMenu = observed.HandlerIsInGameMenu,
            OptionsAllowed = options_ok and tostring(options_allowed) or "<unknown>",
            OptionsError = options_error,
            MapAllowed = map_ok and tostring(map_allowed) or "<unknown>",
            MapError = map_error,
            MoveIgnored = move_probe and tostring(move_ignored) or "<unknown>",
            LookIgnored = look_probe and tostring(look_ignored) or "<unknown>",
            pendingOwnedCleanup = type(ui.native_modal_pending_cleanup) == "table",
        })
    end

    return snapshot, observed
end

    return {
        ObjectAddress = object_address,
        SameObject = same_object,
    }
end

return M
