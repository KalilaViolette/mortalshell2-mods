-- MortalShell2TTS Speech.IPC
-- Pure file/sequence publisher for helper commands. No Unreal, helper-process,
-- queue, reader, synthesis, UI, or input ownership lives in this module.

local M = {}

function M.New(options)
    options = type(options) == "table" and options or {}
    local payload_path = tostring(options.payload_path or "")
    local sequence_path = tostring(options.sequence_path or "")
    local max_payload_bytes = math.max(1, tonumber(options.max_payload_bytes) or (512 * 1024))
    local read_file = options.read_file
    local write_file_atomic = options.write_file_atomic
    local trim = options.trim or function(value) return tostring(value or ""):match("^%s*(.-)%s*$") end
    local log = options.log or function() end
    local ensure_helper_running = options.ensure_helper_running

    if payload_path == "" or sequence_path == "" then return nil, "missing-path" end
    if type(read_file) ~= "function" then return nil, "missing-read-file" end
    if type(write_file_atomic) ~= "function" then return nil, "missing-write-file-atomic" end

    local sequence = 0
    local content = select(1, read_file(sequence_path, 4096))
    local existing = tonumber(trim(content or ""))
    if existing ~= nil and existing >= 0 then sequence = math.floor(existing) end

    local runtime = {}

    function runtime.Command(command, text)
        command = tostring(command or "STOP")
        -- STOP intentionally remains valid when the helper is absent. Commands that
        -- require a live helper delegate policy back to the consumer before publish.
        if command ~= "STOP" and type(ensure_helper_running) == "function" then
            ensure_helper_running(command)
        end

        local payload = command .. "\n" .. tostring(text or "")
        if #payload > max_payload_bytes then
            log("refusing oversized TTS IPC command=" .. command .. " bytes=" .. tostring(#payload) .. " limit=" .. tostring(max_payload_bytes))
            return false
        end
        if not write_file_atomic(payload_path, payload) then return false end

        sequence = sequence + 1
        if not write_file_atomic(sequence_path, tostring(sequence)) then return false end
        return true
    end

    function runtime.Sequence()
        return sequence
    end

    return runtime, nil
end

return M
