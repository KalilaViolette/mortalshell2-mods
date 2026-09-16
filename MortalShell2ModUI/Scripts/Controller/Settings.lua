-- MortalShell2ModUI Controller.Settings
-- Reusable controller settings/calibration/test view-model. Consumer mods supply only
-- primitive axis/key mailbox readers plus presentation callbacks; controller interpretation,
-- calibration math and persistence remain shared ModUI responsibilities.

local Settings = {}

local BUTTON_KEYS = {
    "Gamepad_LeftThumbstick", "Gamepad_RightThumbstick",
    "Gamepad_FaceButton_Bottom", "Gamepad_FaceButton_Right", "Gamepad_FaceButton_Left", "Gamepad_FaceButton_Top",
    "Gamepad_LeftShoulder", "Gamepad_RightShoulder",
    "Gamepad_DPad_Up", "Gamepad_DPad_Down", "Gamepad_DPad_Left", "Gamepad_DPad_Right",
    "Gamepad_Special_Left", "Gamepad_Special_Right",
}

local BUTTON_LABELS = {
    Gamepad_LeftThumbstick = "L3", Gamepad_RightThumbstick = "R3",
    Gamepad_FaceButton_Bottom = "Cross", Gamepad_FaceButton_Right = "Circle",
    Gamepad_FaceButton_Left = "Square", Gamepad_FaceButton_Top = "Triangle",
    Gamepad_LeftShoulder = "L1", Gamepad_RightShoulder = "R1",
    Gamepad_DPad_Up = "DPad Up", Gamepad_DPad_Down = "DPad Down",
    Gamepad_DPad_Left = "DPad Left", Gamepad_DPad_Right = "DPad Right",
    Gamepad_Special_Left = "Select", Gamepad_Special_Right = "Start",
}

local SETTING_ROWS = {
    { key = "stick_activation", label = "Stick Activation", kind = "number", step = 0.01, fine_step = 0.001 },
    { key = "stick_release", label = "Stick Release", kind = "number", step = 0.01, fine_step = 0.001 },
    { key = "stick_neutral", label = "Stick Deadzone", kind = "number", step = 0.01, fine_step = 0.001 },
    { key = "dominance_margin", label = "Direction Margin", kind = "number", step = 0.01, fine_step = 0.001 },
    { key = "neutral_ticks", label = "Neutral Samples", kind = "integer", step = 1 },
    { key = "trigger_activation", label = "Trigger Activation", kind = "number", step = 0.05 },
    { key = "trigger_release", label = "Trigger Release", kind = "number", step = 0.05 },
    { key = "calibrate", label = "Calibrate Controller", kind = "action" },
    { key = "test", label = "Test Controller", kind = "action" },
    { key = "reset", label = "Reset Controller", kind = "action" },
}

local CALIBRATION_STEPS = {
    { kind = "center", label = "Center both sticks" },
    { stick = "left", axis = "y", sign = 1, label = "Left Stick Up" },
    { stick = "left", axis = "y", sign = -1, label = "Left Stick Down" },
    { stick = "left", axis = "x", sign = -1, label = "Left Stick Left" },
    { stick = "left", axis = "x", sign = 1, label = "Left Stick Right" },
    { stick = "right", axis = "y", sign = -1, label = "Right Stick Up" },
    { stick = "right", axis = "y", sign = 1, label = "Right Stick Down" },
    { stick = "right", axis = "x", sign = -1, label = "Right Stick Left" },
    { stick = "right", axis = "x", sign = 1, label = "Right Stick Right" },
}

local function clamp(value, low, high)
    value = tonumber(value) or low
    if value < low then return low end
    if value > high then return high end
    return value
end

local function round(value, digits)
    local scale = 10 ^ math.max(0, math.floor(tonumber(digits) or 0))
    return math.floor((tonumber(value) or 0) * scale + 0.5) / scale
end

local function format_axis(value)
    value = tonumber(value) or 0.0
    return string.format("%+.3f", value)
end

local function format_setting(value)
    value = tonumber(value) or 0.0
    if math.abs(value) < 0.010 then return string.format("%.3f", value) end
    return string.format("%.2f", value)
end

local function direction(x, y, profile)
    x, y = tonumber(x) or 0.0, tonumber(y) or 0.0
    profile = type(profile) == "table" and profile or {}
    local activation = tonumber(profile.stick_activation) or 0.12
    local margin = tonumber(profile.dominance_margin) or 0.05
    local ax, ay = math.abs(x), math.abs(y)
    if math.max(ax, ay) < activation then return "Neutral" end
    if math.abs(ax - ay) < margin then return "Diagonal" end
    if ax > ay then return x < 0 and "Left" or "Right" end
    return y < 0 and "Down" or "Up"
end

local function sample_pair(read_axis, x_key, y_key)
    local x, xs, xr, xf = read_axis(x_key)
    local y, ys, yr, yf = read_axis(y_key)
    x, y = tonumber(x), tonumber(y)
    if x == nil or y == nil then return nil, "axis-unavailable" end
    if xr == false or yr == false then return nil, "host-unavailable" end
    if tonumber(xf) ~= nil and tonumber(yf) ~= nil and tonumber(xf) ~= tonumber(yf) then
        return nil, "frame-mismatch"
    end
    return { x = x, y = y, x_source = tostring(xs or ""), y_source = tostring(ys or ""), frame = tonumber(xf) or tonumber(yf) or 0 }
end

local function calibration_new()
    return {
        step = 1, phase = "collect", center_count = 0, center_max = 0.0,
        center_sum = { lx = 0.0, ly = 0.0, rx = 0.0, ry = 0.0 },
        center_min = { lx = nil, ly = nil, rx = nil, ry = nil },
        center_maximum = { lx = nil, ly = nil, rx = nil, ry = nil },
        centers = { lx = 0.0, ly = 0.0, rx = 0.0, ry = 0.0 },
        neutral_count = 0, onsets = {}, peaks = {}, extrema = {}, complete = false,
        current_peak = 0.0, current_peak_raw = 0.0,
        message = "Center both sticks and release all controller inputs.",
    }
end

local function calibration_prompt(state)
    local step = CALIBRATION_STEPS[math.max(1, math.min(#CALIBRATION_STEPS, tonumber(state.step) or 1))]
    if state.complete then return "Calibration complete." end
    if step.kind == "center" then return "Center both sticks and keep them still." end
    if state.phase == "release" then return "Release " .. step.label .. " back to center." end
    return "Move " .. step.label .. " fully and hold briefly."
end

local function reset_center_collection(state)
    state.center_count = 0
    state.center_max = 0.0
    state.center_sum = { lx = 0.0, ly = 0.0, rx = 0.0, ry = 0.0 }
    state.center_min = { lx = nil, ly = nil, rx = nil, ry = nil }
    state.center_maximum = { lx = nil, ly = nil, rx = nil, ry = nil }
end

local function calibration_update(state, sample)
    if type(state) ~= "table" or state.complete == true or type(sample) ~= "table" then return nil end
    local step = CALIBRATION_STEPS[state.step]
    if step == nil then state.complete = true; return { status = "complete" } end

    local lx, ly = tonumber(sample.lx) or 0.0, tonumber(sample.ly) or 0.0
    local rx, ry = tonumber(sample.rx) or 0.0, tonumber(sample.ry) or 0.0
    if step.kind == "center" then
        local maximum = math.max(math.abs(lx), math.abs(ly), math.abs(rx), math.abs(ry))
        if maximum <= 0.250 then
            state.center_count = state.center_count + 1
            local values = { lx = lx, ly = ly, rx = rx, ry = ry }
            for key, value in pairs(values) do
                state.center_sum[key] = (tonumber(state.center_sum[key]) or 0.0) + value
                state.center_min[key] = state.center_min[key] == nil and value or math.min(state.center_min[key], value)
                state.center_maximum[key] = state.center_maximum[key] == nil and value or math.max(state.center_maximum[key], value)
            end
        else
            reset_center_collection(state)
        end
        if state.center_count >= 12 then
            local noise = 0.0
            for _, key in ipairs({ "lx", "ly", "rx", "ry" }) do
                local center = (tonumber(state.center_sum[key]) or 0.0) / math.max(1, state.center_count)
                state.centers[key] = center
                noise = math.max(noise,
                    math.abs((tonumber(state.center_min[key]) or center) - center),
                    math.abs((tonumber(state.center_maximum[key]) or center) - center))
            end
            state.center_max = noise
            state.step = 2
            state.phase = "seek"
            state.message = calibration_prompt(state)
            return { status = "center-captured", neutral_noise = state.center_max }
        end
        state.message = "Center both sticks... " .. tostring(math.min(12, state.center_count)) .. "/12"
        return nil
    end

    local pair = step.stick == "left" and { x = lx, y = ly } or { x = rx, y = ry }
    local centers = state.centers or {}
    local center_x = step.stick == "left" and (tonumber(centers.lx) or 0.0) or (tonumber(centers.rx) or 0.0)
    local center_y = step.stick == "left" and (tonumber(centers.ly) or 0.0) or (tonumber(centers.ry) or 0.0)
    local centered_x, centered_y = pair.x - center_x, pair.y - center_y
    local expected = step.axis == "x" and centered_x or centered_y
    local orthogonal = step.axis == "x" and centered_y or centered_x
    local expected_raw = step.axis == "x" and pair.x or pair.y
    local signed = expected * step.sign
    local release_limit = math.min(0.150, math.max(0.010, state.center_max * 3.0 + 0.003))

    if state.phase == "seek" then
        local onset_floor = math.min(0.100, math.max(0.001, state.center_max * 3.0 + 0.001))
        local onset_margin = math.min(0.050, math.max(0.001, state.center_max * 2.0 + 0.001))
        if signed >= onset_floor and math.abs(expected) >= math.abs(orthogonal) + onset_margin then
            state.onsets[#state.onsets + 1] = math.abs(expected)
            state.peaks[#state.peaks + 1] = math.abs(expected)
            state.current_peak = math.abs(expected)
            state.current_peak_raw = expected_raw
            state.phase = "release"
            state.neutral_count = 0
            state.message = calibration_prompt(state)
            return { status = "direction-captured", label = step.label, onset = math.abs(expected) }
        end
        if math.max(math.abs(centered_x), math.abs(centered_y)) >= 0.150 then
            state.message = "Waiting for " .. step.label .. "; detected " .. direction(centered_x, centered_y, { stick_activation = onset_floor, dominance_margin = onset_margin }) .. "."
        else
            state.message = calibration_prompt(state)
        end
        return nil
    end

    local current_magnitude = math.abs(expected)
    if current_magnitude > (tonumber(state.current_peak) or 0.0) then
        state.current_peak = current_magnitude
        state.current_peak_raw = expected_raw
    end
    state.peaks[#state.peaks] = math.max(state.peaks[#state.peaks] or 0.0, current_magnitude)
    if math.abs(centered_x) <= release_limit and math.abs(centered_y) <= release_limit then
        state.neutral_count = state.neutral_count + 1
    else
        state.neutral_count = 0
    end
    if state.neutral_count >= 3 then
        if (tonumber(state.current_peak) or 0.0) < 0.350 then
            state.onsets[#state.onsets] = nil
            state.peaks[#state.peaks] = nil
            state.current_peak, state.current_peak_raw = 0.0, 0.0
            state.phase = "seek"
            state.neutral_count = 0
            state.message = "Move " .. step.label .. " farther toward its full range, then return to center."
            return { status = "direction-too-small", label = step.label }
        end
        state.extrema[step.label] = tonumber(state.current_peak_raw) or expected_raw
        state.current_peak, state.current_peak_raw = 0.0, 0.0
        state.step = state.step + 1
        state.phase = "seek"
        state.neutral_count = 0
        if state.step > #CALIBRATION_STEPS then
            state.complete = true
            state.message = "Calibration complete. Applying recommended shared profile."
            return { status = "complete" }
        end
        state.message = calibration_prompt(state)
        return { status = "rearmed", next = CALIBRATION_STEPS[state.step].label }
    end
    return nil
end

-- v0.70.0: the whole controller screen as one presentation snapshot, ready for
-- ConsumerClient.Presentation(). Any consumer that owns a view (ConsumerClient
-- .ControllerSettings) publishes this while the view is active and forwards its
-- navigation to view.Move / Change / Activate / Back; nothing about the screen is
-- consumer-specific. Browser profile: the wide window the calibration text needs.
function Settings.Presentation(view, options)
    if type(view) ~= "table" or type(view.Rows) ~= "function" then return nil, "controller view missing" end
    options = type(options) == "table" and options or {}
    local rows = view.Rows() or {}
    local selected = math.max(1, math.min(math.max(#rows, 1), math.floor(tonumber(view.selected) or 1)))
    local labels, values, kinds, progress = {}, {}, {}, {}
    for index, row in ipairs(rows) do
        local label = type(view.Label) == "function" and view.Label(row) or tostring(row.label or row.key or "")
        local value = type(view.Value) == "function" and view.Value(row) or ""
        local is_selected = index == selected
        labels[#labels + 1] = (is_selected and "> " or "  ") .. tostring(label)
        local kind = tostring(row.kind or "")
        local adjustable = kind ~= "action" and kind ~= "test" and kind ~= "back"
            and tostring(value) ~= "" and tostring(value) ~= "Open" and tostring(value) ~= "Enter"
        values[#values + 1] = (is_selected and adjustable) and ("< " .. tostring(value) .. " >") or tostring(value)
        kinds[#kinds + 1] = adjustable and "choice" or "action"
        progress[#progress + 1] = "0"
    end
    local row = rows[selected]
    local hint = type(view.ControlHint) == "function" and row ~= nil and view.ControlHint(row) or ""
    if tostring(hint) == "" then hint = "Up/Down Select   Left/Right Change   Enter/Cross Activate   Back Return" end
    -- Details: the row's description, the current value, the view's last status line
    -- (calibration prompts, "saved", failures) and the control hint, in that order.
    -- `options.wrap(text)` lets the consumer window it for its details panel.
    local details = { tostring(row ~= nil and type(view.Description) == "function" and view.Description(row) or "") }
    if row ~= nil and tostring(row.kind or "") ~= "action" and tostring(row.kind or "") ~= "display" then
        local value = type(view.Value) == "function" and view.Value(row) or ""
        if tostring(value) ~= "" then
            details[#details + 1] = ""
            details[#details + 1] = "Current: " .. tostring(value)
        end
    end
    local status = tostring(options.status or "")
    if status:match("%S") then
        details[#details + 1] = ""
        details[#details + 1] = "Status: " .. status
    end
    local details_text = table.concat(details, "\n")
    if type(options.wrap) == "function" then
        local ok, wrapped = pcall(options.wrap, details_text)
        if ok and type(wrapped) == "string" then details_text = wrapped end
    end
    return {
        profile = "browser",
        header = tostring(options.header or (type(view.HeaderText) == "function" and view.HeaderText()) or "MORTAL SHELL 2 MOD UI - CONTROLLER"),
        page = tostring(type(view.PageText) == "function" and view.PageText() or ""),
        tabs = tostring(type(view.TabText) == "function" and view.TabText() or "[ CONTROLLER ]"),
        tabLabels = "CONTROLLER",
        selectedTab = 1,
        selectedRow = selected,
        rowKinds = table.concat(kinds, "\n"),
        rowProgress = table.concat(progress, "\n"),
        labels = table.concat(labels, "\n"),
        values = table.concat(values, "\n"),
        body = tostring(hint),
        detailTitle = tostring(row ~= nil and (type(view.Label) == "function" and view.Label(row) or row.label) or "Controller"),
        details = details_text,
    }
end

function Settings.New(options)
    options = type(options) == "table" and options or {}
    local Profile = options.profile
    if type(Profile) ~= "table" or type(Profile.Current) ~= "function" or type(Profile.Save) ~= "function" then
        return nil, "Controller.Settings requires Controller.Profile"
    end
    local read_axis = options.read_axis
    local read_key = options.read_key
    local set_capture_request = options.set_capture_request
    if type(read_axis) ~= "function" then return nil, "controller axis reader missing" end

    local self = {
        active = false, mode = "settings", selected = 1, parent_selected = 1, subview_parent_selected = 1,
        profile = Profile.Current(), calibration = nil, reset_armed = false,
        sample = { lx = 0, ly = 0, rx = 0, ry = 0, lt = 0, rt = 0, buttons = "None" },
        sample_signature = "", last_render_poll = 0, poll_count = 0, sampling = false,
    }

    local function call(name, ...)
        local fn = options[name]
        if type(fn) ~= "function" then return nil end
        return fn(...)
    end

    local function set_status(value)
        call("set_status", tostring(value or ""))
    end

    local function interpreted_direction(stick, x, y)
        local nx, ny
        if type(Profile.NormalizeStickSemantic) == "function" then
            nx, ny = Profile.NormalizeStickSemantic(stick, x, y, self.profile)
        else
            nx, ny = Profile.NormalizeStick(stick, x, y, self.profile)
            if tostring(stick):lower() == "right" then ny = -(tonumber(ny) or 0.0) end
        end
        return direction(nx, ny, self.profile)
    end

    local function normalized_pair(stick, x, y)
        if type(Profile.NormalizeStickSemantic) == "function" then
            return Profile.NormalizeStickSemantic(stick, x, y, self.profile)
        end
        local nx, ny = Profile.NormalizeStick(stick, x, y, self.profile)
        if tostring(stick):lower() == "right" then ny = -(tonumber(ny) or 0.0) end
        return nx, ny
    end

    local function apply_profile(value, status)
        local ok, result = Profile.Save(value)
        if ok then
            self.profile = type(result) == "table" and result or Profile.Current()
            self.reset_armed = false
            set_status(status or "Shared controller settings saved.")
            local sync_ok, sync_detail = call("profile_changed", self.profile, tostring(status or "saved"))
            if sync_ok == false then
                call("diag", "controller.profile", { status = "sync-deferred", error = tostring(sync_detail or "shared revision unavailable") })
            end
            call("diag", "controller.profile", {
                status = "saved", calibrated = self.profile.calibrated,
                activation = self.profile.stick_activation, release = self.profile.stick_release,
                neutral = self.profile.stick_neutral, margin = self.profile.dominance_margin,
                neutralTicks = self.profile.neutral_ticks,
                triggerActivation = self.profile.trigger_activation, triggerRelease = self.profile.trigger_release,
                neutralNoise = self.profile.neutral_noise, weakestOnset = self.profile.weakest_onset,
                centerLX = self.profile.center_lx, centerLY = self.profile.center_ly,
                centerRX = self.profile.center_rx, centerRY = self.profile.center_ry,
                minLX = self.profile.min_lx, maxLX = self.profile.max_lx,
                minLY = self.profile.min_ly, maxLY = self.profile.max_ly,
                minRX = self.profile.min_rx, maxRX = self.profile.max_rx,
                minRY = self.profile.min_ry, maxRY = self.profile.max_ry,
            })
            return true
        end
        set_status("Controller settings could not be saved; previous profile kept.")
        call("diag", "controller.profile", { status = "save-failed", error = tostring(result) })
        return false
    end

    local function sampling(active)
        if type(set_capture_request) ~= "function" then return false end
        local ok, result, detail = pcall(set_capture_request, "controller-sampling", active == true)
        local accepted = ok and result == true
        self.sampling = active == true and accepted
        if active ~= true then self.sampling = false end
        call("diag", "controller.sampling", { status = accepted and (active and "started" or "stopped") or "unavailable", detail = tostring(ok and detail or result) })
        return accepted
    end

    local function refresh_sample()
        local left, left_err = sample_pair(read_axis, "Gamepad_LeftX", "Gamepad_LeftY")
        local right, right_err = sample_pair(read_axis, "Gamepad_RightX", "Gamepad_RightY")
        if left == nil or right == nil then
            return false, tostring(left_err or right_err or "axis-unavailable")
        end
        local lt = select(1, read_axis("Gamepad_LeftTriggerAxis"))
        local rt = select(1, read_axis("Gamepad_RightTriggerAxis"))
        local buttons = {}
        if type(read_key) == "function" then
            for _, key in ipairs(BUTTON_KEYS) do
                local down, _, ready = read_key(key)
                if ready ~= false and down == true then buttons[#buttons + 1] = BUTTON_LABELS[key] or key end
            end
        end
        self.sample = {
            lx = left.x, ly = left.y, rx = right.x, ry = right.y,
            lt = tonumber(lt) or 0.0, rt = tonumber(rt) or 0.0,
            buttons = #buttons > 0 and table.concat(buttons, ", ") or "None",
            left_frame = left.frame, right_frame = right.frame,
        }
        return true
    end

    function self.Active() return self.active == true end
    function self.Mode() return tostring(self.mode or "settings") end
    function self.SamplingActive() return self.active == true and self.sampling == true
        and (self.mode == "calibration" or self.mode == "test") end

    function self.Open()
        if self.active then return true end
        self.profile = select(1, Profile.Reload()) or Profile.Current()
        self.parent_selected = math.max(1, math.floor(tonumber(call("get_selected")) or 1))
        self.selected = 1
        self.active, self.mode, self.reset_armed = true, "settings", false
        self.sample_signature, self.last_render_poll, self.poll_count = "", 0, 0
        call("set_selected", 1)
        call("apply_window_profile", "browser")
        set_status(self.profile.calibrated and "Shared ModUI controller profile loaded from calibration." or "Shared ModUI controller profile is using defaults/manual values.")
        call("diag", "controller.settings", { status = "opened", storage = "shared-profile", calibrated = self.profile.calibrated })
        call("redraw")
        return true
    end

    function self.Back(reason)
        if not self.active then return false end
        if self.mode == "calibration" or self.mode == "test" then
            sampling(false)
            self.mode = "settings"
            self.calibration = nil
            self.selected = math.max(1, math.min(tonumber(self.subview_parent_selected) or 1, #SETTING_ROWS))
            call("set_selected", self.selected)
            set_status("Returned to shared Controller Settings.")
            call("diag", "controller.settings", { status = "subview-closed", reason = tostring(reason or "back") })
            call("redraw")
            return true
        end
        sampling(false)
        self.active = false
        self.mode = "settings"
        self.calibration = nil
        self.reset_armed = false
        call("set_selected", self.parent_selected)
        call("apply_window_profile", "main")
        set_status("")
        call("diag", "controller.settings", { status = "closed", reason = tostring(reason or "back") })
        call("redraw")
        return true
    end

    function self.Shutdown(reason)
        if not self.active then return false end
        sampling(false)
        self.active = false
        self.mode = "settings"
        self.calibration = nil
        self.reset_armed = false
        self.sample_signature = ""
        call("diag", "controller.settings", { status = "shutdown", reason = tostring(reason or "session-close") })
        return true
    end

    function self.Rows()
        if self.mode == "calibration" then
            return {
                { key = "cal_step", label = "Calibration Step", kind = "display" },
                { key = "cal_left", label = "Left Stick", kind = "display" },
                { key = "cal_left_dir", label = "Left Direction", kind = "display" },
                { key = "cal_right", label = "Right Stick", kind = "display" },
                { key = "cal_right_dir", label = "Right Direction", kind = "display" },
                { key = "cal_noise", label = "Center Noise", kind = "display" },
                { key = "cal_onset", label = "Weakest Onset", kind = "display" },
                { key = "cal_status", label = "Instruction", kind = "display" },
            }
        elseif self.mode == "test" then
            return {
                { key = "test_left", label = "Left Stick Raw", kind = "display" },
                { key = "test_left_norm", label = "Left Stick Normalized", kind = "display" },
                { key = "test_left_dir", label = "Left Direction", kind = "display" },
                { key = "test_right", label = "Right Stick Raw", kind = "display" },
                { key = "test_right_norm", label = "Right Stick Normalized", kind = "display" },
                { key = "test_right_dir", label = "Right Direction", kind = "display" },
                { key = "test_lt", label = "L2 / Left Trigger", kind = "display" },
                { key = "test_rt", label = "R2 / Right Trigger", kind = "display" },
                { key = "test_buttons", label = "Buttons", kind = "display" },
                { key = "test_profile", label = "Profile", kind = "display" },
            }
        end
        return SETTING_ROWS
    end

    function self.Move(delta)
        if not self.active then return false end
        if self.mode ~= "settings" then return true end
        local rows = self.Rows()
        self.reset_armed = false
        self.selected = ((self.selected - 1 + (tonumber(delta) or 0)) % #rows) + 1
        call("set_selected", self.selected)
        set_status("")
        call("redraw")
        return true
    end

    function self.Change(delta)
        if not self.active or self.mode ~= "settings" then return false end
        local row = SETTING_ROWS[self.selected]
        if row == nil or row.kind == "action" then return false end
        delta = tonumber(delta) or 0
        local next_profile = Profile.Current()
        if row.kind == "integer" then
            next_profile[row.key] = (tonumber(next_profile[row.key]) or 3) + (delta < 0 and -1 or 1)
        else
            local current = tonumber(next_profile[row.key]) or 0
            local step = tonumber(row.step) or 0.01
            if tonumber(row.fine_step) ~= nil and (current < 0.010 or (current <= 0.010 and delta < 0)) then
                step = tonumber(row.fine_step)
            end
            local proposed = round(current + (delta < 0 and -step or step), 3)
            next_profile[row.key] = proposed
            -- Direct user edits update the remembered preference. Profile.Sanitize computes
            -- the effective runtime threshold from those preferences, temporarily clamping
            -- dependent values when needed. Because the preference survives that clamp,
            -- raising Activation later restores the user's earlier Release/Deadzone choices.
            local preference_keys = {
                stick_activation = "preferred_stick_activation",
                stick_release = "preferred_stick_release",
                stick_neutral = "preferred_stick_neutral",
                trigger_activation = "preferred_trigger_activation",
                trigger_release = "preferred_trigger_release",
            }
            local preference_key = preference_keys[row.key]
            if preference_key ~= nil then next_profile[preference_key] = proposed end
        end
        next_profile.calibrated = false
        if not apply_profile(next_profile) then return false end
        set_status(row.label .. " set to " .. self.Value(row) .. ".")
        return call("redraw") ~= false
    end

    function self.Activate()
        if not self.active then return false end
        if self.mode ~= "settings" then return true end
        local row = SETTING_ROWS[self.selected]
        if row == nil then return false end
        if row.key == "calibrate" then
            self.subview_parent_selected = self.selected
            self.calibration = calibration_new()
            self.mode = "calibration"
            self.selected = 1
            call("set_selected", 1)
            if not sampling(true) then
                self.mode = "settings"
                self.calibration = nil
                self.selected = self.subview_parent_selected
                call("set_selected", self.selected)
                set_status("Controller calibration could not start because shared controller sampling is unavailable.")
                call("diag", "controller.calibration", { status = "start-failed" })
                call("redraw")
                return false
            end
            set_status("Calibration started. " .. calibration_prompt(self.calibration))
            call("diag", "controller.calibration", { status = "started" })
            call("redraw")
            return true
        elseif row.key == "test" then
            self.subview_parent_selected = self.selected
            self.mode = "test"
            self.selected = 1
            call("set_selected", 1)
            if not sampling(true) then
                self.mode = "settings"
                self.selected = self.subview_parent_selected
                call("set_selected", self.selected)
                set_status("Controller test could not start because shared controller sampling is unavailable.")
                call("diag", "controller.test", { status = "start-failed" })
                call("redraw")
                return false
            end
            set_status("Live controller test active. Move sticks/triggers and press buttons; Back returns.")
            call("diag", "controller.test", { status = "started" })
            call("redraw")
            return true
        elseif row.key == "reset" then
            if not self.reset_armed then
                self.reset_armed = true
                set_status("Reset Controller armed. Confirm again to restore shared defaults; move away or Back to cancel.")
                call("redraw")
                return true
            end
            local ok = apply_profile(Profile.Defaults(), "Shared controller settings restored to defaults.")
            if not ok then set_status("Controller defaults could not be saved; previous profile kept.") end
            call("diag", "controller.profile", { status = ok and "reset" or "reset-failed" })
            call("redraw")
            return ok
        elseif row.kind == "number" or row.kind == "integer" then
            return self.Change(1)
        end
        return false
    end

    function self.Poll()
        if not self.SamplingActive() then return false end
        self.poll_count = math.max(0, math.floor(tonumber(self.poll_count) or 0)) + 1
        local force_redraw = false
        local ok, err = refresh_sample()
        if not ok then
            set_status("Controller sampling unavailable: " .. tostring(err))
            return false
        end

        if self.mode == "calibration" and type(self.calibration) == "table" then
            local transition = calibration_update(self.calibration, self.sample)
            if type(transition) == "table" then
                force_redraw = true
                call("diag", "controller.calibration", {
                    status = transition.status, step = self.calibration.step,
                    label = transition.label, onset = transition.onset,
                })
                if transition.status == "complete" then
                    local weakest = 1.0
                    for _, value in ipairs(self.calibration.onsets or {}) do weakest = math.min(weakest, tonumber(value) or 1.0) end
                    if weakest == 1.0 and #(self.calibration.onsets or {}) == 0 then weakest = self.profile.stick_activation end
                    local centers = self.calibration.centers or {}
                    local extrema = self.calibration.extrema or {}
                    local recommended = Profile.Recommend({
                        neutral_noise = self.calibration.center_max,
                        weakest_onset = weakest,
                        center_lx = centers.lx, center_ly = centers.ly,
                        center_rx = centers.rx, center_ry = centers.ry,
                        min_lx = extrema["Left Stick Left"], max_lx = extrema["Left Stick Right"],
                        min_ly = extrema["Left Stick Down"], max_ly = extrema["Left Stick Up"],
                        min_rx = extrema["Right Stick Left"], max_rx = extrema["Right Stick Right"],
                        min_ry = extrema["Right Stick Up"], max_ry = extrema["Right Stick Down"],
                    }, self.profile)
                    apply_profile(recommended, string.format("Calibration applied: activate %s, release %s, neutral %s, margin %s.", format_setting(recommended.stick_activation), format_setting(recommended.stick_release), format_setting(recommended.stick_neutral), format_setting(recommended.dominance_margin)))
                    sampling(false)
                else
                    set_status(self.calibration.message)
                end
            end
        end

        local signature = table.concat({
            self.mode, format_axis(self.sample.lx), format_axis(self.sample.ly), format_axis(self.sample.rx), format_axis(self.sample.ry),
            format_axis(self.sample.lt), format_axis(self.sample.rt), tostring(self.sample.buttons),
            self.calibration and tostring(self.calibration.step) or "0", self.calibration and tostring(self.calibration.phase) or "",
        }, "|")
        if signature ~= self.sample_signature
            and (force_redraw or (self.poll_count - (tonumber(self.last_render_poll) or 0)) >= 4) then
            self.sample_signature = signature
            self.last_render_poll = self.poll_count
            call("redraw")
            return true
        end
        return false
    end

    function self.Label(row) return tostring(type(row) == "table" and row.label or "") end

    function self.Value(row)
        row = type(row) == "table" and row or {}
        local key = tostring(row.key or "")
        local p = self.profile
        if self.mode == "settings" then
            if key == "stick_activation" then return format_setting(p.stick_activation)
            elseif key == "stick_release" then return format_setting(p.stick_release)
            elseif key == "stick_neutral" then return format_setting(p.stick_neutral)
            elseif key == "dominance_margin" then return format_setting(p.dominance_margin)
            elseif key == "neutral_ticks" then return tostring(p.neutral_ticks)
            elseif key == "trigger_activation" then return string.format("%.2f", p.trigger_activation)
            elseif key == "trigger_release" then return string.format("%.2f", p.trigger_release)
            elseif key == "calibrate" then return p.calibrated and "Recalibrate" or "Start"
            elseif key == "test" then return "Open"
            elseif key == "reset" then return self.reset_armed and "Confirm again" or "Defaults" end
        elseif self.mode == "calibration" then
            local c = self.calibration or calibration_new()
            if key == "cal_step" then
                if c.complete then return tostring(#CALIBRATION_STEPS) .. "/" .. tostring(#CALIBRATION_STEPS) .. "  Complete" end
                return tostring(math.min(c.step, #CALIBRATION_STEPS)) .. "/" .. tostring(#CALIBRATION_STEPS) .. "  " .. tostring((CALIBRATION_STEPS[math.min(c.step, #CALIBRATION_STEPS)] or {}).label or "Complete")
            elseif key == "cal_left" then return "X " .. format_axis(self.sample.lx) .. "  Y " .. format_axis(self.sample.ly)
            elseif key == "cal_left_dir" then return interpreted_direction("left", self.sample.lx, self.sample.ly)
            elseif key == "cal_right" then return "X " .. format_axis(self.sample.rx) .. "  Y " .. format_axis(self.sample.ry)
            elseif key == "cal_right_dir" then return interpreted_direction("right", self.sample.rx, self.sample.ry)
            elseif key == "cal_noise" then return string.format("%.3f", c.center_max or 0)
            elseif key == "cal_onset" then
                local weakest = nil
                for _, value in ipairs(c.onsets or {}) do weakest = weakest == nil and value or math.min(weakest, value) end
                return weakest ~= nil and string.format("%.3f", weakest) or "--"
            elseif key == "cal_status" then return c.complete and "Complete - Back" or tostring(c.message or calibration_prompt(c)) end
        elseif self.mode == "test" then
            if key == "test_left" then return "X " .. format_axis(self.sample.lx) .. "  Y " .. format_axis(self.sample.ly)
            elseif key == "test_left_norm" then local x, y = normalized_pair("left", self.sample.lx, self.sample.ly); return "X " .. format_axis(x) .. "  Y " .. format_axis(y)
            elseif key == "test_left_dir" then return interpreted_direction("left", self.sample.lx, self.sample.ly)
            elseif key == "test_right" then return "X " .. format_axis(self.sample.rx) .. "  Y " .. format_axis(self.sample.ry)
            elseif key == "test_right_norm" then local x, y = normalized_pair("right", self.sample.rx, self.sample.ry); return "X " .. format_axis(x) .. "  Y " .. format_axis(y)
            elseif key == "test_right_dir" then return interpreted_direction("right", self.sample.rx, self.sample.ry)
            elseif key == "test_lt" then return format_axis(self.sample.lt)
            elseif key == "test_rt" then return format_axis(self.sample.rt)
            elseif key == "test_buttons" then return tostring(self.sample.buttons or "None")
            elseif key == "test_profile" then return string.format("%s  A %s / R %s / N %s / M %s", p.calibrated and "Calibrated" or "Default/Manual", format_setting(p.stick_activation), format_setting(p.stick_release), format_setting(p.stick_neutral), format_setting(p.dominance_margin)) end
        end
        return ""
    end

    function self.Description(row)
        row = type(row) == "table" and row or {}
        local key = tostring(row.key or "")
        if self.mode == "calibration" then
            return "Guided shared ModUI calibration. The wizard first measures centered-stick noise, then records Left Stick Up/Down/Left/Right and Right Stick Up/Down/Left/Right. It measures center and usable cardinal range, normalizes later stick capture from those measurements, keeps conservative capture thresholds, and persists the shared profile for every ModUI consumer."
        elseif self.mode == "test" then
            return "Live shared controller test. Raw coherent stick axes, profile-normalized axes, interpreted directions, trigger values and currently pressed controller buttons are displayed from the same ModUI profile every consumer can use."
        end
        local descriptions = {
            stick_activation = "Minimum dominant normalized stick magnitude that counts as a captured cardinal direction. Effective Release/Deadzone always remain at least 0.001 below it. Lowering Activation may temporarily constrain them, but their preferred values are remembered and restore automatically when room returns. Minimum Activation is 0.003; below 0.01 the control adjusts by 0.001.",
            stick_release = "Hysteresis threshold below which an active stick direction is released. Runtime Release always remains below Activation. If Activation temporarily forces this lower, ModUI remembers your preferred Release and restores it when Activation is raised again.",
            stick_neutral = "Shared calibrated stick deadzone. Runtime Deadzone always remains below Release. Safety clamping never destroys your preferred value, so it restores automatically when Release/Activation allow it. Minimum is 0.001; below 0.01 the control adjusts by 0.001.",
            dominance_margin = "How much stronger the dominant axis must be than the orthogonal axis before ModUI calls the movement a cardinal direction instead of ambiguous/diagonal.",
            neutral_ticks = "Number of consecutive neutral capture samples required between cardinal directions. More samples reject spring-back noise but require a slightly longer center pause.",
            trigger_activation = "Trigger-axis magnitude required for a new trigger binding press. Effective Trigger Release is safety-constrained below it without overwriting the user's preferred Release value.",
            trigger_release = "Trigger-axis magnitude used after activation to decide the trigger has been released. A temporary Activation clamp does not permanently change the preferred Release value.",
            calibrate = "Runs the shared ModUI guided controller calibration. Center both sticks, then move fully through the eight cardinal prompts. Results are saved under %LOCALAPPDATA% when available (with a ModUI-folder fallback) and are shared by TTS, Minimap and future ModUI consumers.",
            test = "Opens a live controller monitor similar in purpose to a game controller test screen so you can verify stick direction, raw/normalized values, triggers and buttons immediately.",
            reset = "Restores ModUI controller interpretation to the conservative defaults. Requires a second confirmation.",
        }
        return descriptions[key] or "Shared MortalShell2ModUI controller setting."
    end

    function self.ControlHint(row)
        if self.mode == "calibration" then return "Follow the instruction; return each stick to center between directions. Back / Circle / Esc: cancel calibration." end
        if self.mode == "test" then return "Move sticks/triggers and press controller buttons. Back / Circle / Esc: return to Controller Settings." end
        row = type(row) == "table" and row or {}
        if row.kind == "action" then return "Confirm / Enter / Cross / click value: activate" end
        return "Left / Right: adjust shared value | Confirm: increase | Back: return to mod settings"
    end

    function self.HeaderText() return "MORTAL SHELL 2 MOD UI - CONTROLLER" end
    function self.TabText()
        if self.mode == "calibration" then return "[ CONTROLLER CALIBRATION ]    " .. calibration_prompt(self.calibration or calibration_new()) end
        if self.mode == "test" then return "[ CONTROLLER TEST ]    Live shared input monitor" end
        return "[ CONTROLLER SETTINGS ]    Shared across all MortalShell2ModUI consumers"
    end
    function self.PageText()
        if self.mode == "calibration" then
            local step = self.calibration and math.min(self.calibration.step, #CALIBRATION_STEPS) or 1
            return tostring(step) .. "/" .. tostring(#CALIBRATION_STEPS)
        elseif self.mode == "test" then return "TEST" end
        return self.profile.calibrated and "CAL" or "MAN"
    end

    return self
end

return Settings
