-- MortalShell2TTS Helper.Runtime
-- Bounded helper heartbeat/restart and Windows PowerShell launcher orchestration.
-- Heartbeat parsing remains in Helper.Heartbeat; speech IPC and synthesis remain outside.

local Runtime = {}

function Runtime.New(options)
    options = type(options) == "table" and options or {}
    local perf = type(options.perf) == "table" and options.perf
        or { Begin = function() return nil end, End = function() end }
    options = type(options) == "table" and options or {}
    local version = tostring(options.version or "")
    local helper_path = assert(options.helper_path, "Helper.Runtime requires helper_path")
    local heartbeat_path = assert(options.heartbeat_path, "Helper.Runtime requires heartbeat_path")
    local heartbeat = assert(options.heartbeat, "Helper.Runtime requires heartbeat parser")
    local read_file = assert(options.read_file, "Helper.Runtime requires read_file")
    local file_exists = assert(options.file_exists, "Helper.Runtime requires file_exists")
    local log = type(options.log) == "function" and options.log or function() end
    local diag = type(options.diag) == "function" and options.diag or function() end
    local max_age = tonumber(options.max_age_seconds) or 8
    local cooldown = tonumber(options.restart_cooldown_seconds) or 5
    local execute = type(options.execute) == "function" and options.execute or os.execute
    local getenv = type(options.getenv) == "function" and options.getenv or os.getenv
    local epoch = type(options.epoch) == "function" and options.epoch or os.time

    if type(heartbeat.Evaluate) ~= "function" then return nil, "Helper.Heartbeat API missing" end

    local last_launch_attempt_epoch = 0
    local last_launcher = nil
    local last_launch_confirmed = false
    local last_heartbeat_identity = nil
    local last_heartbeat_info = nil
    local last_heartbeat_state = nil
    local deferred_version_mismatch_identity = nil
    local self = {}

    function self.HeartbeatFresh(now_epoch)
        local content = select(1, read_file(heartbeat_path, 1024))
        return heartbeat.Evaluate(content, version, tonumber(now_epoch) or epoch(), max_age)
    end

    local start_body
    -- Launching the helper spawns a PowerShell process: the single most expensive thing
    -- this mod does, so it is its own section even though it is rare.
    function self.Start(reason, prefer_path_fallback)
        local token = perf.Begin()
        local result = start_body(reason, prefer_path_fallback)
        perf.End("helper.start", token)
        return result
    end

    start_body = function(reason, prefer_path_fallback)
        if not file_exists(helper_path) then
            log("TTS helper was not found: " .. tostring(helper_path))
            return false
        end
        last_launch_attempt_epoch = epoch()

        local function request_launch(command, launcher)
            local ok, launched, exit_kind, exit_code = pcall(function() return execute(command) end)
            if ok and launched ~= nil and launched ~= false then
                last_launcher, last_launch_confirmed = tostring(launcher), false
                diag("helper.launch", {status="requested", launcher=tostring(launcher), reason=tostring(reason or "startup")})
                log("TTS helper launch requested launcher=" .. tostring(launcher) .. " reason=" .. tostring(reason or "startup") .. " (settings UI v" .. version .. ")")
                return true
            end
            diag("helper.launch", {status="failed", launcher=tostring(launcher), reason=tostring(reason or "startup"), exitKind=tostring(exit_kind or "unknown"), exitCode=tostring(exit_code or "unknown")})
            log("TTS helper launch attempt failed launcher=" .. tostring(launcher) .. " reason=" .. tostring(reason or "startup") .. " result=" .. tostring(launched) .. " exit=" .. tostring(exit_kind) .. "/" .. tostring(exit_code))
            return false
        end

        local system_root = tostring(getenv("SystemRoot") or getenv("WINDIR") or "")
        local canonical_exe = system_root ~= "" and (system_root .. "\\System32\\WindowsPowerShell\\v1.0\\powershell.exe") or ""
        local canonical_available = canonical_exe ~= "" and file_exists(canonical_exe)
        local canonical_command = canonical_available
            and ('cmd.exe /d /c start "" /b "' .. canonical_exe .. '" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "' .. helper_path .. '"')
            or ('cmd.exe /d /c start "" /b "%SystemRoot%\\System32\\WindowsPowerShell\\v1.0\\powershell.exe" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "' .. helper_path .. '"')
        local fallback_command = 'cmd.exe /d /c start "" /b powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "' .. helper_path .. '"'

        if prefer_path_fallback == true then
            log("previous canonical helper launch did not produce a fresh heartbeat; trying PATH fallback first")
            if request_launch(fallback_command, "path-fallback-recovery") then return true end
            if canonical_available or system_root ~= "" then
                log("PATH fallback launch request failed; retrying canonical Windows PowerShell")
                return request_launch(canonical_command, "canonical-recovery")
            end
            return false
        end

        if canonical_available or system_root ~= "" then
            if request_launch(canonical_command, canonical_available and "canonical" or "canonical-expanded") then return true end
            log("canonical Windows PowerShell launch request failed; trying PATH fallback")
        else
            log("SystemRoot/WINDIR unavailable; trying Windows PowerShell from PATH")
        end
        return request_launch(fallback_command, "path-fallback")
    end

    function self.EnsureRunning(reason)
        local now_epoch = epoch()
        local fresh, age, info = self.HeartbeatFresh(now_epoch)
        if fresh then
            last_launch_confirmed = true
            local identity = info ~= nil and tostring(info.identity or "") or ""
            if identity ~= "" and identity ~= last_heartbeat_identity then
                local previous = last_heartbeat_info
                local recovered = previous ~= nil and tostring(previous.identity or "") ~= "" and tostring(previous.identity) ~= identity
                local same_game = recovered and tonumber(previous.gamePid) ~= nil and tonumber(previous.gamePid) > 0 and tonumber(previous.gamePid) == tonumber(info.gamePid)
                diag("helper.heartbeat", {action=recovered and "identity-changed" or "fresh", helperVersion=tostring(info.version or "unknown"), helperPid=tonumber(info.pid) or 0, helperStartFileTimeUtc=tonumber(info.start) or 0, gamePid=tonumber(info.gamePid) or 0, bindingMode=tostring(info.bindingMode or "unknown"), sameGamePid=same_game == true})
                if recovered then diag("helper.recovery", {status="observed", previousHelperPid=tonumber(previous.pid) or 0, helperPid=tonumber(info.pid) or 0, gamePid=tonumber(info.gamePid) or 0, sameGamePid=same_game == true}) end
                last_heartbeat_identity, last_heartbeat_info = identity, info
            end
            last_heartbeat_state = "fresh"
            return true
        end

        local stale_state = tostring(age or "missing")
        if last_heartbeat_state ~= stale_state then
            diag("helper.heartbeat", {action="stale", reason=stale_state, helperVersion=info ~= nil and tostring(info.version or "unknown") or "unknown", helperPid=info ~= nil and (tonumber(info.pid) or 0) or 0, gamePid=info ~= nil and (tonumber(info.gamePid) or 0) or 0})
            last_heartbeat_state = stale_state
        end

        -- A recent heartbeat from a still-live helper whose only fault is a version
        -- mismatch cannot be replaced by launching another helper: the existing
        -- per-game mutex intentionally rejects the newcomer as a duplicate. Older
        -- builds retried that doomed launch every cooldown, which could flash a
        -- transient cmd/PowerShell window on repeated Settings opens. Treat the
        -- existing helper as temporarily usable and defer replacement until the next
        -- game launch. Truly missing/stale/invalid heartbeats still use normal recovery.
        if stale_state:find("^version%-mismatch:") ~= nil and info ~= nil then
            local heartbeat_epoch = tonumber(info.epoch)
            local heartbeat_age = heartbeat_epoch ~= nil and (now_epoch - heartbeat_epoch) or nil
            local live_mismatch = heartbeat_age ~= nil and heartbeat_age >= -300 and heartbeat_age <= max_age
            if live_mismatch then
                local identity = tostring(info.identity or (tostring(info.version or "unknown") .. ":" .. tostring(info.pid or 0) .. ":" .. tostring(info.start or 0)))
                if deferred_version_mismatch_identity ~= identity then
                    deferred_version_mismatch_identity = identity
                    diag("helper.recovery", {
                        status="deferred-live-version-mismatch", helperVersion=tostring(info.version or "unknown"),
                        helperPid=tonumber(info.pid) or 0, gamePid=tonumber(info.gamePid) or 0, ageSeconds=heartbeat_age,
                    })
                    log("TTS helper heartbeat " .. stale_state .. " is current/live; deferring replacement until next game launch to avoid duplicate-helper recovery churn")
                end
                return true
            end
        else
            deferred_version_mismatch_identity = nil
        end

        if (now_epoch - last_launch_attempt_epoch) < cooldown then return false end
        local prefer_path = last_launcher ~= nil and tostring(last_launcher):find("canonical", 1, true) ~= nil and last_launch_confirmed ~= true
        log("TTS helper heartbeat " .. stale_state .. "; requesting bounded restart reason=" .. tostring(reason or "command") .. " preferPathFallback=" .. tostring(prefer_path))
        return self.Start("heartbeat-recovery:" .. tostring(reason or "command"), prefer_path)
    end

    return self
end

return Runtime
