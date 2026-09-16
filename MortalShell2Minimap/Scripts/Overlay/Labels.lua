-- Map labels: the region name under the minimap, and cardinal letters on its edge.
--
-- v0.11.0, and deliberately conservative: text is new ground for this mod (ModUI
-- v0.67.1 had to gate its own text experiment), so every step is pcall'd, the whole
-- layer ships off (Config.MapLabels = 0), and any failure logs once and stays quiet.
--
-- The region name comes from the game's landing-area notify, whose Text_Name is a
-- real place name. The string is copied inside that live callback -- as a plain Lua
-- string, never as an FText pointing into the game's widget memory -- and so is its
-- font, which is how our labels end up in Trajan Pro instead of Roboto. No widget of
-- the game's, and no struct of the game's, is ever retained.
--
-- Three runtime findings shaped this file, in order:
--   * v0.11.0 crashed: SetText was called with a raw Lua string where a UFunction
--     expects an FText. That is an access violation inside UE4SS, not a Lua error, so
--     the surrounding pcall was worthless.
--   * v0.11.1 refused to build and said why: this UE4SS has no FText global at all
--     (textApi=false), so the ModUI/TTS `FText(...)` form cannot work here either --
--     those call sites are all inside pcalls and have simply been failing quietly.
--     The constructor now comes from UKismetTextLibrary.Conv_StringToText, and no
--     candidate is used until it round-trips a probe string through ToString().
--   * The same run showed WBP_Notify_Large_AreaName_C is the generic large-notify
--     widget, not a region announcement: it gave us "Gloom Retrieved" fourteen times.
--     It is now read for evidence only and the landing-area notify is the source.
--
-- Fonts are written as one whole FSlateFontInfo struct built from plain values, never
-- by reading .Font and assigning into .Size, because a struct read returns a copy.

local Factory = {}

function Factory.New(ctx)
    local state = assert(ctx.State, "Overlay.Labels requires State")
    local Config = assert(ctx.Config, "Overlay.Labels requires Config")
    local Object = assert(ctx.Object, "Overlay.Labels requires Core.Object")
    local log = assert(ctx.Log, "Overlay.Labels requires Log")
    local Perf = type(ctx.Perf) == "table" and ctx.Perf
        or { Begin = function() return nil end, End = function() end, Count = function() end }
    local unwrap, valid = Object.Unwrap, Object.Valid

    local TEXT_CLASS_PATH = "/Script/UMG.TextBlock"
    local KISMET_TEXT_PATH = "/Script/Engine.Default__KismetTextLibrary"
    local PROBE_STRING = "MS2Minimap"
    -- Two sources, both first-class.
    --
    -- v0.11.2 demoted WBP_Notify_Large_AreaName_C to evidence-only because it handed us
    -- "Gloom Retrieved" fourteen times in eleven minutes, and concluded it was a generic
    -- notification widget. Half right: the user's 2026-09-12 12:32 screenshot shows the
    -- same widget announcing "Sanguine Caverns" in the game's own big Trajan. It really
    -- is the area-name notify, just shared with other announcements -- and demoting it
    -- is why the label stayed blank through a session that visibly named the area. It is
    -- a source again alongside the landing-area notify, most recent name wins. Filtering
    -- a non-place string is one condition here, and much cheaper than never showing one.
    local LANDING_NOTIFY = "/Game/Sparta/UI/Notifies/WBP_Notify_Large_LandingArea."
        .. "WBP_Notify_Large_LandingArea_C"
    local AREA_NOTIFY = "/Game/Sparta/UI/Notifies/WBP_Notify_Large_AreaName."
        .. "WBP_Notify_Large_AreaName_C"
    -- The game's own Trajan face, resolved by path. v0.11.2 tried to restyle the
    -- TextBlock's default font instead and that never took: the 2026-09-12 screenshots
    -- came back at the UMG default of 24 (46 px on screen), which is why the letters
    -- were "large white letters". ModUI's Settings/NativeControls.lua has always
    -- assigned a whole FSlateFontInfo built around a font asset it resolved itself,
    -- and that is the shape used here. TypefaceFontName "Default" is the only typeface
    -- in Trajan_Pro_Regular_Font's composite font (FModel export).
    -- v0.17.1 (user: "adjust the label size / text style / color ... and maybe some
    -- fonts"): the game's own font assets, from the 2026-09-12 object dump. Every entry
    -- is a UFont composite (the shape Trajan has always been used in). v0.17.2: the two
    -- Cormorant Unicase entries are gone -- they were UFontFace assets, and a
    -- FSlateFontInfo whose FontObject is a bare face draws NOTHING (her 2026-09-14
    -- report: "the Cormorant fonts don't show anything"); only a UFont carries the
    -- composite Slate reads. resolve_choice now refuses anything but a Font, so a
    -- face can never blank the labels again. "game" adopts whatever face the game's
    -- own area announcement used, once one has been seen.
    local FONT_CHOICES = {
        { key = "trajan", label = "Trajan", package = "/Game/Sparta/UI/Fonts/Trajan_Pro_Regular_Font",
          paths = { "/Game/Sparta/UI/Fonts/Trajan_Pro_Regular_Font.Trajan_Pro_Regular_Font", "/Game/Sparta/UI/Fonts/Trajan_Pro_Regular_Font.0" } },
        { key = "trajanbold", label = "Trajan SemiBold", package = "/Game/Sparta/UI/Fonts/Trajan_Pro_SemiBold_Font",
          paths = { "/Game/Sparta/UI/Fonts/Trajan_Pro_SemiBold_Font.Trajan_Pro_SemiBold_Font" } },
        { key = "trajansub", label = "Trajan Subtitles", package = "/Game/Sparta/UI/Fonts/Trajan_Pro_SemiBold_Font_Subtitles",
          paths = { "/Game/Sparta/UI/Fonts/Trajan_Pro_SemiBold_Font_Subtitles.Trajan_Pro_SemiBold_Font_Subtitles" } },
        { key = "crimson", label = "Crimson Text", package = "/Game/Sparta/UI/Fonts/CrimsonText-Regular_Font",
          paths = { "/Game/Sparta/UI/Fonts/CrimsonText-Regular_Font.CrimsonText-Regular_Font" } },
        { key = "crimsonsemi", label = "Crimson SemiBold", package = "/Game/Sparta/UI/Fonts/CrimsonText-SemiBold_Font",
          paths = { "/Game/Sparta/UI/Fonts/CrimsonText-SemiBold_Font.CrimsonText-SemiBold_Font" } },
        { key = "crimsonbold", label = "Crimson Bold", package = "/Game/Sparta/UI/Fonts/CrimsonText-Bold_Font",
          paths = { "/Game/Sparta/UI/Fonts/CrimsonText-Bold_Font.CrimsonText-Bold_Font" } },
        { key = "crimsonitalic", label = "Crimson Italic", package = "/Game/Sparta/UI/Fonts/CrimsonText-Italic_Font",
          paths = { "/Game/Sparta/UI/Fonts/CrimsonText-Italic_Font.CrimsonText-Italic_Font" } },
        { key = "game", label = "Game announcement", package = nil, paths = {} },
    }
    local FONT_BY_KEY = {}
    for _, choice in ipairs(FONT_CHOICES) do FONT_BY_KEY[choice.key] = choice end
    local FONT_FALLBACK = FONT_CHOICES[1]
    -- Label colors (FSlateColor SpecifiedColor). "white" is the parchment white the
    -- labels have worn since v0.11.x.
    local LABEL_COLORS = {
        white  = { R = 0.98, G = 0.96, B = 0.92, A = 1.0 },
        gold   = { R = 0.92, G = 0.78, B = 0.45, A = 1.0 },
        bronze = { R = 0.72, G = 0.60, B = 0.40, A = 1.0 },
        red    = { R = 0.90, G = 0.25, B = 0.20, A = 1.0 },
        blue   = { R = 0.45, G = 0.68, B = 0.98, A = 1.0 },
        green  = { R = 0.50, G = 0.85, B = 0.50, A = 1.0 },
        grey   = { R = 0.70, G = 0.70, B = 0.68, A = 1.0 },
        black  = { R = 0.05, G = 0.05, B = 0.05, A = 1.0 },
    }
    local LABEL_COLOR_ORDER = { "white", "gold", "bronze", "red", "blue", "green", "grey", "black" }
    local OUTLINE_BLACK = { R = 0.0, G = 0.0, B = 0.0, A = 0.9 }
    local SHADOW_COLOR = { R = 0.0, G = 0.0, B = 0.0, A = 0.85 }
    local VIS_COLLAPSED = 1
    local VIS_HIT_TEST_INVISIBLE = 3
    local CARDINALS = { { key = "N", angle = 0.0 }, { key = "E", angle = 90.0 },
        { key = "S", angle = 180.0 }, { key = "W", angle = 270.0 } }
    -- Sizes follow the minimap, so the letters read the same at any map size, and the
    -- ink color is the map's own rather than white-on-parchment. MapLabelSize in the
    -- ini overrides the scaled value outright (user, 2026-09-12: the scaled ones were
    -- still too large).
    local CARDINAL_SIZE_RATIO = 0.028
    local AREA_SIZE_RATIO = 0.034
    -- The user asked for white text over the fog plate the icons use: the dark ink read
    -- as part of the drawing but was hard to actually read (2026-09-12).
    local INK = LABEL_COLORS.white
    local function ink_color()
        return LABEL_COLORS[tostring(Config.MapLabelColor or "white"):lower()] or INK
    end
    local function outline_size()
        return math.max(0, math.min(3, math.floor(tonumber(Config.MapLabelOutline) or 0)))
    end
    local function shadow_wanted() return Config.MapLabelShadow == true end
    local function font_choice()
        return FONT_BY_KEY[tostring(Config.MapLabelFont or "trajan"):lower()] or FONT_FALLBACK
    end
    local IMAGE_CLASS_PATH = "/Script/UMG.Image"
    local PLATE_TINT = { R = 1.0, G = 1.0, B = 1.0, A = 0.72 }
    local PLATE_HEIGHT_SCALE = 2.1
    -- A rough per-character advance for Trajan caps, used to size the fog behind the
    -- area name. The TextBlock auto-sizes itself, so its real width is not available
    -- here; the fog is a soft blob, so an estimate that errs wide is fine.
    local PLATE_GLYPH_WIDTH = 0.72
    local PLATE_PAD = 1.4
    -- v0.16.2 (user, 2026-09-13): the fog is a soft blob whose dark core is well inside
    -- its box, so a plate the width of the text supported only the middle of it. Twice
    -- the width puts the core behind the whole line.
    local PLATE_WIDTH_SCALE = 2.0
    -- UTextBlock::SetColorAndOpacity takes an FSlateColor, which wraps an
    -- FLinearColor in SpecifiedColor -- NOT the bare FLinearColor that UImage's
    -- identically named setter takes. v0.11.3 passed the UImage shape and the letters
    -- vanished completely: a write that pcall reported as fine produced a transparent
    -- color. Ownership invariant 0b again, this time across two widget types with the
    -- same method name. So the shape is decided on a throwaway probe widget before any
    -- real label is touched, and if none of them reads back correctly the labels keep
    -- their default white and stay visible.
    local INK_CANDIDATES = {
        { name = "FSlateColor", make = function(c) return { SpecifiedColor = c, ColorUseRule = 0 } end },
        { name = "FLinearColor", make = function(c) return c end },
    }
    local EDGE_PADDING = 6.0

    local function map_size()
        return math.max(80, math.floor(tonumber(Config.Size) or 300))
    end

    local function scaled_font_size(ratio, minimum, maximum)
        local value = math.floor(map_size() * ratio + 0.5)
        return math.max(minimum, math.min(maximum, value))
    end

    local function cardinal_font_size()
        local explicit = tonumber(Config.MapLabelSize)
        if explicit ~= nil and explicit > 0 then
            return math.max(6, math.min(28, math.floor(explicit + 0.5)))
        end
        return scaled_font_size(CARDINAL_SIZE_RATIO, 6, 28)
    end

    local function area_font_size()
        local explicit = tonumber(Config.MapLabelSize)
        if explicit ~= nil and explicit > 0 then
            return math.max(7, math.min(32, math.floor(explicit + 0.5) + 2))
        end
        return scaled_font_size(AREA_SIZE_RATIO, 7, 32)
    end

    -- The second line is deliberately smaller than the area name: it is the more
    -- specific, less important half, and two lines of equal weight under a 500 px map
    -- read as a heading rather than a location.
    local function sub_font_size()
        return math.max(6, area_font_size() - 2)
    end

    local function sub_enabled()
        return Config.MapAreaSubLabel ~= false
    end

    -- Which letters to draw. The user only wants north (2026-09-12); MapLabelCardinals
    -- = 4 in the ini brings all four back.
    local function cardinal_wanted(key)
        if math.floor(tonumber(Config.MapLabelCardinals) or 1) >= 4 then return true end
        return key == "N"
    end

    -- The compass ring sits exactly on the map edge by default, so a centre-anchored
    -- letter straddles it half in and half out (user request). Positive inset pulls it
    -- inward, negative pushes it out.
    local function ring_inset()
        return math.max(-40.0, math.min(60.0, tonumber(Config.MapLabelInset) or 0.0))
    end

    local MAX_NAME_CHARS = 64
    -- Breathing room between the two label lines, on top of their own line boxes.
    local LINE_GAP = 2.0
    -- How many frames to keep asking a fresh label for its rendered size.
    local MEASURE_MAX_TRIES = 8

    state.labels = state.labels or {
        area = nil, cardinals = {}, text_class = nil, font_object = nil, ready = false,
        area_name = nil, area_dirty = false, font_ready = false, text_api = false,
        -- v0.12.0 second line: the sub-area (a dungeon, or a beacon you are standing
        -- at). Line one is always the outer area (user decision, 2026-09-12).
        sub = nil, sub_name = nil, sub_dirty = false, sub_source = "none",
        make_text = nil, text_source = "none", generic_name = nil,
        notify_name = nil, notify_source = "none",
        ink_shape = nil, ink_source = "none", parent_kind = "none",
        font_key = nil, font_resolved = "none", font_fallback = nil,
        font_readback = nil, game_font = nil,
        name_source = "none", image_class = nil, plate_texture = nil,
        plate_path = (type(ctx.LocalClassifier) == "table"
            and ctx.LocalClassifier.PlateIconPath) or nil,
        hooks = {}, last_angle = nil, last_mode = nil,
        -- v0.18.44: the compass ring's geometry as last drawn. Keying the reposition on
        -- these rather than on the rotation angle alone is what lets the letters follow a
        -- live resize. Nothing resets them explicitly: last_angle = nil already forces a
        -- recompute at every site that wants one, and that rewrites all three.
        last_ring_radius = nil, last_ring_x = nil, last_ring_y = nil,
        metrics = {
            hook_events = 0, names_captured = 0, font_captures = 0, font_failures = 0,
            generic_events = 0,
            builds = 0, build_failures = 0, text_writes = 0, text_failures = 0,
            font_applies = 0, font_setfont = 0, font_property = 0,
            position_writes = 0, visibility_writes = 0, updates = 0,
            hook_failures = 0, ink_writes = 0, plates = 0, plate_failures = 0,
            measures = 0, names_cleared = 0, names_observed = 0,
        },
    }
    local labels = state.labels

    -- Labels are children of the renderer's OUTER canvas, not the minimap frame.
    -- The frame clips (Clipping = 1) and, in circle mode, is inside the mask and the
    -- opacity RetainerBox, so anything parented there cannot cross the edge. The outer
    -- canvas is the full-screen root the frame itself is placed on, so a label can sit
    -- anywhere; it costs nothing per frame, because it is the same widget count and
    -- the same one position write. Coordinates there include the map's screen offset.
    local function label_parent()
        local retained = state.retained
        if type(retained) ~= "table" then return nil, "none" end
        if valid(retained.root) then return retained.root, "root" end
        if valid(retained.frame) then return retained.frame, "frame" end
        return nil, "none"
    end

    local function parent_origin()
        if labels.parent_kind == "root" then
            return tonumber(Config.OffsetX) or 0.0, tonumber(Config.OffsetY) or 0.0
        end
        return 0.0, 0.0
    end


    local function mode()
        return math.max(0, math.min(3, math.floor(tonumber(Config.MapLabels) or 0)))
    end

    local function area_enabled() local m = mode() return m == 1 or m == 3 end
    local function cardinals_enabled() local m = mode() return m == 2 or m == 3 end

    local function find_object(path)
        local token = Perf.Begin()
        local ok, value = pcall(StaticFindObject, path)
        Perf.End("native.find", token)
        value = unwrap(ok and value or nil)
        return valid(value) and value or nil
    end

    local function make_name(base)
        state.widget_counter = (tonumber(state.widget_counter) or 0) + 1
        return FName("MS2Minimap_" .. tostring(base) .. "_" .. tostring(state.widget_counter))
    end

    -- Anything the game hands us -- an FText, an FName, a string -- becomes a short,
    -- single-line Lua string here, so nothing we keep points at the game's memory.
    local function to_plain_string(value)
        if value == nil then return nil end
        local text = nil
        if type(value) == "string" then
            text = value
        else
            pcall(function() text = value:ToString() end)
            if type(text) ~= "string" then
                local ok, alt = pcall(tostring, value)
                text = ok and type(alt) == "string" and alt or nil
            end
        end
        if type(text) ~= "string" then return nil end
        text = text:gsub("[%c]+", " "):gsub("^%s+", ""):gsub("%s+$", "")
        if text == "" then return nil end
        if #text > MAX_NAME_CHARS then text = text:sub(1, MAX_NAME_CHARS) end
        return text
    end

    -- What the Lua environment actually offers, named once so a failure here is a
    -- fact in the log rather than another guess. Read-only: type() and nothing else.
    local function text_global_inventory()
        local names = {}
        local ok = pcall(function()
            for key, value in pairs(_G) do
                local name = type(key) == "string" and key or nil
                if name ~= nil and string.find(string.lower(name), "text", 1, true) then
                    names[#names + 1] = name .. "=" .. type(value)
                end
            end
        end)
        if not ok then return "inventory-unavailable" end
        table.sort(names)
        if #names == 0 then return "no-text-globals" end
        return table.concat(names, ",")
    end

    -- Returns a verified string -> FText constructor, or nil.
    --
    -- UE4SS 3.0.1 in this game has no FText global at all (v0.11.1 shipped the check
    -- that proved it: textApi=false). UKismetTextLibrary's Conv_StringToText is the
    -- engine's own conversion and is reachable on the library's default object, so it
    -- is the second candidate. Neither is trusted on its say-so: a candidate has to
    -- round-trip a probe string back through ToString() before anything it produces
    -- is handed to SetText, because SetText faults natively on a wrong argument and
    -- no pcall will save us (ownership invariant 0b).
    local function resolve_text_ctor()
        local candidates = {}
        if type(FText) == "function" then
            candidates[#candidates + 1] = { name = "FText",
                make = function(value) return FText(value) end }
        end
        local library = find_object(KISMET_TEXT_PATH)
        if library ~= nil then
            candidates[#candidates + 1] = { name = "KismetTextLibrary.Conv_StringToText",
                make = function(value) return unwrap(library:Conv_StringToText(value)) end }
        end
        for _, candidate in ipairs(candidates) do
            local made = nil
            local built = pcall(function() made = candidate.make(PROBE_STRING) end)
            if built and made ~= nil then
                local round = nil
                pcall(function() round = made:ToString() end)
                if type(round) ~= "string" then
                    pcall(function() round = tostring(made:ToString()) end)
                end
                if round == PROBE_STRING then
                    log("Map labels text constructor=" .. candidate.name)
                    return candidate.make, candidate.name
                end
            end
        end
        log("Map labels unavailable: no verified text constructor; globals: "
            .. text_global_inventory())
        return nil, "none"
    end

    -- Reads an FSlateFontInfo into plain values and returns the table we can assign
    -- back as a whole struct. Never returns a table without a live FontObject: a font
    -- info with no object renders nothing at all.
    local function font_template(source_font, size)
        local template = nil
        pcall(function()
            local object = unwrap(source_font.FontObject)
            if not valid(object) then return end
            local typeface = "Default"
            local named = to_plain_string(source_font.TypefaceFontName)
            if named ~= nil then typeface = named end
            template = {
                FontObject = object,
                TypefaceFontName = FName(typeface),
                Size = size,
                LetterSpacing = math.floor(tonumber(source_font.LetterSpacing) or 0),
            }
        end)
        return template
    end

    -- Resolves the game's Trajan font asset once. Loading the package first is the
    -- same two-step the icon pools use for textures.
    -- Only a UFont (a composite) can dress a label; a UFontFace or anything else in
    -- the slot renders nothing at all, so it is refused here with a named reason.
    local function usable_font(object)
        if object == nil then return nil, "unavailable" end
        local class_name = type(Object.ClassShortName) == "function" and Object.ClassShortName(object) or nil
        if class_name ~= nil and class_name ~= "Font" then return nil, "not-a-font:" .. tostring(class_name) end
        return object, nil
    end

    local function resolve_choice(choice)
        if choice == nil then return nil, "unavailable" end
        local reason = "unavailable"
        for _, path in ipairs(choice.paths) do
            local found = find_object(path)
            if found ~= nil then
                local font, why = usable_font(found)
                if font ~= nil then return font end
                reason = why
            end
        end
        if choice.package ~= nil and type(LoadAsset) == "function" then
            local token = Perf.Begin()
            pcall(LoadAsset, choice.package)
            Perf.End("native.load", token)
            for _, path in ipairs(choice.paths) do
                local found = find_object(path)
                if found ~= nil then
                    local font, why = usable_font(found)
                    if font ~= nil then return font end
                    reason = why
                end
            end
        end
        return nil, reason
    end

    -- Resolves the chosen font asset once per choice. A choice that does not resolve
    -- (or "game" before an announcement has been seen) falls back to Trajan, and the
    -- summary names the fallback so a missing face is never a silent default.
    local function resolve_font_object()
        local choice = font_choice()
        if valid(labels.font_object) and labels.font_key == choice.key then return labels.font_object end
        labels.font_key = choice.key
        labels.font_fallback = nil
        local found = nil
        if choice.key == "game" then
            found = valid(labels.game_font) and labels.game_font or nil
            if found == nil then labels.font_fallback = "game:not-seen-yet" end
        else
            local why
            found, why = resolve_choice(choice)
            if found == nil then labels.font_fallback = choice.key .. ":" .. tostring(why or "unavailable") end
        end
        if found == nil and choice.key ~= FONT_FALLBACK.key then found = resolve_choice(FONT_FALLBACK) end
        labels.font_object = found
        labels.font_resolved = found ~= nil and (labels.font_fallback == nil and choice.key or FONT_FALLBACK.key) or "none"
        return found
    end

    -- source_font nil means "use the font asset we resolved ourselves", which is the
    -- path that actually sets the size. Reading the widget's own default font back is
    -- only a fallback, because on a fresh TextBlock it carries no usable FontObject.
    local function apply_font(entry, source_font)
        if entry == nil or not valid(entry.text) then return false end
        local size = entry.font_size or area_font_size()
        local template = nil
        if source_font ~= nil then
            template = font_template(source_font, size)
        else
            local own = resolve_font_object()
            if own ~= nil then
                template = { FontObject = own, TypefaceFontName = FName("Default"),
                    Size = size, LetterSpacing = 0 }
            else
                local ok, current = pcall(function() return entry.text.Font end)
                if ok and current ~= nil then template = font_template(current, size) end
            end
        end
        if template == nil then return false end
        template.OutlineSettings = { OutlineSize = outline_size(), OutlineColor = OUTLINE_BLACK,
            bSeparateFillAlpha = false, bApplyOutlineToDropShadows = false }
        -- v0.17.1: UTextBlock::SetFont pushes the struct into the Slate text block. A
        -- write to the Font property only lands in the UObject, and the STextBlock
        -- built at AddChildToCanvas time keeps drawing the UMG default (her
        -- 2026-09-14 Citadel screenshot: Roboto at 24 with fontApplies=7,
        -- fontFailures=0). The property write stays as the fallback.
        local ok = pcall(function() entry.text:SetFont(template) end)
        if ok then
            labels.metrics.font_setfont = labels.metrics.font_setfont + 1
        else
            ok = pcall(function() entry.text.Font = template end)
            if ok then labels.metrics.font_property = labels.metrics.font_property + 1 end
        end
        if ok then
            labels.metrics.font_applies = labels.metrics.font_applies + 1
            local read = nil
            pcall(function() read = tonumber(entry.text.Font.Size) end)
            labels.font_readback = read
            entry.font_readback = read
            entry.font_key = labels.font_key
        end
        return ok
    end

    -- Drop shadow through the two UTextBlock setters (FVector2D offset, FLinearColor).
    local function apply_shadow(entry)
        if entry == nil or not valid(entry.text) then return false end
        local offset = shadow_wanted() and { X = 1.0, Y = 1.0 } or { X = 0.0, Y = 0.0 }
        local color = shadow_wanted() and SHADOW_COLOR or { R = 0.0, G = 0.0, B = 0.0, A = 0.0 }
        local ok = pcall(function() entry.text:SetShadowOffset(offset) end)
        pcall(function() entry.text:SetShadowColorAndOpacity(color) end)
        return ok
    end

    local function read_ink_alpha(entry)
        local alpha = nil
        pcall(function() alpha = tonumber(entry.text.ColorAndOpacity.SpecifiedColor.A) end)
        if alpha == nil then
            pcall(function() alpha = tonumber(entry.text.ColorAndOpacity.A) end)
        end
        return alpha
    end

    -- Tries each shape on the probe and keeps the one whose alpha reads back.
    local function resolve_ink_shape(probe)
        if probe == nil or not valid(probe.text) then return nil end
        for index, candidate in ipairs(INK_CANDIDATES) do
            if pcall(probe.text.SetColorAndOpacity, probe.text, candidate.make(INK)) then
                local alpha = read_ink_alpha(probe)
                if alpha ~= nil and math.abs(alpha - INK.A) < 0.05 then
                    labels.ink_shape = index
                    labels.ink_source = candidate.name
                    log("Map labels ink shape=" .. candidate.name)
                    return index
                end
            end
        end
        labels.ink_source = "none-verified"
        log("Map labels ink unavailable: no color shape read back; labels stay white")
        return nil
    end

    -- Fog plate behind a label, on the same canvas, one z-order below the text.
    local function plate_texture()
        if labels.plate_texture ~= nil then return labels.plate_texture end
        local path = labels.plate_path
        if path == nil then return nil end
        local found = find_object(path)
        if found == nil then
            local token = Perf.Begin()
            pcall(LoadAsset, (string.gsub(path, "%.[^%.]+$", "")))
            Perf.End("native.load", token)
            found = find_object(path)
        end
        labels.plate_texture = found
        return found
    end

    local function ensure_plate(entry)
        if entry == nil then return nil end
        if entry.plate ~= nil then
            return valid(entry.plate.image) and entry.plate or nil
        end
        if Config.MapLabelPlate == false then return nil end
        local parent = label_parent()
        local texture = plate_texture()
        if not valid(parent) or not valid(labels.image_class) or texture == nil then
            labels.metrics.plate_failures = labels.metrics.plate_failures + 1
            return nil
        end
        local plate = { position_value = { X = -10000, Y = -10000 },
            size_value = { X = 1, Y = 1 }, visible = false }
        local ok = pcall(function()
            local image = unwrap(StaticConstructObject(labels.image_class, parent,
                make_name("LabelPlate")))
            assert(valid(image), "label plate construction failed")
            plate.image = image
            local slot = unwrap(parent:AddChildToCanvas(image))
            assert(valid(slot), "label plate slot failed")
            plate.slot = slot
            pcall(image.SetBrushFromTexture, image, texture, false)
            pcall(image.SetColorAndOpacity, image, PLATE_TINT)
            pcall(slot.SetZOrder, slot, labels.parent_kind == "root" and 59 or 5)
            image:SetVisibility(VIS_COLLAPSED)
        end)
        if not ok then
            labels.metrics.plate_failures = labels.metrics.plate_failures + 1
            return nil
        end
        entry.plate = plate
        labels.metrics.plates = labels.metrics.plates + 1
        return plate
    end

    -- v0.16.2: declared here, above its assignment. The forward declaration used to sit
    -- below this function, so the assignment created a global and the local that
    -- set_visible tests stayed nil for the life of the mod: the fog behind a hidden
    -- line was never hidden at all. Her "Sanguine Caverns" screenshot is that bug.
    local set_plate_hidden
    set_plate_hidden = function(entry)
        if entry == nil or entry.plate == nil then return end
        local plate = entry.plate
        if not valid(plate.image) or plate.visible == false then return end
        if pcall(plate.image.SetVisibility, plate.image, VIS_COLLAPSED) then
            plate.visible = false
        end
    end

    local function set_plate_visible(plate, visible)
        if plate == nil or not valid(plate.image) then return end
        visible = visible == true
        if plate.visible == visible then return end
        if pcall(plate.image.SetVisibility, plate.image,
            visible and VIS_HIT_TEST_INVISIBLE or VIS_COLLAPSED) then
            plate.visible = visible
        end
    end

    -- v0.12.1. The plate was sized from glyph count times font size, which is a guess
    -- about a proportional face at an unknown UI scale -- and her screenshots show it
    -- badly under-covering "Blackridge Cliffs". The widget knows its own size, so ask
    -- it. GetDesiredSize is a read on a widget we built, not a game object, and it
    -- returns zero until the first layout pass, so the estimate stays as the fallback
    -- and the measurement is re-taken until it is non-zero.
    local function measured(entry)
        if entry == nil then return nil, nil end
        if entry.measured_for == entry.value and entry.measured_w ~= nil then
            return entry.measured_w, entry.measured_h
        end
        entry.measure_tries = (entry.measure_tries or 0) + 1
        if not valid(entry.text) then return nil, nil end
        local got = nil
        pcall(function() got = entry.text:GetDesiredSize() end)
        if got == nil then return nil, nil end
        local w, h = nil, nil
        pcall(function() w, h = tonumber(got.X), tonumber(got.Y) end)
        if w == nil or h == nil or w <= 1 or h <= 1 then return nil, nil end
        entry.measure_tries = 0
        entry.measured_w, entry.measured_h, entry.measured_for = w, h, entry.value
        labels.metrics.measures = labels.metrics.measures + 1
        return w, h
    end

    -- Text height for line layout: measured when available, otherwise the point size.
    local function line_height(entry)
        local _, h = measured(entry)
        if h ~= nil then return h end
        return (entry ~= nil and entry.font_size or 9) * 1.35
    end

    local function place_plate(entry, x, y)
        local plate = ensure_plate(entry)
        if plate == nil or not valid(plate.slot) then return false end
        local size = entry.font_size or 9
        local glyphs = math.max(1, #tostring(entry.value or "N"))
        local width_scale = tonumber(entry.plate_width_scale) or 1.0
        local w = size * (PLATE_GLYPH_WIDTH * glyphs + PLATE_PAD) * width_scale
        local h = size * PLATE_HEIGHT_SCALE
        local mw, mh = measured(entry)
        if mw ~= nil then
            -- Cover the glyphs with a margin rather than approximate them.
            w = (mw + size * PLATE_PAD) * width_scale
            h = mh + size * (PLATE_HEIGHT_SCALE - 1.0)
        end
        if plate.last_w ~= w or plate.last_h ~= h then
            plate.size_value.X, plate.size_value.Y = w, h
            if pcall(plate.slot.SetSize, plate.slot, plate.size_value) then
                plate.last_w, plate.last_h = w, h
            end
        end
        plate.position_value.X, plate.position_value.Y = x - w / 2.0, y - h / 2.0
        local ok = pcall(plate.slot.SetPosition, plate.slot, plate.position_value)
        if ok then set_plate_visible(plate, true) end
        return ok
    end

    local function apply_ink(entry)
        if entry == nil or not valid(entry.text) then return false end
        if Config.MapLabelInk == false then return false end
        local index = labels.ink_shape
        if index == nil then return false end
        local candidate = INK_CANDIDATES[index]
        if candidate == nil then return false end
        if pcall(entry.text.SetColorAndOpacity, entry.text, candidate.make(ink_color())) then
            labels.metrics.ink_writes = labels.metrics.ink_writes + 1
            return true
        end
        return false
    end

    local function set_visible(entry, visible)
        if entry == nil then return end
        visible = visible == true
        -- v0.16.2: the plate is hidden BEFORE the early return. place_plate shows the
        -- plate whenever a line is positioned, so a line that was already hidden and
        -- got positioned again (her screenshot: the empty second line under "Sanguine
        -- Caverns") kept a fog with no text in it.
        if not visible and set_plate_hidden ~= nil then set_plate_hidden(entry) end
        if entry.visible == visible then return end
        if not valid(entry.text) then return end
        if pcall(entry.text.SetVisibility, entry.text,
            visible and VIS_HIT_TEST_INVISIBLE or VIS_COLLAPSED) then
            entry.visible = visible
            labels.metrics.visibility_writes = labels.metrics.visibility_writes + 1
        end
    end

    local function hide_all()
        set_visible(labels.area, false)
        if labels.sub ~= nil then set_visible(labels.sub, false) end
        for _, entry in pairs(labels.cardinals) do set_visible(entry, false) end
    end

    local function build_text(base, font_size)
        local frame, kind = label_parent()
        labels.parent_kind = kind
        if not valid(frame) or not valid(labels.text_class) then return nil end
        local entry = { visible = false, value = nil, last_x = nil, last_y = nil,
            position_value = { X = -10000, Y = -10000 }, size_value = { X = 200, Y = 24 },
            font_size = font_size }
        local ok, err = pcall(function()
            local text = unwrap(StaticConstructObject(labels.text_class, frame, make_name(base)))
            assert(valid(text), "text construction failed")
            entry.text = text
            local slot = unwrap(frame:AddChildToCanvas(text))
            assert(valid(slot), "text slot failed")
            entry.slot = slot
            pcall(slot.SetAutoSize, slot, true)
            pcall(slot.SetAlignment, slot, { X = 0.5, Y = 0.5 })
            slot:SetPosition({ X = -10000, Y = -10000 })
            -- Above the map on the outer canvas; above the icons inside the frame.
            pcall(slot.SetZOrder, slot, labels.parent_kind == "root" and 60 or 6)
            text:SetVisibility(VIS_COLLAPSED)
        end)
        if ok then
            -- Style it immediately from our own font asset: the label must be the
            -- right size before the game announces anything. The color comes after
            -- the probe has settled which shape the engine accepts.
            apply_font(entry, nil)
            apply_shadow(entry)
        end
        if not ok then
            if entry.text ~= nil and valid(entry.text) then
                pcall(entry.text.RemoveFromParent, entry.text)
            end
            labels.metrics.build_failures = labels.metrics.build_failures + 1
            log("Map label construction failed base=" .. tostring(base)
                .. " error=" .. tostring(err))
            return nil
        end
        labels.metrics.builds = labels.metrics.builds + 1
        return entry
    end

    -- value is always a plain Lua string by this point. The FText wrapper is not
    -- optional: SetText with a bare string faults inside UE4SS, and an access
    -- violation is not something pcall can catch. That was the v0.11.0 crash.
    local function set_text(entry, value)
        if entry == nil or type(value) ~= "string" or value == "" then return end
        if entry.value == value then return end
        if not valid(entry.text) or type(labels.make_text) ~= "function" then return end
        local wrapped = nil
        local made = pcall(function() wrapped = labels.make_text(value) end)
        if not made or wrapped == nil then
            labels.metrics.text_failures = labels.metrics.text_failures + 1
            return
        end
        if pcall(entry.text.SetText, entry.text, wrapped) then
            entry.value = value
            entry.measured_w, entry.measured_h, entry.measured_for = nil, nil, nil
            entry.measure_tries = 0
            labels.metrics.text_writes = labels.metrics.text_writes + 1
        else
            labels.metrics.text_failures = labels.metrics.text_failures + 1
        end
    end

    -- Copies the game's own font onto our labels. Called inside the live callback that
    -- gave us the widget: the font asset it names is an asset, not a level actor, and
    -- our own Font property is what keeps it alive afterwards.
    local function adopt_font(source_text)
        if source_text == nil or not valid(source_text) then return false end
        local source_font = nil
        pcall(function() source_font = source_text.Font end)
        if source_font == nil then
            labels.metrics.font_failures = labels.metrics.font_failures + 1
            return false
        end
        -- v0.17.1: the announcement's face is remembered as the "Game announcement"
        -- choice; it only dresses the labels when that choice is the user's.
        local object = nil
        pcall(function() object = unwrap(source_font.FontObject) end)
        if not valid(object) or usable_font(object) == nil then
            labels.metrics.font_failures = labels.metrics.font_failures + 1
            return false
        end
        labels.game_font = object
        labels.metrics.font_captures = labels.metrics.font_captures + 1
        labels.font_ready = true
        if font_choice().key ~= "game" then return true end
        labels.font_object = nil
        local adopted = false
        for _, entry in pairs({ labels.area, labels.sub, labels.cardinals.N, labels.cardinals.E,
            labels.cardinals.S, labels.cardinals.W }) do
            if entry ~= nil then
                adopted = apply_font(entry, nil) or adopted
            end
        end
        return adopted
    end

    -- Reads one string out of a notify widget and takes its font while we are in the
    -- callback that handed it to us. `field` is the text block to read; the widget's
    -- own text property is tried first when one is named.
    local function read_notify_text(widget, property, field)
        local value = nil
        if property ~= nil then
            pcall(function() value = to_plain_string(widget[property]) end)
        end
        local text_block = nil
        pcall(function() text_block = unwrap(widget[field]) end)
        if valid(text_block) then
            if value == nil then
                pcall(function() value = to_plain_string(text_block:GetText()) end)
            end
            if not labels.font_ready then adopt_font(text_block) end
        end
        text_block = nil
        return value
    end

    -- v0.12.0. Local/AreaName.lua owns the model now: named box volumes the game
    -- itself uses, which cannot carry "Gloom Retrieved" because nothing but the volume
    -- writes them. The notify hooks below stay armed as a fallback for an area with no
    -- volume and as evidence, but they never override a volume-sourced name.
    local function pull_names()
        local model = ctx.AreaName
        if type(model) ~= "table" or type(model.Names) ~= "function" then return end
        local ok, outer, sub, source = pcall(model.Names)
        if not ok then return end
        if outer ~= nil then
            if labels.area_name ~= outer then
                labels.area_name = outer
                labels.name_source = "volume"
                labels.area_dirty = true
                labels.metrics.names_captured = labels.metrics.names_captured + 1
            end
        elseif labels.name_source == "volume" then
            -- The model has no name for where we are now. v0.12.0 kept the last one,
            -- so a fast travel to the hub left "Blackridge Cliffs" under the map.
            -- An empty line one is honest; a wrong one is not.
            if labels.area_name ~= nil then
                labels.area_name = nil
                labels.name_source = "none"
                labels.area_dirty = false
                labels.metrics.names_cleared = labels.metrics.names_cleared + 1
            end
        end
        if labels.sub_name ~= sub then
            labels.sub_name = sub
            labels.sub_source = tostring(source or "none")
            labels.sub_dirty = true
        end
    end

    local function on_landing_notify(context)
        labels.metrics.hook_events = labels.metrics.hook_events + 1
        local widget = unwrap(context)
        if not valid(widget) then return end
        local value = read_notify_text(widget, nil, "Text_Name")
        if type(value) ~= "string" then return end
        -- v0.12.3: evidence only, never displayed. v0.12.0 kept the announcement as a
        -- fallback for when the model had no name, and her 15:32 run showed exactly
        -- what that fallback does: line one read "Flooded Village" from the dungeon
        -- announcement while line two read "The Flooded Village" from the volume. The
        -- model now seeds line one from the nearest region instead, so the only thing
        -- this channel can add is a wrong answer. Recorded for the summary.
        labels.notify_name = value
        labels.notify_source = "landing-notify"
        labels.metrics.names_observed = labels.metrics.names_observed + 1
    end

    -- Evidence only. This widget carries whatever the game last shouted at you
    -- ("Gloom Retrieved"), so its string is recorded and never displayed.
    local function on_generic_notify(context)
        labels.metrics.hook_events = labels.metrics.hook_events + 1
        labels.metrics.generic_events = labels.metrics.generic_events + 1
        local widget = unwrap(context)
        if not valid(widget) then return end
        local value = read_notify_text(widget, "AreaName", "Text_Area_Name")
        if type(value) ~= "string" then return end
        labels.generic_name = value
        -- v0.12.3: evidence only, never displayed. v0.12.0 kept the announcement as a
        -- fallback for when the model had no name, and her 15:32 run showed exactly
        -- what that fallback does: line one read "Flooded Village" from the dungeon
        -- announcement while line two read "The Flooded Village" from the volume. The
        -- model now seeds line one from the nearest region instead, so the only thing
        -- this channel can add is a wrong answer. Recorded for the summary.
        labels.notify_name = value
        labels.notify_source = "area-notify"
        labels.metrics.names_observed = labels.metrics.names_observed + 1
    end

    function labels.Arm()
        if type(RegisterHook) ~= "function" then return 0, 0 end
        local specs = {
            { path = LANDING_NOTIFY .. ":Notify_Start", on = on_landing_notify, label = "labels.landingNotify" },
            { path = LANDING_NOTIFY .. ":BuildName", on = on_landing_notify, label = "labels.landingBuildName" },
            { path = AREA_NOTIFY .. ":Notify_Start", on = on_generic_notify, label = "labels.areaNotify" },
        }
        local armed = 0
        for _, spec in ipairs(specs) do
            local path, handler = spec.path, spec.on
            if labels.hooks[path] == nil then
                local section = "hook." .. spec.label
                local ok, pre_id, post_id = pcall(RegisterHook, path, function(context)
                    local token = Perf.Begin()
                    pcall(handler, context)
                    Perf.End(section, token)
                end)
                if ok and (pre_id ~= nil or post_id ~= nil) then
                    labels.hooks[path] = { pre = pre_id, post = post_id }
                else
                    labels.metrics.hook_failures = labels.metrics.hook_failures + 1
                end
            end
            if labels.hooks[path] ~= nil then armed = armed + 1 end
        end
        return armed, #specs
    end

    function labels.OnRendererReady()
        if labels.ready then return true end
        local frame = state.retained and state.retained.frame or nil
        if not state.built or not valid(frame) then return false end
        -- No FText constructor, no text layer. Writing text without one is the
        -- v0.11.0 crash, and it is not a failure pcall can absorb, so the check
        -- happens once here and set_text refuses to run without it.
        local ctor, ctor_name = resolve_text_ctor()
        labels.make_text, labels.text_source = ctor, ctor_name
        labels.text_api = type(ctor) == "function"
        if not labels.text_api then return false end
        labels.image_class = find_object(IMAGE_CLASS_PATH)
        labels.text_class = find_object(TEXT_CLASS_PATH)
        if not valid(labels.text_class) then
            log("Map labels unavailable: UMG TextBlock class not resident")
            return false
        end
        resolve_font_object()
        -- Settle the color shape on a widget nobody will ever see.
        if labels.ink_shape == nil and Config.MapLabelInk ~= false then
            local probe = build_text("InkProbe", cardinal_font_size())
            if probe ~= nil then
                resolve_ink_shape(probe)
                if probe.text ~= nil and valid(probe.text) then
                    pcall(probe.text.RemoveFromParent, probe.text)
                end
            end
        end
        labels.area = build_text("AreaLabel", area_font_size())
        labels.sub = build_text("SubAreaLabel", sub_font_size())
        -- The wide fog is for the two name lines; a compass letter keeps a small one.
        if labels.area ~= nil then labels.area.plate_width_scale = PLATE_WIDTH_SCALE end
        if labels.sub ~= nil then labels.sub.plate_width_scale = PLATE_WIDTH_SCALE end
        labels.cardinals = {}
        for _, cardinal in ipairs(CARDINALS) do
            labels.cardinals[cardinal.key] = build_text("Cardinal" .. cardinal.key,
                cardinal_font_size())
        end
        labels.ready = labels.area ~= nil
        if labels.ready then
            apply_ink(labels.area)
            if labels.sub ~= nil then apply_ink(labels.sub) end
            for _, entry in pairs(labels.cardinals) do apply_ink(entry) end
        end
        if labels.ready then
            if labels.area_name ~= nil then labels.area_dirty = true end
            if labels.sub_name ~= nil then labels.sub_dirty = true end
            labels.last_angle = nil
        end
        return labels.ready
    end

    local function place(entry, x, y)
        if entry == nil or not valid(entry.slot) then return false end
        -- v0.12.1: a pending measurement also counts as work to do. UMG returns a
        -- zero desired size until the first layout pass, so the plate behind a
        -- freshly written line is sized from the estimate; without this the position
        -- never changes again and the plate keeps the wrong size forever.
        -- Bounded: an engine that never gives a desired size must not make this write a
        -- position every tick forever. MEASURE_MAX_TRIES attempts, then the estimate
        -- stands and the label goes quiet again.
        local pending_measure = entry.value ~= nil and entry.measured_for ~= entry.value
            and (entry.measure_tries or 0) < MEASURE_MAX_TRIES
        if not pending_measure and entry.last_x ~= nil and math.abs(entry.last_x - x) < 0.5
            and math.abs(entry.last_y - y) < 0.5
            and entry.plate_value == entry.value then return true end
        entry.position_value.X, entry.position_value.Y = x, y
        if pcall(entry.slot.SetPosition, entry.slot, entry.position_value) then
            entry.last_x, entry.last_y = x, y
            labels.metrics.position_writes = labels.metrics.position_writes + 1
            -- The fog follows the letter, and is resized when the text changes.
            place_plate(entry, x, y)
            entry.plate_value = entry.value
            return true
        end
        return false
    end

    -- Called at pan cadence. Nothing is written unless the map turned, the region
    -- changed, or the setting changed.
    local function trace(phase, extra)
        if Config.LocalDiscoveryTrace == false then return end
        log("Map labels trace phase=" .. tostring(phase)
            .. (extra ~= nil and (" " .. tostring(extra)) or ""))
    end

    function labels.Update()
        if not labels.ready then return false end
        local current = mode()
        if current == 0 then
            if labels.last_mode ~= 0 then hide_all() end
            labels.last_mode = 0
            return true
        end
        labels.metrics.updates = labels.metrics.updates + 1
        if labels.metrics.updates <= 3 then trace("update", "mode=" .. tostring(current)) end
        -- Frame-local coordinates. Map/NativeWidget.lua already positions the frame at
        -- (OffsetX, OffsetY) on the screen canvas, so adding the offset again -- which
        -- v0.11.2 did -- pushed the compass off-centre by exactly that much and threw
        -- two of the four letters outside the frame, where they were clipped. The
        -- 2026-09-12 screenshots are that bug: two letters visible, one sliced by the
        -- right edge, one gone.
        local size = map_size()
        local origin_x, origin_y = parent_origin()
        local center_x = origin_x + size / 2.0
        local center_y = origin_y + size / 2.0

        if area_enabled() then
            pull_names()
            if labels.area_dirty and labels.area_name ~= nil then
                set_text(labels.area, labels.area_name)
                labels.area_dirty = false
            end
            -- The model's name decides, not the widget's last text: set_text refuses
            -- an empty string, so a stale widget value would keep a dead line visible.
            local has_name = labels.area_name ~= nil
                and labels.area ~= nil and labels.area.value ~= nil
            local area_size = (labels.area ~= nil and labels.area.font_size)
                or area_font_size()
            -- On the outer canvas the label can sit just below the map; parented to
            -- the frame it has to stay inside the clip.
            -- v0.17.1: on the outer canvas the line clears the map frame (whatever
            -- style is drawn outside the edge) and the cardinal letter that may be
            -- straddling the bottom edge, so neither sits on the name.
            local clearance = 0.0
            if labels.parent_kind == "root" then
                local frame = ctx.Frame
                if type(frame) == "table" and type(frame.OuterExtent) == "function" then
                    local ok, extent = pcall(frame.OuterExtent)
                    if ok then clearance = math.max(clearance, tonumber(extent) or 0.0) end
                end
                if cardinals_enabled() then
                    clearance = math.max(clearance, cardinal_font_size() * 0.6 - ring_inset())
                end
            end
            local area_y = labels.parent_kind == "root"
                and (origin_y + size + clearance + area_size * 0.9)
                or (size - (area_size + EDGE_PADDING))
            -- v0.16.2: a line with no text is not positioned, so its fog is never
            -- shown for it (user: no smoke until there is text for it).
            if has_name then place(labels.area, center_x, area_y) end
            set_visible(labels.area, has_name)

            -- Second line, directly under the first. When there is no area name yet the
            -- sub-area takes the top slot rather than floating under a gap.
            if sub_enabled() and labels.sub ~= nil then
                if labels.sub_dirty and labels.sub_name ~= nil then
                    set_text(labels.sub, labels.sub_name)
                    labels.sub_dirty = false
                end
                -- v0.17.1: a sub-area that is the area itself (her Citadel of Penance
                -- screenshot: the beacon carries the region's own name) is one line.
                local same_name = labels.sub_name ~= nil and labels.area_name ~= nil
                    and tostring(labels.sub_name):lower() == tostring(labels.area_name):lower()
                local has_sub = labels.sub.value ~= nil and labels.sub_name ~= nil and not same_name
                -- v0.12.1: full line boxes, not half the point size. The old spacing
                -- overlapped the two lines in her screenshots because a rendered glyph
                -- box is taller than its point size and the UI scale is not 1.
                local sub_y = has_name
                    and (area_y + (line_height(labels.area) + line_height(labels.sub)) * 0.5
                        + LINE_GAP)
                    or area_y
                if has_sub then place(labels.sub, center_x, sub_y) end
                set_visible(labels.sub, has_sub)
            elseif labels.sub ~= nil then
                set_visible(labels.sub, false)
            end
        else
            set_visible(labels.area, false)
            if labels.sub ~= nil then set_visible(labels.sub, false) end
        end

        if cardinals_enabled() then
            local map_angle = tonumber(state.map_rotation_angle) or 0.0
            -- Centre-anchored on the map edge, so the letter straddles it half in
            -- and half out. Parented to the frame instead, the ring has to pull in
            -- by a glyph or the letter is clipped.
            local glyph = (labels.cardinals.N ~= nil and labels.cardinals.N.font_size)
                or cardinal_font_size()
            local edge = labels.parent_kind == "root"
                and (size / 2.0 - ring_inset())
                or (size / 2.0 - (glyph + EDGE_PADDING))
            local radius = math.max(8.0, edge)
            -- v0.18.44 (her 04:30 video): this cache used to key on the ROTATION ANGLE
            -- alone, so anything else the ring's geometry depends on could change and the
            -- letters would sit where they were. v0.18.43's live resize is how that finally
            -- showed: "the direction labels aren't following along like the area labels
            -- are". The area line follows because it is placed on every update; the compass
            -- did not because her map was not turning, so the angle never moved.
            --
            -- The letters' positions depend on the ring centre and radius and nothing else,
            -- and those two absorb every input -- map size, the inset row, the glyph size,
            -- and the parent origin. So the cache keys on what the geometry actually is
            -- rather than on a list of things that might have changed it, and a new input
            -- cannot be forgotten here again.
            local changed = labels.last_angle == nil
                or math.abs(labels.last_angle - map_angle) > 0.75
                or labels.last_mode ~= current
                or labels.last_ring_radius ~= radius
                or labels.last_ring_x ~= center_x
                or labels.last_ring_y ~= center_y
            if changed then
                for _, cardinal in ipairs(CARDINALS) do
                    local entry = labels.cardinals[cardinal.key]
                    if entry ~= nil and cardinal_wanted(cardinal.key) then
                        -- Screen north is up; the map's rotation turns the compass.
                        local theta = math.rad(cardinal.angle + map_angle)
                        local x = center_x + radius * math.sin(theta)
                        local y = center_y - radius * math.cos(theta)
                        set_text(entry, cardinal.key)
                        place(entry, x, y)
                        set_visible(entry, true)
                    else
                        set_visible(entry, false)
                    end
                end
                labels.last_angle = map_angle
                labels.last_ring_radius = radius
                labels.last_ring_x = center_x
                labels.last_ring_y = center_y
            end
        else
            for _, entry in pairs(labels.cardinals) do set_visible(entry, false) end
        end
        labels.last_mode = current
        return true
    end

    -- v0.17.1: size / font / color / outline / shadow rows re-dress the live labels
    -- in place; nothing is rebuilt.
    local function restyle()
        labels.font_object = nil
        if labels.area ~= nil then labels.area.font_size = area_font_size() end
        if labels.sub ~= nil then labels.sub.font_size = sub_font_size() end
        for _, entry in pairs(labels.cardinals) do entry.font_size = cardinal_font_size() end
        for _, entry in pairs({ labels.area, labels.sub, labels.cardinals.N, labels.cardinals.E,
            labels.cardinals.S, labels.cardinals.W }) do
            if entry ~= nil then
                apply_font(entry, nil)
                apply_ink(entry)
                apply_shadow(entry)
                entry.measured_w, entry.measured_h, entry.measured_for = nil, nil, nil
                entry.last_x, entry.last_y = nil, nil
            end
        end
    end

    function labels.ApplyLiveSetting(setting)
        if type(setting) ~= "table" then return end
        if setting.apply == "labels" or setting.apply == "geometry"
            or setting.apply == "orientation" or setting.apply == "map-frame" then
            if setting.apply == "labels" then restyle() end
            labels.last_angle, labels.last_mode = nil, nil
            labels.area_dirty = labels.area_name ~= nil
            labels.sub_dirty = labels.sub_name ~= nil
            labels.Update()
        end
    end

    function labels.DropWorldReferencesUnread()
        labels.area = nil
        labels.sub = nil
        labels.cardinals = {}
        labels.text_class = nil
        -- The constructor closure holds the text library's default object. It is a
        -- CDO rather than a level actor, but rule 0 says drop it unread anyway and
        -- resolve it again when the next renderer comes up.
        labels.make_text = nil
        labels.text_api = false
        labels.text_source = "none"
        labels.font_object = nil
        labels.font_key = nil
        labels.game_font = nil
        labels.image_class = nil
        labels.plate_texture = nil
        labels.ink_shape = nil
        labels.ink_source = "none"
        labels.ready = false
        labels.font_ready = false
        labels.last_angle, labels.last_mode = nil, nil
        -- The captured region name is a plain string: it survives the world change,
        -- and the next announcement replaces it.
        labels.area_dirty = labels.area_name ~= nil
        labels.sub_dirty = labels.sub_name ~= nil
    end

    function labels.EmitSummary(reason)
        local m = labels.metrics
        local cardinal_count = 0
        for _ in pairs(labels.cardinals) do cardinal_count = cardinal_count + 1 end
        log(string.format(
            "Map labels summary reason=%s mode=%d ready=%s textApi=%s textSource=%s fontAsset=%s fontChoice=%s fontResolved=%s fontFallback=%s fontReadback=%s fontSetFont=%d fontProperty=%d color=%s outline=%d shadow=%s inkShape=%s inkWrites=%d plates=%d plateFailures=%d parent=%s ringInset=%.1f cardinalMode=%d fontAdopted=%s cardinalSize=%d areaSize=%d areaName=%s nameSource=%s subName=%s subSource=%s subEnabled=%s notifyObserved=%s notifySource=%s genericNotify=%s cardinals=%d builds=%d buildFailures=%d hookEvents=%d genericEvents=%d namesCaptured=%d fontApplies=%d fontCaptures=%d fontFailures=%d hookFailures=%d textWrites=%d textFailures=%d positionWrites=%d visibilityWrites=%d updates=%d retainedGameWidgets=0 retainedGameText=0",
            tostring(reason or "manual"), mode(), tostring(labels.ready),
            tostring(labels.text_api), tostring(labels.text_source or "none"),
            tostring(valid(labels.font_object)), tostring(font_choice().key),
            tostring(labels.font_resolved or "none"), tostring(labels.font_fallback or "none"),
            tostring(labels.font_readback or "none"), m.font_setfont, m.font_property,
            tostring(Config.MapLabelColor or "white"), outline_size(), tostring(shadow_wanted()),
            tostring(labels.ink_source or "none"),
            labels.metrics.ink_writes, labels.metrics.plates, labels.metrics.plate_failures,
            tostring(labels.parent_kind or "none"),
            ring_inset(), math.floor(tonumber(Config.MapLabelCardinals) or 1),
            tostring(labels.font_ready),
            cardinal_font_size(), area_font_size(),
            tostring(labels.area_name or "none"),
            tostring(labels.name_source or "none"),
            tostring(labels.sub_name or "none"),
            tostring(labels.sub_source or "none"),
            tostring(sub_enabled()),
            tostring(labels.notify_name or "none"),
            tostring(labels.notify_source or "none"),
            tostring(labels.generic_name or "none"),
            cardinal_count, m.builds, m.build_failures, m.hook_events, m.generic_events,
            m.names_captured,
            m.font_applies, m.font_captures, m.font_failures, m.hook_failures,
            m.text_writes, m.text_failures,
            m.position_writes, m.visibility_writes, m.updates))
    end

    function labels.FontChoices()
        local out = {}
        for i, choice in ipairs(FONT_CHOICES) do out[i] = { key = choice.key, label = choice.label } end
        return out
    end

    function labels.ColorChoices()
        local out = {}
        for i, key in ipairs(LABEL_COLOR_ORDER) do
            out[i] = { key = key, label = key:sub(1, 1):upper() .. key:sub(2) }
        end
        return out
    end

    return labels
end

-- Module-level copies for the schema, which is built before any renderer exists.
Factory.FontChoices = {
    { key = "trajan", label = "Trajan" }, { key = "trajanbold", label = "Trajan SemiBold" },
    { key = "trajansub", label = "Trajan Subtitles" }, { key = "crimson", label = "Crimson Text" },
    { key = "crimsonsemi", label = "Crimson SemiBold" }, { key = "crimsonbold", label = "Crimson Bold" },
    { key = "crimsonitalic", label = "Crimson Italic" }, { key = "game", label = "Game announcement" },
}
Factory.ColorChoices = { "white", "gold", "bronze", "red", "blue", "green", "grey", "black" }

return Factory
