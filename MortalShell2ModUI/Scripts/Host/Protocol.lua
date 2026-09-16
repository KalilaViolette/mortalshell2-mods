-- MortalShell2ModUI Host.Protocol
-- Primitive-only cross-Lua-state protocol definitions for UE4SS ModRef shared variables.
-- No Lua callbacks/tables cross the mod-state boundary. Complex registration metadata is
-- encoded into bounded strings; consumers and the host keep executable behavior local.

local M = {
    VERSION = 1,
    NAMESPACE = "MortalShell2ModUI.Host",
    SLOT_COUNT = 32,
    NAVIGATION_RING_SIZE = 16,
    NATIVE_INPUT_RING_SIZE = 32,
    MENU_SESSION_RING_SIZE = 16,
    MENU_ACTION_RING_SIZE = 32,
    MAX_CONSUMER_ID = 64,
    MAX_FIELD_VALUE = 512,
    MAX_PAYLOAD = 2048,
    HOST_NATIVE_LISTENER_TOKEN = "host",
    -- Performance-logging enable flags, published by each consumer mod from its own
    -- "Log performance" setting (1 = on, 0 = off). The host polls them once a second and
    -- turns its own [PERF] logging on while any is 1. Outside the host namespace on
    -- purpose: a consumer owns its key, the host only reads. See PERFORMANCE_LOGGING.md.
    PERF_KEYS = {
        Minimap = "MortalShell2Perf.Minimap",
        TTS = "MortalShell2Perf.TTS",
    },
}

local function trim(value)
    local s = tostring(value or "")
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function bounded(value, limit)
    local s = tostring(value or "")
    limit = math.max(0, math.floor(tonumber(limit) or 0))
    if #s > limit then s = s:sub(1, limit) end
    return s
end

local function pct_encode(value)
    local s = bounded(value, M.MAX_FIELD_VALUE)
    return (s:gsub("([^%w%._%-])", function(ch)
        return string.format("%%%02X", string.byte(ch))
    end))
end

local function pct_decode(value)
    return (tostring(value or ""):gsub("%%(%x%x)", function(hex)
        local n = tonumber(hex, 16)
        if n == nil then return "" end
        return string.char(n)
    end))
end

function M.NormalizeConsumerId(value)
    local s = bounded(trim(value), M.MAX_CONSUMER_ID)
    if s == "" then return nil, "consumer id is empty" end
    s = s:gsub("[^%w%._%-]", "_")
    if s == "" then return nil, "consumer id is invalid" end
    return s
end

function M.HashConsumerId(value)
    local id, err = M.NormalizeConsumerId(value)
    if id == nil then return nil, err end
    local hash = 0
    for i = 1, #id do
        hash = (hash * 131 + string.byte(id, i)) % 2147483647
    end
    return hash
end

function M.SlotIndex(value, probe)
    local hash, err = M.HashConsumerId(value)
    if hash == nil then return nil, err end
    probe = math.max(0, math.floor(tonumber(probe) or 0))
    return (hash + probe) % M.SLOT_COUNT
end

function M.HostKey(name)
    return M.NAMESPACE .. "." .. tostring(name or "")
end

function M.SlotKey(slot, field)
    slot = math.floor(tonumber(slot) or -1)
    if slot < 0 or slot >= M.SLOT_COUNT then return nil, "slot out of range" end
    return string.format("%s.ConsumerSlot.%02d.%s", M.NAMESPACE, slot, tostring(field or ""))
end

function M.EncodeFields(fields)
    if type(fields) ~= "table" then return nil, "fields must be a table" end
    local keys = {}
    for key in pairs(fields) do
        local k = tostring(key or "")
        if k:match("^[%w_%-]+$") then keys[#keys + 1] = k end
    end
    table.sort(keys)
    local parts = {}
    for _, key in ipairs(keys) do
        local value = fields[key]
        if value ~= nil then
            parts[#parts + 1] = pct_encode(key) .. "=" .. pct_encode(value)
        end
    end
    local payload = table.concat(parts, ";")
    if #payload > M.MAX_PAYLOAD then return nil, "payload too large" end
    return payload
end

function M.DecodeFields(payload)
    payload = tostring(payload or "")
    if payload == "" then return nil, "payload empty" end
    if #payload > M.MAX_PAYLOAD then return nil, "payload too large" end
    local fields = {}
    for token in payload:gmatch("[^;]+") do
        local eq = token:find("=", 1, true)
        if eq ~= nil and eq > 1 then
            local key = pct_decode(token:sub(1, eq - 1))
            local value = pct_decode(token:sub(eq + 1))
            if key:match("^[%w_%-]+$") then fields[key] = value end
        end
    end
    return fields
end

function M.BuildConsumerDescriptor(options)
    options = options or {}
    local id, err = M.NormalizeConsumerId(options.consumer_id)
    if id == nil then return nil, err end
    return M.EncodeFields({
        protocol = M.VERSION,
        consumer = id,
        version = bounded(options.version, 64),
        display = bounded(options.display_name or id, 96),
        settings = options.settings_provider and 1 or 0,
        hotkeys = options.hotkey_provider and 1 or 0,
        openKeyboard = bounded(options.open_keyboard or "", 256),
        openController = bounded(options.open_controller or "", 256),
        modifierSides = options.modifier_sides_equivalent and 1 or 0,
        keyboardNavigation = options.keyboard_navigation and 1 or 0,
        nativeInput = options.native_input and 1 or 0,
        controllerFeed = options.controller_feed ~= false and 1 or 0,
        actions = bounded(options.actions or "", 256),
        pages = bounded(options.pages or "", 256),
        visibleShell = options.visible_shell and 1 or 0,
        presentation = options.presentation_provider and 1 or 0,
        menuOrder = math.floor(tonumber(options.menu_order) or 100),
    })
end

function M.ValidateConsumerDescriptor(payload, expected_consumer)
    local fields, err = M.DecodeFields(payload)
    if fields == nil then return nil, err end
    if tonumber(fields.protocol) ~= M.VERSION then return nil, "protocol mismatch" end
    local id, id_err = M.NormalizeConsumerId(fields.consumer)
    if id == nil then return nil, id_err end
    if expected_consumer ~= nil then
        local expected, expected_err = M.NormalizeConsumerId(expected_consumer)
        if expected == nil then return nil, expected_err end
        if id ~= expected then return nil, "consumer mismatch" end
    end
    fields.consumer = id
    return fields
end


function M.BuildMenuAction(consumer_id, slot, consumer_revision, sequence, generation, action, source, payload)
    local id, err = M.NormalizeConsumerId(consumer_id)
    if id == nil then return nil, err end
    slot = math.floor(tonumber(slot) or -1)
    if slot < 0 or slot >= M.SLOT_COUNT then return nil, "slot out of range" end
    return M.EncodeFields({
        protocol = M.VERSION,
        consumer = id,
        slot = slot,
        revision = math.max(0, math.floor(tonumber(consumer_revision) or 0)),
        sequence = math.max(1, math.floor(tonumber(sequence) or 0)),
        generation = math.max(0, math.floor(tonumber(generation) or 0)),
        action = bounded(action or "", 128),
        source = bounded(source or "", 128),
        payload = bounded(payload or "", 512),
    })
end

function M.ValidateMenuAction(value, consumer_id, expected_slot, expected_revision)
    local fields, err = M.DecodeFields(value)
    if fields == nil then return nil, err end
    if tonumber(fields.protocol) ~= M.VERSION then return nil, "protocol mismatch" end
    local id, id_err = M.NormalizeConsumerId(fields.consumer)
    if id == nil then return nil, id_err end
    local expected, expected_err = M.NormalizeConsumerId(consumer_id)
    if expected == nil then return nil, expected_err end
    if id ~= expected then return nil, "consumer mismatch" end
    local slot = math.floor(tonumber(fields.slot) or -1)
    if slot < 0 or slot >= M.SLOT_COUNT then return nil, "slot invalid" end
    if expected_slot ~= nil and slot ~= math.floor(tonumber(expected_slot) or -1) then return nil, "slot mismatch" end
    local revision = math.max(0, math.floor(tonumber(fields.revision) or 0))
    if expected_revision ~= nil and revision ~= math.max(0, math.floor(tonumber(expected_revision) or 0)) then
        return nil, "revision mismatch"
    end
    return {
        consumer = id,
        slot = slot,
        revision = revision,
        sequence = math.max(1, math.floor(tonumber(fields.sequence) or 0)),
        generation = math.max(0, math.floor(tonumber(fields.generation) or 0)),
        action = tostring(fields.action or ""),
        source = tostring(fields.source or ""),
        payload = tostring(fields.payload or ""),
    }
end

function M.BuildAcknowledgement(consumer_id, slot, host_epoch, consumer_revision)
    local id, err = M.NormalizeConsumerId(consumer_id)
    if id == nil then return nil, err end
    slot = math.floor(tonumber(slot) or -1)
    if slot < 0 or slot >= M.SLOT_COUNT then return nil, "slot out of range" end
    local revision = math.max(0, math.floor(tonumber(consumer_revision) or 0))
    return M.EncodeFields({
        protocol = M.VERSION,
        consumer = id,
        slot = slot,
        revision = revision,
        hostEpoch = bounded(host_epoch, 128),
        status = "registered",
    })
end

function M.ValidateAcknowledgement(payload, consumer_id, expected_slot, expected_revision)
    local fields, err = M.DecodeFields(payload)
    if fields == nil then return nil, err end
    if tonumber(fields.protocol) ~= M.VERSION then return nil, "protocol mismatch" end
    if tostring(fields.status or "") ~= "registered" then return nil, "ack status mismatch" end
    local id, id_err = M.NormalizeConsumerId(fields.consumer)
    if id == nil then return nil, id_err end
    local expected, expected_err = M.NormalizeConsumerId(consumer_id)
    if expected == nil then return nil, expected_err end
    if id ~= expected then return nil, "consumer mismatch" end
    local slot = tonumber(fields.slot)
    if slot == nil or slot < 0 or slot >= M.SLOT_COUNT then return nil, "ack slot invalid" end
    slot = math.floor(slot)
    if expected_slot ~= nil and slot ~= math.floor(tonumber(expected_slot) or -1) then
        return nil, "ack slot mismatch"
    end
    local revision = math.max(0, math.floor(tonumber(fields.revision) or 0))
    if expected_revision ~= nil and revision ~= math.max(0, math.floor(tonumber(expected_revision) or 0)) then
        return nil, "ack revision mismatch"
    end
    fields.consumer = id
    fields.slot = slot
    fields.revision = revision
    return fields
end

local MENU_SESSION_STATES = { opening = true, ready = true, closing = true, closed = true }

function M.BuildMenuSession(consumer_id, slot, consumer_revision, sequence, state, generation, reason)
    local id, err = M.NormalizeConsumerId(consumer_id)
    if id == nil then return nil, err end
    slot = math.floor(tonumber(slot) or -1)
    if slot < 0 or slot >= M.SLOT_COUNT then return nil, "slot out of range" end
    state = bounded(trim(state), 32)
    if MENU_SESSION_STATES[state] ~= true then return nil, "menu session state invalid" end
    return M.EncodeFields({
        protocol = M.VERSION, consumer = id, slot = slot,
        revision = math.max(0, math.floor(tonumber(consumer_revision) or 0)),
        sequence = math.max(0, math.floor(tonumber(sequence) or 0)),
        state = state, generation = math.max(0, math.floor(tonumber(generation) or 0)),
        reason = bounded(reason or "", 160),
    })
end

function M.ValidateMenuSession(payload, consumer_id, expected_slot, expected_revision)
    local fields, err = M.DecodeFields(payload)
    if fields == nil then return nil, err end
    if tonumber(fields.protocol) ~= M.VERSION then return nil, "protocol mismatch" end
    local id, id_err = M.NormalizeConsumerId(fields.consumer)
    if id == nil then return nil, id_err end
    local expected, expected_err = M.NormalizeConsumerId(consumer_id)
    if expected == nil then return nil, expected_err end
    if id ~= expected then return nil, "consumer mismatch" end
    local slot = math.floor(tonumber(fields.slot) or -1)
    if slot < 0 or slot >= M.SLOT_COUNT then return nil, "menu session slot invalid" end
    if expected_slot ~= nil and slot ~= math.floor(tonumber(expected_slot) or -1) then return nil, "menu session slot mismatch" end
    local revision = math.max(0, math.floor(tonumber(fields.revision) or 0))
    if expected_revision ~= nil and revision ~= math.max(0, math.floor(tonumber(expected_revision) or 0)) then
        return nil, "menu session revision mismatch"
    end
    local state = tostring(fields.state or "")
    if MENU_SESSION_STATES[state] ~= true then return nil, "menu session state invalid" end
    fields.consumer = id
    fields.slot = slot
    fields.revision = revision
    fields.sequence = math.max(0, math.floor(tonumber(fields.sequence) or 0))
    fields.generation = math.max(0, math.floor(tonumber(fields.generation) or 0))
    fields.state = state
    fields.reason = tostring(fields.reason or "")
    return fields
end

function M.BuildMenuLease(consumer_id, slot, consumer_revision, sequence, active, generation, reason)
    local id, err = M.NormalizeConsumerId(consumer_id)
    if id == nil then return nil, err end
    slot = math.floor(tonumber(slot) or -1)
    if slot < 0 or slot >= M.SLOT_COUNT then return nil, "slot out of range" end
    return M.EncodeFields({
        protocol = M.VERSION, consumer = id, slot = slot,
        revision = math.max(0, math.floor(tonumber(consumer_revision) or 0)),
        sequence = math.max(0, math.floor(tonumber(sequence) or 0)),
        active = active == true and 1 or 0,
        generation = math.max(0, math.floor(tonumber(generation) or 0)),
        reason = bounded(reason or "", 160),
    })
end

function M.ValidateMenuLease(payload, consumer_id, expected_slot, expected_revision)
    local fields, err = M.DecodeFields(payload)
    if fields == nil then return nil, err end
    if tonumber(fields.protocol) ~= M.VERSION then return nil, "protocol mismatch" end
    local id, id_err = M.NormalizeConsumerId(fields.consumer)
    if id == nil then return nil, id_err end
    local expected, expected_err = M.NormalizeConsumerId(consumer_id)
    if expected == nil then return nil, expected_err end
    if id ~= expected then return nil, "consumer mismatch" end
    local slot = math.floor(tonumber(fields.slot) or -1)
    if slot < 0 or slot >= M.SLOT_COUNT then return nil, "menu lease slot invalid" end
    if expected_slot ~= nil and slot ~= math.floor(tonumber(expected_slot) or -1) then return nil, "menu lease slot mismatch" end
    local revision = math.max(0, math.floor(tonumber(fields.revision) or 0))
    if expected_revision ~= nil and revision ~= math.max(0, math.floor(tonumber(expected_revision) or 0)) then
        return nil, "menu lease revision mismatch"
    end
    fields.consumer = id
    fields.slot = slot
    fields.revision = revision
    fields.sequence = math.max(0, math.floor(tonumber(fields.sequence) or 0))
    fields.active = tostring(fields.active or "0") == "1"
    fields.generation = math.max(0, math.floor(tonumber(fields.generation) or 0))
    fields.reason = tostring(fields.reason or "")
    return fields
end


local MENU_SHELL_STATES = {
    none = true,
    active = true,
    quarantined = true,
    retained = true,
    retired = true,
}

function M.BuildMenuShell(consumer_id, slot, consumer_revision, sequence, state, generation,
    shell_address, reused, cache_token, reason)
    local id, err = M.NormalizeConsumerId(consumer_id)
    if id == nil then return nil, err end
    slot = math.floor(tonumber(slot) or -1)
    if slot < 0 or slot >= M.SLOT_COUNT then return nil, "slot out of range" end
    state = bounded(trim(state), 32)
    if MENU_SHELL_STATES[state] ~= true then return nil, "menu shell state invalid" end
    local address = bounded(shell_address or "", 32)
    if address ~= "" and not address:match("^%d+$") then return nil, "menu shell address invalid" end
    if (state == "active" or state == "quarantined" or state == "retained") and address == "" then
        return nil, "menu shell address required"
    end
    return M.EncodeFields({
        protocol = M.VERSION, consumer = id, slot = slot,
        revision = math.max(0, math.floor(tonumber(consumer_revision) or 0)),
        sequence = math.max(0, math.floor(tonumber(sequence) or 0)),
        state = state, generation = math.max(0, math.floor(tonumber(generation) or 0)),
        address = address, reused = reused == true and 1 or 0,
        cacheToken = math.max(0, math.floor(tonumber(cache_token) or 0)),
        reason = bounded(reason or "", 160),
    })
end

function M.ValidateMenuShell(payload, consumer_id, expected_slot, expected_revision)
    local fields, err = M.DecodeFields(payload)
    if fields == nil then return nil, err end
    if tonumber(fields.protocol) ~= M.VERSION then return nil, "protocol mismatch" end
    local id, id_err = M.NormalizeConsumerId(fields.consumer)
    if id == nil then return nil, id_err end
    local expected, expected_err = M.NormalizeConsumerId(consumer_id)
    if expected == nil then return nil, expected_err end
    if id ~= expected then return nil, "consumer mismatch" end
    local slot = math.floor(tonumber(fields.slot) or -1)
    if slot < 0 or slot >= M.SLOT_COUNT then return nil, "menu shell slot invalid" end
    if expected_slot ~= nil and slot ~= math.floor(tonumber(expected_slot) or -1) then
        return nil, "menu shell slot mismatch"
    end
    local revision = math.max(0, math.floor(tonumber(fields.revision) or 0))
    if expected_revision ~= nil and revision ~= math.max(0, math.floor(tonumber(expected_revision) or 0)) then
        return nil, "menu shell revision mismatch"
    end
    local state = tostring(fields.state or "")
    if MENU_SHELL_STATES[state] ~= true then return nil, "menu shell state invalid" end
    local address = tostring(fields.address or "")
    if address ~= "" and not address:match("^%d+$") then return nil, "menu shell address invalid" end
    if (state == "active" or state == "quarantined" or state == "retained") and address == "" then
        return nil, "menu shell address required"
    end
    fields.consumer = id
    fields.slot = slot
    fields.revision = revision
    fields.sequence = math.max(0, math.floor(tonumber(fields.sequence) or 0))
    fields.generation = math.max(0, math.floor(tonumber(fields.generation) or 0))
    fields.state = state
    fields.address = address
    fields.reused = tostring(fields.reused or "0") == "1"
    fields.cacheToken = math.max(0, math.floor(tonumber(fields.cacheToken) or 0))
    fields.reason = tostring(fields.reason or "")
    return fields
end

function M.BuildInputEvent(consumer_id, slot, host_epoch, consumer_revision, sequence, action, kind)
    local id, err = M.NormalizeConsumerId(consumer_id)
    if id == nil then return nil, err end
    slot = math.floor(tonumber(slot) or -1)
    if slot < 0 or slot >= M.SLOT_COUNT then return nil, "slot out of range" end
    return M.EncodeFields({
        protocol = M.VERSION, consumer = id, slot = slot,
        revision = math.max(0, math.floor(tonumber(consumer_revision) or 0)),
        sequence = math.max(0, math.floor(tonumber(sequence) or 0)),
        hostEpoch = bounded(host_epoch, 128),
        action = bounded(action, 128), kind = bounded(kind, 64),
    })
end


function M.BuildNavigationEvent(consumer_id, slot, host_epoch, consumer_revision, sequence, action, source)
    local id, err = M.NormalizeConsumerId(consumer_id)
    if id == nil then return nil, err end
    slot = math.floor(tonumber(slot) or -1)
    if slot < 0 or slot >= M.SLOT_COUNT then return nil, "slot out of range" end
    action = bounded(action, 64)
    if action == "" then return nil, "navigation action missing" end
    return M.EncodeFields({
        protocol = M.VERSION, consumer = id, slot = slot,
        revision = math.max(0, math.floor(tonumber(consumer_revision) or 0)),
        sequence = math.max(0, math.floor(tonumber(sequence) or 0)),
        hostEpoch = bounded(host_epoch, 128),
        action = action, source = bounded(source, 96),
    })
end


function M.BuildNativeInputRequest(consumer_id, slot, host_epoch, consumer_revision, sequence, active, listener_address, generation)
    local id, err = M.NormalizeConsumerId(consumer_id)
    if id == nil then return nil, err end
    slot = math.floor(tonumber(slot) or -1)
    if slot < 0 or slot >= M.SLOT_COUNT then return nil, "slot out of range" end
    local address = bounded(listener_address or "", 32)
    if active and (address == "" or (not address:match("^%d+$") and address ~= M.HOST_NATIVE_LISTENER_TOKEN)) then
        return nil, "native listener address invalid"
    end
    return M.EncodeFields({
        protocol = M.VERSION, consumer = id, slot = slot,
        revision = math.max(0, math.floor(tonumber(consumer_revision) or 0)),
        sequence = math.max(0, math.floor(tonumber(sequence) or 0)),
        hostEpoch = bounded(host_epoch, 128), active = active and 1 or 0,
        listenerAddress = address,
        generation = math.max(0, math.floor(tonumber(generation) or 0)),
    })
end

function M.ValidateNativeInputRequest(payload, consumer_id, expected_slot, expected_revision, expected_host_epoch)
    local fields, err = M.DecodeFields(payload)
    if fields == nil then return nil, err end
    if tonumber(fields.protocol) ~= M.VERSION then return nil, "native input request protocol mismatch" end
    local id, id_err = M.NormalizeConsumerId(fields.consumer)
    if id == nil then return nil, id_err end
    local expected, expected_err = M.NormalizeConsumerId(consumer_id)
    if expected == nil then return nil, expected_err end
    if id ~= expected then return nil, "native input request consumer mismatch" end
    local slot = math.floor(tonumber(fields.slot) or -1)
    if slot < 0 or slot >= M.SLOT_COUNT then return nil, "native input request slot invalid" end
    if expected_slot ~= nil and slot ~= math.floor(tonumber(expected_slot) or -1) then
        return nil, "native input request slot mismatch"
    end
    local revision = math.max(0, math.floor(tonumber(fields.revision) or 0))
    if expected_revision ~= nil and revision ~= math.max(0, math.floor(tonumber(expected_revision) or 0)) then
        return nil, "native input request revision mismatch"
    end
    if expected_host_epoch ~= nil and tostring(fields.hostEpoch or "") ~= tostring(expected_host_epoch or "") then
        return nil, "native input request host epoch mismatch"
    end
    local active = tostring(fields.active or "0") == "1"
    local address = tostring(fields.listenerAddress or "")
    if active and (address == "" or (not address:match("^%d+$") and address ~= M.HOST_NATIVE_LISTENER_TOKEN)) then
        return nil, "native input request listener address invalid"
    end
    fields.consumer = id
    fields.slot = slot
    fields.revision = revision
    fields.sequence = math.max(0, math.floor(tonumber(fields.sequence) or 0))
    fields.active = active
    fields.listenerAddress = address
    fields.generation = math.max(0, math.floor(tonumber(fields.generation) or 0))
    return fields
end

function M.BuildNativeInputEvent(consumer_id, slot, host_epoch, consumer_revision, sequence, request_sequence, generation, input_number, source, pointer_snapshot, route)
    local id, err = M.NormalizeConsumerId(consumer_id)
    if id == nil then return nil, err end
    slot = math.floor(tonumber(slot) or -1)
    if slot < 0 or slot >= M.SLOT_COUNT then return nil, "slot out of range" end
    input_number = tonumber(input_number)
    if input_number == nil then return nil, "native input enum invalid" end

    pointer_snapshot = type(pointer_snapshot) == "table" and pointer_snapshot or nil
    local pointer_x = pointer_snapshot ~= nil and tonumber(pointer_snapshot.x) or nil
    local pointer_y = pointer_snapshot ~= nil and tonumber(pointer_snapshot.y) or nil
    local viewport_width = pointer_snapshot ~= nil and tonumber(pointer_snapshot.width) or nil
    local viewport_height = pointer_snapshot ~= nil and tonumber(pointer_snapshot.height) or nil
    local pointer_valid = pointer_x ~= nil and pointer_y ~= nil
        and viewport_width ~= nil and viewport_width > 0
        and viewport_height ~= nil and viewport_height > 0

    return M.EncodeFields({
        protocol = M.VERSION, consumer = id, slot = slot,
        revision = math.max(0, math.floor(tonumber(consumer_revision) or 0)),
        sequence = math.max(0, math.floor(tonumber(sequence) or 0)),
        requestSequence = math.max(0, math.floor(tonumber(request_sequence) or 0)),
        hostEpoch = bounded(host_epoch, 128),
        generation = math.max(0, math.floor(tonumber(generation) or 0)),
        input = math.floor(input_number), source = bounded(source, 96),
        route = route ~= nil and bounded(route, 64) or nil,
        pointerX = pointer_valid and string.format("%.3f", pointer_x) or nil,
        pointerY = pointer_valid and string.format("%.3f", pointer_y) or nil,
        viewportWidth = pointer_valid and string.format("%.3f", viewport_width) or nil,
        viewportHeight = pointer_valid and string.format("%.3f", viewport_height) or nil,
        pointerSource = pointer_valid and bounded(pointer_snapshot.source or "unknown", 96) or nil,
        -- v0.70.0: what the visible shell host found under the pointer, from the layout it
        -- drew (Host.ShellService.ResolvePointer). Absent when no shell resolved it; the
        -- consumer then falls back to its own model.
        hitKind = pointer_valid and pointer_snapshot.hitKind ~= nil and bounded(pointer_snapshot.hitKind, 24) or nil,
        hitIndex = pointer_valid and tonumber(pointer_snapshot.hitIndex) ~= nil
            and tostring(math.floor(tonumber(pointer_snapshot.hitIndex))) or nil,
        hitDirection = pointer_valid and tonumber(pointer_snapshot.hitDirection) ~= nil
            and tostring(math.floor(tonumber(pointer_snapshot.hitDirection))) or nil,
    })
end

function M.ValidateNativeInputEvent(payload, consumer_id, expected_slot, expected_revision, expected_host_epoch, expected_request_sequence)
    local fields, err = M.DecodeFields(payload)
    if fields == nil then return nil, err end
    if tonumber(fields.protocol) ~= M.VERSION then return nil, "native input event protocol mismatch" end
    local id, id_err = M.NormalizeConsumerId(fields.consumer)
    if id == nil then return nil, id_err end
    local expected, expected_err = M.NormalizeConsumerId(consumer_id)
    if expected == nil then return nil, expected_err end
    if id ~= expected then return nil, "native input event consumer mismatch" end
    local slot = math.floor(tonumber(fields.slot) or -1)
    if slot < 0 or slot >= M.SLOT_COUNT then return nil, "native input event slot invalid" end
    if expected_slot ~= nil and slot ~= math.floor(tonumber(expected_slot) or -1) then
        return nil, "native input event slot mismatch"
    end
    local revision = math.max(0, math.floor(tonumber(fields.revision) or 0))
    if expected_revision ~= nil and revision ~= math.max(0, math.floor(tonumber(expected_revision) or 0)) then
        return nil, "native input event revision mismatch"
    end
    if expected_host_epoch ~= nil and tostring(fields.hostEpoch or "") ~= tostring(expected_host_epoch or "") then
        return nil, "native input event host epoch mismatch"
    end
    local request_sequence = math.max(0, math.floor(tonumber(fields.requestSequence) or 0))
    if expected_request_sequence ~= nil
        and request_sequence ~= math.max(0, math.floor(tonumber(expected_request_sequence) or 0)) then
        return nil, "native input event request sequence mismatch"
    end
    local input_number = tonumber(fields.input)
    if input_number == nil then return nil, "native input event enum invalid" end
    fields.consumer = id
    fields.slot = slot
    fields.revision = revision
    fields.sequence = math.max(0, math.floor(tonumber(fields.sequence) or 0))
    fields.requestSequence = request_sequence
    fields.generation = math.max(0, math.floor(tonumber(fields.generation) or 0))
    fields.input = math.floor(input_number)
    fields.source = tostring(fields.source or "")
    fields.route = tostring(fields.route or "")

    local pointer_x = tonumber(fields.pointerX)
    local pointer_y = tonumber(fields.pointerY)
    local viewport_width = tonumber(fields.viewportWidth)
    local viewport_height = tonumber(fields.viewportHeight)
    if pointer_x ~= nil or pointer_y ~= nil or viewport_width ~= nil or viewport_height ~= nil then
        if pointer_x == nil or pointer_y == nil or viewport_width == nil or viewport_width <= 0
            or viewport_height == nil or viewport_height <= 0 then
            return nil, "native input pointer snapshot invalid"
        end
        fields.pointerX = pointer_x
        fields.pointerY = pointer_y
        fields.viewportWidth = viewport_width
        fields.viewportHeight = viewport_height
        fields.pointerSource = tostring(fields.pointerSource or "unknown")
        local kind = tostring(fields.hitKind or "")
        if kind ~= "" then
            fields.hitKind = kind
            fields.hitIndex = tonumber(fields.hitIndex)
            fields.hitDirection = tonumber(fields.hitDirection)
        else
            fields.hitKind, fields.hitIndex, fields.hitDirection = nil, nil, nil
        end
    else
        fields.pointerX = nil
        fields.pointerY = nil
        fields.viewportWidth = nil
        fields.viewportHeight = nil
        fields.pointerSource = nil
        fields.hitKind, fields.hitIndex, fields.hitDirection = nil, nil, nil
    end
    return fields
end

function M.BuildControllerRequest(consumer_id, slot, host_epoch, consumer_revision, sequence, active)
    local id, err = M.NormalizeConsumerId(consumer_id)
    if id == nil then return nil, err end
    slot = math.floor(tonumber(slot) or -1)
    if slot < 0 or slot >= M.SLOT_COUNT then return nil, "slot out of range" end
    return M.EncodeFields({
        protocol = M.VERSION, consumer = id, slot = slot,
        revision = math.max(0, math.floor(tonumber(consumer_revision) or 0)),
        sequence = math.max(0, math.floor(tonumber(sequence) or 0)),
        hostEpoch = bounded(host_epoch, 128),
        active = active and 1 or 0,
    })
end

function M.ValidateControllerRequest(payload, consumer_id, expected_slot, expected_revision, expected_host_epoch)
    local fields, err = M.DecodeFields(payload)
    if fields == nil then return nil, err end
    if tonumber(fields.protocol) ~= M.VERSION then return nil, "controller request protocol mismatch" end
    local id, id_err = M.NormalizeConsumerId(fields.consumer)
    if id == nil then return nil, id_err end
    local expected, expected_err = M.NormalizeConsumerId(consumer_id)
    if expected == nil then return nil, expected_err end
    if id ~= expected then return nil, "controller request consumer mismatch" end
    local slot = math.floor(tonumber(fields.slot) or -1)
    if slot < 0 or slot >= M.SLOT_COUNT then return nil, "controller request slot invalid" end
    if expected_slot ~= nil and slot ~= math.floor(tonumber(expected_slot) or -1) then
        return nil, "controller request slot mismatch"
    end
    local revision = math.max(0, math.floor(tonumber(fields.revision) or 0))
    if expected_revision ~= nil and revision ~= math.max(0, math.floor(tonumber(expected_revision) or 0)) then
        return nil, "controller request revision mismatch"
    end
    if expected_host_epoch ~= nil and tostring(fields.hostEpoch or "") ~= tostring(expected_host_epoch or "") then
        return nil, "controller request host epoch mismatch"
    end
    fields.consumer = id
    fields.slot = slot
    fields.revision = revision
    fields.sequence = math.max(0, math.floor(tonumber(fields.sequence) or 0))
    fields.active = tostring(fields.active or "0") == "1"
    return fields
end

function M.BuildCaptureRequest(consumer_id, slot, host_epoch, consumer_revision, sequence, kind, active)
    local id, err = M.NormalizeConsumerId(consumer_id)
    if id == nil then return nil, err end
    slot = math.floor(tonumber(slot) or -1)
    if slot < 0 or slot >= M.SLOT_COUNT then return nil, "slot out of range" end
    kind = tostring(kind or "")
    if kind ~= "controller" and kind ~= "controller-sampling" and kind ~= "keyboard" and kind ~= "off" then
        return nil, "capture kind invalid"
    end
    return M.EncodeFields({
        protocol = M.VERSION, consumer = id, slot = slot,
        revision = math.max(0, math.floor(tonumber(consumer_revision) or 0)),
        sequence = math.max(0, math.floor(tonumber(sequence) or 0)),
        hostEpoch = bounded(host_epoch, 128),
        kind = kind, active = active and 1 or 0,
    })
end

function M.ValidateCaptureRequest(payload, consumer_id, expected_slot, expected_revision, expected_host_epoch)
    local fields, err = M.DecodeFields(payload)
    if fields == nil then return nil, err end
    if tonumber(fields.protocol) ~= M.VERSION then return nil, "capture protocol mismatch" end
    local id, id_err = M.NormalizeConsumerId(fields.consumer)
    if id == nil then return nil, id_err end
    local expected, expected_err = M.NormalizeConsumerId(consumer_id)
    if expected == nil then return nil, expected_err end
    if id ~= expected then return nil, "capture consumer mismatch" end
    local slot = math.floor(tonumber(fields.slot) or -1)
    if slot < 0 or slot >= M.SLOT_COUNT then return nil, "capture slot invalid" end
    if expected_slot ~= nil and slot ~= math.floor(tonumber(expected_slot) or -1) then
        return nil, "capture slot mismatch"
    end
    local revision = math.max(0, math.floor(tonumber(fields.revision) or 0))
    if expected_revision ~= nil and revision ~= math.max(0, math.floor(tonumber(expected_revision) or 0)) then
        return nil, "capture revision mismatch"
    end
    if expected_host_epoch ~= nil and tostring(fields.hostEpoch or "") ~= tostring(expected_host_epoch or "") then
        return nil, "capture host epoch mismatch"
    end
    local kind = tostring(fields.kind or "")
    if kind ~= "controller" and kind ~= "controller-sampling" and kind ~= "keyboard" and kind ~= "off" then return nil, "capture kind invalid" end
    fields.consumer = id
    fields.slot = slot
    fields.revision = revision
    fields.sequence = math.max(0, math.floor(tonumber(fields.sequence) or 0))
    fields.kind = kind
    fields.active = tostring(fields.active or "0") == "1"
    return fields
end

function M.BuildKeySample(consumer_id, slot, host_epoch, consumer_revision, sequence, capture_sequence, key, down, source, press_sequence)
    local id, err = M.NormalizeConsumerId(consumer_id)
    if id == nil then return nil, err end
    slot = math.floor(tonumber(slot) or -1)
    if slot < 0 or slot >= M.SLOT_COUNT then return nil, "slot out of range" end
    key = bounded(key, 96)
    if key == "" then return nil, "key missing" end
    return M.EncodeFields({
        protocol = M.VERSION, consumer = id, slot = slot,
        revision = math.max(0, math.floor(tonumber(consumer_revision) or 0)),
        sequence = math.max(0, math.floor(tonumber(sequence) or 0)),
        captureSequence = math.max(0, math.floor(tonumber(capture_sequence) or 0)),
        hostEpoch = bounded(host_epoch, 128),
        key = key, down = down and 1 or 0, source = bounded(source, 96),
        pressSequence = math.max(0, math.floor(tonumber(press_sequence) or 0)),
    })
end

function M.ValidateKeySample(payload, consumer_id, expected_slot, expected_revision, expected_host_epoch, expected_capture_sequence, expected_key)
    local fields, err = M.DecodeFields(payload)
    if fields == nil then return nil, err end
    if tonumber(fields.protocol) ~= M.VERSION then return nil, "key protocol mismatch" end
    local id, id_err = M.NormalizeConsumerId(fields.consumer)
    if id == nil then return nil, id_err end
    local expected, expected_err = M.NormalizeConsumerId(consumer_id)
    if expected == nil then return nil, expected_err end
    if id ~= expected then return nil, "key consumer mismatch" end
    local slot = math.floor(tonumber(fields.slot) or -1)
    if slot < 0 or slot >= M.SLOT_COUNT then return nil, "key slot invalid" end
    if expected_slot ~= nil and slot ~= math.floor(tonumber(expected_slot) or -1) then return nil, "key slot mismatch" end
    local revision = math.max(0, math.floor(tonumber(fields.revision) or 0))
    if expected_revision ~= nil and revision ~= math.max(0, math.floor(tonumber(expected_revision) or 0)) then
        return nil, "key revision mismatch"
    end
    if expected_host_epoch ~= nil and tostring(fields.hostEpoch or "") ~= tostring(expected_host_epoch or "") then
        return nil, "key host epoch mismatch"
    end
    local capture_sequence = math.max(0, math.floor(tonumber(fields.captureSequence) or 0))
    if expected_capture_sequence ~= nil
        and capture_sequence ~= math.max(0, math.floor(tonumber(expected_capture_sequence) or 0)) then
        return nil, "key capture sequence mismatch"
    end
    local key = tostring(fields.key or "")
    if expected_key ~= nil and key ~= tostring(expected_key) then return nil, "key name mismatch" end
    fields.consumer = id
    fields.slot = slot
    fields.revision = revision
    fields.sequence = math.max(0, math.floor(tonumber(fields.sequence) or 0))
    fields.captureSequence = capture_sequence
    fields.key = key
    fields.down = tostring(fields.down or "0") == "1"
    fields.pressSequence = math.max(0, math.floor(tonumber(fields.pressSequence) or 0))
    return fields
end

function M.BuildAxisSample(consumer_id, slot, host_epoch, consumer_revision, sequence, axis, value, source, frame)
    local id, err = M.NormalizeConsumerId(consumer_id)
    if id == nil then return nil, err end
    slot = math.floor(tonumber(slot) or -1)
    if slot < 0 or slot >= M.SLOT_COUNT then return nil, "slot out of range" end
    value = tonumber(value)
    if value == nil or value ~= value or value == math.huge or value == -math.huge then
        return nil, "axis value invalid"
    end
    return M.EncodeFields({
        protocol = M.VERSION, consumer = id, slot = slot,
        revision = math.max(0, math.floor(tonumber(consumer_revision) or 0)),
        sequence = math.max(0, math.floor(tonumber(sequence) or 0)),
        hostEpoch = bounded(host_epoch, 128),
        axis = bounded(axis, 64),
        value = string.format("%.6f", value),
        source = bounded(source, 96),
        frame = math.max(0, math.floor(tonumber(frame) or 0)),
    })
end

function M.ValidateAxisSample(payload, consumer_id, expected_slot, expected_revision, expected_host_epoch, expected_axis)
    local fields, err = M.DecodeFields(payload)
    if fields == nil then return nil, err end
    if tonumber(fields.protocol) ~= M.VERSION then return nil, "protocol mismatch" end
    local id, id_err = M.NormalizeConsumerId(fields.consumer)
    if id == nil then return nil, id_err end
    local expected, expected_err = M.NormalizeConsumerId(consumer_id)
    if expected == nil then return nil, expected_err end
    if id ~= expected then return nil, "consumer mismatch" end
    local slot = math.floor(tonumber(fields.slot) or -1)
    if slot < 0 or slot >= M.SLOT_COUNT then return nil, "axis slot invalid" end
    if expected_slot ~= nil and slot ~= math.floor(tonumber(expected_slot) or -1) then
        return nil, "axis slot mismatch"
    end
    local revision = math.max(0, math.floor(tonumber(fields.revision) or 0))
    if expected_revision ~= nil and revision ~= math.max(0, math.floor(tonumber(expected_revision) or 0)) then
        return nil, "axis revision mismatch"
    end
    if expected_host_epoch ~= nil and tostring(fields.hostEpoch or "") ~= tostring(expected_host_epoch or "") then
        return nil, "axis host epoch mismatch"
    end
    local axis = tostring(fields.axis or "")
    if expected_axis ~= nil and axis ~= tostring(expected_axis) then return nil, "axis name mismatch" end
    local value = tonumber(fields.value)
    if value == nil or value ~= value or value == math.huge or value == -math.huge then
        return nil, "axis value invalid"
    end
    fields.consumer, fields.slot, fields.revision = id, slot, revision
    fields.sequence = math.max(0, math.floor(tonumber(fields.sequence) or 0))
    fields.frame = math.max(0, math.floor(tonumber(fields.frame) or 0))
    fields.axis, fields.value = axis, value
    return fields
end

function M.ValidateNavigationEvent(payload, consumer_id, expected_slot, expected_revision, expected_host_epoch)
    local fields, err = M.DecodeFields(payload)
    if fields == nil then return nil, err end
    if tonumber(fields.protocol) ~= M.VERSION then return nil, "navigation protocol mismatch" end
    local id, id_err = M.NormalizeConsumerId(fields.consumer)
    if id == nil then return nil, id_err end
    local expected, expected_err = M.NormalizeConsumerId(consumer_id)
    if expected == nil then return nil, expected_err end
    if id ~= expected then return nil, "navigation consumer mismatch" end
    local slot = math.floor(tonumber(fields.slot) or -1)
    if slot < 0 or slot >= M.SLOT_COUNT then return nil, "navigation slot invalid" end
    if expected_slot ~= nil and slot ~= math.floor(tonumber(expected_slot) or -1) then
        return nil, "navigation slot mismatch"
    end
    local revision = math.max(0, math.floor(tonumber(fields.revision) or 0))
    if expected_revision ~= nil and revision ~= math.max(0, math.floor(tonumber(expected_revision) or 0)) then
        return nil, "navigation revision mismatch"
    end
    if expected_host_epoch ~= nil and tostring(fields.hostEpoch or "") ~= tostring(expected_host_epoch or "") then
        return nil, "navigation host epoch mismatch"
    end
    local action = tostring(fields.action or "")
    if action == "" then return nil, "navigation action missing" end
    fields.consumer = id
    fields.slot = slot
    fields.revision = revision
    fields.sequence = math.max(0, math.floor(tonumber(fields.sequence) or 0))
    fields.action = action
    fields.source = tostring(fields.source or "")
    return fields
end

function M.ValidateInputEvent(payload, consumer_id, expected_slot, expected_revision, expected_host_epoch)
    local fields, err = M.DecodeFields(payload)
    if fields == nil then return nil, err end
    if tonumber(fields.protocol) ~= M.VERSION then return nil, "protocol mismatch" end
    local id, id_err = M.NormalizeConsumerId(fields.consumer)
    if id == nil then return nil, id_err end
    local expected, expected_err = M.NormalizeConsumerId(consumer_id)
    if expected == nil then return nil, expected_err end
    if id ~= expected then return nil, "consumer mismatch" end
    local slot = math.floor(tonumber(fields.slot) or -1)
    if slot < 0 or slot >= M.SLOT_COUNT then return nil, "event slot invalid" end
    if expected_slot ~= nil and slot ~= math.floor(tonumber(expected_slot) or -1) then return nil, "event slot mismatch" end
    local revision = math.max(0, math.floor(tonumber(fields.revision) or 0))
    if expected_revision ~= nil and revision ~= math.max(0, math.floor(tonumber(expected_revision) or 0)) then return nil, "event revision mismatch" end
    if expected_host_epoch ~= nil and tostring(fields.hostEpoch or "") ~= tostring(expected_host_epoch or "") then return nil, "event host epoch mismatch" end
    fields.consumer, fields.slot, fields.revision = id, slot, revision
    fields.sequence = math.max(0, math.floor(tonumber(fields.sequence) or 0))
    return fields
end

return M
