-- MortalShell2ModUI Runtime.InputBridge
-- Cohesive generic WBP_InputListener construction + activation host.
-- Consumers retain listener-class selection, exactly when open/close occurs,
-- callback semantics/dispatch, diagnostics, world/shell ownership, modal
-- isolation, and close quarantine. This module owns the reusable ordered
-- Create -> attach -> handler -> route -> AcceptedInputs -> hook -> binding
-- transaction, failure cleanup, reverse input teardown, bounded retirement,
-- a reusable lease that keeps listener/activation teardown state together,
-- stable trampoline identity, the generic replaceable-handler slot, and the
-- exact hook-retirement specification paired with that lease, support for an
-- externally-hosted process-lifetime callback hook, plus generic lease-vs-legacy
-- lifecycle routing plus lease-aware lazy teardown-option and
-- teardown-activation fallback resolution, and a shared open-to-teardown session while consumer dispatch semantics and teardown timing remain consumer-owned.

local InputBridge = {}

function InputBridge.Bind(Bridge, Listener, Hook)
    if type(Bridge) ~= "table"
        or type(Bridge.CreateListener) ~= "function"
        or type(Bridge.AttachViewport) ~= "function"
        or type(Bridge.EnsureHandler) ~= "function"
        or type(Bridge.RemoveListener) ~= "function" then
        error("Runtime.InputBridge requires Runtime.Bridge", 0)
    end
    if type(Listener) ~= "table"
        or type(Listener.BuildRoutes) ~= "function"
        or type(Listener.ConfigureAcceptedInputs) ~= "function"
        or type(Listener.RestoreAcceptedInputs) ~= "function"
        or type(Listener.EnableBindings) ~= "function"
        or type(Listener.DisableBindings) ~= "function" then
        error("Runtime.InputBridge requires Runtime.Listener", 0)
    end
    if type(Hook) ~= "table"
        or type(Hook.Register) ~= "function"
        or type(Hook.Unregister) ~= "function" then
        error("Runtime.InputBridge requires Runtime.Hook", 0)
    end

    local Bound = {}

    -- Pass 61: keep the stable UE4SS hook callback identity inside the shared
    -- bridge host while leaving the consumer's actual input semantics in its
    -- replaceable handler field. A resolver may be supplied so an already-created
    -- trampoline follows the consumer's authoritative runtime table exactly as the
    -- historical MortalShell2TTS global trampoline did.
    function Bound.EnsureStableTrampoline(runtime, handler_field, callback_field, runtime_resolver)
        if type(runtime) ~= "table"
            or type(handler_field) ~= "string" or handler_field == ""
            or type(callback_field) ~= "string" or callback_field == "" then
            return { ok = false, status = "invalid-arguments", runtime = runtime, callback = nil }
        end

        local existing = runtime[callback_field]
        if existing then
            return {
                ok = type(existing) == "function",
                status = type(existing) == "function" and "existing" or "existing-nonfunction",
                runtime = runtime,
                callback = existing,
            }
        end

        local callback = function(...)
            local current = runtime
            if type(runtime_resolver) == "function" then
                current = runtime_resolver()
            end
            if type(current) == "table" and type(current[handler_field]) == "function" then
                return current[handler_field](...)
            end
        end
        runtime[callback_field] = callback
        return { ok = true, status = "created", runtime = runtime, callback = callback }
    end

    -- Pass 62: install the consumer-supplied semantic handler into the generic
    -- replaceable slot while preserving Pass 61's stable trampoline identity. The
    -- shared host owns only the slot mechanics; the handler function body and all
    -- semantic dispatch remain consumer-owned. Status mirrors EnsureStableTrampoline
    -- so existing diagnostics retain their created/existing meaning.
    function Bound.InstallStableHandler(runtime, handler_field, callback_field, handler, runtime_resolver)
        if type(runtime) ~= "table"
            or type(handler_field) ~= "string" or handler_field == ""
            or type(callback_field) ~= "string" or callback_field == ""
            or type(handler) ~= "function" then
            return {
                ok = false,
                status = "invalid-arguments",
                runtime = runtime,
                handler = nil,
                callback = nil,
                handlerInstalled = false,
            }
        end

        runtime[handler_field] = handler
        local trampoline = Bound.EnsureStableTrampoline(
            runtime, handler_field, callback_field, runtime_resolver
        )
        trampoline = type(trampoline) == "table" and trampoline
            or { ok = false, status = "invalid-result", runtime = runtime, callback = nil }

        return {
            ok = trampoline.ok == true and type(trampoline.callback) == "function",
            status = tostring(trampoline.status or "invalid-result"),
            runtime = runtime,
            handler = runtime[handler_field],
            callback = trampoline.callback,
            handlerInstalled = runtime[handler_field] == handler,
        }
    end

    local function emit(options, stage, payload)
        local callback = type(options) == "table" and options.onStage or nil
        if type(callback) ~= "function" then return nil end
        local ok, err = pcall(callback, stage, payload)
        return ok and nil or tostring(err)
    end

    local function emit_cleanup(options, stage, payload)
        local callback = type(options) == "table" and options.onCleanupStage or nil
        if type(callback) ~= "function" then return nil end
        local ok, err = pcall(callback, stage, payload)
        return ok and nil or tostring(err)
    end

    local function hook_options(options)
        options = type(options) == "table" and options or {}
        return options.hookRuntime, options.hookPath, options.hookCallback,
            options.registerHook, options.unregisterHook, options.hookFields
    end

    -- Pass 139: a consumer listener may be observed by a single process-lifetime
    -- hook owned elsewhere (for example Host.InputService's exact-address native
    -- input mirror). In that topology Runtime.InputBridge still owns listener
    -- creation, AcceptedInputs and binding enable/disable, but it must not create
    -- or retire a second RegisterHook transaction on the same UFunction.
    local function hook_externally_hosted(options)
        return type(options) == "table" and options.hookExternallyHosted == true
    end

    -- Pass 63: once Open succeeds, retain the exact hook transaction identity on
    -- the lease so normal DeactivateLease cannot accidentally reconstruct a
    -- different runtime/path/unregister/field tuple at close time. The consumer
    -- still decides when deactivation occurs and supplies diagnostics callbacks.
    local function capture_hook_spec(options)
        local runtime, path, callback, register_hook, unregister_hook, fields = hook_options(options)
        local captured_fields = fields
        if type(fields) == "table" then
            captured_fields = {}
            for key, value in pairs(fields) do captured_fields[key] = value end
        end
        local external = hook_externally_hosted(options)
        return {
            valid = external or (type(runtime) == "table" and type(path) == "string" and path ~= ""
                and type(register_hook) == "function" and type(unregister_hook) == "function"),
            hookExternallyHosted = external,
            hookRuntime = runtime,
            hookPath = path,
            hookCallback = callback,
            registerHook = register_hook,
            unregisterHook = unregister_hook,
            hookFields = captured_fields,
        }
    end

    local function lease_deactivate_options(lease, options)
        local effective = {}
        for key, value in pairs(type(options) == "table" and options or {}) do
            effective[key] = value
        end

        local spec = type(lease) == "table" and lease.hookSpec or nil
        if type(spec) == "table" and spec.valid == true then
            -- Use the exact retirement half of the registration transaction that
            -- produced this lease. This intentionally overrides any reconstructed
            -- hook fields supplied by the consumer on normal close.
            effective.hookExternallyHosted = spec.hookExternallyHosted == true
            effective.hookRuntime = spec.hookRuntime
            effective.hookPath = spec.hookPath
            effective.unregisterHook = spec.unregisterHook
            effective.hookFields = spec.hookFields
            return effective, true
        end
        return effective, false
    end

    function Bound.Activate(listener, options)
        options = type(options) == "table" and options or {}
        local runtime, path, callback, register_hook, _, fields = hook_options(options)
        local result = {
            ok = false,
            status = "invalid-arguments",
            routes = nil,
            accepted = nil,
            hook = nil,
            bindings = nil,
            ownedAcceptedInputs = false,
            stageObserverErrors = {},
        }

        local external_hook = hook_externally_hosted(options)
        if listener == nil then return result end
        if not external_hook and (type(runtime) ~= "table" or type(path) ~= "string" or path == ""
            or type(callback) ~= "function" or type(register_hook) ~= "function") then
            return result
        end

        local observer_error = emit(options, "before-routes", { listener = listener })
        if observer_error ~= nil then result.stageObserverErrors.beforeRoutes = observer_error end

        local routes = Listener.BuildRoutes(
            listener,
            options.minimumInput == nil and 0 or options.minimumInput,
            options.maximumInput == nil and 32 or options.maximumInput
        )
        routes = type(routes) == "table" and routes or { status = "invalid-result", accepted = {} }
        result.routes = routes
        observer_error = emit(options, "routes", routes)
        if observer_error ~= nil then result.stageObserverErrors.routes = observer_error end

        local desired = type(routes.accepted) == "table" and routes.accepted or {}
        if #desired == 0 then
            result.status = routes.status == "listener-invalid" and "listener-invalid"
                or routes.status == "interface-map-unavailable" and "routes-unavailable"
                or "routes-empty"
            return result
        end

        observer_error = emit(options, "before-accepted", { listener = listener, desired = desired })
        if observer_error ~= nil then result.stageObserverErrors.beforeAccepted = observer_error end

        local accepted = Listener.ConfigureAcceptedInputs(listener, desired)
        accepted = type(accepted) == "table" and accepted or { ok = false, status = "invalid-result" }
        result.accepted = accepted
        local rollback_complete = type(accepted.restore) == "table" and accepted.restore.ok == true
        result.ownedAcceptedInputs = accepted.changed == true
            and (accepted.ok == true or not rollback_complete)
        accepted.ownedByHost = result.ownedAcceptedInputs
        observer_error = emit(options, "accepted", accepted)
        if observer_error ~= nil then result.stageObserverErrors.accepted = observer_error end
        if not accepted.ok then
            result.status = "accepted-" .. tostring(accepted.status or "failed")
            return result
        end

        observer_error = emit(options, "before-hook", { listener = listener })
        if observer_error ~= nil then result.stageObserverErrors.beforeHook = observer_error end

        local hook_result
        if external_hook then
            hook_result = {
                ok = true, status = "externally-hosted", externallyHosted = true,
                alreadyRegistered = true, pre = nil, post = nil, cycle = 0,
            }
        else
            hook_result = Hook.Register(runtime, path, callback, register_hook, fields)
        end
        hook_result = type(hook_result) == "table" and hook_result or { ok = false, status = "invalid-result" }
        result.hook = hook_result
        observer_error = emit(options, "hook", hook_result)
        if observer_error ~= nil then result.stageObserverErrors.hook = observer_error end
        if not hook_result.ok then
            result.status = "hook-" .. tostring(hook_result.status or "failed")
            return result
        end

        observer_error = emit(options, "before-bindings", { listener = listener })
        if observer_error ~= nil then result.stageObserverErrors.beforeBindings = observer_error end

        local bindings = Listener.EnableBindings(listener)
        bindings = type(bindings) == "table" and bindings or { ok = false, status = "invalid-result" }
        result.bindings = bindings
        observer_error = emit(options, "bindings", bindings)
        if observer_error ~= nil then result.stageObserverErrors.bindings = observer_error end
        if not bindings.ok then
            result.status = "bindings-" .. tostring(bindings.status or "failed")
            return result
        end

        result.ok = true
        result.status = "active"
        return result
    end

    function Bound.Deactivate(listener, activation, options)
        activation = type(activation) == "table" and activation or {}
        options = type(options) == "table" and options or {}
        local runtime, path, _, _, unregister_hook, fields = hook_options(options)
        local external_hook = hook_externally_hosted(options)
        local result = {
            ok = true,
            status = "complete",
            bindings = nil,
            accepted = nil,
            hook = nil,
            stageObserverErrors = {},
        }

        local observer_error = emit(options, "before-disable", { listener = listener })
        if observer_error ~= nil then result.stageObserverErrors.beforeDisable = observer_error end

        local bindings = Listener.DisableBindings(listener)
        bindings = type(bindings) == "table" and bindings or { ok = false, status = "invalid-result" }
        result.bindings = bindings
        if not bindings.ok then result.ok = false end
        observer_error = emit(options, "bindings-disabled", bindings)
        if observer_error ~= nil then result.stageObserverErrors.bindingsDisabled = observer_error end

        local accepted_activation = type(activation.accepted) == "table" and activation.accepted or {}
        local accepted = Listener.RestoreAcceptedInputs(
            listener,
            accepted_activation.original,
            activation.ownedAcceptedInputs == true
        )
        accepted = type(accepted) == "table" and accepted or { ok = false, status = "invalid-result" }
        result.accepted = accepted
        if not accepted.ok then result.ok = false end
        observer_error = emit(options, "accepted-restored", accepted)
        if observer_error ~= nil then result.stageObserverErrors.acceptedRestored = observer_error end

        local hook_result
        if external_hook then
            hook_result = {
                ok = true, status = "externally-hosted", externallyHosted = true,
                wasRegistered = false, pre = nil, post = nil, cycle = 0,
            }
        elseif type(runtime) == "table" and type(path) == "string" and path ~= "" and type(unregister_hook) == "function" then
            hook_result = Hook.Unregister(runtime, path, unregister_hook, fields)
        else
            hook_result = { ok = false, status = "invalid-arguments" }
        end
        hook_result = type(hook_result) == "table" and hook_result or { ok = false, status = "invalid-result" }
        result.hook = hook_result
        if not hook_result.ok then result.ok = false end
        observer_error = emit(options, "hook-retired", hook_result)
        if observer_error ~= nil then result.stageObserverErrors.hookRetired = observer_error end

        result.status = result.ok and "complete" or "partial-failure"
        return result
    end

    local function cleanup_open_failure(listener, activation, options, reason)
        local cleanup = {
            reason = tostring(reason or "open-failed"),
            deactivate = nil,
            remove = nil,
            stageObserverErrors = {},
        }
        local observer_error = emit_cleanup(options, "cleanup-begin", {
            listener = listener,
            activation = activation,
            reason = cleanup.reason,
        })
        if observer_error ~= nil then cleanup.stageObserverErrors.cleanupBegin = observer_error end

        local cleanup_options = {}
        for key, value in pairs(type(options) == "table" and options or {}) do cleanup_options[key] = value end
        cleanup_options.onStage = type(options) == "table" and options.onCleanupStage or nil
        cleanup.deactivate = Bound.Deactivate(listener, activation or {}, cleanup_options)

        cleanup.remove = Bridge.RemoveListener(listener)
        cleanup.remove = type(cleanup.remove) == "table" and cleanup.remove or { ok = false, status = "invalid-result" }
        observer_error = emit_cleanup(options, "cleanup-remove", cleanup.remove)
        if observer_error ~= nil then cleanup.stageObserverErrors.cleanupRemove = observer_error end

        observer_error = emit_cleanup(options, "cleanup-end", cleanup)
        if observer_error ~= nil then cleanup.stageObserverErrors.cleanupEnd = observer_error end
        return cleanup
    end

    function Bound.Open(player, controller, library, listener_class, handler, options)
        options = type(options) == "table" and options or {}
        local result = {
            ok = false,
            status = "invalid-prerequisite",
            listener = nil,
            create = nil,
            attach = nil,
            handler = nil,
            activation = nil,
            cleanup = nil,
            stageObserverErrors = {},
        }

        local observer_error = emit(options, "before-create", {
            player = player,
            controller = controller,
            library = library,
            listenerClass = listener_class,
            handler = handler,
        })
        if observer_error ~= nil then result.stageObserverErrors.beforeCreate = observer_error end

        local create_result = Bridge.CreateListener(player, controller, library, listener_class)
        create_result = type(create_result) == "table" and create_result or { ok = false, status = "invalid-result" }
        result.create = create_result
        result.listener = create_result.listener
        observer_error = emit(options, "created", create_result)
        if observer_error ~= nil then result.stageObserverErrors.created = observer_error end
        if not create_result.ok then
            result.status = "create-" .. tostring(create_result.status or "failed")
            return result
        end

        local listener = create_result.listener
        observer_error = emit(options, "before-attach", { listener = listener })
        if observer_error ~= nil then result.stageObserverErrors.beforeAttach = observer_error end

        local attach_result = Bridge.AttachViewport(listener, options.zOrder)
        attach_result = type(attach_result) == "table" and attach_result or { ok = false, status = "invalid-result" }
        result.attach = attach_result
        observer_error = emit(options, "attached", attach_result)
        if observer_error ~= nil then result.stageObserverErrors.attached = observer_error end
        if not attach_result.ok then
            result.status = "attach-" .. tostring(attach_result.status or "failed")
            result.cleanup = cleanup_open_failure(listener, {}, options, result.status)
            return result
        end

        observer_error = emit(options, "before-handler", { listener = listener, handler = handler })
        if observer_error ~= nil then result.stageObserverErrors.beforeHandler = observer_error end

        local handler_result = Bridge.EnsureHandler(listener, handler)
        handler_result = type(handler_result) == "table" and handler_result or { ok = false, status = "invalid-result" }
        result.handler = handler_result
        observer_error = emit(options, "handler", handler_result)
        if observer_error ~= nil then result.stageObserverErrors.handler = observer_error end
        if not handler_result.ok then
            result.status = "handler-" .. tostring(handler_result.status or "failed")
            result.cleanup = cleanup_open_failure(listener, {}, options, result.status)
            return result
        end

        observer_error = emit(options, "before-activate", { listener = listener })
        if observer_error ~= nil then result.stageObserverErrors.beforeActivate = observer_error end

        local activation = Bound.Activate(listener, options)
        activation = type(activation) == "table" and activation or { ok = false, status = "invalid-result" }
        result.activation = activation
        observer_error = emit(options, "activated", activation)
        if observer_error ~= nil then result.stageObserverErrors.activated = observer_error end
        if not activation.ok then
            result.status = "activation-" .. tostring(activation.status or "failed")
            result.cleanup = cleanup_open_failure(listener, activation, options, result.status)
            return result
        end

        local hook_spec = capture_hook_spec(options)
        result.leaseHookSpecOwned = hook_spec.valid == true
        result.lease = {
            listener = listener,
            activation = activation,
            hookSpec = hook_spec,
            hookSpecOwned = hook_spec.valid == true,
            state = "active",
            deactivationAttempted = false,
            deactivation = nil,
            retirement = nil,
        }
        result.ok = true
        result.status = "active"
        return result
    end

    function Bound.DeactivateLease(lease, options)
        if type(lease) ~= "table" or lease.listener == nil then
            return { ok = false, status = "invalid-lease" }
        end
        if lease.state == "retired" then
            return { ok = false, status = "already-retired" }
        end
        if lease.state == "deactivated" and type(lease.deactivation) == "table" then
            return {
                ok = lease.deactivation.ok == true,
                status = "already-deactivated",
                bindings = lease.deactivation.bindings,
                accepted = lease.deactivation.accepted,
                hook = lease.deactivation.hook,
                sharedLeaseHookSpec = lease.hookSpecOwned == true,
                previous = lease.deactivation,
            }
        end

        lease.deactivationAttempted = true
        local effective_options, shared_hook_spec = lease_deactivate_options(lease, options)
        local result = Bound.Deactivate(lease.listener, lease.activation or {}, effective_options)
        result = type(result) == "table" and result or { ok = false, status = "invalid-result" }
        result.sharedLeaseHookSpec = shared_hook_spec
        lease.deactivation = result
        lease.state = result.ok and "deactivated" or "deactivate-partial"
        return result
    end

    local function copy_options(options, skip_legacy_factories)
        local copied = {}
        for key, value in pairs(type(options) == "table" and options or {}) do
            local is_factory = key == "legacyOptionsFactory" or key == "legacyActivationFactory"
            if not (skip_legacy_factories and is_factory) then
                copied[key] = value
            end
        end
        return copied
    end

    local function merge_options(base, override)
        local merged = copy_options(base, true)
        for key, value in pairs(type(override) == "table" and override or {}) do
            if key ~= "legacyOptionsFactory" and key ~= "legacyActivationFactory" then
                merged[key] = value
            end
        end
        return merged
    end

    -- Pass 66: mirror Pass 65's lazy teardown-option ownership for the legacy
    -- activation fallback. A healthy shared lease already owns the activation
    -- transaction that must be unwound, so normal close no longer reconstructs
    -- AcceptedInputs ownership state in the consumer merely to discard it.
    -- Preserve Pass 65's exact lifecycle predicate: any non-nil lease routes
    -- through DeactivateLease, including malformed lease values that are then
    -- bounded by DeactivateLease itself.
    function Bound.ResolveDeactivateActivation(lease, activation, options)
        options = type(options) == "table" and options or {}
        if lease ~= nil then
            return {
                ok = true,
                status = "lease-owned",
                activation = activation,
                sharedLeaseTeardownActivation = true,
                teardownActivationRoute = "lease-owned",
                legacyActivationFactoryCalled = false,
            }
        end

        if type(activation) == "table" then
            return {
                ok = true,
                status = "provided",
                activation = activation,
                sharedLeaseTeardownActivation = true,
                teardownActivationRoute = "provided",
                legacyActivationFactoryCalled = false,
            }
        end

        local factory = options.legacyActivationFactory
        if type(factory) ~= "function" then
            return {
                ok = true,
                status = "empty",
                activation = activation,
                sharedLeaseTeardownActivation = true,
                teardownActivationRoute = "empty",
                legacyActivationFactoryCalled = false,
            }
        end

        -- As with Pass 65's option factory, errors propagate. The MortalShell2TTS
        -- compatibility factory is deterministic; propagating retains the former
        -- consumer-side behavior instead of silently changing a failure mode.
        local fallback = factory()
        if type(fallback) ~= "table" then
            return {
                ok = false,
                status = "legacy-activation-invalid",
                activation = activation,
                sharedLeaseTeardownActivation = true,
                teardownActivationRoute = "legacy-fallback-failed",
                legacyActivationFactoryCalled = true,
            }
        end

        return {
            ok = true,
            status = "legacy-fallback",
            activation = fallback,
            sharedLeaseTeardownActivation = true,
            teardownActivationRoute = "legacy-fallback",
            legacyActivationFactoryCalled = true,
        }
    end

    -- Pass 65: decide inside the shared host whether teardown can rely entirely
    -- on the lease-owned hook specification or needs the consumer's legacy hook
    -- options. The fallback factory is lazy: a healthy lease never reconstructs
    -- or reinstalls hook runtime/callback state merely to close.
    function Bound.ResolveDeactivateOptions(lease, options)
        options = type(options) == "table" and options or {}
        local base = copy_options(options, true)
        -- Preserve the exact Pass-64 consumer branch predicate. A lease that
        -- explicitly claims hookSpecOwned=true stays on the lease-owned option
        -- path even if its internals are later malformed; DeactivateLease retains
        -- the established fail-soft behavior for that state.
        if type(lease) == "table" and lease.hookSpecOwned == true then
            return {
                ok = true,
                status = "lease-owned",
                options = base,
                sharedLeaseTeardownOptions = true,
                teardownOptionRoute = "lease-owned",
                legacyOptionsFactoryCalled = false,
            }
        end

        local factory = options.legacyOptionsFactory
        if type(factory) ~= "function" then
            return {
                ok = true,
                status = "provided",
                options = base,
                sharedLeaseTeardownOptions = true,
                teardownOptionRoute = "provided",
                legacyOptionsFactoryCalled = false,
            }
        end

        -- The Pass-64 consumer called this factory directly. Keep that behavior:
        -- factory errors propagate rather than being silently converted into a
        -- different teardown state. The TTS factory is deterministic and returns
        -- a table; the type guard below only bounds malformed third-party callers.
        local fallback = factory()
        if type(fallback) ~= "table" then
            return {
                ok = false,
                status = "legacy-options-invalid",
                options = base,
                sharedLeaseTeardownOptions = true,
                teardownOptionRoute = "legacy-fallback-failed",
                legacyOptionsFactoryCalled = true,
            }
        end

        return {
            ok = true,
            status = "legacy-fallback",
            options = merge_options(fallback, base),
            sharedLeaseTeardownOptions = true,
            teardownOptionRoute = "legacy-fallback",
            legacyOptionsFactoryCalled = true,
        }
    end

    local function decorate_stage_callback(options, option_route, activation_route)
        local callback = type(options) == "table" and options.onStage or nil
        if type(callback) ~= "function" then return options end
        local decorated = copy_options(options, true)
        decorated.onStage = function(stage, payload)
            if type(payload) == "table" then
                payload.sharedLeaseTeardownOptions = true
                payload.teardownOptionRoute = option_route
                payload.sharedLeaseTeardownActivation = true
                payload.teardownActivationRoute = activation_route
            end
            return callback(stage, payload)
        end
        return decorated
    end

    -- Pass 64 routed generic teardown through the cohesive lease whenever one
    -- exists. Pass 65 moved lazy teardown-option selection here; Pass 66 does
    -- the same for the legacy activation fallback. The consumer still owns when
    -- teardown runs and the semantic behavior carried by the bridge.
    function Bound.DeactivateOwned(lease, listener, activation, options)
        local resolved_activation = Bound.ResolveDeactivateActivation(lease, activation, options)
        resolved_activation = type(resolved_activation) == "table" and resolved_activation
            or { ok = false, status = "invalid-result", activation = activation }

        if not resolved_activation.ok then
            return {
                ok = false,
                status = tostring(resolved_activation.status or "teardown-activation-failed"),
                error = resolved_activation.error,
                sharedLease = lease ~= nil,
                sharedLeaseRouter = true,
                sharedLeaseTeardownOptions = true,
                sharedLeaseTeardownActivation = true,
                lifecycleRoute = lease ~= nil and "lease" or "legacy",
                teardownActivationRoute = resolved_activation.teardownActivationRoute or "legacy-fallback-failed",
                legacyActivationFactoryCalled = resolved_activation.legacyActivationFactoryCalled == true,
                legacyOptionsFactoryCalled = false,
            }
        end

        local resolved = Bound.ResolveDeactivateOptions(lease, options)
        resolved = type(resolved) == "table" and resolved
            or { ok = false, status = "invalid-result", options = {} }

        if not resolved.ok then
            return {
                ok = false,
                status = tostring(resolved.status or "teardown-options-failed"),
                error = resolved.error,
                sharedLease = lease ~= nil,
                sharedLeaseRouter = true,
                sharedLeaseTeardownOptions = true,
                sharedLeaseTeardownActivation = true,
                lifecycleRoute = lease ~= nil and "lease" or "legacy",
                teardownOptionRoute = resolved.teardownOptionRoute or "legacy-fallback-failed",
                legacyOptionsFactoryCalled = resolved.legacyOptionsFactoryCalled == true,
                teardownActivationRoute = resolved_activation.teardownActivationRoute,
                legacyActivationFactoryCalled = resolved_activation.legacyActivationFactoryCalled == true,
            }
        end

        local effective_options = decorate_stage_callback(
            resolved.options, resolved.teardownOptionRoute, resolved_activation.teardownActivationRoute
        )
        local result
        local shared_lease = lease ~= nil
        if shared_lease then
            result = Bound.DeactivateLease(lease, effective_options)
        else
            result = Bound.Deactivate(listener, resolved_activation.activation, effective_options)
        end
        result = type(result) == "table" and result or { ok = false, status = "invalid-result" }
        result.sharedLease = shared_lease
        result.sharedLeaseRouter = true
        result.sharedLeaseTeardownOptions = true
        result.sharedLeaseTeardownActivation = true
        result.lifecycleRoute = shared_lease and "lease" or "legacy"
        result.teardownOptionRoute = resolved.teardownOptionRoute
        result.legacyOptionsFactoryCalled = resolved.legacyOptionsFactoryCalled == true
        result.teardownActivationRoute = resolved_activation.teardownActivationRoute
        result.legacyActivationFactoryCalled = resolved_activation.legacyActivationFactoryCalled == true
        return result
    end

    function Bound.Retire(listener)
        local result = Bridge.RemoveListener(listener)
        return type(result) == "table" and result or { ok = false, status = "invalid-result" }
    end

    function Bound.RetireLease(lease)
        if type(lease) ~= "table" or lease.listener == nil then
            return { ok = false, status = "invalid-lease" }
        end
        if lease.state == "retired" and type(lease.retirement) == "table" then
            return {
                ok = lease.retirement.ok == true,
                status = "already-retired",
                previous = lease.retirement,
            }
        end
        if lease.deactivationAttempted ~= true then
            return { ok = false, status = "deactivation-not-attempted" }
        end

        local result = Bound.Retire(lease.listener)
        result = type(result) == "table" and result or { ok = false, status = "invalid-result" }
        lease.retirement = result
        if result.ok then lease.state = "retired" end
        return result
    end

    function Bound.RetireOwned(lease, listener)
        local result
        local shared_lease = lease ~= nil
        if shared_lease then
            result = Bound.RetireLease(lease)
        else
            result = Bound.Retire(listener)
        end
        result = type(result) == "table" and result or { ok = false, status = "invalid-result" }
        result.sharedLease = shared_lease
        result.sharedLeaseRouter = true
        result.lifecycleRoute = shared_lease and "lease" or "legacy"
        return result
    end

    -- Pass 67: bind the exact ownership inputs used for deactivation into a
    -- short-lived teardown ticket. The consumer still decides when deactivation
    -- begins and, separately, when retirement is safe after its own quarantine
    -- and modal-isolation policy. The ticket only prevents the later retirement
    -- step from reconstructing or reselecting lease/listener ownership.
    function Bound.BeginOwnedTeardown(lease, listener, activation, options)
        local effective_options = copy_options(options, false)
        local callback = type(effective_options.onStage) == "function" and effective_options.onStage or nil
        if callback ~= nil then
            effective_options.onStage = function(stage, payload)
                if type(payload) == "table" then payload.sharedTeardownTicket = true end
                return callback(stage, payload)
            end
        end

        local result = Bound.DeactivateOwned(lease, listener, activation, effective_options)
        result = type(result) == "table" and result or { ok = false, status = "invalid-result" }
        result.sharedTeardownTicket = true

        local ticket = {
            lease = lease,
            listener = listener,
            deactivation = result,
            state = result.ok and "deactivated" or "deactivate-partial",
            retirementAuthorized = false,
            authorization = nil,
            sharedTeardownTicket = true,
            sharedLease = lease ~= nil,
            lifecycleRoute = result.lifecycleRoute or (lease ~= nil and "lease" or "legacy"),
        }

        return {
            ok = result.ok == true,
            status = tostring(result.status or (result.ok and "complete" or "partial")),
            deactivation = result,
            ticket = ticket,
            sharedTeardownTicket = true,
            sharedLease = lease ~= nil,
            sharedLeaseRouter = result.sharedLeaseRouter == true,
            sharedLeaseTeardownOptions = result.sharedLeaseTeardownOptions == true,
            teardownOptionRoute = result.teardownOptionRoute,
            legacyOptionsFactoryCalled = result.legacyOptionsFactoryCalled == true,
            sharedLeaseTeardownActivation = result.sharedLeaseTeardownActivation == true,
            teardownActivationRoute = result.teardownActivationRoute,
            legacyActivationFactoryCalled = result.legacyActivationFactoryCalled == true,
            lifecycleRoute = ticket.lifecycleRoute,
        }
    end

    -- Pass 68: retirement is still timed by the consumer, but the shared host now
    -- requires an explicit authorization after the consumer has released its own
    -- modal/isolation ownership. This makes the proven ordering an enforceable
    -- ticket invariant without moving the 225 ms quarantine or its policy here.
    function Bound.AuthorizeOwnedTeardown(ticket, authorization)
        if type(ticket) ~= "table" or ticket.sharedTeardownTicket ~= true then
            return {
                ok = false,
                status = "invalid-teardown-ticket",
                sharedTeardownTicket = false,
                sharedTeardownAuthorization = false,
                retirementAuthorized = false,
            }
        end
        if ticket.state == "retired" then
            return {
                ok = false,
                status = "already-retired",
                sharedTeardownTicket = true,
                sharedTeardownAuthorization = true,
                retirementAuthorized = ticket.retirementAuthorized == true,
                sharedLease = ticket.sharedLease == true,
                lifecycleRoute = ticket.lifecycleRoute,
            }
        end
        if ticket.retirementAuthorized == true then
            return {
                ok = true,
                status = "already-authorized",
                sharedTeardownTicket = true,
                sharedTeardownAuthorization = true,
                retirementAuthorized = true,
                authorization = ticket.authorization,
                sharedLease = ticket.sharedLease == true,
                lifecycleRoute = ticket.lifecycleRoute,
            }
        end

        ticket.retirementAuthorized = true
        ticket.authorization = tostring(authorization or "consumer-authorized")
        return {
            ok = true,
            status = "authorized",
            sharedTeardownTicket = true,
            sharedTeardownAuthorization = true,
            retirementAuthorized = true,
            authorization = ticket.authorization,
            sharedLease = ticket.sharedLease == true,
            lifecycleRoute = ticket.lifecycleRoute,
        }
    end

    function Bound.FinishOwnedTeardown(ticket)
        if type(ticket) ~= "table" or ticket.sharedTeardownTicket ~= true then
            return {
                ok = false,
                status = "invalid-teardown-ticket",
                sharedTeardownTicket = false,
                sharedTeardownAuthorization = false,
                retirementAuthorized = false,
            }
        end
        if ticket.state == "retired" and type(ticket.retirement) == "table" then
            local prior = ticket.retirement
            return {
                ok = prior.ok == true,
                status = "already-retired",
                previous = prior,
                sharedTeardownTicket = true,
                sharedTeardownAuthorization = true,
                retirementAuthorized = ticket.retirementAuthorized == true,
                sharedLease = ticket.sharedLease == true,
                sharedLeaseRouter = prior.sharedLeaseRouter == true,
                lifecycleRoute = prior.lifecycleRoute or ticket.lifecycleRoute,
            }
        end
        if ticket.retirementAuthorized ~= true then
            return {
                ok = false,
                status = "retirement-not-authorized",
                sharedTeardownTicket = true,
                sharedTeardownAuthorization = true,
                retirementAuthorized = false,
                sharedLease = ticket.sharedLease == true,
                sharedLeaseRouter = true,
                lifecycleRoute = ticket.lifecycleRoute,
            }
        end

        local result = Bound.RetireOwned(ticket.lease, ticket.listener)
        result = type(result) == "table" and result or { ok = false, status = "invalid-result" }
        result.sharedTeardownTicket = true
        result.sharedTeardownAuthorization = true
        result.retirementAuthorized = true
        ticket.retirement = result
        if result.ok then ticket.state = "retired" else ticket.state = "retire-partial" end
        return result
    end



    -- Pass 71: preserve the consumer-owned timing boundary while moving the
    -- generic authorize-then-retire transaction behind one shared call. The
    -- caller still invokes this only after its own quarantine and modal
    -- isolation release. This function intentionally preserves the Pass-68
    -- failure semantics: failed authorization does not attempt retirement.
    function Bound.CompleteOwnedTeardown(ticket, authorization)
        local authorized = Bound.AuthorizeOwnedTeardown(ticket, authorization)
        authorized = type(authorized) == "table" and authorized
            or { ok = false, status = "invalid-result", sharedTeardownTicket = false, sharedTeardownAuthorization = false, retirementAuthorized = false }

        local retired
        if authorized.ok then
            retired = Bound.FinishOwnedTeardown(ticket)
        else
            retired = {
                ok = false,
                status = "retirement-authorization-failed",
                error = authorized.status,
                sharedTeardownTicket = authorized.sharedTeardownTicket == true,
                sharedTeardownAuthorization = authorized.sharedTeardownAuthorization == true,
                retirementAuthorized = false,
                sharedLease = type(ticket) == "table" and ticket.sharedLease == true,
                sharedLeaseRouter = true,
                lifecycleRoute = type(ticket) == "table" and ticket.lifecycleRoute or nil,
            }
        end
        retired = type(retired) == "table" and retired or { ok = false, status = "invalid-result" }

        return {
            ok = retired.ok == true,
            status = tostring(retired.status or (retired.ok and "complete" or "failed")),
            authorization = authorized,
            retirement = retired,
            sharedTeardownCompletion = true,
            sharedTeardownTicket = retired.sharedTeardownTicket == true or authorized.sharedTeardownTicket == true,
            sharedTeardownAuthorization = retired.sharedTeardownAuthorization == true or authorized.sharedTeardownAuthorization == true,
            retirementAuthorized = retired.retirementAuthorized == true,
            sharedLease = retired.sharedLease == true,
            sharedLeaseRouter = retired.sharedLeaseRouter == true,
            lifecycleRoute = retired.lifecycleRoute or authorized.lifecycleRoute,
        }
    end

    -- Pass 72: the consumer still decides when the post-quarantine teardown may
    -- progress and supplies the modal/isolation-release barrier itself. The shared
    -- host now owns the generic ordering invariant that this barrier must run
    -- before ticket authorization and exact-listener retirement. Deliberately do
    -- not pcall the barrier: the Pass-71 consumer invoked its release functions
    -- directly, so a consumer exception must retain the same fail-closed behavior
    -- and prevent authorization/RemoveFromParent from running.
    function Bound.CompleteOwnedTeardownAfterBarrier(ticket, barrier, authorization)
        if type(barrier) ~= "function" then
            return {
                ok = false,
                status = "invalid-teardown-barrier",
                authorization = nil,
                retirement = nil,
                sharedTeardownBarrier = true,
                barrierCompleted = false,
                sharedTeardownCompletion = false,
                sharedTeardownTicket = type(ticket) == "table" and ticket.sharedTeardownTicket == true or false,
                sharedTeardownAuthorization = false,
                retirementAuthorized = false,
                sharedLease = type(ticket) == "table" and ticket.sharedLease == true or false,
                sharedLeaseRouter = true,
                lifecycleRoute = type(ticket) == "table" and ticket.lifecycleRoute or nil,
            }
        end

        local barrier_result = barrier(ticket)
        local completion = Bound.CompleteOwnedTeardown(ticket, authorization)
        completion = type(completion) == "table" and completion
            or { ok = false, status = "invalid-result", authorization = nil, retirement = nil }

        completion.sharedTeardownBarrier = true
        completion.barrierCompleted = true
        completion.barrierResult = barrier_result
        if type(completion.authorization) == "table" then
            completion.authorization.sharedTeardownBarrier = true
            completion.authorization.barrierCompleted = true
        end
        if type(completion.retirement) == "table" then
            completion.retirement.sharedTeardownBarrier = true
            completion.retirement.barrierCompleted = true
        end
        return completion
    end


    -- Pass 73: keep the already-proven deactivation ticket and later barrier /
    -- authorization / retirement completion inside one short-lived shared
    -- transaction object. The consumer still decides when deactivation begins
    -- and when the post-quarantine barrier may run; this object only prevents
    -- those two phases from reconstructing or reselecting ownership between calls.
    function Bound.BeginTeardownTransaction(lease, listener, activation, options)
        local effective_options = copy_options(options, false)
        local callback = type(effective_options.onStage) == "function" and effective_options.onStage or nil
        if callback ~= nil then
            effective_options.onStage = function(stage, payload)
                if type(payload) == "table" then payload.sharedTeardownTransaction = true end
                return callback(stage, payload)
            end
        end

        local begun = Bound.BeginOwnedTeardown(lease, listener, activation, effective_options)
        begun = type(begun) == "table" and begun
            or { ok = false, status = "invalid-result", deactivation = nil, ticket = nil }

        local transaction = {
            sharedTeardownTransaction = true,
            state = begun.ok and "deactivated" or "deactivate-partial",
            lease = lease,
            listener = listener,
            beginResult = begun,
            deactivation = begun.deactivation,
            ticket = begun.ticket,
            completion = nil,
            lifecycleRoute = begun.lifecycleRoute or (lease ~= nil and "lease" or "legacy"),
        }

        return {
            ok = begun.ok == true,
            status = tostring(begun.status or (begun.ok and "complete" or "partial")),
            transaction = transaction,
            deactivation = begun.deactivation,
            ticket = begun.ticket,
            sharedTeardownTransaction = true,
            sharedTeardownTicket = begun.sharedTeardownTicket == true,
            sharedLease = begun.sharedLease == true,
            sharedLeaseRouter = begun.sharedLeaseRouter == true,
            sharedLeaseTeardownOptions = begun.sharedLeaseTeardownOptions == true,
            teardownOptionRoute = begun.teardownOptionRoute,
            legacyOptionsFactoryCalled = begun.legacyOptionsFactoryCalled == true,
            sharedLeaseTeardownActivation = begun.sharedLeaseTeardownActivation == true,
            teardownActivationRoute = begun.teardownActivationRoute,
            legacyActivationFactoryCalled = begun.legacyActivationFactoryCalled == true,
            lifecycleRoute = transaction.lifecycleRoute,
        }
    end

    function Bound.CompleteTeardownTransaction(transaction, barrier, authorization)
        if type(transaction) ~= "table" or transaction.sharedTeardownTransaction ~= true then
            return {
                ok = false,
                status = "invalid-teardown-transaction",
                authorization = nil,
                retirement = nil,
                sharedTeardownTransaction = false,
                sharedTeardownBarrier = false,
                barrierCompleted = false,
                sharedTeardownCompletion = false,
                sharedTeardownTicket = false,
                sharedTeardownAuthorization = false,
                retirementAuthorized = false,
                sharedLease = false,
                sharedLeaseRouter = true,
                lifecycleRoute = nil,
            }
        end

        if transaction.state == "retired" and type(transaction.completion) == "table" then
            local prior = transaction.completion
            return {
                ok = prior.ok == true,
                status = "already-completed",
                previous = prior,
                authorization = prior.authorization,
                retirement = prior.retirement,
                sharedTeardownTransaction = true,
                sharedTeardownBarrier = prior.sharedTeardownBarrier == true,
                barrierCompleted = prior.barrierCompleted == true,
                sharedTeardownCompletion = prior.sharedTeardownCompletion == true,
                sharedTeardownTicket = prior.sharedTeardownTicket == true,
                sharedTeardownAuthorization = prior.sharedTeardownAuthorization == true,
                retirementAuthorized = prior.retirementAuthorized == true,
                sharedLease = prior.sharedLease == true,
                sharedLeaseRouter = prior.sharedLeaseRouter == true,
                lifecycleRoute = prior.lifecycleRoute or transaction.lifecycleRoute,
            }
        end

        local completion = Bound.CompleteOwnedTeardownAfterBarrier(
            transaction.ticket, barrier, authorization
        )
        completion = type(completion) == "table" and completion
            or { ok = false, status = "invalid-result", authorization = nil, retirement = nil }
        completion.sharedTeardownTransaction = true
        if type(completion.authorization) == "table" then
            completion.authorization.sharedTeardownTransaction = true
        end
        if type(completion.retirement) == "table" then
            completion.retirement.sharedTeardownTransaction = true
        end

        transaction.completion = completion
        if type(completion.retirement) == "table" and completion.retirement.ok == true then
            transaction.state = "retired"
        elseif completion.barrierCompleted == true then
            transaction.state = "completion-partial"
        end
        return completion
    end

    -- Pass 74: bind the exact consumer-supplied completion inputs to the shared
    -- teardown transaction before completion runs. The consumer still owns the
    -- barrier function itself and decides when CompleteTeardownPlan may execute;
    -- the plan only prevents the later completion call from reconstructing or
    -- substituting a different transaction/barrier/authorization tuple.
    function Bound.BeginTeardownPlan(lease, listener, activation, options, barrier, authorization)
        local effective_options = copy_options(options, false)
        local callback = type(effective_options.onStage) == "function" and effective_options.onStage or nil
        if callback ~= nil then
            effective_options.onStage = function(stage, payload)
                if type(payload) == "table" then payload.sharedTeardownPlan = true end
                return callback(stage, payload)
            end
        end

        local begun = Bound.BeginTeardownTransaction(lease, listener, activation, effective_options)
        begun = type(begun) == "table" and begun
            or { ok = false, status = "invalid-result", transaction = nil, deactivation = nil, ticket = nil }

        local plan = {
            sharedTeardownPlan = true,
            state = "bound",
            transaction = begun.transaction,
            barrier = barrier,
            authorization = authorization,
            beginResult = begun,
            completion = nil,
            lifecycleRoute = begun.lifecycleRoute or (lease ~= nil and "lease" or "legacy"),
        }

        return {
            ok = begun.ok == true,
            status = tostring(begun.status or (begun.ok and "complete" or "partial")),
            plan = plan,
            transaction = begun.transaction,
            deactivation = begun.deactivation,
            ticket = begun.ticket,
            sharedTeardownPlan = true,
            sharedTeardownTransaction = begun.sharedTeardownTransaction == true,
            sharedTeardownTicket = begun.sharedTeardownTicket == true,
            sharedLease = begun.sharedLease == true,
            sharedLeaseRouter = begun.sharedLeaseRouter == true,
            sharedLeaseTeardownOptions = begun.sharedLeaseTeardownOptions == true,
            teardownOptionRoute = begun.teardownOptionRoute,
            legacyOptionsFactoryCalled = begun.legacyOptionsFactoryCalled == true,
            sharedLeaseTeardownActivation = begun.sharedLeaseTeardownActivation == true,
            teardownActivationRoute = begun.teardownActivationRoute,
            legacyActivationFactoryCalled = begun.legacyActivationFactoryCalled == true,
            lifecycleRoute = plan.lifecycleRoute,
        }
    end

    function Bound.CompleteTeardownPlan(plan)
        if type(plan) ~= "table" or plan.sharedTeardownPlan ~= true then
            return {
                ok = false,
                status = "invalid-teardown-plan",
                authorization = nil,
                retirement = nil,
                sharedTeardownPlan = false,
                sharedTeardownTransaction = false,
                sharedTeardownBarrier = false,
                barrierCompleted = false,
                sharedTeardownCompletion = false,
                sharedTeardownTicket = false,
                sharedTeardownAuthorization = false,
                retirementAuthorized = false,
                sharedLease = false,
                sharedLeaseRouter = true,
                lifecycleRoute = nil,
            }
        end

        if plan.state == "retired" and type(plan.completion) == "table" then
            local prior = plan.completion
            return {
                ok = prior.ok == true,
                status = "already-completed",
                previous = prior,
                authorization = prior.authorization,
                retirement = prior.retirement,
                sharedTeardownPlan = true,
                sharedTeardownTransaction = prior.sharedTeardownTransaction == true,
                sharedTeardownBarrier = prior.sharedTeardownBarrier == true,
                barrierCompleted = prior.barrierCompleted == true,
                sharedTeardownCompletion = prior.sharedTeardownCompletion == true,
                sharedTeardownTicket = prior.sharedTeardownTicket == true,
                sharedTeardownAuthorization = prior.sharedTeardownAuthorization == true,
                retirementAuthorized = prior.retirementAuthorized == true,
                sharedLease = prior.sharedLease == true,
                sharedLeaseRouter = prior.sharedLeaseRouter == true,
                lifecycleRoute = prior.lifecycleRoute or plan.lifecycleRoute,
            }
        end

        local completion = Bound.CompleteTeardownTransaction(
            plan.transaction, plan.barrier, plan.authorization
        )
        completion = type(completion) == "table" and completion
            or { ok = false, status = "invalid-result", authorization = nil, retirement = nil }
        completion.sharedTeardownPlan = true
        if type(completion.authorization) == "table" then
            completion.authorization.sharedTeardownPlan = true
        end
        if type(completion.retirement) == "table" then
            completion.retirement.sharedTeardownPlan = true
        end

        plan.completion = completion
        if type(completion.retirement) == "table" and completion.retirement.ok == true then
            plan.state = "retired"
        elseif completion.barrierCompleted == true then
            plan.state = "completion-partial"
        end
        return completion
    end


    -- Pass 75: retain the successful Open result as one shared input-bridge
    -- session spanning construction/activation through the later two-phase
    -- teardown plan. The consumer still chooses the listener class and exactly
    -- when open, deactivation, quarantine completion, and retirement may occur.
    -- This session only prevents listener/lease/activation ownership from being
    -- reconstructed between the proven open and close transactions.
    function Bound.OpenSession(player, controller, library, listener_class, handler, options)
        local opened = Bound.Open(player, controller, library, listener_class, handler, options)
        opened = type(opened) == "table" and opened or { ok = false, status = "invalid-result" }

        if opened.ok ~= true then
            opened.sharedInputBridgeSession = true
            opened.session = nil
            return opened
        end

        local session = {
            sharedInputBridgeSession = true,
            state = "active",
            listener = opened.listener,
            lease = opened.lease,
            activation = opened.activation,
            openResult = opened,
            teardownPlan = nil,
            teardownBegin = nil,
            completion = nil,
        }
        opened.session = session
        opened.sharedInputBridgeSession = true
        return opened
    end

    function Bound.BeginSessionTeardown(session, options, barrier, authorization)
        if type(session) ~= "table" or session.sharedInputBridgeSession ~= true then
            return {
                ok = false,
                status = "invalid-input-bridge-session",
                plan = nil,
                transaction = nil,
                deactivation = nil,
                ticket = nil,
                sharedInputBridgeSession = false,
                sharedTeardownPlan = false,
            }
        end

        if session.state == "retired" and type(session.completion) == "table" then
            return {
                ok = session.completion.ok == true,
                status = "already-completed",
                plan = session.teardownPlan,
                transaction = type(session.teardownPlan) == "table" and session.teardownPlan.transaction or nil,
                deactivation = type(session.teardownBegin) == "table" and session.teardownBegin.deactivation or nil,
                ticket = type(session.teardownBegin) == "table" and session.teardownBegin.ticket or nil,
                sharedInputBridgeSession = true,
                sharedTeardownPlan = true,
                previous = session.completion,
            }
        end

        if type(session.teardownBegin) == "table" and type(session.teardownPlan) == "table" then
            local prior = session.teardownBegin
            return {
                ok = prior.ok == true,
                status = "already-begun",
                plan = session.teardownPlan,
                transaction = prior.transaction,
                deactivation = prior.deactivation,
                ticket = prior.ticket,
                sharedInputBridgeSession = true,
                sharedTeardownPlan = prior.sharedTeardownPlan == true,
                sharedTeardownTransaction = prior.sharedTeardownTransaction == true,
                sharedTeardownTicket = prior.sharedTeardownTicket == true,
                sharedLease = prior.sharedLease == true,
                sharedLeaseRouter = prior.sharedLeaseRouter == true,
                sharedLeaseTeardownOptions = prior.sharedLeaseTeardownOptions == true,
                teardownOptionRoute = prior.teardownOptionRoute,
                legacyOptionsFactoryCalled = prior.legacyOptionsFactoryCalled == true,
                sharedLeaseTeardownActivation = prior.sharedLeaseTeardownActivation == true,
                teardownActivationRoute = prior.teardownActivationRoute,
                legacyActivationFactoryCalled = prior.legacyActivationFactoryCalled == true,
                lifecycleRoute = prior.lifecycleRoute,
            }
        end

        local effective_options = copy_options(options, false)
        local callback = type(effective_options.onStage) == "function" and effective_options.onStage or nil
        if callback ~= nil then
            effective_options.onStage = function(stage, payload)
                if type(payload) == "table" then payload.sharedInputBridgeSession = true end
                return callback(stage, payload)
            end
        end

        local begun = Bound.BeginTeardownPlan(
            session.lease, session.listener, session.activation,
            effective_options, barrier, authorization
        )
        begun = type(begun) == "table" and begun
            or { ok = false, status = "invalid-result", plan = nil, transaction = nil, deactivation = nil, ticket = nil }
        begun.sharedInputBridgeSession = true
        if type(begun.deactivation) == "table" then
            begun.deactivation.sharedInputBridgeSession = true
        end

        session.teardownBegin = begun
        session.teardownPlan = begun.plan
        session.state = begun.ok and "deactivated" or "deactivate-partial"
        return begun
    end

    function Bound.CompleteSessionTeardown(session)
        if type(session) ~= "table" or session.sharedInputBridgeSession ~= true then
            return {
                ok = false,
                status = "invalid-input-bridge-session",
                authorization = nil,
                retirement = nil,
                sharedInputBridgeSession = false,
                sharedTeardownPlan = false,
            }
        end

        if session.state == "retired" and type(session.completion) == "table" then
            local prior = session.completion
            return {
                ok = prior.ok == true,
                status = "already-completed",
                previous = prior,
                authorization = prior.authorization,
                retirement = prior.retirement,
                sharedInputBridgeSession = true,
                sharedTeardownPlan = prior.sharedTeardownPlan == true,
                sharedTeardownTransaction = prior.sharedTeardownTransaction == true,
                sharedTeardownBarrier = prior.sharedTeardownBarrier == true,
                barrierCompleted = prior.barrierCompleted == true,
                sharedTeardownCompletion = prior.sharedTeardownCompletion == true,
                sharedTeardownTicket = prior.sharedTeardownTicket == true,
                sharedTeardownAuthorization = prior.sharedTeardownAuthorization == true,
                retirementAuthorized = prior.retirementAuthorized == true,
                sharedLease = prior.sharedLease == true,
                sharedLeaseRouter = prior.sharedLeaseRouter == true,
                lifecycleRoute = prior.lifecycleRoute,
            }
        end

        local completion = Bound.CompleteTeardownPlan(session.teardownPlan)
        completion = type(completion) == "table" and completion
            or { ok = false, status = "invalid-result", authorization = nil, retirement = nil }
        completion.sharedInputBridgeSession = true
        if type(completion.authorization) == "table" then
            completion.authorization.sharedInputBridgeSession = true
        end
        if type(completion.retirement) == "table" then
            completion.retirement.sharedInputBridgeSession = true
        end

        session.completion = completion
        if type(completion.retirement) == "table" and completion.retirement.ok == true then
            session.state = "retired"
        elseif completion.barrierCompleted == true then
            session.state = "completion-partial"
        end
        return completion
    end

    return Bound
end

return InputBridge
