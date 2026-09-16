-- MortalShell2TTS UI.NativePresentation
-- Pass 164 extraction: consumer-local native presentation/fallback widget system.

local M = {}

function M.Bind(deps)
    deps = type(deps) == "table" and deps or {}
    local dd = assert(deps.dd, "UI.NativePresentation requires dd")
    local ui = assert(deps.ui, "UI.NativePresentation requires ui")
    local config = assert(deps.config, "UI.NativePresentation requires config")
    local unwrap = assert(deps.unwrap, "UI.NativePresentation requires unwrap")
    local valid = assert(deps.valid, "UI.NativePresentation requires valid")
    local object_name = assert(deps.object_name, "UI.NativePresentation requires object_name")
    local log = assert(deps.log, "UI.NativePresentation requires log")
    local diag = assert(deps.diag, "UI.NativePresentation requires diag")
    local trim = assert(deps.trim, "UI.NativePresentation requires trim")
    local clamp = assert(deps.clamp, "UI.NativePresentation requires clamp")
    local tabs = assert(deps.tabs, "UI.NativePresentation requires tabs")
    local row_description = assert(deps.row_description, "UI.NativePresentation requires row_description")
    local row_control_hint = assert(deps.row_control_hint, "UI.NativePresentation requires row_control_hint")
    local current_tab = assert(deps.current_tab, "UI.NativePresentation requires current_tab")
    local current_rows = assert(deps.current_rows, "UI.NativePresentation requires current_rows")
    local ellipsize_text = assert(deps.ellipsize_text, "UI.NativePresentation requires ellipsize_text")
    local row_value = assert(deps.row_value, "UI.NativePresentation requires row_value")
    local settings_tab_text = assert(deps.settings_tab_text, "UI.NativePresentation requires settings_tab_text")
    local settings_label_text = assert(deps.settings_label_text, "UI.NativePresentation requires settings_label_text")
    local settings_values_text = assert(deps.settings_values_text, "UI.NativePresentation requires settings_values_text")
    local read_modui_host_axis = deps.read_modui_host_axis
    local NATIVE_SETTINGS_ASSET = deps.NATIVE_SETTINGS_ASSET
    local NATIVE_SETTINGS_CLASS = deps.NATIVE_SETTINGS_CLASS
    local NATIVE_INPUT_LISTENER_ASSET = deps.NATIVE_INPUT_LISTENER_ASSET
    local NATIVE_INPUT_LISTENER_CLASS = deps.NATIVE_INPUT_LISTENER_CLASS
    local NATIVE_SETTING_INFO_PANEL_ASSET = deps.NATIVE_SETTING_INFO_PANEL_ASSET
    local NATIVE_SETTING_INFO_PANEL_CLASS = deps.NATIVE_SETTING_INFO_PANEL_CLASS
    local SETTINGS_PROMPT_WIDTH = deps.SETTINGS_PROMPT_WIDTH
    local SETTINGS_LIST_WIDTH = deps.SETTINGS_LIST_WIDTH
    local SETTINGS_VALUE_WIDTH = deps.SETTINGS_VALUE_WIDTH
    local SETTINGS_FALLBACK_LIST_WIDTH = deps.SETTINGS_FALLBACK_LIST_WIDTH
    local SETTINGS_INFO_WIDTH = deps.SETTINGS_INFO_WIDTH
    local SETTINGS_INFO_TEXT_WIDTH = deps.SETTINGS_INFO_TEXT_WIDTH
    local SETTINGS_LAYOUT = assert(deps.SETTINGS_LAYOUT, "UI.NativePresentation requires SETTINGS_LAYOUT")
    local SCALEBOX_STRETCH_USER_SPECIFIED = deps.SCALEBOX_STRETCH_USER_SPECIFIED
    local HALIGN_FILL = deps.HALIGN_FILL
    local HALIGN_LEFT = deps.HALIGN_LEFT
    local VALIGN_TOP = deps.VALIGN_TOP

local function native_widget_field(widget, field)
    widget = unwrap(widget)
    if not valid(widget) then return nil end
    local ok, value = pcall(function() return unwrap(widget[field]) end)
    if ok and valid(value) then return value end
    return nil
end

local function set_native_render_translation(widget, x, y)
    widget = unwrap(widget)
    if not valid(widget) then return false end
    local fn = widget["SetRenderTranslation"]
    if fn == nil then return false end
    -- UE4SS accepts a Lua table for simple reflected structs such as FVector2D.
    local ok = pcall(fn, widget, { X = tonumber(x) or 0.0, Y = tonumber(y) or 0.0 })
    return ok
end

local function native_widget_tree_find(widget, name)
    widget = unwrap(widget)
    if not valid(widget) then return nil end

    local tree = nil
    pcall(function() tree = unwrap(widget.WidgetTree) end)
    if not valid(tree) then return nil end

    local find = tree["FindWidget"]
    if find == nil then return nil end

    local ok, value = pcall(find, tree, FName(tostring(name)))
    value = unwrap(value)
    if ok and valid(value) then return value end
    return nil
end

local function set_native_text(widget, text, cache_key)
    widget = unwrap(widget)
    if not valid(widget) then return false end
    local rendered = tostring(text or "")
    local key = cache_key ~= nil and tostring(cache_key) or nil
    if key ~= nil and ui.render_text_cache[key] == rendered then
        ui.render_set_skips = (tonumber(ui.render_set_skips) or 0) + 1
        return true, true
    end

    local ok = pcall(function() widget:SetText(FText(rendered)) end)
    if ok then
        if key ~= nil then ui.render_text_cache[key] = rendered end
        ui.render_set_calls = (tonumber(ui.render_set_calls) or 0) + 1
    end
    return ok, false
end

local function native_widget_visible(widget)
    widget = unwrap(widget)
    if not valid(widget) then return false end
    local ok, value = pcall(function() return unwrap(widget:IsInViewport()) end)
    return ok and value == true
end

local function set_native_visibility(widget, visibility)
    widget = unwrap(widget)
    if not valid(widget) then return false end
    return pcall(function() widget:SetVisibility(visibility) end)
end

local function compact_reader_shell_for_safe_ui(widget)
    widget = unwrap(widget)
    if not valid(widget) then return false end

    -- These belong to the real multi-page lore-reader behavior, not to TTS settings.
    -- v0.9.20 proved collapsing them is safe; the crash occurred only when the first
    -- WBP_NB_Option was attached afterward. Keep the safe compacting improvement.
    local fields = {
        "Text_Page_Status",
        "ScaleBox_Page",
        "ReadTextPrompts",
        "ScaleBox_Prompts",
    }
    local collapsed = 0
    for _, field in ipairs(fields) do
        local child = native_widget_field(widget, field)
        if valid(child) and set_native_visibility(child, 1) then collapsed = collapsed + 1 end
    end
    log("native reader presentation compacted collapsed=" .. tostring(collapsed)
        .. " pageAndLorePrompts=true bodyMode=compact-text-list")
    return collapsed > 0
end

local function get_player_and_controller()
    local player, controller, resolution_error, resolution_source =
        dd.ModUI.Runtime.Resolve.PlayerController(FindFirstOf, FindAllOf)
    dd.player_controller_resolution_source = tostring(resolution_source or "unknown")
    dd.player_controller_resolution_error = resolution_error ~= nil and tostring(resolution_error) or ""
    return player, controller
end

-- Pass 136: Settings is a gameplay-only surface. The front-end has its own stable
-- BP_PlayerController_MainMenu_C / BP_MainMenuCharacter_C / UI handler and can report
-- permissive native menu queries even during shaders, credits and the title/start menu.
-- Stability is therefore not eligibility. Keep this decision primitive/name-based and
-- require Mortal Shell II's actual gameplay controller/player identities before any
-- borrowed Settings shell may be constructed.
function dd.evaluate_gameplay_context(player, controller, handler)
    player = unwrap(player)
    controller = unwrap(controller)
    handler = unwrap(handler)
    local identity = {
        playerName = valid(player) and object_name(player) or "",
        controllerName = valid(controller) and object_name(controller) or "",
        handlerName = valid(handler) and object_name(handler) or "",
    }
    local allowed, blockers, reason = dd.ModUI.Runtime.Admission.EvaluateGameplayContext(identity)
    return allowed == true, tostring(reason or ""), identity, blockers
end

function dd.evaluate_gameplay_controller_context(controller)
    controller = unwrap(controller)
    local identity = {
        controllerName = valid(controller) and object_name(controller) or "",
    }
    local allowed, blockers, reason = dd.ModUI.Runtime.Admission.EvaluateGameplayContext(identity)
    return allowed == true, tostring(reason or ""), identity, blockers
end

local function load_native_settings_class()
    -- LoadAsset is only called from the game-thread settings-toggle path.
    pcall(function() LoadAsset(NATIVE_SETTINGS_ASSET) end)

    local ok, value = pcall(function() return unwrap(StaticFindObject(NATIVE_SETTINGS_CLASS)) end)
    if ok and valid(value) then return value end
    return nil
end

local function load_native_input_listener_class()
    pcall(function() LoadAsset(NATIVE_INPUT_LISTENER_ASSET) end)
    local ok, value = pcall(function() return unwrap(StaticFindObject(NATIVE_INPUT_LISTENER_CLASS)) end)
    if ok and valid(value) then return value end
    return nil
end


local function load_native_widget_class(asset_path, class_path)
    pcall(function() LoadAsset(asset_path) end)
    local ok, value = pcall(function() return unwrap(StaticFindObject(class_path)) end)
    if ok and valid(value) then return value end
    return nil
end

local function create_native_child_widget(player, controller, library, asset_path, class_path)
    local class = load_native_widget_class(asset_path, class_path)
    if not valid(class) or not valid(library) then return nil, "class/library unavailable" end
    local create = library["Create"]
    if create == nil then return nil, "WidgetBlueprintLibrary.Create unavailable" end

    local ok, widget = pcall(create, library, player, class, controller)
    widget = unwrap(widget)
    if not ok or not valid(widget) then
        return nil, tostring(widget)
    end
    return widget, nil
end

local function selected_setting_details_text()
    local rows = current_rows()
    local row = rows[ui.selected]
    if row == nil then return current_tab().description or "" end

    if dd.voice_browser_active ~= nil and dd.voice_browser_active() then
        if row.kind ~= "voice_browser" or row.voice == nil then
            return "No voices match the current search and gender filter.\n\nType to search, use Left / Right to change gender, or Backspace to edit the search."
        end
        local voice = row.voice
        local parts = {
            "Engine: " .. (config.engine == "azure" and "Microsoft Azure" or "Windows Speech"),
            "Gender: " .. (trim(voice.gender) ~= "" and tostring(voice.gender) or "Unknown"),
            "Locale: " .. (trim(voice.locale) ~= "" and tostring(voice.locale) or "Unknown"),
            "Favorite: " .. (dd.is_voice_favorite(voice.value) and "Yes" or "No"),
        }
        local styles = type(voice.styles) == "table" and voice.styles or {}
        if #styles == 0 then
            parts[#parts + 1] = "Styles: N/A"
        else
            local shown = {}
            local limit = math.min(#styles, 12)
            for i = 1, limit do shown[#shown + 1] = tostring(styles[i]) end
            local suffix = #styles > limit and (" (+" .. tostring(#styles - limit) .. " more)") or ""
            parts[#parts + 1] = "Styles: " .. table.concat(shown, ", ") .. suffix
        end
        parts[#parts + 1] = "Pitch: " .. (voice.pitch_supported ~= false and "Supported" or "N/A")
        parts[#parts + 1] = ""
        if tostring(dd.voice_browser.chosen or ""):lower() == tostring(voice.value):lower() then
            parts[#parts + 1] = "Selected. Confirm / Enter / Cross again: preview"
        else
            parts[#parts + 1] = "Confirm / Enter / Cross: select"
        end
        parts[#parts + 1] = "Tab / Square: favorite"
        parts[#parts + 1] = "Left / Right: gender filter"
        parts[#parts + 1] = "Browse: Up / Down / Wheel"
        parts[#parts + 1] = "Page: PgUp / PgDn / RStick"
        parts[#parts + 1] = "Ctrl / Shift + Wheel: page"
        parts[#parts + 1] = "Home / End: first / last"
        parts[#parts + 1] = "Type: search | Backspace: erase"
        parts[#parts + 1] = "Delete: clear"
        parts[#parts + 1] = "Esc / Circle: close + apply"
        return table.concat(parts, "\n")
    end

    -- The right column is contextual help, not a second settings page. Keep its copy
    -- compact so the native setting font never has to wrap into the smoky edge.
    local parts = { row_description(row) }
    if row.kind ~= "action" and row.kind ~= "engine_info" then
        parts[#parts + 1] = ""
        parts[#parts + 1] = "Current: " .. tostring(row_value(row))
    end
    if (row.key == "menu_keybind" or row.key == "controller_menu_bind") and dd.binding_conflict_details ~= nil then
        local conflict_details = dd.binding_conflict_details(row.key == "menu_keybind" and "keyboard" or "controller")
        if trim(conflict_details) ~= "" then
            parts[#parts + 1] = ""
            parts[#parts + 1] = conflict_details
        end
    end
    if trim(ui.status or "") ~= "" then
        parts[#parts + 1] = ""
        parts[#parts + 1] = "Status: " .. ellipsize_text(ui.status, 54)
    end
    parts[#parts + 1] = ""
    parts[#parts + 1] = row_control_hint(row)
    return table.concat(parts, "\n")
end

-- v0.9.64 keeps the native SettingInfoPanel title/divider and the v0.9.63
-- bounded line-window description. The widened details column now also expands
-- the smoke panel horizontally, and the scrolling input paths remain content-only
-- mutations so the hard-won widget hierarchy/lifecycle stays untouched.
function dd.details_context_key()
    local row = current_rows()[ui.selected]
    if dd.controller_settings_active ~= nil and dd.controller_settings_active() then
        return "controller:" .. tostring(dd.controller_settings.Mode()) .. ":" .. tostring(row ~= nil and row.key or "panel")
    end
    if dd.voice_browser_active ~= nil and dd.voice_browser_active() and row ~= nil and row.voice ~= nil then
        return "voice-browser:" .. tostring(row.voice.value)
    end
    return tostring(ui.tab) .. ":" .. tostring(row ~= nil and row.key or "tab")
end

function dd.wrap_details_lines(value)
    local configured_width = SETTINGS_LAYOUT.INFO_WRAP_COLUMNS
    if (dd.voice_browser_active ~= nil and dd.voice_browser_active())
        or (dd.controller_settings_active ~= nil and dd.controller_settings_active()) then
        configured_width = SETTINGS_LAYOUT.BROWSER_INFO_WRAP_COLUMNS
    end
    return dd.ModUI.Settings.Details.WrapLines(value, configured_width)
end

function dd.details_view_text(full_text)
    local context = dd.details_context_key()
    if ui.details_scroll_context ~= context then
        ui.details_scroll_context = context
        ui.details_scroll_offset = 0
        ui.details_scroll_axis_accum = 0.0
    end

    local lines = dd.wrap_details_lines(full_text)
    if dd.voice_browser_active ~= nil and dd.voice_browser_active() then
        ui.details_scroll_offset = 0
        ui.details_scroll_max = 0
        ui.details_scroll_total_lines = #lines
        ui.details_scroll_axis_accum = 0.0
        return table.concat(lines, "\n")
    end
    local visible_total = math.max(4, math.floor(tonumber(SETTINGS_LAYOUT.INFO_VISIBLE_LINES) or 18))
    local shown, offset, max_offset, total_lines = dd.ModUI.Settings.Details.Window(
        lines,
        ui.details_scroll_offset,
        visible_total,
        function(current_offset, current_max)
            return string.format("[%d/%d  RStick / Wheel / PgUp/PgDn]", current_offset + 1, current_max + 1)
        end
    )
    ui.details_scroll_offset = offset
    ui.details_scroll_max = max_offset
    ui.details_scroll_total_lines = total_lines
    return shown
end

local function trace_reader_text_branch(widget)
    widget = unwrap(widget)
    if not valid(widget) then return nil, nil, nil, nil, nil, "", false end

    local body = native_widget_field(widget, "RTB_ReadText")
    local overlay_main = native_widget_field(widget, "Overlay_Main")
    local overlay_prompt = native_widget_field(widget, "Overlay_Prompt")
    local vb_data = native_widget_field(widget, "VB_Data")
    if not valid(body) or not valid(overlay_main) or not valid(overlay_prompt) or not valid(vb_data) then
        return overlay_main, overlay_prompt, vb_data, nil, nil, "<missing-reader-branch>", false
    end

    local chain = { object_name(body) }
    local read_scale_box = nil
    local read_size_box = nil
    local saw_vb_data = false
    local saw_overlay_prompt = false
    local reached_overlay_main = false
    local current = body

    for _ = 1, 10 do
        local ok_parent, parent = pcall(function() return unwrap(current:GetParent()) end)
        if not ok_parent or not valid(parent) then break end

        local name = object_name(parent)
        chain[#chain + 1] = name
        if name:find("ScaleBox_ReadText", 1, true) then read_scale_box = parent end
        if name:find("SizeBox_ReadText", 1, true) then read_size_box = parent end
        if name:find("VB_Data", 1, true) then saw_vb_data = true end
        if name:find("Overlay_Prompt", 1, true) then saw_overlay_prompt = true end
        if name:find("Overlay_Main", 1, true) then
            reached_overlay_main = true
            break
        end
        current = parent
    end

    local vb_parent_ok = false
    pcall(function()
        local parent = unwrap(vb_data:GetParent())
        vb_parent_ok = valid(parent) and object_name(parent):find("Overlay_Prompt", 1, true) ~= nil
    end)

    local chain_text = table.concat(chain, " > ")
    local recognized = reached_overlay_main and saw_vb_data and saw_overlay_prompt
        and vb_parent_ok and valid(read_size_box) and valid(read_scale_box)
    log("native reader text branch traced recognized=" .. tostring(recognized)
        .. " reachedOverlayMain=" .. tostring(reached_overlay_main)
        .. " sawOverlayPrompt=" .. tostring(saw_overlay_prompt)
        .. " vbDataDirectChildOfPrompt=" .. tostring(vb_parent_ok)
        .. " scaleBox=" .. tostring(valid(read_scale_box) and object_name(read_scale_box) or "<nil>")
        .. " sizeBox=" .. tostring(valid(read_size_box) and object_name(read_size_box) or "<nil>")
        .. " promptOverlay=" .. object_name(overlay_prompt)
        .. " chain=" .. chain_text)
    return overlay_main, overlay_prompt, vb_data, read_size_box, read_scale_box, chain_text, recognized
end

local function tune_setting_info_panel(details)
    details = unwrap(details)
    if not valid(details) then return false end

    -- Use the real settings typography/divider, but not its standalone bright card.
    -- Inside the lore-reader prompt we already have the dark smoky background.
    local background_collapsed = false
    local background = native_widget_field(details, "MyBackground")
    if valid(background) then
        background_collapsed = set_native_visibility(background, 1)
    end

    local image_collapsed = false
    local hide_image = details["HideImageWidget"]
    if hide_image ~= nil then pcall(hide_image, details) end
    local collapse_image = details["CollapseImagePanel"]
    if collapse_image ~= nil then image_collapsed = pcall(collapse_image, details) end
    local remove_video = details["RemoveVideo"]
    if remove_video ~= nil then pcall(remove_video, details) end

    -- Reinforce the text-only image collapse in case a native Build*/Construct path
    -- restores visibility after the first update.
    for _, field in ipairs({ "SizeBox_SettingImage", "ScaleBox_SettingImage", "Overlay_SettingImage", "SettingImage" }) do
        local child = native_widget_field(details, field)
        if valid(child) then set_native_visibility(child, 1) end
    end

    local size_data = native_widget_field(details, "SizeBox_Data")
    local size_description = native_widget_field(details, "SizeBox_Description")
    local size_setting_description = native_widget_field(details, "SizeBox_SettingDescription")
    local width_ok = false

    if valid(size_data) then
        width_ok = pcall(function()
            size_data:SetWidthOverride(SETTINGS_INFO_WIDTH)
            local set_min = size_data["SetMinDesiredWidth"]
            if set_min ~= nil then set_min(size_data, SETTINGS_INFO_WIDTH) end
        end)
    end

    -- The production SettingInfoPanel has RichSettingDescription nested below
    -- SizeBox_SettingDescription -> SizeBox_Description -> Overlay/VerticalBox slots.
    -- Width overrides alone left those slots at their native narrow alignment.
    -- Force the live description branch to consume the full text column.
    local description = native_widget_field(details, "RichSettingDescription")
    local chain_slots_filled = 0
    local chain_size_boxes_tuned = 0
    local chain_parts = {}
    if valid(description) then
        local current = description
        chain_parts[#chain_parts + 1] = object_name(current)
        for _ = 1, 10 do
            local slot = nil
            pcall(function() slot = unwrap(current.Slot) end)
            if valid(slot) then
                local set_h = slot["SetHorizontalAlignment"]
                local set_v = slot["SetVerticalAlignment"]
                local h_ok = false
                if set_h ~= nil then h_ok = pcall(set_h, slot, HALIGN_FILL) end
                if set_v ~= nil then pcall(set_v, slot, VALIGN_TOP) end
                if h_ok then chain_slots_filled = chain_slots_filled + 1 end
            end

            local name = object_name(current)
            if name:find("SizeBox", 1, true) then
                local tuned = pcall(function()
                    local clear_max_width = current["ClearMaxDesiredWidth"]
                    if clear_max_width ~= nil then clear_max_width(current) end
                    local set_width = current["SetWidthOverride"]
                    if set_width ~= nil then set_width(current, SETTINGS_INFO_TEXT_WIDTH) end
                    local set_min = current["SetMinDesiredWidth"]
                    if set_min ~= nil then set_min(current, SETTINGS_INFO_TEXT_WIDTH) end
                end)
                if tuned then chain_size_boxes_tuned = chain_size_boxes_tuned + 1 end
            end

            local ok_parent, parent = pcall(function() return unwrap(current:GetParent()) end)
            if not ok_parent or not valid(parent) then break end
            current = parent
            chain_parts[#chain_parts + 1] = object_name(current)
            if current == details then break end
        end
    end

    -- Keep the known description boxes explicitly synchronized as a second guard.
    for _, box in ipairs({ size_description, size_setting_description }) do
        if valid(box) then
            pcall(function()
                local clear_height = box["ClearHeightOverride"]
                if clear_height ~= nil then clear_height(box) end
                local clear_max_height = box["ClearMaxDesiredHeight"]
                if clear_max_height ~= nil then clear_max_height(box) end
                local clear_max_width = box["ClearMaxDesiredWidth"]
                if clear_max_width ~= nil then clear_max_width(box) end
                local set_width = box["SetWidthOverride"]
                if set_width ~= nil then set_width(box, SETTINGS_INFO_TEXT_WIDTH) end
                local set_min = box["SetMinDesiredWidth"]
                if set_min ~= nil then set_min(box, SETTINGS_INFO_TEXT_WIDTH) end
            end)
        end
    end

    local text_ok = false
    if valid(description) then
        text_ok = pcall(function()
            -- The ObjectDump confirms this exact RichSettingDescription is a plain
            -- UMG RichTextBlock, so MobileTextBlockScale is not a reliable native
            -- size control here. Keep the historical write for wrapper compatibility,
            -- but apply a real render scale at a top-left pivot so the right-hand copy
            -- is visibly smaller without changing its wrapping/allotted layout width.
            description.MobileTextBlockScale = SETTINGS_LAYOUT.INFO_TEXT_SCALE
            local set_pivot = description["SetRenderTransformPivot"]
            if set_pivot ~= nil then pcall(set_pivot, description, { X = 0.0, Y = 0.0 }) end
            local set_scale = description["SetRenderScale"]
            if set_scale ~= nil then
                pcall(set_scale, description, { X = SETTINGS_LAYOUT.INFO_RENDER_SCALE, Y = SETTINGS_LAYOUT.INFO_RENDER_SCALE })
            end
            description:SetAutoWrapText(false)
            -- With the parent chain forced to Fill, let AutoWrap use the actual
            -- allotted geometry instead of imposing another competing wrap width.
            description.WrapTextAt = 0.0
            description:SetJustification(0)
            local set_min = description["SetMinDesiredWidth"]
            if set_min ~= nil then set_min(description, SETTINGS_INFO_TEXT_WIDTH) end
            local refresh = description["RefreshTextLayout"]
            if refresh ~= nil then refresh(description) end
        end)
    end

    local offset_y = tonumber(SETTINGS_LAYOUT.INFO_CONTENT_OFFSET_Y) or 0.0
    local translated_parts = 0
    local name_branch = native_widget_tree_find(details, "ScaleBox_SettingName")
    if not valid(name_branch) then name_branch = native_widget_tree_find(details, "SizeBox_SettingName") end
    local description_branch = size_description
    if not valid(description_branch) then description_branch = size_setting_description end
    local divider = native_widget_tree_find(details, "Image_DescriptionDivider")

    for _, widget in ipairs({ name_branch, divider, description_branch }) do
        if valid(widget) and set_native_render_translation(widget, 0.0, offset_y) then
            translated_parts = translated_parts + 1
        end
    end

    log("native setting info panel tuned width=" .. tostring(SETTINGS_INFO_WIDTH)
        .. " textWidth=" .. tostring(SETTINGS_INFO_TEXT_WIDTH)
        .. " widthOk=" .. tostring(width_ok)
        .. " descriptionOk=" .. tostring(text_ok)
        .. " descriptionSlotsFilled=" .. tostring(chain_slots_filled)
        .. " descriptionSizeBoxesTuned=" .. tostring(chain_size_boxes_tuned)
        .. " backgroundCollapsed=" .. tostring(background_collapsed)
        .. " imageCollapsed=" .. tostring(image_collapsed)
        .. " contentOffsetY=" .. tostring(offset_y)
        .. " translatedParts=" .. tostring(translated_parts)
        .. " style=DT_TextStyle_SettingInfoPanel"
        .. " descriptionChain=" .. table.concat(chain_parts, " > "))
    return width_ok or text_ok
end

function dd.selected_setting_details_title()
    local rows = current_rows()
    local row = rows[ui.selected]
    local title = row ~= nil and tostring(row.label) or tostring(current_tab().label)
    if dd.voice_browser_active ~= nil and dd.voice_browser_active() and row ~= nil and row.voice ~= nil then
        title = ellipsize_text(tostring(row.voice.label or row.voice.value), 30)
    elseif dd.voice_browser_active ~= nil and dd.voice_browser_active() then
        title = "Voice Browser"
    end
    return title
end

local function update_native_details_panel()
    if not ui.open or not valid(ui.native_details_widget) then return false end

    local title = dd.selected_setting_details_title()
    local details_text = dd.details_view_text(selected_setting_details_text())

    local details = ui.native_details_widget
    local name_widget = native_widget_field(details, "SettingName")
    local description_widget = native_widget_field(details, "RichSettingDescription")
    local name_changed = ui.render_text_cache["details.name"] ~= title
    local description_changed = ui.render_text_cache["details.description"] ~= details_text

    -- Mirror the data fields used by the real options screen, but avoid invoking
    -- Update(HasData,Name,Description,Image,Video) from Lua because its soft-object
    -- arguments add no value for our text-only panel. Direct presentation fields
    -- keep the widget passive and avoid image/video construction paths.
    if name_changed or description_changed then
        pcall(function()
            if name_changed then details.MyName = FText(title) end
            if description_changed then details.MyDescription = FText(details_text) end
        end)
    end

    local name_ok = set_native_text(name_widget, title, "details.name")
    local description_ok = set_native_text(description_widget, details_text, "details.description")

    local build_name = details["BuildName"]
    if name_changed and build_name ~= nil then pcall(build_name, details) end

    -- Geometry/style stripping is initialization-only from v0.9.41 onward. Redraw
    -- mutates content only; repeatedly collapsing branches and refreshing layout
    -- on every selection change created needless Slate invalidation churn.
    return name_ok and description_ok
end


function dd.scroll_details(delta, source)
    if not ui.open or ui.closing or (ui.host_visible_shell ~= true and not valid(ui.native_details_widget)) then return false end
    delta = tonumber(delta) or 0
    if delta == 0 then return false end

    -- Refresh the context/max range before applying a scroll. This also resets to the
    -- top automatically when selection/tab changes.
    dd.details_view_text(selected_setting_details_text())
    local old = tonumber(ui.details_scroll_offset) or 0
    local max_offset = tonumber(ui.details_scroll_max) or 0
    if max_offset <= 0 then return false end
    local next_offset = clamp(old + delta, 0, max_offset)
    if next_offset == old then return false end

    ui.details_scroll_offset = next_offset
    local ok = ui.host_visible_shell == true and type(dd.set_ui_text) == "function" and dd.set_ui_text() or update_native_details_panel()
    diag("input.detailsScroll", {
        source = tostring(source or "unknown"),
        delta = delta,
        offsetBefore = old,
        offsetAfter = next_offset,
        maxOffset = max_offset,
        totalLines = tonumber(ui.details_scroll_total_lines) or 0,
        updateOk = ok,
    })
    return true
end

function dd.mouse_pointer_in_details(pointer_override)
    if dd.mouse_screen_position == nil and type(pointer_override) ~= "table" then return false, nil end
    local pointer = type(pointer_override) == "table" and pointer_override or dd.mouse_screen_position()
    if pointer == nil then return false, nil end
    local x = tonumber(pointer.reference_x) or -1
    local y = tonumber(pointer.reference_y) or -1
    local browser = dd.voice_browser_active ~= nil and dd.voice_browser_active()
    local controller_panel = dd.controller_settings_active ~= nil and dd.controller_settings_active()
    local wide_profile = browser or controller_panel
    local resolved = type(dd.UILayout) == "table" and type(dd.UILayout.ResolveAdaptive) == "function"
        and dd.UILayout.ResolveAdaptive(wide_profile and "browser" or "main", settings_label_text(), settings_values_text()) or nil
    local pointer = resolved and resolved.pointer or nil
    local left = pointer and pointer.detailsLeft or (wide_profile and SETTINGS_LAYOUT.BROWSER_DETAILS_HIT_LEFT or SETTINGS_LAYOUT.DETAILS_HIT_LEFT)
    local right = pointer and pointer.detailsRight or (wide_profile and SETTINGS_LAYOUT.BROWSER_DETAILS_HIT_RIGHT or SETTINGS_LAYOUT.DETAILS_HIT_RIGHT)
    local top = pointer and pointer.detailsTop or (wide_profile and SETTINGS_LAYOUT.BROWSER_DETAILS_HIT_TOP or SETTINGS_LAYOUT.DETAILS_HIT_TOP)
    local bottom = pointer and pointer.detailsBottom or (wide_profile and SETTINGS_LAYOUT.BROWSER_DETAILS_HIT_BOTTOM or SETTINGS_LAYOUT.DETAILS_HIT_BOTTOM)
    local inside = x >= left and x < right and y >= top and y < bottom
    return inside, pointer
end

local function filtered_right_y(raw)
    raw = tonumber(raw)
    if raw == nil then return nil end
    local profile = dd.ModUI and dd.ModUI.Controller and dd.ModUI.Controller.Profile or nil
    if type(profile) == "table" and type(profile.NormalizeAxis) == "function" then
        local current = type(dd.current_modui_controller_profile) == "function"
            and select(1, dd.current_modui_controller_profile(false))
            or (type(profile.Current) == "function" and profile.Current() or nil)
        local ok, value = pcall(profile.NormalizeAxis, "Gamepad_RightY", raw, current)
        if ok and tonumber(value) ~= nil then return tonumber(value) end
    end
    return raw
end

function dd.right_stick_y(controller)
    -- Pass 176: prefer the shared ModUI host mailbox and apply the shared calibrated
    -- deadzone/range before Voice Browser/details consume RightY. The host publishes the
    -- coherent analog sample used by every consumer, so no duplicate physical polling is added.
    if type(read_modui_host_axis) == "function" then
        local host_value, host_source, host_ready = read_modui_host_axis("Gamepad_RightY")
        if host_ready == true and tonumber(host_value) ~= nil then
            return filtered_right_y(host_value), "ModUIHost:" .. tostring(host_source or "Gamepad_RightY") .. ":filtered"
        end
    end

    controller = unwrap(controller)
    if not valid(controller) then return nil, "controller-invalid" end

    local direct, direct_error = dd.input_analog_value(controller, "Gamepad_RightY")

    -- If the direct analog API is finite, it is authoritative even when near zero.
    -- Pass 175's runtime log proved that falling through from a small/neutral analog value
    -- to digital RightStick Up/Down can synthesize an opposite +/-1 springback page.
    -- We still consult GetInputAnalogStickState when direct is effectively zero, because
    -- older runtime branches sometimes exposed movement only through that paired API.
    if dd.finite_number(direct) then
        if math.abs(direct) < 0.001 then
            local get_stick = controller["GetInputAnalogStickState"]
            if get_stick ~= nil then
                local x_out, y_out = {}, {}
                local ok_stick = pcall(function() controller:GetInputAnalogStickState(1, x_out, y_out) end)
                if ok_stick then
                    local y = dd.output_number(y_out, { "StickY", "Y", "Value" })
                    if dd.finite_number(y) and math.abs(y) >= 0.001 then
                        return filtered_right_y(y), "GetInputAnalogStickState:filtered"
                    end
                end
            end
        end
        return filtered_right_y(direct), "Gamepad_RightY:filtered"
    end

    -- Only synthesize digital +/-1 when analog APIs are actually unavailable, not merely
    -- centered. This retains the old emergency fallback without turning springback into a
    -- full-strength opposite page when a valid analog source says neutral.
    local up = select(1, dd.input_key_down(controller, "Gamepad_RightStick_Up"))
    local down = select(1, dd.input_key_down(controller, "Gamepad_RightStick_Down"))
    -- Preserve the same raw-sign convention as Gamepad_RightY: physical Up is raw
    -- negative and Down is raw positive. The labels are human-facing, not a reason to
    -- change the serialized/raw axis convention used elsewhere.
    if up == true and down ~= true then return filtered_right_y(-1.0), "Gamepad_RightStick_Up:fallback-filtered" end
    if down == true and up ~= true then return filtered_right_y(1.0), "Gamepad_RightStick_Down:fallback-filtered" end
    return nil, tostring(direct_error or "right-stick-unavailable")
end

function dd.update_details_analog_scroll(controller)
    if not ui.open or ui.closing
        or (dd.bind_capture_active ~= nil and dd.bind_capture_active())
        or (dd.controller_settings_active ~= nil and dd.controller_settings_active()) then
        ui.details_scroll_axis_accum = 0.0
        return false
    end
    local value, axis_source = dd.right_stick_y(controller)
    value = tonumber(value)
    if value == nil then return false end

    local magnitude = math.abs(value)

    if dd.voice_browser_active ~= nil and dd.voice_browser_active() then
        -- Browser right-stick paging now behaves like keyboard key-repeat instead of
        -- requiring a neutral re-arm after every page. A fresh >=70% tilt moves one
        -- page immediately, waits ~400 ms, then repeats every ~150 ms while held.
        -- This cadence stays well below the v0.9.72 full-redraw hammer that froze the
        -- game, while still allowing deliberate fast traversal through long catalogs.
        local state = dd.voice_browser
        ui.details_scroll_axis_accum = 0.0
        local release_threshold = 0.35
        local trigger_threshold = 0.70
        if magnitude < release_threshold then
            state.right_page_hold_direction = 0
            state.right_page_hold_ticks = 0
            state.right_page_neutral_seen = true
            state.right_page_springback_logged = false
            return false
        end

        local step = value > 0 and 1 or -1
        if state.right_page_hold_direction ~= 0 and step ~= state.right_page_hold_direction
            and state.right_page_neutral_seen ~= true then
            if state.right_page_springback_logged ~= true then
                state.right_page_springback_logged = true
                diag("voice.browser", {
                    action = "right-stick-springback-suppressed",
                    direction = step > 0 and "down" or "up",
                    source = tostring(axis_source), value = value,
                })
            end
            return false
        end
        if magnitude < trigger_threshold then return false end
        if state.right_page_hold_direction == 0 and state.right_page_neutral_seen ~= true then return false end
        if state.right_page_hold_direction == 0 then state.right_page_neutral_seen = false end

        local direction, ticks, first_fire, repeat_fire = dd.ModUI.Input.Repeat.AdvanceDirectional(
            state.right_page_hold_direction, state.right_page_hold_ticks, step, true, 8, 3
        )
        state.right_page_hold_direction = direction
        state.right_page_hold_ticks = ticks

        if first_fire then
            dd.voice_browser_page(step)
            diag("voice.browser", {
                action = "right-stick-page-first",
                direction = step > 0 and "down" or "up",
                source = tostring(axis_source),
                value = value,
            })
            return true
        end

        if repeat_fire then
            dd.voice_browser_page(step)
            diag("voice.browser", {
                action = "right-stick-page-repeat",
                direction = step > 0 and "down" or "up",
                source = tostring(axis_source),
                value = value,
                ticks = ticks,
            })
            return true
        end
        return false
    end

    if magnitude < 0.30 then
        ui.details_scroll_axis_accum = 0.0
        return false
    end

    -- v0.9.70 intentionally uses camera/content-style scrolling: pushing the right
    -- stick forward/up moves farther down through the description, while pulling it
    -- back/down moves upward. Accumulation keeps movement smooth one line at a time.
    if ui.details_scroll_axis_source ~= axis_source then
        ui.details_scroll_axis_source = axis_source
        diag("input.detailsAnalog", { source = tostring(axis_source), value = value, status = "active" })
    end

    local strength = clamp((magnitude - 0.30) / 0.70, 0.0, 1.0)
    local direction = value > 0 and 1 or -1
    ui.details_scroll_axis_accum = (tonumber(ui.details_scroll_axis_accum) or 0.0)
        + direction * (0.16 + 0.16 * strength)

    local moved = false
    while math.abs(ui.details_scroll_axis_accum) >= 1.0 do
        local step = ui.details_scroll_axis_accum > 0 and 1 or -1
        if dd.scroll_details(step, "right-stick") then moved = true end
        ui.details_scroll_axis_accum = ui.details_scroll_axis_accum - step
        if not moved and ((step > 0 and ui.details_scroll_offset >= ui.details_scroll_max)
            or (step < 0 and ui.details_scroll_offset <= 0)) then
            ui.details_scroll_axis_accum = 0.0
            break
        end
    end
    return moved
end

local function tune_native_values_panel(panel, source_body, rail_width)
    panel = unwrap(panel)
    source_body = unwrap(source_body)
    if not valid(panel) or not valid(source_body) then return false end
    rail_width = tonumber(rail_width) or SETTINGS_VALUE_WIDTH

    local collapsed = 0
    local function collapse(widget)
        if valid(widget) and set_native_visibility(widget, 1) then
            collapsed = collapsed + 1
        end
    end

    -- This second SettingInfoPanel is only a safe cooked host for one RichTextBlock.
    -- Strip every piece of settings-card chrome so it becomes a passive value rail.
    collapse(native_widget_field(panel, "MyBackground"))
    collapse(native_widget_field(panel, "SettingName"))
    collapse(native_widget_field(panel, "SizeBox_SettingImage"))
    collapse(native_widget_field(panel, "ScaleBox_SettingImage"))
    collapse(native_widget_field(panel, "Overlay_SettingImage"))
    collapse(native_widget_field(panel, "SettingImage"))

    for _, name in ipairs({
        "ScaleBox_SettingName",
        "SizeBox_SettingName",
        "Image_DescriptionDivider",
        "Spacer",
        "Spacer_170",
    }) do
        collapse(native_widget_tree_find(panel, name))
    end

    local hide_image = panel["HideImageWidget"]
    if hide_image ~= nil then pcall(hide_image, panel) end
    local collapse_image = panel["CollapseImagePanel"]
    if collapse_image ~= nil then pcall(collapse_image, panel) end
    local remove_video = panel["RemoveVideo"]
    if remove_video ~= nil then pcall(remove_video, panel) end

    local description = native_widget_field(panel, "RichSettingDescription")
    if not valid(description) then
        log("native passive text rail unavailable: RichSettingDescription missing")
        return false
    end

    local source_style = nil
    local source_common_style = nil
    pcall(function() source_style = unwrap(source_body:GetTextStyleSet()) end)
    pcall(function() source_common_style = unwrap(source_body.DefaultTextStyleOverrideClass) end)

    local style_ok = false
    pcall(function()
        description:ClearAllDefaultStyleOverrides()
        description.bOverrideDefaultStyle = false
    end)
    if valid(source_style) then
        style_ok = pcall(function() description:SetTextStyleSet(source_style) end)
    end
    if valid(source_common_style) then
        local common_ok = pcall(function() description:SetStyle(source_common_style) end)
        style_ok = style_ok or common_ok
    end

    local slots_filled = 0
    local size_boxes_tuned = 0
    local chain = {}
    local current = description
    for _ = 1, 10 do
        chain[#chain + 1] = object_name(current)

        local slot = nil
        pcall(function() slot = unwrap(current.Slot) end)
        if valid(slot) then
            local set_h = slot["SetHorizontalAlignment"]
            local set_v = slot["SetVerticalAlignment"]
            if set_h ~= nil and pcall(set_h, slot, HALIGN_FILL) then
                slots_filled = slots_filled + 1
            end
            if set_v ~= nil then pcall(set_v, slot, VALIGN_TOP) end
        end

        if object_name(current):find("SizeBox", 1, true) then
            local ok = pcall(function()
                local clear_max = current["ClearMaxDesiredWidth"]
                if clear_max ~= nil then clear_max(current) end
                local set_width = current["SetWidthOverride"]
                if set_width ~= nil then set_width(current, rail_width) end
                local set_min = current["SetMinDesiredWidth"]
                if set_min ~= nil then set_min(current, rail_width) end
            end)
            if ok then size_boxes_tuned = size_boxes_tuned + 1 end
        end

        local ok_parent, parent = pcall(function() return unwrap(current:GetParent()) end)
        if not ok_parent or not valid(parent) then break end
        current = parent
    end

    local text_ok = pcall(function()
        description.MobileTextBlockScale = 1.0
        description:SetAutoWrapText(false)
        description.WrapTextAt = 0.0
        description:SetJustification(0)
        local set_min = description["SetMinDesiredWidth"]
        if set_min ~= nil then set_min(description, rail_width) end
        local refresh = description["RefreshTextLayout"]
        if refresh ~= nil then refresh(description) end
    end)

    local size_data = native_widget_field(panel, "SizeBox_Data")
    if valid(size_data) then
        pcall(function()
            size_data:SetWidthOverride(rail_width)
            local set_min = size_data["SetMinDesiredWidth"]
            if set_min ~= nil then set_min(size_data, rail_width) end
        end)
    end

    log("native passive text rail tuned width=" .. tostring(rail_width)
        .. " styleOk=" .. tostring(style_ok)
        .. " textOk=" .. tostring(text_ok)
        .. " chromeCollapsed=" .. tostring(collapsed)
        .. " slotsFilled=" .. tostring(slots_filled)
        .. " sizeBoxesTuned=" .. tostring(size_boxes_tuned)
        .. " chain=" .. table.concat(chain, " > "))
    return text_ok
end

function dd.set_dynamic_info_width(panel, panel_width, text_width)
    panel = unwrap(panel)
    if not valid(panel) then return false end
    panel_width = tonumber(panel_width) or SETTINGS_INFO_WIDTH
    text_width = tonumber(text_width) or SETTINGS_INFO_TEXT_WIDTH
    local size_data = native_widget_field(panel, "SizeBox_Data")
    if valid(size_data) then
        pcall(function()
            size_data:SetWidthOverride(panel_width)
            local set_min = size_data["SetMinDesiredWidth"]
            if set_min ~= nil then set_min(size_data, panel_width) end
        end)
    end
    local description = native_widget_field(panel, "RichSettingDescription")
    if valid(description) then
        local current = description
        for _ = 1, 10 do
            if object_name(current):find("SizeBox", 1, true) then
                pcall(function()
                    local clear_max = current["ClearMaxDesiredWidth"]
                    if clear_max ~= nil then clear_max(current) end
                    local set_width = current["SetWidthOverride"]
                    if set_width ~= nil then set_width(current, text_width) end
                    local set_min = current["SetMinDesiredWidth"]
                    if set_min ~= nil then set_min(current, text_width) end
                end)
            end
            local ok_parent, parent = pcall(function() return unwrap(current:GetParent()) end)
            if not ok_parent or not valid(parent) or parent == panel then break end
            current = parent
        end
        pcall(function()
            local set_min = description["SetMinDesiredWidth"]
            if set_min ~= nil then set_min(description, text_width) end
            description.WrapTextAt = 0.0
            local refresh = description["RefreshTextLayout"]
            if refresh ~= nil then refresh(description) end
        end)
    end
    return true
end

-- Metadata-only display observation for release validation. This records the actual
-- viewport/DPI profile seen when the main/browser window profile is applied; it does
-- not record pointer coordinates, user paths, narration text, or other personal data.
function dd.log_window_viewport(profile_name)
    local context = unwrap(ui.controller)
    if not valid(context) then context = unwrap(ui.widget) end
    if not valid(context) then return false end
    local ok_layout, layout = pcall(function()
        return unwrap(StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary"))
    end)
    if not ok_layout or not valid(layout) then return false end
    local ok_size, viewport = pcall(function() return layout:GetViewportSize(context) end)
    if not ok_size or viewport == nil then return false end
    local width = dd.direct_struct_number(viewport, { "X", "Width" })
    local height = dd.direct_struct_number(viewport, { "Y", "Height" })
    if not dd.finite_number(width) or not dd.finite_number(height) or width <= 0 or height <= 0 then return false end
    local scale = 1.0
    pcall(function()
        local candidate = tonumber(unwrap(layout:GetViewportScale(context)))
        if dd.finite_number(candidate) and candidate > 0.0 then scale = candidate end
    end)
    diag("renderer.viewport", {
        profile = tostring(profile_name or "main"),
        width = math.floor(width + 0.5),
        height = math.floor(height + 0.5),
        scale = string.format("%.3f", scale),
        logicalWidth = math.floor((width / scale) + 0.5),
        logicalHeight = math.floor((height / scale) + 0.5),
    })
    return true
end

function dd.apply_window_profile(profile_name, force)
    if not ui.open or ui.closing or (ui.host_visible_shell ~= true and not valid(ui.widget)) then return false end
    profile_name = profile_name == "browser" and "browser" or "main"
    local resolved = type(dd.UILayout) == "table" and type(dd.UILayout.ResolveAdaptive) == "function"
        and dd.UILayout.ResolveAdaptive(profile_name, settings_label_text(), settings_values_text()) or nil
    local layout_signature = resolved and tostring(resolved.signature or profile_name) or profile_name
    if ui.window_profile == profile_name and tostring(ui.local_layout_signature or "") == layout_signature and force ~= true then return true end
    if ui.host_visible_shell == true then
        ui.window_profile = profile_name
        ui.local_layout_signature = layout_signature
        ui.render_text_cache = {}
        diag("renderer.profile", { profile = profile_name, owner = "MortalShell2ModUI.Host.ShellService", status = "presentation-republish", layoutSignature = layout_signature })
        if type(dd.set_ui_text) == "function" then return dd.set_ui_text() end
        return true
    end
    local browser = profile_name == "browser"
    local prompt_width = resolved and resolved.promptWidth or (browser and SETTINGS_LAYOUT.BROWSER_PROMPT_WIDTH or SETTINGS_PROMPT_WIDTH)
    local prompt_height = resolved and resolved.promptHeight or (browser and SETTINGS_LAYOUT.BROWSER_PROMPT_HEIGHT or SETTINGS_LAYOUT.PROMPT_HEIGHT)
    local tab_width = resolved and resolved.tabWidth or (browser and SETTINGS_LAYOUT.BROWSER_TAB_WIDTH or SETTINGS_FALLBACK_LIST_WIDTH)
    local list_width = resolved and resolved.labelWidth or (browser and SETTINGS_LAYOUT.BROWSER_LIST_WIDTH or SETTINGS_LIST_WIDTH)
    local value_width = resolved and resolved.valueWidth or (browser and SETTINGS_LAYOUT.BROWSER_VALUE_WIDTH or SETTINGS_VALUE_WIDTH)
    local info_width = resolved and resolved.infoWidth or (browser and SETTINGS_LAYOUT.BROWSER_INFO_WIDTH or SETTINGS_INFO_WIDTH)
    local info_text_width = resolved and resolved.infoTextWidth or (browser and SETTINGS_LAYOUT.BROWSER_INFO_TEXT_WIDTH or SETTINGS_INFO_TEXT_WIDTH)
    local safe_left = resolved and resolved.safeLeft or (browser and SETTINGS_LAYOUT.BROWSER_SAFE_LEFT or SETTINGS_LAYOUT.SAFE_LEFT)
    local tab_top = resolved and resolved.tabTop or (browser and SETTINGS_LAYOUT.BROWSER_TAB_TOP or SETTINGS_LAYOUT.TAB_TOP)
    local rows_top = resolved and resolved.rowsTop or (browser and SETTINGS_LAYOUT.BROWSER_ROWS_TOP or SETTINGS_LAYOUT.ROWS_TOP)
    local value_left = resolved and resolved.valueLeft or (browser and SETTINGS_LAYOUT.BROWSER_VALUE_LEFT or SETTINGS_LAYOUT.VALUE_LEFT)
    local info_left = resolved and resolved.infoLeft or (browser and SETTINGS_LAYOUT.BROWSER_INFO_LEFT or SETTINGS_LAYOUT.INFO_LEFT)
    local info_right = resolved and resolved.infoRight or (browser and SETTINGS_LAYOUT.BROWSER_INFO_RIGHT or SETTINGS_LAYOUT.INFO_RIGHT)
    local info_top = resolved and resolved.infoTop or (browser and SETTINGS_LAYOUT.BROWSER_INFO_TOP or SETTINGS_LAYOUT.INFO_TOP)
    local prompt_box = unwrap(ui.native_prompt_box)
    if valid(prompt_box) then
        pcall(function()
            prompt_box:SetWidthOverride(prompt_width)
            local set_min_w = prompt_box["SetMinDesiredWidth"]
            if set_min_w ~= nil then set_min_w(prompt_box, prompt_width) end
            prompt_box:SetHeightOverride(prompt_height)
            local set_min_h = prompt_box["SetMinDesiredHeight"]
            if set_min_h ~= nil then set_min_h(prompt_box, prompt_height) end
        end)
    end
    local source_body = unwrap(ui.native_source_body)
    if valid(source_body) then
        if valid(ui.native_tabs_widget) then tune_native_values_panel(ui.native_tabs_widget, source_body, tab_width) end
        if valid(ui.native_labels_widget) then tune_native_values_panel(ui.native_labels_widget, source_body, list_width) end
        if valid(ui.native_values_widget) then tune_native_values_panel(ui.native_values_widget, source_body, value_width) end
    end
    dd.set_dynamic_info_width(ui.native_details_widget, info_width, info_text_width)
    local function set_pad(slot, left, top, right)
        slot = unwrap(slot)
        if not valid(slot) then return false end
        local set_padding = slot["SetPadding"]
        if set_padding == nil then return false end
        return pcall(set_padding, slot, { Left = left, Top = top, Right = right or 0.0, Bottom = 0.0 })
    end
    set_pad(ui.native_tabs_slot, safe_left, tab_top, SETTINGS_LAYOUT.SAFE_RIGHT)
    set_pad(ui.native_labels_slot, safe_left, rows_top, 0.0)
    set_pad(ui.native_values_slot, value_left, rows_top, 0.0)
    set_pad(ui.native_details_slot, info_left, info_top, info_right)
    local update_background = ui.widget["UpdateBackgroundSize"]
    if update_background ~= nil then pcall(update_background, ui.widget) end
    local background = unwrap(ui.native_background)
    if valid(background) then
        local background_translate_x = resolved and resolved.backgroundTranslateX or (browser and SETTINGS_LAYOUT.BROWSER_BACKGROUND_TRANSLATE_X or SETTINGS_LAYOUT.BACKGROUND_TRANSLATE_X)
        local background_translate_y = resolved and resolved.backgroundTranslateY or (browser and SETTINGS_LAYOUT.BROWSER_BACKGROUND_TRANSLATE_Y or 0.0)
        local background_scale_x = resolved and resolved.backgroundScaleX or (browser and SETTINGS_LAYOUT.BROWSER_BACKGROUND_SCALE_X or SETTINGS_LAYOUT.BACKGROUND_SCALE_X)
        local background_scale_y = resolved and resolved.backgroundScaleY or (browser and SETTINGS_LAYOUT.BROWSER_BACKGROUND_SCALE_Y or SETTINGS_LAYOUT.BACKGROUND_SCALE_Y)
        set_native_render_translation(background, background_translate_x, background_translate_y)
        local set_pivot = background["SetRenderTransformPivot"]
        if set_pivot ~= nil then pcall(set_pivot, background, { X = SETTINGS_LAYOUT.BACKGROUND_PIVOT_X, Y = SETTINGS_LAYOUT.BACKGROUND_PIVOT_Y }) end
        local set_scale = background["SetRenderScale"]
        if set_scale ~= nil then pcall(set_scale, background, { X = background_scale_x, Y = background_scale_y }) end
    end
    ui.window_profile = profile_name
    ui.local_layout_signature = layout_signature
    ui.render_text_cache = {}
    diag("renderer.profile", { profile = profile_name, layoutSignature = layout_signature, promptWidth = prompt_width, promptHeight = prompt_height, pageSize = browser and dd.voice_browser.page_size or 0, labelWidth = list_width, valueWidth = value_width, infoWidth = info_width, safeLeft = safe_left, valueLeft = value_left, infoLeft = info_left, backgroundTranslateY = resolved and resolved.backgroundTranslateY or (browser and SETTINGS_LAYOUT.BROWSER_BACKGROUND_TRANSLATE_Y or 0.0), backgroundScaleX = resolved and resolved.backgroundScaleX or (browser and SETTINGS_LAYOUT.BROWSER_BACKGROUND_SCALE_X or SETTINGS_LAYOUT.BACKGROUND_SCALE_X) })
    if dd.log_window_viewport ~= nil then pcall(dd.log_window_viewport, profile_name) end
    log("settings window profile=" .. profile_name .. " prompt=" .. tostring(prompt_width) .. "x" .. tostring(prompt_height) .. " labelWidth=" .. tostring(list_width) .. " valueWidth=" .. tostring(value_width) .. " infoWidth=" .. tostring(info_width))
    return true
end

local function update_native_values_panel()
    if ui.host_visible_shell ~= true and type(dd.apply_window_profile) == "function" then
        pcall(dd.apply_window_profile, ui.window_profile or "main", false)
    end
    -- v0.9.40 updates the complete passive rail group together. Tabs, labels and
    -- values all use the same cooked WBP_Setting_InfoPanel host, so they no longer
    -- depend on the reader's VB_Data/ScaleBox_ReadText layout cadence.
    if not ui.open then return false end
    local tabs_ok = true
    local labels_ok = true
    local values_ok = true

    if valid(ui.native_tabs_widget) then
        if not valid(ui.native_tabs_text) then
            ui.native_tabs_text = native_widget_field(ui.native_tabs_widget, "RichSettingDescription")
        end
        tabs_ok = valid(ui.native_tabs_text) and set_native_text(ui.native_tabs_text, settings_tab_text(), "rails.tabs")
        if valid(ui.native_tabs_text) then
            pcall(function()
                ui.native_tabs_text:SetJustification(1)
                ui.native_tabs_text:SetAutoWrapText(false)
                ui.native_tabs_text.WrapTextAt = 0.0
                local refresh = ui.native_tabs_text["RefreshTextLayout"]
                if refresh ~= nil then refresh(ui.native_tabs_text) end
            end)
        end
    end

    if valid(ui.native_labels_widget) then
        if not valid(ui.native_labels_text) then
            ui.native_labels_text = native_widget_field(ui.native_labels_widget, "RichSettingDescription")
        end
        labels_ok = valid(ui.native_labels_text) and set_native_text(ui.native_labels_text, settings_label_text(), "rails.labels")
    end

    if valid(ui.native_values_widget) then
        if not valid(ui.native_values_text) then
            ui.native_values_text = native_widget_field(ui.native_values_widget, "RichSettingDescription")
        end
        values_ok = valid(ui.native_values_text) and set_native_text(ui.native_values_text, settings_values_text(), "rails.values")
    end

    return tabs_ok and labels_ok and values_ok
end

local function create_native_ui_foundation(player, controller, library, widget)
    ui.presentation_mode = "fallback"
    ui.native_reader_vb_data = nil
    compact_reader_shell_for_safe_ui(widget)

    local overlay_main, overlay_prompt, vb_data, read_size_box, read_scale_box, chain_text, recognized =
        trace_reader_text_branch(widget)
    if valid(vb_data) then ui.native_reader_vb_data = vb_data end

    if not recognized or not valid(overlay_prompt) then
        log("native scale-anchored rails UI unavailable: reader prompt branch did not match expected path; retaining compact text-list fallback")
        return false
    end

    local body = native_widget_field(widget, "RTB_ReadText")
    if not valid(body) then
        log("native scale-anchored rails UI unavailable: RTB_ReadText missing; retaining compact text-list fallback")
        return false
    end

    -- The raw WidgetTree proves Overlay_Main is the child of the exact outer
    -- ScaleBox_Main. Resolve that object through the live child's PanelSlot first.
    -- GetMainScaleBox() is retained only as a secondary route and is accepted only
    -- when it ALSO identifies an object named ScaleBox_Main: other prompt subclasses
    -- override that API for prompt/text scaling, while ReadText does not.
    local main_scale_box = nil
    local main_scale_source = "none"
    if valid(overlay_main) then
        pcall(function()
            local slot = unwrap(overlay_main.Slot)
            local parent = valid(slot) and unwrap(slot.Parent) or nil
            if valid(parent) and tostring(object_name(parent)):find("ScaleBox_Main", 1, true) ~= nil then
                main_scale_box = parent
                main_scale_source = "OverlayMainSlot.Parent"
            end
        end)
    end
    if not valid(main_scale_box) then
        local get_main_scale = widget["GetMainScaleBox"]
        if get_main_scale ~= nil then
            pcall(function()
                local candidate = unwrap(get_main_scale(widget))
                if valid(candidate) and tostring(object_name(candidate)):find("ScaleBox_Main", 1, true) ~= nil then
                    main_scale_box = candidate
                    main_scale_source = "GetMainScaleBox-verified"
                end
            end)
        end
    end

    -- v0.9.39 proved ScaleToFit + DownOnly is not a compactness policy: when the
    -- authored rectangle already fits the allotted area, Slate correctly leaves it
    -- at 1.0. We now have a stable fixed design rectangle, so use the documented
    -- literal UserSpecified scale to make the entire reader presentation (rails,
    -- details and chrome) compact in one coherent operation.
    local main_scale_native_stretch = "unread"
    local main_scale_native_direction = "unread"
    local main_scale_native_user_scale = "unread"
    local main_scale_guard_ok = false
    if valid(main_scale_box) then
        pcall(function()
            local get_stretch = main_scale_box["GetStretch"]
            if get_stretch ~= nil then main_scale_native_stretch = tostring(unwrap(get_stretch(main_scale_box))) end
            local get_direction = main_scale_box["GetStretchDirection"]
            if get_direction ~= nil then main_scale_native_direction = tostring(unwrap(get_direction(main_scale_box))) end
            local get_user_scale = main_scale_box["GetUserSpecifiedScale"]
            if get_user_scale ~= nil then main_scale_native_user_scale = tostring(unwrap(get_user_scale(main_scale_box))) end
        end)
        local set_stretch = main_scale_box["SetStretch"]
        local set_user_scale = main_scale_box["SetUserSpecifiedScale"]
        if set_stretch ~= nil and set_user_scale ~= nil then
            main_scale_guard_ok = pcall(function()
                set_stretch(main_scale_box, SCALEBOX_STRETCH_USER_SPECIFIED)
                set_user_scale(main_scale_box, 0.50)
            end)
        end
    end

    -- Right-side selected-setting details panel.
    local details, details_err = create_native_child_widget(
        player, controller, library,
        NATIVE_SETTING_INFO_PANEL_ASSET, NATIVE_SETTING_INFO_PANEL_CLASS
    )
    if not valid(details) then
        log("native scale-anchored rails UI unavailable: WBP_Setting_InfoPanel create failed: " .. tostring(details_err))
        return false
    end
    tune_setting_info_panel(details)

    local ok_attach, details_slot = pcall(function()
        return unwrap(overlay_prompt:AddChildToOverlay(details))
    end)
    if not ok_attach or not valid(details_slot) then
        pcall(function() details:RemoveFromParent() end)
        log("native scale-anchored rails UI unavailable: details attach to Overlay_Prompt failed: " .. tostring(details_slot))
        return false
    end

    local details_h_ok = false
    local details_v_ok = false
    local details_set_h = details_slot["SetHorizontalAlignment"]
    local details_set_v = details_slot["SetVerticalAlignment"]
    if details_set_h ~= nil then details_h_ok = pcall(details_set_h, details_slot, HALIGN_LEFT) end
    if details_set_v ~= nil then details_v_ok = pcall(details_set_v, details_slot, VALIGN_TOP) end

    -- Build three IDENTICAL passive text hosts: tabs, labels, values. This removes
    -- the last dependency on the reader's original VB_Data origin, which is why the
    -- v0.9.37 tab strip could cross row 3 while the two row rails were aligned.
    local tabrail = nil
    local tabrail_slot = nil
    local tabrail_ready = false
    local tabrail_h_ok = false
    local tabrail_v_ok = false
    local tabrail_create, tabrail_err = create_native_child_widget(
        player, controller, library,
        NATIVE_SETTING_INFO_PANEL_ASSET, NATIVE_SETTING_INFO_PANEL_CLASS
    )
    if valid(tabrail_create) then
        tabrail = tabrail_create
        tune_native_values_panel(tabrail, body, SETTINGS_FALLBACK_LIST_WIDTH)
        local ok_tab_attach, candidate_slot = pcall(function()
            return unwrap(overlay_prompt:AddChildToOverlay(tabrail))
        end)
        if ok_tab_attach and valid(candidate_slot) then
            tabrail_slot = candidate_slot
            local set_h = tabrail_slot["SetHorizontalAlignment"]
            local set_v = tabrail_slot["SetVerticalAlignment"]
            if set_h ~= nil then tabrail_h_ok = pcall(set_h, tabrail_slot, HALIGN_LEFT) end
            if set_v ~= nil then tabrail_v_ok = pcall(set_v, tabrail_slot, VALIGN_TOP) end
            ui.native_tabs_widget = tabrail
            ui.native_tabs_text = native_widget_field(tabrail, "RichSettingDescription")
            ui.native_tabs_slot = tabrail_slot
            tabrail_ready = valid(ui.native_tabs_text)
        else
            pcall(function() tabrail:RemoveFromParent() end)
            tabrail = nil
        end
    end

    local labels = nil
    local labels_slot = nil
    local labels_h_ok = false
    local labels_v_ok = false
    local labels_ready = false
    local labels_create, labels_err = create_native_child_widget(
        player, controller, library,
        NATIVE_SETTING_INFO_PANEL_ASSET, NATIVE_SETTING_INFO_PANEL_CLASS
    )
    if valid(labels_create) then
        labels = labels_create
        tune_native_values_panel(labels, body, SETTINGS_LIST_WIDTH)
        local ok_labels_attach, candidate_slot = pcall(function()
            return unwrap(overlay_prompt:AddChildToOverlay(labels))
        end)
        if ok_labels_attach and valid(candidate_slot) then
            labels_slot = candidate_slot
            local set_h = labels_slot["SetHorizontalAlignment"]
            local set_v = labels_slot["SetVerticalAlignment"]
            if set_h ~= nil then labels_h_ok = pcall(set_h, labels_slot, HALIGN_LEFT) end
            if set_v ~= nil then labels_v_ok = pcall(set_v, labels_slot, VALIGN_TOP) end
            ui.native_labels_widget = labels
            ui.native_labels_text = native_widget_field(labels, "RichSettingDescription")
            ui.native_labels_slot = labels_slot
            labels_ready = valid(ui.native_labels_text)
        else
            pcall(function() labels:RemoveFromParent() end)
            labels = nil
        end
    end

    local values = nil
    local values_slot = nil
    local values_h_ok = false
    local values_v_ok = false
    local values_ready = false
    local values_create, values_err = create_native_child_widget(
        player, controller, library,
        NATIVE_SETTING_INFO_PANEL_ASSET, NATIVE_SETTING_INFO_PANEL_CLASS
    )
    if valid(values_create) then
        values = values_create
        tune_native_values_panel(values, body, SETTINGS_VALUE_WIDTH)
        local ok_values_attach, candidate_slot = pcall(function()
            return unwrap(overlay_prompt:AddChildToOverlay(values))
        end)
        if ok_values_attach and valid(candidate_slot) then
            values_slot = candidate_slot
            local set_h = values_slot["SetHorizontalAlignment"]
            local set_v = values_slot["SetVerticalAlignment"]
            if set_h ~= nil then values_h_ok = pcall(set_h, values_slot, HALIGN_LEFT) end
            if set_v ~= nil then values_v_ok = pcall(set_v, values_slot, VALIGN_TOP) end
            ui.native_values_widget = values
            ui.native_values_text = native_widget_field(values, "RichSettingDescription")
            ui.native_values_slot = values_slot
            values_ready = valid(ui.native_values_text)
        else
            pcall(function() values:RemoveFromParent() end)
            values = nil
        end
    end

    local passive_group_ready = tabrail_ready and labels_ready and values_ready
    if not passive_group_ready then
        if valid(tabrail) then pcall(function() tabrail:RemoveFromParent() end) end
        if valid(labels) then pcall(function() labels:RemoveFromParent() end) end
        if valid(values) then pcall(function() values:RemoveFromParent() end) end
        ui.native_tabs_widget = nil
        ui.native_tabs_text = nil
        ui.native_tabs_slot = nil
        ui.native_labels_widget = nil
        ui.native_labels_text = nil
        ui.native_labels_slot = nil
        ui.native_values_widget = nil
        ui.native_values_text = nil
        ui.native_values_slot = nil
        tabrail, labels, values = nil, nil, nil
        tabrail_ready, labels_ready, values_ready = false, false, false
        log("native passive rail group unavailable; retaining combined text fallback tabs="
            .. tostring(tabrail_err or tabrail_ready)
            .. " labels=" .. tostring(labels_err or labels_ready)
            .. " values=" .. tostring(values_err or values_ready))
    else
        tune_native_values_panel(tabrail, body, SETTINGS_FALLBACK_LIST_WIDTH)
        tune_native_values_panel(labels, body, SETTINGS_LIST_WIDTH)
        tune_native_values_panel(values, body, SETTINGS_VALUE_WIDTH)
    end

    local prompt_box = native_widget_field(widget, "SizeBox_Prompt")
    ui.native_prompt_box = prompt_box
    ui.native_source_body = body
    local prompt_width_ok = false
    local prompt_height_ok = false
    local prompt_height_mode = "natural-fallback"
    if valid(prompt_box) then
        prompt_width_ok = pcall(function()
            prompt_box:SetWidthOverride(SETTINGS_PROMPT_WIDTH)
            local set_min_w = prompt_box["SetMinDesiredWidth"]
            if set_min_w ~= nil then set_min_w(prompt_box, SETTINGS_PROMPT_WIDTH) end
        end)

        -- Fixed authored geometry is safe only after the exact outer ScaleBox_Main
        -- accepted our compact literal scale. The 1680x650 rectangle gives the three
        -- rails more design-space breathing room while the outer 0.50 scale keeps the
        -- resulting screen footprint close to the saner pre-v0.9.36 prototypes.
        if main_scale_guard_ok then
            prompt_height_ok = pcall(function()
                prompt_box:SetHeightOverride(SETTINGS_LAYOUT.PROMPT_HEIGHT)
                local set_min_h = prompt_box["SetMinDesiredHeight"]
                if set_min_h ~= nil then set_min_h(prompt_box, SETTINGS_LAYOUT.PROMPT_HEIGHT) end
            end)
            if prompt_height_ok then prompt_height_mode = "fixed-650-user-scale-0.50" end
        else
            prompt_height_ok = pcall(function()
                local clear_h = prompt_box["ClearHeightOverride"]
                if clear_h ~= nil then clear_h(prompt_box) end
                local clear_min_h = prompt_box["ClearMinDesiredHeight"]
                if clear_min_h ~= nil then clear_min_h(prompt_box) end
            end)
        end
    end

    -- If the independent rail group is active, collapse the reader's original
    -- VB_Data entirely. It otherwise contributes a second coordinate system and
    -- was the sole source of the tab/row overlap in v0.9.37.
    local original_reader_branch_collapsed = false
    if passive_group_ready and valid(vb_data) then
        original_reader_branch_collapsed = set_native_visibility(vb_data, 1)
        if original_reader_branch_collapsed then
            ui.presentation_mode = "rails"
        else
            ui.presentation_mode = "fallback"
            set_native_visibility(vb_data, 0)
        end
    elseif valid(vb_data) then
        ui.presentation_mode = "fallback"
        set_native_visibility(vb_data, 0)
    end
    diag("renderer.mode", {
        stage = "foundation",
        mode = ui.presentation_mode,
        passiveGroupReady = passive_group_ready,
        fallbackBranch = valid(vb_data) and object_name(vb_data) or "<invalid>",
        fallbackCollapsed = original_reader_branch_collapsed,
    })

    -- Layout-aware OverlaySlot padding is intentionally used instead of render
    -- translations. Padding participates in desired-size/layout and therefore gives
    -- UpdateBackgroundSize() one coherent rectangle to fit.
    local tab_padding_ok = true
    local label_padding_ok = true
    local value_padding_ok = true
    local info_padding_ok = true
    if passive_group_ready then
        local tab_pad = tabrail_slot["SetPadding"]
        local label_pad = labels_slot["SetPadding"]
        local value_pad = values_slot["SetPadding"]
        if tab_pad ~= nil then
            tab_padding_ok = pcall(tab_pad, tabrail_slot, {
                Left = SETTINGS_LAYOUT.SAFE_LEFT, Top = SETTINGS_LAYOUT.TAB_TOP,
                Right = SETTINGS_LAYOUT.SAFE_RIGHT, Bottom = 0.0
            })
        end
        if label_pad ~= nil then
            label_padding_ok = pcall(label_pad, labels_slot, {
                Left = SETTINGS_LAYOUT.SAFE_LEFT, Top = SETTINGS_LAYOUT.ROWS_TOP,
                Right = 0.0, Bottom = 0.0
            })
        end
        if value_pad ~= nil then
            value_padding_ok = pcall(value_pad, values_slot, {
                Left = SETTINGS_LAYOUT.VALUE_LEFT, Top = SETTINGS_LAYOUT.ROWS_TOP,
                Right = 0.0, Bottom = 0.0
            })
        end
    end
    local info_pad = details_slot["SetPadding"]
    if info_pad ~= nil then
        info_padding_ok = pcall(info_pad, details_slot, {
            Left = SETTINGS_LAYOUT.INFO_LEFT, Top = SETTINGS_LAYOUT.INFO_TOP,
            Right = SETTINGS_LAYOUT.INFO_RIGHT, Bottom = 0.0
        })
    end

    -- Clear historical visual translations; position is now entirely slot-driven.
    local prompt_content_inset_ok = set_native_render_translation(overlay_prompt, 0.0, 0.0)
    local tab_translate_ok = valid(tabrail) and set_native_render_translation(tabrail, 0.0, 0.0) or true
    local label_translate_ok = valid(labels) and set_native_render_translation(labels, 0.0, 0.0) or true
    local value_translate_ok = valid(values) and set_native_render_translation(values, 0.0, 0.0) or true
    local info_translate_ok = set_native_render_translation(details, 0.0, 0.0)

    local background_update_ok = false
    local update_background = widget["UpdateBackgroundSize"]
    if update_background ~= nil then
        background_update_ok = pcall(update_background, widget)
    end

    local background = native_widget_field(widget, "ARB_Background")
    ui.native_background = background
    ui.window_profile = "main"
    ui.local_layout_signature = ""
    local background_translate_ok = false
    local background_pivot_ok = false
    local background_scale_ok = false
    if valid(background) then
        background_translate_ok = set_native_render_translation(background, SETTINGS_LAYOUT.BACKGROUND_TRANSLATE_X, 0.0)
        local set_pivot = background["SetRenderTransformPivot"]
        if set_pivot ~= nil then
            background_pivot_ok = pcall(set_pivot, background, {
                X = SETTINGS_LAYOUT.BACKGROUND_PIVOT_X,
                Y = SETTINGS_LAYOUT.BACKGROUND_PIVOT_Y,
            })
        end
        local set_scale = background["SetRenderScale"]
        if set_scale ~= nil then
            -- v0.9.67 corrects the v0.9.63 origin mismatch instead of continuing to
            -- inflate a centered smoke transform. With pivot X=0, the 1.14 factor adds
            -- the extra width almost entirely to the widened details side while the
            -- translated left edge follows the content rails instead of drifting outward.
            background_scale_ok = pcall(set_scale, background, {
                X = SETTINGS_LAYOUT.BACKGROUND_SCALE_X,
                Y = SETTINGS_LAYOUT.BACKGROUND_SCALE_Y,
            })
        end
    end

    ui.native_details_widget = details
    ui.native_details_container = overlay_prompt
    ui.native_details_overlay = overlay_prompt
    ui.native_details_active = true
    ui.native_two_column_active = true
    ui.native_details_created = true
    ui.native_details_slot = details_slot
    ui.native_details_panel = details

    log("native compact parent-owned passive rails UI created active=true"
        .. " promptWidth=" .. tostring(SETTINGS_PROMPT_WIDTH)
        .. " promptWidthOk=" .. tostring(prompt_width_ok)
        .. " promptHeightMode=" .. tostring(prompt_height_mode)
        .. " promptHeightOk=" .. tostring(prompt_height_ok)
        .. " mainScaleBox=" .. object_name(main_scale_box)
        .. " mainScaleSource=" .. tostring(main_scale_source)
        .. " mainScaleUserSpecified050=" .. tostring(main_scale_guard_ok)
        .. " nativeStretchBefore=" .. tostring(main_scale_native_stretch)
        .. " nativeDirectionBefore=" .. tostring(main_scale_native_direction)
        .. " nativeUserScaleBefore=" .. tostring(main_scale_native_user_scale)
        .. " passiveGroup=" .. tostring(passive_group_ready)
        .. " originalVBDataCollapsed=" .. tostring(original_reader_branch_collapsed)
        .. " tabWidth=" .. tostring(SETTINGS_FALLBACK_LIST_WIDTH)
        .. " labelWidth=" .. tostring(SETTINGS_LIST_WIDTH)
        .. " valueWidth=" .. tostring(SETTINGS_VALUE_WIDTH)
        .. " infoWidth=" .. tostring(SETTINGS_INFO_WIDTH)
        .. " tabPadding=" .. tostring(SETTINGS_LAYOUT.SAFE_LEFT) .. "," .. tostring(SETTINGS_LAYOUT.TAB_TOP) .. " ok=" .. tostring(tab_padding_ok)
        .. " labelPadding=" .. tostring(SETTINGS_LAYOUT.SAFE_LEFT) .. "," .. tostring(SETTINGS_LAYOUT.ROWS_TOP) .. " ok=" .. tostring(label_padding_ok)
        .. " valuePadding=" .. tostring(SETTINGS_LAYOUT.VALUE_LEFT) .. "," .. tostring(SETTINGS_LAYOUT.ROWS_TOP) .. " ok=" .. tostring(value_padding_ok)
        .. " infoPadding=" .. tostring(SETTINGS_LAYOUT.INFO_LEFT) .. "," .. tostring(SETTINGS_LAYOUT.INFO_TOP) .. " rightSafe=" .. tostring(SETTINGS_LAYOUT.INFO_RIGHT) .. " ok=" .. tostring(info_padding_ok)
        .. " translationsCleared=" .. tostring(prompt_content_inset_ok and tab_translate_ok and label_translate_ok and value_translate_ok and info_translate_ok)
        .. " backgroundUpdate=" .. tostring(background_update_ok)
        .. " backgroundTranslateX=" .. tostring(SETTINGS_LAYOUT.BACKGROUND_TRANSLATE_X)
        .. " backgroundTranslateOk=" .. tostring(background_translate_ok)
        .. " backgroundScale=" .. tostring(SETTINGS_LAYOUT.BACKGROUND_SCALE_X) .. "x" .. tostring(SETTINGS_LAYOUT.BACKGROUND_SCALE_Y)
        .. " backgroundPivotOk=" .. tostring(background_pivot_ok)
        .. " backgroundScaleOk=" .. tostring(background_scale_ok)
        .. " container=" .. object_name(overlay_prompt)
        .. " backendChanged=false")
    return true
end

    return {
        NativeWidgetField = native_widget_field,
        SetNativeText = set_native_text,
        NativeWidgetVisible = native_widget_visible,
        SetNativeVisibility = set_native_visibility,
        GetPlayerAndController = get_player_and_controller,
        LoadNativeSettingsClass = load_native_settings_class,
        LoadNativeInputListenerClass = load_native_input_listener_class,
        SelectedSettingDetailsText = selected_setting_details_text,
        UpdateNativeDetailsPanel = update_native_details_panel,
        UpdateNativeValuesPanel = update_native_values_panel,
        CreateNativeUIFoundation = create_native_ui_foundation,
    }
end

return M
