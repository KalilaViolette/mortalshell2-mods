-- MortalShell2ModUI Input.Binding
-- Pure binding-string parsing and presentation helpers only. This module owns no
-- Unreal objects, hooks, polling, recorder state, conflict scans, or input routes.

local Binding = {}

local function trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$")
end

Binding.Labels = {
    LeftControl = "Ctrl", RightControl = "Right Ctrl",
    LeftShift = "Shift", RightShift = "Right Shift",
    LeftAlt = "Alt", RightAlt = "Right Alt",
    Zero = "0", One = "1", Two = "2", Three = "3", Four = "4",
    Five = "5", Six = "6", Seven = "7", Eight = "8", Nine = "9",
    SpaceBar = "Space", BackSpace = "Backspace", Delete = "Del",
    PageUp = "Page Up", PageDown = "Page Down",
    Semicolon = ";", Equals = "=", Comma = ",", Hyphen = "-", Period = ".",
    Slash = "/", Tilde = "`", LeftBracket = "[", Backslash = "\\", RightBracket = "]", Apostrophe = "'",
    Gamepad_LeftThumbstick = "L3", Gamepad_RightThumbstick = "R3",
    Gamepad_FaceButton_Bottom = "Cross / A", Gamepad_FaceButton_Right = "Circle / B", Gamepad_FaceButton_Left = "Square / X",
    Gamepad_FaceButton_Top = "Triangle / Y",
    Gamepad_LeftShoulder = "L1", Gamepad_RightShoulder = "R1",
    Gamepad_DPad_Up = "D-Pad Up", Gamepad_DPad_Down = "D-Pad Down",
    Gamepad_DPad_Left = "D-Pad Left", Gamepad_DPad_Right = "D-Pad Right",
    Gamepad_Special_Left = "Share / Back", Gamepad_Special_Right = "Options / Start",
}

Binding.AxisLabels = {
    ["axis:Gamepad_LeftX:neg"] = "L Stick Left",
    ["axis:Gamepad_LeftX:pos"] = "L Stick Right",
    ["axis:Gamepad_LeftY:pos"] = "L Stick Up",
    ["axis:Gamepad_LeftY:neg"] = "L Stick Down",
    ["axis:Gamepad_RightX:neg"] = "R Stick Left",
    ["axis:Gamepad_RightX:pos"] = "R Stick Right",
    ["axis:Gamepad_RightY:pos"] = "R Stick Down",
    ["axis:Gamepad_RightY:neg"] = "R Stick Up",
    ["axis:Gamepad_LeftTriggerAxis:pos"] = "L2",
    ["axis:Gamepad_RightTriggerAxis:pos"] = "R2",
}

local tokens_cache = {}

function Binding.IsSequence(value)
    return tostring(value or ""):sub(1, 4):lower() == "seq:"
end

function Binding.Tokens(value)
    local original = trim(value)
    local cached = tokens_cache[original]
    if cached ~= nil then return cached end

    local raw = original
    local out = {}
    if raw == "" or raw:lower() == "off" then
        tokens_cache[original] = out
        return out
    end

    if Binding.IsSequence(raw) then
        raw = raw:sub(5)
        for raw_token in raw:gmatch("[^>]+") do
            local token = trim(raw_token)
            if token ~= "" then out[#out + 1] = token end
        end
        tokens_cache[original] = out
        return out
    end

    for raw_token in raw:gmatch("[^+]+") do
        local token = trim(raw_token)
        if token ~= "" then out[#out + 1] = token end
    end
    tokens_cache[original] = out
    return out
end

function Binding.TokenLabel(token, modifier_sides_equivalent)
    token = tostring(token or "")
    if modifier_sides_equivalent == true then
        if token == "LeftControl" or token == "RightControl" then return "Ctrl" end
        if token == "LeftShift" or token == "RightShift" then return "Shift" end
        if token == "LeftAlt" or token == "RightAlt" then return "Alt" end
    end
    return Binding.AxisLabels[token] or Binding.Labels[token] or token
end

function Binding.Label(value, fallback, modifier_sides_equivalent)
    local labels = {}
    for _, token in ipairs(Binding.Tokens(value)) do
        labels[#labels + 1] = Binding.TokenLabel(token, modifier_sides_equivalent)
    end
    if #labels == 0 then return tostring(fallback or "Unbound") end
    return table.concat(labels, " + ")
end

return Binding
