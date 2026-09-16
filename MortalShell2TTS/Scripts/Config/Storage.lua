-- MortalShell2TTS bounded file/config publication helpers.
-- Policy/state ownership remains in main.lua; this module owns the exact filesystem
-- mechanics used by config and IPC publication.

local Storage = {}

local function emit(log_fn, message)
    if type(log_fn) == "function" then
        log_fn(message)
    end
end

function Storage.Write(path, value, log_fn)
    local file, err = io.open(path, "wb")
    if file == nil then
        emit(log_fn, "unable to write " .. tostring(path) .. ": " .. tostring(err))
        return false
    end
    file:write(value or "")
    file:close()
    return true
end

function Storage.WriteAtomic(path, value, log_fn)
    local temp_path = tostring(path) .. ".tmp"
    local file, err = io.open(temp_path, "wb")
    if file == nil then
        emit(log_fn, "unable to stage " .. tostring(path) .. ": " .. tostring(err))
        return false
    end

    local ok_write, write_err = pcall(function()
        file:write(value or "")
        file:flush()
    end)
    file:close()
    if not ok_write then
        os.remove(temp_path)
        emit(log_fn, "unable to stage " .. tostring(path) .. ": " .. tostring(write_err))
        return false
    end

    os.remove(path)
    local renamed, rename_err = os.rename(temp_path, path)
    if not renamed then
        os.remove(temp_path)
        emit(log_fn, "unable to publish " .. tostring(path) .. ": " .. tostring(rename_err))
        return false
    end
    return true
end

function Storage.Read(path, max_bytes)
    local file = io.open(path, "rb")
    if file == nil then return nil, "missing" end

    max_bytes = tonumber(max_bytes)
    if max_bytes ~= nil and max_bytes > 0 then
        local ok_size, size = pcall(function()
            local current = file:seek()
            local ending = file:seek("end")
            if current ~= nil then file:seek("set", current) else file:seek("set", 0) end
            return ending
        end)
        size = ok_size and tonumber(size) or nil
        if size ~= nil and size > max_bytes then
            file:close()
            return nil, "oversized"
        end
    end

    local ok_read, value = pcall(function() return file:read("*a") end)
    file:close()
    if not ok_read then return nil, "read-failed" end
    if max_bytes ~= nil and max_bytes > 0 and value ~= nil and #value > max_bytes then
        return nil, "oversized"
    end
    return value, nil
end

function Storage.Exists(path)
    local file = io.open(path, "rb")
    if file == nil then return false end
    file:close()
    return true
end

function Storage.WriteConfigAtomic(path, value, snapshot_valid, log_fn)
    local temp_path = tostring(path) .. ".tmp"
    local backup_path = tostring(path) .. ".bak"
    value = tostring(value or "")

    if type(snapshot_valid) == "function" then
        local valid, reason = snapshot_valid(value)
        if not valid then
            emit(log_fn, "refusing to publish incomplete config snapshot: " .. tostring(reason))
            return false
        end
    end

    local file, err = io.open(temp_path, "wb")
    if file == nil then
        emit(log_fn, "unable to stage config: " .. tostring(err))
        return false
    end
    local ok_write, write_err = pcall(function()
        file:write(value)
        file:flush()
    end)
    file:close()
    if not ok_write then
        os.remove(temp_path)
        emit(log_fn, "unable to stage config: " .. tostring(write_err))
        return false
    end

    local staged = Storage.Read(temp_path)
    if staged ~= value then
        os.remove(temp_path)
        emit(log_fn, "staged config readback did not match generated snapshot; current config left untouched")
        return false
    end
    if type(snapshot_valid) == "function" then
        local staged_valid, staged_reason = snapshot_valid(staged)
        if not staged_valid then
            os.remove(temp_path)
            emit(log_fn, "staged config failed snapshot validation: " .. tostring(staged_reason))
            return false
        end
    end

    local original = Storage.Read(path)
    local had_original = original ~= nil
    local original_valid = false
    if had_original then
        original_valid = true
        if type(snapshot_valid) == "function" then
            original_valid = select(1, snapshot_valid(original))
        end
        if original_valid then
            if not Storage.WriteAtomic(backup_path, original, log_fn) then
                os.remove(temp_path)
                emit(log_fn, "unable to preserve last-known-good config; current config left untouched")
                return false
            end
        else
            emit(log_fn, "current config is not a valid complete snapshot; retaining existing last-known-good backup")
        end
    end

    os.remove(path)
    local renamed, rename_err = os.rename(temp_path, path)
    if not renamed then
        os.remove(temp_path)
        if had_original then
            local restored = Storage.WriteAtomic(path, original, log_fn)
            if not restored then emit(log_fn, "CRITICAL config rollback failed after publish error") end
        end
        emit(log_fn, "unable to publish config: " .. tostring(rename_err))
        return false
    end

    local published = Storage.Read(path)
    local published_ok = published == value
    local published_reason = nil
    if published_ok and type(snapshot_valid) == "function" then
        published_ok, published_reason = snapshot_valid(published)
    end
    if not published_ok then
        emit(log_fn, "published config failed readback verification: " .. tostring(published_reason or "byte-mismatch") .. "; attempting rollback")
        local rollback_ok = false
        if had_original then
            rollback_ok = Storage.WriteAtomic(path, original, log_fn)
        else
            os.remove(path)
            rollback_ok = not Storage.Exists(path)
        end
        if not rollback_ok then emit(log_fn, "CRITICAL config rollback failed after readback verification error") end
        return false
    end

    return true
end

return Storage
