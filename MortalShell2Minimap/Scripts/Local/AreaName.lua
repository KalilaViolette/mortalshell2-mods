-- Local.AreaName -- where the player is, from the game's own named volumes.
--
-- WHY THIS EXISTS
--
-- Until v0.12.0 the map label read WBP_Notify_Large_AreaName_C, the widget the game
-- uses to shout things at you. That channel is shared: her 2026-09-12 screenshot has
-- "Gloom Retrieved" sitting under the minimap while she stands in a cavern. The notify
-- is a notification, not a location.
--
-- The 2026-09-11 object dump and the AreaProbe runs found the real source. The world is
-- carved into named box volumes:
--
--     BP_LocationNameDisplay_C  (Actor)
--       Box                     UBoxComponent, overlap-bound
--       LocationID    FName     0x2D0
--       LocationText  FText     0x2D8
--       bTriggeredRegularNotify 0x2E8
--       Cooldown                0x2EC
--       ReceiveBeginPlay / TriggerRegularNotify / TryTriggerDungeonNotify / Reset
--
-- The notify we used to read is this actor's OUTPUT. We were reading the loudspeaker
-- instead of the sign. Nothing but the volume writes LocationText, so no announcement
-- can ever contaminate it, and the volume still fires when the game suppresses a
-- re-entry notify on its own Cooldown.
--
-- TWO THINGS THE PROBE CAUGHT THAT WOULD OTHERWISE HAVE SHIPPED BROKEN
--
--  1. The name field is INVERTED between overworld and dungeon volumes:
--         overworld:  LocationID=None               LocationText="Blackridge Cliffs"
--         dungeon:    LocationID="The King's Crypt"  LocationText=empty
--     Only 3 of her 31 overworld volumes set LocationID at all. Taking LocationText
--     alone would have produced a blank label in every dungeon, and taking LocationID
--     alone a blank label everywhere else. Hence classify(): text wins when present,
--     id is the fallback AND the marker of a sub-area.
--  2. Point-in-box is a SEED, not a live source. She crossed the Blackridge Cliffs box
--     in and out four times in sixteen seconds, because many of these volumes are thin
--     entry gates rather than region covers. So the triggers drive the value and the
--     box test only answers "where am I already?" after a world load.
--
-- SHAPE (user decision, 2026-09-12): line one is always the outer area; line two is the
-- sub-area -- a dungeon, or a beacon/landing site when you are standing at one.
--
-- PERFORMANCE
--
-- Spawn-sourced like every other layer here: hooks capture primitives inside the live
-- callback and no UObject wrapper is ever retained (invariants 0/0a). Resolve() is pure
-- Lua arithmetic over ~31 volumes and ~60 beacons of cached numbers, gated on the
-- player having actually moved, so the steady state costs no native call at all. The
-- one-shot seed is sliced through WorkBudget and runs once per world.

local Factory = {}

local LOC_CLASS = "/Game/Sparta/Core/Common/Interactions/Blueprints/"
    .. "BP_LocationNameDisplay.BP_LocationNameDisplay_C"
local LANDING_CLASS = "/Game/Sparta/Core/World/Launch/BP_LandingAreaBase.BP_LandingAreaBase_C"

-- Centimetres. A dungeon sub-name survives until you are this far outside the volume
-- that named it, which stops the label flickering as you cross its gate.
local SUB_RELEASE_MARGIN = 4000.0
-- How near a beacon has to be before its name takes the second line.
-- v0.12.1. 18 m only lit up while she was standing on the beacon, so the second line
-- never changed as she walked the hub -- and the hub's sub-areas (Ova Nursery, Tarforge
-- Chamber, Merrick's Quarters, Shellkeeper's Vault) ARE landing areas. 60 m makes the
-- nearest one track her through the hub while still going quiet in open country, where
-- beacons are hundreds of metres apart.
local DEFAULT_BEACON_RADIUS_M = 60.0
-- v0.12.3. When no gate has been crossed and no box contains the player, the nearest
-- outer volume by box-surface distance fills line one -- but only if it is within this
-- many centimetres, so the hub (1.5 km from anything) stays honest rather than showing
-- a random overworld region. Never overrides a trigger.
local NEAREST_OUTER_MAX_CM = 60000.0
-- The hub has no location volume at all, but it has an anchor beacon: UniqueID
-- LandingArea_HUB, area name "Marrow Keep". Within this radius of it, that name is the
-- outer area and the hub's own sub-areas (Ova Nursery, Tarforge Chamber ...) are line
-- two. Special-cased on that one id, and documented as such.
local HUB_BEACON_ID = "LandingArea_HUB"
local HUB_ANCHOR_RADIUS_CM = 25000.0
-- Don't re-resolve until the player has moved this far (cm).
local RESOLVE_MOVE_EPSILON = 150.0

function Factory.New(ctx)
    local Object = assert(ctx.Object, "Local.AreaName requires Core.Object")
    local Config = assert(ctx.Config, "Local.AreaName requires Config")
    local state = assert(ctx.State, "Local.AreaName requires State")
    local log = assert(ctx.Log, "Local.AreaName requires Log")
    local Perf = type(ctx.Perf) == "table" and ctx.Perf
        or { Begin = function() return nil end, End = function() end, Count = function() end }
    local WorkBudget = ctx.WorkBudget
    local global_runtime = assert(ctx.GlobalRuntime, "Local.AreaName requires GlobalRuntime")
    local instance_generation = assert(ctx.InstanceGeneration,
        "Local.AreaName requires InstanceGeneration")

    local runtime = {
        hooks = {},
        volumes = {},       -- address -> { name, kind, x, y, z, ex, ey, ez }
        volume_count = 0,
        beacons = {},       -- address -> { name, x, y, z }
        beacon_count = 0,
        outer = nil,
        sub = nil,          -- { name, source = "dungeon"|"beacon", x, y, z, radius }
        seeded = false,
        seed_running = false,
        last_x = nil, last_y = nil, last_z = nil,
        hub_anchored = false, hub_name = nil,
        metrics = {
            volume_events = 0, volumes_admitted = 0, volumes_rejected = 0,
            beacon_events = 0, beacons_admitted = 0,
            triggers = 0, outer_changes = 0, sub_changes = 0,
            seed_runs = 0, seed_volumes = 0, seed_beacons = 0, seed_cpu_ms = 0.0,
            resolves = 0, resolves_skipped = 0, invalid_contexts = 0,
            outer_seeded_nearest = 0,
        },
    }

    local function unwrap(value) return Object.Unwrap(value) end
    local function valid(value) return Object.Valid(value) end

    -- FText -> plain string. ToString() is the verified route (invariant 0b); this
    -- UE4SS exports no FText global.
    local function plain(value)
        if value == nil then return nil end
        local out = nil
        pcall(function() out = value:ToString() end)
        if out == nil then return nil end
        out = tostring(out):gsub("[\r\n]", " "):match("^%s*(.-)%s*$")
        if out == "" then return nil end
        return out
    end

    -- An unset FName reads back as the literal "None"; an unset FText reads back empty.
    local function usable(value)
        if value == nil then return nil end
        if value == "None" then return nil end
        return value
    end

    local function read_property(object, field)
        if not valid(object) then return nil end
        local out = nil
        if not pcall(function() out = object[field] end) then return nil end
        return out
    end

    -- Returns name, kind. Text wins when present; an id-only volume is a sub-area.
    local function classify(text, id)
        text = usable(text)
        if text ~= nil then return text, "outer" end
        id = usable(id)
        if id ~= nil then return id, "sub" end
        return nil, nil
    end

    local function actor_position(actor)
        local pos = Object.ActorLocation(actor)
        if pos == nil then return nil end
        local x, y, z = tonumber(pos.x or pos.X), tonumber(pos.y or pos.Y), tonumber(pos.z or pos.Z)
        if x == nil or y == nil then return nil end
        return x, y, z or 0.0
    end

    local function box_extent(actor)
        local box = unwrap(read_property(actor, "Box"))
        if not valid(box) then return nil end
        local got = nil
        pcall(function() got = box:GetScaledBoxExtent() end)
        if got == nil then return nil end
        local x, y, z = nil, nil, nil
        pcall(function() x, y, z = got.X, got.Y, got.Z end)
        x, y, z = tonumber(x), tonumber(y), tonumber(z)
        if x == nil or y == nil then return nil end
        return x, y, z or 0.0
    end

    -- Volumes ----------------------------------------------------------------

    local function admit_volume(actor)
        actor = unwrap(actor)
        if not valid(actor) then
            runtime.metrics.invalid_contexts = runtime.metrics.invalid_contexts + 1
            return nil
        end
        local key = Object.Address(actor)
        if key == nil then return nil end
        local existing = runtime.volumes[key]
        if existing ~= nil then return existing end
        local name, kind = classify(plain(read_property(actor, "LocationText")),
            plain(read_property(actor, "LocationID")))
        if name == nil then
            runtime.metrics.volumes_rejected = runtime.metrics.volumes_rejected + 1
            return nil
        end
        local x, y, z = actor_position(actor)
        if x == nil then
            runtime.metrics.volumes_rejected = runtime.metrics.volumes_rejected + 1
            return nil
        end
        local ex, ey, ez = box_extent(actor)
        local record = { name = name, kind = kind, x = x, y = y, z = z,
            ex = ex, ey = ey, ez = ez }
        runtime.volumes[key] = record
        runtime.volume_count = runtime.volume_count + 1
        runtime.metrics.volumes_admitted = runtime.metrics.volumes_admitted + 1
        return record
    end

    local function set_outer(name)
        if runtime.outer == name then return end
        if name == nil then
            runtime.outer = nil
            runtime.metrics.outer_changes = runtime.metrics.outer_changes + 1
            state.overlay_refresh_requested = true
            return
        end
        runtime.outer = name
        runtime.metrics.outer_changes = runtime.metrics.outer_changes + 1
        state.overlay_refresh_requested = true
    end

    local function set_sub(record, source)
        if record == nil then
            if runtime.sub == nil then return end
            runtime.sub = nil
            runtime.metrics.sub_changes = runtime.metrics.sub_changes + 1
            state.overlay_refresh_requested = true
            return
        end
        if runtime.sub ~= nil and runtime.sub.name == record.name then return end
        local reach = SUB_RELEASE_MARGIN
        if record.ex ~= nil then
            reach = math.max(reach, math.max(record.ex, record.ey) + SUB_RELEASE_MARGIN)
        end
        runtime.sub = { name = record.name, source = source,
            x = record.x, y = record.y, z = record.z, radius = reach }
        runtime.metrics.sub_changes = runtime.metrics.sub_changes + 1
        state.overlay_refresh_requested = true
    end

    -- One handler for both trigger functions: the name lives on the actor, not in the
    -- arguments. (TryTriggerDungeonNotify's DungeonName parameter read back
    -- "unreadable" in both probe runs, and does not need to be read at all.)
    local function on_trigger(context)
        runtime.metrics.triggers = runtime.metrics.triggers + 1
        local record = admit_volume(context)
        if record == nil then return end
        if record.kind == "outer" then
            set_outer(record.name)
            -- Leaving a dungeon means entering an area, so an outer trigger clears the
            -- second line unless a beacon is about to claim it back in Resolve.
            if runtime.sub ~= nil and runtime.sub.source == "dungeon" then set_sub(nil) end
        else
            set_sub(record, "dungeon")
        end
    end

    local function on_volume_begin(context)
        runtime.metrics.volume_events = runtime.metrics.volume_events + 1
        admit_volume(context)
    end

    -- Beacons ----------------------------------------------------------------

    local function admit_beacon(actor)
        actor = unwrap(actor)
        if not valid(actor) then
            runtime.metrics.invalid_contexts = runtime.metrics.invalid_contexts + 1
            return nil
        end
        local key = Object.Address(actor)
        if key == nil or runtime.beacons[key] ~= nil then return nil end
        local got = nil
        pcall(function() got = actor:GetAreaName() end)
        local name = plain(unwrap(got))
        local unique = usable(plain(read_property(actor, "UniqueID")))
        if name == nil then
            name = unique
            if name == nil then return nil end
        end
        local x, y, z = actor_position(actor)
        if x == nil then return nil end
        runtime.beacons[key] = { name = name, unique = unique or "", x = x, y = y, z = z,
            anchor = unique == HUB_BEACON_ID }
        runtime.beacon_count = runtime.beacon_count + 1
        runtime.metrics.beacons_admitted = runtime.metrics.beacons_admitted + 1
        return runtime.beacons[key]
    end

    local function on_beacon_begin(context)
        runtime.metrics.beacon_events = runtime.metrics.beacon_events + 1
        admit_beacon(context)
    end

    -- Hooks ------------------------------------------------------------------

    local HOOK_SPECS = {
        { label = "area.volumeBegin", path = LOC_CLASS .. ":ReceiveBeginPlay", on = on_volume_begin },
        { label = "area.trigger", path = LOC_CLASS .. ":TriggerRegularNotify", on = on_trigger },
        { label = "area.triggerDungeon", path = LOC_CLASS .. ":TryTriggerDungeonNotify", on = on_trigger },
        { label = "area.beaconBegin", path = LANDING_CLASS .. ":ReceiveBeginPlay", on = on_beacon_begin },
    }

    -- A hook on a Blueprint class cannot arm until that class is loaded. The volume
    -- class came up on the fifteenth attempt in the AreaProbe run, eighty seconds in,
    -- so arming has to be retried -- the same "pending" rule Local/Discovery.lua uses.
    function runtime.Arm()
        if type(RegisterHook) ~= "function" then return 0, #HOOK_SPECS end
        local armed = 0
        for _, spec in ipairs(HOOK_SPECS) do
            if runtime.hooks[spec.path] == nil then
                local handler = spec.on
                local section = "hook." .. spec.label
                local ok, pre_id, post_id = pcall(RegisterHook, spec.path, function(context)
                    if global_runtime.generation ~= instance_generation then return end
                    local token = Perf.Begin()
                    pcall(handler, context)
                    Perf.End(section, token)
                end)
                if ok and (pre_id ~= nil or post_id ~= nil) then
                    runtime.hooks[spec.path] = { pre = pre_id, post = post_id, label = spec.label }
                    log("Area name hook label=" .. spec.label .. " state=armed")
                end
            end
            if runtime.hooks[spec.path] ~= nil then armed = armed + 1 end
        end
        return armed, #HOOK_SPECS
    end

    -- One-shot seed ----------------------------------------------------------
    -- Volumes and beacons that spawned before the mod armed are invisible to a
    -- spawn-sourced layer. This is the only global enumeration in the minimap and it
    -- runs once per world, sliced, and never again.

    local function seed_class(class_name, admit)
        if type(FindAllOf) ~= "function" then return 0 end
        local token = Perf.Begin()
        local ok, list = pcall(function() return FindAllOf(class_name) end)
        Perf.End("native.findall", token)
        if not ok or type(list) ~= "table" then return 0 end
        local added = 0
        for _, item in ipairs(list) do
            if admit(item) ~= nil then added = added + 1 end
        end
        return added
    end

    function runtime.Seed(reason)
        if runtime.seeded or runtime.seed_running then return false end
        runtime.seed_running = true
        local started = os.clock()
        local volumes = seed_class("BP_LocationNameDisplay_C", admit_volume)
        local beacons = seed_class("BP_LandingAreaBase_C", admit_beacon)
        runtime.seed_running = false
        runtime.seeded = true
        local cpu = (os.clock() - started) * 1000.0
        runtime.metrics.seed_runs = runtime.metrics.seed_runs + 1
        runtime.metrics.seed_volumes = runtime.metrics.seed_volumes + volumes
        runtime.metrics.seed_beacons = runtime.metrics.seed_beacons + beacons
        runtime.metrics.seed_cpu_ms = runtime.metrics.seed_cpu_ms + cpu
        log(string.format(
            "Area name seed reason=%s volumes=%d beacons=%d totalVolumes=%d totalBeacons=%d cpuMs=%.3f",
            tostring(reason or "world"), volumes, beacons,
            runtime.volume_count, runtime.beacon_count, cpu))
        runtime.last_x = nil
        return true
    end

    -- Resolution -------------------------------------------------------------

    local function beacon_radius_cm()
        local metres = tonumber(Config.MapAreaBeaconRadiusMeters)
        if metres == nil or metres <= 0 then metres = DEFAULT_BEACON_RADIUS_M end
        return metres * 100.0
    end

    -- Squared distance from a point to the surface of a record's box (zero inside).
    -- A record without an extent is treated as a point.
    local function box_distance_sq(record, x, y)
        local dx = math.abs(x - record.x) - (record.ex or 0)
        local dy = math.abs(y - record.y) - (record.ey or 0)
        if dx < 0 then dx = 0 end
        if dy < 0 then dy = 0 end
        return dx * dx + dy * dy
    end

    local function inside(record, x, y, z)
        if record.ex == nil then return false end
        if math.abs(x - record.x) > record.ex then return false end
        if math.abs(y - record.y) > record.ey then return false end
        if record.ez ~= nil and record.ez > 0 and math.abs(z - record.z) > record.ez then
            return false
        end
        return true
    end

    function runtime.Resolve(x, y, z)
        x, y, z = tonumber(x), tonumber(y), tonumber(z) or 0.0
        if x == nil or y == nil then return runtime.outer, runtime.sub and runtime.sub.name end
        if runtime.last_x ~= nil then
            local dx, dy = x - runtime.last_x, y - runtime.last_y
            if dx * dx + dy * dy < RESOLVE_MOVE_EPSILON * RESOLVE_MOVE_EPSILON then
                runtime.metrics.resolves_skipped = runtime.metrics.resolves_skipped + 1
                return runtime.outer, runtime.sub and runtime.sub.name
            end
        end
        runtime.last_x, runtime.last_y, runtime.last_z = x, y, z
        runtime.metrics.resolves = runtime.metrics.resolves + 1

        -- Geometry corrects the outer name whenever it can answer. v0.12.0 only ran
        -- this when the name was nil, which meant a fast travel left "Blackridge
        -- Cliffs" under the map all the way to the hub: the world change cleared the
        -- model but nothing re-established it, because no volume triggers at the far
        -- end of a warp. Being INSIDE a volume is authoritative and overrides; being
        -- outside every volume says nothing and keeps the last trigger, which is what
        -- stops the flapping across thin gate volumes.
        -- Not while a dungeon owns the second line: a dungeon is a level instance
        -- placed in world space, and her King's Crypt run sat inside the Blackridge
        -- Cliffs box the whole time. The outer name in a dungeon is whatever it was when
        -- you went in; the exit trigger sets it again.
        local in_dungeon = runtime.sub ~= nil and runtime.sub.source == "dungeon"
        if not in_dungeon then
            local containing = nil
            for _, record in pairs(runtime.volumes) do
                if record.kind == "outer" and inside(record, x, y, z) then
                    containing = record
                    break
                end
            end
            if containing ~= nil then
                set_outer(containing.name)
            elseif runtime.outer == nil then
                -- Nothing has triggered and no box holds us. Her 15:32 run spent its
                -- whole length like this: loaded at a beacon that sits inside no box,
                -- warped to the hub and back, never crossed a gate, and line one had
                -- nothing but the announcement fallback to show -- which was the
                -- dungeon's own name. The closest region by box surface is the honest
                -- seed; a trigger or a containment replaces it the moment one happens.
                local best, best_d2 = nil, NEAREST_OUTER_MAX_CM * NEAREST_OUTER_MAX_CM
                for _, record in pairs(runtime.volumes) do
                    if record.kind == "outer" then
                        local d2 = box_distance_sq(record, x, y)
                        if d2 < best_d2 then best, best_d2 = record, d2 end
                    end
                end
                if best ~= nil then
                    set_outer(best.name)
                    runtime.metrics.outer_seeded_nearest = runtime.metrics.outer_seeded_nearest + 1
                end
            end
        end

        -- The hub. No location volume anywhere in it, so its anchor beacon names line
        -- one while we are near it, and the hub's own sub-area beacons take line two.
        local hub = nil
        for _, beacon in pairs(runtime.beacons) do
            if beacon.anchor then
                local dx, dy = x - beacon.x, y - beacon.y
                if dx * dx + dy * dy <= HUB_ANCHOR_RADIUS_CM * HUB_ANCHOR_RADIUS_CM then
                    hub = beacon
                    break
                end
            end
        end
        if hub ~= nil and not in_dungeon then
            set_outer(hub.name)
            runtime.hub_anchored = true
            runtime.hub_name = hub.name
        elseif runtime.hub_anchored then
            -- Left the hub's reach: drop its name so the next seed or trigger can speak.
            runtime.hub_anchored = false
            if runtime.outer == runtime.hub_name then set_outer(nil) end
        end

        -- A beacon in reach owns the second line; it is the most specific thing near
        -- you and the user put landing sites in this category explicitly.
        local radius = beacon_radius_cm()
        local nearest, nearest_d2 = nil, radius * radius
        for _, beacon in pairs(runtime.beacons) do
            if not beacon.anchor then
                local dx, dy = x - beacon.x, y - beacon.y
                local d2 = dx * dx + dy * dy
                if d2 <= nearest_d2 then nearest, nearest_d2 = beacon, d2 end
            end
        end
        -- A dungeon name is sticky. v0.12.1 released it by distance from the volume
        -- that set it, and that volume is a gate at the entrance: her King's Crypt run
        -- lost the second line about 45 m in, "at some point in the dungeon". It now
        -- survives until an outer trigger (the exit), another dungeon volume (the next
        -- level -- Flooded Village followed King's Crypt in the same run), or a world
        -- change. Beacons defer to it for the same reason: a checkpoint inside a
        -- dungeon is still inside that dungeon.
        if in_dungeon then
            -- nothing to do: the triggers own it
        elseif nearest ~= nil then
            if runtime.sub == nil or runtime.sub.name ~= nearest.name then
                set_sub({ name = nearest.name, x = nearest.x, y = nearest.y, z = nearest.z },
                    "beacon")
            end
        elseif runtime.sub ~= nil then
            -- A beacon name releases once you are out of its radius.
            local dx, dy = x - runtime.sub.x, y - runtime.sub.y
            if dx * dx + dy * dy > radius * radius then set_sub(nil) end
        end

        return runtime.outer, runtime.sub and runtime.sub.name
    end

    function runtime.Names()
        return runtime.outer, runtime.sub and runtime.sub.name,
            runtime.sub and runtime.sub.source or nil
    end

    function runtime.OnWorldPre()
        runtime.volumes, runtime.volume_count = {}, 0
        runtime.beacons, runtime.beacon_count = {}, 0
        runtime.outer, runtime.sub = nil, nil
        runtime.seeded, runtime.seed_running = false, false
        runtime.last_x, runtime.last_y, runtime.last_z = nil, nil, nil
        runtime.hub_anchored = false
        state.overlay_refresh_requested = true
    end

    function runtime.DropWorldReferencesUnread()
        runtime.OnWorldPre()
    end

    function runtime.EmitSummary(reason)
        local m = runtime.metrics
        local armed = 0
        for _, spec in ipairs(HOOK_SPECS) do
            if runtime.hooks[spec.path] ~= nil then armed = armed + 1 end
        end
        local outer_count, sub_count = 0, 0
        for _, record in pairs(runtime.volumes) do
            if record.kind == "outer" then outer_count = outer_count + 1
            else sub_count = sub_count + 1 end
        end
        log(string.format(
            "Area name summary reason=%s hooks=%d/%d outer=%s sub=%s subSource=%s volumes=%d(outer=%d,sub=%d) beacons=%d volumeEvents=%d admitted=%d rejected=%d beaconEvents=%d triggers=%d outerChanges=%d subChanges=%d seedRuns=%d seedVolumes=%d seedBeacons=%d seedCpuMs=%.3f resolves=%d resolvesSkipped=%d outerSeededNearest=%d hubAnchored=%s invalid=%d beaconRadiusM=%.0f retainedActorRefs=0 recurringGlobalScans=0",
            tostring(reason or "manual"), armed, #HOOK_SPECS,
            tostring(runtime.outer or "none"),
            tostring(runtime.sub and runtime.sub.name or "none"),
            tostring(runtime.sub and runtime.sub.source or "none"),
            runtime.volume_count, outer_count, sub_count, runtime.beacon_count,
            m.volume_events, m.volumes_admitted, m.volumes_rejected, m.beacon_events,
            m.triggers, m.outer_changes, m.sub_changes,
            m.seed_runs, m.seed_volumes, m.seed_beacons, m.seed_cpu_ms,
            m.resolves, m.resolves_skipped, m.outer_seeded_nearest, tostring(runtime.hub_anchored),
            m.invalid_contexts,
            beacon_radius_cm() / 100.0))
    end

    return runtime
end

return Factory
