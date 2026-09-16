-- MortalShell2TTS VoiceBrowser.Catalog
-- Pure Voice Browser catalog filtering/sorting/paging/search transforms. Runtime
-- voice refresh, favorites persistence, selection commit, preview, input and UI remain
-- owned by MortalShell2TTS.

local Catalog = {}

local function trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$")
end

function Catalog.Rebuild(voices, state, favorite_set, preserve_value, selected)
    voices = type(voices) == "table" and voices or {}
    state = type(state) == "table" and state or {}
    favorite_set = type(favorite_set) == "table" and favorite_set or {}

    local query = trim(state.query):lower()
    local gender = tostring(state.gender or "All"):lower()
    local filtered = {}
    for _, voice in ipairs(voices) do
        local voice_gender = tostring(voice.gender or "")
        local gender_ok = gender == "all" or voice_gender:lower() == gender
        local haystack = (tostring(voice.label or "") .. " " .. tostring(voice.value or "") .. " " .. tostring(voice.locale or "") .. " " .. voice_gender):lower()
        if gender_ok and (query == "" or haystack:find(query, 1, true) ~= nil) then
            filtered[#filtered + 1] = voice
        end
    end

    table.sort(filtered, function(a, b)
        local af = favorite_set[tostring(a.value or ""):lower()] ~= nil and 0 or 1
        local bf = favorite_set[tostring(b.value or ""):lower()] ~= nil and 0 or 1
        if af ~= bf then return af < bf end
        return tostring(a.label or a.value):lower() < tostring(b.label or b.value):lower()
    end)

    local wanted = tostring(preserve_value or "")
    local wanted_index = nil
    if wanted ~= "" then
        for index, voice in ipairs(filtered) do
            if tostring(voice.value):lower() == wanted:lower() then
                wanted_index = index
                break
            end
        end
    end

    if wanted_index == nil then
        wanted_index = math.min(#filtered, math.max(1, tonumber(state.offset or 1) + tonumber(selected or 1) - 1))
    end

    if #filtered == 0 then
        return filtered, 1, 1
    end

    local page = math.max(1, tonumber(state.page_size) or 7)
    local offset = math.floor((wanted_index - 1) / page) * page + 1
    return filtered, offset, wanted_index - offset + 1
end

function Catalog.Rows(filtered, offset, page_size)
    filtered = type(filtered) == "table" and filtered or {}
    if #filtered == 0 then
        return { { key = "voice_browser_empty", label = "No voices match", kind = "voice_browser_empty" } }
    end

    offset = math.max(1, tonumber(offset) or 1)
    page_size = math.max(1, tonumber(page_size) or 7)
    local rows = {}
    local last = math.min(#filtered, offset + page_size - 1)
    for index = offset, last do
        local voice = filtered[index]
        rows[#rows + 1] = {
            key = "voice_browser",
            label = tostring(voice.label or voice.value),
            kind = "voice_browser",
            voice = voice,
            absolute_index = index,
        }
    end
    return rows
end

function Catalog.CycleGender(genders, current, delta)
    genders = type(genders) == "table" and genders or {}
    if #genders == 0 then return tostring(current or "All") end
    local index = 1
    for i, value in ipairs(genders) do
        if value == current then
            index = i
            break
        end
    end
    index = index + (tonumber(delta) ~= nil and tonumber(delta) < 0 and -1 or 1)
    if index < 1 then index = #genders end
    if index > #genders then index = 1 end
    return genders[index]
end

function Catalog.EditQuery(query, text)
    query = tostring(query or "")
    text = tostring(text or "")
    if text == "<BACKSPACE>" then
        return query:sub(1, math.max(0, #query - 1))
    elseif text == "<CLEAR>" then
        return ""
    end
    return query .. text
end

return Catalog
