-- MortalShell2ModUI Runtime.ModalIsolation
-- Shared Mortal Shell II gameplay/modal isolation policy used by settings consumers.
-- Pass 183 transfers the proven Pass-163 implementation into framework ownership without
-- changing acquisition/release semantics or session timing. Consumers still own when their
-- active settings session acquires/releases this policy until a separately runtime-proven
-- host-policy migration is justified.

local M = {}

function M.New(ctx)
    ctx = type(ctx) == "table" and ctx or {}
    local ui = assert(ctx.ui, "UI.ModalIsolation requires ui")
    local config = assert(ctx.config, "UI.ModalIsolation requires config")
    local ModUI = assert(ctx.ModUI, "UI.ModalIsolation requires ModUI")
    local unwrap = assert(ctx.unwrap, "UI.ModalIsolation requires unwrap")
    local valid = assert(ctx.valid, "UI.ModalIsolation requires valid")
    local same_object = assert(ctx.same_object, "UI.ModalIsolation requires same_object")
    local struct_field = assert(ctx.struct_field, "UI.ModalIsolation requires struct_field")
    local log = type(ctx.log) == "function" and ctx.log or function() end
    local diag = type(ctx.diag) == "function" and ctx.diag or function() end

local function pause_native_gameplay(source, reason)
    reason = tostring(reason or "compatibility-fallback")
    if ui.native_pause_bumped and (tonumber(ui.native_pause_bumps) or 0) > 0 then
        return true
    end

    source = unwrap(source)
    if not valid(source) then return false end

    local handler = nil
    if source["UIPauseGame"] ~= nil then
        handler = source
    else
        local ok_handler, value = pcall(function() return unwrap(source.UserInterfaceComponent) end)
        if ok_handler and valid(value) then handler = value end
    end
    if not valid(handler) or handler["UIPauseGame"] == nil then
        log("native UI gameplay pause unavailable: BPC_UserInterfaceHandler/UIPauseGame was not exposed")
        return false
    end

    local function pause_counter()
        local ok, value = pcall(function() return tonumber(unwrap(handler.PauseGameCounter)) end)
        if ok then return value end
        return nil
    end

    local before = pause_counter()
    local bumps = 0
    local after = before

    -- Mortal Shell normally pauses when this reference counter becomes positive.
    -- A zone/UI transition can leave the shared counter below zero; one old-style
    -- bump would then only move -1 -> 0 and leave gameplay active. Add only as
    -- many references as are required to make the counter positive, and remember
    -- the exact count so close restores the original baseline.
    repeat
        local ok_pause, pause_error = pcall(function() handler:UIPauseGame(true) end)
        if not ok_pause then
            log("native UI gameplay pause failed: " .. tostring(pause_error))
            for _ = 1, bumps do pcall(function() handler:UIPauseGame(false) end) end
            return false
        end
        bumps = bumps + 1
        after = pause_counter()
        if after == nil or after > 0 then break end
    until bumps >= 4

    if after ~= nil and after <= 0 then
        for _ = 1, bumps do pcall(function() handler:UIPauseGame(false) end) end
        log("native UI gameplay pause could not reach a positive counter; baseline="
            .. tostring(before) .. " after=" .. tostring(after) .. " bumps=" .. tostring(bumps))
        return false
    end

    ui.native_pause_component = handler
    ui.native_pause_bumped = bumps > 0
    ui.native_pause_bumps = bumps
    ui.native_pause_reason = reason
    log("native UI gameplay pause acquired counter=" .. tostring(before) .. "->" .. tostring(after)
        .. " bumps=" .. tostring(bumps) .. " reason=" .. tostring(reason))
    diag("modalIsolation.pause", {
        action = "acquire",
        status = "ok",
        reason = reason,
        counterBefore = before,
        counterAfter = after,
        bumps = bumps,
    })
    return true
end

local function release_native_gameplay_pause(expected_reason)
    if expected_reason ~= nil and tostring(ui.native_pause_reason or "") ~= tostring(expected_reason) then
        return false
    end
    local handler = unwrap(ui.native_pause_component)
    local bumps = tonumber(ui.native_pause_bumps) or 0
    if ui.native_pause_bumped and bumps > 0 and valid(handler) and handler["UIPauseGame"] ~= nil then
        local before = "?"
        pcall(function() before = tostring(unwrap(handler.PauseGameCounter)) end)
        local release_ok = true
        local release_error = nil
        for _ = 1, bumps do
            local ok, err = pcall(function() handler:UIPauseGame(false) end)
            if not ok then
                release_ok = false
                release_error = err
                break
            end
        end
        if not release_ok then
            log("native UI gameplay pause release failed: " .. tostring(release_error))
        else
            local after = "?"
            pcall(function() after = tostring(unwrap(handler.PauseGameCounter)) end)
            log("native UI gameplay pause released counter=" .. before .. "->" .. after
                .. " bumps=" .. tostring(bumps))
        end
    end
    local released_reason = ui.native_pause_reason
    ui.native_pause_component = nil
    ui.native_pause_bumped = false
    ui.native_pause_bumps = 0
    ui.native_pause_reason = nil
    if bumps > 0 then
        diag("modalIsolation.pause", {
            action = "release",
            status = "ok",
            reason = released_reason,
            bumps = bumps,
        })
    end
    return true
end

local function resolve_player_ability_system(player)
    player = unwrap(player)
    if not valid(player) then return nil end

    local ok_field, field_value = pcall(function() return unwrap(player.AbilitySystemComponent) end)
    if ok_field and valid(field_value) then return field_value end

    local ok_library, library = pcall(function()
        return unwrap(StaticFindObject("/Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary"))
    end)
    if ok_library and valid(library) and library["GetAbilitySystemComponent"] ~= nil then
        local ok_get, asc = pcall(function()
            return unwrap(library:GetAbilitySystemComponent(player))
        end)
        if ok_get and valid(asc) then return asc end
    end
    return nil
end

local function remove_native_modal_effect(asc, entry, reason)
    asc = unwrap(asc)
    if not valid(asc) or type(entry) ~= "table" then return false end
    local handle_id = tonumber(entry.id)
    if handle_id == nil or handle_id < 0 or asc["RemoveActiveGameplayEffect"] == nil then return false end

    -- Copy the returned handle into a fresh Lua struct table. UE4SS supports Lua
    -- tables for reflected struct parameters; retaining a temporary UFunction
    -- return wrapper across the whole UI session would be a less reliable owner.
    local ok_remove, removed = pcall(function()
        return unwrap(asc:RemoveActiveGameplayEffect({
            Handle = handle_id,
            bPassedFiltersAndWasExecuted = entry.passed ~= false,
        }, 1))
    end)
    local success = ok_remove and removed ~= false
    diag("modalIsolation.effectRemove", {
        key = entry.key,
        handle = handle_id,
        status = success and "ok" or "failed",
        result = removed,
        reason = reason,
    })
    return success
end

local native_menu_query = ModUI.Runtime.Observation.MenuQuery

local function probe_native_menu_blocks(handler, stage)
    local map_ok, map_allowed, map_error = native_menu_query(handler, "MapMenuQuery")
    local options_ok, options_allowed, options_error = native_menu_query(handler, "OptionsMenuQuery")
    local map_allowed_diag = "<unknown>"
    local options_allowed_diag = "<unknown>"
    if map_ok then map_allowed_diag = map_allowed end
    if options_ok then options_allowed_diag = options_allowed end
    diag("modalIsolation.menuProbe", {
        stage = stage,
        mapProbe = map_ok,
        mapAllowed = map_allowed_diag,
        mapError = map_error,
        optionsProbe = options_ok,
        optionsAllowed = options_allowed_diag,
        optionsError = options_error,
    })
    return map_ok and map_allowed == false, options_ok and options_allowed == false, map_ok, options_ok
end

local function retry_pending_native_modal_cleanup(player, reason)
    local pending = ui.native_modal_pending_cleanup
    if type(pending) ~= "table" then return true end

    local pending_asc = unwrap(pending.asc)
    local current_asc = resolve_player_ability_system(player)
    if not valid(pending_asc) or not valid(current_asc) or not same_object(pending_asc, current_asc) then
        diag("modalIsolation.cleanupRetry", {
            status = "scope-changed",
            pending = type(pending.handles) == "table" and #pending.handles or 0,
            reason = tostring(reason or "retry"),
        })
        ui.native_modal_pending_cleanup = nil
        return false
    end

    local remaining = {}
    local handles = type(pending.handles) == "table" and pending.handles or {}
    for index = #handles, 1, -1 do
        local entry = handles[index]
        if not remove_native_modal_effect(current_asc, entry, tostring(reason or "retry") .. " pending cleanup") then
            table.insert(remaining, 1, entry)
        end
    end

    if #remaining == 0 then
        ui.native_modal_pending_cleanup = nil
        diag("modalIsolation.cleanupRetry", {
            status = "recovered",
            attempted = #handles,
            remaining = 0,
            reason = tostring(reason or "retry"),
        })
        return true
    end

    pending.handles = remaining
    diag("modalIsolation.cleanupRetry", {
        status = "still-pending",
        attempted = #handles,
        remaining = #remaining,
        reason = tostring(reason or "retry"),
    })
    return false
end

local function release_native_modal_isolation(reason)
    reason = tostring(reason or "settings close")
    release_native_gameplay_pause()

    local asc = unwrap(ui.native_modal_asc)
    local handles = type(ui.native_modal_handles) == "table" and ui.native_modal_handles or {}
    local removed = 0
    local failed = {}
    for index = #handles, 1, -1 do
        local entry = handles[index]
        if remove_native_modal_effect(asc, entry, reason) then
            removed = removed + 1
        else
            table.insert(failed, 1, entry)
        end
    end

    if #failed > 0 and valid(asc) then
        ui.native_modal_pending_cleanup = {
            asc = asc,
            handles = failed,
            generation = tonumber(ui.active_generation) or 0,
        }
    elseif #failed == 0 then
        ui.native_modal_pending_cleanup = nil
    end

    diag("modalIsolation.release", {
        reason = reason,
        mode = ui.native_modal_mode,
        owned = #handles,
        removed = removed,
        failed = #failed,
        retryPending = #failed > 0,
    })

    local handler = unwrap(ui.native_modal_handler)
    if valid(handler) then
        local post_map_ok, post_map_allowed, post_map_error = native_menu_query(handler, "MapMenuQuery")
        local post_options_ok, post_options_allowed, post_options_error = native_menu_query(handler, "OptionsMenuQuery")
        local expected_map = ui.native_modal_pre_map_allowed
        local expected_options = ui.native_modal_pre_options_allowed
        local restored = (#failed == 0)
            and (expected_map ~= true or (post_map_ok and post_map_allowed == true))
            and (expected_options ~= true or (post_options_ok and post_options_allowed == true))
        diag("modalIsolation.postReleaseProbe", {
            status = restored and "restored" or "mismatch",
            expectedMap = expected_map ~= nil and expected_map or "<unknown>",
            postMap = post_map_ok and tostring(post_map_allowed) or "<unknown>",
            postMapError = post_map_error,
            expectedOptions = expected_options ~= nil and expected_options or "<unknown>",
            postOptions = post_options_ok and tostring(post_options_allowed) or "<unknown>",
            postOptionsError = post_options_error,
            failed = #failed,
        })
        if not restored then
            log("native modal isolation post-release mismatch"
                .. " expectedMap=" .. tostring(expected_map)
                .. " postMap=" .. (post_map_ok and tostring(post_map_allowed) or "<unknown>")
                .. " expectedOptions=" .. tostring(expected_options)
                .. " postOptions=" .. (post_options_ok and tostring(post_options_allowed) or "<unknown>")
                .. " failedHandles=" .. tostring(#failed))
        end
    end

    ui.native_modal_handler = nil
    ui.native_modal_asc = nil
    ui.native_modal_handles = {}
    ui.native_modal_isolation = false
    ui.native_modal_mode = "none"
    ui.native_menu_block_verified = false
    ui.native_modal_pre_map_allowed = nil
    ui.native_modal_pre_options_allowed = nil
end

local function acquire_native_modal_isolation(player, handler)
    player = unwrap(player)
    handler = unwrap(handler)
    if ui.native_modal_isolation then return true end

    local asc = resolve_player_ability_system(player)
    if not valid(asc) then
        log("native modal isolation unavailable: player AbilitySystemComponent was invalid")
        diag("modalIsolation.acquire", { status = "asc-unavailable" })
        return false
    end

    -- These are the exact effects used by Mortal Shell's own player/UI helper
    -- library. Keeping each returned ActiveGameplayEffectHandle lets TTS remove
    -- only its own instances instead of clearing a global tag shared with the game.
    local specs = {
        {
            key = "game_menu",
            asset = "/Game/Sparta/Core/Effects/GE_BlockGameMenu",
            class = "/Game/Sparta/Core/Effects/GE_BlockGameMenu.GE_BlockGameMenu_C",
        },
        {
            -- ObjectDump/BPFL_Player exposes this exact blocker for ordinary player
            -- interaction. Keep the returned handle TTS-owned so E / Cross cannot
            -- activate nearby world interactables while Settings owns Confirm.
            key = "interact",
            asset = "/Game/Sparta/Core/Effects/GE_Block_Interact",
            class = "/Game/Sparta/Core/Effects/GE_Block_Interact.GE_Block_Interact_C",
        },
        {
            key = "movement",
            asset = "/Game/Sparta/Core/Effects/GE_BlockPlayerMovement",
            class = "/Game/Sparta/Core/Effects/GE_BlockPlayerMovement.GE_BlockPlayerMovement_C",
        },
        {
            key = "camera",
            asset = "/Game/Sparta/Core/Effects/GE_BlockPlayerCamera",
            class = "/Game/Sparta/Core/Effects/GE_BlockPlayerCamera.GE_BlockPlayerCamera_C",
        },
        {
            key = "abilities",
            asset = "/Game/Sparta/Core/Effects/GE_BlockPlayerAbilities",
            class = "/Game/Sparta/Core/Effects/GE_BlockPlayerAbilities.GE_BlockPlayerAbilities_C",
        },
    }

    ui.native_modal_handler = handler
    ui.native_modal_asc = asc
    ui.native_modal_handles = {}
    ui.native_modal_isolation = false
    ui.native_modal_mode = "acquiring"
    ui.native_menu_block_verified = false

    local pre_map_ok, pre_map_allowed = native_menu_query(handler, "MapMenuQuery")
    local pre_options_ok, pre_options_allowed = native_menu_query(handler, "OptionsMenuQuery")
    ui.native_modal_pre_map_allowed = nil
    ui.native_modal_pre_options_allowed = nil
    if pre_map_ok then ui.native_modal_pre_map_allowed = pre_map_allowed end
    if pre_options_ok then ui.native_modal_pre_options_allowed = pre_options_allowed end
    diag("modalIsolation.preAcquireProbe", {
        mapAllowed = pre_map_ok and tostring(pre_map_allowed) or "<unknown>",
        optionsAllowed = pre_options_ok and tostring(pre_options_allowed) or "<unknown>",
    })

    local failed_key = nil
    local failed_reason = nil
    for _, spec in ipairs(specs) do
        pcall(function() LoadAsset(spec.asset) end)
        local ok_class, effect_class = pcall(function() return unwrap(StaticFindObject(spec.class)) end)
        if not ok_class or not valid(effect_class) then
            failed_key = spec.key
            failed_reason = "effect-class-unavailable"
            break
        end

        local ok_context, context = pcall(function() return unwrap(asc:MakeEffectContext()) end)
        if not ok_context or context == nil then
            failed_key = spec.key
            failed_reason = "effect-context-failed: " .. tostring(context)
            break
        end

        local ok_apply, handle = pcall(function()
            return unwrap(asc:BP_ApplyGameplayEffectToSelf(effect_class, 1.0, context))
        end)
        local handle_id = ok_apply and tonumber(struct_field(handle, "Handle")) or nil
        local passed = ok_apply and struct_field(handle, "bPassedFiltersAndWasExecuted") or nil
        if not ok_apply or handle_id == nil or handle_id < 0 or passed == false then
            failed_key = spec.key
            failed_reason = not ok_apply and tostring(handle) or "invalid-active-effect-handle"
            break
        end

        ui.native_modal_handles[#ui.native_modal_handles + 1] = {
            key = spec.key,
            id = handle_id,
            passed = passed,
        }
        diag("modalIsolation.effectApply", {
            key = spec.key,
            handle = handle_id,
            passed = passed,
            status = "ok",
        })

        if spec.key == "game_menu" then
            local map_blocked, options_blocked, map_probed = probe_native_menu_blocks(handler, "after-game-menu-effect")
            ui.native_menu_block_verified = map_blocked
            if not map_probed or not map_blocked then
                failed_key = spec.key
                failed_reason = map_probed and "MapMenuQuery-remained-open" or "MapMenuQuery-probe-unavailable"
                break
            end
            if options_blocked then
                diag("modalIsolation.gameMenu", { status = "map-and-options-blocked" })
            end
        end
    end

    if failed_key == "game_menu" or #ui.native_modal_handles == 0 then
        log("native modal isolation unavailable: native game-menu block failed key="
            .. tostring(failed_key) .. " reason=" .. tostring(failed_reason))
        diag("modalIsolation.acquire", {
            status = "game-menu-block-failed",
            key = failed_key,
            reason = failed_reason,
        })
        release_native_modal_isolation("game-menu block acquisition failed")
        return false
    end

    if failed_key ~= nil then
        -- Keep the exact menu blocker (the D-pad/map fix), remove any partial
        -- player effects, and fall back to the already-proven balanced pause for
        -- combat isolation. This path is diagnostic compatibility, not primary.
        for index = #ui.native_modal_handles, 2, -1 do
            remove_native_modal_effect(asc, ui.native_modal_handles[index], "partial player block rollback")
            table.remove(ui.native_modal_handles, index)
        end
        if not pause_native_gameplay(handler, "compatibility-fallback") then
            log("native modal isolation unavailable: player effects failed and pause fallback could not be acquired")
            diag("modalIsolation.acquire", {
                status = "player-block-and-pause-failed",
                key = failed_key,
                reason = failed_reason,
            })
            release_native_modal_isolation("player isolation acquisition failed")
            return false
        end
        ui.native_modal_isolation = true
        ui.native_modal_mode = "exact-menu+balanced-pause-fallback"
        log("native modal isolation acquired mode=" .. ui.native_modal_mode
            .. " failedPlayerEffect=" .. tostring(failed_key)
            .. " reason=" .. tostring(failed_reason))
        diag("modalIsolation.acquire", {
            status = "fallback",
            mode = ui.native_modal_mode,
            ownedHandles = #ui.native_modal_handles,
            failedKey = failed_key,
            reason = failed_reason,
        })
        return true
    end

    ui.native_modal_isolation = true
    local pause_requested = config.pause_game_while_menu_open == true
    local pause_acquired = false
    if pause_requested then
        pause_acquired = pause_native_gameplay(handler, "user-option")
    end
    if pause_acquired then
        ui.native_modal_mode = "exact-gameplay-effects+user-pause"
    elseif pause_requested then
        ui.native_modal_mode = "exact-gameplay-effects-unpaused-pause-request-failed"
    else
        ui.native_modal_mode = "exact-gameplay-effects-unpaused"
    end
    log("native modal isolation acquired mode=" .. ui.native_modal_mode
        .. " ownedHandles=" .. tostring(#ui.native_modal_handles)
        .. " mapVerified=" .. tostring(ui.native_menu_block_verified)
        .. " pauseRequested=" .. tostring(pause_requested)
        .. " pauseBumps=" .. tostring(ui.native_pause_bumps))
    diag("modalIsolation.acquire", {
        status = pause_requested and not pause_acquired and "pause-request-failed" or "ok",
        mode = ui.native_modal_mode,
        ownedHandles = #ui.native_modal_handles,
        mapVerified = ui.native_menu_block_verified,
        pauseRequested = pause_requested,
        pauseBumps = ui.native_pause_bumps,
        pauseReason = ui.native_pause_reason,
    })
    return true
end


    return {
        PauseNativeGameplay = pause_native_gameplay,
        ReleaseNativeGameplayPause = release_native_gameplay_pause,
        ResolvePlayerAbilitySystem = resolve_player_ability_system,
        RemoveNativeModalEffect = remove_native_modal_effect,
        ProbeNativeMenuBlocks = probe_native_menu_blocks,
        RetryPendingNativeModalCleanup = retry_pending_native_modal_cleanup,
        ReleaseNativeModalIsolation = release_native_modal_isolation,
        AcquireNativeModalIsolation = acquire_native_modal_isolation,
    }
end

return M
