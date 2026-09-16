-- MortalShell2ModUI runtime object-resolution helpers.
-- This module locates existing game-owned objects only. It does not own hooks,
-- polling, world lifetime, widgets, input listeners, pause/effects, or teardown.

local Resolve = {}

function Resolve.Bind(Object)
    if type(Object) ~= "table"
        or type(Object.Unwrap) ~= "function"
        or type(Object.Valid) ~= "function" then
        error("Runtime.Resolve requires Core.Object", 0)
    end

    local unwrap = Object.Unwrap
    local valid = Object.Valid
    local Bound = {}

    function Bound.PlayerController(find_first_of, find_all_of)
        local function pawn_from_controller(controller)
            controller = unwrap(controller)
            if not valid(controller) then return nil end

            local ok_property, property_value = pcall(function()
                return unwrap(controller.Pawn)
            end)
            if ok_property and valid(property_value) then
                return property_value
            end

            local ok_function, function_value = pcall(function()
                return unwrap(controller:GetPawn())
            end)
            if ok_function and valid(function_value) then
                return function_value
            end
            return nil
        end

        -- Pass 133 transition corrective: a main-menu/world round trip can leave multiple
        -- BP_PlayerCharacter_C wrappers discoverable. FindFirstOf on that character class is
        -- therefore not authoritative enough to choose the active local player's controller.
        -- Prefer the same UE4SS-native pattern used by shared UEHelpers: enumerate
        -- PlayerController objects and select the valid local controller, then resolve its Pawn.
        -- The standalone host still calls this only on controller-cache miss/world transition,
        -- and the consumer closed-menu fast path keeps it off the permanent 50 ms idle cadence.
        -- Other consumers may resolve on demand at an operation boundary (for example narration).
        if find_all_of ~= nil then
            local ok_controllers, controllers = pcall(function()
                return find_all_of("PlayerController")
            end)
            if ok_controllers and type(controllers) == "table" then
                local fallback_controller = nil
                local fallback_player = nil
                for _, candidate in ipairs(controllers) do
                    local controller = unwrap(candidate)
                    if valid(controller) then
                        local local_ok, is_local = pcall(function()
                            return controller:IsLocalPlayerController()
                        end)
                        if local_ok and is_local == true then
                            local player = pawn_from_controller(controller)
                            if valid(player) then
                                return player, controller, nil, "local-player-controller"
                            end
                            -- A local controller with no current Pawn is still more authoritative
                            -- than a stale loaded BP_PlayerCharacter_C. Let callers that need a
                            -- Pawn fail closed/retry instead of selecting a different controller.
                            return nil, controller, "player-unavailable", "local-player-controller"
                        end

                        local player = pawn_from_controller(controller)
                        if valid(player) and fallback_controller == nil then
                            local player_ok, is_player = pcall(function()
                                return controller:IsPlayerController()
                            end)
                            if player_ok and is_player == true then
                                fallback_controller = controller
                                fallback_player = player
                            end
                        end
                    end
                end

                -- Mortal Shell II is single-player, but keep a conservative UE4SS compatibility
                -- fallback if IsLocalPlayerController is unavailable in a future runtime.
                if valid(fallback_controller) and valid(fallback_player) then
                    return fallback_player, fallback_controller, nil, "player-controller-fallback"
                end
            end
        end

        -- Compatibility fallback for runtimes/callers that do not expose FindAllOf yet.
        if type(find_first_of) ~= "function" then
            return nil, nil, "player-controller-resolution-unavailable", "unavailable"
        end

        local ok_player, player = pcall(function()
            return unwrap(find_first_of("BP_PlayerCharacter_C"))
        end)
        if not ok_player or not valid(player) then
            return nil, nil, ok_player and "player-invalid" or "player-find-failed",
                "bp-player-character-fallback"
        end

        local controller = nil
        local ok_property, property_value = pcall(function()
            return unwrap(player.Controller)
        end)
        if ok_property and valid(property_value) then
            controller = property_value
        else
            local ok_function, function_value = pcall(function()
                return unwrap(player:GetController())
            end)
            if ok_function and valid(function_value) then
                controller = function_value
            end
        end

        if controller ~= nil then
            return player, controller, nil, "bp-player-character-fallback"
        end
        return player, nil, "controller-unavailable", "bp-player-character-fallback"
    end

    function Bound.UIHandler(world_context, options)
        options = type(options) == "table" and options or {}
        world_context = unwrap(world_context)
        if not valid(world_context) then
            return nil, { status = "world-context-invalid" }
        end

        local load_asset = options.LoadAsset
        local static_find_object = options.StaticFindObject
        local find_first_of = options.FindFirstOf
        local bpfl_asset = tostring(options.BPFLAsset or "")
        local bpfl_cdo = tostring(options.BPFLCdo or "")

        if type(load_asset) == "function" and bpfl_asset ~= "" then
            pcall(function() load_asset(bpfl_asset) end)
        end

        local cdo = nil
        local ok_cdo = false
        if type(static_find_object) == "function" and bpfl_cdo ~= "" then
            ok_cdo, cdo = pcall(function()
                return unwrap(static_find_object(bpfl_cdo))
            end)
        end

        if ok_cdo and valid(cdo) and cdo["GetUserInterfaceHandler"] ~= nil then
            local success_out = {}
            local ok_call, first, second, third = pcall(function()
                return cdo:GetUserInterfaceHandler(world_context, success_out)
            end)
            if ok_call then
                local candidates = { first, second, third }
                for _, candidate in ipairs(candidates) do
                    candidate = unwrap(candidate)
                    if valid(candidate) then
                        return candidate, {
                            status = "bpfl",
                            first = first,
                            second = second,
                            third = third,
                        }
                    end
                end
                return nil, {
                    status = "bpfl-no-object-return",
                    first = first,
                    second = second,
                    third = third,
                    tryFallback = true,
                }
            end
            return nil, {
                status = "bpfl-call-failed",
                error = first,
                tryFallback = true,
            }
        end

        local primary_meta = {
            status = "bpfl-cdo-unavailable",
            cdo = cdo,
            tryFallback = true,
        }

        if type(find_first_of) == "function" then
            local ok_fallback, handler = pcall(function()
                return unwrap(find_first_of("BPC_UserInterfaceHandler_C"))
            end)
            if ok_fallback and valid(handler) then
                return handler, {
                    status = "FindFirstOf-fallback",
                    primary = primary_meta,
                }
            end
            return nil, {
                status = "failed",
                fallback = handler,
                primary = primary_meta,
            }
        end

        return nil, {
            status = "failed",
            fallback = "FindFirstOf unavailable",
            primary = primary_meta,
        }
    end

    -- When BPFL exists but returns/calls unsuccessfully, preserve the historical
    -- FindFirstOf fallback without making consumers duplicate the resolution code.
    function Bound.UIHandlerWithFallback(world_context, options)
        options = type(options) == "table" and options or {}
        local handler, meta = Bound.UIHandler(world_context, options)
        if handler ~= nil or type(meta) ~= "table" or meta.tryFallback ~= true then
            return handler, meta
        end

        local find_first_of = options.FindFirstOf
        if type(find_first_of) == "function" then
            local ok_fallback, fallback = pcall(function()
                return unwrap(find_first_of("BPC_UserInterfaceHandler_C"))
            end)
            if ok_fallback and valid(fallback) then
                return fallback, {
                    status = "FindFirstOf-fallback",
                    primary = meta,
                }
            end
            return nil, {
                status = "failed",
                fallback = fallback,
                primary = meta,
            }
        end

        return nil, {
            status = "failed",
            fallback = "FindFirstOf unavailable",
            primary = meta,
        }
    end

    return Bound
end

return Resolve
