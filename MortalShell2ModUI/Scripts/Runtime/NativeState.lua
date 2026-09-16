-- MortalShell2ModUI Runtime.NativeState
-- Pure change-tracker for read-only native UI observations.
-- The consumer owns sampling cadence, UE4SS object resolution, hooks, diagnostics,
-- and every mutation. This module never calls Unreal/UE4SS APIs.

local NativeState = {}

local function b(value)
    if value == true then return "true" end
    if value == false then return "false" end
    return "<unknown>"
end

local function s(value)
    if value == nil then return "<nil>" end
    return tostring(value)
end

local function normalized_count(value)
    value = tonumber(value)
    if value == nil then return nil end
    return math.max(0, math.floor(value + 0.5))
end

function NativeState.KnownBoolean(known, value)
    if known ~= true then return nil end
    if value == true then return true end
    if value == false then return false end
    return nil
end

function NativeState.NewTracker()
    return {
        signature = nil,
        transition = 0,
        samples = 0,
        idleBlockedSamples = 0,
        lastIdleBlockedMilestone = 0,
    }
end

function NativeState.Signature(observation)
    observation = type(observation) == "table" and observation or {}
    return table.concat({
        b(observation.handlerValid),
        s(observation.activeMenu),
        s(observation.activeSubMenu),
        s(observation.activeReadText),
        s(observation.transitionWidget),
        s(normalized_count(observation.confirmationsCount)),
        s(observation.confirmations),
        b(observation.noActiveMenu),
        b(observation.controllerInMenu),
        b(observation.handlerInMenu),
        b(observation.canOpenOptions),
        b(observation.canOpenMap),
        b(observation.ownedModalActive),
        b(observation.pendingOwnedCleanup),
    }, "|")
end

function NativeState.IsIdleBlockedCandidate(observation)
    observation = type(observation) == "table" and observation or {}
    local confirmations = normalized_count(observation.confirmationsCount)
    local active_menu = tostring(observation.activeMenu or "<nil>")
    local active_submenu = tostring(observation.activeSubMenu or "<nil>")
    local active_read = tostring(observation.activeReadText or "<nil>")
    local transition = tostring(observation.transitionWidget or "<nil>")

    local function inactive_name(name)
        return name == "<nil>" or name == "<invalid>" or name == ""
    end

    return observation.handlerValid == true
        and inactive_name(active_menu)
        and inactive_name(active_submenu)
        and inactive_name(active_read)
        and inactive_name(transition)
        and confirmations == 0
        and observation.noActiveMenu == true
        and observation.controllerInMenu == false
        and observation.handlerInMenu == false
        and observation.canOpenOptions == false
        and observation.canOpenMap == false
        and observation.ownedModalActive ~= true
        and observation.pendingOwnedCleanup ~= true
end

function NativeState.Observe(tracker, observation)
    if type(tracker) ~= "table" then
        tracker = NativeState.NewTracker()
    end
    observation = type(observation) == "table" and observation or {}

    tracker.samples = (tonumber(tracker.samples) or 0) + 1
    local signature = NativeState.Signature(observation)
    local changed = signature ~= tracker.signature
    local prior_signature = tracker.signature

    if changed then
        tracker.signature = signature
        tracker.transition = (tonumber(tracker.transition) or 0) + 1
    end

    local idle_blocked = NativeState.IsIdleBlockedCandidate(observation)
    if idle_blocked then
        tracker.idleBlockedSamples = (tonumber(tracker.idleBlockedSamples) or 0) + 1
    else
        tracker.idleBlockedSamples = 0
        tracker.lastIdleBlockedMilestone = 0
    end

    local milestone = nil
    -- Consumers currently sample at a bounded cadence. These sample milestones are
    -- deliberately time-agnostic: diagnostics report the sample count rather than
    -- pretending it is an exact wall-clock duration.
    for _, candidate in ipairs({ 1, 5, 10, 25, 50 }) do
        if tracker.idleBlockedSamples >= candidate
            and (tonumber(tracker.lastIdleBlockedMilestone) or 0) < candidate then
            tracker.lastIdleBlockedMilestone = candidate
            milestone = candidate
        end
    end

    return {
        tracker = tracker,
        changed = changed,
        transition = tonumber(tracker.transition) or 0,
        samples = tonumber(tracker.samples) or 0,
        signature = signature,
        priorSignature = prior_signature,
        idleBlockedCandidate = idle_blocked,
        idleBlockedSamples = tonumber(tracker.idleBlockedSamples) or 0,
        idleBlockedMilestone = milestone,
    }
end

return NativeState
