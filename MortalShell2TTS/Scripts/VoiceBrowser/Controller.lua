-- MortalShell2TTS VoiceBrowser.Controller
-- Browser interaction/state orchestration: favorites, filtering, selection,
-- preview, paging and bounded hold-repeat. Catalog loading, synthesis/helper
-- lifecycle, native Settings shell ownership and input-hook registration stay
-- consumer-owned/injected.

local Controller = {}

local SEARCH_KEYS = {
    "A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z",
    "Zero", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine",
    "SpaceBar", "BackSpace", "Delete",
}

local DIGIT_TEXT = {
    Zero = "0", One = "1", Two = "2", Three = "3", Four = "4",
    Five = "5", Six = "6", Seven = "7", Eight = "8", Nine = "9",
}

function Controller.New(options)
    options = type(options) == "table" and options or {}
    local config = options.config
    local ui = options.ui
    local state = options.state
    local catalog = options.catalog
    local repeat_api = options.repeat_api
    local refresh_voices = options.refresh_voices
    local active_voice_value = options.active_voice_value
    local current_voice_label = options.current_voice_label
    local save_config = options.save_config
    local trim = options.trim
    local log = options.log or function() end
    local diag = options.diag or function() end
    local capture_voice_profile = options.capture_voice_profile
    local apply_voice_profile = options.apply_voice_profile
    local current_voice_pitch_supported = options.current_voice_pitch_supported
    local normalized_voice_style = options.normalized_voice_style
    local voice_profile = options.voice_profile
    local default_voice_profile = options.default_voice_profile
    local sanitize_voice_profile = options.sanitize_voice_profile
    local tts_command = options.tts_command
    local redraw = options.redraw or function() end
    local apply_window_profile = options.apply_window_profile or function() end
    local reset_open_sequences = options.reset_open_sequences or function() end
    local unwrap = options.unwrap
    local valid = options.valid
    local input_key_down = options.input_key_down
    local input_analog_value = options.input_analog_value
    local finite_number = options.finite_number

    if type(config) ~= "table" then return nil, "config missing" end
    if type(ui) ~= "table" then return nil, "ui missing" end
    if type(state) ~= "table" then return nil, "state missing" end
    if type(catalog) ~= "table" or type(catalog.Rebuild) ~= "function" or type(catalog.Rows) ~= "function" then return nil, "catalog missing" end
    if type(repeat_api) ~= "table" or type(repeat_api.AdvanceHeld) ~= "function" then return nil, "repeat api missing" end
    if type(refresh_voices) ~= "function" then return nil, "refresh_voices missing" end
    if type(active_voice_value) ~= "function" then return nil, "active_voice_value missing" end
    if type(current_voice_label) ~= "function" then return nil, "current_voice_label missing" end
    if type(save_config) ~= "function" then return nil, "save_config missing" end
    if type(trim) ~= "function" then return nil, "trim missing" end
    if type(capture_voice_profile) ~= "function" then return nil, "capture_voice_profile missing" end
    if type(apply_voice_profile) ~= "function" then return nil, "apply_voice_profile missing" end
    if type(current_voice_pitch_supported) ~= "function" then return nil, "pitch capability missing" end
    if type(normalized_voice_style) ~= "function" then return nil, "style capability missing" end
    if type(voice_profile) ~= "function" then return nil, "voice_profile missing" end
    if type(default_voice_profile) ~= "function" then return nil, "default_voice_profile missing" end
    if type(sanitize_voice_profile) ~= "function" then return nil, "sanitize_voice_profile missing" end
    if type(tts_command) ~= "function" then return nil, "tts_command missing" end
    if type(unwrap) ~= "function" then return nil, "unwrap missing" end
    if type(valid) ~= "function" then return nil, "valid missing" end
    if type(input_key_down) ~= "function" then return nil, "input_key_down missing" end
    if type(input_analog_value) ~= "function" then return nil, "input_analog_value missing" end
    if type(finite_number) ~= "function" then return nil, "finite_number missing" end

    local self = {}

    local function active()
        return state.active == true
    end

    local function favorite_field()
        return config.engine == "azure" and "favorite_azure_voices" or "favorite_windows_voices"
    end

    local function favorite_set()
        local out = {}
        local raw = tostring(config[favorite_field()] or "")
        for token in raw:gmatch("[^|]+") do
            token = trim(token)
            if token ~= "" then out[token:lower()] = token end
        end
        return out
    end

    local function rebuild(preserve_value)
        refresh_voices()
        local filtered, offset, selected = catalog.Rebuild(
            ui.voices,
            state,
            favorite_set(),
            preserve_value,
            ui.selected
        )
        state.filtered = filtered
        state.offset = offset
        ui.selected = selected
    end

    local function rows()
        return catalog.Rows(state.filtered, state.offset, state.page_size)
    end

    local function current_voice()
        if not active() then return nil end
        local current_rows = rows()
        local row = current_rows[ui.selected]
        return row ~= nil and row.voice or nil
    end

    function self.Active() return active() end
    function self.FavoriteField() return favorite_field() end
    function self.FavoriteSet() return favorite_set() end
    function self.IsFavorite(value) return favorite_set()[tostring(value or ""):lower()] ~= nil end

    function self.ToggleFavoriteValue(value)
        value = tostring(value or "")
        if value == "" or value == "default" then return false end
        local set = favorite_set()
        local key = value:lower()
        if set[key] ~= nil then set[key] = nil else set[key] = value end
        local values = {}
        for _, original in pairs(set) do values[#values + 1] = original end
        table.sort(values, function(a, b) return tostring(a):lower() < tostring(b):lower() end)
        config[favorite_field()] = table.concat(values, "|")
        save_config()
        log("voice favorite " .. (set[key] ~= nil and "added: " or "removed: ") .. value)
        return set[key] ~= nil
    end

    function self.Rebuild(preserve_value) return rebuild(preserve_value) end
    function self.Rows() return rows() end
    function self.CurrentVoice() return current_voice() end

    function self.Open()
        refresh_voices(true)
        state.active = true
        state.query = ""
        state.gender = "All"
        state.original = tostring(active_voice_value())
        state.chosen = state.original
        state.offset = 1
        state.previous_search_down = {}
        state.nav_hold_ticks = { up = 0, down = 0 }
        state.square_down = false
        state.right_page_hold_direction = 0
        state.right_page_hold_ticks = 0
        state.right_page_neutral_seen = true
        state.right_page_springback_logged = false
        state.page_hold_ticks = { up = 0, down = 0 }
        state.home_down = false
        state.end_down = false
        reset_open_sequences()
        rebuild(state.chosen)
        apply_window_profile("browser")
        ui.status = "Voice browser opened. Type to search."
        diag("voice.browser", { action = "open", engine = config.engine, voices = #state.filtered, selected = state.chosen })
        redraw()
    end

    function self.Commit(source)
        if not active() then return false end
        local changed = state.chosen ~= "" and tostring(state.chosen):lower() ~= tostring(state.original):lower()
        if not changed then return false end

        capture_voice_profile(config.engine, state.original)
        if config.engine == "azure" then config.azure_voice = state.chosen else config.voice = state.chosen end
        apply_voice_profile(config.engine, state.chosen)
        capture_voice_profile(config.engine, state.chosen)
        diag("voice.browser", {
            action = "commit",
            engine = config.engine,
            source = tostring(source or "browser-close"),
            selected = tostring(state.chosen),
            pitchSupported = current_voice_pitch_supported(state.chosen),
            rate = config.rate,
            volume = config.volume,
            pitch = config.pitch,
            effectiveStyle = normalized_voice_style(state.chosen),
            storedStyle = tostring(config.voice_style),
        })
        return true
    end

    function self.Close(reason)
        if not active() then return false end
        local changed = self.Commit("browser-close")
        state.active = false
        state.previous_search_down = {}
        state.nav_hold_ticks = { up = 0, down = 0 }
        state.square_down = false
        state.right_page_hold_direction = 0
        state.right_page_hold_ticks = 0
        state.right_page_neutral_seen = true
        state.right_page_springback_logged = false
        state.page_hold_ticks = { up = 0, down = 0 }
        state.home_down = false
        state.end_down = false
        apply_window_profile("main")
        ui.selected = 1
        ui.selected_by_tab[ui.tab] = 1
        if changed then
            save_config()
            ui.status = "Voice selected: " .. current_voice_label()
            log("voice browser committed voice=" .. tostring(active_voice_value()))
        else
            ui.status = "Voice browser closed."
        end
        diag("voice.browser", { action = "close", reason = tostring(reason or "back"), changed = changed, selected = tostring(active_voice_value()) })
        redraw()
        return true
    end

    function self.CycleGender(delta)
        state.gender = catalog.CycleGender(state.genders, state.gender, delta)
        state.offset = 1
        ui.selected = 1
        rebuild("")
        ui.status = "Gender filter: " .. state.gender
        diag("voice.browser.input", {
            action = "gender",
            direction = delta < 0 and "previous" or "next",
            gender = state.gender,
            results = #state.filtered,
        })
        redraw()
    end

    function self.AppendSearch(text, input_kind, shifted)
        if not active() then return end
        text = tostring(text or "")
        state.query = catalog.EditQuery(state.query, text)
        state.offset = 1
        ui.selected = 1
        rebuild("")
        ui.status = state.query == "" and "Search cleared." or ("Search: " .. state.query)
        diag("voice.browser.input", {
            action = "search",
            kind = tostring(input_kind or "text"),
            shifted = shifted == true,
            queryLength = #state.query,
            results = #state.filtered,
        })
        redraw()
    end

    function self.ToggleFavorite()
        local voice = current_voice()
        if voice == nil then return end
        local added = self.ToggleFavoriteValue(voice.value)
        local keep = voice.value
        rebuild(keep)
        ui.status = (added and "Favorited: " or "Removed favorite: ") .. tostring(voice.label or voice.value)
        diag("voice.browser.input", { action = "favorite", favorite = added == true, results = #state.filtered })
        redraw()
    end

    function self.Activate()
        local voice = current_voice()
        if voice == nil then return end
        if tostring(state.chosen):lower() ~= tostring(voice.value):lower() then
            state.chosen = voice.value
            ui.status = "Selected " .. tostring(voice.label or voice.value) .. ". Confirm again to preview."
            diag("voice.browser.input", { action = "select", engine = config.engine, absolute = state.offset + ui.selected - 1 })
            redraw()
            return
        end
        local profile = voice_profile(config.engine, voice.value, false) or default_voice_profile()
        profile = sanitize_voice_profile(profile)
        local preview_payload = table.concat({
            tostring(voice.value),
            tostring(profile.rate),
            tostring(profile.volume),
            tostring(profile.pitch),
            tostring(profile.style),
            "Mortal Shell Two text to speech preview. The darkness remembers every name.",
        }, "\n")
        if tts_command("TEST_VOICE", preview_payload) then
            ui.status = "Previewing " .. tostring(voice.label or voice.value) .. "."
            diag("voice.browser", { action = "preview", voice = voice.value, engine = config.engine, rate = profile.rate, volume = profile.volume, pitch = profile.pitch, style = profile.style })
            redraw()
        end
    end

    function self.Move(delta)
        if #state.filtered == 0 then return end
        local absolute = state.offset + ui.selected - 1 + delta
        if absolute < 1 then absolute = #state.filtered end
        if absolute > #state.filtered then absolute = 1 end
        local page = math.max(1, state.page_size)
        state.offset = math.floor((absolute - 1) / page) * page + 1
        ui.selected = absolute - state.offset + 1
        ui.status = ""
        redraw()
    end

    function self.Page(delta)
        if not active() or #state.filtered == 0 then return end
        self.Move((delta < 0 and -1 or 1) * math.max(1, state.page_size))
    end

    function self.Jump(which)
        if not active() or #state.filtered == 0 then return false end
        local total = #state.filtered
        local absolute = tostring(which or "start") == "end" and total or 1
        local page = math.max(1, tonumber(state.page_size) or 10)
        state.offset = math.floor((absolute - 1) / page) * page + 1
        ui.selected = absolute - state.offset + 1
        ui.status = ""
        redraw()
        diag("voice.browser", { action = "jump", target = which, absolute = absolute, offset = state.offset, selected = ui.selected })
        return true
    end

    function self.PageModifierDown(controller)
        controller = unwrap(controller)
        if not valid(controller) then return false end
        return select(1, input_key_down(controller, "LeftControl")) == true
            or select(1, input_key_down(controller, "RightControl")) == true
            or select(1, input_key_down(controller, "LeftShift")) == true
            or select(1, input_key_down(controller, "RightShift")) == true
    end

    function self.Wheel(delta, source)
        if not active() then return false end
        local direction = tonumber(delta) ~= nil and (tonumber(delta) < 0 and -1 or 1) or 0
        if direction == 0 then return false end
        local page_modifier = self.PageModifierDown(ui.controller)
        if page_modifier then self.Page(direction) else self.Move(direction) end
        diag("input.mouse.wheel", {
            direction = direction < 0 and "up" or "down",
            mode = page_modifier and "page" or "row",
            rows = page_modifier and math.max(1, state.page_size) or 1,
            source = tostring(source or "native"),
        })
        return true
    end

    function self.UpdatePoll(controller)
        if not active() then return end
        local shift_down = select(1, input_key_down(controller, "LeftShift")) == true
            or select(1, input_key_down(controller, "RightShift")) == true

        for _, key_name in ipairs(SEARCH_KEYS) do
            local down = select(1, input_key_down(controller, key_name)) == true
            local before = state.previous_search_down[key_name] == true
            if down and not before then
                if key_name == "BackSpace" then
                    self.AppendSearch("<BACKSPACE>", "backspace", false)
                elseif key_name == "Delete" then
                    self.AppendSearch("<CLEAR>", "clear", false)
                elseif key_name == "SpaceBar" then
                    self.AppendSearch(" ", "space", false)
                elseif DIGIT_TEXT[key_name] ~= nil then
                    self.AppendSearch(DIGIT_TEXT[key_name], "digit", false)
                elseif #key_name == 1 then
                    self.AppendSearch(shift_down and key_name:upper() or key_name:lower(), "letter", shift_down)
                end
            end
            state.previous_search_down[key_name] = down
        end

        local keyboard_up = select(1, input_key_down(controller, "Up")) == true
        local keyboard_down = select(1, input_key_down(controller, "Down")) == true
        local dpad_up = select(1, input_key_down(controller, "Gamepad_DPad_Up")) == true
        local dpad_down = select(1, input_key_down(controller, "Gamepad_DPad_Down")) == true
        local stick_key_up = select(1, input_key_down(controller, "Gamepad_LeftStick_Up")) == true
        local stick_key_down = select(1, input_key_down(controller, "Gamepad_LeftStick_Down")) == true
        local analog_up, analog_down = false, false
        local left_y, left_y_source = input_analog_value(controller, "Gamepad_LeftY")
        if finite_number(left_y) then
            analog_up = left_y >= 0.65
            analog_down = left_y <= -0.65
        end
        local up_down = keyboard_up or dpad_up or stick_key_up or analog_up
        local down_down = keyboard_down or dpad_down or stick_key_down or analog_down

        for name, held in pairs({ up = up_down and not down_down, down = down_down and not up_down }) do
            local ticks, should_repeat = repeat_api.AdvanceHeld(state.nav_hold_ticks[name], held, 8, 2)
            if should_repeat then
                self.Move(name == "up" and -1 or 1)
                local source_flags = {}
                if (name == "up" and keyboard_up) or (name == "down" and keyboard_down) then source_flags[#source_flags + 1] = "keyboard" end
                if (name == "up" and dpad_up) or (name == "down" and dpad_down) then source_flags[#source_flags + 1] = "dpad" end
                if (name == "up" and stick_key_up) or (name == "down" and stick_key_down) then source_flags[#source_flags + 1] = "left-stick-key" end
                if (name == "up" and analog_up) or (name == "down" and analog_down) then
                    source_flags[#source_flags + 1] = "left-stick-analog:" .. tostring(left_y_source or "unknown")
                end
                diag("voice.browser", { action = "hold-repeat", direction = name, ticks = ticks, sources = table.concat(source_flags, ",") })
            end
            state.nav_hold_ticks[name] = ticks
        end

        local page_up_down = select(1, input_key_down(controller, "PageUp")) == true
        local page_down_down = select(1, input_key_down(controller, "PageDown")) == true
        for name, held in pairs({ up = page_up_down and not page_down_down, down = page_down_down and not page_up_down }) do
            local ticks, should_repeat = repeat_api.AdvanceHeld(state.page_hold_ticks[name], held, 8, 3)
            if should_repeat then
                self.Page(name == "up" and -1 or 1)
                diag("voice.browser", { action = "page-hold-repeat", source = "keyboard", direction = name, ticks = ticks })
            end
            state.page_hold_ticks[name] = ticks
        end

        local home = select(1, input_key_down(controller, "Home")) == true
        local finish = select(1, input_key_down(controller, "End")) == true
        if home and not state.home_down then self.Jump("start") end
        if finish and not state.end_down then self.Jump("end") end
        state.home_down = home
        state.end_down = finish

        local square = select(1, input_key_down(controller, "Gamepad_FaceButton_Left")) == true
        if square and not state.square_down then self.ToggleFavorite() end
        state.square_down = square
    end

    return self, nil
end

return Controller
