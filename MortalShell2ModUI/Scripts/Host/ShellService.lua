-- MortalShell2ModUI Host.ShellService
-- Standalone single-owner visible Settings shell for independent UE4SS consumer Lua states.
-- The host owns the borrowed native UMG shell, its passive rails, focus/cursor/input-mode
-- lifetime, and rendering. Consumers publish primitive-only presentation snapshots and keep
-- executable setting/action semantics in their own Lua state. Pass 163 also enforces
-- field/line presentation bounds so one consumer cannot overlap neighboring shared-shell rails.

-- v0.71.8: the shell's own open and close sounds, named once here rather than spelled at
-- the call sites, because they are a STAND-IN and will change. She auditioned every value
-- in Enum_UI_Events from the playground's AUDIO tab: the game's real menu open/close is
-- resolved from the event plus a Context gameplay tag we pass empty, so it is not in the
-- generic palette at all, and the generic Open/Close that ARE there sit 15 dB below the
-- clicks she can hear. These two are the closest audible pair she found -- her words,
-- "they aren't really correct but they are close".
local OPEN_EVENT = "HoldComplete"
local CLOSE_EVENT = "HoldCancel"

local M = {}

-- The pointer, resolved against what the host drew: the strip window it laid out
-- and the rails it sized. Returns { kind, index, direction } or nil.
function M.ResolvePointerAgainst(layout, interaction, resolved, strip, presentation, event)
    if type(layout) ~= "table" or type(interaction) ~= "table" or type(resolved) ~= "table"
        or type(presentation) ~= "table" or type(event) ~= "table" then return nil end
    -- The host's pointer snapshot is { x, y, width, height }; the consumer-side event
    -- is { pointerX, pointerY, viewportWidth, viewportHeight }. Take either.
    local point = interaction.Pointer({
        pointerX = event.pointerX or event.x, pointerY = event.pointerY or event.y,
        viewportWidth = event.viewportWidth or event.width, viewportHeight = event.viewportHeight or event.height,
    })
    if point == nil then return nil end
    local row_count = 0
    for _ in (tostring(presentation.labels or "") .. "\n"):gmatch("(.-)\n") do row_count = row_count + 1 end
    row_count = math.max(0, row_count - 1)
    local tab_labels = {}
    for line in (tostring(presentation.tabLabels or "") .. "\n"):gmatch("(.-)\n") do
        if line ~= "" then tab_labels[#tab_labels + 1] = line end
    end
    return interaction.Hit(layout, tostring(presentation.profile or "main"), presentation, tab_labels,
        tonumber(presentation.selectedTab) or 1, row_count, point.x, point.y,
        { resolved = resolved, window = strip })
end

function M.Bind(ModUI, registry, protocol, options)
    if type(ModUI) ~= "table" or type(ModUI.Object) ~= "table" then
        return nil, "Host.ShellService requires ModUI core"
    end
    if type(registry) ~= "table" or type(registry.ReadConsumerMenuPresentation) ~= "function" then
        return nil, "Host.ShellService requires presentation-capable Host.Registry"
    end
    options = type(options) == "table" and options or {}
    local Layout = type(ModUI.Settings) == "table" and ModUI.Settings.Layout or nil
    if type(Layout) ~= "table" or type(Layout.assets) ~= "table" or type(Layout.settings) ~= "table" then
        return nil, "Host.ShellService requires ModUI.Settings.Layout"
    end
    local PresentationSafety = type(ModUI.Settings) == "table" and ModUI.Settings.PresentationSafety or nil
    if type(PresentationSafety) ~= "table" or type(PresentationSafety.Sanitize) ~= "function" then
        return nil, "Host.ShellService requires ModUI.Settings.PresentationSafety"
    end
    local Viewport = type(ModUI.Settings) == "table" and ModUI.Settings.Viewport or nil
    if type(Viewport) ~= "table" or type(Viewport.Apply) ~= "function" then
        return nil, "Host.ShellService requires ModUI.Settings.Viewport"
    end
    -- v0.71.0: section headers ("header" in rowKinds) are drawn as divider lines.
    local Render = type(ModUI.Settings) == "table" and ModUI.Settings.Render or nil
    local decorate_headers = type(Render) == "table" and type(Render.DecorateHeaders) == "function"
        and Render.DecorateHeaders or function(labels) return labels, 0 end

    local unwrap = ModUI.Object.Unwrap
    local valid = ModUI.Object.Valid
    local object_name = ModUI.Object.Name
    local object_address = ModUI.Object.Address
    local log = type(options.log) == "function" and options.log or function() end
    local diag = type(options.diag) == "function" and options.diag or function() end
    -- v0.71.4: the game's own UI click. Constructed once per bind; it resolves its
    -- object lazily on the first sound and disables itself for the session if the game
    -- does not have the broadcaster, so a missing sound can never cost a menu.
    local audio_factory = type(ModUI.Host) == "table" and ModUI.Host.Audio or nil
    local host_audio = type(audio_factory) == "table" and type(audio_factory.New) == "function"
        and audio_factory.New({ Object = ModUI.Object, Log = function(line) print(tostring(line) .. "\n") end })
        or nil

    local ui = {
        audio = host_audio,
        widget = nil, header_widget = nil, body_widget = nil, page_widget = nil,
        native_reader_vb_data = nil, native_tabs_widget = nil, native_tabs_text = nil,
        native_tabs_slot = nil, native_labels_widget = nil, native_labels_text = nil,
        native_labels_slot = nil, native_values_widget = nil, native_values_text = nil,
        native_values_slot = nil, native_details_widget = nil, native_details_slot = nil,
        native_details_container = nil, native_details_overlay = nil, native_details_panel = nil,
        native_details_active = false, native_details_created = false, native_two_column_active = false,
        native_controls = nil, native_controls_active = false,
        native_prompt_box = nil, native_source_body = nil, native_background = nil,
        presentation_mode = "fallback", window_profile = "main", render_text_cache = {},
        controller = nil, widget_library = nil, handler = nil,
        saved_show_cursor = false, saved_click_events = false, saved_hover_events = false,
        saved_move_probe_ok = false, saved_move_ignored = false,
        saved_look_probe_ok = false, saved_look_ignored = false,
        move_ignore_bumped = false, look_ignore_bumped = false, input_mode_owned = false,
        consumer = "", slot = -1, revision = 0, generation = 0, presentation_sequence = 0,
        world_quarantined = false,
        last_clip_signature = "", layout_signature = "",
        -- v0.70.0 measured layout: the glyph width the rendered rails actually have,
        -- the tab window drawn last, and the presentation to redraw when a measurement
        -- changes the layout. Calibration outlives one open (the font does not change).
        calibration = { glyphWidth = nil, source = "model" },
        tab_first = 1, last_strip = nil, last_resolved = nil, last_presentation = nil,
        measure = nil, relayout_pending = false,
    }
    -- Host-lifetime memory of the measured glyph, so a reopened shell starts right.
    local remembered_glyph = nil

    local NATIVE_SETTINGS_ASSET = Layout.assets.settings
    local NATIVE_SETTINGS_CLASS = Layout.assets.settingsClass
    local NATIVE_BPFL_UI_ASSET = Layout.assets.bpflUi
    local NATIVE_BPFL_UI_CDO = Layout.assets.bpflUiCdo
    local NATIVE_SETTING_INFO_PANEL_ASSET = Layout.assets.settingInfoPanel
    local NATIVE_SETTING_INFO_PANEL_CLASS = Layout.assets.settingInfoPanelClass
    local SETTINGS_PROMPT_WIDTH = Layout.widths.prompt
    local SETTINGS_LIST_WIDTH = Layout.widths.list
    local SETTINGS_VALUE_WIDTH = Layout.widths.value
    local SETTINGS_FALLBACK_LIST_WIDTH = Layout.widths.fallbackList
    local SETTINGS_INFO_WIDTH = Layout.widths.info
    local SETTINGS_INFO_TEXT_WIDTH = Layout.widths.infoText
    local SETTINGS_LAYOUT = Layout.settings
    local SCALEBOX_STRETCH_USER_SPECIFIED = Layout.enums.SCALEBOX_STRETCH_USER_SPECIFIED
    local WIDGET_CLIP_INHERIT = Layout.enums.WIDGET_CLIP_INHERIT
    local WIDGET_CLIP_TO_BOUNDS = Layout.enums.WIDGET_CLIP_TO_BOUNDS
    local HALIGN_FILL = Layout.enums.HALIGN_FILL
    local HALIGN_LEFT = Layout.enums.HALIGN_LEFT
    local HALIGN_CENTER = Layout.enums.HALIGN_CENTER
    local HALIGN_RIGHT = Layout.enums.HALIGN_RIGHT
    local VALIGN_TOP = Layout.enums.VALIGN_TOP
    local VALIGN_CENTER = Layout.enums.VALIGN_CENTER
    local WIDGET_BLUEPRINT_LIBRARY_CDO = "/Script/UMG.Default__WidgetBlueprintLibrary"
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
            -- v0.70.0: no minimum desired width on the text block itself -- the SizeBox
            -- chain above holds the rail open at rail_width, and the block's own
            -- desired size is then the text's natural width, which is what the host
            -- measures to size the rails (measure_rails).
            local set_min = description["SetMinDesiredWidth"]
            if set_min ~= nil then set_min(description, 0.0) end
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
    
    local function set_dynamic_info_width(panel, panel_width, text_width)
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
    
    local function controller_property_bool(controller, property_name)
        controller = unwrap(controller)
        if not valid(controller) then return false end
        local value = false
        pcall(function() value = unwrap(controller[property_name]) == true end)
        return value
    end

    local function controller_ignored_state(controller, method_name)
        controller = unwrap(controller)
        if not valid(controller) then return false, false end
        local method = controller[method_name]
        if method == nil then return false, false end
        local ok, value = pcall(method, controller)
        return ok, ok and unwrap(value) == true or false
    end

    local function set_native_text_direct(widget, text, cache_key)
        widget = unwrap(widget)
        if not valid(widget) then return false end
        local rendered = tostring(text or "")
        local key = tostring(cache_key or "")
        if key ~= "" and ui.render_text_cache[key] == rendered then return true end
        local ok = pcall(function() widget:SetText(FText(rendered)) end)
        if ok and key ~= "" then ui.render_text_cache[key] = rendered end
        return ok
    end

    local function retire_visual_shell(widget, handler, clear_active)
        widget = unwrap(widget)
        handler = unwrap(handler)
        if not valid(widget) then return end
        local update = widget["UpdateOpenState"]
        if update ~= nil then pcall(update, widget, false) end
        if clear_active == true and valid(handler) then
            local active = nil
            pcall(function() active = unwrap(handler.ActiveReadText) end)
            if valid(active) and (active == widget or object_name(active) == object_name(widget)) then
                local invalidate = widget["Invalidate"]
                if invalidate ~= nil then pcall(invalidate, widget) end
                pcall(function() handler.ActiveReadText = nil end)
            end
        end
    end

    local function disable_embedded_reader_listener(widget)
        local listener = native_widget_field(widget, "WBP_IL_ReadText")
        if not valid(listener) then return false end
        pcall(function() listener.bAutoActivate = false end)
        pcall(function() listener:SetEnabledState(false) end)
        pcall(function() listener:UnbindInputs() end)
        pcall(function() listener.bEnabled = false end)
        return true
    end

    local function acquire_input_mode(controller, library, widget)
        controller, library, widget = unwrap(controller), unwrap(library), unwrap(widget)
        if not valid(controller) or not valid(library) or not valid(widget) then return false end
        local fn = library["SetInputMode_GameAndUIEx"]
        if fn == nil then return false end
        ui.saved_show_cursor = controller_property_bool(controller, "bShowMouseCursor")
        ui.saved_click_events = controller_property_bool(controller, "bEnableClickEvents")
        ui.saved_hover_events = controller_property_bool(controller, "bEnableMouseOverEvents")
        ui.saved_move_probe_ok, ui.saved_move_ignored = controller_ignored_state(controller, "IsMoveInputIgnored")
        ui.saved_look_probe_ok, ui.saved_look_ignored = controller_ignored_state(controller, "IsLookInputIgnored")
        if not pcall(fn, library, controller, widget, 0, false, true) then return false end
        if ui.saved_move_probe_ok and not ui.saved_move_ignored then
            ui.move_ignore_bumped = pcall(function() controller:SetIgnoreMoveInput(true) end)
        end
        if ui.saved_look_probe_ok and not ui.saved_look_ignored then
            ui.look_ignore_bumped = pcall(function() controller:SetIgnoreLookInput(true) end)
        end
        pcall(function() controller.bShowMouseCursor = true end)
        pcall(function() controller.bEnableClickEvents = true end)
        pcall(function() controller.bEnableMouseOverEvents = true end)
        if not ui.saved_show_cursor then
            pcall(function()
                if LoadAsset ~= nil then LoadAsset(NATIVE_BPFL_UI_ASSET) end
                local bpfl = StaticFindObject ~= nil and unwrap(StaticFindObject(NATIVE_BPFL_UI_CDO)) or nil
                if valid(bpfl) and bpfl["ResetMouseToScreenCenter"] ~= nil then
                    bpfl:ResetMouseToScreenCenter(true, widget, controller)
                end
            end)
        end
        pcall(function() widget:SetKeyboardFocus() end)
        pcall(function() widget:SetUserFocus(controller) end)
        pcall(function() widget:SetFocus() end)
        ui.input_mode_owned = true
        return true
    end

    local function restore_input_mode()
        if not ui.input_mode_owned then return end
        local controller, library = unwrap(ui.controller), unwrap(ui.widget_library)
        if valid(controller) then
            if ui.move_ignore_bumped then pcall(function() controller:SetIgnoreMoveInput(false) end) end
            if ui.look_ignore_bumped then pcall(function() controller:SetIgnoreLookInput(false) end) end
            pcall(function() controller.bShowMouseCursor = ui.saved_show_cursor end)
            pcall(function() controller.bEnableClickEvents = ui.saved_click_events end)
            pcall(function() controller.bEnableMouseOverEvents = ui.saved_hover_events end)
            if valid(library) and library["SetInputMode_GameOnly"] ~= nil then
                pcall(function() library:SetInputMode_GameOnly(controller, true) end)
                pcall(function()
                    if library["SetFocusToGameViewport"] ~= nil then library:SetFocusToGameViewport() end
                end)
            end
        end
        ui.input_mode_owned = false
        ui.move_ignore_bumped, ui.look_ignore_bumped = false, false
    end

    local function clear_refs()
        if type(ui.native_controls) == "table" and type(ui.native_controls.Clear) == "function" then
            pcall(ui.native_controls.Clear)
        end
        ui.widget, ui.header_widget, ui.body_widget, ui.page_widget = nil, nil, nil, nil
        ui.native_reader_vb_data = nil
        ui.native_tabs_widget, ui.native_tabs_text, ui.native_tabs_slot = nil, nil, nil
        ui.native_labels_widget, ui.native_labels_text, ui.native_labels_slot = nil, nil, nil
        ui.native_values_widget, ui.native_values_text, ui.native_values_slot = nil, nil, nil
        ui.native_details_widget, ui.native_details_slot = nil, nil
        ui.native_details_container, ui.native_details_overlay, ui.native_details_panel = nil, nil, nil
        ui.native_prompt_box, ui.native_source_body, ui.native_background = nil, nil, nil
        ui.native_details_active, ui.native_details_created, ui.native_two_column_active = false, false, false
        ui.native_controls, ui.native_controls_active = nil, false
        ui.presentation_mode, ui.window_profile = "fallback", "main"
        ui.layout_signature = ""
        ui.render_text_cache = {}
        ui.controller, ui.widget_library, ui.handler = nil, nil, nil
        ui.consumer, ui.slot, ui.revision, ui.generation, ui.presentation_sequence = "", -1, 0, 0, 0
    end

    local function close_shell(reason, safe_deref)
        local widget, handler = unwrap(ui.widget), unwrap(ui.handler)
        -- v0.71.4: played while the widget is still ours to name as the instigator.
        if ui.audio ~= nil and valid(widget) then pcall(ui.audio.Play, CLOSE_EVENT, widget) end
        if safe_deref ~= false and valid(widget) then
            -- Do not send this borrowed prompt through the native forced-focus call.
            -- The game owns the lore reader's complete registration/removal
            -- lifecycle; a mod shell does not. Our explicit input-mode restore
            -- and consumer close guard release input without leaving the native
            -- handler referencing a widget we immediately remove.
            retire_visual_shell(widget, handler, true)
            restore_input_mode()
            pcall(function() widget:RemoveFromParent() end)
        else
            -- World-preload quarantine: never validate/dereference an old-world wrapper.
            ui.input_mode_owned = false
        end
        local prior_address = valid(widget) and tostring(object_address(widget) or "") or ""
        clear_refs()
        return prior_address, tostring(reason or "closed")
    end

    local function apply_profile(profile, snapshot)
        if not valid(ui.widget) then return false end
        profile = tostring(profile or "main") == "browser" and "browser" or "main"
        snapshot = type(snapshot) == "table" and snapshot or {}
        local resolved = type(Layout.ResolveAdaptive) == "function"
            and Layout.ResolveAdaptive(profile, snapshot.labels or "", snapshot.values or "", ui.calibration) or nil
        local browser = profile == "browser"
        local prompt_width = resolved and resolved.promptWidth or (browser and SETTINGS_LAYOUT.BROWSER_PROMPT_WIDTH or SETTINGS_PROMPT_WIDTH)
        local prompt_height = resolved and resolved.promptHeight or (browser and SETTINGS_LAYOUT.BROWSER_PROMPT_HEIGHT or SETTINGS_LAYOUT.PROMPT_HEIGHT)
        local tab_width = resolved and resolved.tabWidth or (browser and SETTINGS_LAYOUT.BROWSER_TAB_WIDTH or SETTINGS_FALLBACK_LIST_WIDTH)
        -- v0.70.0: the tab rail is the prompt's inner width (Layout.ResolveAdaptive);
        -- the strip is windowed to fit inside it and clipped at its edge.
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
        local layout_signature = (resolved and tostring(resolved.signature or profile) or profile)
            .. ":t" .. tostring(math.floor(tab_width))
        if ui.window_profile == profile and ui.layout_signature == layout_signature then return true end
        if valid(ui.native_prompt_box) then
            pcall(function()
                ui.native_prompt_box:SetWidthOverride(prompt_width)
                local m = ui.native_prompt_box["SetMinDesiredWidth"]; if m ~= nil then m(ui.native_prompt_box, prompt_width) end
                ui.native_prompt_box:SetHeightOverride(prompt_height)
                local h = ui.native_prompt_box["SetMinDesiredHeight"]; if h ~= nil then h(ui.native_prompt_box, prompt_height) end
            end)
        end
        if valid(ui.native_source_body) then
            if valid(ui.native_tabs_widget) then tune_native_values_panel(ui.native_tabs_widget, ui.native_source_body, tab_width) end
            if valid(ui.native_labels_widget) then tune_native_values_panel(ui.native_labels_widget, ui.native_source_body, list_width) end
            if valid(ui.native_values_widget) then tune_native_values_panel(ui.native_values_widget, ui.native_source_body, value_width) end
        end
        set_dynamic_info_width(ui.native_details_widget, info_width, info_text_width)
        local function pad(slot, left, top, right)
            slot = unwrap(slot); if not valid(slot) or slot["SetPadding"] == nil then return end
            pcall(slot["SetPadding"], slot, { Left = left, Top = top, Right = right or 0.0, Bottom = 0.0 })
        end
        pad(ui.native_tabs_slot, safe_left, tab_top, SETTINGS_LAYOUT.SAFE_RIGHT)
        if valid(ui.native_tabs_widget) then
            pcall(function() ui.native_tabs_widget:SetClipping(WIDGET_CLIP_TO_BOUNDS) end)
        end
        pad(ui.native_labels_slot, safe_left, rows_top, 0.0)
        pad(ui.native_values_slot, value_left, rows_top, 0.0)
        pad(ui.native_details_slot, info_left, info_top, info_right)
        if ui.widget["UpdateBackgroundSize"] ~= nil then pcall(ui.widget["UpdateBackgroundSize"], ui.widget) end
        if valid(ui.native_background) then
            local tx = resolved and resolved.backgroundTranslateX or (browser and SETTINGS_LAYOUT.BROWSER_BACKGROUND_TRANSLATE_X or SETTINGS_LAYOUT.BACKGROUND_TRANSLATE_X)
            local ty = resolved and resolved.backgroundTranslateY or (browser and SETTINGS_LAYOUT.BROWSER_BACKGROUND_TRANSLATE_Y or 0.0)
            local sx = resolved and resolved.backgroundScaleX or (browser and SETTINGS_LAYOUT.BROWSER_BACKGROUND_SCALE_X or SETTINGS_LAYOUT.BACKGROUND_SCALE_X)
            local sy = resolved and resolved.backgroundScaleY or (browser and SETTINGS_LAYOUT.BROWSER_BACKGROUND_SCALE_Y or SETTINGS_LAYOUT.BACKGROUND_SCALE_Y)
            set_native_render_translation(ui.native_background, tx, ty)
            local pivot = ui.native_background["SetRenderTransformPivot"]
            if pivot ~= nil then pcall(pivot, ui.native_background, { X = SETTINGS_LAYOUT.BACKGROUND_PIVOT_X, Y = SETTINGS_LAYOUT.BACKGROUND_PIVOT_Y }) end
            local scale = ui.native_background["SetRenderScale"]
            if scale ~= nil then pcall(scale, ui.native_background, { X = sx, Y = sy }) end
        end
        ui.window_profile = profile
        ui.layout_signature = layout_signature
        ui.render_text_cache = {}
        diag("host.shell.adaptiveLayout", {
            status = "applied", profile = profile, signature = layout_signature,
            promptWidth = prompt_width, labelWidth = list_width, valueWidth = value_width,
            valueLeft = value_left, infoLeft = info_left,
        })
        return true
    end

    local function decorate_provider_header(snapshot, menu_report)
        if type(snapshot) ~= "table" then return snapshot end
        local count = math.max(0, math.floor(tonumber(type(menu_report) == "table" and menu_report.providerCount or 0) or 0))
        if count <= 1 then return snapshot end
        local index = math.max(1, math.floor(tonumber(menu_report.providerIndex) or 1))
        local display = tostring(menu_report.providerDisplay or "")
        local copy = {}
        for key, value in pairs(snapshot) do copy[key] = value end
        copy.header = tostring(snapshot.header or "MOD SETTINGS") .. "   [" .. tostring(index) .. "/" .. tostring(count)
            .. (display ~= "" and (" " .. display) or "") .. "]"
        return copy
    end

    local render_presentation_body
    local function render_presentation(snapshot)
        local perf = ModUI.Perf
        local token = perf ~= nil and perf.Begin() or nil
        local ok, mode = render_presentation_body(snapshot)
        if token ~= nil then perf.End("shell.render", token) end
        return ok, mode
    end

    -- v0.71.4 UI audio. The host is the right place for this and the only sane one: the
    -- consumer owns the selection, but the host is what both consumers publish THROUGH, so
    -- one diff here gives Minimap and TTS the same sounds with no consumer changes at all
    -- (and she has been clear that ModUI owns shared UI work).
    --
    -- What a snapshot diff can honestly tell apart:
    --   profile changed            -> Tab Switch
    --   the cursor moved rows      -> Hover   (her "subtle click when I change options")
    --   same row, values changed   -> Select  (a value was cycled or toggled)
    --
    -- Deliberately NOT Increase/Decrease: the values arrive as formatted strings, so
    -- direction would be a guess, and guessing produces a sound that contradicts what the
    -- player just did. Select is the honest choice until a consumer sends the direction.
    --
    -- A RE-RENDER IS NOT AN INTERACTION. The relayout path re-renders ui.last_presentation
    -- verbatim -- the same thing that produced the four-em-dash header in v0.71.3 -- so a
    -- diff against an identical snapshot has to be silent. It is, because nothing differs.
    -- v0.71.6 (user, 2026-09-15): "i don't hear the navigation/tab audio in TTS menu for
    -- some reason. I hear it in minimap and ui playground. isn't the audio rooted in ui
    -- mod?" It is -- but 0.71.4 read the cursor by looking for "> " in the LABEL TEXT, and
    -- that is a rendering detail a consumer is free to differ on. Every consumer publishes
    -- selectedRow and selectedTab as numbers in the snapshot, which is the host's own
    -- contract and cannot be styled away. Read those first and fall back to the text, so a
    -- consumer that sends either one is heard.
    local function selected_row_index(snapshot)
        if type(snapshot) ~= "table" then return nil end
        local published = tonumber(snapshot.selectedRow)
        if published ~= nil and published > 0 then return math.floor(published) end
        local index = 0
        for line in (tostring(snapshot.labels or "") .. "\n"):gmatch("(.-)\n") do
            index = index + 1
            if line:match("^%s*>") ~= nil then return index end
        end
        return nil
    end

    -- v0.71.6: a value changed ON THE ROW THE CURSOR IS ON. The whole-rail comparison
    -- 0.71.4 used would also fire for a row that changes by itself, and TTS has several
    -- (engine status, helper heartbeat, voice counts) -- a click with no keypress behind it
    -- is worse than no click at all. Without a published row index there is nothing better
    -- than the whole rail, so that stays as the fallback.
    local function nth_line(text, index)
        if index == nil then return nil end
        local count = 0
        for line in (tostring(text or "") .. "\n"):gmatch("(.-)\n") do
            count = count + 1
            if count == index then return line end
        end
        return nil
    end

    local function changed_value(previous, snapshot, row)
        if row == nil then
            return tostring(previous.values or "") ~= tostring(snapshot.values or "")
        end
        local was, now = nth_line(previous.values, row), nth_line(snapshot.values, row)
        if was == nil or now == nil then
            return tostring(previous.values or "") ~= tostring(snapshot.values or "")
        end
        return was ~= now
    end

    -- v0.71.7 (user, 2026-09-15, after auditioning the palette from the playground's AUDIO
    -- tab): "It would be cool making right (increase) #10 Increase, and making left
    -- (decrease) #11 Decrease for menu options that have a < and > to change values."
    --
    -- v0.71.4 refused to do this because "the values arrive as formatted strings, so
    -- direction would be a guess". The refusal was right about guessing and wrong about
    -- the strings: "360 px" -> "380 px" is not a guess, it is a comparison. So the rule is
    -- read the FIRST NUMBER out of the old and new value and compare them; when either
    -- side has no number -- ON/OFF, a list of names, a keybinding -- there is nothing to
    -- compare and Select stays, which is the honest answer rather than a coin flip.
    local function value_number(text)
        if text == nil then return nil end
        -- Strip the host's own "< >" / "[ ]" selection decoration first, so a stray digit
        -- in the decoration can never be read as the value.
        local body = tostring(text):gsub("^%s*[<%[]%s*", ""):gsub("%s*[>%]]%s*$", "")
        return tonumber(body:match("^%s*(%-?%d+%.?%d*)"))
    end

    local function value_direction(previous, snapshot, row)
        if row == nil then return nil end
        local was = value_number(nth_line(previous.values, row))
        local now = value_number(nth_line(snapshot.values, row))
        if was == nil or now == nil or was == now then return nil end
        return now > was and "Increase" or "Decrease"
    end

    local function play_presentation_audio(previous, snapshot)
        local audio = ui.audio
        if audio == nil or type(snapshot) ~= "table" then return end
        -- Nothing to compare against is the first draw of a session, which the open
        -- sound already covers; a second Open here would double it.
        if type(previous) ~= "table" then return end
        local event = nil
        if tostring(previous.profile or "") ~= tostring(snapshot.profile or "")
            or tostring(previous.selectedTab or "") ~= tostring(snapshot.selectedTab or "") then
            -- A tab change moves the row and rewrites every value, so it is checked first
            -- or it would be heard as three sounds at once.
            event = "TabSwitch"
        else
            local was, now = selected_row_index(previous), selected_row_index(snapshot)
            if was ~= nil and now ~= nil and was ~= now then
                event = "Hover"
            elseif changed_value(previous, snapshot, now) then
                event = value_direction(previous, snapshot, now) or "Select"
            end
        end
        if event == nil then return end
        pcall(audio.Play, event, ui.widget)
    end

    render_presentation_body = function(snapshot)
        if type(snapshot) ~= "table" or not valid(ui.widget) then return false, "snapshot-or-shell-invalid" end
        -- v0.71.0: header rows become divider lines before anything measures, clips,
        -- windows or hit-tests the labels, so every later stage sees what is drawn.
        if tostring(snapshot.profile or "main") ~= "browser" then
            local decorated, header_count = decorate_headers(snapshot.labels, snapshot.rowKinds)
            if header_count > 0 then
                local copy = {}
                for key, value in pairs(snapshot) do copy[key] = value end
                copy.labels = decorated
                snapshot = copy
            end
        end
        local changed, changed_fields
        snapshot, changed, changed_fields = PresentationSafety.Sanitize(snapshot)
        if changed == true then
            local signature = tostring(snapshot.profile or "main") .. ":" .. table.concat(changed_fields or {}, ",")
            if signature ~= tostring(ui.last_clip_signature or "") then
                ui.last_clip_signature = signature
                diag("host.shell.presentationSafety", {
                    status = "clipped",
                    profile = tostring(snapshot.profile or "main"),
                    fields = table.concat(changed_fields or {}, ","),
                    consumer = tostring(ui.consumer or ""),
                    generation = tonumber(ui.generation) or 0,
                })
            end
        else
            ui.last_clip_signature = ""
        end
        -- Adaptive rail widths come from the whole tab so they match what the pointer
        -- hit-test resolves; only the rendered rows are windowed.
        local resolved = type(Layout.ResolveAdaptive) == "function"
            and Layout.ResolveAdaptive(snapshot.profile, snapshot.labels or "", snapshot.values or "", ui.calibration) or nil
        -- v0.70.2 (user): the rails follow the tab that is showing, both ways. 0.70.1
        -- kept the widest width seen per open so the window would not change size on a
        -- tab switch; she wants the space given back when a narrower tab no longer
        -- needs it, so each tab is sized on its own again.
        apply_profile(snapshot.profile, snapshot)
        play_presentation_audio(ui.last_presentation, snapshot)
        ui.last_resolved = resolved
        ui.last_presentation = snapshot
        -- v0.70.0: the strip. The host lays the visible window of tabs out from the
        -- measured glyph and remembers it, so the pointer regions it resolves are the
        -- regions it drew (Settings/Layout.TabWindow).
        local strip = nil
        if type(resolved) == "table" and resolved.profile ~= "browser" and type(Layout.TabWindow) == "function" then
            local tab_labels = {}
            for line in (tostring(snapshot.tabLabels or "") .. "\n"):gmatch("(.-)\n") do
                if line ~= "" then tab_labels[#tab_labels + 1] = line end
            end
            if #tab_labels > 0 then
                strip = Layout.TabWindow(tab_labels, tonumber(snapshot.selectedTab) or 1,
                    resolved.tabWidth, ui.calibration.glyphWidth, ui.tab_first)
                ui.tab_first = strip.first
            end
        end
        ui.last_strip = strip
        local windowed
        snapshot, windowed = Viewport.Apply(snapshot)
        if windowed and ui.last_scroll_first ~= snapshot.scrollFirst then
            ui.last_scroll_first = snapshot.scrollFirst
            diag("host.shell.viewport", {
                status = "windowed", first = snapshot.scrollFirst, rows = snapshot.scrollRows,
                total = snapshot.scrollTotal, consumer = tostring(ui.consumer or ""),
            })
        elseif not windowed then
            ui.last_scroll_first = nil
        end
        if not valid(ui.header_widget) then ui.header_widget = native_widget_field(ui.widget, "Text_PromptName") end
        if not valid(ui.body_widget) then ui.body_widget = native_widget_field(ui.widget, "RTB_ReadText") end
        if not valid(ui.page_widget) then ui.page_widget = native_widget_field(ui.widget, "Text_Page_Status") end
        local header_ok = set_native_text_direct(ui.header_widget, snapshot.header or "MOD SETTINGS", "header")
        local page_ok = set_native_text_direct(ui.page_widget, snapshot.page or "", "page")
        local body_text = tostring(snapshot.body or "")
        local body_ok = set_native_text_direct(ui.body_widget, body_text, "body")
        local rails_ok = ui.presentation_mode == "rails"
        local native_controls_ok = false
        if type(ui.native_controls) == "table" and type(ui.native_controls.Render) == "function"
            and valid(ui.native_details_container) and type(resolved) == "table" then
            local ok_controls, active = pcall(ui.native_controls.Render,
                ui.native_details_container, snapshot, resolved)
            native_controls_ok = ok_controls and active == true
        end
        ui.native_controls_active = native_controls_ok
        if valid(ui.native_tabs_widget) then set_native_visibility(ui.native_tabs_widget, native_controls_ok and 1 or 0) end
        if valid(ui.native_labels_widget) then set_native_visibility(ui.native_labels_widget, native_controls_ok and 1 or 0) end
        if valid(ui.native_values_widget) then set_native_visibility(ui.native_values_widget, native_controls_ok and 1 or 0) end
        if rails_ok and not native_controls_ok then
            local strip_text = strip ~= nil and strip.text or tostring(snapshot.tabs or "")
            rails_ok = set_native_text_direct(ui.native_tabs_text, strip_text, "tabs")
                and set_native_text_direct(ui.native_labels_text, snapshot.labels or "", "labels")
                and set_native_text_direct(ui.native_values_text, snapshot.values or "", "values")
            if valid(ui.native_tabs_text) then
                pcall(function()
                    -- v0.70.0: left-justified, so the strip starts at the rail's left edge
                    -- (a centred string wider than the rail spilled off both sides).
                    ui.native_tabs_text:SetJustification(0)
                    ui.native_tabs_text:SetAutoWrapText(false)
                    ui.native_tabs_text.WrapTextAt = 0.0
                end)
            end
            -- Measure what was just drawn on a later tick, once Slate has laid it out.
            -- v0.70.3: both profiles -- the browser (controller screen, voice browser)
            -- sizes its rails from the same glyph.
            if type(resolved) == "table" and type(Layout.MaxLineUnits) == "function" then
                ui.measure = {
                    tries = 0,
                    labels_units = Layout.MaxLineUnits(snapshot.labels or "", 0),
                    values_units = Layout.MaxLineUnits(snapshot.values or "", 0),
                    tabs_units = strip ~= nil and Layout.LineUnits(strip.text) or 0,
                    label_rail = tonumber(resolved.labelWidth) or 0,
                    value_rail = tonumber(resolved.valueWidth) or 0,
                    tab_rail = tonumber(resolved.tabWidth) or 0,
                }
            end
        end
        if valid(ui.native_details_widget) then
            local name = native_widget_field(ui.native_details_widget, "SettingName")
            local description = native_widget_field(ui.native_details_widget, "RichSettingDescription")
            local title = tostring(snapshot.detailTitle or "")
            local details = tostring(snapshot.details or "")
            pcall(function() ui.native_details_widget.MyName = FText(title) end)
            pcall(function() ui.native_details_widget.MyDescription = FText(details) end)
            set_native_text_direct(name, title, "detailTitle")
            set_native_text_direct(description, details, "details")
            local build = ui.native_details_widget["BuildName"]
            if build ~= nil then pcall(build, ui.native_details_widget) end
        end
        ui.presentation_sequence = math.max(ui.presentation_sequence, tonumber(snapshot.sequence) or 0)
        local mode = native_controls_ok and "native-controls" or ui.presentation_mode
        return header_ok and page_ok and (native_controls_ok or rails_ok or body_ok), mode
    end

    -- v0.70.0: read the natural width of each rail's text block (our own widgets; the
    -- read is a cached desired size, zero until Slate's first layout pass, so it is
    -- retried a few ticks and never trusted at zero). The widest rail against its glyph
    -- count gives the glyph width the font really has; when that moves the layout, the
    -- last presentation is drawn again with the new widths, and the strip window with it.
    local function desired_width(widget)
        widget = unwrap(widget)
        if not valid(widget) or widget["GetDesiredSize"] == nil then return nil end
        local got = nil
        pcall(function() got = widget:GetDesiredSize() end)
        if got == nil then return nil end
        local w = nil
        pcall(function() w = tonumber(got.X) end)
        if w == nil or w ~= w or w <= 1.0 then return nil end
        return w
    end

    local function measure_rails()
        local m = ui.measure
        if m == nil or m.done or not valid(ui.widget) then return false end
        m.tries = m.tries + 1
        if m.tries > 12 then m.done = true; return false end
        local lw, vw, tw = desired_width(ui.native_labels_text), desired_width(ui.native_values_text), desired_width(ui.native_tabs_text)
        if lw == nil and vw == nil and tw == nil then return false end
        local best = nil
        local function consider(width, units)
            if width == nil or units == nil or units < 3 then return end
            local ratio = width / units
            if ratio > 4.0 and ratio < 200.0 and (best == nil or ratio > best) then best = ratio end
        end
        consider(lw, m.labels_units); consider(vw, m.values_units); consider(tw, m.tabs_units)
        m.done = true
        if best == nil then return false end
        local previous = tonumber(ui.calibration.glyphWidth)
        -- Take the widest reading, never a narrower one: an under-estimate clips text,
        -- an over-estimate only spends a little width.
        if previous == nil or best > previous * 1.02 then
            ui.calibration.glyphWidth = best
            ui.calibration.source = "measured"
            remembered_glyph = best
            diag("host.shell.measured", {
                status = "calibrated", glyphWidth = string.format("%.2f", best),
                labels = lw and string.format("%.0f", lw) or "n/a", values = vw and string.format("%.0f", vw) or "n/a",
                tabs = tw and string.format("%.0f", tw) or "n/a", consumer = tostring(ui.consumer or ""),
            })
            ui.relayout_pending = true
            return true
        end
        return false
    end

    local function open_shell(selected, generation, presentation)
        if valid(ui.widget) then return true, "already-active" end
        local player, controller = ModUI.Runtime.Resolve.PlayerController(FindFirstOf, FindAllOf)
        player, controller = unwrap(player), unwrap(controller)
        if not valid(player) or not valid(controller) then return false, "player-controller-invalid" end
        local handler = select(1, ModUI.Runtime.Resolve.UIHandlerWithFallback(player, {
            LoadAsset = LoadAsset, StaticFindObject = StaticFindObject, FindFirstOf = FindFirstOf,
            BPFLAsset = NATIVE_BPFL_UI_ASSET, BPFLCdo = NATIVE_BPFL_UI_CDO,
        }))
        handler = unwrap(handler)
        if not valid(handler) then return false, "ui-handler-invalid" end
        pcall(function() if LoadAsset ~= nil then LoadAsset(NATIVE_SETTINGS_ASSET) end end)
        local widget_class = StaticFindObject ~= nil and unwrap(StaticFindObject(NATIVE_SETTINGS_CLASS)) or nil
        local library = StaticFindObject ~= nil and unwrap(StaticFindObject(WIDGET_BLUEPRINT_LIBRARY_CDO)) or nil
        if not valid(widget_class) or not valid(library) or library["Create"] == nil then
            return false, "widget-class-library-unavailable"
        end
        local ok_create, widget = pcall(library["Create"], library, player, widget_class, controller)
        widget = unwrap(widget)
        if not ok_create or not valid(widget) then return false, "widget-create-failed" end
        pcall(function() widget.bShouldRemoveOnDeath = false end)
        pcall(function() widget.bPauseGame = false end)
        disable_embedded_reader_listener(widget)
        local ok_add = pcall(function() widget:AddToViewport(10000) end)
        if not ok_add then pcall(function() widget:RemoveFromParent() end); return false, "add-to-viewport-failed" end
        disable_embedded_reader_listener(widget)
        retire_visual_shell(widget, handler, false)
        ui.widget, ui.controller, ui.widget_library, ui.handler = widget, controller, library, handler
        ui.tab_first, ui.last_strip, ui.last_resolved, ui.last_presentation = 1, nil, nil, nil
        ui.measure, ui.relayout_pending = nil, false
        -- v0.71.4: the shell is up. last_presentation is nil here, which is what
        -- keeps the first draw's diff silent -- this is the only Open.
        -- v0.71.8: a STAND-IN, not the game's menu open -- see OPEN_EVENT at the top.
        if ui.audio ~= nil then pcall(ui.audio.Play, OPEN_EVENT, widget) end
        if remembered_glyph ~= nil then ui.calibration = { glyphWidth = remembered_glyph, source = "remembered" } end
        ui.consumer = tostring(selected.consumer or "")
        ui.slot = math.floor(tonumber(selected.slot) or -1)
        ui.revision = math.max(0, math.floor(tonumber(selected.revision) or 0))
        ui.generation = math.max(0, math.floor(tonumber(generation) or 0))
        ui.header_widget = native_widget_field(widget, "Text_PromptName")
        ui.body_widget = native_widget_field(widget, "RTB_ReadText")
        ui.page_widget = native_widget_field(widget, "Text_Page_Status")
        create_native_ui_foundation(player, controller, library, widget)
        local native_factory = type(ModUI.Settings) == "table" and ModUI.Settings.NativeControls or nil
        if type(native_factory) == "table" and native_factory.RUNTIME_ENABLED == true
            and type(native_factory.Bind) == "function"
            and valid(ui.native_details_container) then
            local native_font = nil
            pcall(function()
                if LoadAsset ~= nil then LoadAsset(native_factory.assets.font) end
                if StaticFindObject ~= nil then native_font = unwrap(StaticFindObject(native_factory.assets.fontObject)) end
            end)
            local controls, controls_err = native_factory.Bind({
                unwrap = unwrap, valid = valid, field = native_widget_field,
                create = function(asset_path, class_path)
                    return create_native_child_widget(player, controller, library, asset_path, class_path)
                end,
                ftext = FText, font = native_font, log = log,
                -- v0.69.1: the strip rule lives in Layout so the drawn cells and the
                -- pointer regions cannot disagree.
                tab_strip = Layout.TabStrip,
            })
            if type(controls) == "table" then
                ui.native_controls = controls
            else
                log("native settings controls unavailable; passive rails retained: " .. tostring(controls_err))
            end
        end
        if not acquire_input_mode(controller, library, widget) then
            retire_visual_shell(widget, handler, true)
            pcall(function() widget:RemoveFromParent() end)
            clear_refs()
            return false, "input-mode-failed"
        end
        disable_embedded_reader_listener(widget)
        if type(presentation) == "table" then render_presentation(presentation) end
        log("visible shell active consumer=" .. ui.consumer .. " generation=" .. tostring(ui.generation)
            .. " address=" .. tostring(object_address(widget) or "") .. " mode=" .. tostring(ui.presentation_mode))
        return true, "active"
    end

    local self = {}

    function self.State()
        return {
            active = valid(ui.widget), consumer = ui.consumer, slot = ui.slot, revision = ui.revision,
            generation = ui.generation, sequence = ui.presentation_sequence,
            address = valid(ui.widget) and tostring(object_address(ui.widget) or "") or "",
            mode = ui.native_controls_active and "native-controls" or ui.presentation_mode,
            profile = ui.window_profile,
            quarantined = ui.world_quarantined == true,
        }
    end

    function self.WorldPreload(reason)
        ui.world_quarantined = true
        -- Never inspect/dereference cached old-world wrappers inside this boundary.
        clear_refs()
        log("visible shell world quarantine reason=" .. tostring(reason or "LoadMap-pre"))
        return true
    end

    function self.WorldPostload(reason)
        ui.world_quarantined = false
        log("visible shell world quarantine released reason=" .. tostring(reason or "LoadMap-post"))
        return true
    end

    function self.Close(reason)
        local address = close_shell(reason, true)
        return true, address
    end

    -- v0.70.0: the host's own answer to "what is under the pointer", from the layout it
    -- drew. Nil when no shell is up or nothing is under the point; the consumer then
    -- falls back to its own model.
    function self.ResolvePointer(event)
        if not valid(ui.widget) or type(ui.last_resolved) ~= "table" or type(ui.last_presentation) ~= "table" then return nil end
        local interaction = type(ModUI.Settings) == "table" and ModUI.Settings.Interaction or nil
        if type(interaction) ~= "table" or type(interaction.Hit) ~= "function" then return nil end
        local ok, hit = pcall(M.ResolvePointerAgainst, Layout, interaction, ui.last_resolved, ui.last_strip, ui.last_presentation, event)
        return ok and type(hit) == "table" and hit or nil
    end

    function self.Calibration()
        return { glyphWidth = ui.calibration.glyphWidth, source = ui.calibration.source }
    end

    function self.Tick(menu_report, selected)
        menu_report = type(menu_report) == "table" and menu_report or {}
        selected = type(selected) == "table" and selected or nil
        local state = tostring(menu_report.state or "idle")
        local lease = type(menu_report.lease) == "table" and menu_report.lease or {}
        local generation = math.max(0, math.floor(tonumber(menu_report.generation) or 0))
        local wants_visible = selected ~= nil and type(selected.fields) == "table"
            and tostring(selected.fields.visibleShell or "0") == "1"
            and tostring(selected.fields.presentation or "0") == "1"
        local active_session = state == "opening" or state == "ready" or state == "closing"
        local lease_ok = tostring(lease.state or "idle") == "granted"
        if ui.world_quarantined then return { state = "quarantined", active = false } end
        if not wants_visible or not active_session or not lease_ok then
            if valid(ui.widget) and (state == "closed" or state == "idle" or not wants_visible) then
                self.Close("session-" .. state)
            end
            return { state = valid(ui.widget) and "active" or "ready", active = valid(ui.widget) }
        end
        local presentation = registry.ReadConsumerMenuPresentation(
            selected.slot, selected.consumer, selected.revision, generation)
        if type(presentation) == "table" then presentation = decorate_provider_header(presentation, menu_report) end
        if not valid(ui.widget) and type(presentation) ~= "table" then
            return {
                state = "waiting-presentation", active = false,
                consumer = tostring(selected.consumer or ""), slot = math.floor(tonumber(selected.slot) or -1),
                revision = math.max(0, math.floor(tonumber(selected.revision) or 0)), generation = generation,
                sequence = 0, address = "", mode = "single-owner",
            }
        end
        if not valid(ui.widget) then
            local ok, status = open_shell(selected, generation, presentation)
            if not ok then return { state = "degraded", active = false, error = status } end
        elseif ui.consumer ~= tostring(selected.consumer or "") or ui.generation ~= generation then
            self.Close("provider-or-generation-changed")
            local ok, status = open_shell(selected, generation, presentation)
            if not ok then return { state = "degraded", active = false, error = status } end
        else
            local selected_revision = math.max(0, math.floor(tonumber(selected.revision) or 0))
            if ui.revision ~= selected_revision then
                -- Pass 161: provider revisions mutate descriptor/configuration state, not the
                -- physical menu session. Preserve the exact visible UMG instance across a
                -- same-consumer/same-generation revision and render the new revision snapshot
                -- in place. This is the visible-shell analogue of Pass-153 listener continuity.
                local prior_revision = ui.revision
                ui.revision = selected_revision
                ui.slot = math.floor(tonumber(selected.slot) or ui.slot)
                ui.presentation_sequence = 0
                ui.render_text_cache = {}
                log("visible shell revision continuity consumer=" .. tostring(ui.consumer)
                    .. " generation=" .. tostring(ui.generation)
                    .. " revision=" .. tostring(prior_revision) .. "->" .. tostring(selected_revision)
                    .. " address=" .. tostring(object_address(ui.widget) or ""))
            end
        end
        if type(presentation) == "table" and (tonumber(presentation.sequence) or 0) > ui.presentation_sequence then
            local ok, mode = render_presentation(presentation)
            if not ok then return { state = "degraded", active = true, error = "render-failed:" .. tostring(mode) } end
        elseif measure_rails() or ui.relayout_pending then
            -- v0.70.0: a measurement changed the layout; draw the same presentation again
            -- with the rails and strip sized from it.
            ui.relayout_pending = false
            if type(ui.last_presentation) == "table" then
                ui.render_text_cache = {}
                render_presentation(ui.last_presentation)
            end
        end
        return {
            state = "active", active = true, consumer = ui.consumer, slot = ui.slot,
            revision = ui.revision, generation = ui.generation, sequence = ui.presentation_sequence,
            address = tostring(object_address(ui.widget) or ""), mode = ui.presentation_mode,
        }
    end

    -- shell.tick: the whole visible-shell reconciliation, one per host poll. It
    -- encloses shell.render (presentation writes into native widgets).
    local tick_body = self.Tick
    function self.Tick(menu_report, selected)
        local perf = ModUI.Perf
        local token = perf ~= nil and perf.Begin() or nil
        local report = tick_body(menu_report, selected)
        if token ~= nil then perf.End("shell.tick", token) end
        return report
    end

    return self
end

return M
