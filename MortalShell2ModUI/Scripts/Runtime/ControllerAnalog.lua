-- MortalShell2ModUI Runtime.ControllerAnalog
-- Shared controller-axis fallback reader. The standalone host and consumer runtime can
-- use the same stick/trigger policy without duplicating MortalShell2TTS-specific physical
-- reads. Pass 178 makes finite analog data authoritative at every magnitude: deadzone and
-- activation policy belong above this physical reader, so a near-center scalar must never be
-- replaced by a synthetic digital +/-1. Paired/digital fallbacks are now used only when the
-- corresponding analog API is genuinely unavailable/non-finite. Pass 174's coherent Stick()
-- pairing remains intact for capture/calibration/test consumers.
-- Trigger axes prefer the direct scalar and fall back to the digital trigger FKey.
-- No UI/action semantics live here.

local M = {}

local STICK_AXIS = {
    Gamepad_LeftX  = { stick = 0, component = "x", positive = "Gamepad_LeftStick_Right", negative = "Gamepad_LeftStick_Left" },
    Gamepad_LeftY  = { stick = 0, component = "y", positive = "Gamepad_LeftStick_Up",    negative = "Gamepad_LeftStick_Down" },
    Gamepad_RightX = { stick = 1, component = "x", positive = "Gamepad_RightStick_Right", negative = "Gamepad_RightStick_Left" },
    Gamepad_RightY = { stick = 1, component = "y", positive = "Gamepad_RightStick_Down",  negative = "Gamepad_RightStick_Up" },
}

local TRIGGER_AXIS = {
    Gamepad_LeftTriggerAxis = "Gamepad_LeftTrigger",
    Gamepad_RightTriggerAxis = "Gamepad_RightTrigger",
}

local STICK_PAIR = {
    left = {
        stick = 0, x_key = "Gamepad_LeftX", y_key = "Gamepad_LeftY",
        right = "Gamepad_LeftStick_Right", left = "Gamepad_LeftStick_Left",
        up = "Gamepad_LeftStick_Up", down = "Gamepad_LeftStick_Down",
    },
    right = {
        stick = 1, x_key = "Gamepad_RightX", y_key = "Gamepad_RightY",
        right = "Gamepad_RightStick_Right", left = "Gamepad_RightStick_Left",
        up = "Gamepad_RightStick_Up", down = "Gamepad_RightStick_Down", raw_y_inverted = true,
    },
}

-- Diagnostic-only activity label. It never decides whether analog data is accepted: any
-- finite analog pair is authoritative after Pass 178. This threshold only labels the returned
-- source string as active vs neutral for logs/debugging. Deadzone/activation policy belongs to
-- Controller.Profile above this reader.
local CAPTURE_DIRECT_ACTIVITY = 0.10

local function finite(value)
    value = tonumber(value)
    return value ~= nil and value == value and value ~= math.huge and value ~= -math.huge
end

local function out_number(value, component)
    value = value
    if finite(value) then return tonumber(value) end
    if type(value) ~= "table" then return nil end
    local preferred
    if component == "x" then
        preferred = { "StickX", "X", "Value", "value", "OutValue", "ReturnValue" }
    else
        preferred = { "StickY", "Y", "Value", "value", "OutValue", "ReturnValue" }
    end
    for _, key in ipairs(preferred) do
        if finite(value[key]) then return tonumber(value[key]) end
    end
    for _, item in pairs(value) do
        if finite(item) then return tonumber(item) end
    end
    return nil
end

function M.New(options)
    options = type(options) == "table" and options or {}
    local unwrap = options.unwrap
    local valid = options.valid
    local analog_value = options.analog_value
    local key_down = options.key_down
    if type(unwrap) ~= "function" then return nil, "unwrap missing" end
    if type(valid) ~= "function" then return nil, "valid missing" end
    if type(analog_value) ~= "function" then return nil, "analog_value missing" end
    if type(key_down) ~= "function" then return nil, "key_down missing" end

    local self = {}

    -- Return one coherent X/Y sample for binding capture, calibration, and Controller Test.
    -- Analog source selection is threshold-free; consumer layers own deadzone/activation.
    function self.Stick(controller, stick_name, stick_options)
        stick_name = tostring(stick_name or "left")
        stick_options = type(stick_options) == "table" and stick_options or {}
        local direct_activity = tonumber(stick_options.direct_activity) or CAPTURE_DIRECT_ACTIVITY
        direct_activity = math.max(0.03, math.min(0.20, direct_activity))
        local spec = STICK_PAIR[stick_name]
        if spec == nil then return nil, nil, "stick-invalid", "stick-invalid" end
        controller = unwrap(controller)
        if not valid(controller) then return nil, nil, "controller-invalid", "controller-invalid" end

        local direct_x, direct_x_error = analog_value(controller, spec.x_key)
        local direct_y, direct_y_error = analog_value(controller, spec.y_key)
        local x_ok, y_ok = finite(direct_x), finite(direct_y)
        local x_value = x_ok and tonumber(direct_x) or 0.0
        local y_value = y_ok and tonumber(direct_y) or 0.0
        -- A successful analog pair is authoritative even inside the configured deadzone.
        -- Source selection must not apply capture/deadzone thresholds: doing so allowed the
        -- later digital cardinal fallback to turn a real near-center value into synthetic
        -- +/-1. Filtering/activation is applied by Controller.Profile/Input.Capture instead.
        if x_ok and y_ok then
            return x_value, y_value,
                math.abs(x_value) >= direct_activity and spec.x_key or (spec.x_key .. "-neutral"),
                math.abs(y_value) >= direct_activity and spec.y_key or (spec.y_key .. "-neutral")
        end

        -- If the native paired API works in this game/build, prefer its one-call X/Y result.
        local get_stick = controller["GetInputAnalogStickState"]
        if get_stick ~= nil then
            local x_out, y_out = {}, {}
            local ok_stick, stick_error = pcall(function()
                controller:GetInputAnalogStickState(spec.stick, x_out, y_out)
            end)
            if ok_stick then
                local paired_x = out_number(x_out, "x")
                local paired_y = out_number(y_out, "y")
                if finite(paired_x) or finite(paired_y) then
                    paired_x = finite(paired_x) and tonumber(paired_x) or 0.0
                    paired_y = finite(paired_y) and tonumber(paired_y) or 0.0
                    return paired_x, paired_y, "GetInputAnalogStickState", "GetInputAnalogStickState"
                end
            elseif direct_x_error == nil and direct_y_error == nil then
                direct_x_error, direct_y_error = tostring(stick_error), tostring(stick_error)
            end
        end

        -- Only synthesize cardinal +/-1 values when no finite analog pair is available.
        -- Query all four keys as one pair so X/Y are derived from the same fallback policy.
        local right = select(1, key_down(controller, spec.right)) == true
        local left = select(1, key_down(controller, spec.left)) == true
        local up = select(1, key_down(controller, spec.up)) == true
        local down = select(1, key_down(controller, spec.down)) == true
        local digital_x = right ~= left and (right and 1.0 or -1.0) or 0.0
        local digital_y = up ~= down and (up and 1.0 or -1.0) or 0.0
        if spec.raw_y_inverted == true then digital_y = -digital_y end
        if digital_x ~= 0.0 or digital_y ~= 0.0 then
            local x_source = right ~= left and (right and spec.right or spec.left) or (spec.x_key .. "-neutral")
            local y_source = up ~= down and (up and spec.up or spec.down) or (spec.y_key .. "-neutral")
            return digital_x, digital_y, x_source, y_source
        end

        if x_ok or y_ok then
            return x_value, y_value, spec.x_key .. "-neutral", spec.y_key .. "-neutral"
        end
        local err = tostring(direct_x_error or direct_y_error or "stick-unavailable")
        return nil, nil, err, err
    end

    function self.Axis(controller, axis_key)
        axis_key = tostring(axis_key or "")
        controller = unwrap(controller)
        if not valid(controller) then return nil, "controller-invalid" end

        local direct, direct_error = analog_value(controller, axis_key)
        -- A finite direct scalar is authoritative at any magnitude. Deadzone/activation
        -- belongs to the consumer profile, not the source-selection layer.
        if finite(direct) then
            direct = tonumber(direct)
            return direct, math.abs(direct) >= 0.05 and axis_key or (axis_key .. "-neutral")
        end

        local stick = STICK_AXIS[axis_key]
        if stick ~= nil then
            local get_stick = controller["GetInputAnalogStickState"]
            if get_stick ~= nil then
                local x_out, y_out = {}, {}
                local ok_stick, stick_error = pcall(function()
                    controller:GetInputAnalogStickState(stick.stick, x_out, y_out)
                end)
                if ok_stick then
                    local value = stick.component == "x"
                        and out_number(x_out, "x") or out_number(y_out, "y")
                    if finite(value) then
                        return tonumber(value), "GetInputAnalogStickState"
                    end
                elseif direct_error == nil then
                    direct_error = tostring(stick_error)
                end
            end

            local positive = select(1, key_down(controller, stick.positive))
            local negative = select(1, key_down(controller, stick.negative))
            if positive == true and negative ~= true then return 1.0, stick.positive end
            if negative == true and positive ~= true then return -1.0, stick.negative end
        end

        local trigger = TRIGGER_AXIS[axis_key]
        if trigger ~= nil then
            local pressed = select(1, key_down(controller, trigger))
            if pressed == true then return 1.0, trigger end
        end

        if finite(direct) then return tonumber(direct), axis_key .. "-neutral" end
        return nil, tostring(direct_error or (axis_key ~= "" and (axis_key .. "-unavailable") or "axis-unavailable"))
    end

    function self.RightY(controller)
        return self.Axis(controller, "Gamepad_RightY")
    end

    function self.SupportedAxes()
        return {
            "Gamepad_LeftX",
            "Gamepad_LeftY",
            "Gamepad_RightX",
            "Gamepad_RightY",
            "Gamepad_LeftTriggerAxis",
            "Gamepad_RightTriggerAxis",
        }
    end

    return self
end

return M
