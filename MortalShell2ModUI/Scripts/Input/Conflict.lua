-- MortalShell2ModUI pure binding-conflict data helpers.
-- This module intentionally owns NO Unreal access, file IO, registry queries,
-- recorder state, input polling, or consumer-specific conflict scanning.

local Conflict = {}

local function trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$")
end

local key_fields = {
    Zero = "ZERO", One = "ONE", Two = "TWO", Three = "THREE", Four = "FOUR",
    Five = "FIVE", Six = "SIX", Seven = "SEVEN", Eight = "EIGHT", Nine = "NINE",
    SpaceBar = "SPACE", Tab = "TAB", Enter = "RETURN", BackSpace = "BACKSPACE",
    Insert = "INS", Delete = "DEL", Home = "HOME", End = "END", PageUp = "PAGE_UP", PageDown = "PAGE_DOWN",
    Up = "UP_ARROW", Down = "DOWN_ARROW", Left = "LEFT_ARROW", Right = "RIGHT_ARROW",
    CapsLock = "CAPS_LOCK", NumLock = "NUM_LOCK", ScrollLock = "SCROLL_LOCK",
    Semicolon = "OEM_ONE", Equals = "OEM_PLUS", Comma = "OEM_COMMA", Hyphen = "OEM_MINUS",
    Period = "OEM_PERIOD", Slash = "OEM_TWO", Tilde = "OEM_THREE", LeftBracket = "OEM_FOUR",
    Backslash = "OEM_FIVE", RightBracket = "OEM_SIX", Apostrophe = "OEM_SEVEN",
    NumPadZero = "NUM_ZERO", NumPadOne = "NUM_ONE", NumPadTwo = "NUM_TWO", NumPadThree = "NUM_THREE",
    NumPadFour = "NUM_FOUR", NumPadFive = "NUM_FIVE", NumPadSix = "NUM_SIX", NumPadSeven = "NUM_SEVEN",
    NumPadEight = "NUM_EIGHT", NumPadNine = "NUM_NINE", Decimal = "DECIMAL", Divide = "DIVIDE",
    Multiply = "MULTIPLY", Subtract = "SUBTRACT", Add = "ADD",
}

function Conflict.Add(result, source, detail, category, registry_fingerprint)
    if type(result) ~= "table" then return false end
    result.items = result.items or {}
    result.seen = result.seen or {}
    local source_text = trim(source)
    local detail_text = trim(detail)
    local dedupe = tostring(category or "conflict") .. "|" .. source_text .. "|" .. detail_text
    if result.seen[dedupe] then return false end
    result.seen[dedupe] = true
    result.items[#result.items + 1] = {
        source = source_text ~= "" and source_text or "Unknown",
        detail = detail_text ~= "" and detail_text or "Input is already in use.",
        category = tostring(category or "conflict"),
        registry_fingerprint = registry_fingerprint,
    }
    if registry_fingerprint ~= nil then
        result.registry_explained = result.registry_explained or {}
        result.registry_explained[tostring(registry_fingerprint)] = true
    end
    return true
end

function Conflict.KeyFieldForToken(token)
    token = tostring(token or "")
    if token:match("^[A-Z]$") then return token end
    if token:match("^F%d+$") then return token end
    return key_fields[token]
end

function Conflict.IniSectionValues(content, wanted_section)
    local out = {}
    local section = ""
    for raw_line in tostring(content or ""):gmatch("[^\r\n]+") do
        local line = trim(raw_line:gsub("[;#].*$", ""))
        local new_section = line:match("^%[([^%]]+)%]$")
        if new_section ~= nil then
            section = trim(new_section):lower()
        elseif section == tostring(wanted_section or ""):lower() then
            local key, value = line:match("^([^=]+)=(.*)$")
            if key ~= nil then out[trim(key):lower()] = trim(value) end
        end
    end
    return out
end

function Conflict.Priority(item)
    local category = tostring(type(item) == "table" and item.category or "")
    if category == "ue4ss-exact" then return 10 end
    if category == "ue4ss-setting" then return 20 end
    if category == "ue4ss-registry" then return 30 end
    if category == "tts-menu" then return 40 end
    if category == "game-mapping" then return 100 end
    return 60
end

function Conflict.State(conflicts, kind, expected_value)
    local result = type(conflicts) == "table" and conflicts[kind] or nil
    if type(result) ~= "table" or tostring(result.value) ~= tostring(expected_value) then return nil end
    return result
end

function Conflict.Badge(result)
    if result == nil or (tonumber(result.count) or 0) <= 0 then return "" end
    local count = tonumber(result.count) or 0
    return string.format(" [%d conflict%s]", count, count == 1 and "" or "s")
end

function Conflict.Details(result)
    if result == nil then return "Conflicts: not scanned yet" end
    local count = tonumber(result.count) or 0
    local lines = {
        count == 0 and "Conflicts: none known" or string.format("Conflicts: %d known", count),
    }
    for index = 1, count do
        local item = result.items[index]
        lines[#lines + 1] = "- " .. tostring(item.source) .. ": " .. tostring(item.detail)
    end
    if result.game_scan ~= nil and result.game_scan ~= "ok" then
        lines[#lines + 1] = "- Game mapping scan unavailable"
    end
    return table.concat(lines, "\n")
end

function Conflict.StatusSuffix(result)
    if result == nil then return " Conflict scan unavailable." end
    local count = tonumber(result.count) or 0
    if count == 0 then return " No known conflicts." end
    return string.format(" %d known conflict%s.", count, count == 1 and "" or "s")
end

function Conflict.Bind(Binding)
    if type(Binding) ~= "table"
        or type(Binding.Tokens) ~= "function"
        or type(Binding.TokenLabel) ~= "function" then
        error("MortalShell2ModUI Input.Conflict requires Input.Binding", 0)
    end

    local Bound = {
        Add = Conflict.Add,
        KeyFieldForToken = Conflict.KeyFieldForToken,
        IniSectionValues = Conflict.IniSectionValues,
        Priority = Conflict.Priority,
        State = Conflict.State,
        Badge = Conflict.Badge,
        Details = Conflict.Details,
        StatusSuffix = Conflict.StatusSuffix,
    }

    function Bound.ComponentKeyMap(value, modifier_sides_equivalent)
        local out = {}
        local function add(key_name, label)
            key_name = trim(key_name)
            if key_name ~= "" and out[key_name] == nil then out[key_name] = tostring(label or key_name) end
        end

        for _, token in ipairs(Binding.Tokens(value)) do
            local axis_key, direction = tostring(token):match("^axis:([^:]+):([^:]+)$")
            if axis_key ~= nil then
                local label = Binding.TokenLabel(token, modifier_sides_equivalent)
                add(axis_key, label)
                if axis_key == "Gamepad_LeftX" then
                    add("Gamepad_Left2D", label)
                    add(direction == "neg" and "Gamepad_LeftStick_Left" or "Gamepad_LeftStick_Right", label)
                elseif axis_key == "Gamepad_LeftY" then
                    add("Gamepad_Left2D", label)
                    add(direction == "pos" and "Gamepad_LeftStick_Up" or "Gamepad_LeftStick_Down", label)
                elseif axis_key == "Gamepad_RightX" then
                    add("Gamepad_Right2D", label)
                    add(direction == "neg" and "Gamepad_RightStick_Left" or "Gamepad_RightStick_Right", label)
                elseif axis_key == "Gamepad_RightY" then
                    add("Gamepad_Right2D", label)
                    add(direction == "pos" and "Gamepad_RightStick_Up" or "Gamepad_RightStick_Down", label)
                elseif axis_key == "Gamepad_LeftTriggerAxis" then
                    add("Gamepad_LeftTrigger", label)
                elseif axis_key == "Gamepad_RightTriggerAxis" then
                    add("Gamepad_RightTrigger", label)
                end
            else
                add(token, Binding.TokenLabel(token, modifier_sides_equivalent))
            end
        end
        return out
    end

    function Bound.CandidateChords(value)
        local modifiers = {}
        local modifier_seen = {}
        local bases = {}
        for _, token in ipairs(Binding.Tokens(value)) do
            local modifier = nil
            if token == "LeftControl" or token == "RightControl" then modifier = "CONTROL"
            elseif token == "LeftShift" or token == "RightShift" then modifier = "SHIFT"
            elseif token == "LeftAlt" or token == "RightAlt" then modifier = "ALT"
            end
            if modifier ~= nil then
                if not modifier_seen[modifier] then
                    modifier_seen[modifier] = true
                    modifiers[#modifiers + 1] = modifier
                end
            else
                local field = Conflict.KeyFieldForToken(token)
                if field ~= nil then bases[#bases + 1] = { token = token, field = field } end
            end
        end
        table.sort(modifiers)

        local out = {}
        for _, base in ipairs(bases) do
            local parts = {}
            for _, modifier in ipairs(modifiers) do parts[#parts + 1] = modifier end
            parts[#parts + 1] = base.field
            out[#out + 1] = {
                token = base.token,
                key_field = base.field,
                modifier_fields = modifiers,
                fingerprint = table.concat(parts, "+"),
            }
        end
        return out
    end

    function Bound.ChordLabel(chord, modifier_sides_equivalent)
        if type(chord) ~= "table" then return "Unknown chord" end
        local parts = {}
        for _, modifier in ipairs(chord.modifier_fields or {}) do
            if modifier == "CONTROL" then parts[#parts + 1] = "Ctrl"
            elseif modifier == "SHIFT" then parts[#parts + 1] = "Shift"
            elseif modifier == "ALT" then parts[#parts + 1] = "Alt"
            else parts[#parts + 1] = tostring(modifier) end
        end
        parts[#parts + 1] = Binding.TokenLabel(chord.token, modifier_sides_equivalent)
        return table.concat(parts, " + ")
    end

    return Bound
end

return Conflict
