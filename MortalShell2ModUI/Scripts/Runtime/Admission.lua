-- MortalShell2ModUI Runtime.Admission
-- Pure Mortal Shell II menu-admission policy. Consumers still acquire the actual
-- BPC_UserInterfaceHandler / PlayerController snapshot and own all diagnostics,
-- hooks, world lifetime, shell creation and modal effects.

local Admission = {}

local function text(value)
    if value == nil then return "" end
    return tostring(value)
end

function Admission.EvaluateGameplayContext(identity)
    identity = type(identity) == "table" and identity or {}
    local controller_name = text(identity.controllerName)
    local player_name = text(identity.playerName)
    local handler_name = text(identity.handlerName)

    local blockers = {}
    if controller_name:find("BP_PlayerController_MainMenu_C", 1, true) ~= nil
        or player_name:find("BP_MainMenuCharacter_C", 1, true) ~= nil
        or handler_name:find("BPC_UserInterfaceHandler_MainMenu_C", 1, true) ~= nil then
        blockers[#blockers + 1] = "FrontEndMainMenu"
    end
    if not controller_name:match("^BP_PlayerController_C%s") then
        blockers[#blockers + 1] = "NonGameplayController"
    end
    if player_name ~= "" and not player_name:match("^BP_PlayerCharacter_C%s") then
        blockers[#blockers + 1] = "NonGameplayPlayer"
    end
    if handler_name ~= "" and handler_name:find("BPC_UserInterfaceHandler_MainMenu_C", 1, true) ~= nil then
        blockers[#blockers + 1] = "FrontEndUIHandler"
    end

    if #blockers > 0 then
        return false, blockers, table.concat(blockers, ",")
    end
    return true, blockers, nil
end

function Admission.Evaluate(snapshot)
    snapshot = type(snapshot) == "table" and snapshot or {}
    if snapshot.handlerValid == false then
        return true, {}, "handler unavailable"
    end

    local blockers = {}
    if snapshot.activeMenuValid == true then blockers[#blockers + 1] = "ActiveMenu" end
    if snapshot.activeSubMenuValid == true then blockers[#blockers + 1] = "ActiveSubMenu" end
    if snapshot.activeReadTextValid == true then blockers[#blockers + 1] = "ActiveReadText" end
    if snapshot.transitionValid == true then blockers[#blockers + 1] = "CurrentTransitionWidget" end
    if tonumber(snapshot.confirmationsCount) ~= nil and tonumber(snapshot.confirmationsCount) > 0 then
        blockers[#blockers + 1] = "ActiveConfirmations"
    end
    if snapshot.noActiveMenu == false then blockers[#blockers + 1] = "NoActiveMenu=false" end
    if snapshot.controllerInMenu == true then blockers[#blockers + 1] = "ControllerIsInGameMenu" end
    if snapshot.handlerInMenu == true then blockers[#blockers + 1] = "HandlerIsInGameMenu" end
    if snapshot.canOpenOptions == false then blockers[#blockers + 1] = "OptionsMenuQuery=false" end

    if #blockers > 0 then
        return false, blockers, table.concat(blockers, ",")
    end
    return true, blockers, nil
end

return Admission
