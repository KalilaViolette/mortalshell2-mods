-- MortalShell2TTS Runtime.Diagnostics
-- Owns the bounded/sanitized UE4SS diagnostic stream and repeat-session compaction.
-- Consumer code retains event semantics and decides what to report.

local M = {}

local function lua_pattern_escape(value)
    return (tostring(value or ""):gsub("([^%w])", "%%%1"))
end

local function diagnostic_value(value)
    if value == nil then return "<nil>" end
    local text = tostring(value)
    text = text:gsub("\r", "\\r"):gsub("\n", "\\n"):gsub("\t", "\\t")
    return text
end

function M.New(options)
    options = type(options) == "table" and options or {}

    local mod_name = tostring(options.mod_name or "MortalShell2TTS")
    local mod_dir = tostring(options.mod_dir or "")
    local print_fn = type(options.print_fn) == "function" and options.print_fn or print
    -- v0.9.262 (user): routine DIAG events are gated by the Debug Logging setting.
    -- `debug_enabled()` returns nil before the config has loaded (everything logs, so
    -- startup evidence is never lost), then the user's choice. Release-evidence and
    -- abnormal events ignore the gate.
    local debug_enabled = type(options.debug_enabled) == "function" and options.debug_enabled
        or function() return nil end
    local sequence = 0
    local session = 0

    local compact_repeat_log_prefixes = {
        "visual settings shell death policy",
        "visual reader input listener forced",
        "visual settings shell retired stage=post-construct",
        "native UI shared mapping preserved",
        "modal input acquired",
        "settings UI opened",
        "native modal isolation acquired",
        "native controller route ",
        "native AcceptedInputs exact verification passed",
        "native input hook armed ",
        "native input bridge enabled ",
        "controller menu chord fired:",
        "close quarantine armed ",
        "native input bridge bindings released",
        "native UI shared mapping left untouched on close",
        "visual settings shell retired stage=close",
        "settings root teardown begin",
        "settings root teardown rootRemove=",
        "modal input released",
        "settings UI closed after close quarantine",
    }

    local release_evidence_events = {
        ["startup.begin"] = true,
        ["session.begin"] = true,
        ["session.ready"] = true,
        ["session.end"] = true,
        ["session.failure"] = true,
        ["voice.browser"] = true,
        ["voice.browser.input"] = true,
        ["renderer.profile"] = true,
        ["renderer.viewport"] = true,
        ["input.bindCapture"] = true,
        ["input.bindCaptureAnalog"] = true,
        ["input.bindCaptureDigital"] = true,
        ["input.bindCaptureHost"] = true,
        ["input.bindConflictScan"] = true,
        ["input.trampoline"] = true,
        ["input.dedupe"] = true,
        ["input.detailsAnalog"] = true,
        ["input.mouse.wheel"] = true,
        ["close.quarantine"] = true,
        ["delay.callback"] = true,
        ["reader.lifecycle"] = true,
        ["config.runtime"] = true,
        ["speech.voiceProfile"] = true,
        ["speech.queueMode"] = true,
        ["speech.duplicateSetting"] = true,
        ["speech.duplicate"] = true,
        ["speech.stop"] = true,
        ["helper.heartbeat"] = true,
        ["helper.recovery"] = true,
        ["helper.launch"] = true,
        ["helper.settingsOpenCheck"] = true,
        ["dependency.modui"] = true,
        ["nativeUI.observer"] = true,
    }

    local function safe_log_text(message)
        local text = tostring(message or "")
        text = text:gsub("[\r\n]+", " ")
        text = text:gsub("(%a:[/\\][Uu][Ss][Ee][Rr][Ss][/\\])([^/\\]+)", function(prefix)
            return prefix .. "<USER>"
        end)
        if mod_dir ~= "" then
            text = text:gsub(lua_pattern_escape(mod_dir), "<MOD_DIR>")
        end
        if #text > 4096 then text = text:sub(1, 4096) .. "...[truncated]" end
        return text
    end

    local function plain_log_should_emit(message)
        local text = tostring(message or "")
        local lower = text:lower()

        if text:find("settings redraw ", 1, true) == 1
            and lower:find("fail", 1, true) == nil
            and lower:find("reject", 1, true) == nil
            and lower:find("error", 1, true) == nil
            and lower:find("ok=false", 1, true) == nil then
            return false
        end

        if session <= 1 then return true end
        if lower:find("fail", 1, true) ~= nil
            or lower:find("error", 1, true) ~= nil
            or lower:find("reject", 1, true) ~= nil
            or lower:find("timeout", 1, true) ~= nil then
            return true
        end

        for _, prefix in ipairs(compact_repeat_log_prefixes) do
            if text:find(prefix, 1, true) == 1 then return false end
        end
        return true
    end

    local function log(message)
        if not plain_log_should_emit(message) then return end
        print_fn(string.format("[%s] %s\n", mod_name, safe_log_text(message)))
    end

    local function diag_fields_abnormal(fields)
        if type(fields) ~= "table" then return false end
        for _, key in ipairs({ "error", "failure", "reasonError" }) do
            local value = fields[key]
            if value ~= nil then
                local text = tostring(value)
                if text ~= "" and text ~= "nil" and text ~= "<nil>" then return true end
            end
        end
        for _, key in ipairs({ "ok", "passed", "success" }) do
            if fields[key] == false then return true end
        end
        local status = tostring(fields.status or ""):lower()
        if status ~= "" then
            for _, token in ipairs({
                "fail", "error", "reject", "invalid", "mismatch", "timeout",
                "unavailable", "blocked", "missing", "corrupt",
            }) do
                if status:find(token, 1, true) ~= nil then return true end
            end
        end
        return false
    end

    local function diag_should_emit(event, fields)
        event = tostring(event or "")

        if event:find("redraw.", 1, true) == 1 then
            return diag_fields_abnormal(fields)
        end

        if event == "admission.state" then
            local blockers = type(fields) == "table" and tostring(fields.blockers or "") or ""
            local stage = type(fields) == "table" and tostring(fields.stage or "") or ""
            local allowed = type(fields) == "table" and fields.allowed or nil
            if blockers:find("CurrentTransitionWidget", 1, true) ~= nil then return true end
            if stage == "pre-open" and allowed == false then return true end
            return diag_fields_abnormal(fields)
        end

        if release_evidence_events[event] then return true end
        if diag_fields_abnormal(fields) then return true end
        local debug = debug_enabled()
        if debug == nil then return session <= 1 end
        return debug == true
    end

    local function diag(event, fields)
        if not diag_should_emit(event, fields) then return end

        sequence = sequence + 1
        local parts = {
            "DIAG",
            "seq=" .. tostring(sequence),
            "session=" .. tostring(session),
            "event=" .. diagnostic_value(event),
        }

        if type(fields) == "table" then
            local keys = {}
            for key in pairs(fields) do keys[#keys + 1] = tostring(key) end
            table.sort(keys)
            for _, key in ipairs(keys) do
                parts[#parts + 1] = key .. "=" .. diagnostic_value(fields[key])
            end
        elseif fields ~= nil then
            parts[#parts + 1] = "value=" .. diagnostic_value(fields)
        end

        log(table.concat(parts, " "))
    end

    local api = {}
    api.Log = log
    api.Diag = diag
    api.Session = function() return session end
    api.Sequence = function() return sequence end
    api.BeginSession = function()
        session = session + 1
        return session
    end
    return api
end

return M
