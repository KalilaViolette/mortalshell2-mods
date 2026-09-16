-- MortalShell2TTS Input.BridgeDiagnostics
-- Consumer-specific diagnostics/state adapter for MortalShell2ModUI Runtime.InputBridge.
-- Shared framework owns reusable mechanics; this module keeps MortalShell2TTS log
-- vocabulary and ui-state mirrors out of the composition root.

local BridgeDiagnostics = {}

function BridgeDiagnostics.Bind(ctx)
    if type(ctx) ~= "table" or type(ctx.ui) ~= "table"
        or type(ctx.log) ~= "function" or type(ctx.diag) ~= "function"
        or type(ctx.listCsv) ~= "function" then
        error("Input.BridgeDiagnostics requires ui/log/diag/listCsv", 0)
    end

    local ui = ctx.ui
    local log = ctx.log
    local diag = ctx.diag
    local list_csv = ctx.listCsv
    local log_handles = type(ctx.logHandles) == "function" and ctx.logHandles or function() end
    local log_active = type(ctx.logActive) == "function" and ctx.logActive or function() end

    local Bound = {}

    function Bound.ApplyRoutes(result)
        result = type(result) == "table" and result or {}
        ui.native_route_by_enum = type(result.routeByEnum) == "table" and result.routeByEnum or {}
        ui.native_route_by_action = type(result.routeByAction) == "table" and result.routeByAction or {}
        ui.native_action_name_by_enum = type(result.actionNameByEnum) == "table" and result.actionNameByEnum or {}
        ui.mouse_input_ready = result.mouseInputReady == true

        if result.status == "listener-invalid" then return {} end
        if result.status == "interface-map-unavailable" then
            log("native controller routes unavailable: InterfaceInputs was not exposed")
            diag("input.routes", { status = "interface-map-unavailable", error = tostring(result.error) })
            return {}
        end

        for _, entry in ipairs(type(result.entries) == "table" and result.entries or {}) do
            log("native controller route enum=" .. tostring(entry.enum) .. " action=" .. tostring(entry.action) .. " route=" .. tostring(entry.route))
            diag("input.route", { enum = entry.enum, action = entry.action, route = entry.route })
        end

        local accepted = type(result.accepted) == "table" and result.accepted or {}
        diag("input.routes", {
            status = #accepted > 0 and "ok" or "empty",
            count = #accepted,
            enums = list_csv(accepted),
            sharedHost = true,
        })
        return accepted
    end

    function Bound.AcceptedRestore(result, original, extra)
        result = type(result) == "table" and result or {}
        extra = type(extra) == "table" and extra or {}
        if result.status == "assignment-failed" then
            log("native AcceptedInputs restore failed: " .. tostring(result.error))
            diag("input.accepted.restore", { status = "assignment-failed", expected = list_csv(original), error = result.error, sharedHost = extra.sharedHost })
        elseif result.status == "read-failed" then
            diag("input.accepted.restore", { status = "read-failed", expected = list_csv(original), error = result.readError, sharedHost = extra.sharedHost })
        elseif result.status == "original-unknown" then
            diag("input.accepted.restore", { status = "original-unknown", sharedHost = extra.sharedHost })
        elseif result.status ~= nil and result.status ~= "not-owned" then
            local restored = result.active or {}
            local missing = result.missing or {}
            local unexpected = result.unexpected or {}
            diag("input.accepted.restore", {
                status = result.status,
                expected = list_csv(original),
                active = list_csv(restored),
                missing = list_csv(missing),
                unexpected = list_csv(unexpected),
                sharedHost = extra.sharedHost,
            })
            if result.status ~= "exact" then
                log("native AcceptedInputs restore verification FAILED expected=" .. list_csv(original) .. " active=" .. list_csv(restored))
            end
        end
    end

    function Bound.ApplyAccepted(result, desired, owned)
        result = type(result) == "table" and result or {}
        desired = type(desired) == "table" and desired or {}
        ui.native_original_accepted_inputs = result.original
        ui.native_accepted_inputs_changed = owned == true
        ui.native_verified_accepted_inputs = {}

        diag("input.accepted.before", {
            count = result.original and #result.original or "<unknown>",
            enums = result.original and list_csv(result.original) or "<unknown>",
            error = result.originalError,
            sharedHost = true,
        })

        if result.status == "assignment-failed" then
            log("native AcceptedInputs expansion unavailable: " .. tostring(result.error))
            diag("input.accepted.configure", { status = "assignment-failed", desiredCount = #desired, desired = list_csv(desired), error = result.error, sharedHost = true })
            return false
        elseif result.status == "invalid-arguments" then
            diag("input.accepted.configure", { status = "invalid-arguments", desiredCount = #desired, sharedHost = true })
            return false
        elseif result.status == "read-failed" then
            log("native AcceptedInputs expansion could not be verified: " .. tostring(result.verifyError))
            diag("input.accepted.verify", { status = "read-failed", desiredCount = #desired, desired = list_csv(desired), error = result.verifyError, sharedHost = true })
            Bound.AcceptedRestore(result.restore, result.original, { sharedHost = true })
            return false
        end

        local verified = result.verified
        local missing = result.missing or {}
        local unexpected = result.unexpected or {}
        local exact = result.ok == true and result.status == "exact"
        diag("input.accepted.verify", {
            status = exact and "exact" or "mismatch",
            desiredCount = #desired,
            activeCount = verified and #verified or 0,
            desired = list_csv(desired),
            active = verified and list_csv(verified) or "",
            missing = list_csv(missing),
            unexpected = list_csv(unexpected),
            sharedHost = true,
        })
        if not exact then
            log("native AcceptedInputs exact verification FAILED desired=" .. list_csv(desired)
                .. " active=" .. (verified and list_csv(verified) or "<unavailable>")
                .. " missing=" .. list_csv(missing) .. " unexpected=" .. list_csv(unexpected))
            Bound.AcceptedRestore(result.restore, result.original, { sharedHost = true })
            return false
        end

        ui.native_verified_accepted_inputs = verified
        log("native AcceptedInputs exact verification passed original=" .. tostring(result.original and #result.original or "unknown")
            .. " desired=" .. tostring(#desired) .. " active=" .. tostring(#verified) .. " enums=" .. list_csv(verified))
        return true
    end

    function Bound.HookRegister(result)
        result = type(result) == "table" and result or { ok = false, status = "invalid-result" }
        if not result.ok then
            log("native input hook unavailable: InputTriggeredCallback: " .. tostring(result.error or result.status))
            diag("input.hook.register", { status = result.status, error = result.error, sharedRuntime = true, sharedHost = true })
            return false
        end
        ui.native_input_hooks_ready = true
        if result.externallyHosted == true or result.status == "externally-hosted" then
            log("native input hook ownership=ModUI-process-mirror; per-session RegisterHook skipped")
            diag("input.hook.register", {
                status = "externally-hosted", owner = "ModUI-process-mirror",
                perSessionRegisterHook = false, sharedRuntime = true, sharedHost = true,
            })
            return true
        end
        if result.alreadyRegistered then
            diag("input.hook.register", { status = "already-registered", cycle = result.cycle, sharedRuntime = true, sharedHost = true })
            return true
        end
        log("native input hook armed on WBP_InputListener_C InputTriggeredCallback only cycle=" .. tostring(result.cycle)
            .. " pre=" .. tostring(result.pre) .. " post=" .. tostring(result.post))
        diag("input.hook.register", { status = "registered", cycle = result.cycle, pre = tostring(result.pre), post = tostring(result.post), sharedRuntime = true, sharedHost = true })
        return true
    end

    function Bound.HookRetire(result, reason)
        result = type(result) == "table" and result or { ok = false, status = "invalid-result" }
        if not result.ok then
            if result.status == "hook-ids-unavailable" then
                log("native input hook retire skipped: hook IDs unavailable; keeping registration state")
            elseif result.status ~= "invalid-arguments" then
                log("native input hook retire failed: " .. tostring(result.error or result.status) .. "; keeping registration state to avoid duplicate hook")
            end
            diag("input.hook.retire", { status = result.status, error = result.error, cycle = result.cycle, reason = tostring(reason or "settings close"), sharedRuntime = true, sharedHost = true })
            return false
        end
        ui.native_input_hooks_ready = false
        if result.externallyHosted == true or result.status == "externally-hosted" then
            log("native input hook retirement skipped ownership=ModUI-process-mirror reason=" .. tostring(reason or "settings close"))
            diag("input.hook.retire", {
                status = "externally-hosted", owner = "ModUI-process-mirror",
                perSessionUnregisterHook = false, reason = tostring(reason or "settings close"),
                sharedRuntime = true, sharedHost = true,
            })
            return true
        end
        if result.status == "not-registered" then return true end
        log("native input hook retired cycle=" .. tostring(result.cycle or 0) .. " pre=" .. tostring(result.pre)
            .. " post=" .. tostring(result.post) .. " reason=" .. tostring(reason or "settings close"))
        diag("input.hook.retire", { status = result.status, cycle = result.cycle, pre = tostring(result.pre), post = tostring(result.post), reason = tostring(reason or "settings close"), sharedRuntime = true, sharedHost = true })
        return true
    end

    function Bound.BindingEnable(result, listener, handler)
        result = type(result) == "table" and result or { ok = false, status = "invalid-result" }
        if not result.ok then
            local scrub = type(result.scrub) == "table" and result.scrub or {}
            diag("input.enable", { path = result.path or "<unknown>", status = "failed", error = result.bindError or result.initialError or result.status, sharedRuntime = true, sharedHost = true })
            if result.initialError ~= nil then
                diag("input.enable.scrub", {
                    SetEnabledState = scrub.setEnabledStateOk == false and tostring(scrub.setEnabledStateError) or "ok",
                    UnbindInputs = scrub.unbindInputsOk == false and tostring(scrub.unbindInputsError) or "ok",
                    sharedRuntime = true, sharedHost = true,
                })
                log_handles(listener, "after-enable-failure-scrub")
                log_active(handler, listener, "after-enable-failure-scrub")
            end
            log("native input bridge enable failed SetEnabledState=" .. tostring(result.initialError) .. " BindInputs=" .. tostring(result.bindError))
            return false
        end

        if result.path == "BindInputs-fallback" then
            local scrub = type(result.scrub) == "table" and result.scrub or {}
            diag("input.enable", { path = "SetEnabledState", status = "failed", error = result.initialError, sharedRuntime = true, sharedHost = true })
            diag("input.enable.scrub", {
                SetEnabledState = scrub.setEnabledStateOk == false and tostring(scrub.setEnabledStateError) or "ok",
                UnbindInputs = scrub.unbindInputsOk == false and tostring(scrub.unbindInputsError) or "ok",
                sharedRuntime = true, sharedHost = true,
            })
            log_handles(listener, "after-enable-failure-scrub")
            log_active(handler, listener, "after-enable-failure-scrub")
            diag("input.enable", { path = "BindInputs-fallback", status = "ok", initialError = result.initialError, sharedRuntime = true, sharedHost = true })
            log("native input bridge used direct BindInputs fallback after SetEnabledState failure: " .. tostring(result.initialError))
        else
            diag("input.enable", { path = "SetEnabledState", status = "ok", sharedRuntime = true, sharedHost = true })
        end
        ui.native_listener_enabled = true
        return true
    end

    return Bound
end

return BridgeDiagnostics
