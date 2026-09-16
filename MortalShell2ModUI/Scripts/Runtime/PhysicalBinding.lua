-- MortalShell2ModUI Runtime.PhysicalBinding
-- Shared physical binding evaluator used by both consumer-scoped InputHost features and
-- the standalone ModUI hotkey host. It owns FKey caching, key/axis reads, modifier-side
-- equivalence, chord evaluation, and sequence edge progression. Action semantics remain
-- with the consumer and no callbacks cross Lua-state boundaries.

local M = {}

function M.New(binding, options)
    options = type(options) == "table" and options or {}
    if type(binding) ~= "table" or type(binding.Tokens) ~= "function" or type(binding.IsSequence) ~= "function" then
        return nil, "Runtime.PhysicalBinding requires Input.Binding"
    end
    local unwrap = options.unwrap
    local valid = options.valid
    local FName = options.fname
    local input_time_seconds = options.input_time_seconds or function()
        local ok, value = pcall(function() return os.clock() end)
        if ok and tonumber(value) ~= nil then return tonumber(value), "os.clock" end
        return tonumber(os.time()) or 0, "os.time"
    end
    local diag = options.diag or function() end
    local binding_label = options.binding_label or function(value) return tostring(value or "") end
    local analog_override = options.analog_override
    local analog_policy = options.analog_policy
    local key_cache = options.key_cache or {}
    local sequence_state = options.sequence_state or {}
    local axis_state = options.axis_state or {}

    if type(unwrap) ~= "function" then return nil, "unwrap missing" end
    if type(valid) ~= "function" then return nil, "valid missing" end
    if type(FName) ~= "function" then return nil, "FName missing" end

    local self = {
        key_cache = key_cache,
        sequence_state = sequence_state,
        axis_state = axis_state,
    }

    function self.Reset(kind)
        if kind == nil then
            for key in pairs(sequence_state) do sequence_state[key] = nil end
            for key in pairs(axis_state) do axis_state[key] = nil end
        else
            sequence_state[tostring(kind)] = nil
        end
    end

    function self.FKey(name)
        name = tostring(name or "")
        if name == "" then return nil end
        if key_cache[name] ~= nil then return key_cache[name] end
        local key = { KeyName = FName(name) }
        key_cache[name] = key
        return key
    end

    function self.KeyDown(controller, key_name)
        controller = unwrap(controller)
        if not valid(controller) or controller["IsInputKeyDown"] == nil then
            return nil, "controller/input method unavailable"
        end
        local key = self.FKey(key_name)
        if key == nil then return nil, "key unavailable" end
        local ok, value = pcall(function() return unwrap(controller:IsInputKeyDown(key)) end)
        if not ok then return nil, tostring(value) end
        return value == true, nil
    end

    function self.AnalogValue(controller, key_name)
        controller = unwrap(controller)
        if not valid(controller) or controller["GetInputAnalogKeyState"] == nil then
            return nil, "analog input method unavailable"
        end
        local key = self.FKey(key_name)
        if key == nil then return nil, "analog key unavailable" end
        local ok, value = pcall(function() return tonumber(unwrap(controller:GetInputAnalogKeyState(key))) end)
        if not ok or value == nil then return nil, tostring(value) end
        return value, nil
    end

    function self.ModifierEquivalentTokens(token)
        token = tostring(token or "")
        if token == "LeftControl" or token == "RightControl" then return "LeftControl", "RightControl" end
        if token == "LeftShift" or token == "RightShift" then return "LeftShift", "RightShift" end
        if token == "LeftAlt" or token == "RightAlt" then return "LeftAlt", "RightAlt" end
        return nil, nil
    end

    function self.TokenActive(controller, token, modifier_sides_equivalent)
        token = tostring(token or "")
        if modifier_sides_equivalent == true then
            local left_token, right_token = self.ModifierEquivalentTokens(token)
            if left_token ~= nil then
                local left_down, left_err = self.KeyDown(controller, left_token)
                if left_down == nil then return nil, left_err end
                if left_down then return true, nil end
                local right_down, right_err = self.KeyDown(controller, right_token)
                if right_down == nil then return nil, right_err end
                return right_down == true, nil
            end
        end
        local axis_key, direction = token:match("^axis:([^:]+):([^:]+)$")
        if axis_key ~= nil then
            local value, err
            if type(analog_override) == "function" then
                local handled
                handled, value, err = analog_override(controller, axis_key)
                if handled ~= true then value, err = self.AnalogValue(controller, axis_key) end
            else
                value, err = self.AnalogValue(controller, axis_key)
            end
            if value == nil then return nil, err end
            local was_active = axis_state[token] == true
            local active
            if type(analog_policy) == "function" then
                local ok_policy, policy_active, policy_err = pcall(
                    analog_policy, axis_key, direction, value, was_active, token)
                if ok_policy and policy_active ~= nil then
                    active = policy_active == true
                elseif not ok_policy then
                    return nil, tostring(policy_active)
                elseif policy_err ~= nil then
                    return nil, tostring(policy_err)
                end
            end
            if active == nil then
                active = direction == "neg" and value <= -0.60 or value >= 0.60
            end
            axis_state[token] = active
            return active, nil
        end
        return self.KeyDown(controller, token)
    end

    function self.IsDown(controller, value, modifier_sides_equivalent)
        if binding.IsSequence(value) then return false, nil end
        local tokens = binding.Tokens(value)
        if #tokens == 0 then return false, nil end
        for _, token in ipairs(tokens) do
            local down, err = self.TokenActive(controller, token, modifier_sides_equivalent)
            if down == nil then return nil, err end
            if not down then return false, nil end
        end
        return true, nil
    end

    function self.SequenceTriggered(controller, value, kind, modifier_sides_equivalent)
        if not binding.IsSequence(value) then return false, nil end
        local tokens = binding.Tokens(value)
        if #tokens == 0 then return false, nil end

        kind = tostring(kind or "binding")
        local state = sequence_state[kind]
        if type(state) ~= "table" or tostring(state.value) ~= tostring(value) then
            state = { value = tostring(value), index = 1, down = {}, last_clock = nil }
            sequence_state[kind] = state
        end

        local unique, unique_order = {}, {}
        for _, token in ipairs(tokens) do
            if not unique[token] then
                unique[token] = true
                unique_order[#unique_order + 1] = token
            end
        end

        local current, rising = {}, {}
        for _, token in ipairs(unique_order) do
            local down, err = self.TokenActive(controller, token, modifier_sides_equivalent)
            if down == nil then return nil, err end
            current[token] = down == true
            if current[token] and state.down[token] ~= true then rising[token] = true end
        end

        local now, clock_source = input_time_seconds()
        now = tonumber(now)
        clock_source = tostring(clock_source or "unknown")
        if state.clock_source ~= nil and state.clock_source ~= clock_source then
            state.index = 1
            state.last_clock = nil
        end
        state.clock_source = clock_source
        if now ~= nil and state.last_clock ~= nil and state.index > 1 and (now - state.last_clock) > 1.50 then
            diag("input.openSequence", {
                status = "timeout-reset", kind = kind, bind = tostring(value),
                elapsedMs = math.floor(((now - state.last_clock) * 1000.0) + 0.5), clock = clock_source,
            })
            state.index = 1
            state.last_clock = nil
        end

        local consumed_any = false
        while state.index <= #tokens and rising[tokens[state.index]] == true do
            rising[tokens[state.index]] = nil
            state.index = state.index + 1
            state.last_clock = now
            consumed_any = true
        end

        local unexpected = false
        for _ in pairs(rising) do unexpected = true break end
        if unexpected then
            state.index = 1
            if rising[tokens[1]] == true then
                state.index = 2
                state.last_clock = now
            end
        end
        state.down = current

        if state.index > #tokens then
            state.index = 1
            state.last_clock = nil
            diag("input.openSequence", {
                status = "completed", kind = kind, bind = tostring(value),
                label = binding_label(value), steps = #tokens,
            })
            return true, nil
        end
        if consumed_any then
            diag("input.openSequence", {
                status = "progress", kind = kind, bind = tostring(value),
                nextStep = state.index, steps = #tokens,
            })
        end
        return false, nil
    end

    return self
end

return M
