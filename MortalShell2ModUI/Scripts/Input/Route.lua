-- MortalShell2ModUI Input.Route
-- Pure Mortal Shell II menu-action routing and cross-source dedupe transforms.
-- Consumers own clocks, diagnostics, physical input/listeners, and action dispatch.

local Route = {}

function Route.Action(action_name)
    action_name = tostring(action_name or "")
    if action_name:find("IA_Menu_Up_Continuous", 1, true) then return nil end
    if action_name:find("IA_Menu_Down_Continuous", 1, true) then return nil end
    if action_name:find("IA_Menu_Left_Continuous", 1, true) then return nil end
    if action_name:find("IA_Menu_Right_Continuous", 1, true) then return nil end

    if action_name:find("IA_Menu_Mouse_Left.", 1, true) then return "mouse_left" end
    if action_name:find("IA_Menu_Mouse_Right.", 1, true) then return "mouse_right" end
    if action_name:find("IA_Menu_MouseWheel_Up.", 1, true) then return "mouse_wheel_up" end
    if action_name:find("IA_Menu_MouseWheel_Down.", 1, true) then return "mouse_wheel_down" end

    if action_name:find("IA_Menu_Up.", 1, true) then return "up" end
    if action_name:find("IA_Menu_Down.", 1, true) then return "down" end
    if action_name:find("IA_Menu_Left_Primary.", 1, true) then return "left" end
    if action_name:find("IA_Menu_Right_Primary.", 1, true) then return "right" end
    if action_name:find("IA_Menu_Left_Secondary.", 1, true) then return "previous_tab" end
    if action_name:find("IA_Menu_Right_Secondary.", 1, true) then return "next_tab" end
    if action_name:find("IA_Menu_Left_Tertiary.", 1, true) then return "previous_tab" end
    if action_name:find("IA_Menu_Right_Tertiary.", 1, true) then return "next_tab" end
    if action_name:find("IA_Menu_Confirm_Primary_Press.", 1, true) then return "confirm" end
    if action_name:find("IA_Menu_Confirm_Secondary_Press.", 1, true) then return "confirm" end
    if action_name:find("IA_Menu_Confirm_Tertiary_Press.", 1, true) then return "confirm" end
    if action_name:find("IA_Menu_Back.", 1, true) then return "back" end
    return nil
end

-- Mortal Shell II's default menu mapping reports D-pad vertical presses through
-- both IA_Menu_Up/Down and IA_Menu_MouseWheel_Up/Down. Treat those routes as one
-- semantic edge before consumer-level deduplication.
function Route.Semantic(action)
    action = tostring(action or "")
    if action == "mouse_wheel_up" then return "up" end
    if action == "mouse_wheel_down" then return "down" end
    return action
end

function Route.ClaimCrossSource(last_semantic, last_source_kind, last_clock,
        semantic, source_kind, now, window_seconds)
    semantic = tostring(semantic or "")
    source_kind = tostring(source_kind or "")
    if semantic == "" or source_kind == "" then
        return true, last_semantic, last_source_kind, last_clock, nil
    end

    now = tonumber(now)
    if now == nil then
        return true, last_semantic, last_source_kind, last_clock, nil
    end

    last_clock = tonumber(last_clock) or -1.0
    last_semantic = tostring(last_semantic or "")
    last_source_kind = tostring(last_source_kind or "")
    window_seconds = tonumber(window_seconds) or 0.0

    local elapsed = last_clock >= 0.0 and (now - last_clock) or math.huge
    local duplicate = last_semantic == semantic
        and last_source_kind ~= ""
        and last_source_kind ~= source_kind
        and elapsed >= 0.0
        and elapsed <= window_seconds

    if duplicate then
        return false, last_semantic, last_source_kind, last_clock, {
            elapsed = elapsed,
            prior_source_kind = last_source_kind,
        }
    end

    return true, semantic, source_kind, now, { elapsed = elapsed }
end

return Route
