-- MortalShell2TTS Reader.Runtime
-- Lore-reader discovery plus event-driven narration lifecycle state. Exact UE4SS
-- hook registration, delayed-action scheduling, speech dispatch, UI ownership and
-- native settings-shell lifetime remain consumer-owned/injected.

local Runtime = {}

function Runtime.New(options)
    options = type(options) == "table" and options or {}
    local perf = type(options.perf) == "table" and options.perf
        or { Begin = function() return nil end, End = function() end, Count = function() end }
    options = type(options) == "table" and options or {}
    local unwrap = options.unwrap
    local valid = options.valid
    local object_name = options.object_name
    local widget_text = options.widget_text
    local find_all = options.find_all
    local settings_widget_name = options.settings_widget_name
    local clear_pending_speech = options.clear_pending_speech
    local queue_speech = options.queue_speech
    local process_pending_speech = options.process_pending_speech
    local stop_speech = options.stop_speech
    local log = options.log or function() end
    local diag = options.diag or function() end

    if type(unwrap) ~= "function" then return nil, "unwrap missing" end
    if type(valid) ~= "function" then return nil, "valid missing" end
    if type(object_name) ~= "function" then return nil, "object_name missing" end
    if type(widget_text) ~= "function" then return nil, "widget_text missing" end
    if type(find_all) ~= "function" then return nil, "find_all missing" end
    if type(settings_widget_name) ~= "function" then return nil, "settings_widget_name missing" end
    if type(clear_pending_speech) ~= "function" then return nil, "clear_pending_speech missing" end
    if type(queue_speech) ~= "function" then return nil, "queue_speech missing" end
    if type(process_pending_speech) ~= "function" then return nil, "process_pending_speech missing" end
    if type(stop_speech) ~= "function" then return nil, "stop_speech missing" end

    local reader_open = false
    local last_page = nil
    local last_text = nil
    local cached_reader = nil
    local pending_open_object = nil
    local pending_open_text = nil
    local pending_open_seen = 0

    local self = {}

    local function is_visible(current)
        current = unwrap(current)
        if not valid(current) then return false end

        local ok_viewport, in_viewport = pcall(function() return unwrap(current:IsInViewport()) end)
        if ok_viewport and in_viewport == true then return true end

        local ok_rendered, rendered = pcall(function() return unwrap(current:IsRendered()) end)
        return ok_rendered and rendered == true
    end

    local function reader_field(current, field)
        if not valid(current) then return nil end
        local ok, value = pcall(function() return unwrap(current[field]) end)
        if ok and valid(value) then return value end
        return nil
    end

    local function clear_pending_open()
        pending_open_object = nil
        pending_open_text = nil
        pending_open_seen = 0
    end

    -- Find: one FindAllOf when the cached reader is gone (native.findall counts it).
    function self.Find()
        if valid(cached_reader) and is_visible(cached_reader) then
            return cached_reader
        end

        local token = perf.Begin()
        local ok, values = pcall(find_all, "WBP_ConfirmationPrompt_ReadText_C")
        perf.End("native.findall", token)
        if not ok or values == nil then return nil end

        for _, value in ipairs(values) do
            value = unwrap(value)
            if valid(value) then
                local name = object_name(value)
                local settings_name = settings_widget_name()
                if name ~= settings_name
                    and name:find("/Engine/Transient", 1, true) ~= nil
                    and is_visible(value) then
                    cached_reader = value
                    return value
                end
            end
        end
        return nil
    end

    function self.Read()
        local token = perf.Begin()
        local current = self.Find()
        if not valid(current) then
            cached_reader = nil
            perf.End("reader.read", token)
            return nil
        end

        local page_widget = reader_field(current, "Text_Page_Status")
        local text_widget = reader_field(current, "RTB_ReadText")
        local state = {
            object = object_name(current),
            page = widget_text(page_widget),
            text = widget_text(text_widget),
        }
        perf.End("reader.read", token)
        return state
    end

    -- Retained fail-soft watcher path for compatibility/diagnostics. The normal
    -- runtime remains exact event-driven and does not schedule this permanently.
    local function watch_body()
        local state = self.Read()
        if state == nil then
            clear_pending_open()
            clear_pending_speech()
            if reader_open then
                reader_open = false
                cached_reader = nil
                last_page = nil
                last_text = nil
                stop_speech("reader closed")
                log("reader closed")
            end
            return
        end

        if not reader_open then
            if state.object == pending_open_object and state.text == pending_open_text and tostring(state.text or "") ~= "" then
                pending_open_seen = pending_open_seen + 1
            else
                pending_open_object = state.object
                pending_open_text = state.text
                pending_open_seen = 1
            end
            if pending_open_seen < 2 then return end

            reader_open = true
            last_page = state.page
            last_text = state.text
            clear_pending_open()
            log("reader opened: " .. tostring(state.object))
            queue_speech(state.text, state.page, "reader opened")
            process_pending_speech()
            return
        end

        local page_changed = state.page ~= last_page
        local text_changed = state.text ~= last_text
        if page_changed then
            log("page changed " .. tostring(last_page) .. " -> " .. tostring(state.page))
            last_page = state.page
        end
        if text_changed then
            last_text = state.text
            queue_speech(state.text, state.page, "page changed")
        end
        process_pending_speech()
    end

    local function event_state(current)
        current = unwrap(current)
        if not valid(current) then return nil end

        local name = object_name(current)
        local settings_name = settings_widget_name()
        if settings_name ~= nil and name == settings_name then return nil end

        local page_widget = reader_field(current, "Text_Page_Status")
        local text_widget = reader_field(current, "RTB_ReadText")
        local text = widget_text(text_widget)
        if tostring(text or "") == "" then return nil end

        return {
            object_ref = current,
            object = name,
            page = widget_text(page_widget),
            text = text,
        }
    end

    local function handlecontent_body(current, reason)
        local state = event_state(current)
        if state == nil then return false end

        local previous_object = valid(cached_reader) and object_name(cached_reader) or nil
        local same_reader = reader_open and previous_object == state.object
        local page_changed = same_reader and state.page ~= last_page
        local text_changed = same_reader and state.text ~= last_text
        cached_reader = state.object_ref

        if not same_reader then
            reader_open = true
            last_page = state.page
            last_text = state.text
            clear_pending_open()
            log("reader opened event=" .. tostring(reason) .. ": " .. tostring(state.object))
            diag("reader.lifecycle", { action = "open", reason = tostring(reason or "event"), chars = #tostring(state.text or "") })
            queue_speech(state.text, state.page, "reader opened")
            return true
        end

        if page_changed then
            log("page changed " .. tostring(last_page) .. " -> " .. tostring(state.page) .. " event=" .. tostring(reason))
            last_page = state.page
            diag("reader.lifecycle", { action = "page", reason = tostring(reason or "event"), chars = #tostring(state.text or "") })
        end
        if text_changed then
            last_text = state.text
            queue_speech(state.text, state.page, "page changed")
        end
        return page_changed or text_changed
    end

    local function handleclose_body(current, reason)
        current = unwrap(current)
        if not reader_open then return false end

        local current_name = valid(current) and object_name(current) or nil
        local cached_name = valid(cached_reader) and object_name(cached_reader) or nil
        if current_name ~= nil and cached_name ~= nil and current_name ~= cached_name then return false end
        local settings_name = settings_widget_name()
        if settings_name ~= nil and current_name == settings_name then return false end

        reader_open = false
        cached_reader = nil
        last_page = nil
        last_text = nil
        clear_pending_open()
        clear_pending_speech()
        stop_speech("reader closed")
        log("reader closed event=" .. tostring(reason))
        diag("reader.lifecycle", { action = "close", reason = tostring(reason or "event") })
        return true
    end

    function self.Watch()
        local token = perf.Begin()
        watch_body()
        perf.End("reader.watch", token)
    end

    function self.HandleContent(current, reason)
        local token = perf.Begin()
        local result = handlecontent_body(current, reason)
        perf.End("reader.content", token)
        return result
    end

    function self.HandleClose(current, reason)
        local token = perf.Begin()
        local result = handleclose_body(current, reason)
        perf.End("reader.close", token)
        return result
    end

    function self.IsOpen()
        return reader_open == true
    end

    function self.Snapshot()
        return {
            open = reader_open == true,
            last_page = last_page,
            last_text = last_text,
            cached_object = valid(cached_reader) and object_name(cached_reader) or nil,
        }
    end

    return self, nil
end

return Runtime
