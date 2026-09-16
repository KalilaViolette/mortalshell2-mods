-- MortalShell2ModUI Input.Capture
-- Pure keybind-recorder state/serialization helpers only. This module owns no
-- Unreal objects, polling, analog reads, recorder lifecycle, config writes, or UI.
-- Pass 38 also owns the deterministic thumbstick cardinal-direction gate state
-- machine; the consumer still supplies sampled axis values and owns diagnostics.

local Capture = {}

-- Public capture catalogs let every settings provider use the same recorder
-- vocabulary as TTS without adding its own physical-input scanner. The
-- standalone ModUI host remains the sole owner of querying these keys.
Capture.KeyboardKeys = {
    "LeftControl", "RightControl", "LeftShift", "RightShift", "LeftAlt", "RightAlt",
    "A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M",
    "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z",
    "Zero", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine",
    "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12",
    "SpaceBar", "Tab", "Enter", "Escape", "BackSpace", "Insert", "Delete", "Home", "End", "PageUp", "PageDown",
    "Up", "Down", "Left", "Right", "CapsLock", "NumLock", "ScrollLock",
    "Semicolon", "Equals", "Comma", "Hyphen", "Period", "Slash", "Tilde",
    "LeftBracket", "Backslash", "RightBracket", "Apostrophe",
    "NumPadZero", "NumPadOne", "NumPadTwo", "NumPadThree", "NumPadFour",
    "NumPadFive", "NumPadSix", "NumPadSeven", "NumPadEight", "NumPadNine",
    "Decimal", "Divide", "Multiply", "Subtract", "Add",
}

Capture.ControllerKeys = {
    "Gamepad_LeftThumbstick", "Gamepad_RightThumbstick",
    "Gamepad_FaceButton_Bottom", "Gamepad_FaceButton_Right", "Gamepad_FaceButton_Left", "Gamepad_FaceButton_Top",
    "Gamepad_LeftShoulder", "Gamepad_RightShoulder",
    "Gamepad_DPad_Up", "Gamepad_DPad_Down", "Gamepad_DPad_Left", "Gamepad_DPad_Right",
    "Gamepad_Special_Left", "Gamepad_Special_Right",
}

function Capture.NewState(kind, started_clock, clock_source)
    if kind ~= "keyboard" and kind ~= "controller" then return nil end
    return {
        active = true,
        kind = kind,
        phase = "wait_clear",
        seen = {},
        order = {},
        press_order = {},
        previous_active = {},
        last_display = "",
        started_clock = tonumber(started_clock),
        clock_source = tostring(clock_source or "unknown"),
        starter_token = kind == "keyboard" and "Enter" or "Gamepad_FaceButton_Bottom",
        starter_suppress_until = nil,
        stick_capture = {},
    }
end

function Capture.NewStickGate(required_neutral_ticks)
    return {
        active_token = nil,
        neutral_ticks = math.max(0, math.floor(tonumber(required_neutral_ticks) or 3)),
        neutral_logged = false,
    }
end

function Capture.ResolveStickDirection(gate, stick_name, x, y, options)
    if type(gate) ~= "table" then return nil, nil end
    stick_name = tostring(stick_name or "left")
    x = tonumber(x) or 0.0
    y = tonumber(y) or 0.0
    options = type(options) == "table" and options or {}

    local activation = tonumber(options.activation) or 0.68
    local release = tonumber(options.release) or 0.30
    local neutral = tonumber(options.neutral) or 0.22
    local dominance_margin = tonumber(options.dominance_margin) or 0.12
    local required_neutral_ticks = math.max(1, math.floor(tonumber(options.required_neutral_ticks) or 3))
    local prefix = stick_name == "left" and "Gamepad_Left" or "Gamepad_Right"

    if gate.active_token ~= nil then
        local token = tostring(gate.active_token)
        local held = false
        if token:find("X:neg", 1, true) ~= nil then held = x <= -release
        elseif token:find("X:pos", 1, true) ~= nil then held = x >= release
        elseif token:find("Y:neg", 1, true) ~= nil then held = y <= -release
        elseif token:find("Y:pos", 1, true) ~= nil then held = y >= release end
        if held then return token, nil end

        gate.active_token = nil
        gate.neutral_ticks = 0
        gate.neutral_logged = false
        return nil, { status = "released-wait-neutral", token = token }
    end

    local ax, ay = math.abs(x), math.abs(y)
    if ax <= neutral and ay <= neutral then
        gate.neutral_ticks = math.min(required_neutral_ticks, (tonumber(gate.neutral_ticks) or 0) + 1)
        if gate.neutral_ticks >= required_neutral_ticks and not gate.neutral_logged then
            gate.neutral_logged = true
            return nil, { status = "neutral-rearmed" }
        end
        return nil, nil
    end

    gate.neutral_logged = false
    if (tonumber(gate.neutral_ticks) or 0) < required_neutral_ticks then return nil, nil end
    if math.max(ax, ay) < activation then return nil, nil end
    if math.abs(ax - ay) < dominance_margin then return nil, nil end

    local token
    if ax > ay then
        token = "axis:" .. prefix .. "X:" .. (x < 0 and "neg" or "pos")
    else
        token = "axis:" .. prefix .. "Y:" .. (y < 0 and "neg" or "pos")
    end
    gate.active_token = token
    gate.neutral_ticks = 0
    return token, { status = "captured-direction", token = token }
end

function Capture.InputsLabel(inputs, binding, modifier_sides_equivalent)
    local labels = {}
    if type(binding) ~= "table" or type(binding.TokenLabel) ~= "function" then return "" end
    for _, token in ipairs(inputs or {}) do
        labels[#labels + 1] = binding.TokenLabel(token, modifier_sides_equivalent == true)
    end
    return table.concat(labels, " + ")
end

function Capture.ResolveCommit(state)
    if type(state) ~= "table" or state.active ~= true then return nil end
    if #(state.order or {}) == 0 then return nil end

    local press_order = state.press_order or {}
    local duplicate_seen = false
    local press_seen = {}
    for _, token in ipairs(press_order) do
        if press_seen[token] then
            duplicate_seen = true
            break
        end
        press_seen[token] = true
    end

    local committed_tokens = duplicate_seen and press_order or (state.order or {})
    local kind = tostring(state.kind or "")
    if #committed_tokens == 1 then
        local only = committed_tokens[1]
        if kind == "keyboard" and only == "Escape" then
            return { cancel = true, cancel_reason = "Escape alone", kind = kind }
        elseif kind == "controller" and only == "Gamepad_FaceButton_Right" then
            return { cancel = true, cancel_reason = "Circle alone", kind = kind }
        end
    end

    local mode = duplicate_seen and "sequence" or "chord"
    local serialized = duplicate_seen
        and ("seq:" .. table.concat(committed_tokens, ">"))
        or table.concat(committed_tokens, "+")

    return {
        cancel = false,
        kind = kind,
        mode = mode,
        serialized = serialized,
        tokens = committed_tokens,
        steps = #committed_tokens,
    }
end

return Capture
