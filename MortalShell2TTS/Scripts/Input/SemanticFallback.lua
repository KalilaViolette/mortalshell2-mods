-- MortalShell2TTS Input.SemanticFallback
-- Pass 163 extraction: consumer-local semantic/pointer fallback and legacy InputBridge
-- teardown helpers. Healthy shared-menu semantics remain owned by MortalShell2ModUI.Host.SemanticService.

local M = {}

function M.Install(ctx)
    ctx = type(ctx) == "table" and ctx or {}
    local dd = assert(ctx.dd, "Input.SemanticFallback requires dd")
    local ui = assert(ctx.ui, "Input.SemanticFallback requires ui")
    local unwrap = assert(ctx.unwrap, "Input.SemanticFallback requires unwrap")
    local valid = assert(ctx.valid, "Input.SemanticFallback requires valid")
    local same_object = assert(ctx.same_object, "Input.SemanticFallback requires same_object")
    local object_address = assert(ctx.object_address, "Input.SemanticFallback requires object_address")
    local native_controller_is_gamepad = assert(ctx.native_controller_is_gamepad, "Input.SemanticFallback requires native_controller_is_gamepad")
    local native_input_value = assert(ctx.native_input_value, "Input.SemanticFallback requires native_input_value")
    local dispatch_native_controller_route = assert(ctx.dispatch_native_controller_route, "Input.SemanticFallback requires dispatch_native_controller_route")
    local runtime_diagnostics = assert(ctx.runtime_diagnostics, "Input.SemanticFallback requires runtime_diagnostics")
    local log = type(ctx.log) == "function" and ctx.log or function() end
    local diag = type(ctx.diag) == "function" and ctx.diag or function() end
    local RegisterHook = assert(ctx.RegisterHook, "Input.SemanticFallback requires RegisterHook")
    local UnregisterHook = assert(ctx.UnregisterHook, "Input.SemanticFallback requires UnregisterHook")

function dd.host_native_semantics_active(generation)
    local rt = _G.MortalShell2TTSRuntime
    local state = type(rt) == "table" and rt.modui_host_native_input_state or nil
    generation = tonumber(generation) or tonumber(ui.active_generation) or 0
    return type(rt) == "table"
        and rt.modui_host_native_input_hook_ready == true
        and type(state) == "table"
        and state.active == true
        and tonumber(state.generation) == generation
        and generation > 0
end

-- Pass 123 transfers pointer semantics only after the standalone host has proven,
-- in the current process, that its callback-time snapshot agrees with the existing
-- consumer-local resolver. The first valid pointer event remains local/bootstrap.
-- Later events may delegate, but every delegated event keeps its local callback-time
-- snapshot as a fail-soft fallback if the host tuple is missing or drifts beyond the
-- deliberately small reference-space tolerance.
local HOST_POINTER_REFERENCE_TOLERANCE = 8.0

function dd.host_native_pointer_semantics_active(generation)
    local rt = _G.MortalShell2TTSRuntime
    return dd.host_native_semantics_active(generation)
        and type(rt) == "table"
        and rt.modui_host_pointer_snapshot_ready == true
end

function dd.record_local_pointer_snapshot(generation, input_number, route)
    local pointer = dd.mouse_screen_position()
    if type(pointer) ~= "table" then return nil end
    ui.host_pointer_compare_queue = type(ui.host_pointer_compare_queue) == "table" and ui.host_pointer_compare_queue or {}
    local queue = ui.host_pointer_compare_queue
    local sample = {
        generation = tonumber(generation) or 0,
        input = tonumber(input_number),
        route = tostring(route or ""),
        referenceX = tonumber(pointer.reference_x),
        referenceY = tonumber(pointer.reference_y),
        screenX = tonumber(pointer.x),
        screenY = tonumber(pointer.y),
        width = tonumber(pointer.width),
        height = tonumber(pointer.height),
        source = tostring(pointer.source or "consumer-local"),
        delegated = false,
        pointer = {
            x = tonumber(pointer.x),
            y = tonumber(pointer.y),
            width = tonumber(pointer.width),
            height = tonumber(pointer.height),
            reference_x = tonumber(pointer.reference_x),
            reference_y = tonumber(pointer.reference_y),
            normalized_x = tonumber(pointer.normalized_x),
            normalized_y = tonumber(pointer.normalized_y),
            source = tostring(pointer.source or "consumer-local"),
        },
    }
    queue[#queue + 1] = sample
    while #queue > 32 do table.remove(queue, 1) end
    return sample
end

function dd.host_pointer_from_event(event)
    event = type(event) == "table" and event or {}
    local px = tonumber(event.pointerX)
    local py = tonumber(event.pointerY)
    local width = tonumber(event.viewportWidth)
    local height = tonumber(event.viewportHeight)
    if px == nil or py == nil or width == nil or height == nil or width <= 0.0 or height <= 0.0 then
        return nil
    end
    local reference_scale = height / 1080.0
    if reference_scale <= 0.0 then return nil end
    local reference_x = ((px - (width * 0.5)) / reference_scale) + 960.0
    local reference_y = py / reference_scale
    return {
        x = px,
        y = py,
        width = width,
        height = height,
        reference_x = reference_x,
        reference_y = reference_y,
        normalized_x = (reference_x / 960.0) - 1.0,
        normalized_y = (reference_y / 540.0) - 1.0,
        source = "ModUIHost:" .. tostring(event.pointerSource or "unknown"),
        host_source = tostring(event.pointerSource or "unknown"),
        -- ModUI 0.70.0: what the visible shell found under the pointer in the layout it
        -- drew (tab / tab-scroll / label / value). handle_mouse_click prefers it.
        host_hit = (type(event.hitKind) == "string" and event.hitKind ~= "") and {
            kind = event.hitKind, index = tonumber(event.hitIndex), direction = tonumber(event.hitDirection),
        } or nil,
    }
end

function dd.observe_host_pointer_snapshot(event, source, route)
    event = type(event) == "table" and event or {}
    local generation = tonumber(event.generation) or 0
    local input_number = tonumber(event.input)
    local host_pointer = dd.host_pointer_from_event(event)

    local queue = type(ui.host_pointer_compare_queue) == "table" and ui.host_pointer_compare_queue or {}
    local local_sample = nil
    local match_index = nil
    for index, candidate in ipairs(queue) do
        if tonumber(candidate.generation) == generation and tonumber(candidate.input) == input_number then
            local_sample = candidate
            match_index = index
            break
        end
    end
    if match_index ~= nil then table.remove(queue, match_index) end

    local rt = _G.MortalShell2TTSRuntime
    if host_pointer == nil then
        if type(rt) == "table" then rt.modui_host_pointer_snapshot_ready = false end
        diag("input.hostPointerSnapshot", {
            status = "host-missing",
            route = route,
            input = input_number,
            source = source,
            generation = generation,
            localSnapshot = local_sample ~= nil,
            delegated = local_sample ~= nil and local_sample.delegated == true,
        })
        return nil, local_sample, "host-missing"
    end

    local delta_x = local_sample ~= nil and tonumber(local_sample.referenceX) ~= nil
        and math.abs(host_pointer.reference_x - tonumber(local_sample.referenceX)) or nil
    local delta_y = local_sample ~= nil and tonumber(local_sample.referenceY) ~= nil
        and math.abs(host_pointer.reference_y - tonumber(local_sample.referenceY)) or nil
    local compared = local_sample ~= nil and delta_x ~= nil and delta_y ~= nil
    local within_tolerance = compared
        and delta_x <= HOST_POINTER_REFERENCE_TOLERANCE
        and delta_y <= HOST_POINTER_REFERENCE_TOLERANCE

    if type(rt) == "table" and compared then
        rt.modui_host_pointer_snapshot_ready = within_tolerance
    end

    diag("input.hostPointerSnapshot", {
        status = compared and (within_tolerance and "compared" or "mismatch") or "host-only",
        route = route,
        input = input_number,
        source = source,
        generation = generation,
        hostSource = tostring(event.pointerSource or "unknown"),
        hostScreenX = host_pointer.x,
        hostScreenY = host_pointer.y,
        hostViewport = string.format("%.0fx%.0f", host_pointer.width, host_pointer.height),
        hostReferenceX = host_pointer.reference_x,
        hostReferenceY = host_pointer.reference_y,
        localSource = local_sample ~= nil and local_sample.source or nil,
        localReferenceX = local_sample ~= nil and local_sample.referenceX or nil,
        localReferenceY = local_sample ~= nil and local_sample.referenceY or nil,
        deltaX = delta_x,
        deltaY = delta_y,
        delegated = local_sample ~= nil and local_sample.delegated == true,
        tolerance = HOST_POINTER_REFERENCE_TOLERANCE,
    })
    return within_tolerance and host_pointer or nil, local_sample,
        compared and (within_tolerance and "compared" or "mismatch") or "host-only"
end

function dd.ensure_native_input_hook_runtime()
    _G.MortalShell2TTSRuntime = _G.MortalShell2TTSRuntime or {}
    local native_runtime = _G.MortalShell2TTSRuntime

    -- The semantic handler function remains MortalShell2TTS-owned. Runtime.InputBridge owns
    -- the generic replaceable-handler slot plus the stable callback identity that forwards to it.
    local semantic_handler = function(Context, Input)
        local listener = unwrap(Context)
        local generation = tonumber(ui.active_generation) or 0
        if not ui.open or ui.closing or generation <= 0
            or (ui.host_visible_shell ~= true and not valid(ui.widget)) or not valid(listener) then
            return
        end

        if ui.native_host_listener_primary == true then
            local expected_address = tostring(ui.native_host_listener_address or "")
            if expected_address == "" and type(dd.read_modui_host_native_listener_address) == "function" then
                local refreshed = tostring(dd.read_modui_host_native_listener_address() or "")
                if refreshed:match("^%d+$") then
                    expected_address = refreshed
                    ui.native_host_listener_address = refreshed
                end
            end
            local callback_address = tonumber(object_address(listener))
            local callback_text = callback_address ~= nil and string.format("%.0f", callback_address) or ""
            if expected_address == "" or callback_text ~= expected_address then return end
            if next(ui.native_route_by_enum) == nil then
                local routes = dd.ModUI.Runtime.Listener.BuildRoutes(listener, 0, 32)
                routes = type(routes) == "table" and routes or {}
                ui.native_route_by_enum = type(routes.routeByEnum) == "table" and routes.routeByEnum or {}
                ui.native_route_by_action = type(routes.routeByAction) == "table" and routes.routeByAction or {}
                ui.native_action_name_by_enum = type(routes.actionNameByEnum) == "table" and routes.actionNameByEnum or {}
                ui.mouse_input_ready = routes.mouseInputReady == true
                diag("input.hostPrimaryRoutes", {
                    status = tostring(routes.status or "unknown"), generation = generation,
                    address = expected_address, entries = type(routes.entries) == "table" and #routes.entries or 0,
                    localSessionHook = true, processWideHook = false,
                })
            end
        elseif not same_object(listener, ui.native_listener) then
            return
        end

        local input_number = tonumber(unwrap(Input))
        local route = input_number ~= nil and ui.native_route_by_enum[input_number] or nil
        local action_name = input_number ~= nil and ui.native_action_name_by_enum[input_number] or nil
        local gamepad_mode = native_controller_is_gamepad()
        local accepted, native_state = dd.listener_native_acceptance(listener, input_number)

        log("native input event enum=" .. native_input_value(Input))
        diag("input.raw", {
            enum = input_number ~= nil and input_number or native_input_value(Input),
            route = route or "<none>",
            action = action_name or "<unknown>",
            gamepadMode = gamepad_mode,
            nativeAccepted = accepted,
            nativeEnabled = native_state.enabled,
            inAcceptedInputs = native_state.accepted,
            secondaryBlocked = native_state.secondaryBlocked,
            tertiaryBlocked = native_state.tertiaryBlocked,
            error = native_state.error,
            generation = generation,
        })

        if route ~= nil and not accepted then
            diag("input.raw.blocked", {
                enum = input_number,
                route = route,
                action = action_name,
                reason = native_state.error ~= "" and native_state.error or "native-listener-policy",
            })
            return
        end

        if generation ~= ui.active_generation or not ui.open or ui.closing then
            diag("input.raw.blocked", {
                enum = input_number,
                route = route,
                reason = "session-generation-changed",
                expectedGeneration = generation,
                activeGeneration = ui.active_generation,
            })
            return
        end

        if route ~= nil and route:find("mouse_", 1, true) == 1 then
            local local_pointer_sample = dd.record_local_pointer_snapshot(generation, input_number, route)
            local capture_active = dd.bind_capture_active ~= nil and dd.bind_capture_active()
            local delegate_pointer = local_pointer_sample ~= nil
                and not capture_active
                and dd.host_native_pointer_semantics_active(generation)
            if delegate_pointer then
                local_pointer_sample.delegated = true
                diag("input.raw.pointerSemantic", {
                    status = "delegated-to-host",
                    enum = input_number,
                    route = route,
                    action = action_name,
                    generation = generation,
                    pointerSource = local_pointer_sample.source,
                })
            else
                diag("input.raw.pointerSemantic", {
                    status = capture_active and "local-bind-capture"
                        or (dd.host_native_semantics_active(generation) and "local-bootstrap" or "local-fallback"),
                    enum = input_number,
                    route = route,
                    action = action_name,
                    generation = generation,
                    pointerSource = local_pointer_sample ~= nil and local_pointer_sample.source or "<unavailable>",
                })
                dd.dispatch_native_pointer_route(
                    route,
                    "enum=" .. tostring(input_number),
                    local_pointer_sample ~= nil and local_pointer_sample.pointer or nil
                )
            end
        elseif route ~= nil then
            if dd.host_native_semantics_active(generation) then
                diag("input.raw.semantic", {
                    status = "delegated-to-host",
                    enum = input_number,
                    route = route,
                    action = action_name,
                    generation = generation,
                })
            else
                diag("input.raw.semantic", {
                    status = "local-fallback",
                    enum = input_number,
                    route = route,
                    action = action_name,
                    generation = generation,
                })
                dispatch_native_controller_route(route, "enum=" .. tostring(input_number))
            end
        end
    end

    local handler_slot = dd.ModUI.Runtime.InputBridge.InstallStableHandler(
        native_runtime,
        "native_input_enum_handler",
        "native_input_enum_callback",
        semantic_handler,
        function() return _G.MortalShell2TTSRuntime end
    )
    handler_slot = type(handler_slot) == "table" and handler_slot
        or { ok = false, status = "invalid-result", handler = nil, callback = nil, handlerInstalled = false }

    if handler_slot.status == "created" or runtime_diagnostics.Session() <= 1 or not handler_slot.ok then
        diag("input.trampoline", {
            status = handler_slot.status,
            sharedRuntime = true,
            sharedHost = true,
            sharedTrampoline = true,
            sharedHandlerSlot = true,
            handlerInstalled = handler_slot.handlerInstalled == true,
            handlerType = type(handler_slot.handler),
            callbackType = type(handler_slot.callback),
        })
    end

    return native_runtime, handler_slot.callback
end

-- Pass 123 extends the proven Pass-119 non-pointer semantic transfer to pointer routes.
-- Pointer hit testing still belongs to MortalShell2TTS, but it now consumes the exact
-- callback-time host snapshot rather than re-reading cursor state on the later consumer poll.
-- The first current-process pointer event remains local while snapshot agreement bootstraps;
-- a later missing/mismatched host tuple falls back to the paired local callback-time snapshot.
function dd.dispatch_modui_host_native_input_event(event, source)
    event = type(event) == "table" and event or {}
    source = tostring(source or "ModUIHost:WBP_InputListener")
    local generation = tonumber(event.generation) or 0
    local active_generation = tonumber(ui.active_generation) or 0
    if not ui.open or ui.closing or generation <= 0 or generation ~= active_generation then
        return false, "session-inactive-or-stale"
    end
    if not dd.host_native_semantics_active(generation) then
        return false, "host-request-inactive"
    end

    local listener = unwrap(ui.native_listener)
    local host_primary = ui.native_host_listener_primary == true
    if (ui.host_visible_shell ~= true and not valid(ui.widget)) or (not host_primary and not valid(listener)) then
        return false, "listener-or-shell-invalid"
    end

    local input_number = tonumber(event.input)
    if input_number == nil then return false, "input-invalid" end
    local event_route = tostring(event.route or "")
    local route = event_route ~= "" and event_route or ui.native_route_by_enum[input_number]
    local action_name = ui.native_action_name_by_enum[input_number]
    if route == nil or route == "" then return false, "route-unmapped" end
    if route:find("mouse_", 1, true) == 1 then
        if dd.bind_capture_active ~= nil and dd.bind_capture_active() then
            return false, "bind-capture"
        end
        if host_primary then
            local host_pointer = dd.host_pointer_from_event(event)
            if host_pointer == nil then
                diag("input.hostPointerSemantic", {
                    status = "host-owned-pointer-missing", route = route, input = input_number,
                    source = source, generation = generation,
                })
                return false, "host-owned-pointer-missing"
            end
            dd.dispatch_native_pointer_route(route, source .. ":host-owned:enum=" .. tostring(input_number), host_pointer)
            diag("input.hostPointerSemantic", {
                status = "dispatched-host-owned", route = route, input = input_number, source = source,
                pointerSource = host_pointer.source, referenceX = host_pointer.reference_x,
                referenceY = host_pointer.reference_y, generation = generation,
            })
            return true, "pointer-host-owned:" .. route
        end
        local host_pointer, local_sample, pointer_status = dd.observe_host_pointer_snapshot(event, source, route)
        if local_sample == nil or local_sample.delegated ~= true then
            return false, "pointer-bootstrap-local"
        end
        if host_pointer ~= nil then
            dd.dispatch_native_pointer_route(route, source .. ":enum=" .. tostring(input_number), host_pointer)
            diag("input.hostPointerSemantic", {
                status = "dispatched",
                route = route,
                input = input_number,
                source = source,
                pointerSource = host_pointer.source,
                referenceX = host_pointer.reference_x,
                referenceY = host_pointer.reference_y,
                generation = generation,
            })
            return true, "pointer:" .. route
        end
        if type(local_sample.pointer) == "table" then
            dd.dispatch_native_pointer_route(
                route,
                source .. ":local-snapshot-fallback:enum=" .. tostring(input_number),
                local_sample.pointer
            )
            diag("input.hostPointerSemantic", {
                status = "local-snapshot-fallback",
                route = route,
                input = input_number,
                source = source,
                pointerStatus = pointer_status,
                pointerSource = local_sample.source,
                referenceX = local_sample.referenceX,
                referenceY = local_sample.referenceY,
                generation = generation,
            })
            return true, "pointer-local-snapshot-fallback:" .. route
        end
        return false, "pointer-unpaired"
    end

    local accepted, native_state
    if host_primary then
        accepted = true
        native_state = { error = "", enabled = true, accepted = true }
    else
        accepted, native_state = dd.listener_native_acceptance(listener, input_number)
    end
    if not accepted then
        diag("input.hostNativeSemantic", {
            status = "blocked",
            enum = input_number,
            route = route,
            action = action_name or "<unknown>",
            source = source,
            generation = generation,
            reason = native_state.error ~= "" and native_state.error or "native-listener-policy",
        })
        return false, "native-listener-policy"
    end

    if dd.bind_capture_active ~= nil and dd.bind_capture_active() then
        return false, "bind-capture"
    end
    if not native_controller_is_gamepad() then
        return false, "not-gamepad"
    end

    dispatch_native_controller_route(route, source .. ":enum=" .. tostring(input_number))
    return true, route
end

function dd.native_input_bridge_host_options(reason, on_stage)
    local runtime, callback = dd.ensure_native_input_hook_runtime()
    -- Pass 139: when standalone ModUI's process-lifetime native input mirror is
    -- ready, the consumer-owned listener is observed through that exact-address
    -- mailbox and MUST NOT dynamically RegisterHook/UnregisterHook the same
    -- InputTriggeredCallback UFunction a second time. Keep the historical local
    -- hook only as a compatibility fallback if the host mirror never became ready.
    -- Pass 151 rollback: Pass 150 re-enabled the process-lifetime ModUI callback mirror and the
    -- historical CBADB8CF transition crash immediately returned after LoadMap -> fresh Settings.
    -- Force the Pass-149-proven topology: exactly one TTS-local hook for this Settings session.
    -- Do not allow stale/shared readiness to switch this bridge back to external hosting.
    local external_hook = false
    return {
        minimumInput = 0,
        maximumInput = 32,
        hookExternallyHosted = external_hook,
        hookRuntime = runtime,
        hookPath = dd.NativeInputTriggerFunction,
        hookCallback = callback,
        registerHook = RegisterHook,
        unregisterHook = UnregisterHook,
        hookFields = dd.NativeInputHookFields,
        reason = tostring(reason or "settings input bridge"),
        onStage = on_stage,
    }
end

function dd.deactivate_native_input_host(listener, handler, reason, mode, completion_barrier, completion_authorization)
    listener = unwrap(listener)
    handler = unwrap(handler)
    reason = tostring(reason or "settings input bridge disabled")
    mode = tostring(mode or "disable")

    local activation = type(ui.native_bridge_activation) == "table" and ui.native_bridge_activation or nil

    if type(dd.write_modui_host_native_input_request) == "function" then
        pcall(dd.write_modui_host_native_input_request, false, listener, ui.active_generation)
    end

    local lease = type(ui.native_bridge_lease) == "table" and ui.native_bridge_lease or nil
    local session = type(ui.native_bridge_session) == "table" and ui.native_bridge_session or nil
    local shared_input_bridge_session = session ~= nil and session.sharedInputBridgeSession == true
    local shared_lease_hook_spec = lease ~= nil and lease.hookSpecOwned == true

    local function deactivation_stage(stage, payload)
        if stage == "before-disable" then
            if valid(listener) then
                dd.log_listener_input_handles(listener, mode == "cleanup" and "failure-before-cleanup" or "before-disable")
                dd.log_handler_active_listeners(handler, listener, mode == "cleanup" and "failure-before-cleanup" or "before-disable")
                if mode ~= "cleanup" then
                    dd.log_listener_delegate_bindings(listener, "before-disable")
                end
            end
        elseif stage == "bindings-disabled" then
            payload = type(payload) == "table" and payload or {}
            if not payload.ok then
                log("native input bridge disable warning SetEnabledState="
                    .. tostring(payload.setEnabledStateOk and "ok" or payload.setEnabledStateError)
                    .. " UnbindInputs="
                    .. tostring(payload.unbindInputsOk and "ok" or payload.unbindInputsError))
            elseif mode ~= "cleanup" then
                log("native input bridge bindings released listener-local only")
            end
            diag(mode == "cleanup" and "input.cleanup.native" or "input.disable.native", {
                reason = mode == "cleanup" and reason or nil,
                SetEnabledState = payload.setEnabledStateOk and "ok" or tostring(payload.setEnabledStateError),
                UnbindInputs = payload.unbindInputsOk and "ok" or tostring(payload.unbindInputsError),
                sharedRuntime = true,
                sharedHost = true,
                sharedConstruction = true,
                sharedLeaseHookSpec = shared_lease_hook_spec,
                sharedLeaseRouter = true,
                sharedLeaseTeardownOptions = payload.sharedLeaseTeardownOptions == true,
                teardownOptionRoute = payload.teardownOptionRoute,
                sharedLeaseTeardownActivation = payload.sharedLeaseTeardownActivation == true,
                teardownActivationRoute = payload.teardownActivationRoute,
                sharedTeardownTicket = payload.sharedTeardownTicket == true,
                sharedTeardownTransaction = payload.sharedTeardownTransaction == true,
                sharedTeardownPlan = payload.sharedTeardownPlan == true,
                sharedInputBridgeSession = payload.sharedInputBridgeSession == true or shared_input_bridge_session,
            })
            if valid(listener) then
                dd.log_listener_input_handles(listener, mode == "cleanup" and "failure-after-unbind" or "after-disable-unbind")
                dd.log_handler_active_listeners(handler, listener, mode == "cleanup" and "failure-after-unbind" or "after-disable-unbind")
            end
        elseif stage == "accepted-restored" then
            local accepted = type(activation.accepted) == "table" and activation.accepted or {}
            dd.InputBridgeDiagnostics.AcceptedRestore(payload, accepted.original, { sharedHost = true })
        elseif stage == "hook-retired" then
            dd.InputBridgeDiagnostics.HookRetire(payload, reason)
        end
    end

    -- Pass 66: the shared host now also decides whether the lease-owned activation
    -- transaction is sufficient or whether a legacy/incomplete path needs the old
    -- AcceptedInputs ownership fallback. Both compatibility factories stay lazy,
    -- so the normal proven lease path reconstructs neither activation nor hook state.
    local host_options = {
        reason = reason,
        onStage = deactivation_stage,
        legacyActivationFactory = function()
            return {
                accepted = { original = ui.native_original_accepted_inputs },
                ownedAcceptedInputs = ui.native_accepted_inputs_changed == true,
            }
        end,
        legacyOptionsFactory = function()
            return dd.native_input_bridge_host_options(reason, deactivation_stage)
        end,
    }

    local begin_result
    if shared_input_bridge_session then
        begin_result = dd.ModUI.Runtime.InputBridge.BeginSessionTeardown(
            session, host_options, completion_barrier, completion_authorization
        )
    else
        begin_result = dd.ModUI.Runtime.InputBridge.BeginTeardownPlan(
            lease, listener, activation, host_options, completion_barrier, completion_authorization
        )
    end
    begin_result = type(begin_result) == "table" and begin_result or { ok = false, status = "invalid-result" }
    local result = type(begin_result.deactivation) == "table" and begin_result.deactivation
        or { ok = false, status = begin_result.status or "invalid-result" }
    result.sharedTeardownTicket = begin_result.sharedTeardownTicket == true
    result.sharedTeardownTransaction = begin_result.sharedTeardownTransaction == true
    result.sharedTeardownPlan = begin_result.sharedTeardownPlan == true
    result.sharedInputBridgeSession = begin_result.sharedInputBridgeSession == true or shared_input_bridge_session

    ui.native_listener_enabled = false
    ui.native_original_accepted_inputs = nil
    ui.native_accepted_inputs_changed = false
    ui.native_verified_accepted_inputs = {}
    ui.native_bridge_activation = nil
    if type(result.hook) ~= "table" or result.hook.ok ~= true then
        -- Preserve Runtime.Hook's fail-safe registration marker; only the local
        -- readiness mirror is cleared when retirement was actually successful.
        if type(result.hook) == "table" and result.hook.status == "not-registered" then
            ui.native_input_hooks_ready = false
        end
    end
    return result, begin_result.plan, session
end

function dd.reset_native_input_bridge_state()
    ui.native_listener = nil
    ui.native_host_listener_primary = false
    ui.native_host_listener_address = ""
    ui.native_host_listener_fallback_scheduled = false
    ui.native_input_bridge = nil
    ui.native_bridge_lease = nil
    ui.native_bridge_session = nil
    ui.native_listener_enabled = false
    ui.native_original_accepted_inputs = nil
    ui.native_accepted_inputs_changed = false
    ui.native_bridge_activation = nil
    ui.native_bridge_external_hook = false
    ui.native_last_source = ""
    ui.native_route_by_enum = {}
    ui.native_route_by_action = {}
    ui.native_action_name_by_enum = {}
    ui.native_verified_accepted_inputs = {}
    ui.native_gamepad_probe_warned = false
end


    return true
end

return M
