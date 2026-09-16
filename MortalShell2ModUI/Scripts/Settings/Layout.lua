-- MortalShell2ModUI Settings.Layout
-- Shared settings/browser geometry and deterministic adaptive main-rail sizing.
-- This module remains pure Lua: no Unreal calls, hooks, timers, input ownership, or
-- runtime state live here. Runtime hosts consume the same resolved geometry so native
-- rail placement and TTS pointer hit-testing cannot drift apart.

local Layout = {
    assets = {
        settings = "/Game/Sparta/UI/Menu/Misc/WBP_ConfirmationPrompt_ReadText",
        settingsClass = "/Game/Sparta/UI/Menu/Misc/WBP_ConfirmationPrompt_ReadText.WBP_ConfirmationPrompt_ReadText_C",
        inputListener = "/Game/Sparta/UI/Core/Navigation/WBP_InputListener",
        inputListenerClass = "/Game/Sparta/UI/Core/Navigation/WBP_InputListener.WBP_InputListener_C",
        bpflUi = "/Game/Sparta/UI/Core/BPFL_UI",
        bpflUiCdo = "/Game/Sparta/UI/Core/BPFL_UI.Default__BPFL_UI_C",
        settingInfoPanel = "/Game/Sparta/UI/Settings/WBP_Setting_InfoPanel",
        settingInfoPanelClass = "/Game/Sparta/UI/Settings/WBP_Setting_InfoPanel.WBP_Setting_InfoPanel_C",
        plainText = "/Game/Sparta/UI/Common/WBP_Text",
        plainTextClass = "/Game/Sparta/UI/Common/WBP_Text.WBP_Text_C",
        option = "/Game/Sparta/UI/Menu/WBP_NB_Option",
        optionClass = "/Game/Sparta/UI/Menu/WBP_NB_Option.WBP_NB_Option_C",
        optionSlider = "/Game/Sparta/UI/Menu/WBP_NB_Option_Slider",
        optionSliderClass = "/Game/Sparta/UI/Menu/WBP_NB_Option_Slider.WBP_NB_Option_Slider_C",
        tabButton = "/Game/Sparta/UI/Settings/W_SpartaTabButton",
        tabButtonClass = "/Game/Sparta/UI/Settings/W_SpartaTabButton.W_SpartaTabButton_C",
    },

    widths = {
        prompt = 2000.0,
        list = 340.0,
        value = 380.0,
        fallbackList = 920.0,
        info = 580.0,
        infoText = 550.0,
    },

    settings = {
        PROMPT_HEIGHT = 650.0,
        INFO_TEXT_SCALE = 0.59,
        INFO_RENDER_SCALE = 0.70,
        INFO_WRAP_COLUMNS = 38,
        INFO_VISIBLE_LINES = 18,
        -- Pass 43 realigned the main-row pointer map with the rendered rails.
        -- Pass 45 keeps the measured standardized `<` band but makes its right edge
        -- the exact start of Next/increase. There is intentionally no center/no-op
        -- gap because the rendered `>` position moves with value-text width.
        -- Keep all values in normalized 1920x1080 reference space so the existing
        -- pointer transform continues to scale across DPI.
        MAIN_ROW_HIT_LEFT = 670.0,
        MAIN_ROW_HIT_TOP = 294.0,
        ROW_HIT_STEP = 40.5,
        MAIN_ROW_HIT_RIGHT = 1115.0,
        MAIN_VALUE_HIT_LEFT = 895.0,
        MAIN_VALUE_HIT_RIGHT = 1115.0,
        MAIN_VALUE_PREVIOUS_RIGHT = 960.0,
        MAIN_VALUE_NEXT_LEFT = 960.0,
        DETAILS_HIT_LEFT = 1170.0,
        DETAILS_HIT_RIGHT = 1460.0,
        DETAILS_HIT_TOP = 255.0,
        DETAILS_HIT_BOTTOM = 790.0,
        -- Pass 42 runtime-calibrated main-tab map. These reference-space bounds
        -- align the three equal tab slots with the currently centered MOD/SPEECH/ENGINE
        -- glyphs at 1920x1080 and scale through the existing reference-pointer transform.
        TAB_HIT_LEFT = 730.0,
        TAB_HIT_RIGHT = 1100.0,
        TAB_HIT_TOP = 238.0,
        TAB_HIT_BOTTOM = 284.0,
        SAFE_LEFT = 460.0,
        SAFE_RIGHT = 80.0,
        TAB_TOP = -40.0,
        ROWS_TOP = 82.0,
        VALUE_LEFT = 900.0,
        INFO_LEFT = 1420.0,
        INFO_RIGHT = 0.0,
        INFO_TOP = 82.0,
        INFO_CONTENT_OFFSET_Y = 22.0,
        BACKGROUND_TRANSLATE_X = 120.0,
        BACKGROUND_PIVOT_X = 0.00,
        BACKGROUND_PIVOT_Y = 1.00,
        BACKGROUND_SCALE_X = 1.14,
        BACKGROUND_SCALE_Y = 1.10,
        -- v0.70.1: the smoke backdrop (ARB_Background inside the prompt's SizeBox_3,
        -- 1920 units, centred in the prompt) does not follow the prompt width, so a
        -- widened prompt drew its text past the smoke on both sides (her 10:51
        -- screenshot, CAPTURE tab, prompt 2554). The backdrop is scaled from a model
        -- of what the tuned 2000-unit constants above actually show at 4K: the smoke
        -- image fades over BACKGROUND_FADE of its width at each edge, the visible dark
        -- starts BACKGROUND_VISIBLE_LEFT units into the prompt and ends
        -- BACKGROUND_VISIBLE_RIGHT_MARGIN past it. At 2000 the model gives back
        -- 1.14 / 120 exactly; a wider prompt gets a wider smoke, same look.
        BACKGROUND_NATURAL_WIDTH = 1920.0,
        BACKGROUND_FADE = 0.141,
        BACKGROUND_VISIBLE_LEFT = 469.0,
        BACKGROUND_VISIBLE_RIGHT_MARGIN = 40.0,

        BROWSER_PROMPT_WIDTH = 2600.0,
        BROWSER_PROMPT_HEIGHT = 880.0,
        BROWSER_TAB_WIDTH = 1520.0,
        BROWSER_LIST_WIDTH = 540.0,
        BROWSER_VALUE_WIDTH = 390.0,
        BROWSER_INFO_WIDTH = 680.0,
        BROWSER_INFO_TEXT_WIDTH = 640.0,
        BROWSER_INFO_WRAP_COLUMNS = 42,
        BROWSER_SAFE_LEFT = 680.0,
        BROWSER_TAB_TOP = 40.0,
        BROWSER_ROWS_TOP = 160.0,
        BROWSER_VALUE_LEFT = 1340.0,
        BROWSER_INFO_LEFT = 1820.0,
        BROWSER_INFO_RIGHT = 100.0,
        BROWSER_INFO_TOP = 160.0,
        BROWSER_ROW_HIT_LEFT = 565.0,
        BROWSER_ROW_HIT_RIGHT = 1125.0,
        BROWSER_VALUE_HIT_LEFT = 810.0,
        -- Pass 60 corrects a previously untested Browser mouse-row Y origin.
        -- Runtime clicks at 3840x2160 / viewport scale 2.0 proved the pointer is
        -- already normalized correctly, but the old 270 reference origin mapped
        -- clicks about two rows below the visible row. Browser row padding is 78
        -- design units below the main row padding; at the proven outer 0.50 scale
        -- that is +39 logical pixels: 294 + 39 = 333. Keep the proven 40.5 pitch.
        BROWSER_ROW_HIT_TOP = 333.0,
        BROWSER_DETAILS_HIT_LEFT = 1030.0,
        BROWSER_DETAILS_HIT_RIGHT = 1435.0,
        BROWSER_DETAILS_HIT_TOP = 230.0,
        BROWSER_DETAILS_HIT_BOTTOM = 900.0,
        BROWSER_BACKGROUND_TRANSLATE_X = 120.0,
        BROWSER_BACKGROUND_TRANSLATE_Y = 20.0,
        BROWSER_BACKGROUND_SCALE_X = 1.18,
        BROWSER_BACKGROUND_SCALE_Y = 1.10,
    },

    -- Pass 173 adaptive main-profile geometry. The browser keeps its separately proven
    -- wide layout and mouse calibration; ordinary Settings expands only when rendered
    -- label/value text actually needs more room. Values are design-space units before
    -- the outer 0.50 ScaleBox transform.
    -- v0.70.0: the glyph model is only the first guess. The host measures the rendered
    -- rails (GetDesiredSize on its own text blocks) and passes the measured widths back
    -- in as `calibration`; the caps grew so a long value ("Ctrl + T + T + S [2 conflicts]")
    -- gets its room instead of running into the details panel. Her 2026-09-14 screenshots
    -- put the real glyph near 44 units, three and a half times the old 13.
    adaptive = {
        main = {
            labelMin = 340.0, labelMax = 1000.0, labelPadding = 40.0,
            valueMin = 380.0, valueMax = 1300.0, valuePadding = 50.0,
            glyphWidth = 13.0,
            labelValueGap = 100.0, valueInfoGap = 140.0,
            promptMin = 2000.0, promptMax = 3580.0,
            pointerScale = 0.50,
            -- The tab strip: "<  " / "  >" scroll marks and the gap between labels.
            tabGap = "    ", tabPrev = "<  ", tabNext = "  >",
        },
        -- v0.70.3 (user: "can the controller settings window also adopt that as well?
        -- as well as the voice browser?"): the browser profile -- the shared Controller
        -- Settings screen and TTS's voice browser -- sizes its columns from the text
        -- the same way. Its tuned 2600-unit layout is the floor; the gaps are what
        -- the tuned constants imply (1340 - 680 - 540, 1820 - 1340 - 390).
        browser = {
            labelMin = 540.0, labelMax = 1200.0, labelPadding = 40.0,
            valueMin = 390.0, valueMax = 1300.0, valuePadding = 50.0,
            glyphWidth = 13.0,
            labelValueGap = 120.0, valueInfoGap = 90.0,
            promptMin = 2600.0, promptMax = 3800.0,
            pointerScale = 0.50,
        },
    },

    -- Generic shared-shell presentation safety. These are defensive hard bounds,
    -- not TTS-specific formatting rules: a consumer may publish shorter polished
    -- text, but it cannot push unbounded strings into neighboring native rails.
    presentation = {
        main = {
            header = 72, page = 16, tabs = 96, labelLine = 42, valueLine = 44,
            bodyLine = 120, detailTitle = 64, detailLine = 104, detailLines = 24,
        },
        browser = {
            header = 88, page = 16, tabs = 120, labelLine = 64, valueLine = 48,
            bodyLine = 150, detailTitle = 72, detailLine = 120, detailLines = 30,
        },
    },

    enums = {
        SCALEBOX_STRETCH_USER_SPECIFIED = 7,
        WIDGET_CLIP_INHERIT = 0,
        WIDGET_CLIP_TO_BOUNDS = 1,
        HALIGN_FILL = 0,
        HALIGN_LEFT = 1,
        HALIGN_CENTER = 2,
        HALIGN_RIGHT = 3,
        VALIGN_TOP = 1,
        VALIGN_CENTER = 2,
    },
}

local function clamp(value, low, high)
    value = tonumber(value) or low
    if value < low then return low end
    if value > high then return high end
    return value
end

local function glyph_units(codepoint)
    codepoint = tonumber(codepoint) or 32
    if codepoint == 32 then return 0.55 end
    if codepoint == 73 or codepoint == 105 or codepoint == 108 or codepoint == 33
        or codepoint == 39 or codepoint == 44 or codepoint == 46 or codepoint == 58
        or codepoint == 59 or codepoint == 124 then return 0.55 end
    if codepoint == 87 or codepoint == 77 or codepoint == 109 or codepoint == 119
        or codepoint == 64 or codepoint == 35 or codepoint == 37 or codepoint == 38 then return 1.35 end
    if codepoint < 128 then return 1.0 end
    return 1.20
end

local function line_units(line, max_chars)
    line = tostring(line or "")
    max_chars = math.max(0, math.floor(tonumber(max_chars) or 0))
    local total = 0.0
    if utf8 ~= nil and type(utf8.codes) == "function" then
        local count = 0
        local ok = pcall(function()
            for _, codepoint in utf8.codes(line) do
                count = count + 1
                if max_chars > 0 and count > max_chars then break end
                total = total + glyph_units(codepoint)
            end
        end)
        if ok then return total end
    end
    if max_chars > 0 then return math.min(#line, max_chars) end
    return #line
end

local function max_line_units(value, max_chars)
    value = tostring(value or "")
    local maximum = 0.0
    local saw = false
    for line in (value .. "\n"):gmatch("(.-)\n") do
        saw = true
        maximum = math.max(maximum, line_units(line, max_chars))
    end
    return saw and maximum or 0.0
end

function Layout.LineUnits(line) return line_units(line, 0) end
function Layout.MaxLineUnits(value, max_chars) return max_line_units(value, max_chars) end

-- v0.70.1: the smoke backdrop's render transform for a prompt of the given width
-- (design units). Pivot X = 0 (left edge). See BACKGROUND_NATURAL_WIDTH above.
--   visible left  = natural_left + tx + fade * natural * sx
--   visible right = natural_left + tx + (1 - fade) * natural * sx
-- with natural_left = (prompt_width - natural) / 2 (SizeBox_3 is centred in the prompt).
-- v0.70.3: per profile. The visible left edge and the right margin are read off the
-- profile's tuned constants (its prompt width, scale and translation), so at that width
-- the tuned look is returned exactly and a wider prompt keeps the same margins.
local function background_profile(profile)
    local S = Layout.settings
    if tostring(profile or "main") == "browser" then
        return S.BROWSER_PROMPT_WIDTH, S.BROWSER_BACKGROUND_SCALE_X, S.BROWSER_BACKGROUND_TRANSLATE_X
    end
    return Layout.widths.prompt, S.BACKGROUND_SCALE_X, S.BACKGROUND_TRANSLATE_X
end

function Layout.BackgroundTransform(prompt_width, profile)
    local S = Layout.settings
    local natural = S.BACKGROUND_NATURAL_WIDTH
    local fade = S.BACKGROUND_FADE
    local tuned_width, tuned_scale, tuned_translate = background_profile(profile)
    prompt_width = tonumber(prompt_width) or tuned_width
    local tuned_left = (tuned_width - natural) * 0.5 + tuned_translate
    local visible_left = tuned_left + fade * natural * tuned_scale
    local right_margin = tuned_left + (1.0 - fade) * natural * tuned_scale - tuned_width
    local visible_right = prompt_width + right_margin
    local sx = (visible_right - visible_left) / (natural * (1.0 - 2.0 * fade))
    local natural_left = (prompt_width - natural) * 0.5
    local tx = visible_left - natural_left - fade * natural * sx
    return {
        scaleX = math.floor(sx * 1000 + 0.5) / 1000,
        translateX = math.floor(tx * 10 + 0.5) / 10,
        visibleLeft = visible_left, visibleRight = visible_right,
    }
end

function Layout.ResolveAdaptive(profile, labels, values, calibration)
    profile = tostring(profile or "main") == "browser" and "browser" or "main"
    local S = Layout.settings
    calibration = type(calibration) == "table" and calibration or {}
    if profile == "browser" then
        -- v0.70.3: the browser profile grows like main. Its tuned 2600-unit layout is the
        -- floor (a snapshot that fits it resolves to exactly the old constants); longer
        -- labels or values widen their rail, the details panel and the prompt move right
        -- by the same amount, the pointer map shifts with them, and the smoke follows.
        local A = Layout.adaptive.browser
        local P = Layout.presentation.browser
        local glyph = tonumber(calibration.glyphWidth) or A.glyphWidth
        if glyph <= 0 then glyph = A.glyphWidth end
        local label_natural = math.max(max_line_units(labels, P.labelLine) * glyph, tonumber(calibration.labelWidth) or 0)
        local value_natural = math.max(max_line_units(values, P.valueLine) * glyph, tonumber(calibration.valueWidth) or 0)
        local label_width = math.floor(clamp(A.labelPadding + label_natural, A.labelMin, A.labelMax) + 0.5)
        local value_width = math.floor(clamp(A.valuePadding + value_natural, A.valueMin, A.valueMax) + 0.5)
        local label_delta = label_width - S.BROWSER_LIST_WIDTH
        local value_delta = value_width - S.BROWSER_VALUE_WIDTH
        local value_left = S.BROWSER_SAFE_LEFT + label_width + A.labelValueGap
        local info_left = value_left + value_width + A.valueInfoGap
        local prompt_width = clamp(info_left + S.BROWSER_INFO_WIDTH + S.BROWSER_INFO_RIGHT, A.promptMin, A.promptMax)
        local px_label = label_delta * A.pointerScale
        local px_total = (label_delta + value_delta) * A.pointerScale
        local prompt_shift = (prompt_width - S.BROWSER_PROMPT_WIDTH) * A.pointerScale * 0.5
        local tab_width = math.max(S.BROWSER_TAB_WIDTH, prompt_width - S.BROWSER_SAFE_LEFT - S.SAFE_RIGHT)
        local background = Layout.BackgroundTransform(prompt_width, "browser")
        return {
            profile = "browser",
            signature = string.format("browser:%d:%d:%d", label_width, value_width, prompt_width),
            promptWidth = prompt_width, promptHeight = S.BROWSER_PROMPT_HEIGHT,
            tabWidth = tab_width, labelWidth = label_width, valueWidth = value_width,
            labelNatural = label_natural, valueNatural = value_natural,
            glyphWidth = glyph,
            infoWidth = S.BROWSER_INFO_WIDTH,
            infoTextWidth = S.BROWSER_INFO_TEXT_WIDTH, safeLeft = S.BROWSER_SAFE_LEFT,
            tabTop = S.BROWSER_TAB_TOP, rowsTop = S.BROWSER_ROWS_TOP,
            valueLeft = value_left, infoLeft = info_left,
            infoRight = S.BROWSER_INFO_RIGHT, infoTop = S.BROWSER_INFO_TOP,
            backgroundTranslateX = background.translateX,
            backgroundTranslateY = S.BROWSER_BACKGROUND_TRANSLATE_Y,
            backgroundScaleX = background.scaleX, backgroundScaleY = S.BROWSER_BACKGROUND_SCALE_Y,
            pointer = {
                rowLeft = S.BROWSER_ROW_HIT_LEFT - prompt_shift, rowRight = S.BROWSER_ROW_HIT_RIGHT + px_total - prompt_shift,
                valueLeft = S.BROWSER_VALUE_HIT_LEFT + px_label - prompt_shift,
                valueRight = S.BROWSER_ROW_HIT_RIGHT + px_total - prompt_shift,
                detailsLeft = S.BROWSER_DETAILS_HIT_LEFT + px_total - prompt_shift,
                detailsRight = S.BROWSER_DETAILS_HIT_RIGHT + px_total - prompt_shift,
                detailsTop = S.BROWSER_DETAILS_HIT_TOP, detailsBottom = S.BROWSER_DETAILS_HIT_BOTTOM,
            },
        }
    end

    local A = Layout.adaptive.main
    local P = Layout.presentation.main
    -- Measured glyph width wins over the model; measured rail widths win over both.
    local glyph = tonumber(calibration.glyphWidth) or A.glyphWidth
    if glyph <= 0 then glyph = A.glyphWidth end
    local label_natural = math.max(max_line_units(labels, P.labelLine) * glyph, tonumber(calibration.labelWidth) or 0)
    local value_natural = math.max(max_line_units(values, P.valueLine) * glyph, tonumber(calibration.valueWidth) or 0)
    local label_width = clamp(A.labelPadding + label_natural, A.labelMin, A.labelMax)
    local value_width = clamp(A.valuePadding + value_natural, A.valueMin, A.valueMax)
    label_width = math.floor(label_width + 0.5)
    value_width = math.floor(value_width + 0.5)

    local label_delta = label_width - Layout.widths.list
    local value_delta = value_width - Layout.widths.value
    local value_left = S.SAFE_LEFT + label_width + A.labelValueGap
    local info_left = value_left + value_width + A.valueInfoGap
    local prompt_width = clamp(info_left + Layout.widths.info, A.promptMin, A.promptMax)
    local actual_extra = prompt_width - Layout.widths.prompt
    if actual_extra < (label_delta + value_delta) then
        -- The current caps should keep this branch dormant, but if future constants change,
        -- give the value rail the remaining room rather than allowing prompt overflow.
        local allowed_value_delta = math.max(0.0, actual_extra - label_delta)
        value_width = Layout.widths.value + allowed_value_delta
        value_left = S.SAFE_LEFT + label_width + A.labelValueGap
        info_left = value_left + value_width + A.valueInfoGap
        value_delta = value_width - Layout.widths.value
    end

    local px_label = label_delta * A.pointerScale
    local px_total = (label_delta + value_delta) * A.pointerScale
    -- The prompt is centered. Expanding its authored width moves every left-anchored
    -- child left by half the added width after the outer 0.50 scale.
    local prompt_shift = (prompt_width - Layout.widths.prompt) * A.pointerScale * 0.5
    -- v0.70.0: the strip owns the whole inner width of the prompt (it scrolls when the
    -- labels do not fit), so its rail is never narrower than the row rails together.
    local tab_width = math.max(Layout.widths.fallbackList, prompt_width - S.SAFE_LEFT - S.SAFE_RIGHT)
    local background = Layout.BackgroundTransform(prompt_width, "main")
    return {
        profile = "main",
        signature = string.format("main:%d:%d:%d", label_width, value_width, prompt_width),
        promptWidth = prompt_width, promptHeight = S.PROMPT_HEIGHT,
        tabWidth = tab_width, labelWidth = label_width, valueWidth = value_width,
        labelNatural = label_natural, valueNatural = value_natural,
        glyphWidth = glyph,
        infoWidth = Layout.widths.info, infoTextWidth = Layout.widths.infoText,
        safeLeft = S.SAFE_LEFT, tabTop = S.TAB_TOP, rowsTop = S.ROWS_TOP,
        valueLeft = value_left, infoLeft = info_left, infoRight = S.INFO_RIGHT, infoTop = S.INFO_TOP,
        backgroundTranslateX = background.translateX, backgroundTranslateY = 0.0,
        backgroundScaleX = background.scaleX, backgroundScaleY = S.BACKGROUND_SCALE_Y,
        pointer = {
            rowLeft = S.MAIN_ROW_HIT_LEFT - prompt_shift, rowRight = S.MAIN_ROW_HIT_RIGHT + px_total - prompt_shift,
            valueLeft = S.MAIN_VALUE_HIT_LEFT + px_label - prompt_shift,
            valueRight = S.MAIN_VALUE_HIT_RIGHT + px_total - prompt_shift,
            previousRight = S.MAIN_VALUE_PREVIOUS_RIGHT + px_label - prompt_shift,
            detailsLeft = S.DETAILS_HIT_LEFT + px_total - prompt_shift, detailsRight = S.DETAILS_HIT_RIGHT + px_total - prompt_shift,
            detailsTop = S.DETAILS_HIT_TOP, detailsBottom = S.DETAILS_HIT_BOTTOM,
        },
    }
end

-- v0.70.0: the tab strip is laid out by the host from measured glyph widths, left to
-- right inside the prompt, and scrolls when the labels do not fit: a window of whole
-- labels around the selected one, with "<" / ">" marks for the tabs off either end.
-- Her 2026-09-14 screenshot had seven Minimap tabs spilling off the screen edge from a
-- centred single string; v0.69.1's equal-cell model never matched a proportional font.
-- TabWindow is pure: the same call lays out the drawn strip and the pointer regions.
--
--   labels            the tab labels, in order
--   selected          1-based selected tab
--   available_units   the strip's width in design units
--   glyph_width       design units per glyph unit (measured by the host when it can)
--   previous_first    the window's first tab last time, so scrolling is sticky
function Layout.TabWindow(labels, selected, available_units, glyph_width, previous_first)
    labels = type(labels) == "table" and labels or {}
    local count = #labels
    local A = Layout.adaptive.main
    glyph_width = tonumber(glyph_width) or A.glyphWidth
    if glyph_width <= 0 then glyph_width = A.glyphWidth end
    available_units = tonumber(available_units) or Layout.widths.fallbackList
    selected = math.max(1, math.min(math.max(count, 1), math.floor(tonumber(selected) or 1)))
    local function units(text) return line_units(text, 0) * glyph_width end
    local function shown(index)
        return index == selected and ("[ " .. tostring(labels[index]) .. " ]") or tostring(labels[index])
    end
    local gap_units, prev_units, next_units = units(A.tabGap), units(A.tabPrev), units(A.tabNext)
    local widths = {}
    for index = 1, count do widths[index] = units(shown(index)) end

    -- The window: start from the remembered first tab, keep the selected tab inside it,
    -- and take whole labels while they fit (with room for the scroll marks they imply).
    local function fits(first)
        local total = first > 1 and prev_units or 0
        local last = first - 1
        for index = first, count do
            local extra = widths[index] + (index > first and gap_units or 0)
            local mark = index < count and next_units or 0
            if total + extra + mark > available_units and index > first then break end
            total = total + extra
            last = index
        end
        return last, total
    end
    local first = math.max(1, math.min(count, math.floor(tonumber(previous_first) or 1)))
    if selected < first then first = selected end
    local last, total = fits(first)
    while last < selected and first < selected do
        first = first + 1
        last, total = fits(first)
    end
    if count == 0 then first, last, total = 1, 0, 0 end
    -- Pull the window back left when it ends at the last tab and there is room.
    while first > 1 do
        local candidate_last = fits(first - 1)
        if candidate_last < count or candidate_last < selected then break end
        first = first - 1
        last, total = fits(first)
    end

    local has_prev, has_next = first > 1, last < count
    local parts, regions, cursor = {}, {}, 0.0
    local prev_region, next_region = nil, nil
    if has_prev then
        parts[#parts + 1] = A.tabPrev
        prev_region = { left = cursor, right = cursor + prev_units }
        cursor = cursor + prev_units
    end
    for index = first, last do
        if index > first then
            parts[#parts + 1] = A.tabGap
            cursor = cursor + gap_units
        end
        parts[#parts + 1] = shown(index)
        regions[#regions + 1] = { index = index, left = cursor, right = cursor + widths[index] }
        cursor = cursor + widths[index]
    end
    if has_next then
        parts[#parts + 1] = A.tabNext
        next_region = { left = cursor, right = cursor + next_units }
        cursor = cursor + next_units
    end
    -- Gaps belong to the label on their left, so a click between two labels lands on one.
    for i = 1, #regions - 1 do regions[i].right = regions[i + 1].left end
    if has_next and #regions > 0 then regions[#regions].right = next_region.left end
    return {
        text = table.concat(parts), first = first, last = last, count = count,
        hasPrev = has_prev, hasNext = has_next, totalUnits = cursor,
        regions = regions, prevRegion = prev_region, nextRegion = next_region,
        glyphWidth = glyph_width, availableUnits = available_units,
    }
end

-- The strip's pointer regions in reference space (1920x1080), from the same window the
-- host drew. `window` comes from Layout.TabWindow; without one this falls back to a
-- window laid out here with the model glyph (the consumer-side fallback for an old host).
function Layout.ResolveTabHitRegions(labels, selected_index, resolved, window)
    labels = type(labels) == "table" and labels or {}
    selected_index = math.max(1, math.floor(tonumber(selected_index) or 1))
    local S, A = Layout.settings, Layout.adaptive.main
    resolved = type(resolved) == "table" and resolved or Layout.ResolveAdaptive("main", "", "")
    local prompt_width = tonumber(resolved.promptWidth) or Layout.widths.prompt
    local prompt_left = 960.0 - prompt_width * A.pointerScale * 0.5
    local left = prompt_left + (tonumber(resolved.safeLeft) or S.SAFE_LEFT) * A.pointerScale
    if type(window) ~= "table" then
        window = Layout.TabWindow(labels, selected_index, resolved.tabWidth, resolved.glyphWidth, 1)
    end
    local scale = A.pointerScale
    local regions = {}
    for _, region in ipairs(window.regions or {}) do
        regions[#regions + 1] = { index = region.index, left = left + region.left * scale, right = left + region.right * scale }
    end
    local function mark(region)
        if region == nil then return nil end
        return { left = left + region.left * scale, right = left + region.right * scale }
    end
    return {
        left = left, right = left + (tonumber(window.totalUnits) or 0) * scale,
        top = S.TAB_HIT_TOP, bottom = S.TAB_HIT_BOTTOM,
        regions = regions, prevRegion = mark(window.prevRegion), nextRegion = mark(window.nextRegion),
        first = window.first, last = window.last,
    }
end

-- Kept for callers of the v0.69.1 rule (the shell's rail width); the strip itself is
-- windowed now and never wider than the rail.
Layout.MIN_TAB_CELL_DIVISOR = 6.0
function Layout.TabStrip(tab_width, count)
    tab_width = tonumber(tab_width) or Layout.widths.fallbackList
    count = math.max(1, math.floor(tonumber(count) or 1))
    return { cell = tab_width / count, width = tab_width }
end

return Layout
