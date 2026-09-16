-- MortalShell2ModUI host UI audio (v0.71.5).
--
-- User, 2026-09-15: "would it be possible to add the menu sound when navigating the menu
-- for our mod ui, is a very subtle click sound when i change options. There is also a
-- change tab sound we could use when changing tabs."
--
-- Yes, and through the game's OWN broadcaster rather than a sound asset of our own. She
-- exported Content/Sparta/UI and it carries a Blueprint function library built for exactly
-- this:
--
--   /Game/Sparta/UI/Audio/Events/BPFL_UI_Audio.BPFL_UI_Audio_C:BroadcastUIAudioEvent
--     (InstigatorWidget: Widget, EventType: Enum_UI_Events,
--      Context: GameplayTag, OptionalSubContext: GameplayTag, __WorldContext: Object)
--
-- Going through the broadcaster means the sound is routed by the game's audio system, so
-- it obeys the player's own UI volume for free, there is no asset to load or keep alive,
-- and it is the same click the game's menus make rather than an approximation of it.
--
-- TWO PARAMETERS ARE STRUCTS (FGameplayTag), which is the part that cannot be settled by
-- reading an export. Invariant 0b: a successful pcall is not evidence the sound played,
-- and invariant 0f: a path read off a file is still unproven until something calls it. So
-- this module does NOT assume a call shape. It tries the shapes in order, keeps the first
-- that does not raise, and says in the log which one worked and what the others said. One
-- run answers it; after that the module is a table lookup and a call.
--
-- Everything is failure-tolerant by construction: if no shape works the module disables
-- itself for the session, says so once, and every later Play() is a boolean check. A mod
-- that cannot make a click must never be a mod that cannot draw a menu.

local Factory = {}

-- Enum_UI_Events, transcribed from her export's DisplayNameMap. The names are ours; the
-- numbers are the game's, and the numbers are what the call takes.
local EVENTS = {
    Confirm = 0,
    ConfirmFailed = 1,
    Select = 2,
    Hover = 3,
    HoldStart = 4,
    HoldComplete = 5,
    HoldCancel = 6,
    Open = 7,
    Close = 8,
    TabSwitch = 9,
    Increase = 10,
    Decrease = 11,
    ZoomIn = 12,
    ZoomOut = 13,
    Revealed = 14,
    Place = 15,
    Remove = 16,
    Focus = 17,
    Toggle = 18,
}

-- v0.71.5. Her 153038 run proved the call itself works -- one line, "ui audio armed
-- shape=full event=Open value=7 rejected=none", first shape, nothing rejected -- and she
-- can hear the navigation clicks. Open and Close produce nothing she can hear.
--
-- The export says why that is the likely story rather than a broken call. Every UI sound
-- is an AudioEvent asset under /Game/Sparta/UI/Audio/WaveWeaver with its own mix volume,
-- and the three she CAN hear sit 15-16 dB above the two she cannot:
--
--   AE_UI_Select  +4.0 dB      AE_UI_Open   -12.0 dB  (MS1_SFX_UI_Menu_Open)
--   AE_UI_Hover   +3.0 dB      AE_UI_Close  -12.0 dB  (MS1_SFX_UI_Menu_Close)
--   AE_UI_TabSwitch +3.0 dB
--
-- That is the game's own mix for its own menus, not something we did.
--
-- BUT: nothing in the export maps an Enum_UI_Events VALUE to one of those assets. Nothing
-- in Content binds the broadcast at all -- the listener is native -- so the pairing below
-- is READ OFF THE NAMES and is exactly the kind of thing invariant 0f says not to trust.
-- It is recorded here only so the sweep's log is self-interpreting: if what she hears
-- tracks the dB column, the mix is the whole story; if it does not, the mapping is wrong
-- and the sweep says which values actually make a sound.
local MIX = {
    [0]  = { asset = "AE_UI_Confirm",       db =   3.0 },
    [1]  = { asset = "AE_UI_ConfirmFailed", db =  -6.0 },
    [2]  = { asset = "AE_UI_Select",        db =   4.0 },
    [3]  = { asset = "AE_UI_Hover",         db =   3.0 },
    [4]  = { asset = "AE_UI_HoldStart",     db =  -3.0 },
    [5]  = { asset = "AE_UI_HoldComplete",  db =   3.0 },
    [6]  = { asset = "AE_UI_HoldCancel",    db =  -9.0 },
    [7]  = { asset = "AE_UI_Open",          db = -12.0 },
    [8]  = { asset = "AE_UI_Close",         db = -12.0 },
    [9]  = { asset = "AE_UI_TabSwitch",     db =   3.0 },
    [10] = { asset = "AE_UI_Increase",      db =   3.0 },
    [11] = { asset = "AE_UI_Decrease",      db =   3.0 },
    [12] = { asset = "AE_UI_Zoom_Tick",     db =  12.0 },
    [13] = { asset = "AE_UI_Zoom_Tick",     db =  12.0 },
    [14] = { asset = "AE_UI_ButtonReveal",  db =   3.0 },
    -- 15 Place, 16 Remove, 17 Focus, 18 Toggle: no generic AE_UI_* asset carries those
    -- names, so either they are context-only or they are silent. The sweep settles it.
}

local ASSET = "/Game/Sparta/UI/Audio/Events/BPFL_UI_Audio"
local CDO = "/Game/Sparta/UI/Audio/Events/BPFL_UI_Audio.Default__BPFL_UI_Audio_C"
local FUNCTION_NAME = "BroadcastUIAudioEvent"

-- A menu repeat can outrun any sound. The consumer already throttles input, but the floor
-- belongs here too so no future caller can turn this into a machine gun.
local MIN_INTERVAL_SECONDS = 0.04

function Factory.New(ctx)
    ctx = type(ctx) == "table" and ctx or {}
    local Object = ctx.Object
    local log = type(ctx.Log) == "function" and ctx.Log or function() end
    local clock = type(ctx.Clock) == "function" and ctx.Clock or os.clock

    local audio = { Events = EVENTS, Mix = MIX }

    local state = {
        cdo = nil,
        shape = nil,        -- the call that worked, once one has
        disabled = false,   -- nothing worked; stay quiet for the session
        reported = false,
        last_at = nil,
        plays = 0,
        refused = 0,
    }

    local function unwrap(value)
        if Object ~= nil and type(Object.Unwrap) == "function" then return Object.Unwrap(value) end
        return value
    end
    local function valid(value)
        if Object ~= nil and type(Object.Valid) == "function" then return Object.Valid(value) end
        return value ~= nil
    end

    -- The call shapes, most complete first. Each is pcall'd; the first that does not raise
    -- is remembered. An empty table is how UE4SS spells a zeroed struct, which is what a
    -- default (empty) GameplayTag is.
    local SHAPES = {
        {
            name = "full",
            call = function(cdo, widget, event)
                cdo[FUNCTION_NAME](cdo, widget, event, {}, {}, widget)
            end,
        },
        {
            name = "no-world-context",
            call = function(cdo, widget, event)
                cdo[FUNCTION_NAME](cdo, widget, event, {}, {})
            end,
        },
        {
            name = "event-only",
            call = function(cdo, widget, event)
                cdo[FUNCTION_NAME](cdo, widget, event)
            end,
        },
    }

    local function resolve()
        if state.disabled then return nil end
        local cdo = unwrap(state.cdo)
        if valid(cdo) then return cdo end
        state.cdo = nil
        if type(LoadAsset) == "function" then pcall(LoadAsset, ASSET) end
        if type(StaticFindObject) ~= "function" then
            if not state.reported then
                state.reported = true
                state.disabled = true
                log("[MortalShell2ModUI] ui audio unavailable reason=no-StaticFindObject")
            end
            return nil
        end
        local ok, found = pcall(StaticFindObject, CDO)
        cdo = ok and unwrap(found) or nil
        if not valid(cdo) then
            if not state.reported then
                state.reported = true
                state.disabled = true
                log("[MortalShell2ModUI] ui audio unavailable reason=cdo-not-found path=" .. CDO)
            end
            return nil
        end
        if cdo[FUNCTION_NAME] == nil then
            if not state.reported then
                state.reported = true
                state.disabled = true
                log("[MortalShell2ModUI] ui audio unavailable reason=no-function name="
                    .. FUNCTION_NAME .. " path=" .. CDO)
            end
            return nil
        end
        state.cdo = cdo
        return cdo
    end

    -- Returns true when the call was made. That is NOT the same as "a sound came out"
    -- (invariant 0b) -- only a person listening can say that, which is why the first
    -- success is logged with the shape that produced it.
    function audio.Play(event_name, widget)
        if state.disabled then return false, "disabled" end
        local event = EVENTS[tostring(event_name or "")]
        if event == nil then return false, "unknown-event" end
        local now = clock()
        if state.last_at ~= nil and (now - state.last_at) < MIN_INTERVAL_SECONDS then
            state.refused = state.refused + 1
            return false, "throttled"
        end
        local cdo = resolve()
        if cdo == nil then return false, "unavailable" end
        widget = unwrap(widget)
        if not valid(widget) then widget = nil end

        if state.shape ~= nil then
            local ok, err = pcall(state.shape.call, cdo, widget, event)
            if ok then
                state.last_at = now
                state.plays = state.plays + 1
                return true
            end
            -- A shape that worked and then stopped means the world moved under us; drop
            -- the cached object and let the next call resolve again rather than going mute.
            state.cdo, state.shape = nil, nil
            return false, tostring(err)
        end

        local tried = {}
        for _, shape in ipairs(SHAPES) do
            local ok, err = pcall(shape.call, cdo, widget, event)
            if ok then
                state.shape = shape
                state.last_at = now
                state.plays = state.plays + 1
                log(string.format(
                    "[MortalShell2ModUI] ui audio armed shape=%s event=%s value=%d rejected=%s"
                    .. " -- if no sound is audible the call is reaching a function that does"
                    .. " nothing, not failing",
                    shape.name, tostring(event_name), event,
                    #tried > 0 and table.concat(tried, "|") or "none"))
                return true
            end
            tried[#tried + 1] = shape.name .. ":" .. tostring(err):gsub("%s+", " "):sub(1, 90)
        end
        state.disabled = true
        log("[MortalShell2ModUI] ui audio unavailable reason=no-call-shape-worked attempts="
            .. table.concat(tried, " || "))
        return false, "no-shape"
    end

    -- The world took the object with it. Resolving again is one StaticFindObject; the
    -- learned shape is kept, because the function's signature does not change with a level.
    function audio.OnWorldReleased()
        state.cdo = nil
    end

    -- v0.71.5 SWEEP -- the diagnostic that settles open/close instead of me guessing a
    -- second time at which number is a door closing.
    --
    -- It plays every value in the enum, far enough apart to tell them apart, and prints
    -- each one with the asset and mix volume the export says it should reach. One listen
    -- with the log beside it names the whole usable palette.
    --
    -- The experiment carries its OWN CONTROL. Hover, Select and TabSwitch are already
    -- known audible from her own play, so they have to be audible in the sweep too. If
    -- they are, the instigator widget did not matter and every other result in the run is
    -- trustworthy. If NOTHING is audible, the widget is the variable, not the event, and
    -- the sweep has to be re-run from inside an open shell. Either way the run answers a
    -- question rather than adding a guess.
    --
    -- Dev-only by construction: it lives here because the host owns audio, and it is
    -- reached only from the UIPlayground's Ctrl+Shift+A, which never ships.
    function audio.Sweep(widget, schedule, step_ms)
        if type(schedule) ~= "function" then return false, "no-scheduler" end
        step_ms = math.max(250, math.floor(tonumber(step_ms) or 900))
        local order = {}
        for name, value in pairs(EVENTS) do order[#order + 1] = { name = name, value = value } end
        table.sort(order, function(a, b) return a.value < b.value end)
        log(string.format("[MortalShell2ModUI] ui audio SWEEP begin count=%d stepMs=%d"
            .. " -- note which numbers you HEAR; 2/3/9 are the control and must be audible",
            #order, step_ms))
        for index, entry in ipairs(order) do
            schedule((index - 1) * step_ms, function()
                -- The throttle exists for menu repeats, not for a deliberate sweep.
                state.last_at = nil
                local played = audio.Play(entry.name, widget)
                local mix = MIX[entry.value]
                log(string.format(
                    "[MortalShell2ModUI] ui audio sweep %02d/%02d value=%d name=%s called=%s expect=%s",
                    index, #order, entry.value, entry.name, tostring(played),
                    mix ~= nil and string.format("%s@%+.1fdB", mix.asset, mix.db) or "unmapped"))
            end)
        end
        return true
    end

    function audio.Status()
        return {
            armed = state.shape ~= nil and state.shape.name or nil,
            disabled = state.disabled,
            plays = state.plays,
            throttled = state.refused,
        }
    end

    return audio
end

-- Readable without constructing an instance, so the regression can pin the enum and the
-- mix table against each other without a fake UE4SS around them.
Factory.EVENTS = EVENTS
Factory.MIX = MIX

return Factory
